package main

import "time"

const crewDayTimezone = "UTC"

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
	return utcDayPeriod(time.Now())
}

func utcDayPeriod(now time.Time) dayPeriod {
	now = now.UTC()
	start := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	return dayPeriod{Start: start, End: start.Add(24 * time.Hour)}
}

func utcActivityPeriod(now time.Time, requested string) (string, dayPeriod) {
	day := utcDayPeriod(now)
	switch requested {
	case periodWeek:
		daysSinceMonday := (int(day.Start.Weekday()) + 6) % 7
		start := day.Start.AddDate(0, 0, -daysSinceMonday)
		return periodWeek, dayPeriod{Start: start, End: start.AddDate(0, 0, 7)}
	case periodMonth:
		start := time.Date(day.Start.Year(), day.Start.Month(), 1, 0, 0, 0, 0, time.UTC)
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
