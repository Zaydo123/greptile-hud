package main

// Lockstep coverage for pulse()'s seed row-read in db.go — the one devtime
// statement still trusted by hand after devtime_sql_test.go pinned the
// aggregate, today, insert, extend and restart statements. This read drives
// the accrual branch decision, and its drift-failure shapes are distinct from
// the ones already pinned:
//
//   - pulse() must read BOTH seconds and last_heartbeat_at, in that column
//     order, into the Scan(&seconds, &lastBeat) targets. classifySprintBeat
//     keys entirely off last_heartbeat_at, so a read that silently drops the
//     beat column (e.g. a "simplification" to the single-column
//     devtimeToday SELECT) would collapse every beat into the sprintExtend
//     path and corrupt focus time with no schema or compile error.
//   - The statement must end at the day bound ($2::date) with no extra
//     window: this is the only devtime read that returns the raw beat
//     timestamp, and it must keep doing so for this user/day pairing alone.
//   - Exactly one pulse row-read must exist. The devtimeAll/devtimeToday/
//     devtimeForPeriod queries all SELECT either a sum or seconds alone, so a
//     second copy-paste of this two-column read elsewhere would be new
//     surface that classifySprintBeat's coverage never sees.
//
// This test reads the actual query text back out of db.go and pins each
// property, mirroring devtime_sql_test.go, leaderboard_sql_test.go,
// sprints_sql_test.go, statuses_sql_test.go and user_sql_test.go. Stdlib
// only — no new dependency.

import (
	"os"
	"strings"
	"testing"
)

func TestPulseSeedReadSelectsSecondsThenBeatClock(t *testing.T) {
	src, err := os.ReadFile("db.go")
	if err != nil {
		t.Fatalf("read db.go: %v", err)
	}
	raw := string(src)

	// The pulse seed read must fetch seconds and last_heartbeat_at in this
	// exact SELECT order, matching Scan(&seconds, &lastBeat) at db.go:108.
	// Pinning the whole statement means a reorder or a dropped column breaks
	// the match instead of silently corrupting the accrual decision.
	const seed = `SELECT seconds, last_heartbeat_at FROM devtime WHERE user_id = $1 AND day = $2::date`
	if got := strings.Count(raw, seed); got != 1 {
		t.Fatalf("db.go contains pulse seed read %q %d times, want exactly 1 (both columns, in Scan order)", seed, got)
	}
}

func TestPulseSeedReadHasNoWindowFilter(t *testing.T) {
	src, err := os.ReadFile("db.go")
	if err != nil {
		t.Fatalf("read db.go: %v", err)
	}
	raw := string(src)

	// The seed read returns the raw beat timestamp for exactly this user and
	// day — its bind args must terminate right after the day bound
	// (userID, day) with no extra window/limit argument. The devtimeAll,
	// devtimeToday, devtimeForPeriod and sprintRestart statements all end
	// their WHERE at $1 or $2 as well, but only the seed read pairs that
	// bound with a two-column SELECT of seconds + last_heartbeat_at, so the
	// combined signature pins the read uniquely and a window argument
	// ($3...) added to it breaks the match.
	const anchored = `seconds, last_heartbeat_at FROM devtime WHERE user_id = $1 AND day = $2::date", userID, day).`
	if got := strings.Count(raw, anchored); got != 1 {
		t.Fatalf("db.go contains seed-read anchor %q %d times, want exactly 1 (no window past the day bound)", anchored, got)
	}
}

func TestPulseSeedReadScanMatchesColumnOrder(t *testing.T) {
	src, err := os.ReadFile("db.go")
	if err != nil {
		t.Fatalf("read db.go: %v", err)
	}
	raw := string(src)

	// The seed read's Scan targets must line up with the SELECT columns:
	// &seconds then &lastBeat. If the scan order were swapped relative to the
	// literal's column order, classifySprintBeat would read the seconds value
	// as the beat clock and treat every beat as a fresh sprint, corrupting
	// focus time with no type error. Pin both halves so they can't drift
	// apart.
	if !strings.Contains(raw, `last_heartbeat_at FROM devtime WHERE user_id = $1`) {
		t.Fatal("db.go pulse seed read must SELECT last_heartbeat_at after seconds in the FROM list")
	}
	if !strings.Contains(raw, `Scan(&seconds, &lastBeat)`) {
		t.Fatal("db.go pulse seed read must Scan(&seconds, &lastBeat) to match column order")
	}
}
