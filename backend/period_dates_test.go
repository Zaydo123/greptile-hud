package main

import (
	"reflect"
	"testing"
	"time"
)

// dateKey / endDateKey and addDayPeriod are the wire serializers for the
// calendar-day filters used by the leaderboard and online handlers. Cover those
// so a regression in SQL boundary dates is caught, not just the in-memory
// time.Time periods.

func TestDayPeriodDateKeys(t *testing.T) {
	// Wednesday 2026-08-26, 17:30 Central, matching TestCrewActivityPeriods.
	now := centralTime(2026, time.August, 26, 17, 30)
	tests := []struct {
		name       string
		period     dayPeriod
		wantKey    string
		wantEndKey string
	}{
		{
			name:       "today",
			period:     crewDayPeriod(now),
			wantKey:    "2026-08-26",
			wantEndKey: "2026-08-27",
		},
		{
			name:       "week starts on Monday",
			period:     func() dayPeriod { _, p := crewActivityPeriod(now, periodWeek); return p }(),
			wantKey:    "2026-08-24",
			wantEndKey: "2026-08-31",
		},
		{
			name:       "month starts on the first",
			period:     func() dayPeriod { _, p := crewActivityPeriod(now, periodMonth); return p }(),
			wantKey:    "2026-08-01",
			wantEndKey: "2026-09-01",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.period.dateKey(); got != tt.wantKey {
				t.Fatalf("dateKey() = %q, want %q", got, tt.wantKey)
			}
			if got := tt.period.endDateKey(); got != tt.wantEndKey {
				t.Fatalf("endDateKey() = %q, want %q", got, tt.wantEndKey)
			}
		})
	}
}

func TestAddDayPeriod(t *testing.T) {
	now := centralTime(2026, time.August, 26, 17, 30)
	period := crewDayPeriod(now)

	v := addDayPeriod(map[string]any{"existing": int64(7)}, period)
	if v["existing"] != int64(7) {
		t.Fatalf("addDayPeriod dropped existing key: %v", v)
	}
	if got := v["period_start"]; !reflect.DeepEqual(got, period.Start) {
		t.Fatalf("period_start = %v (%T), want %v", got, got, period.Start)
	}
	if got := v["period_end"]; !reflect.DeepEqual(got, period.End) {
		t.Fatalf("period_end = %v (%T), want %v", got, got, period.End)
	}
	if v["timezone"] != crewDayTimezone {
		t.Fatalf("timezone = %v, want %q", v["timezone"], crewDayTimezone)
	}

	// Wire serialization must be stable YYYY-MM-DD regardless of local offset.
	if got := v["period_start"].(time.Time).Format(time.DateOnly); got != "2026-08-26" {
		t.Fatalf("serialized period_start = %q, want 2026-08-26", got)
	}
}
