package main

import (
	"time"
	_ "time/tzdata"
)

const crewDayTimezone = "America/Chicago"

var crewDayLocation = func() *time.Location {
	location, err := time.LoadLocation(crewDayTimezone)
	if err != nil {
		panic("load Crew timezone: " + err.Error())
	}
	return location
}()

const (
	periodToday = "today"
	periodWeek  = "week"
	periodMonth = "month"
	periodAll   = "all"
)

type dayPeriod struct {
	Start time.Time
	End   time.Time
}

func currentDayPeriod() dayPeriod {
	return crewDayPeriod(time.Now())
}

func crewDayPeriod(now time.Time) dayPeriod {
	now = now.In(crewDayLocation)
	start := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, crewDayLocation)
	return dayPeriod{Start: start, End: start.AddDate(0, 0, 1)}
}

func crewActivityPeriod(now time.Time, requested string) (string, dayPeriod) {
	day := crewDayPeriod(now)
	switch requested {
	case periodWeek:
		daysSinceMonday := (int(day.Start.Weekday()) + 6) % 7
		start := day.Start.AddDate(0, 0, -daysSinceMonday)
		return periodWeek, dayPeriod{Start: start, End: start.AddDate(0, 0, 7)}
	case periodMonth:
		start := time.Date(day.Start.Year(), day.Start.Month(), 1, 0, 0, 0, 0, crewDayLocation)
		return periodMonth, dayPeriod{Start: start, End: start.AddDate(0, 1, 0)}
	case periodAll:
		return periodAll, dayPeriod{}
	default:
		return periodToday, day
	}
}

func (p dayPeriod) dateKey() string {
	return p.Start.Format(time.DateOnly)
}

func (p dayPeriod) endDateKey() string {
	return p.End.Format(time.DateOnly)
}

func addDayPeriod(v map[string]any, period dayPeriod) map[string]any {
	v["period_start"] = period.Start
	v["period_end"] = period.End
	v["timezone"] = crewDayTimezone
	return v
}
