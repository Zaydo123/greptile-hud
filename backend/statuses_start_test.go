package main

// Unit coverage for resolveStatusStart (statuses.go). It is the single place a
// client-supplied "started_at" is translated into the published status start,
// and its future-clamp guards against clock-skewed or forged timestamps pushing
// a status into the future. Tested with the stdlib only — no new dependency.

import (
	"testing"
	"time"
)

func TestResolveStatusStart(t *testing.T) {
	now := time.Date(2026, 9, 27, 12, 0, 0, 0, time.UTC)

	t.Run("nil start means now", func(t *testing.T) {
		if got := resolveStatusStart(nil, now); !got.Equal(now) {
			t.Fatalf("resolveStatusStart(nil) = %v, want %v", got, now)
		}
	})

	t.Run("past start is kept", func(t *testing.T) {
		// Legitimate backdated resume must survive the clamp unchanged.
		start := now.Add(-time.Hour)
		if got := resolveStatusStart(&start, now); !got.Equal(start) {
			t.Fatalf("resolveStatusStart(past) = %v, want %v", got, start)
		}
	})

	t.Run("recent future start is kept", func(t *testing.T) {
		start := now.Add(2 * time.Minute)
		if got := resolveStatusStart(&start, now); !got.Equal(start.UTC()) {
			t.Fatalf("resolveStatusStart(recent future) = %v, want %v", got, start)
		}
	})

	t.Run("exactly at the window edge is kept", func(t *testing.T) {
		// After() is exclusive: a started_at exactly statusStartFutureWindow
		// ahead is inside the allowed window, not clamped.
		start := now.Add(statusStartFutureWindow)
		if got := resolveStatusStart(&start, now); !got.Equal(start.UTC()) {
			t.Fatalf("resolveStatusStart(edge) = %v, want %v", got, start)
		}
	})

	t.Run("beyond the window clamps to now", func(t *testing.T) {
		start := now.Add(statusStartFutureWindow + time.Minute)
		if got := resolveStatusStart(&start, now); !got.Equal(now) {
			t.Fatalf("resolveStatusStart(too far) = %v, want %v", got, now)
		}
	})

	t.Run("non-UTC start is normalized to UTC", func(t *testing.T) {
		if now.Location() == time.Local {
			t.Skip("local zone equals UTC; cannot exercise the conversion")
		}
		start := now.In(time.FixedZone("UTC-5", -5*60*60))
		got := resolveStatusStart(&start, now)
		if _, offset := got.Zone(); offset != 0 {
			t.Fatalf("resolveStatusStart() = %v, want a UTC-normalized time", got)
		}
	})
}

func TestStatusStartFutureWindowValue(t *testing.T) {
	// resolveStatusStart's backdate clamp is deliberately capped: a client may
	// push a status start at most this far ahead of the server clock before it
	// is treated as clock-skewed or forged and clamped to "now". Pin the value
	// so an edit that widens or changes the units (e.g. to 10*time.Minute or a
	// bare 300) is forced to acknowledge the intended five-minute cap — the
	// same lockstep guard windows_test.go applies to the other time windows.
	if statusStartFutureWindow != 5*time.Minute {
		t.Fatalf("statusStartFutureWindow = %s, want 5m", statusStartFutureWindow)
	}
}
