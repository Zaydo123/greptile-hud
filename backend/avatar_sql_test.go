package main

// Lockstep coverage for the avatar statements in avatar.go. Profile photos are
// stored per user (one row keyed by user_id) and the client cache-busts on the
// upload time, so the three statements here pin contracts that a silent drift
// would break with no compiler or schema error:
//
//   - handlePutAvatar's upsert must conflict on (user_id) — the schema's
//     PRIMARY KEY and the whole one-photo-per-user grain — and must set
//     updated_at forward via GREATEST(now(), updated_at + interval '1
//     second') so two uploads in the same second still produce distinct
//     cache-busting URLs. It must DO UPDATE, never DO NOTHING, or a re-upload
//     would stop refreshing the photo and the client would serve a stale
//     cached bytes forever.
//   - handleDeleteAvatar and handleGetAvatar must match login
//     case-insensitively via a join through users (lower($1)), the same
//     merge-the-casing convention db.go's getOrCreateUser uses — otherwise a
//     photo stored for "Zayd" couldn't be read or deleted as "zayd".
//
// This test reads the actual query text back out of avatar.go and pins each
// property, mirroring the guards usage_sql_test.go, user_sql_test.go and
// status_history_sql_test.go apply. Stdlib only — no new dependency. The
// schema-side PRIMARY KEY those statements lean on is already pinned in
// schema_lockstep_test.go's TestSchemaConflictTargetsExist.

import (
	"os"
	"strings"
	"testing"
)

func avatarSource(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile("avatar.go")
	if err != nil {
		t.Fatalf("read avatar.go: %v", err)
	}
	return string(raw)
}

// The upsert must keep tracking one photo per user. Its ON CONFLICT names
// (user_id), the avatars table's PRIMARY KEY; a drift to a coarser or missing
// target would either split photos across duplicate rows or make Postgres
// reject the statement outright.
func TestAvatarUpsertKeepsPerUserGrain(t *testing.T) {
	src := avatarSource(t)

	const insert = "INSERT INTO avatars (user_id, content_type, data, updated_at)"
	if got := strings.Count(src, insert); got != 1 {
		t.Fatalf("avatar.go contains %q %d times, want exactly 1 (the upsert)", insert, got)
	}

	const conflict = "ON CONFLICT (user_id) DO UPDATE"
	if got := strings.Count(src, conflict); got != 1 {
		t.Fatalf("avatar.go contains %q %d times, want exactly 1", conflict, got)
	}

	// A re-upload is a replacement: DO NOTHING would silently keep serving the
	// old bytes and the client, seeing an unchanged updated_at URL, would cache
	// them forever.
	if strings.Contains(src, "DO NOTHING") {
		t.Fatal("avatar upsert must DO UPDATE on conflict, never DO NOTHING")
	}
}

// The client cache-busts profile photos by the upload time inside the URL, so
// on every save the stored updated_at must move strictly forward — even for
// two uploads landing in the same second. GREATEST(now(), updated_at +
// interval '1 second') is exactly that guarantee; assigning now() alone would
// let a same-second re-upload keep the old URL.
func TestAvatarUpsertAdvancesUpdatedAt(t *testing.T) {
	src := avatarSource(t)

	const advance = "updated_at = GREATEST(now(), avatars.updated_at + interval '1 second')"
	if got := strings.Count(src, advance); got != 1 {
		t.Fatalf("avatar.go contains the updated_at advance %q %d times, want exactly 1", advance, got)
	}

	// Binding the returned timestamp into the response is what gives the client
	// a fresh cache-busting version; a RETURNING that dropped updated_at would
	// break the whole mechanism.
	const returning = "RETURNING updated_at"
	if got := strings.Count(src, returning); got != 1 {
		t.Fatalf("avatar.go contains %q %d times, want exactly 1 (the upsert RETURNING)", returning, got)
	}
}

// Deleting a photo for a user must be case-insensitive on the login: the user
// is identified by a self-chosen username, and db.go collapses "Zayd"/"zayd"
// into one row. A case-sensitive delete would fail to clear a photo stored
// under a differently-cased claim.
func TestAvatarDeleteMatchesLoginCaseInsensitively(t *testing.T) {
	src := avatarSource(t)

	const del = "DELETE FROM avatars"
	if got := strings.Count(src, del); got != 1 {
		t.Fatalf("avatar.go contains %q %d times, want exactly 1", del, got)
	}

	const lookup = "WHERE user_id IN (SELECT id FROM users WHERE lower(login) = lower($1))"
	if got := strings.Count(src, lookup); got != 1 {
		t.Fatalf("avatar.go contains the delete lookup %q %d times, want exactly 1", lookup, got)
	}
}

// Reading must go through the same case-insensitive login join, and select the
// stored content type (client never picks it). This is the mirror of the
// delete lookup.
func TestAvatarReadMatchesLoginCaseInsensitively(t *testing.T) {
	src := avatarSource(t)

	if got := strings.Count(src, "SELECT a.content_type, a.data"); got != 1 {
		t.Fatalf("avatar.go contains the read select %d times, want exactly 1", got)
	}
	if got := strings.Count(src, "JOIN users u ON u.id = a.user_id"); got != 1 {
		t.Fatalf("avatar.go contains %q %d times, want exactly 1", "JOIN users u ON u.id = a.user_id", got)
	}
	if got := strings.Count(src, "WHERE lower(u.login) = lower($1)"); got != 1 {
		t.Fatalf("avatar.go contains %q %d times, want exactly 1", "WHERE lower(u.login) = lower($1)", got)
	}
}
