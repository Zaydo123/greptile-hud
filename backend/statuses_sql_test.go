package main

// Lockstep coverage for the status statements in statuses.go. The result cap
// (LIMIT 100) on the status-list query and the two mutation statements
// (handleSetStatus / handleClearStatus) are inline literals, so they can drift
// silently with no compiler error:
//
//   - a dropped LIMIT would grow the payload unboundedly as the users table
//     accumulates;
//   - handleSetStatus keys its UPDATE by the canonical row id the
//     getOrCreateUser lookup returned (WHERE id = $1). A drift to matching by
//     login instead would let a differently-cased re-claim write to a
//     case-twin row, breaking the merged identity that user_sql_test.go pins
//     for the create path;
//   - handleClearStatus must keep matching by lower(login) = lower($1), the
//     case-insensitive identity the trust model relies on (user_sql_test.go
//     asserts this lookup is pinned; this test is what actually pins it), and
//     must clear exactly the three status columns, never deleting the row or
//     touching other columns;
//   - both mutations must keep writing the full status column set (emoji,
//     message, started_at) plus updated_at = now() — a dropped column would
//     silently lose published status data.
//
// This test reads the actual query text back out of statuses.go and pins each
// property, mirroring the guards user_sql_test.go and leaderboard_sql_test.go
// apply. Stdlib only — no new dependency.

import (
	"os"
	"strings"
	"testing"
)

func statusSource(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile("statuses.go")
	if err != nil {
		t.Fatalf("read statuses.go: %v", err)
	}
	return string(raw)
}

// handleStatuses must cap its result set, or the Crew status feed grows
// without bound and the per-refresh cost balloons as the users table
// accumulates. The single LIMIT literal sits in the one active-status query.
func TestStatusesQueryCapsAtLimit100(t *testing.T) {
	src := statusSource(t)
	if got := strings.Count(src, "LIMIT 100"); got != 1 {
		t.Fatalf("statuses.go contains LIMIT 100 %d times, want exactly 1 (the active-status query)", got)
	}
}

// The set-status UPDATE must key by the row id getOrCreateUser resolved, not
// by login. Matching by login would write to whichever row's exact case
// matches — a "Zayd" claim after the row was created as "zayd" would update a
// twin instead of the merged identity, and the published status would
// silently diverge from the profile it claims to belong to.
func TestSetStatusUpdateKeysById(t *testing.T) {
	src := statusSource(t)

	const byID = "WHERE id = $1"
	if got := strings.Count(src, byID); got != 1 {
		t.Fatalf("statuses.go contains %q %d times, want exactly 1 (the handleSetStatus UPDATE)", byID, got)
	}

	// The set handler must never match by lower(login): the id keying above
	// is what makes the merged identity work, so a drift here must fail CI.
	if strings.Contains(src, "SET status_emoji = $2, status_message = $3, status_started_at = $4, updated_at = now()\n\t\tWHERE lower(login)") {
		t.Fatal("handleSetStatus UPDATE must key by id, not lower(login)")
	}
}

// The clear-status UPDATE must keep matching by lower(login) = lower($1), the
// same case-insensitive identity the create/fallback path uses — a user who
// claimed "Zayd" and clears with "zayd" must clear the same merged row. It
// must also clear exactly the three status columns: anything that deletes the
// row, or touches last_seen / name, would violate the trust model's "clear the
// status, keep the identity" contract.
func TestClearStatusUpdateIsCaseInsensitiveAndTargeted(t *testing.T) {
	src := statusSource(t)

	const ci = "WHERE lower(login) = lower($1)"
	if got := strings.Count(src, ci); got != 1 {
		t.Fatalf("statuses.go contains %q %d times, want exactly 1 (the handleClearStatus UPDATE)", ci, got)
	}

	const clear = "SET status_emoji = NULL, status_message = NULL, status_started_at = NULL, updated_at = now()"
	if got := strings.Count(src, clear); got != 1 {
		t.Fatalf("statuses.go contains the clear column-set %q %d times, want exactly 1", clear, got)
	}
}

// Both status mutations must write the full published column set plus
// updated_at. If a column (started_at especially) were dropped from the SET
// clause, the status would be published without its start time or with stale
// data, and no compiler would notice.
func TestStatusMutationsWriteFullColumnSet(t *testing.T) {
	src := statusSource(t)

	const set = "SET status_emoji = $2, status_message = $3, status_started_at = $4, updated_at = now()"
	if got := strings.Count(src, set); got != 1 {
		t.Fatalf("statuses.go contains the set column-set %q %d times, want exactly 1", set, got)
	}

	// The full column set must appear exactly twice in mutations (set + clear)
	// and once in the SELECT (statuses.go also selects status_* in handleStatuses),
	// so a dropped column in either mutation is caught by the count below.
	if got := strings.Count(src, "status_emoji"); got != 3 {
		t.Fatalf("statuses.go mentions status_emoji %d times, want 3 (SELECT + set + clear)", got)
	}
}
