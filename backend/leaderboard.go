package main

import (
	"database/sql"
	"net/http"
	"regexp"
	"strings"
	"time"
)

const onlineWindow = 5 * time.Minute

var loginRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$`)

// normalizeLogin cleans a raw username (trims, strips a leading "@") and
// returns "" when it isn't a valid name.
func normalizeLogin(raw string) string {
	s := strings.TrimSpace(raw)
	s = strings.TrimPrefix(s, "@")
	s = strings.TrimSpace(s)
	if !loginRe.MatchString(s) {
		return ""
	}
	return s
}

func isOnline(u *User) bool {
	return u.LastSeen != nil && time.Since(*u.LastSeen) < onlineWindow
}

type leaderboardEntry struct {
	Rank     int        `json:"rank"`
	Login    string     `json:"login"`
	Name     string     `json:"name"`
	Value    int64      `json:"value"`
	Online   bool       `json:"online"`
	LastSeen *time.Time `json:"last_seen"`
}

// handleLeaderboard returns the devtime leaderboard:
//
//	GET /api/leaderboard?period=today|all
//
// "today" is the default; "all" sums every recorded day.
func (s *server) handleLeaderboard(w http.ResponseWriter, r *http.Request) {
	day := currentDayPeriod()
	period := r.URL.Query().Get("period")
	if period != "all" {
		period = "today"
	}
	var rows *sql.Rows
	var err error
	if period == "all" {
		rows, err = s.db.QueryContext(r.Context(), `
			SELECT u.login, u.name, u.last_seen, COALESCE(SUM(d.seconds), 0) AS value
			FROM users u
			LEFT JOIN devtime d ON d.user_id = u.id
			GROUP BY u.id
			ORDER BY value DESC, u.login
			LIMIT 100`)
	} else {
		rows, err = s.db.QueryContext(r.Context(), `
			SELECT u.login, u.name, u.last_seen, COALESCE(d.seconds, 0) AS value
			FROM users u
			LEFT JOIN devtime d ON d.user_id = u.id AND d.day = $1::date
			ORDER BY value DESC, u.login
			LIMIT 100`, day.dateKey())
	}
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
		if err := rows.Scan(&e.Login, &name, &e.LastSeen, &e.Value); err != nil {
			logf("leaderboard scan: %v", err)
			continue
		}
		if name.Valid && name.String != "" {
			e.Name = name.String
		} else {
			e.Name = e.Login
		}
		e.Rank = rank + 1
		e.Online = isOnline(&User{LastSeen: e.LastSeen})
		out = append(out, e)
		rank++
	}
	response := map[string]any{
		"metric":  "devtime",
		"period":  period,
		"updated": time.Now().UTC(),
		"entries": out,
	}
	if period == "today" {
		addDayPeriod(response, day)
	}
	writeJSON(w, http.StatusOK, response)
}

// handleOnline lists currently online users (heartbeat within the window).
func (s *server) handleOnline(w http.ResponseWriter, r *http.Request) {
	day := currentDayPeriod()
	rows, err := s.db.QueryContext(r.Context(), `
		SELECT login, name, last_seen,
			COALESCE((SELECT seconds FROM devtime WHERE user_id = users.id AND day = $1::date), 0)
		FROM users
		WHERE last_seen IS NOT NULL AND last_seen > now() - interval '5 minutes'
		ORDER BY last_seen DESC`, day.dateKey())
	if err != nil {
		logf("online: %v", err)
		httpError(w, http.StatusInternalServerError, "online query failed")
		return
	}
	defer rows.Close()
	type entry struct {
		Login        string    `json:"login"`
		Name         string    `json:"name"`
		LastSeen     time.Time `json:"last_seen"`
		DevtimeToday int64     `json:"devtime_today"`
	}
	var out []entry
	for rows.Next() {
		var e entry
		var name sql.NullString
		if err := rows.Scan(&e.Login, &name, &e.LastSeen, &e.DevtimeToday); err != nil {
			continue
		}
		if name.Valid && name.String != "" {
			e.Name = name.String
		} else {
			e.Name = e.Login
		}
		out = append(out, e)
	}
	writeJSON(w, http.StatusOK, map[string]any{"online": out})
}

// handleUser returns a user's profile (creating the row on first sight):
//
//	GET /api/user?login=name
//
// Everything is public; there is no auth.
func (s *server) handleUser(w http.ResponseWriter, r *http.Request) {
	period := currentDayPeriod()
	login := normalizeLogin(r.URL.Query().Get("login"))
	if login == "" {
		httpError(w, http.StatusBadRequest, "missing or invalid login")
		return
	}
	u, err := getOrCreateUser(r.Context(), s.db, login)
	if err != nil {
		logf("user lookup: %v", err)
		httpError(w, http.StatusInternalServerError, "user lookup failed")
		return
	}
	today, err := devtimeToday(r.Context(), s.db, u.ID, period.dateKey())
	if err != nil {
		logf("user devtime: %v", err)
	}
	writeJSON(w, http.StatusOK, addDayPeriod(map[string]any{
		"user":          u,
		"devtime_today": today,
		"online":        isOnline(u),
	}, period))
}
