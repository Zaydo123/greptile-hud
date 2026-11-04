package main

// Coverage for crew banners (banners.go): the pure validation and lifetime
// rules, the handlers' reject paths (which run before any database access, so
// a nil server is safe), the routes, and lockstep pins on the inline SQL —
// the per-author cap, the expiry filter, the result cap and the delete
// permission rule are all literals a careless edit could drop silently.
// Stdlib only — no new dependency.

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func TestNormalizeBanner(t *testing.T) {
	in, err := normalizeBanner(" @Alice ", " 🎂 ", "  Happy birthday!  ", 0)
	if err != nil {
		t.Fatalf("normalizeBanner: %v", err)
	}
	if in.to != "Alice" || in.emoji != "🎂" || in.message != "Happy birthday!" || in.ttl != 24*time.Hour {
		t.Fatalf("normalizeBanner = %+v, want trimmed fields and a 24h ttl", in)
	}

	crew, err := normalizeBanner("", "", "Ship day 🚀", 0)
	if err != nil || crew.to != "" {
		t.Fatalf("crew-wide banner = %+v, %v; want no recipient and no error", crew, err)
	}

	for _, tt := range []struct {
		name, to, emoji, message, want string
	}{
		{"empty message", "alice", "🎂", "   ", "message is required"},
		{"long message", "alice", "🎂", strings.Repeat("a", bannerMessageLimit+1), "message is too long"},
		{"long emoji", "alice", strings.Repeat("x", bannerEmojiByteMax+1), "hi", "emoji is too long"},
		{"bad recipient", "not valid!", "🎂", "hi", "invalid recipient"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := normalizeBanner(tt.to, tt.emoji, tt.message, 0); err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("err = %v, want %q", err, tt.want)
			}
		})
	}

	// Exactly at the limit (counted in runes, not bytes) is accepted.
	if _, err := normalizeBanner("", "", strings.Repeat("🎉", bannerMessageLimit), 0); err != nil {
		t.Fatalf("message at the rune limit rejected: %v", err)
	}
}

func TestBannerTTL(t *testing.T) {
	for hours, want := range map[int]time.Duration{
		-5:  24 * time.Hour,
		0:   24 * time.Hour,
		1:   time.Hour,
		48:  48 * time.Hour,
		72:  72 * time.Hour,
		500: 72 * time.Hour,
	} {
		if got := bannerTTL(hours); got != want {
			t.Errorf("bannerTTL(%d) = %v, want %v", hours, got, want)
		}
	}
}

func TestBannerHandlersRejectBadInput(t *testing.T) {
	s := &server{} // nil db: every case must reject before touching it.
	for _, tt := range []struct {
		name    string
		handler http.HandlerFunc
		method  string
		body    string
		want    string
	}{
		{"post bad json", s.handlePostBanner, http.MethodPost, `{`, "invalid banner payload"},
		{"post bad user", s.handlePostBanner, http.MethodPost, `{"user":"bad name","message":"hi"}`, "missing or invalid user"},
		{"post no message", s.handlePostBanner, http.MethodPost, `{"user":"zayd","to":"alice","emoji":"🎂"}`, "message is required"},
		{"post bad recipient", s.handlePostBanner, http.MethodPost, `{"user":"zayd","to":"no way!","message":"hi"}`, "invalid recipient"},
		{"delete bad json", s.handleDeleteBanner, http.MethodDelete, `nope`, "invalid banner payload"},
		{"delete bad user", s.handleDeleteBanner, http.MethodDelete, `{"user":"","id":1}`, "missing or invalid user"},
		{"delete no id", s.handleDeleteBanner, http.MethodDelete, `{"user":"zayd"}`, "missing banner id"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			tt.handler(rec, httptest.NewRequest(tt.method, "/api/banner", strings.NewReader(tt.body)))
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400", rec.Code)
			}
			if !strings.Contains(rec.Body.String(), tt.want) {
				t.Fatalf("body = %q, want it to contain %q", rec.Body.String(), tt.want)
			}
		})
	}
}

func TestBannerRoutesRegistered(t *testing.T) {
	mux := newMux(brokenDB(t))
	for _, route := range []struct{ method, path string }{
		{http.MethodGet, "/api/banners"},
		{http.MethodPost, "/api/banner"},
		{http.MethodDelete, "/api/banner"},
	} {
		req := httptest.NewRequest(route.method, route.path, nil)
		if _, pattern := mux.Handler(req); pattern == "" {
			t.Errorf("%s %s is not routed", route.method, route.path)
		}
	}
}

func bannerSource(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile("banners.go")
	if err != nil {
		t.Fatalf("read banners.go: %v", err)
	}
	return string(raw)
}

func TestBannerSQLLockstep(t *testing.T) {
	src := bannerSource(t)
	for name, needle := range map[string]string{
		// The cap must live inside the INSERT (atomic), counting only live banners.
		"per-author cap in the insert": "WHERE (SELECT count(*) FROM banners WHERE author_id = $1 AND expires_at > $5) < $7",
		// Expired banners never reach a HUD.
		"list filters expired": "WHERE b.expires_at > now()",
		// The feed is bounded.
		"list is capped": "LIMIT 20",
		// Only the author or the recipient may take a banner down, matched
		// case-insensitively like every other identity check.
		"delete is author-or-recipient": "(lower(au.login) = lower($2) OR lower(b.to_login) = lower($2))",
		// Recipient lookups are case-insensitive so "Alice" finds "alice".
		"recipient join is case-insensitive": "LEFT JOIN users tu ON lower(tu.login) = lower(b.to_login)",
	} {
		if !strings.Contains(src, needle) {
			t.Errorf("banners.go lost the %s: %q", name, needle)
		}
	}
	if got := strings.Count(src, "LIMIT 20"); got != 1 {
		t.Errorf("banners.go contains LIMIT 20 %d times, want exactly 1", got)
	}
}
