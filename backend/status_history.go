package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// Completed status sessions are stored server-side (the user asked for their
// history to follow them across Macs). The Mac app's StatusStore still owns
// timing; it uploads each finished session with its own UUID, so re-uploads
// and renames upsert by (user, client UUID) instead of duplicating.

const (
	statusHistoryMaxSessions  = 200
	statusHistoryMaxDuration  = 7 * 24 * time.Hour
	statusHistoryDefaultLimit = 100
	statusHistoryMaxLimit     = 500
	statusHistoryMaxBodyBytes = 256 * 1024
	statusHistoryFutureWindow = statusStartFutureWindow
)

type historySession struct {
	ID        string    `json:"id"`
	Emoji     string    `json:"emoji"`
	Message   string    `json:"message"`
	StartedAt time.Time `json:"started_at"`
	EndedAt   time.Time `json:"ended_at"`
}

// parseUUID validates the canonical 8-4-4-4-12 hex form (either case) and
// returns it lowercased — the form Postgres prints a UUID column back as.
func parseUUID(raw string) (string, bool) {
	s := strings.ToLower(strings.TrimSpace(raw))
	if len(s) != 36 {
		return "", false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch i {
		case 8, 13, 18, 23:
			if c != '-' {
				return "", false
			}
		default:
			if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
				return "", false
			}
		}
	}
	return s, true
}

// validateHistorySession normalizes one uploaded session or reports why it
// can't be stored. Emoji/message use the same rules as a live status.
func validateHistorySession(in historySession, now time.Time) (historySession, error) {
	id, ok := parseUUID(in.ID)
	if !ok {
		return historySession{}, errors.New("id must be a UUID")
	}
	emoji, message, err := normalizeStatus(in.Emoji, in.Message)
	if err != nil {
		return historySession{}, err
	}
	if in.StartedAt.IsZero() || in.EndedAt.IsZero() {
		return historySession{}, errors.New("started_at and ended_at are required")
	}
	if !in.EndedAt.After(in.StartedAt) {
		return historySession{}, errors.New("ended_at must be after started_at")
	}
	if in.EndedAt.Sub(in.StartedAt) > statusHistoryMaxDuration {
		return historySession{}, errors.New("session is longer than 7 days")
	}
	if in.StartedAt.After(now.Add(statusHistoryFutureWindow)) {
		return historySession{}, errors.New("started_at is in the future")
	}
	return historySession{
		ID: id, Emoji: emoji, Message: message,
		StartedAt: in.StartedAt.UTC(), EndedAt: in.EndedAt.UTC(),
	}, nil
}

// validateHistorySessions splits an upload into storable sessions and a count
// of skipped ones. Each session is decoded on its own, so a malformed one (a
// bad timestamp, a wrong type) is skipped like any other invalid session
// rather than failing the batch: one bad local record can't block the rest of
// a user's history.
func validateHistorySessions(in []json.RawMessage, now time.Time) ([]historySession, int) {
	valid := make([]historySession, 0, len(in))
	skipped := 0
	for _, raw := range in {
		var session historySession
		if err := json.Unmarshal(raw, &session); err != nil {
			skipped++
			continue
		}
		v, err := validateHistorySession(session, now)
		if err != nil {
			skipped++
			continue
		}
		valid = append(valid, v)
	}
	return valid, skipped
}

// handlePostStatusHistory upserts completed status sessions:
//
//	POST /api/status/history {"user": "name", "sessions": [...]}
func (s *server) handlePostStatusHistory(w http.ResponseWriter, r *http.Request) {
	var body struct {
		User     string            `json:"user"`
		Sessions []json.RawMessage `json:"sessions"`
	}
	if r.Body == nil || json.NewDecoder(http.MaxBytesReader(w, r.Body, statusHistoryMaxBodyBytes)).Decode(&body) != nil {
		httpError(w, http.StatusBadRequest, "invalid history payload")
		return
	}
	login := normalizeLogin(body.User)
	if login == "" {
		httpError(w, http.StatusBadRequest, "missing or invalid user")
		return
	}
	if len(body.Sessions) == 0 || len(body.Sessions) > statusHistoryMaxSessions {
		httpError(w, http.StatusBadRequest, "sessions must contain 1 to 200 entries")
		return
	}
	valid, skipped := validateHistorySessions(body.Sessions, time.Now())
	if len(valid) == 0 {
		httpError(w, http.StatusBadRequest, "no valid sessions")
		return
	}
	u, err := getOrCreateUser(r.Context(), s.db, login)
	if err != nil {
		logf("status history: %s: user lookup: %v", login, err)
		httpError(w, http.StatusInternalServerError, "could not store history")
		return
	}
	if err := upsertHistory(r.Context(), s.db, u.ID, valid); err != nil {
		logf("status history: %s: upsert: %v", login, err)
		httpError(w, http.StatusInternalServerError, "could not store history")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "stored": len(valid), "skipped": skipped})
}

func upsertHistory(ctx context.Context, db *sql.DB, userID int64, sessions []historySession) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, session := range sessions {
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO status_history (user_id, client_id, emoji, message, started_at, ended_at, updated_at)
			VALUES ($1, $2::uuid, $3, $4, $5, $6, now())
			ON CONFLICT (user_id, client_id) DO UPDATE
			SET emoji = EXCLUDED.emoji,
				message = EXCLUDED.message,
				started_at = EXCLUDED.started_at,
				ended_at = EXCLUDED.ended_at,
				updated_at = now()`,
			userID, session.ID, session.Emoji, session.Message,
			session.StartedAt, session.EndedAt); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// handleDeleteStatusHistory removes one session by its client UUID.
// Idempotent: an unknown session or user still succeeds.
func (s *server) handleDeleteStatusHistory(w http.ResponseWriter, r *http.Request) {
	var body struct {
		User string `json:"user"`
		ID   string `json:"id"`
	}
	if r.Body == nil || json.NewDecoder(r.Body).Decode(&body) != nil {
		httpError(w, http.StatusBadRequest, "invalid history payload")
		return
	}
	login := normalizeLogin(body.User)
	if login == "" {
		httpError(w, http.StatusBadRequest, "missing or invalid user")
		return
	}
	id, ok := parseUUID(body.ID)
	if !ok {
		httpError(w, http.StatusBadRequest, "id must be a UUID")
		return
	}
	if _, err := s.db.ExecContext(r.Context(), `
		DELETE FROM status_history
		WHERE client_id = $2::uuid
			AND user_id IN (SELECT id FROM users WHERE lower(login) = lower($1))`, login, id); err != nil {
		logf("status history: %s: delete: %v", login, err)
		httpError(w, http.StatusInternalServerError, "could not delete session")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// historyLimit parses ?limit=, defaulting to 100 and clamping to 1…500.
func historyLimit(raw string) int {
	n, err := strconv.Atoi(strings.TrimSpace(raw))
	if err != nil {
		return statusHistoryDefaultLimit
	}
	return min(max(n, 1), statusHistoryMaxLimit)
}

// handleGetStatusHistory lists a user's sessions, newest first:
//
//	GET /api/status/history?login=name&limit=100
//
// An unknown user simply has no sessions.
func (s *server) handleGetStatusHistory(w http.ResponseWriter, r *http.Request) {
	login := normalizeLogin(r.URL.Query().Get("login"))
	if login == "" {
		httpError(w, http.StatusBadRequest, "missing or invalid login")
		return
	}
	limit := historyLimit(r.URL.Query().Get("limit"))
	rows, err := s.db.QueryContext(r.Context(), `
		SELECT h.client_id::text, h.emoji, h.message, h.started_at, h.ended_at
		FROM status_history h
		JOIN users u ON u.id = h.user_id
		WHERE lower(u.login) = lower($1)
		ORDER BY h.started_at DESC, h.client_id
		LIMIT $2`, login, limit)
	if err != nil {
		logf("status history: %s: %v", login, err)
		httpError(w, http.StatusInternalServerError, "history query failed")
		return
	}
	defer rows.Close()
	out := make([]historySession, 0)
	for rows.Next() {
		var session historySession
		if err := rows.Scan(&session.ID, &session.Emoji, &session.Message,
			&session.StartedAt, &session.EndedAt); err != nil {
			logf("status history scan: %v", err)
			httpError(w, http.StatusInternalServerError, "history query failed")
			return
		}
		out = append(out, session)
	}
	if err := rows.Err(); err != nil {
		logf("status history rows: %v", err)
		httpError(w, http.StatusInternalServerError, "history query failed")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"sessions": out})
}
