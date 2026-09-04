package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	statusMessageLimit = 80
	statusEmojiByteMax = 32
)

type crewStatus struct {
	Login     string    `json:"login"`
	Name      string    `json:"name"`
	Emoji     string    `json:"emoji"`
	Message   string    `json:"message"`
	StartedAt time.Time `json:"started_at"`
	Online    bool      `json:"online"`
}

type statusRequest struct {
	User      string     `json:"user"`
	Emoji     string     `json:"emoji"`
	Message   string     `json:"message"`
	StartedAt *time.Time `json:"started_at"`
}

func normalizeStatus(emoji, message string) (string, string, error) {
	emoji = strings.TrimSpace(emoji)
	message = strings.TrimSpace(message)
	if emoji == "" && message == "" {
		return "", "", fmt.Errorf("emoji or message is required")
	}
	// Emoji grapheme clusters can contain several runes (variation selectors,
	// skin tones and ZWJ sequences), so use a small byte ceiling rather than a
	// one-rune rule. The macOS client already limits this field to one Character.
	if len(emoji) > statusEmojiByteMax || !utf8.ValidString(emoji) {
		return "", "", fmt.Errorf("emoji is too long")
	}
	if utf8.RuneCountInString(message) > statusMessageLimit {
		return "", "", fmt.Errorf("message is too long")
	}
	return emoji, message, nil
}

// handleSetStatus publishes the user's currently running local stopwatch.
// Identity follows the rest of Vibecoders: a self-chosen, unauthenticated name.
func (s *server) handleSetStatus(w http.ResponseWriter, r *http.Request) {
	var body statusRequest
	if r.Body == nil || json.NewDecoder(r.Body).Decode(&body) != nil {
		httpError(w, http.StatusBadRequest, "invalid status payload")
		return
	}
	login := normalizeLogin(body.User)
	if login == "" {
		httpError(w, http.StatusBadRequest, "missing or invalid user")
		return
	}
	emoji, message, err := normalizeStatus(body.Emoji, body.Message)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	u, err := getOrCreateUser(r.Context(), s.db, login)
	if err != nil {
		logf("status: %s: user lookup: %v", login, err)
		httpError(w, http.StatusInternalServerError, "could not set status")
		return
	}

	now := time.Now().UTC()
	startedAt := now
	if body.StartedAt != nil && !body.StartedAt.After(now.Add(5*time.Minute)) {
		startedAt = body.StartedAt.UTC()
	}
	if _, err := s.db.ExecContext(r.Context(), `
		UPDATE users
		SET status_emoji = $2, status_message = $3, status_started_at = $4, updated_at = now()
		WHERE id = $1`, u.ID, emoji, message, startedAt); err != nil {
		logf("status: %s: update: %v", login, err)
		httpError(w, http.StatusInternalServerError, "could not set status")
		return
	}

	name := u.Name
	if name == "" {
		name = u.Login
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true,
		"status": crewStatus{
			Login: u.Login, Name: name, Emoji: emoji, Message: message,
			StartedAt: startedAt, Online: isOnline(u),
		},
	})
}

// handleClearStatus removes only the shared active status. Completed interval
// history never reaches the backend; it remains in the macOS app's UserDefaults.
func (s *server) handleClearStatus(w http.ResponseWriter, r *http.Request) {
	var body struct {
		User string `json:"user"`
	}
	if r.Body == nil || json.NewDecoder(r.Body).Decode(&body) != nil {
		httpError(w, http.StatusBadRequest, "invalid status payload")
		return
	}
	login := normalizeLogin(body.User)
	if login == "" {
		httpError(w, http.StatusBadRequest, "missing or invalid user")
		return
	}
	if _, err := s.db.ExecContext(r.Context(), `
		UPDATE users
		SET status_emoji = NULL, status_message = NULL, status_started_at = NULL, updated_at = now()
		WHERE lower(login) = lower($1)`, login); err != nil {
		logf("status: %s: clear: %v", login, err)
		httpError(w, http.StatusInternalServerError, "could not clear status")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// handleStatuses lists every explicitly running status, including people who
// are away and therefore no longer appear in the five-minute online feed.
func (s *server) handleStatuses(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.QueryContext(r.Context(), `
		SELECT login, name, status_emoji, status_message, status_started_at, last_seen
		FROM users
		WHERE status_started_at IS NOT NULL
		ORDER BY status_started_at DESC
		LIMIT 100`)
	if err != nil {
		logf("statuses: %v", err)
		httpError(w, http.StatusInternalServerError, "status query failed")
		return
	}
	defer rows.Close()

	out := make([]crewStatus, 0)
	for rows.Next() {
		var status crewStatus
		var name, emoji, message sql.NullString
		var lastSeen sql.NullTime
		if err := rows.Scan(&status.Login, &name, &emoji, &message,
			&status.StartedAt, &lastSeen); err != nil {
			logf("statuses scan: %v", err)
			continue
		}
		status.Name = name.String
		if status.Name == "" {
			status.Name = status.Login
		}
		status.Emoji = emoji.String
		status.Message = message.String
		status.Online = lastSeen.Valid && time.Since(lastSeen.Time) < onlineWindow
		out = append(out, status)
	}
	if err := rows.Err(); err != nil {
		logf("statuses rows: %v", err)
		httpError(w, http.StatusInternalServerError, "status query failed")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"statuses": out})
}
