package main

// Lockstep coverage for the sprint-list statement built in listSprints. Its
// retention window (interval '90 days') and its period window filter are inline
// SQL literals in sprints.go, so they can drift silently with no compiler
// error — a lost retention filter would let stale rows linger in the sprint
// feed, and a period window that leaked into (or disappeared from) the bounded
// query would misreport sprint history the same way leaderboard_sql_test.go
// guards the leaderboard. recordSprint's retention DELETE, by contrast, binds
// the Go constant sprintRetention via a parameter, so the two sides must agree
// by hand. This test reads the actual query text back out of sprints.go and
// pins both the literal and the relationship to the constant, mirroring the
// guard windows_test.go applies to the constants themselves. Stdlib only — no
// new dependency.

import (
	"os"
	"strings"
	"testing"
)

func sprintSource(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile("sprints.go")
	if err != nil {
		t.Fatalf("read sprints.go: %v", err)
	}
	return string(raw)
}

// listSprints must keep a retention bound on the sprint feed, or dead sprints
// accumulate for every user as the table grows. The literal is spelled inline
// in listSprints; windows_test.go pins the companion sprintRetention constant
// to these same 90 days, so the two halves of the contract must land together.
func TestSprintListRetentionLiteralMatchesConstant(t *testing.T) {
	src := sprintSource(t)

	// The retention filter is a raw interval literal inline in the query.
	if got := strings.Count(src, "interval '90 days'"); got != 1 {
		t.Fatalf("sprints.go contains interval '90 days' %d times, want exactly 1 (the listSprints retention filter)", got)
	}

	// recordSprint's retention DELETE must bind the Go constant via its
	// parameter, never a literal of its own, so a change to sprintRetention
	// can't diverge from the listSprints literal silently.
	if !strings.Contains(src, "DELETE FROM sprints WHERE last_active_at < $1") {
		t.Fatalf("sprints.go is missing the parameterized retention DELETE in recordSprint")
	}
	if !strings.Contains(src, "now.Add(-sprintRetention)") {
		t.Fatalf("recordSprint's retention DELETE must use -sprintRetention, not a literal")
	}
}

// The period window filter must be applied only to bounded periods. listSprints
// appends `AND started_at < $3 AND last_active_at >= $4` when the caller
// requests a bounded period (today/week/month); the "all" query must select
// across every recorded day. A lost filter would silently spill all-time sprint
// history into period views, and one that leaked into "all" would start
// dropping rows — the same invariant leaderboard_sql_test.go pins for the
// leaderboard.
func TestSprintListWindowFilterIsBoundedPeriodOnly(t *testing.T) {
	src := sprintSource(t)

	filter := "AND started_at < $3 AND last_active_at >= $4"
	// The filter is built in exactly one place, guarded by the bounded-period
	// check, so it must appear exactly once in the source.
	if got := strings.Count(src, filter); got != 1 {
		t.Fatalf("sprints.go contains period window filter `%s` %d times, want exactly 1 (the listSprints bounded-period append)", filter, got)
	}

	// The two construction sites must stay coupled: the window guard reads
	// periodAll and the filter references the period.End/period.Start args.
	if !strings.Contains(src, "if periodName != periodAll {") {
		t.Fatalf("sprints.go is missing the `if periodName != periodAll` guard around the period window filter")
	}
	if !strings.Contains(src, "period.End, period.Start") {
		t.Fatalf("listSprints must bind the window filter to period.End and period.Start, in that order")
	}
}
