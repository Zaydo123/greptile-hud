package main

import (
	"testing"
	"time"
)

func centralTime(year int, month time.Month, day, hour, minute int) time.Time {
	return time.Date(year, month, day, hour, minute, 0, 0, crewDayLocation)
}

func TestCrewDayPeriodBoundary(t *testing.T) {
	tests := []struct {
		name      string
		now       time.Time
		wantStart time.Time
		wantEnd   time.Time
	}{
		{
			name:      "UTC instant remains on prior Central day",
			now:       time.Date(2026, time.August, 26, 4, 59, 59, 0, time.UTC),
			wantStart: centralTime(2026, time.August, 25, 0, 0),
			wantEnd:   centralTime(2026, time.August, 26, 0, 0),
		},
		{
			name:      "Central midnight starts a new day",
			now:       time.Date(2026, time.August, 26, 5, 0, 0, 0, time.UTC),
			wantStart: centralTime(2026, time.August, 26, 0, 0),
			wantEnd:   centralTime(2026, time.August, 27, 0, 0),
		},
		{
			name:      "spring DST day has calendar-day boundaries",
			now:       centralTime(2026, time.March, 8, 12, 0),
			wantStart: centralTime(2026, time.March, 8, 0, 0),
			wantEnd:   centralTime(2026, time.March, 9, 0, 0),
		},
		{
			name:      "fall DST day has calendar-day boundaries",
			now:       centralTime(2026, time.November, 1, 12, 0),
			wantStart: centralTime(2026, time.November, 1, 0, 0),
			wantEnd:   centralTime(2026, time.November, 2, 0, 0),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := crewDayPeriod(tt.now)
			if !got.Start.Equal(tt.wantStart) || !got.End.Equal(tt.wantEnd) {
				t.Fatalf("crewDayPeriod(%s) = [%s, %s), want [%s, %s)",
					tt.now, got.Start, got.End, tt.wantStart, tt.wantEnd)
			}
		})
	}

	spring := crewDayPeriod(centralTime(2026, time.March, 8, 12, 0))
	if got := spring.End.Sub(spring.Start); got != 23*time.Hour {
		t.Fatalf("spring DST day = %s, want 23h", got)
	}
	fall := crewDayPeriod(centralTime(2026, time.November, 1, 12, 0))
	if got := fall.End.Sub(fall.Start); got != 25*time.Hour {
		t.Fatalf("fall DST day = %s, want 25h", got)
	}
}

func TestCrewActivityPeriods(t *testing.T) {
	now := centralTime(2026, time.August, 26, 17, 30) // Wednesday
	tests := []struct {
		requested string
		wantName  string
		wantStart time.Time
		wantEnd   time.Time
	}{
		{periodToday, periodToday,
			centralTime(2026, time.August, 26, 0, 0),
			centralTime(2026, time.August, 27, 0, 0)},
		{periodWeek, periodWeek,
			centralTime(2026, time.August, 24, 0, 0),
			centralTime(2026, time.August, 31, 0, 0)},
		{periodMonth, periodMonth,
			centralTime(2026, time.August, 1, 0, 0),
			centralTime(2026, time.September, 1, 0, 0)},
		{"unexpected", periodToday,
			centralTime(2026, time.August, 26, 0, 0),
			centralTime(2026, time.August, 27, 0, 0)},
	}

	for _, tt := range tests {
		t.Run(tt.requested, func(t *testing.T) {
			name, got := crewActivityPeriod(now, tt.requested)
			if name != tt.wantName || !got.Start.Equal(tt.wantStart) || !got.End.Equal(tt.wantEnd) {
				t.Fatalf("crewActivityPeriod(%q) = %q [%s, %s), want %q [%s, %s)",
					tt.requested, name, got.Start, got.End, tt.wantName, tt.wantStart, tt.wantEnd)
			}
		})
	}
}
