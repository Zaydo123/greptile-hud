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
