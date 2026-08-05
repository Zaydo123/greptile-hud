package main

import (
	"database/sql"
	"net/http"
	"strings"
	"time"
)

const onlineWindow = 5 * time.Minute

func isOnline(u *User) bool {
	return u.LastSeen != nil && time.Since(*u.LastSeen) < onlineWindow
}

type leaderboardEntry struct {
	Rank     int        `json:"rank"`
	Login    string     `json:"login"`
	Name     string     `json:"name"`
	Avatar   string     `json:"avatar_url"`
	Value    int64      `json:"value"`
	Online   bool       `json:"online"`
	LastSeen *time.Time `json:"last_seen"`
}

// handleLeaderboard returns the leaderboard for a metric:
//
//	GET /api/leaderboard?metric=devtime|commits|loc|prs&period=30d|all
func (s *server) handleLeaderboard(w http.ResponseWriter, r *http.Request) {
	metric := r.URL.Query().Get("metric")
	period := r.URL.Query().Get("period")
	if period != "all" {
		period = "30d"
	}
	valueExpr := leaderboardValueExpr(metric, period)
	if valueExpr == "" {
		httpError(w, http.StatusBadRequest, "metric must be devtime, commits, loc, or prs")
		return
	}
	rows, err := s.db.QueryContext(r.Context(), `
		SELECT u.login, u.name, u.avatar_url, u.last_seen, `+valueExpr+` AS value
		FROM users u
		LEFT JOIN github_stats gs ON gs.user_id = u.id
		LEFT JOIN devtime d ON d.user_id = u.id AND d.day = CURRENT_DATE
		ORDER BY value DESC, u.login
		LIMIT 100`)
	if err != nil {
		logf("leaderboard: %v", err)
		httpError(w, http.StatusInternalServerError, "leaderboard query failed")
		return
	}
	defer rows.Close()
	var out []leaderboardEntry
	rank := 0
	for rows.Next() {
		var e leaderboardEntry
		var name sql.NullString
		if err := rows.Scan(&e.Login, &name, &e.Avatar, &e.LastSeen, &e.Value); err != nil {
			logf("leaderboard scan: %v", err)
			continue
		}
		e.Name, e.Rank = name.String, rank+1
		e.Online = isOnline(&User{LastSeen: e.LastSeen})
		out = append(out, e)
		rank++
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"metric":  metric,
		"period":  period,
		"updated": time.Now().UTC(),
		"entries": out,
	})
}

func leaderboardValueExpr(metric, period string) string {
	suffix := "_30d"
	if period == "all" {
		suffix = "_all"
	}
	switch metric {
	case "devtime":
		return "COALESCE(d.seconds, 0)"
	case "commits", "loc", "prs":
		return "COALESCE(gs." + metric + suffix + ", 0)"
	}
	return ""
}

// handleOnline lists currently online users (heartbeat within the window).
func (s *server) handleOnline(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.QueryContext(r.Context(), `
		SELECT login, name, avatar_url, last_seen,
			COALESCE((SELECT seconds FROM devtime WHERE user_id = users.id AND day = CURRENT_DATE), 0)
		FROM users
		WHERE last_seen IS NOT NULL AND last_seen > now() - interval '5 minutes'
		ORDER BY last_seen DESC`)
	if err != nil {
		logf("online: %v", err)
		httpError(w, http.StatusInternalServerError, "online query failed")
		return
	}
	defer rows.Close()
	type entry struct {
		Login        string    `json:"login"`
		Name         string    `json:"name"`
		Avatar       string    `json:"avatar_url"`
		LastSeen     time.Time `json:"last_seen"`
		DevtimeToday int64     `json:"devtime_today"`
	}
	var out []entry
	for rows.Next() {
		var e entry
		var name sql.NullString
		if err := rows.Scan(&e.Login, &name, &e.Avatar, &e.LastSeen, &e.DevtimeToday); err != nil {
			continue
		}
		e.Name = name.String
		out = append(out, e)
	}
	writeJSON(w, http.StatusOK, map[string]any{"online": out})
}

// handleMe returns the authenticated user with stats, devtime, and API tokens.
func (s *server) handleMe(w http.ResponseWriter, r *http.Request) {
	user, ok := s.currentUser(r)
	if !ok {
		httpError(w, http.StatusUnauthorized, "not authenticated")
		return
	}
	s.writeUserProfile(w, r, user, true)
}

// handleProfile returns a public profile for a login.
func (s *server) handleProfile(w http.ResponseWriter, r *http.Request) {
	login := strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/profile/"), "/")
	if login == "" {
		httpError(w, http.StatusBadRequest, "missing login")
		return
	}
	u, err := scanUser(s.db.QueryRowContext(r.Context(),
		"SELECT "+userCols+" FROM users WHERE lower(login) = lower($1)", login))
	if err != nil {
		if err == sql.ErrNoRows {
			httpError(w, http.StatusNotFound, "user not found")
			return
		}
		logf("profile lookup: %v", err)
		httpError(w, http.StatusInternalServerError, "profile lookup failed")
		return
	}
	s.writeUserProfile(w, r, u, false)
}

func (s *server) writeUserProfile(w http.ResponseWriter, r *http.Request, u *User, private bool) {
	stats, err := getStats(r.Context(), s.db, u.ID)
	if err != nil {
		logf("profile stats: %v", err)
	}
	today, err := devtimeToday(r.Context(), s.db, u.ID)
	if err != nil {
		logf("profile devtime: %v", err)
	}
	resp := map[string]any{
		"user":          u,
		"stats":         stats,
		"devtime_today": today,
		"online":        isOnline(u),
	}
	if private {
		tokens, err := tokensForUser(r.Context(), s.db, u.ID)
		if err != nil {
			logf("tokens: %v", err)
		}
		resp["api_tokens"] = tokens
	}
	writeJSON(w, http.StatusOK, resp)
}

// currentUser resolves the session cookie or Bearer token.
func (s *server) currentUser(r *http.Request) (*User, bool) {
	if id, ok := s.auth.userIDFromCookie(r); ok {
		u, err := getUserByID(r.Context(), s.db, id)
		if err != nil {
			logf("session user lookup: %v", err)
			return nil, false
		}
		if u != nil {
			return u, true
		}
	}
	if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
		u, err := userByToken(r.Context(), s.db, strings.TrimPrefix(h, "Bearer "))
		if err != nil {
			logf("token user lookup: %v", err)
			return nil, false
		}
		if u != nil {
			return u, true
		}
	}
	return nil, false
}
