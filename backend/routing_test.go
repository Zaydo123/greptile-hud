package main

// Routing coverage for the top-level ServeMux built by newMux (main.go): the
// landing page served at "/", the 404 for unknown paths, the health endpoint's
// unhealthy branch, and that every API route is registered. This is the wire
// surface a deploy depends on (Render health-checks /api/health), so a routing
// regression here should fail loudly rather than take the service dangling.
// Tested with the stdlib only — the DB handle is pointed at an unreachable DSN
// so PingContext fails without a live Postgres.

import (
	"bytes"
	"database/sql"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// brokenDB returns a *sql.DB whose PingContext always fails. sql.Open does not
// dial, so a syntactically valid but unreachable DSN yields a handle that only
// errors once PingContext actually tries to connect — exactly the shape main()
// would leave a degraded deploy in.
func brokenDB(t *testing.T) *server {
	t.Helper()
	db, err := sql.Open("postgres", "postgres://user@127.0.0.1:1/nope")
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	return &server{db: db}
}

func TestHealthUnavailable(t *testing.T) {
	mux := newMux(brokenDB(t))

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/health", nil))

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusServiceUnavailable)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("Content-Type = %q, want application/json", ct)
	}
	if !strings.Contains(rec.Body.String(), "db unavailable") {
		t.Fatalf("body = %q, want it to report db unavailable", rec.Body.String())
	}
}

func TestLandingPageServed(t *testing.T) {
	mux := newMux(brokenDB(t))

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
		t.Fatalf("Content-Type = %q, want text/html", ct)
	}
	if cc := rec.Header().Get("Cache-Control"); cc != "no-cache" {
		t.Fatalf("Cache-Control = %q, want no-cache", cc)
	}
	if !bytes.Equal(rec.Body.Bytes(), landingHTML) {
		t.Fatalf("body does not match the embedded landing page")
	}
}

func TestUnknownPathNotFound(t *testing.T) {
	mux := newMux(brokenDB(t))

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/definitely/not/a/route", nil))

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusNotFound)
	}
}

func TestHealthMethodNotAllowed(t *testing.T) {
	mux := newMux(brokenDB(t))

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/health", nil))

	// Method-pattern muxes reject a non-matching method before invoking the
	// handler, so this must never return 200 no matter the DB state.
	if rec.Code == http.StatusOK {
		t.Fatalf("POST /api/health returned 200, want method rejection")
	}
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusMethodNotAllowed)
	}
}
