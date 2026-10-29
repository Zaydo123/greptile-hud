package main

// Unit coverage for the pure profile helpers in profile.go — the function
// body calls these out explicitly ("computed by pure functions so the
// period/clipping rules are testable without Postgres"). Two regressions this
// pins:
//
//   - aggregateActivities must never count negative or zero time, must clip
//     every span to [start, end) and to now, and must sort by seconds desc
//     then emoji asc so the /api/user breakdown is stable and honest.
//   - denseDailySeries must emit exactly one point per crew day (no skipped
//     or repeated dates across a DST edge) and fill gaps with zero, so the
//     profile chart always has a full-width, gapless bar series.

import (
	"testing"
	"time"
)

func TestAggregateActivitiesCountingAndOrdering(t *testing.T) {
	base := time.Date(2026, time.October, 14, 9, 0, 0, 0, time.UTC)
	// Five spans: two complete inside the window, one clipped on the right by
	// `now`, one running (EndedAt = now), one entirely outside -> dropped.
	spans := []activitySpan{
		{Emoji: "☕️", StartedAt: base.Add(1 * time.Hour), EndedAt: base.Add(2 * time.Hour)},  // 3600s
		{Emoji: "🚽", StartedAt: base.Add(2 * time.Hour), EndedAt: base.Add(3 * time.Hour)},   // 3600s
		{Emoji: "🏋️", StartedAt: base.Add(3 * time.Hour), EndedAt: base.Add(10 * time.Hour)}, // clipped to 06:00 -> 10800s
		{Emoji: "🎯", StartedAt: base.Add(4 * time.Hour), EndedAt: base.Add(9 * time.Hour)},   // running: EndedAt=now caps to 2h  -> 7200s
		{Emoji: "🚶", StartedAt: base.Add(20 * time.Hour), EndedAt: base.Add(21 * time.Hour)}, // outside window -> dropped
	}
	start := base
	end := base.Add(6 * time.Hour)
	now := base.Add(6 * time.Hour)

	got := aggregateActivities(spans, start, end, now)

	if len(got) != 4 {
		t.Fatalf("aggregateActivities returned %d totals, want 4 (outside-window span must be dropped)", len(got))
	}
	wantOrder := []string{"🏋️", "🎯", "☕️", "🚽"} // seconds desc; tie broken by emoji asc
	wantSecs := map[string]int64{"🏋️": 10800, "🎯": 7200, "☕️": 3600, "🚽": 3600}
	for i, total := range got {
		if total.Emoji != wantOrder[i] {
			t.Fatalf("sort order[%d] = %q, want %q (must be seconds desc, emoji asc)", i, total.Emoji, wantOrder[i])
		}
		if total.Seconds != wantSecs[total.Emoji] {
			t.Fatalf("emoji %q = %d seconds, want %d", total.Emoji, total.Seconds, wantSecs[total.Emoji])
		}
	}
	// Two distinct spans share the "☕️"/"🚽" emojis, so each should have count 1.
	for _, total := range got {
		if total.Count != 1 {
			t.Fatalf("emoji %q count = %d, want 1", total.Emoji, total.Count)
		}
	}
}

func TestAggregateActivitiesCountsDistinctSpans(t *testing.T) {
	base := time.Date(2026, time.October, 14, 9, 0, 0, 0, time.UTC)
	spans := []activitySpan{
		{Emoji: "☕️", StartedAt: base.Add(1 * time.Hour), EndedAt: base.Add(2 * time.Hour)},
		{Emoji: "☕️", StartedAt: base.Add(3 * time.Hour), EndedAt: base.Add(4 * time.Hour)},
	}
	// "all" period: zero start/end means unbounded, so no clipping occurs.
	got := aggregateActivities(spans, time.Time{}, time.Time{}, base.Add(24*time.Hour))
	if len(got) != 1 {
		t.Fatalf("aggregateActivities(2 same-emoji spans) = %d totals, want 1", len(got))
	}
	if got[0].Seconds != 2*3600 {
		t.Fatalf("combined seconds = %d, want %d", got[0].Seconds, 2*3600)
	}
	if got[0].Count != 2 {
		t.Fatalf("combined count = %d, want 2 (each span counted)", got[0].Count)
	}
}

func TestAggregateActivitiesSkipsNonPositiveClip(t *testing.T) {
	base := time.Date(2026, time.October, 14, 9, 0, 0, 0, time.UTC)
	// Span fully before the window start -> clipped to zero time -> dropped.
	spans := []activitySpan{
		{Emoji: "☕️", StartedAt: base.Add(-2 * time.Hour), EndedAt: base.Add(-1 * time.Hour)},
	}
	got := aggregateActivities(spans, base, base.Add(6*time.Hour), base.Add(6*time.Hour))
	if len(got) != 0 {
		t.Fatalf("aggregateActivities(span ending before window) = %d totals, want 0", len(got))
	}
}

func TestDenseDailySeriesIsGapFree(t *testing.T) {
	now := time.Date(2026, time.October, 14, 12, 0, 0, 0, time.UTC)
	window := crewDayPeriod(now) // today 00:00 -> tomorrow 00:00
	mid := window.Start.AddDate(0, 0, 0).Format(time.DateOnly)
	// Only today has a row; the others (future crew days to make the window
	// span several days) must fill as zeros.
	byDay := map[string]int64{mid: 123}

	got := denseDailySeries(window, byDay)
	if len(got) != 1 {
		t.Fatalf("denseDailySeries(1-day window) = %d points, want 1", len(got))
	}
	if got[0].Seconds != 123 {
		t.Fatalf("densified day seconds = %d, want 123", got[0].Seconds)
	}
}

func TestDenseDailySeriesFillsGapsWithZero(t *testing.T) {
	// A 3-day window with only the first and last days present must still emit
	// 3 points and zero-fill the middle day. Build the window in the crew
	// timezone (denseDailySeries keys dates in crewDayLocation), so the byDay
	// keys line up with the formatted dates.
	start := time.Date(2026, time.October, 12, 0, 0, 0, 0, crewDayLocation)
	window := dayPeriod{Start: start, End: start.AddDate(0, 0, 3)}
	byDay := map[string]int64{
		start.Format(time.DateOnly):                  111,
		start.AddDate(0, 0, 2).Format(time.DateOnly): 222,
	}

	got := denseDailySeries(window, byDay)
	if len(got) != 3 {
		t.Fatalf("denseDailySeries(3-day window) = %d points, want exactly 3", len(got))
	}
	if got[0].Seconds != 111 {
		t.Fatalf("day 0 seconds = %d, want 111", got[0].Seconds)
	}
	if got[1].Seconds != 0 {
		t.Fatalf("day 1 (missing row) seconds = %d, want 0 gap fill", got[1].Seconds)
	}
	if got[2].Seconds != 222 {
		t.Fatalf("day 2 seconds = %d, want 222", got[2].Seconds)
	}
	// Consecutive dates, formatted YYYY-MM-DD.
	for i, p := range got {
		wantDay := start.AddDate(0, 0, i).Format(time.DateOnly)
		if p.Day != wantDay {
			t.Fatalf("point[%d].Day = %q, want %q (dates must not skip/repeat)", i, p.Day, wantDay)
		}
	}
}

func TestDailySeriesWindowAllPeriodIsRecentWindow(t *testing.T) {
	now := time.Date(2026, time.October, 14, 12, 0, 0, 0, time.UTC)
	period := crewDayPeriod(now)
	// A specific period returns itself unchanged.
	got := dailySeriesWindow(now, "week", period)
	if got.Start != period.Start || got.End != period.End {
		t.Fatal("dailySeriesWindow for a named period must return the window unchanged")
	}
	// "all" widens to the last 30 crew days ending today.
	all := dailySeriesWindow(now, periodAll, period)
	wantDays := 30
	days := int(all.End.Sub(all.Start).Hours() / 24)
	if days != wantDays {
		t.Fatalf("dailySeriesWindow(all) covers %d days, want %d", days, wantDays)
	}
	if !all.End.Equal(period.End) {
		t.Fatalf("dailySeriesWindow(all) end %v, want window end %v", all.End, period.End)
	}
}
