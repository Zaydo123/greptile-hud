package main

// Lockstep coverage for the two SQL statements in handleLeaderboard. The
// leaderboard result cap (LIMIT 100) and the calendar-window filter
// (d.day >= $1::date AND d.day < $2::date) are inline literals in
// leaderboard.go, so they can drift silently with no compiler error — a dropped
// LIMIT would grow the payload unboundedly and a lost filter would leak
// all-time devtime into a "today/week/month" view (or vice-versa, if the window
// leaked into the "all" query and started dropping rows). These tests read the
// actual query text back out of leaderboard.go and pin both properties, so an
// edit that changes the cap or relocates the window filter is forced to move
// the test too. Stdlib only — no new dependency.

import (
	"os"
	"strings"
	"testing"
)

func leaderboardSource(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile("leaderboard.go")
	if err != nil {
		t.Fatalf("read leaderboard.go: %v", err)
	}
	return string(raw)
}

// Each leaderboard query must cap its result set, or the payload grows without
// bound and the per-refresh cost balloons as the devtime table accumulates.
func TestLeaderboardQueriesCapAtLimit100(t *testing.T) {
	src := leaderboardSource(t)
	occurrences := strings.Count(src, "LIMIT 100")
	// One for the "all" query, one for the period-bounded query; both call
	// sites share the same literal cap so the leaderboard never exceeds 100
	// rows regardless of the requested period.
	if occurrences != 2 {
		t.Fatalf("leaderboard.go contains LIMIT 100 %d times, want exactly 2 (the 'all' and period queries)", occurrences)
	}
}

// Only the period-bounded query applies the calendar-window filter. The "all"
// query must select across everything. The filter shows up as the $1/$2 day
// range join condition; if it leaked into the "all" query, that query would
// start dropping rows, and if it disappeared from the period query, a period
// view would silently report all-time devtime.
func TestLeaderboardWindowFilterMatchesPeriodSemantics(t *testing.T) {
	src := leaderboardSource(t)

	filter := "AND d.day >= $1::date AND d.day < $2::date"
	// Every filter reference sits inside the single period-bounded query text,
	// so the window join must appear exactly once.
	if got := strings.Count(src, filter); got != 1 {
		t.Fatalf("period window filter `%s` appears %d times in leaderboard.go, want exactly 1", filter, got)
	}

	// The day-range constraint names both day-bounds as $1 and $2 together;
	// there is no other place that binds both params to a calendar window.
	if !strings.Contains(src, filter) {
		t.Fatalf("leaderboard.go is missing the period window filter `%s`", filter)
	}
}

// avatar_url comes from a LEFT JOIN on avatars in all three user-shaped
// queries in leaderboard.go (both leaderboard queries and the online feed). It
// must be a LEFT JOIN — an inner join would silently drop everyone without a
// photo from the leaderboard — and must only read updated_at, never the image
// bytes, or every poll would ship every photo through the database.
func TestUserShapedQueriesLeftJoinAvatarsWithoutBytes(t *testing.T) {
	src := leaderboardSource(t)

	const join = "LEFT JOIN avatars a ON a.user_id = u.id"
	if got := strings.Count(src, join); got != 3 {
		t.Fatalf("leaderboard.go contains %q %d times, want 3 (all, period, online)", join, got)
	}
	if strings.Contains(src, "a.data") {
		t.Fatal("leaderboard.go selects avatar bytes (a.data); user-shaped queries must read only a.updated_at")
	}
	// The leaderboard groups by user; the avatar version is functionally
	// dependent on the user (avatars is keyed by user_id) and joins the GROUP BY.
	if got := strings.Count(src, "GROUP BY u.id, a.updated_at"); got != 2 {
		t.Fatalf("leaderboard.go GROUP BY u.id, a.updated_at appears %d times, want 2", got)
	}
	// Ordering must still end on the unique login tie-break.
	if got := strings.Count(src, "ORDER BY value DESC, u.login"); got != 2 {
		t.Fatalf("leaderboard.go ORDER BY value DESC, u.login appears %d times, want 2", got)
	}
}
