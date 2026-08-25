package main

import (
	"context"
	"database/sql"
	_ "embed"
	"fmt"
	"time"

	_ "github.com/lib/pq"
)

//go:embed schema.sql
var schemaSQL string

func openDB(databaseURL string) (*sql.DB, error) {
	db, err := sql.Open("postgres", databaseURL)
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}
	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(30 * time.Minute)

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := db.PingContext(ctx); err != nil {
		return nil, fmt.Errorf("ping database: %w", err)
	}
	if _, err := db.ExecContext(ctx, schemaSQL); err != nil {
		return nil, fmt.Errorf("apply schema: %w", err)
	}
	return db, nil
}

// ---- users (trust-based: a user is a self-chosen username) ----

type User struct {
	ID        int64      `json:"id"`
	Login     string     `json:"login"`
	Name      string     `json:"name,omitempty"`
	LastSeen  *time.Time `json:"last_seen"`
	CreatedAt time.Time  `json:"created_at"`
	UpdatedAt time.Time  `json:"updated_at"`
}

func scanUser(row interface{ Scan(...any) error }) (*User, error) {
	var u User
	var name sql.NullString
	if err := row.Scan(&u.ID, &u.Login, &name, &u.LastSeen, &u.CreatedAt, &u.UpdatedAt); err != nil {
		return nil, err
	}
	u.Name = name.String
	return &u, nil
}

const userCols = "id, login, name, last_seen, created_at, updated_at"

// getUserByLogin finds a user by exact login first, then case-insensitively so
// "Zayd" and "zayd" don't split into two people.
func getUserByLogin(ctx context.Context, db *sql.DB, login string) (*User, error) {
	u, err := scanUser(db.QueryRowContext(ctx, "SELECT "+userCols+" FROM users WHERE login = $1", login))
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return u, nil
}

// getOrCreateUser returns the user for a login, creating the row on first
// sight. Anyone can claim any username — that's the trust model. Matches are
// case-insensitive (see the users_login_lower_idx index), so a pulse with a
// different casing merges into the existing row instead of creating a twin.
func getOrCreateUser(ctx context.Context, db *sql.DB, login string) (*User, error) {
	if u, err := getUserByLogin(ctx, db, login); err != nil || u != nil {
		return u, err
	}
	u, err := scanUser(db.QueryRowContext(ctx,
		"INSERT INTO users (login) VALUES ($1) ON CONFLICT DO NOTHING RETURNING "+userCols, login))
	if err == sql.ErrNoRows {
		// Lost a race or the login already exists with different casing.
		u, err = scanUser(db.QueryRowContext(ctx,
			"SELECT "+userCols+" FROM users WHERE lower(login) = lower($1)", login))
	}
	return u, err
}

func touchUser(ctx context.Context, db *sql.DB, id int64) error {
	_, err := db.ExecContext(ctx, "UPDATE users SET last_seen = now() WHERE id = $1", id)
	return err
}

// ---- devtime ----

func pulse(ctx context.Context, db *sql.DB, userID int64, day string) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var seconds sql.NullInt64
	var lastBeat sql.NullTime
	err = tx.QueryRowContext(ctx,
		"SELECT seconds, last_heartbeat_at FROM devtime WHERE user_id = $1 AND day = $2::date", userID, day).
		Scan(&seconds, &lastBeat)
	if err != nil && err != sql.ErrNoRows {
		return err
	}
	if err == sql.ErrNoRows {
		if _, err := tx.ExecContext(ctx,
			"INSERT INTO devtime (user_id, day, seconds, last_heartbeat_at) VALUES ($1, $2::date, 0, now())", userID, day); err != nil {
			return err
		}
	} else {
		dt := time.Since(lastBeat.Time)
		switch {
		case dt >= 30*time.Second && dt <= 10*time.Minute:
			if _, err := tx.ExecContext(ctx,
				"UPDATE devtime SET seconds = seconds + $2, last_heartbeat_at = now() WHERE user_id = $1 AND day = $3::date",
				userID, int64(dt.Seconds()), day); err != nil {
				return err
			}
		case dt > 10*time.Minute:
			if _, err := tx.ExecContext(ctx,
				"UPDATE devtime SET last_heartbeat_at = now() WHERE user_id = $1 AND day = $2::date", userID, day); err != nil {
				return err
			}
		}
	}
	if _, err := tx.ExecContext(ctx,
		"UPDATE users SET last_seen = now() WHERE id = $1", userID); err != nil {
		return err
	}
	return tx.Commit()
}

func devtimeToday(ctx context.Context, db *sql.DB, userID int64, day string) (int64, error) {
	var s sql.NullInt64
	err := db.QueryRowContext(ctx,
		"SELECT seconds FROM devtime WHERE user_id = $1 AND day = $2::date", userID, day).Scan(&s)
	if err == sql.ErrNoRows || (err == nil && !s.Valid) {
		return 0, nil
	}
	return s.Int64, err
}
