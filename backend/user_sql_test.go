package main

// Lockstep coverage for the user lookup/create statements in db.go. Identity
// here is trust-based: anyone can claim any username, and a re-claim with
// different casing (a pulse arriving as "zayd" after the row was created as
// "Zayd") must MERGE into the existing row instead of creating a twin. The
// whole model leans on three query-side invariants that can't be caught by
// the compiler:
//
//   - getUserByLogin reads by exact login ($1). The case-insensitive
//     re-lookup lives only in getOrCreateUser's conflict path — the exact
//     read is what makes the primary lookup use the plain unique login index.
//   - getOrCreateUser inserts with ON CONFLICT DO NOTHING, never DO UPDATE.
//     First claim wins: an upsert here would let a differently-cased claim
//     silently overwrite the original row's name and timestamps.
//   - Every read selects userCols in the same order scanUser decodes them.
//     A column reorder in userCols (or in scanUser) would corrupt every
//     profile and leaderboard read with no schema or compile error.
//
// This test reads the actual query text back out of db.go and pins each
// property, mirroring devtime_sql_test.go, leaderboard_sql_test.go,
// sprints_sql_test.go and statuses_sql_test.go. Stdlib only — no new
// dependency.

import (
	"os"
	"strings"
	"testing"
)

func userSource(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile("db.go")
	if err != nil {
		t.Fatalf("read db.go: %v", err)
	}
	return string(raw)
}

func TestUserLookupIsExactMatchFirst(t *testing.T) {
	src := userSource(t)

	// The primary lookup matches the exact login string. The query must not
	// carry a lower() on either side: that read rides the plain UNIQUE login
	// index, and pinning the full statement means a lower() wrapper can't be
	// added to it unnoticed.
	const exact = `"SELECT "+userCols+" FROM users WHERE login = $1"`
	if got := strings.Count(src, exact); got != 1 {
		t.Fatalf("db.go contains getUserByLogin statement %q %d times, want exactly 1", exact, got)
	}
}

func TestUserConflictPathStaysCaseInsensitive(t *testing.T) {
	src := userSource(t)

	// The case-insensitive re-lookup must exist in the conflict/race path of
	// getOrCreateUser: when the INSERT loses to the users_login_lower_idx
	// unique index (or a concurrent create), the fallback reads by lower(login)
	// so "Zayd" and "zayd" collapse into one row instead of creating a twin.
	// The exact string appears once and only in db.go's getOrCreateUser — the
	// status clear handler has its own lower() lookup in statuses.go, which
	// is pinned there.
	const ci = `"SELECT "+userCols+" FROM users WHERE lower(login) = lower($1)"`
	if got := strings.Count(src, ci); got != 1 {
		t.Fatalf("db.go contains the case-insensitive fallback %d times, want exactly 1", got)
	}
}

func TestGetOrCreateInsertIsConflictDoNothing(t *testing.T) {
	src := userSource(t)

	// First claim wins: the create must be ON CONFLICT DO NOTHING. A drift to
	// DO UPDATE would let a later, differently-cased claim overwrite the
	// original row's identity data (name, updated_at) — a supply-chain of the
	// trust model. Pin the full statement so neither the conflict target nor
	// the RETURNING column list can change silently.
	const insert = `"INSERT INTO users (login) VALUES ($1) ON CONFLICT DO NOTHING RETURNING "+userCols`
	if got := strings.Count(src, insert); got != 1 {
		t.Fatalf("db.go contains getOrCreateUser INSERT %q %d times, want exactly 1", insert, got)
	}
	if got := strings.Count(src, "DO UPDATE"); got != 0 {
		t.Fatalf("db.go contains DO UPDATE %d times, want 0 (first-claim-wins must not upsert)", got)
	}
}

func TestUserColsMatchScanOrder(t *testing.T) {
	src := userSource(t)

	// userCols is the one column list every user read shares, and scanUser
	// decodes by position. Both must stay the same six columns in the same
	// order, or every profile/leaderboard/status read shifts columns silently.
	// Pin the const and the scan statement together so a reorder on either
	// side fails CI.
	const cols = `const userCols = "id, login, name, last_seen, created_at, updated_at"`
	if got := strings.Count(src, cols); got != 1 {
		t.Fatalf("db.go contains %q %d times, want exactly 1", cols, got)
	}
	const scan = "row.Scan(&u.ID, &u.Login, &name, &u.LastSeen, &u.CreatedAt, &u.UpdatedAt)"
	if got := strings.Count(src, scan); got != 1 {
		t.Fatalf("db.go contains scanUser scan %q %d times, want exactly 1", scan, got)
	}
}
