package main

// Clock-skew coverage for classifySprintBeat. The sprint accrual path
// (recordSprint) trusts the gap it computes between the last recorded beat and
// the current one. A client that heartbeats out of order — an earlier beat
// arriving after a later one, or server/client clock drift — produces a
// negative or zero gap. Those must be ignored: never accrue phantom devtime
// and never start a phantom sprint, or the leaderboard and sprint list silently
// drift from reality. sprintMinBeat already swallows any sub-30-second gap
// (including the entire negative range), so this pins that the whole "before"
// window is inert.

import (
	"testing"
	"time"
)

func TestClassifySprintBeatZeroAndNegativeGaps(t *testing.T) {
	last := time.Date(2026, time.October, 14, 9, 0, 0, 0, time.UTC)

	tests := []struct {
		name       string
		beatOffset time.Duration
	}{
		// now == last: zero elapsed, nothing to accrue.
		{name: "zero gap is ignored", beatOffset: 0},
		// now before last: out-of-order heartbeat or clock drift backwards.
		{name: "small backwards skew is ignored", beatOffset: -5 * time.Second},
		// Even a large backwards drift must stay inert, not restart a sprint.
		{name: "large backwards skew is ignored", beatOffset: -25 * time.Minute},
		// Sub-30-second forward beats are ignored by the same lower bound.
		{name: "tiny forward gap stays ignored", beatOffset: 1 * time.Second},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			action, accrued := classifySprintBeat(last, last.Add(tt.beatOffset))
			if action != sprintIgnore {
				t.Fatalf("classifySprintBeat(beat %s) = action %d, want sprintIgnore (%d); an out-of-order beat must not extend or restart a sprint", tt.beatOffset, action, sprintIgnore)
			}
			if accrued != 0 {
				t.Fatalf("classifySprintBeat(beat %s) accrued %d seconds, want 0; a non-advancing beat must not add phantom devtime", tt.beatOffset, accrued)
			}
		})
	}
}
