package main

// Lockstep coverage for the active-status filter in handleStatuses
// (statuses.go). The Crew feed must list every explicitly running status —
// including people who fell out of the five-minute online window — and must
// never surface users who never set one. That contract lives entirely in the
// inline WHERE clause `status_started_at IS NOT NULL`, so it can drift
// silently with no compiler error:
//
//   - a dropped filter would flood the feed with every user row ever created,
//     most carrying empty emoji/message, and the HUD Crew tab would fill with
//     blank status rows;
//   - a filter that pinned the feed to the presence window instead (a
//     `last_seen` bound) would make explicitly running but away crew vanish —
//     AGENTS.md is explicit that presence and a running status are separate
//     states, and statuses_sql_test.go pins the LIMIT and the mutations while
//     this test pins the filter itself.
//
// It reads the actual query text back out of statuses.go, exactly like
// statuses_sql_test.go. Stdlib only — no new dependency.

import (
	"strings"
	"testing"
)

// handleStatuses' WHERE clause must keep the active-only status filter: the
// feed lists explicitly running statuses, never every user in the table. The
// literal must appear exactly once — in the single feed query — so a dropped
// or duplicated filter fails CI.
func TestStatusesFeedFiltersToActiveOnly(t *testing.T) {
	src := statusSource(t)

	const active = "WHERE status_started_at IS NOT NULL"
	if got := strings.Count(src, active); got != 1 {
		t.Fatalf("statuses.go contains %q %d times, want exactly 1 (the handleStatuses feed filter)", active, got)
	}
}

// The Crew feed must stay presence-independent: a running status remains
// visible after its owner falls out of the five-minute online window — that is
// the documented point of handleStatuses vs the handleOnline feed. A presence
// bound sneaking into statuses.go would drop away-but-running crew rows with
// no schema or compiler error, so pin the literal's absence in this file.
func TestStatusesFeedHasNoPresenceFilter(t *testing.T) {
	src := statusSource(t)

	const presence = "interval '5 minutes'"
	if got := strings.Count(src, presence); got != 0 {
		t.Fatalf("statuses.go contains the presence window %q %d times, want 0 — the status feed must not be presence-bounded (presence and a running status are separate states)", presence, got)
	}
}
