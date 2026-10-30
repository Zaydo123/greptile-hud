package main

// Lockstep coverage for the status-history statements in status_history.go.
// Completed sessions are stored server-side so a user's history follows them
// across Macs; the app uploads each finished session with its own client
// UUID, and the handlers below are the only code that touches status_history.
// These statements are inline literals, so they can drift silently with no
// compiler error:
//
//   - upsertHistory keys its ON CONFLICT on (user_id, client_id): that pair is
//     the whole "history follows me" contract — a re-upload or a rename must
//     merge into the same row, never duplicate. A drift to conflict on id, or
//     to DO NOTHING, would either duplicate sessions or silently drop updates.
//     The upsert must also keep writing the full column set (emoji, message,
//     started_at, ended_at) plus updated_at = now(); a dropped column would
//     silently lose recorded history.
//   - handleDeleteStatusHistory must delete exactly one session (client_id =
//     $2::uuid) scoped through the user's case-insensitive login identity —
//     clearing "zayd" must remove the session recorded as "Zayd" — and it must
//     never delete the users row itself.
//   - handleGetStatusHistory must look the user up case-insensitively and
//     return newest-first with a stable unique tie-break (h.client_id), so two
//     sessions started in the same instant can't swap places between polls;
//     and it must keep its LIMIT parameterized ($2) so the handler's 1…500
//     clamp stays the single source of the cap.
//
// This test reads the actual query text back out of status_history.go and
// pins each property, mirroring the guards user_sql_test.go,
// leaderboard_sql_test.go and statuses_sql_test.go apply. Stdlib only — no
// new dependency.

import (
	"os"
	"strings"
	"testing"
)

func statusHistorySource(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile("status_history.go")
	if err != nil {
		t.Fatalf("read status_history.go: %v", err)
	}
	return string(raw)
}

// The history upsert must keep merging on the (user_id, client_id) pair the
// schema's unique constraint declares. That pair is what makes re-uploads and
// renames follow the user across Macs instead of duplicating rows.
func TestStatusHistoryUpsertKeepsClientIDIdentity(t *testing.T) {
	src := statusHistorySource(t)

	const insert = "INSERT INTO status_history (user_id, client_id, emoji, message, started_at, ended_at, updated_at)"
	if got := strings.Count(src, insert); got != 1 {
		t.Fatalf("status_history.go contains %q %d times, want exactly 1 (the upsert)", insert, got)
	}

	const conflict = "ON CONFLICT (user_id, client_id) DO UPDATE"
	if got := strings.Count(src, conflict); got != 1 {
		t.Fatalf("status_history.go contains %q %d times, want exactly 1", conflict, got)
	}

	// A UPSERT that stopped updating (DO NOTHING) would silently drop renamed
	// or corrected sessions instead of merging them.
	if strings.Contains(src, "ON CONFLICT (user_id, client_id) DO NOTHING") {
		t.Fatal("status_history upsert must DO UPDATE, never DO NOTHING")
	}
}

// The upsert must write every stored column via EXCLUDED plus a fresh
// updated_at. If any one of them were dropped from the SET clause, uploaded
// history would be stored partially and no compiler would notice.
func TestStatusHistoryUpsertWritesFullColumnSet(t *testing.T) {
	src := statusHistorySource(t)

	for _, col := range []string{
		"emoji = EXCLUDED.emoji",
		"message = EXCLUDED.message",
		"started_at = EXCLUDED.started_at",
		"ended_at = EXCLUDED.ended_at",
	} {
		if got := strings.Count(src, col); got != 1 {
			t.Fatalf("status_history.go contains the upsert column-set fragment %q %d times, want exactly 1", col, got)
		}
	}

	if got := strings.Count(src, "updated_at = now()"); got != 1 {
		t.Fatalf("status_history.go contains %q %d times, want exactly 1 (the upsert refresh)", "updated_at = now()", got)
	}
}

// Deleting a history session must remove exactly that one client session,
// resolved through the user's case-insensitive login identity — the same
// merged identity the trust model pins elsewhere — and must never delete the
// users row itself.
func TestStatusHistoryDeleteIsScopedAndCaseInsensitive(t *testing.T) {
	src := statusHistorySource(t)

	if got := strings.Count(src, "DELETE FROM status_history"); got != 1 {
		t.Fatalf("status_history.go contains %q %d times, want exactly 1 (the delete)", "DELETE FROM status_history", got)
	}

	const byUUID = "WHERE client_id = $2::uuid"
	if got := strings.Count(src, byUUID); got != 1 {
		t.Fatalf("status_history.go contains %q %d times, want exactly 1", byUUID, got)
	}

	const viaLogin = "AND user_id IN (SELECT id FROM users WHERE lower(login) = lower($1))"
	if got := strings.Count(src, viaLogin); got != 1 {
		t.Fatalf("status_history.go contains %q %d times, want exactly 1", viaLogin, got)
	}

	// A delete that matched (or cascaded into) the users table would blow away
	// the identity along with the session — the trust model's "clear the
	// status, keep the identity" contract applies to history too.
	if strings.Contains(src, "DELETE FROM users") {
		t.Fatal("status_history delete must only touch status_history, never users")
	}
}

// The history list must stay newest-first with the client UUID as a stable
// tie-break (identical started_at values otherwise swap between polls), read
// through the case-insensitive login merge, and keep its LIMIT parameterized
// so the handler's 1…500 clamp is the single cap.
func TestStatusHistoryListIsOrderedAndLimitScoped(t *testing.T) {
	src := statusHistorySource(t)

	const join = "JOIN users u ON u.id = h.user_id"
	if got := strings.Count(src, join); got != 1 {
		t.Fatalf("status_history.go contains %q %d times, want exactly 1 (the list query)", join, got)
	}

	const lookup = "WHERE lower(u.login) = lower($1)"
	if got := strings.Count(src, lookup); got != 1 {
		t.Fatalf("status_history.go contains %q %d times, want exactly 1", lookup, got)
	}

	const order = "ORDER BY h.started_at DESC, h.client_id"
	if got := strings.Count(src, order); got != 1 {
		t.Fatalf("status_history.go contains %q %d times, want exactly 1", order, got)
	}

	if got := strings.Count(src, "LIMIT $2"); got != 1 {
		t.Fatalf("status_history.go contains %q %d times, want exactly 1 (the parameterized cap)", "LIMIT $2", got)
	}
}
