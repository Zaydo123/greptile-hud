package main

import (
	"encoding/json"
	"net/http"
	"time"
)

// handlePulse records a devtime heartbeat. Auth via session cookie or
// Authorization: Bearer <api token>. The client sends one while a dev app
// (editor/terminal) is running; the server accrues the time between beats.
func (s *server) handlePulse(w http.ResponseWriter, r *http.Request) {
	user, ok := s.currentUser(r)
	if !ok {
		httpError(w, http.StatusUnauthorized, "not authenticated")
		return
	}
	var body struct {
		App string `json:"app"`
	}
	if r.Body != nil {
		_ = json.NewDecoder(r.Body).Decode(&body)
	}
	if err := pulse(r.Context(), s.db, user.ID); err != nil {
		logf("pulse: %s: %v", user.Login, err)
		httpError(w, http.StatusInternalServerError, "could not record pulse")
		return
	}
	seconds, err := devtimeToday(r.Context(), s.db, user.ID)
	if err != nil {
		logf("pulse: %s: devtime read: %v", user.Login, err)
		seconds = 0
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":            true,
		"devtime_today": seconds,
		"last_seen":     time.Now().UTC(),
	})
}
