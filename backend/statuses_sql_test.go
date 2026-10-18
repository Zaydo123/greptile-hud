package main

// Lockstep coverage for the status-list statement in handleStatuses. The
// result cap (LIMIT 100) is an inline literal in statuses.go, so it can drift
// silently with no compiler error — a dropped LIMIT would grow the payload
// unboundedly as the users table accumulates. This test reads the actual
// query text back out of statuses.go and pins the cap, mirroring the guard
// leaderboard_sql_test.go applies to handleLeaderboard. An edit that changes
// the cap is forced to move the test too. Stdlib only — no new dependency.

import (
	"os"
	"strings"
	"testing"
)

// handleStatuses must cap its result set, or the Crew status feed grows
// without bound and the per-refresh cost balloons as the users table
// accumulates. The single LIMIT literal sits in the one active-status query.
func TestStatusesQueryCapsAtLimit100(t *testing.T) {
	raw, err := os.ReadFile("statuses.go")
	if err != nil {
		t.Fatalf("read statuses.go: %v", err)
	}
	src := string(raw)
	if got := strings.Count(src, "LIMIT 100"); got != 1 {
		t.Fatalf("statuses.go contains LIMIT 100 %d times, want exactly 1 (the active-status query)", got)
	}
}
