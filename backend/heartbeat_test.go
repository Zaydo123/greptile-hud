package main

// The devtime accrual window lives in two places that must stay in lockstep:
//
//   - pulse() (db.go) hardcodes the same thresholds as bare literal durations
//     in its SQL branches: beats <30s apart accrue nothing, [30s, 10m] accrue
//     the gap, and >10m apart only refresh the heartbeat without accruing.
//   - classifySprintBeat (sprints.go) encodes the identical rule through the
//     sprintMinBeat / sprintIdleGap constants.
//
// A drift between the two means focus time and the sprint stopwatch would
// disagree on the same stream of heartbeats. These tests pin pulse's literals
// to the constants so the coupling is explicit and a future edit to one side
// is forced to touch the other.

import (
	"testing"
	"time"
)

func TestPulseAccrualWindowMatchesSprintConstants(t *testing.T) {
	if sprintMinBeat != 30*time.Second {
		t.Fatalf("pulse() accrues beats >= 30s (db.go literal), but sprintMinBeat = %s", sprintMinBeat)
	}
	if sprintIdleGap != 10*time.Minute {
		t.Fatalf("pulse() restarts after >10m (db.go literal), but sprintIdleGap = %s", sprintIdleGap)
	}
}

// Pin the three branches of pulse()'s accrual decision to the sprint
// classification, mirroring the transition boundaries exactly.
func TestPulseBranchesAlignWithClassify(t *testing.T) {
	now := time.Now().UTC()

	// A beat < 30s apart: sprint ignores it, and pulse accrues nothing.
	short := now.Add(-29 * time.Second)
	if action, accrued := classifySprintBeat(short, now); action != sprintIgnore || accrued != 0 {
		t.Fatalf("sub-30s beat classified as action=%d accrued=%d, want ignore/0", action, accrued)
	}

	// The 30s minimum: sprint extends, pulse accrues the gap.
	atMin := now.Add(-30 * time.Second)
	if action, accrued := classifySprintBeat(atMin, now); action != sprintExtend || accrued != 30 {
		t.Fatalf("30s beat classified as action=%d accrued=%d, want extend/30", action, accrued)
	}

	// The 10-minute idle boundary: sprint still extends (pulse still accrues).
	atGap := now.Add(-10 * time.Minute)
	if action, accrued := classifySprintBeat(atGap, now); action != sprintExtend || accrued != 600 {
		t.Fatalf("10m beat classified as action=%d accrued=%d, want extend/600", action, accrued)
	}

	// Just past the idle gap: sprint restarts, pulse refreshes without accruing.
	pastGap := now.Add(-(10*time.Minute + time.Second))
	if action, _ := classifySprintBeat(pastGap, now); action != sprintRestart {
		t.Fatalf(">10m beat classified as action=%d, want restart", action)
	}
}
