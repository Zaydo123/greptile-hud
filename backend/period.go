package main

import "time"

const crewDayTimezone = "UTC"

type dayPeriod struct {
	Start time.Time
	End   time.Time
}

func currentDayPeriod() dayPeriod {
	return utcDayPeriod(time.Now())
}

func utcDayPeriod(now time.Time) dayPeriod {
	now = now.UTC()
	start := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	return dayPeriod{Start: start, End: start.Add(24 * time.Hour)}
}

func (p dayPeriod) dateKey() string {
	return p.Start.Format(time.DateOnly)
}

func addDayPeriod(v map[string]any, period dayPeriod) map[string]any {
	v["period_start"] = period.Start
	v["period_end"] = period.End
	v["timezone"] = crewDayTimezone
	return v
}
