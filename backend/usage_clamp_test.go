package main

// Pure-logic coverage for clampUsageSeconds, which guards the per-item ceiling
// on usage payloads (usageItemSecondsMax = 600). It normalizes a float from the
// macOS client into the integer seconds used for summing, so it must reject
// NaN and +Inf rather than let them poison the total, clamp negatives and
// zeros to 0, cap at the ceiling, and truncate fractions. Everything here runs
// without Postgres. Stdlib only.

import (
	"math"
	"testing"
)

func TestClampUsageSeconds(t *testing.T) {
	cases := []struct {
		name string
		in   float64
		want int64
	}{
		{"zero is dropped", 0, 0},
		{"tiny negative dropped", -0.5, 0},
		{"negative dropped", -40, 0},
		{"NaN dropped", math.NaN(), 0},
		{"negative infinity dropped", math.Inf(-1), 0},
		{"positive infinity capped", math.Inf(1), usageItemSecondsMax},
		{"fraction truncated", 25.9, 25},
		{"below ceiling kept", 30, 30},
		{"at ceiling kept", usageItemSecondsMax, usageItemSecondsMax},
		{"above ceiling capped", 5000, usageItemSecondsMax},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := clampUsageSeconds(tc.in); got != tc.want {
				t.Fatalf("clampUsageSeconds(%v) = %d, want %d", tc.in, got, tc.want)
			}
		})
	}
}
