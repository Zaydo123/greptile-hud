package main

import "testing"
import "time"

// currentDayPeriod is the production shim that feeds "now" into the shared
// crew-day calculator. It is used by the online and status handlers, so a
// regression here (e.g. someone "simplifying" it to time.Now().UTC() and
// losing the Central-Time conversion) silently moves the day boundary and
// miscalculates every devtime and presence window from midnight. These tests
// pin it to the same shift-conversion contract as crewDayPeriod.
func TestCurrentDayPeriodAnchorsToCentralMidnight(t *testing.T) {
	got := currentDayPeriod()

	// The window must contain the instant it was computed.
	now := time.Now()
	if got.Start.After(now) || !got.End.After(now) {
		t.Fatalf("currentDayPeriod() = [%s, %s) does not contain now %s",
			got.Start, got.End, now)
	}

	centralNow := now.In(crewDayLocation)
	// The start boundary must be midnight on today's Central calendar day and
	// carry the Central location (not UTC — the exact regression we guard).
	if got.Start.Hour() != 0 || got.Start.Minute() != 0 ||
		got.Start.Second() != 0 || got.Start.Nanosecond() != 0 {
		t.Fatalf("currentDayPeriod() start %s is not Central midnight "+
			"(hour=%d min=%d sec=%d nsec=%d)", got.Start,
			got.Start.Hour(), got.Start.Minute(), got.Start.Second(), got.Start.Nanosecond())
	}
	if _, off := got.Start.Zone(); off == 0 {
		t.Fatalf("currentDayPeriod() start %s carries a UTC offset 0; "+
			"want an America/Chicago offset", got.Start)
	}
	if got.Start.Year() != centralNow.Year() ||
		got.Start.Month() != centralNow.Month() ||
		got.Start.Day() != centralNow.Day() {
		t.Fatalf("currentDayPeriod() start %s is not today's Central date (%s)",
			got.Start, centralNow.Format("2006-01-02"))
	}

	// End is exactly one crew-day later.
	wantEnd := got.Start.AddDate(0, 0, 1)
	if !got.End.Equal(wantEnd) {
		t.Fatalf("currentDayPeriod() end %s, want start+1day %s", got.End, wantEnd)
	}
}
