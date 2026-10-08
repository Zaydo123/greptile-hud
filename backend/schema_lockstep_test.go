package main

// Lockstep coverage: the SQL in this package hardcodes table, column and index
// names against schema.sql (embedded as schemaSQL and applied at startup, see
// openDB). A rename in a query but not the schema — or a new column a handler
// starts reading that was never added to the schema — silently breaks the API,
// and dropping the case-insensitive-unique login index splits "Zayd" and "zayd"
// into two leaderboard rows. These tests pin every identifier the handlers
// touch against the schema so drift can't ship unnoticed. Stdlib only — no new
// dependency.

import (
	"regexp"
	"strings"
	"testing"
)

// requiredTables lists, per table, the columns this package's queries read or
// write (sourced from db.go, sprints.go, statuses.go, leaderboard.go). Add a
// column here when a new query starts touching it.
var requiredTables = map[string][]string{
	"users": {
		"id", "login", "name", "last_seen",
		"created_at", "updated_at",
		"status_emoji", "status_message", "status_started_at",
	},
	"devtime": {"user_id", "day", "seconds", "last_heartbeat_at"},
	"sprints": {"user_id", "started_at", "last_active_at", "ended_at", "duration_seconds"},
}

// schemaColumns parses schemaSQL into table -> set of declared columns. It
// covers the CREATE TABLE declarations and the idempotent ALTER TABLE ADD
// COLUMN migrations (including multi-line statements like the status columns
// added after launch).
func schemaColumns(t *testing.T) map[string]map[string]bool {
	t.Helper()
	cols := map[string]map[string]bool{}
	add := func(table, col string) {
		if cols[table] == nil {
			cols[table] = map[string]bool{}
		}
		cols[table][col] = true
	}

	// CREATE TABLE IF NOT EXISTS users ( ... \n);
	tableBlock := regexp.MustCompile(`(?s)CREATE TABLE IF NOT EXISTS\s+(\w+)\s*\((.*?)\n\);`)
	columnName := regexp.MustCompile(`(?m)^\s*(\w+)\s`)
	tableConstraints := map[string]bool{
		"PRIMARY": true, "FOREIGN": true, "UNIQUE": true,
		"CHECK": true, "CONSTRAINT": true,
	}
	for _, m := range tableBlock.FindAllStringSubmatch(schemaSQL, -1) {
		table := m[1]
		for _, cm := range columnName.FindAllStringSubmatch(m[2]+"\n", -1) {
			name := cm[1]
			if tableConstraints[name] {
				continue
			}
			add(table, name)
		}
	}

	// ALTER TABLE users ADD COLUMN IF NOT EXISTS status_emoji TEXT,\n  ...;
	alterBlock := regexp.MustCompile(`(?s)ALTER TABLE\s+(\w+)\s+(.*?);`)
	addedColumn := regexp.MustCompile(`ADD COLUMN IF NOT EXISTS\s+(\w+)`)
	for _, m := range alterBlock.FindAllStringSubmatch(schemaSQL, -1) {
		for _, c := range addedColumn.FindAllStringSubmatch(m[2], -1) {
			add(m[1], c[1])
		}
	}

	if len(cols) == 0 {
		t.Fatal("schema parser found no tables — is schemaSQL embedded?")
	}
	return cols
}

func TestSchemaDefinesRequiredColumns(t *testing.T) {
	cols := schemaColumns(t)

	for table, want := range requiredTables {
		got, ok := cols[table]
		if !ok {
			t.Errorf("schema.sql defines no %q table, but this package's queries reference it", table)
			continue
		}
		for _, col := range want {
			if !got[col] {
				t.Errorf("schema.sql table %q is missing column %q that this package's queries reference", table, col)
			}
		}
	}
}

func TestSchemaCaseInsensitiveLoginUnique(t *testing.T) {
	// getOrCreateUser merges same-login rows case-insensitively and the status
	// handlers clear/re-set on lower(login); the unique index on lower(login)
	// is what guarantees "Zayd" and "zayd" stay one row. Pin it so a migration
	// can't quietly weaken it into a plain index.
	re := regexp.MustCompile(`CREATE\s+UNIQUE\s+INDEX\s+IF\s+NOT\s+EXISTS\s+users_login_lower_idx\s+ON\s+users\s*\(\s*lower\s*\(\s*login\s*\)\s*\)`)
	if !re.MatchString(schemaSQL) {
		t.Fatal("schema.sql no longer defines users_login_lower_idx as UNIQUE on users(lower(login))")
	}
}

func TestSchemaSQLIsEmbedded(t *testing.T) {
	// Guard the //go:embed contract: openDB applies schemaSQL at startup, so an
	// edit that renames the embed target or breaks it must fail loudly here
	// rather than ship a schema-less binary.
	if !strings.Contains(schemaSQL, "CREATE TABLE IF NOT EXISTS users") {
		t.Fatal("schemaSQL is empty or missing the users table — //go:embed may be broken")
	}
}
