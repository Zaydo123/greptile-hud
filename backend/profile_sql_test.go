package main

// Lockstep coverage for the SQL statements in profile.go — the last unpinned
// SQL surface in the backend (every other handler is guarded by its own
// *_sql_test.go, e.g. leaderboard_sql_test.go, status_history_sql_test.go,
// devtime_sql_test.go). These are inline literals, so they can drift silently
// with no compiler error; the profile endpoints must not trust by hand:
//
//   - devtimeByDay feeds the /api/user daily devtime series. It must stay
//     scoped to the user, keep the half-open day window [start, end) (the same
//     semantics devtime_sql_test.go pins for db.go) so period sums never
//     double-count or drop a boundary day, and bind its window to
//     window.dateKey()/window.endDateKey() — a swapped argument silently
//     shifts every series by one day.
//   - activitySpans loads status_history for /api/user's per-emoji breakdown.
//     The base select must stay scoped to the user and the overlap filter
//     (AND started_at < end AND ended_at > start) may only be appended for a
//     bounded period — the "all" period must keep the bare user-scoped query
//     or the all-time breakdown starts dropping rows. $2 and $3 bind to
//     window.End and window.Start respectively; reversing them inverts the
//     half-open overlap. The live running status must come from the users
//     table and tolerate a missing row (sql.ErrNoRows).
//   - userAvatarURL reads the profile-photo version and treats no row as "no
//     avatar" rather than a 500.
//
// These tests read the actual query text back out of profile.go and pin each
// property, mirroring the sibling *_sql_test.go guards. Stdlib only — no new
// dependency.

import (
	"os"
	"strings"
	"testing"
)

func profileSource(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile("profile.go")
	if err != nil {
		t.Fatalf("read profile.go: %v", err)
	}
	return string(raw)
}

// devtimeByDay feeds the dense daily series, so it must read per-day seconds
// keyed by YYYY-MM-DD, scoped to one user.
func TestDevtimeByDayIsUserScopedPerDay(t *testing.T) {
	src := profileSource(t)

	// The daily series is keyed by calendar date (not a raw timestamp), and
	// must stay one row per user/day.
	if got := strings.Count(src, "SELECT to_char(day, 'YYYY-MM-DD'), seconds"); got != 1 {
		t.Fatalf("profile.go contains %q %d times, want exactly 1 (the daily-series select)", "SELECT to_char(day, 'YYYY-MM-DD'), seconds", got)
	}
	if got := strings.Count(src, "WHERE user_id = $1 AND day >= $2::date AND day < $3::date"); got != 1 {
		t.Fatalf("profile.go contains the user-scoped half-open window %d times, want exactly 1", got)
	}
}

// The window must stay half-open (day >= start AND day < end), matching the
// devtimeForPeriod semantics pinned in devtime_sql_test.go — a closed upper
// bound double-counts the boundary day, and args must bind start then end.
func TestDevtimeByDayWindowIsHalfOpenAndBoundInOrder(t *testing.T) {
	src := profileSource(t)

	// The dateKey()/endDateKey() pair is what keeps the window half-open; a
	// swap silently shifts the whole series by one day.
	if got := strings.Count(src, "window.dateKey(), window.endDateKey()"); got != 1 {
		t.Fatalf("profile.go contains %q %d times, want exactly 1 (window bound start then end)", "window.dateKey(), window.endDateKey()", got)
	}
	// A closed upper bound would double-count the last day of every series.
	if strings.Contains(src, "day <= $3::date") {
		t.Fatal("devtimeByDay window must stay half-open (day < upper), never closed (day <=)")
	}
}

// activitySpans must load status_history scoped to the user and end every
// variant on the (started_at, id) tie-break so per-emoji aggregation order is
// stable across polls.
func TestActivitySpansIsUserScopedAndOrdered(t *testing.T) {
	src := profileSource(t)

	if got := strings.Count(src, "SELECT emoji, started_at, ended_at"); got != 1 {
		t.Fatalf("profile.go contains %q %d times, want exactly 1 (the history select)", "SELECT emoji, started_at, ended_at", got)
	}
	if !strings.Contains(src, "FROM status_history") {
		t.Fatal("activitySpans must read status_history for the per-emoji breakdown")
	}
	if got := strings.Count(src, "ORDER BY started_at, id"); got != 1 {
		t.Fatalf("profile.go contains %q %d times, want exactly 1 (stable span ordering)", "ORDER BY started_at, id", got)
	}
}

// The overlap filter must only apply to a bounded period; the "all" period
// must keep the bare user-scoped select, or the all-time breakdown truncates.
// And $2/$3 bind to window.End/window.Start — reversed, the half-open overlap
// inverts and drops every span.
func TestActivitySpansOverlapGatedToBoundedPeriodAndBoundInOrder(t *testing.T) {
	src := profileSource(t)

	// The window is appended conditionally, so the bare base select stays
	// reachable for the "all" period.
	if got := strings.Count(src, "AND started_at < $2 AND ended_at > $3"); got != 1 {
		t.Fatalf("profile.go contains the overlap filter %q %d times, want exactly 1", "AND started_at < $2 AND ended_at > $3", got)
	}
	if !strings.Contains(src, "if periodName != periodAll {") {
		t.Fatal("the activitySpans overlap filter must be gated on a bounded period (all must skip it)")
	}
	// Overlap args bind end first then start (the append after the base query).
	if got := strings.Count(src, "window.End, window.Start"); got != 1 {
		t.Fatalf("profile.go must bind the overlap filter to window.End then window.Start, found %d occurrences", got)
	}
}

// The active running status is appended from the users table and a missing
// row must be tolerated (sql.ErrNoRows) rather than failing the whole request.
func TestActivitySpansReadsLiveStatusAndToleratesMissingUser(t *testing.T) {
	src := profileSource(t)

	if got := strings.Count(src, "SELECT status_emoji, status_started_at FROM users WHERE id = $1"); got != 1 {
		t.Fatalf("profile.go contains the live-status read %q %d times, want exactly 1", "SELECT status_emoji, status_started_at FROM users WHERE id = $1", got)
	}
	if !strings.Contains(src, "err != sql.ErrNoRows") {
		t.Fatal("the profile status read must keep tolerating a user with no row (sql.ErrNoRows)")
	}
}

// userAvatarURL reads the photo version and treats "no avatar" as nil, never
// surfacing an ErrNoRows as a 500.
func TestUserAvatarReadsVersionAndToleratesNone(t *testing.T) {
	src := profileSource(t)

	if got := strings.Count(src, "SELECT updated_at FROM avatars WHERE user_id = $1"); got != 1 {
		t.Fatalf("profile.go contains %q %d times, want exactly 1 (the avatar version read)", "SELECT updated_at FROM avatars WHERE user_id = $1", got)
	}
	if !strings.Contains(src, "err == sql.ErrNoRows") {
		t.Fatal("userAvatarURL must keep mapping a missing avatar row to no-avatar (nil)")
	}
}
