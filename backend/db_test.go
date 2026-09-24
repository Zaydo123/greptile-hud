package main

// Unit coverage for scanUser (db.go). It is the single place a users row is
// decoded into a *User across every handler, so a regression here (mis-ordered
// columns, a dropped NULL-name fallback, or a swallowed scan error) would
// corrupt every profile/leaderboard/status response. Tested with the stdlib
// only — a fake row scanner stands in for the database driver, so no Postgres
// and no new dependency.

import (
	"database/sql"
	"errors"
	"fmt"
	"testing"
	"time"
)

// stubRow mimics the Scan(...any) contract of *sql.Row/*sql.Rows. It copies
// each provided cell into the matching destination by type, mirroring how the
// postgres driver fills a *sql.Row.
type stubRow struct {
	vals []any
	err  error
}

var errStubScan = errors.New("stub scan failure")

func (r stubRow) Scan(dest ...any) error {
	if r.err != nil {
		return r.err
	}
	if len(dest) != len(r.vals) {
		return fmt.Errorf("scan: %d destinations for %d values", len(dest), len(r.vals))
	}
	for i, d := range dest {
		if err := assignCell(d, r.vals[i]); err != nil {
			return err
		}
	}
	return nil
}

func assignCell(dest, src any) error {
	switch d := dest.(type) {
	case *int64:
		v, ok := src.(int64)
		if !ok {
			return fmt.Errorf("scan: cannot assign %T to *int64", src)
		}
		*d = v
	case *string:
		v, ok := src.(string)
		if !ok {
			return fmt.Errorf("scan: cannot assign %T to *string", src)
		}
		*d = v
	case *sql.NullString:
		v, ok := src.(sql.NullString)
		if !ok {
			return fmt.Errorf("scan: cannot assign %T to *sql.NullString", src)
		}
		*d = v
	case *time.Time:
		v, ok := src.(time.Time)
		if !ok {
			return fmt.Errorf("scan: cannot assign %T to *time.Time", src)
		}
		*d = v
	case **time.Time:
		v, ok := src.(*time.Time)
		if !ok {
			return fmt.Errorf("scan: cannot assign %T to **time.Time", src)
		}
		*d = v
	default:
		return fmt.Errorf("scan: unsupported destination type %T", dest)
	}
	return nil
}

// user cells in the fixed order scanUser requests them: id, login, name,
// last_seen, created_at, updated_at.
func fullUserCells() []any {
	lastSeen := time.Date(2026, 9, 24, 12, 0, 0, 0, time.UTC)
	created := time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)
	updated := time.Date(2026, 9, 24, 12, 5, 0, 0, time.UTC)
	return []any{
		int64(7),
		"zayd",
		sql.NullString{String: "Zayd Alzein", Valid: true},
		&lastSeen,
		created,
		updated,
	}
}

func TestScanUser(t *testing.T) {
	got, err := scanUser(stubRow{vals: fullUserCells()})
	if err != nil {
		t.Fatalf("scanUser() error = %v, want nil", err)
	}
	if got == nil {
		t.Fatal("scanUser() = nil, want *User")
	}
	if got.ID != 7 || got.Login != "zayd" {
		t.Fatalf("scanUser() = (%d, %q), want (7, zayd)", got.ID, got.Login)
	}
	if got.Name != "Zayd Alzein" {
		t.Fatalf("Name = %q, want Zayd Alzein", got.Name)
	}
	if got.LastSeen == nil || !got.LastSeen.Equal(time.Date(2026, 9, 24, 12, 0, 0, 0, time.UTC)) {
		t.Fatalf("LastSeen = %v, want 2026-09-24T12:00:00Z", got.LastSeen)
	}
	if !got.CreatedAt.Equal(time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("CreatedAt = %v, want 2026-09-01T00:00:00Z", got.CreatedAt)
	}
	if !got.UpdatedAt.Equal(time.Date(2026, 9, 24, 12, 5, 0, 0, time.UTC)) {
		t.Fatalf("UpdatedAt = %v, want 2026-09-24T12:05:00Z", got.UpdatedAt)
	}
}

func TestScanUserNullName(t *testing.T) {
	cells := fullUserCells()
	// A NULL users.name comes back as an invalid NullString; scanUser must
	// fall back to the empty string rather than blow up or leave a zero User.
	cells[2] = sql.NullString{Valid: false}

	got, err := scanUser(stubRow{vals: cells})
	if err != nil {
		t.Fatalf("scanUser() with NULL name error = %v, want nil", err)
	}
	if got == nil {
		t.Fatal("scanUser() with NULL name = nil, want *User")
	}
	if got.Name != "" {
		t.Fatalf("Name = %q, want empty string (NULL fallback)", got.Name)
	}
	if got.Login != "zayd" {
		t.Fatalf("Login = %q, want zayd (other columns unaffected by NULL name)", got.Login)
	}
}

func TestScanUserNullLastSeen(t *testing.T) {
	cells := fullUserCells()
	// A user who has never sent a heartbeat has a NULL last_seen (*time.Time
	// nil) — isOnline() depends on this staying nil so it reads as offline.
	cells[3] = (*time.Time)(nil)

	got, err := scanUser(stubRow{vals: cells})
	if err != nil {
		t.Fatalf("scanUser() with NULL last_seen error = %v, want nil", err)
	}
	if got == nil {
		t.Fatal("scanUser() with NULL last_seen = nil, want *User")
	}
	if got.LastSeen != nil {
		t.Fatalf("LastSeen = %v, want nil for a user with no heartbeat", got.LastSeen)
	}
}

func TestScanUserPropagatesError(t *testing.T) {
	got, err := scanUser(stubRow{err: errStubScan})
	if err != errStubScan {
		t.Fatalf("scanUser() error = %v, want errStubScan", err)
	}
	if got != nil {
		t.Fatalf("scanUser() = %v, want nil on error", got)
	}
}

func TestScanUserColumnMismatch(t *testing.T) {
	// A schema drift that reorders columns must fail loudly instead of silently
	// producing a wrong user. Pass one fewer cell than scanUser scans.
	cells := fullUserCells()[:5]
	if _, err := scanUser(stubRow{vals: cells}); err == nil {
		t.Fatal("scanUser() with a column count mismatch = nil, want error")
	}
}
