package main

import (
	"encoding/json"
	"net/http"
	"time"
)

// handlePulse records a devtime heartbeat. There is no auth: the client sends
// the username it chose ("we take your word for it" model). The client sends
// one while a dev app (editor/terminal) is running; the server accrues the
// time between beats.
func (s *server) handlePulse(w http.ResponseWriter, r *http.Request) {
	var body struct {
		User string `json:"user"`
		App  string `json:"app"`
	}
	if r.Body != nil {
		_ = json.NewDecoder(r.Body).Decode(&body)
	}
	login := normalizeLogin(body.User)
	if login == "" {
		httpError(w, http.StatusBadRequest, "missing or invalid user")
		return
	}
	u, err := getOrCreateUser(r.Context(), s.db, login)
	if err != nil {
		logf("pulse: %s: user lookup: %v", login, err)
		httpError(w, http.StatusInternalServerError, "could not record pulse")
		return
	}
	if err := pulse(r.Context(), s.db, u.ID); err != nil {
		logf("pulse: %s: %v", login, err)
		httpError(w, http.StatusInternalServerError, "could not record pulse")
		return
	}
	seconds, err := devtimeToday(r.Context(), s.db, u.ID)
	if err != nil {
		logf("pulse: %s: devtime read: %v", login, err)
		seconds = 0
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":            true,
		"devtime_today": seconds,
		"last_seen":     time.Now().UTC(),
	})
}
