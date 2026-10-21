package main

// Year-boundary coverage for the calendar-window helpers in period.go. The
// existing tables in period_test.go only exercise dates inside a single
// calendar year (all August 2026), so a regression in the month/week windows —
// a naive rewrite that computes the next month as Start.AddDate(0, 0, 30) or
// forgets the weekday offset crosses a year — would sail through with January
// still rolling to January, i.e. the very code working when 2026-12 + 1 month
// must become 2027-01. These tests pin the rollover explicitly, mirroring the
// DST-day care TestCrewDayPeriodBoundary already takes:
//
//   - the "month" window computed from a late-December day must end on
//     January 1 of the NEXT year (a 31-day month, not a 30-day one);
//   - a leap-year February must span 29 days (and a plain one 28), the days
//     where a "30 days in a month" approximation breaks;
//   - the "week" window computed from a Wednesday that falls on 2026-12-30 must
//     start on the prior Monday, which is still in 2026, and end on a Monday
//     in 2027;
//   - the day-window string keys must roll their year digit too ("2026-12-31"
//     ends with endDateKey "2027-01-01"), not wrap to a same-year date.
//
// Stdlib only — no new dependency.

import (
	"testing"
	"time"
)

func TestCrewDayPeriodYearRollover(t *testing.T) {
	// 2027-01-01 06:00:00Z is midnight Central on New Year's Day: the crew day
	// that starts in America/Chicago strips one calendar year late must roll
	// into 2027, not wrap back to 2026-12-31.
	now := time.Date(2027, time.January, 1, 6, 0, 0, 0, time.UTC)
	got := crewDayPeriod(now)
	wantStart := centralTime(2027, time.January, 1, 0, 0)
	wantEnd := centralTime(2027, time.January, 2, 0, 0)
	if !got.Start.Equal(wantStart) || !got.End.Equal(wantEnd) {
		t.Fatalf("crewDayPeriod(%s) = [%s, %s), want [%s, %s)",
			now, got.Start, got.End, wantStart, wantEnd)
	}
}

func TestMonthWindowCrossesYearBoundary(t *testing.T) {
	// 2026-12-30 12:00 Central (a Wednesday). The month window must start
	// 2026-12-01 and END on 2027-01-01 — a 31-day month. A rewrite that
	// approximates next-month as +30 days produces 2026-12-31 and must fail
	// here.
	now := centralTime(2026, time.December, 30, 12, 0)
	name, got := crewActivityPeriod(now, periodMonth)
	wantStart := centralTime(2026, time.December, 1, 0, 0)
	wantEnd := centralTime(2027, time.January, 1, 0, 0)
	if name != periodMonth || !got.Start.Equal(wantStart) || !got.End.Equal(wantEnd) {
		t.Fatalf("crewActivityPeriod(2026-12-30, month) = %q [%s, %s), want %q [2026-12-01, 2027-01-01)",
			name, got.Start, got.End, periodMonth)
	}
}

func TestMonthWindowLeapFebruary(t *testing.T) {
	// 2024-02-14 12:00 Central (a Wednesday). A leap-year February is the
	// month where a fixed "+30 days" or "+28 days" approximation breaks: the
	// window must be the full 29 days and end on 2024-03-01.
	now := centralTime(2024, time.February, 14, 12, 0)
	_, got := crewActivityPeriod(now, periodMonth)
	wantStart := centralTime(2024, time.February, 1, 0, 0)
	wantEnd := centralTime(2024, time.March, 1, 0, 0)
	if !got.Start.Equal(wantStart) || !got.End.Equal(wantEnd) {
		t.Fatalf("leap February window = [%s, %s), want [2024-02-01, 2024-03-01)",
			got.Start, got.End)
	}
	if days := got.End.Sub(got.Start); days != 29*24*time.Hour {
		t.Fatalf("leap February window spans %s, want 29 days", days)
	}
}

func TestMonthWindowPlainFebruary(t *testing.T) {
	// 2026-02-14 12:00 Central is a Saturday; use it to pin the 28-day
	// non-leap February so the adjacent leap test has a contrast.
	now := centralTime(2026, time.February, 14, 12, 0)
	_, got := crewActivityPeriod(now, periodMonth)
	wantStart := centralTime(2026, time.February, 1, 0, 0)
	wantEnd := centralTime(2026, time.March, 1, 0, 0)
	if !got.Start.Equal(wantStart) || !got.End.Equal(wantEnd) {
		t.Fatalf("plain February window = [%s, %s), want [2026-02-01, 2026-03-01)",
			got.Start, got.End)
	}
	if days := got.End.Sub(got.Start); days != 28*24*time.Hour {
		t.Fatalf("plain February window spans %s, want 28 days", days)
	}
}

func TestWeekWindowCrossesYearBoundary(t *testing.T) {
	// 2026-12-30 is a Wednesday (weekday 3), so the week window walks back 2
	// days to Monday 2026-12-28 and runs to Monday 2027-01-04 — both the start
	// and the end straddle the year line.
	now := centralTime(2026, time.December, 30, 12, 0)
	name, got := crewActivityPeriod(now, periodWeek)
	wantStart := centralTime(2026, time.December, 28, 0, 0)
	wantEnd := centralTime(2027, time.January, 4, 0, 0)
	if name != periodWeek || !got.Start.Equal(wantStart) || !got.End.Equal(wantEnd) {
		t.Fatalf("crewActivityPeriod(2026-12-30, week) = %q [%s, %s), want %q [2026-12-28, 2027-01-04)",
			name, got.Start, got.End, periodWeek)
	}
}

func TestDayPeriodKeysRollYear(t *testing.T) {
	// The SQL day range for New Year's Eve must serialize as 2026-12-31 →
	// 2027-01-01, not wrap the year digit back to 2026.
	now := centralTime(2026, time.December, 31, 6, 0)
	day := crewDayPeriod(now)
	if key := day.dateKey(); key != "2026-12-31" {
		t.Fatalf("dateKey() = %q, want 2026-12-31", key)
	}
	if key := day.endDateKey(); key != "2027-01-01" {
		t.Fatalf("endDateKey() = %q, want 2027-01-01", key)
	}
}
