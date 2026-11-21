package main

// Coverage for the database-failure path of the read handlers in
// leaderboard.go, statuses.go, status_history.go, usage.go, banners.go and
// avatar.go: what a
// degraded deployment (unreachable Postgres) returns for each top-level
// endpoint. These branches log and answer 500 with a stable message; a bad
// refactor that drops the guard and panics on a nil rows / a closed db would
// take the whole service down instead. Each handler is pointed at an
// unreachable DSN so the query step fails deterministically without a live
// Postgres. Stdlib only — no new dependency.

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestReadHandlersReturn500WhenDBDown(t *testing.T) {
	s := brokenDB(t) // PingContext always fails; every case must hit the DB.

	cases := []struct {
		name    string
		handler http.HandlerFunc
		method  string
		target  string
		body    string
		want    string
	}{
		{"leaderboard", s.handleLeaderboard, http.MethodGet, "/api/leaderboard?period=week", "", "leaderboard query failed"},
		{"online", s.handleOnline, http.MethodGet, "/api/online", "", "online query failed"},
		{"statuses", s.handleStatuses, http.MethodGet, "/api/statuses", "", "status query failed"},
		{"status history", s.handleGetStatusHistory, http.MethodGet, "/api/status/history?login=zayd&limit=5", "", "history query failed"},
		{"user profile", s.handleUser, http.MethodGet, "/api/user?login=zayd", "", "user lookup failed"},
		{"single usage", s.handleGetUsage, http.MethodGet, "/api/usage?login=zayd", "", "usage query failed"},
		{"crew usage", s.handleGetCrewUsage, http.MethodGet, "/api/usage/crew?period=week", "", "usage query failed"},
		{"banners", s.handleBanners, http.MethodGet, "/api/banners", "", "banner query failed"},
		{"avatar", s.handleGetAvatar, http.MethodGet, "/api/avatar?login=zayd", "", "could not read avatar"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			tc.handler(rec, httptest.NewRequest(tc.method, tc.target, strings.NewReader(tc.body)))
			if rec.Code != http.StatusInternalServerError {
				t.Fatalf("status = %d, want %d (body %s)", rec.Code, http.StatusInternalServerError, rec.Body.String())
			}
			if !strings.Contains(rec.Body.String(), tc.want) {
				t.Fatalf("body = %q, want it to contain %q", rec.Body.String(), tc.want)
			}
			if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
				t.Fatalf("Content-Type = %q, want application/json", ct)
			}
		})
	}
}
