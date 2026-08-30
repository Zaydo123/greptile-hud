package main

import (
	"testing"
	"time"
)

func TestClassifySprintBeat(t *testing.T) {
	last := time.Date(2026, time.August, 25, 14, 0, 0, 0, time.UTC)
	tests := []struct {
		name        string
		gap         time.Duration
		wantAction  sprintAction
		wantAccrued int64
	}{
		{name: "ignore rapid beat", gap: 29 * time.Second, wantAction: sprintIgnore},
		{name: "extend at minimum", gap: 30 * time.Second, wantAction: sprintExtend, wantAccrued: 30},
		{name: "extend at idle boundary", gap: 10 * time.Minute, wantAction: sprintExtend, wantAccrued: 600},
		{name: "restart after idle boundary", gap: 10*time.Minute + time.Second, wantAction: sprintRestart},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			action, accrued := classifySprintBeat(last, last.Add(tt.gap))
			if action != tt.wantAction || accrued != tt.wantAccrued {
				t.Fatalf("classifySprintBeat gap %s = (%d, %d), want (%d, %d)",
					tt.gap, action, accrued, tt.wantAction, tt.wantAccrued)
			}
		})
	}
}

func TestSprintMinimumDisplayDuration(t *testing.T) {
	if sprintMinimumDisplaySeconds != int64(time.Minute/time.Second) {
		t.Fatalf("sprintMinimumDisplaySeconds = %d, want 60", sprintMinimumDisplaySeconds)
	}
}
