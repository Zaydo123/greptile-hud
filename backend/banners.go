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

// Crew banners are short, time-boxed shout-outs — "🎂 Happy birthday!" for a
// crew member — shown across the top of everyone's HUD until they expire.
// Identity is trust-based like the rest of the API, so the guard rails are
// structural rather than permission-based: a bounded message, a hard expiry,
// and a cap on how many live banners one author can have at once.
const (
	bannerMessageLimit = 120
	bannerEmojiByteMax = 32
	bannerDefaultHours = 24
	bannerMaxHours     = 72
	// bannerActivePerAuthor caps live banners per author so one name can't
	// flood every HUD; a fourth is rejected until one expires or is removed.
	bannerActivePerAuthor = 3
)

type crewBanner struct {
	ID          int64     `json:"id"`
	Author      string    `json:"author"`
	AuthorName  string    `json:"author_name"`
	To          *string   `json:"to"`
	ToName      *string   `json:"to_name"`
	ToAvatarURL *string   `json:"to_avatar_url"`
	Emoji       string    `json:"emoji"`
	Message     string    `json:"message"`
	CreatedAt   time.Time `json:"created_at"`
	ExpiresAt   time.Time `json:"expires_at"`
}

type bannerRequest struct {
	User    string `json:"user"`
	To      string `json:"to"`
	Emoji   string `json:"emoji"`
	Message string `json:"message"`
	Hours   int    `json:"hours"`
}

type bannerInput struct {
	to      string // "" when the banner is for the whole crew
	emoji   string
	message string
	ttl     time.Duration
}

// normalizeBanner validates the client-supplied banner fields. The message is
// required (a lone emoji isn't much of a shout-out); the recipient is optional
// but, when given, must be a valid login so the HUD can link it to a profile.
func normalizeBanner(to, emoji, message string, hours int) (bannerInput, error) {
	var in bannerInput
	if strings.TrimSpace(to) != "" {
		in.to = normalizeLogin(to)
		if in.to == "" {
			return in, fmt.Errorf("invalid recipient")
		}
	}
	in.emoji = strings.TrimSpace(emoji)
	if len(in.emoji) > bannerEmojiByteMax || !utf8.ValidString(in.emoji) {
		return in, fmt.Errorf("emoji is too long")
	}
	in.message = strings.TrimSpace(message)
	if in.message == "" {
		return in, fmt.Errorf("message is required")
	}
	if !utf8.ValidString(in.message) || utf8.RuneCountInString(in.message) > bannerMessageLimit {
		return in, fmt.Errorf("message is too long")
	}
	in.ttl = bannerTTL(hours)
	return in, nil
}

// bannerTTL turns the requested lifetime into a duration: 0 (unset) means a
// day, anything else is clamped to 1–72 hours.
func bannerTTL(hours int) time.Duration {
	switch {
	case hours <= 0:
		hours = bannerDefaultHours
	case hours > bannerMaxHours:
		hours = bannerMaxHours
	}
	return time.Duration(hours) * time.Hour
}

// handlePostBanner publishes a banner:
//
//	POST /api/banner {"user", "to", "emoji", "message", "hours"}
func (s *server) handlePostBanner(w http.ResponseWriter, r *http.Request) {
	var body bannerRequest
	if r.Body == nil || json.NewDecoder(r.Body).Decode(&body) != nil {
		httpError(w, http.StatusBadRequest, "invalid banner payload")
		return
	}
	login := normalizeLogin(body.User)
	if login == "" {
		httpError(w, http.StatusBadRequest, "missing or invalid user")
		return
	}
	in, err := normalizeBanner(body.To, body.Emoji, body.Message, body.Hours)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	u, err := getOrCreateUser(r.Context(), s.db, login)
	if err != nil {
		logf("banner: %s: user lookup: %v", login, err)
		httpError(w, http.StatusInternalServerError, "could not post banner")
		return
	}

	now := time.Now().UTC()
	var to sql.NullString
	if in.to != "" {
		to = sql.NullString{String: in.to, Valid: true}
	}
	// The per-author cap is checked in the INSERT itself, so two quick posts
	// can't both slip past a separate count-then-insert.
	var id int64
	err = s.db.QueryRowContext(r.Context(), `
		INSERT INTO banners (author_id, to_login, emoji, message, created_at, expires_at)
		SELECT $1, $2, $3, $4, $5, $6
		WHERE (SELECT count(*) FROM banners WHERE author_id = $1 AND expires_at > $5) < $7
		RETURNING id`,
		u.ID, to, in.emoji, in.message, now, now.Add(in.ttl), bannerActivePerAuthor).Scan(&id)
	if err == sql.ErrNoRows {
		httpError(w, http.StatusTooManyRequests,
			fmt.Sprintf("you already have %d live banners — remove one first", bannerActivePerAuthor))
		return
	}
	if err != nil {
		logf("banner: %s: insert: %v", login, err)
		httpError(w, http.StatusInternalServerError, "could not post banner")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "id": id})
}

// handleBanners lists live banners, newest first.
func (s *server) handleBanners(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.QueryContext(r.Context(), `
		SELECT b.id, au.login, au.name, b.to_login, tu.login, tu.name, ta.updated_at,
			b.emoji, b.message, b.created_at, b.expires_at
		FROM banners b
		JOIN users au ON au.id = b.author_id
		LEFT JOIN users tu ON lower(tu.login) = lower(b.to_login)
		LEFT JOIN avatars ta ON ta.user_id = tu.id
		WHERE b.expires_at > now()
		ORDER BY b.created_at DESC, b.id DESC
		LIMIT 20`)
	if err != nil {
		logf("banners: %v", err)
		httpError(w, http.StatusInternalServerError, "banner query failed")
		return
	}
	defer rows.Close()

	out := make([]crewBanner, 0)
	for rows.Next() {
		var b crewBanner
		var authorName, toLogin, toUserLogin, toName sql.NullString
		var toAvatarAt sql.NullTime
		if err := rows.Scan(&b.ID, &b.Author, &authorName, &toLogin, &toUserLogin, &toName,
			&toAvatarAt, &b.Emoji, &b.Message, &b.CreatedAt, &b.ExpiresAt); err != nil {
			logf("banners scan: %v", err)
			continue
		}
		b.AuthorName = displayName(b.Author, authorName.String)
		if toLogin.Valid && toLogin.String != "" {
			// Prefer the recipient's canonical casing once they've joined.
			login := toLogin.String
			if toUserLogin.Valid {
				login = toUserLogin.String
			}
			name := displayName(login, toName.String)
			b.To, b.ToName = &login, &name
			b.ToAvatarURL = avatarURL(login, toAvatarAt)
		}
		out = append(out, b)
	}
	if err := rows.Err(); err != nil {
		logf("banners rows: %v", err)
		httpError(w, http.StatusInternalServerError, "banner query failed")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"banners": out})
}

// handleDeleteBanner takes a banner down for everyone. Its author can remove
// it, and so can its recipient — nobody should be stuck with a shout-out on
// every crew HUD that they didn't want.
//
//	DELETE /api/banner {"user", "id"}
func (s *server) handleDeleteBanner(w http.ResponseWriter, r *http.Request) {
	var body struct {
		User string `json:"user"`
		ID   int64  `json:"id"`
	}
	if r.Body == nil || json.NewDecoder(r.Body).Decode(&body) != nil {
		httpError(w, http.StatusBadRequest, "invalid banner payload")
		return
	}
	login := normalizeLogin(body.User)
	if login == "" {
		httpError(w, http.StatusBadRequest, "missing or invalid user")
		return
	}
	if body.ID <= 0 {
		httpError(w, http.StatusBadRequest, "missing banner id")
		return
	}
	res, err := s.db.ExecContext(r.Context(), `
		DELETE FROM banners b
		USING users au
		WHERE b.id = $1 AND au.id = b.author_id
			AND (lower(au.login) = lower($2) OR lower(b.to_login) = lower($2))`,
		body.ID, login)
	if err != nil {
		logf("banner: %s: delete %d: %v", login, body.ID, err)
		httpError(w, http.StatusInternalServerError, "could not remove banner")
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		httpError(w, http.StatusNotFound, "banner not found or not yours")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
