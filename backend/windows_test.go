package main

// The online window and sprint retention are expressed twice: as the Go
// duration constants onlineWindow / sprintRetention that drive the presence
// and sprint logic, and again as SQL interval literals baked into the queries
// in leaderboard.go (handleOnline: `interval '5 minutes'`) and sprints.go
// (listSprints: `interval '90 days'`). PostgreSQL cannot read a Go constant,
// so the two must agree by hand. These tests pin each constant to the value
// its SQL counterpart spells out, so a future edit that drifts one side is
// forced to notice the other — the same lockstep guard heartbeat_test.go
// applies to the pulse/sprint coupling.

import (
	"testing"
	"time"
)

func TestOnlineWindowMatchesSQL(t *testing.T) {
	// handleOnline filters `last_seen > now() - interval '5 minutes'`.
	if onlineWindow != 5*time.Minute {
		t.Fatalf("onlineWindow = %s, but handleOnline SQL reads 'interval 5 minutes'", onlineWindow)
	}
}

func TestSprintRetentionMatchesSQL(t *testing.T) {
	// listSprints returns rows with `last_active_at >= now() - interval '90 days'`.
	if sprintRetention != 90*24*time.Hour {
		t.Fatalf("sprintRetention = %s, but listSprints SQL reads 'interval 90 days'", sprintRetention)
	}
}

func TestSprintActiveBeatUsesOnlineWindow(t *testing.T) {
	// listSprints marks a run Active when `last_active_at > now() - interval
	// '5 minutes'` — the same presence window as the online feed. The Go side
	// of that reuse is the onlineWindow constant (sprintIdleGap governs the
	// *accrual* gap, a separate idea); keep them distinct.
	if onlineWindow != 5*time.Minute {
		t.Fatalf("onlineWindow = %s, but listSprints Active beat reads 'interval 5 minutes'", onlineWindow)
	}
	if sprintIdleGap == onlineWindow {
		t.Fatalf("sprintIdleGap (%s) collides with onlineWindow (%s); the sprint list's Active beat must keep using onlineWindow", sprintIdleGap, onlineWindow)
	}
}
