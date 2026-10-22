package main

// Lockstep coverage for the devtime statements in db.go — the one SQL surface
// this package still trusted by hand. The leaderboard, statuses and sprint
// queries are all pinned by their own *_sql_test.go guards so a drifted
// literal fails CI; the devtime queries power /api/user's stats card (today /
// week / month / all-time sums) and pulse()'s accrual, and a silent drift
// breaks them differently:
//
//   - devtimeForPeriod computes stats-card totals for a bounded period. Its
//     window must stay half-open (day >= start AND day < end) to match the
//     leaderboard's day-range semantics, or the boundary day double-counts
//     (or, with strict inequality both sides, vanishes) from period sums.
//   - devtimeAll selects every recorded day for the "all" card. A window
//     filter sneaking in here silently truncates all-time devtime — the same
//     leak leaderboard_sql_test.go pins for the leaderboard.
//   - Both aggregate queries must keep COALESCE(SUM(seconds), 0): without it,
//     a user with no devtime rows scans SQL NULL into an int64 and /api/user
//     500s instead of returning 0.
//   - pulse() accrues beats through classifySprintBeat (see heartbeat_test.go);
//     its sprintExtend branch must ADD to seconds (never overwrite) and its
//     sprintRestart branch must leave seconds alone, or focus time and the
//     sprint stopwatch disagree on the same heartbeat stream.
//
// These tests read the actual query text back out of db.go and pin each
// property, mirroring leaderboard_sql_test.go and sprints_sql_test.go. Stdlib
// only — no new dependency.

import (
	"os"
	"strings"
	"testing"
)

func dbSource(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile("db.go")
	if err != nil {
		t.Fatalf("read db.go: %v", err)
	}
	return string(raw)
}

func TestDevtimeAllQueryHasNoDayWindow(t *testing.T) {
	src := dbSource(t)

	// devtimeAll must select across every recorded day: the statement ends at
	// the user_id filter, with no day bound. The exact string (closing quote
	// included) only matches this statement — pulse's row read and the other
	// queries all continue past $1 — so a window filter sneaking in here
	// breaks the match.
	const exact = `"SELECT COALESCE(SUM(seconds), 0) FROM devtime WHERE user_id = $1"`
	if got := strings.Count(src, exact); got != 1 {
		t.Fatalf("db.go contains devtimeAll statement %q %d times, want exactly 1 (and no day filter)", exact, got)
	}
}

func TestDevtimePeriodWindowIsHalfOpenAndCoalesced(t *testing.T) {
	src := dbSource(t)

	// The bounded-period window is half-open: start day included, end day
	// excluded — the same [start, end) semantics the leaderboard period query
	// uses, so replacing devtime with the leaderboard SQL can't drift the
	// boundary-day treatment apart.
	window := "day >= $2::date AND day < $3::date"
	if got := strings.Count(src, window); got != 1 {
		t.Fatalf("db.go contains devtimeForPeriod window `%s` %d times, want exactly 1", window, got)
	}

	// Both aggregate queries (devtimeAll and devtimeForPeriod) coalesce the
	// sum, so a user with no rows scans 0 instead of NULL.
	if got := strings.Count(src, "COALESCE(SUM(seconds), 0)"); got != 2 {
		t.Fatalf("db.go contains COALESCE(SUM(seconds), 0) %d times, want exactly 2 (devtimeAll and devtimeForPeriod)", got)
	}

	// The window args must bind start then end, via dateKey/endDateKey — an
	// accidental swap silently shifts every period total by one day.
	if !strings.Contains(src, "userID, period.dateKey(), period.endDateKey()") {
		t.Fatalf("devtimeForPeriod must bind its window to period.dateKey() then period.endDateKey()")
	}
}

func TestDevtimeTodayUsesExactDayEquality(t *testing.T) {
	src := dbSource(t)

	// The "today" card sums exactly one day: day = $2::date. A drift to a
	// range would fold adjacent days into the today total (or drop the day
	// entirely at the boundary).
	const exact = `"SELECT seconds FROM devtime WHERE user_id = $1 AND day = $2::date"`
	if got := strings.Count(src, exact); got != 1 {
		t.Fatalf("db.go contains devtimeToday statement %q %d times, want exactly 1", exact, got)
	}
}

func TestPulseNewDaySeedsZero(t *testing.T) {
	src := dbSource(t)

	// A first beat of the day inserts with 0 seconds accumulated; the accrual
	// only ever flows through the sprintExtend branch below. Seeding from an
	// existing value would double-count every new-day restart.
	const insert = `INSERT INTO devtime (user_id, day, seconds, last_heartbeat_at) VALUES ($1, $2::date, 0, $3)`
	if got := strings.Count(src, insert); got != 1 {
		t.Fatalf("db.go contains the new-day INSERT %d times, want exactly 1 (seeding seconds at 0)", got)
	}
}

func TestPulseExtendAccruesNotOverwrites(t *testing.T) {
	src := dbSource(t)

	// sprintExtend must ADD the accrued gap to the stored seconds. An
	// overwrite (seconds = $2) would throw away everything accrued before the
	// current beat — the lockstep half of heartbeat_test.go's
	// TestPulseBranchesAlignWithClassify.
	if got := strings.Count(src, "seconds = seconds + $2"); got != 1 {
		t.Fatalf("db.go contains seconds = seconds + $2 %d times, want exactly 1 (the sprintExtend accrual)", got)
	}
}

func TestPulseRestartLeavesSecondsUntouched(t *testing.T) {
	src := dbSource(t)

	// sprintRestart only refreshes the heartbeat timer: it must not reference
	// seconds at all (a beat after the 10m idle gap resets the timer without
	// accruing — see classifySprintBeat). Pinning the full statement means a
	// seconds assignment can't be added to it unnoticed.
	const restart = `UPDATE devtime SET last_heartbeat_at = $3 WHERE user_id = $1 AND day = $2::date`
	if got := strings.Count(src, restart); got != 1 {
		t.Fatalf("db.go contains the sprintRestart UPDATE %d times, want exactly 1 (heartbeat refresh, no seconds write)", got)
	}
}
