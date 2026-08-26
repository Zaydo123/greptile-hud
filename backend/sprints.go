package main

import (
	"context"
	"database/sql"
	"time"
)

const (
	sprintIdleGap               = 10 * time.Minute
	sprintMinBeat               = 30 * time.Second
	sprintRetention             = 90 * 24 * time.Hour
	sprintMinimumDisplaySeconds = int64(60)
)

type sprintAction int

const (
	sprintIgnore sprintAction = iota
	sprintExtend
	sprintRestart
)

func classifySprintBeat(lastActive, now time.Time) (sprintAction, int64) {
	gap := now.Sub(lastActive)
	switch {
	case gap < sprintMinBeat:
		return sprintIgnore, 0
	case gap <= sprintIdleGap:
		return sprintExtend, int64(gap.Seconds())
	default:
		return sprintRestart, 0
	}
}

func recordSprint(ctx context.Context, tx *sql.Tx, userID int64, now time.Time) error {
	if _, err := tx.ExecContext(ctx, `
		DELETE FROM sprints WHERE last_active_at < $1`, now.Add(-sprintRetention)); err != nil {
		return err
	}

	var id int64
	var lastActive time.Time
	err := tx.QueryRowContext(ctx, `
		SELECT id, last_active_at
		FROM sprints
		WHERE user_id = $1 AND ended_at IS NULL
		ORDER BY started_at DESC
		LIMIT 1
		FOR UPDATE`, userID).Scan(&id, &lastActive)
	if err != nil && err != sql.ErrNoRows {
		return err
	}

	if err == sql.ErrNoRows {
		_, err = tx.ExecContext(ctx, `
			INSERT INTO sprints (user_id, started_at, last_active_at)
			VALUES ($1, $2, $2)`, userID, now)
	} else {
		action, accrued := classifySprintBeat(lastActive, now)
		switch action {
		case sprintIgnore:
			// Match devtime accounting: sub-30-second beats do not move the clock.
		case sprintExtend:
			_, err = tx.ExecContext(ctx, `
				UPDATE sprints
				SET last_active_at = $2, duration_seconds = duration_seconds + $3
				WHERE id = $1`, id, now, accrued)
		case sprintRestart:
			if _, err = tx.ExecContext(ctx, `
				UPDATE sprints SET ended_at = last_active_at WHERE id = $1`, id); err == nil {
				_, err = tx.ExecContext(ctx, `
					INSERT INTO sprints (user_id, started_at, last_active_at)
					VALUES ($1, $2, $2)`, userID, now)
			}
		}
	}
	if err != nil {
		return err
	}

	return err
}

type Sprint struct {
	ID              int64     `json:"id"`
	StartedAt       time.Time `json:"started_at"`
	EndedAt         time.Time `json:"ended_at"`
	DurationSeconds int64     `json:"duration_seconds"`
	Active          bool      `json:"active"`
}

func listSprints(ctx context.Context, db *sql.DB, userID int64, periodName string, period dayPeriod) ([]Sprint, error) {
	query := `
		SELECT id, started_at, COALESCE(ended_at, last_active_at), duration_seconds,
			ended_at IS NULL AND last_active_at > now() - interval '5 minutes'
		FROM sprints
		WHERE user_id = $1
			AND duration_seconds >= $2
			AND last_active_at >= now() - interval '90 days'`
	args := []any{userID, sprintMinimumDisplaySeconds}
	if periodName != periodAll {
		query += ` AND started_at < $3 AND last_active_at >= $4`
		args = append(args, period.End, period.Start)
	}
	query += ` ORDER BY started_at DESC LIMIT 250`

	rows, err := db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]Sprint, 0)
	for rows.Next() {
		var sprint Sprint
		if err := rows.Scan(&sprint.ID, &sprint.StartedAt, &sprint.EndedAt,
			&sprint.DurationSeconds, &sprint.Active); err != nil {
			return nil, err
		}
		out = append(out, sprint)
	}
	return out, rows.Err()
}
