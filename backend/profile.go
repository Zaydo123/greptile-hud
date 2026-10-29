package main

import (
	"context"
	"database/sql"
	"sort"
	"time"
)

// Extra profile detail for GET /api/user: a dense per-day devtime series and a
// per-emoji breakdown of status time. Both are computed by pure functions so
// the period/clipping rules are testable without Postgres.

// profileAllDays is how many crew days the "all" period's daily series covers.
// An all-time dense series would grow without bound, so "all" shows a recent
// window instead.
const profileAllDays = 30

type dailyPoint struct {
	Day     string `json:"day"`
	Seconds int64  `json:"seconds"`
}

// dailySeriesWindow picks the crew days the daily series covers: the selected
// period itself for today/week/month (future days included, as zeros, so a
// week is always seven bars), or the last 30 crew days through today for
// "all".
func dailySeriesWindow(now time.Time, periodName string, window dayPeriod) dayPeriod {
	if periodName != periodAll {
		return window
	}
	today := crewDayPeriod(now)
	return dayPeriod{Start: today.Start.AddDate(0, 0, -(profileAllDays - 1)), End: today.End}
}

// denseDailySeries emits one point per crew day in [window.Start, window.End),
// filling days with no devtime row with zero. Days are stepped with AddDate
// in the crew timezone so DST transitions (23h/25h days) don't skip or repeat
// a date. byDay is keyed by YYYY-MM-DD; keys outside the window are ignored.
func denseDailySeries(window dayPeriod, byDay map[string]int64) []dailyPoint {
	out := make([]dailyPoint, 0)
	start := window.Start.In(crewDayLocation)
	for day := start; day.Before(window.End); day = day.AddDate(0, 0, 1) {
		key := day.Format(time.DateOnly)
		out = append(out, dailyPoint{Day: key, Seconds: byDay[key]})
	}
	return out
}

func devtimeByDay(ctx context.Context, db *sql.DB, userID int64, window dayPeriod) (map[string]int64, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT to_char(day, 'YYYY-MM-DD'), seconds
		FROM devtime
		WHERE user_id = $1 AND day >= $2::date AND day < $3::date
		ORDER BY day`, userID, window.dateKey(), window.endDateKey())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]int64{}
	for rows.Next() {
		var day string
		var seconds int64
		if err := rows.Scan(&day, &seconds); err != nil {
			return nil, err
		}
		out[day] = seconds
	}
	return out, rows.Err()
}

type activitySpan struct {
	Emoji     string
	StartedAt time.Time
	EndedAt   time.Time
}

type activityTotal struct {
	Emoji   string `json:"emoji"`
	Seconds int64  `json:"seconds"`
	Count   int    `json:"count"`
}

// aggregateActivities sums status time per emoji. Each span is clipped to
// [start, end) and never past now (a running status is passed with
// EndedAt = now); a zero start or end means unbounded on that side (the "all"
// period). Spans with no time left after clipping don't count. Sorted by
// seconds desc, then emoji asc.
func aggregateActivities(spans []activitySpan, start, end, now time.Time) []activityTotal {
	limit := now
	if !end.IsZero() && end.Before(limit) {
		limit = end
	}
	byEmoji := map[string]*activityTotal{}
	for _, span := range spans {
		from, to := span.StartedAt, span.EndedAt
		if !start.IsZero() && from.Before(start) {
			from = start
		}
		if to.After(limit) {
			to = limit
		}
		seconds := int64(to.Sub(from) / time.Second)
		if seconds <= 0 {
			continue
		}
		total := byEmoji[span.Emoji]
		if total == nil {
			total = &activityTotal{Emoji: span.Emoji}
			byEmoji[span.Emoji] = total
		}
		total.Seconds += seconds
		total.Count++
	}
	out := make([]activityTotal, 0, len(byEmoji))
	for _, total := range byEmoji {
		out = append(out, *total)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Seconds != out[j].Seconds {
			return out[i].Seconds > out[j].Seconds
		}
		return out[i].Emoji < out[j].Emoji
	})
	return out
}

// activitySpans loads the history sessions overlapping the period plus the
// currently running status (ended "now"), ready for aggregateActivities.
func activitySpans(ctx context.Context, db *sql.DB, userID int64, periodName string, window dayPeriod, now time.Time) ([]activitySpan, error) {
	query := `
		SELECT emoji, started_at, ended_at
		FROM status_history
		WHERE user_id = $1`
	args := []any{userID}
	if periodName != periodAll {
		query += ` AND started_at < $2 AND ended_at > $3`
		args = append(args, window.End, window.Start)
	}
	query += ` ORDER BY started_at, id`
	rows, err := db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []activitySpan
	for rows.Next() {
		var span activitySpan
		if err := rows.Scan(&span.Emoji, &span.StartedAt, &span.EndedAt); err != nil {
			return nil, err
		}
		out = append(out, span)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	var emoji sql.NullString
	var startedAt sql.NullTime
	if err := db.QueryRowContext(ctx, `
		SELECT status_emoji, status_started_at FROM users WHERE id = $1`, userID).
		Scan(&emoji, &startedAt); err != nil && err != sql.ErrNoRows {
		return nil, err
	}
	if startedAt.Valid {
		out = append(out, activitySpan{Emoji: emoji.String, StartedAt: startedAt.Time, EndedAt: now})
	}
	return out, nil
}

// userAvatarURL reads the profile photo version for /api/user.
func userAvatarURL(ctx context.Context, db *sql.DB, u *User) (*string, error) {
	var updatedAt sql.NullTime
	err := db.QueryRowContext(ctx,
		"SELECT updated_at FROM avatars WHERE user_id = $1", u.ID).Scan(&updatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return avatarURL(u.Login, updatedAt), nil
}
