package main

// Lockstep coverage for the handleOnline presence filter in leaderboard.go.
// windows_test.go pins the Go constant onlineWindow to 5 minutes, but it only
// checks the constant — it never verifies that the handleOnline query actually
// carries its matching `interval '5 minutes'` literal. The sprints retention
// filter gets this same treatment in sprints_sql_test.go ("interval '90 days'"),
// so handleOnline is the one presence window left unpinned. A dropped or
// drifted filter here would silently turn the online feed into a list of every
// user who ever sent a beat, ballooning the per-refresh payload and drowning
// the real currently-online crew — with no schema or compiler error. This test
// reads the actual query text back out of leaderboard.go and pins the filter
// to the onlineWindow constant it must mirror, mirroring the guards
// leaderboard_sql_test.go and sprints_sql_test.go apply. Stdlib only — no new
// dependency.

import (
	"os"
	"strings"
	"testing"
)

// handleOnline's WHERE clause must keep the 5-minute presence bound. The
// filter is spelled as an inline interval literal in the single query text, so
// it must appear exactly once in leaderboard.go.
func TestHandleOnlineFiltersByOnlineWindow(t *testing.T) {
	raw, err := os.ReadFile("leaderboard.go")
	if err != nil {
		t.Fatalf("read leaderboard.go: %v", err)
	}
	src := string(raw)

	// users is aliased u because the online query LEFT JOINs avatars.
	const filter = "u.last_seen > now() - interval '5 minutes'"
	if got := strings.Count(src, filter); got != 1 {
		t.Fatalf("leaderboard.go contains handleOnline filter %q %d times, want exactly 1 (the online query's WHERE bound)", filter, got)
	}
}

// The online feed is ordered newest beat first with a unique login tie-break,
// so two users who beat in the same instant can't swap places between polls.
func TestHandleOnlineOrderingHasUniqueTieBreak(t *testing.T) {
	raw, err := os.ReadFile("leaderboard.go")
	if err != nil {
		t.Fatalf("read leaderboard.go: %v", err)
	}
	const order = "ORDER BY u.last_seen DESC, u.login"
	if got := strings.Count(string(raw), order); got != 1 {
		t.Fatalf("leaderboard.go contains %q %d times, want exactly 1 (the online query)", order, got)
	}
}
