package main

import (
	"testing"
	"time"
)

func TestUTCDayPeriodBoundary(t *testing.T) {
	tests := []struct {
		name      string
		now       time.Time
		wantStart time.Time
		wantEnd   time.Time
	}{
		{
			name:      "immediately before midnight",
			now:       time.Date(2026, time.August, 25, 23, 59, 59, 999999999, time.UTC),
			wantStart: time.Date(2026, time.August, 25, 0, 0, 0, 0, time.UTC),
			wantEnd:   time.Date(2026, time.August, 26, 0, 0, 0, 0, time.UTC),
		},
		{
			name:      "exactly at midnight",
			now:       time.Date(2026, time.August, 26, 0, 0, 0, 0, time.UTC),
			wantStart: time.Date(2026, time.August, 26, 0, 0, 0, 0, time.UTC),
			wantEnd:   time.Date(2026, time.August, 27, 0, 0, 0, 0, time.UTC),
		},
		{
			name:      "non-UTC input",
			now:       time.Date(2026, time.August, 25, 20, 0, 0, 0, time.FixedZone("CDT", -5*60*60)),
			wantStart: time.Date(2026, time.August, 26, 0, 0, 0, 0, time.UTC),
			wantEnd:   time.Date(2026, time.August, 27, 0, 0, 0, 0, time.UTC),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := utcDayPeriod(tt.now)
			if !got.Start.Equal(tt.wantStart) || !got.End.Equal(tt.wantEnd) {
				t.Fatalf("utcDayPeriod(%s) = [%s, %s), want [%s, %s)",
					tt.now, got.Start, got.End, tt.wantStart, tt.wantEnd)
			}
		})
	}
}

func TestUTCActivityPeriods(t *testing.T) {
	now := time.Date(2026, time.August, 26, 17, 30, 0, 0, time.UTC) // Wednesday
	tests := []struct {
		requested string
		wantName  string
		wantStart time.Time
		wantEnd   time.Time
	}{
		{periodToday, periodToday,
			time.Date(2026, time.August, 26, 0, 0, 0, 0, time.UTC),
			time.Date(2026, time.August, 27, 0, 0, 0, 0, time.UTC)},
		{periodWeek, periodWeek,
			time.Date(2026, time.August, 24, 0, 0, 0, 0, time.UTC),
			time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)},
		{periodMonth, periodMonth,
			time.Date(2026, time.August, 1, 0, 0, 0, 0, time.UTC),
			time.Date(2026, time.September, 1, 0, 0, 0, 0, time.UTC)},
		{"unexpected", periodToday,
			time.Date(2026, time.August, 26, 0, 0, 0, 0, time.UTC),
			time.Date(2026, time.August, 27, 0, 0, 0, 0, time.UTC)},
	}

	for _, tt := range tests {
		t.Run(tt.requested, func(t *testing.T) {
			name, got := utcActivityPeriod(now, tt.requested)
			if name != tt.wantName || !got.Start.Equal(tt.wantStart) || !got.End.Equal(tt.wantEnd) {
				t.Fatalf("utcActivityPeriod(%q) = %q [%s, %s), want %q [%s, %s)",
					tt.requested, name, got.Start, got.End, tt.wantName, tt.wantStart, tt.wantEnd)
			}
		})
	}
}
