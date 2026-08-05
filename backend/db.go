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

// ---- users ----

type User struct {
	ID          int64      `json:"id"`
	GitHubID    int64      `json:"github_id"`
	Login       string     `json:"login"`
	Name        string     `json:"name,omitempty"`
	AvatarURL   string     `json:"avatar_url,omitempty"`
	Orgs        []string   `json:"orgs"`
	LastSeen    *time.Time `json:"last_seen"`
	LastSyncAt  *time.Time `json:"last_sync_at"`
	CreatedAt   time.Time  `json:"created_at"`
	UpdatedAt   time.Time  `json:"updated_at"`
	AccessToken string     `json:"-"`
}

func scanUser(row interface{ Scan(...any) error }) (*User, error) {
	var u User
	var orgs string
	var name, avatar sql.NullString
	if err := row.Scan(&u.ID, &u.GitHubID, &u.Login, &name, &avatar, &orgs, &u.LastSeen, &u.LastSyncAt, &u.CreatedAt, &u.UpdatedAt); err != nil {
		return nil, err
	}
	u.Name, u.AvatarURL = name.String, avatar.String
	u.Orgs = parseOrgs(orgs)
	return &u, nil
}

const userCols = "id, github_id, login, name, avatar_url, orgs, last_seen, last_sync_at, created_at, updated_at"

func getUserByID(ctx context.Context, db *sql.DB, id int64) (*User, error) {
	u, err := scanUser(db.QueryRowContext(ctx, "SELECT "+userCols+" FROM users WHERE id = $1", id))
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return u, err
}

func getUserByGitHubID(ctx context.Context, db *sql.DB, ghID int64) (*User, error) {
	u, err := scanUser(db.QueryRowContext(ctx, "SELECT "+userCols+" FROM users WHERE github_id = $1", ghID))
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return u, err
}

func upsertUser(ctx context.Context, db *sql.DB, u *User, accessToken string) (*User, error) {
	u.UpdatedAt = time.Now().UTC()
	row := db.QueryRowContext(ctx, `
		INSERT INTO users (github_id, login, name, avatar_url, access_token, orgs)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (github_id) DO UPDATE SET
			login = EXCLUDED.login,
			name = CASE WHEN EXCLUDED.name IS NULL THEN users.name ELSE EXCLUDED.name END,
			avatar_url = EXCLUDED.avatar_url,
			access_token = EXCLUDED.access_token,
			orgs = EXCLUDED.orgs,
			updated_at = now()
		RETURNING `+userCols,
		u.GitHubID, u.Login, nullIfEmpty(u.Name), nullIfEmpty(u.AvatarURL), accessToken, marshalOrgs(u.Orgs))
	return scanUser(row)
}

func updateUserProfile(ctx context.Context, db *sql.DB, userID int64, name, avatarURL string) error {
	_, err := db.ExecContext(ctx, `
		UPDATE users SET
			name = CASE WHEN $2 <> '' THEN $2 ELSE name END,
			avatar_url = CASE WHEN $3 <> '' THEN $3 ELSE avatar_url END,
			updated_at = now()
		WHERE id = $1`, userID, name, avatarURL)
	return err
}

func touchUser(ctx context.Context, db *sql.DB, id int64) error {
	_, err := db.ExecContext(ctx, "UPDATE users SET last_seen = now() WHERE id = $1", id)
	return err
}

func setUserSyncTime(ctx context.Context, db *sql.DB, id int64) error {
	_, err := db.ExecContext(ctx, "UPDATE users SET last_sync_at = now() WHERE id = $1", id)
	return err
}

func allUsers(ctx context.Context, db *sql.DB) ([]*User, error) {
	rows, err := db.QueryContext(ctx, "SELECT "+userCols+" FROM users ORDER BY login")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*User
	for rows.Next() {
		u, err := scanUser(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

// ---- github_stats ----

type Stats struct {
	Commits30D int64 `json:"commits_30d"`
	CommitsAll int64 `json:"commits_all"`
	LOC30D     int64 `json:"loc_30d"`
	LOCAll     int64 `json:"loc_all"`
	PRs30D     int64 `json:"prs_30d"`
	PRsAll     int64 `json:"prs_all"`
}

func getStats(ctx context.Context, db *sql.DB, userID int64) (Stats, error) {
	var s Stats
	err := db.QueryRowContext(ctx, `
		SELECT commits_30d, commits_all, loc_30d, loc_all, prs_30d, prs_all
		FROM github_stats WHERE user_id = $1`, userID).
		Scan(&s.Commits30D, &s.CommitsAll, &s.LOC30D, &s.LOCAll, &s.PRs30D, &s.PRsAll)
	if err == sql.ErrNoRows {
		return Stats{}, nil
	}
	return s, err
}

func saveStats(ctx context.Context, db *sql.DB, userID int64, s Stats) error {
	_, err := db.ExecContext(ctx, `
		INSERT INTO github_stats (user_id, commits_30d, commits_all, loc_30d, loc_all, prs_30d, prs_all)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		ON CONFLICT (user_id) DO UPDATE SET
			commits_30d = EXCLUDED.commits_30d,
			commits_all = EXCLUDED.commits_all,
			loc_30d = EXCLUDED.loc_30d,
			loc_all = EXCLUDED.loc_all,
			prs_30d = EXCLUDED.prs_30d,
			prs_all = EXCLUDED.prs_all,
			updated_at = now()`,
		userID, s.Commits30D, s.CommitsAll, s.LOC30D, s.LOCAll, s.PRs30D, s.PRsAll)
	return err
}

// ---- devtime ----

func pulse(ctx context.Context, db *sql.DB, userID int64) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var seconds sql.NullInt64
	var lastBeat sql.NullTime
	err = tx.QueryRowContext(ctx,
		"SELECT seconds, last_heartbeat_at FROM devtime WHERE user_id = $1 AND day = CURRENT_DATE", userID).
		Scan(&seconds, &lastBeat)
	if err != nil && err != sql.ErrNoRows {
		return err
	}
	if err == sql.ErrNoRows {
		if _, err := tx.ExecContext(ctx,
			"INSERT INTO devtime (user_id, day, seconds, last_heartbeat_at) VALUES ($1, CURRENT_DATE, 0, now())", userID); err != nil {
			return err
		}
	} else {
		dt := time.Since(lastBeat.Time)
		switch {
		case dt >= 30*time.Second && dt <= 10*time.Minute:
			if _, err := tx.ExecContext(ctx,
				"UPDATE devtime SET seconds = seconds + $2, last_heartbeat_at = now() WHERE user_id = $1 AND day = CURRENT_DATE",
				userID, int64(dt.Seconds())); err != nil {
				return err
			}
		case dt > 10*time.Minute:
			if _, err := tx.ExecContext(ctx,
				"UPDATE devtime SET last_heartbeat_at = now() WHERE user_id = $1 AND day = CURRENT_DATE", userID); err != nil {
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

func devtimeToday(ctx context.Context, db *sql.DB, userID int64) (int64, error) {
	var s sql.NullInt64
	err := db.QueryRowContext(ctx,
		"SELECT seconds FROM devtime WHERE user_id = $1 AND day = CURRENT_DATE", userID).Scan(&s)
	if err == sql.ErrNoRows || (err == nil && !s.Valid) {
		return 0, nil
	}
	return s.Int64, err
}

// ---- api_tokens ----

func createToken(ctx context.Context, db *sql.DB, userID int64) (string, error) {
	tok, err := randomHex(32)
	if err != nil {
		return "", err
	}
	if _, err := db.ExecContext(ctx,
		"INSERT INTO api_tokens (token, user_id) VALUES ($1, $2)", tok, userID); err != nil {
		return "", err
	}
	return tok, nil
}

func userByToken(ctx context.Context, db *sql.DB, token string) (*User, error) {
	var userID int64
	err := db.QueryRowContext(ctx,
		"SELECT user_id FROM api_tokens WHERE token = $1", token).Scan(&userID)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return getUserByID(ctx, db, userID)
}

func tokensForUser(ctx context.Context, db *sql.DB, userID int64) ([]string, error) {
	rows, err := db.QueryContext(ctx, "SELECT token FROM api_tokens WHERE user_id = $1 ORDER BY created_at DESC", userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var t string
		if err := rows.Scan(&t); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func deleteToken(ctx context.Context, db *sql.DB, userID int64, token string) error {
	_, err := db.ExecContext(ctx,
		"DELETE FROM api_tokens WHERE token = $1 AND user_id = $2", token, userID)
	return err
}
