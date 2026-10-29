package main

import (
	"bytes"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	_ "image/jpeg" // register the JPEG decoder for image.DecodeConfig/Decode
	_ "image/png"  // register the PNG decoder for image.DecodeConfig/Decode
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	// avatarMaxBytes caps the decoded image. 300 KB is plenty for a 1024px
	// JPEG and keeps a profile photo from becoming a free file host.
	avatarMaxBytes = 300 * 1024
	avatarMinSide  = 16
	avatarMaxSide  = 1024
	// avatarMaxBody bounds the JSON request body: base64 inflates by 4/3,
	// plus a little room for the "user" field and JSON framing.
	avatarMaxBody = avatarMaxBytes*4/3 + 4096
)

// avatarContentTypes maps image.DecodeConfig's format name to the content type
// we serve. Only formats listed here are accepted; the client never chooses
// the served Content-Type.
var avatarContentTypes = map[string]string{
	"png":  "image/png",
	"jpeg": "image/jpeg",
}

// decodeAvatarBase64 decodes the standard-base64 image field.
func decodeAvatarBase64(raw string) ([]byte, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, errors.New("image is required")
	}
	if base64.StdEncoding.DecodedLen(len(raw)) > avatarMaxBytes+3 {
		return nil, errors.New("image is too large")
	}
	data, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		return nil, errors.New("image is not valid base64")
	}
	return data, nil
}

// validateAvatar checks decoded image bytes against the size, format and
// dimension limits and returns the content type to serve them as. The header
// check (DecodeConfig) runs first so an oversized image is rejected before we
// spend memory decoding it; the full decode then proves the file isn't a valid
// header glued to garbage.
func validateAvatar(data []byte) (string, error) {
	if len(data) == 0 {
		return "", errors.New("image is required")
	}
	if len(data) > avatarMaxBytes {
		return "", fmt.Errorf("image is larger than %d KB", avatarMaxBytes/1024)
	}
	cfg, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return "", errors.New("image must be a PNG or JPEG")
	}
	contentType, ok := avatarContentTypes[format]
	if !ok {
		return "", errors.New("image must be a PNG or JPEG")
	}
	if cfg.Width < avatarMinSide || cfg.Height < avatarMinSide ||
		cfg.Width > avatarMaxSide || cfg.Height > avatarMaxSide {
		return "", fmt.Errorf("image must be between %d and %d pixels on each side", avatarMinSide, avatarMaxSide)
	}
	if _, _, err := image.Decode(bytes.NewReader(data)); err != nil {
		return "", errors.New("image could not be decoded")
	}
	return contentType, nil
}

// avatarURL builds the relative, cache-busted photo URL for a user, or nil
// when they have no photo (updatedAt NULL from the LEFT JOIN). The version is
// the upload time in unix seconds; the server ignores it, it only changes the
// URL so clients drop their cached copy after a new upload.
func avatarURL(login string, updatedAt sql.NullTime) *string {
	if !updatedAt.Valid {
		return nil
	}
	u := "/api/avatar?login=" + url.QueryEscape(login) +
		"&v=" + strconv.FormatInt(updatedAt.Time.Unix(), 10)
	return &u
}

// handlePutAvatar stores (or replaces) the user's profile photo:
//
//	PUT /api/avatar {"user": "name", "image": "<base64 PNG/JPEG>"}
func (s *server) handlePutAvatar(w http.ResponseWriter, r *http.Request) {
	var body struct {
		User  string `json:"user"`
		Image string `json:"image"`
	}
	if r.Body == nil {
		httpError(w, http.StatusBadRequest, "invalid avatar payload")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, avatarMaxBody)
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			httpError(w, http.StatusBadRequest, "image is too large")
			return
		}
		httpError(w, http.StatusBadRequest, "invalid avatar payload")
		return
	}
	login := normalizeLogin(body.User)
	if login == "" {
		httpError(w, http.StatusBadRequest, "missing or invalid user")
		return
	}
	data, err := decodeAvatarBase64(body.Image)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	contentType, err := validateAvatar(data)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	u, err := getOrCreateUser(r.Context(), s.db, login)
	if err != nil {
		logf("avatar: %s: user lookup: %v", login, err)
		httpError(w, http.StatusInternalServerError, "could not save avatar")
		return
	}
	// updated_at always moves forward by at least a second so two uploads in
	// the same second still produce distinct cache-busting URLs.
	var updatedAt time.Time
	if err := s.db.QueryRowContext(r.Context(), `
		INSERT INTO avatars (user_id, content_type, data, updated_at)
		VALUES ($1, $2, $3, now())
		ON CONFLICT (user_id) DO UPDATE
		SET content_type = EXCLUDED.content_type,
			data = EXCLUDED.data,
			updated_at = GREATEST(now(), avatars.updated_at + interval '1 second')
		RETURNING updated_at`, u.ID, contentType, data).Scan(&updatedAt); err != nil {
		logf("avatar: %s: upsert: %v", login, err)
		httpError(w, http.StatusInternalServerError, "could not save avatar")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":         true,
		"avatar_url": avatarURL(u.Login, sql.NullTime{Time: updatedAt, Valid: true}),
	})
}

// handleDeleteAvatar removes the user's photo. Idempotent: deleting a photo
// that doesn't exist (or for a user that doesn't exist) still succeeds.
func (s *server) handleDeleteAvatar(w http.ResponseWriter, r *http.Request) {
	var body struct {
		User string `json:"user"`
	}
	if r.Body == nil || json.NewDecoder(r.Body).Decode(&body) != nil {
		httpError(w, http.StatusBadRequest, "invalid avatar payload")
		return
	}
	login := normalizeLogin(body.User)
	if login == "" {
		httpError(w, http.StatusBadRequest, "missing or invalid user")
		return
	}
	if _, err := s.db.ExecContext(r.Context(), `
		DELETE FROM avatars
		WHERE user_id IN (SELECT id FROM users WHERE lower(login) = lower($1))`, login); err != nil {
		logf("avatar: %s: delete: %v", login, err)
		httpError(w, http.StatusInternalServerError, "could not delete avatar")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// handleGetAvatar serves the raw image bytes:
//
//	GET /api/avatar?login=name[&v=…]
//
// The stored content type was derived from the decoded format at upload time,
// and nosniff stops a browser second-guessing it.
func (s *server) handleGetAvatar(w http.ResponseWriter, r *http.Request) {
	login := normalizeLogin(r.URL.Query().Get("login"))
	if login == "" {
		httpError(w, http.StatusBadRequest, "missing or invalid login")
		return
	}
	var contentType string
	var data []byte
	err := s.db.QueryRowContext(r.Context(), `
		SELECT a.content_type, a.data
		FROM avatars a
		JOIN users u ON u.id = a.user_id
		WHERE lower(u.login) = lower($1)`, login).Scan(&contentType, &data)
	if err == sql.ErrNoRows {
		httpError(w, http.StatusNotFound, "no avatar")
		return
	}
	if err != nil {
		logf("avatar: %s: read: %v", login, err)
		httpError(w, http.StatusInternalServerError, "could not read avatar")
		return
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "public, max-age=86400")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}
