package main

// Coverage for the database-failure path of the write handlers in
// banners.go, statuses.go, status_history.go, pulse.go, usage.go and
// avatar.go: what a degraded deployment (unreachable Postgres) returns for
// each mutating endpoint. These branches log and answer 500 with a stable
// message; a bad refactor that drops the guard would instead panic on a nil
// row / closed db and take the whole service down mid-write. Each handler is
// pointed at an unreachable DSN so the first query or exec fails
// deterministically without a live Postgres. Stdlib only — no new dependency.

import (
	"bytes"
	"encoding/base64"
	"image"
	"image/color"
	"image/png"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// validAvatarB64 is a 16x16 opaque PNG (the avatar min side) encoded as
// base64, so handlePutAvatar passes decode + format validation and reaches
// the database step.
func validAvatarB64(t *testing.T) string {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 16, 16))
	for i := 0; i < 16; i++ {
		for j := 0; j < 16; j++ {
			img.Set(i, j, color.RGBA{R: 30, G: 40, B: 60, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatalf("png.Encode: %v", err)
	}
	return base64.StdEncoding.EncodeToString(buf.Bytes())
}

func TestWriteHandlersReturn500WhenDBDown(t *testing.T) {
	s := brokenDB(t) // PingContext always fails; every case must hit the DB.

	now := time.Now().UTC()
	historySession := `{"id":"9f8c5b3a-4d2e-4f1a-9b6c-2e3d4f5a6b7c",` +
		`"emoji":"🙂","message":"hi",` +
		`"started_at":` + jsonTime(now.Add(-2*time.Hour)) + `,` +
		`"ended_at":` + jsonTime(now.Add(-time.Hour)) + `}`

	cases := []struct {
		name    string
		handler http.HandlerFunc
		method  string
		body    string
		want    string
	}{
		{"post banner", s.handlePostBanner, http.MethodPost, `{"user":"zayd","emoji":"🎂","message":"hi"}`, "could not post banner"},
		{"delete banner", s.handleDeleteBanner, http.MethodDelete, `{"user":"zayd","id":1}`, "could not remove banner"},
		{"set status", s.handleSetStatus, http.MethodPost, `{"user":"zayd","emoji":"🙂","message":"hi"}`, "could not set status"},
		{"clear status", s.handleClearStatus, http.MethodPost, `{"user":"zayd"}`, "could not clear status"},
		{"pulse", s.handlePulse, http.MethodPost, `{"user":"zayd","app":"code"}`, "could not record pulse"},
		{"post usage", s.handlePostUsage, http.MethodPost, `{"user":"zayd","usage":[{"key":"code","seconds":10}]}`, "could not record usage"},
		{"put avatar", s.handlePutAvatar, http.MethodPut, `{"user":"zayd","image":"` + validAvatarB64(t) + `"}`, "could not save avatar"},
		{"delete avatar", s.handleDeleteAvatar, http.MethodDelete, `{"user":"zayd"}`, "could not delete avatar"},
		{"post history", s.handlePostStatusHistory, http.MethodPost, `{"user":"zayd","sessions":[` + historySession + `]}`, "could not store history"},
		{"delete history", s.handleDeleteStatusHistory, http.MethodDelete, `{"user":"zayd","id":"9f8c5b3a-4d2e-4f1a-9b6c-2e3d4f5a6b7c"}`, "could not delete session"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			tc.handler(rec, httptest.NewRequest(tc.method, "/api/x", strings.NewReader(tc.body)))
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

func jsonTime(t time.Time) string {
	b, _ := t.MarshalJSON()
	return string(b)
}

// Sanity check: the avatar fixture really is a decodable PNG inside the
// size limits, so the DB-down case above is exercising the DB failure and
// not the validation path by accident.
func TestAvatarFixturePassesValidation(t *testing.T) {
	data, err := base64.StdEncoding.DecodeString(validAvatarB64(t))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	contentType, err := validateAvatar(data)
	if err != nil {
		t.Fatalf("validateAvatar: %v", err)
	}
	if contentType != "image/png" {
		t.Fatalf("contentType = %q, want image/png", contentType)
	}
	cfg, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("DecodeConfig: %v", err)
	}
	if cfg.Width != 16 || cfg.Height != 16 {
		t.Fatalf("fixture is %dx%d, want 16x16", cfg.Width, cfg.Height)
	}
}
