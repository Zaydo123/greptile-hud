package main

// Unit coverage for the shared HTTP/config helpers in main.go. These sit
// between every handler and the wire, so a regression here (wrong status,
// wrong content type, missing error key) breaks every endpoint. Tested with
// the stdlib only — no new dependency.

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestEnvOr(t *testing.T) {
	t.Setenv("GHTEST_PRESENT", "set-via-env")
	t.Setenv("GHTEST_BLANK", "")

	cases := []struct {
		name     string
		key      string
		fallback string
		want     string
	}{
		{name: "returns value when set", key: "GHTEST_PRESENT", fallback: "fb", want: "set-via-env"},
		{name: "falls back when unset", key: "GHTEST_MISSING", fallback: "fb", want: "fb"},
		{name: "blank counts as unset", key: "GHTEST_BLANK", fallback: "fb", want: "fb"},
	}
	for _, tt := range cases {
		t.Run(tt.name, func(t *testing.T) {
			if got := envOr(tt.key, tt.fallback); got != tt.want {
				t.Fatalf("envOr(%q) = %q, want %q", tt.key, got, tt.want)
			}
		})
	}
}

func TestConfigValidate(t *testing.T) {
	t.Run("missing DATABASE_URL is an error", func(t *testing.T) {
		c := config{databaseURL: ""}
		if err := c.validate(); err == nil {
			t.Fatal("validate() = nil, want error")
		}
	})
	t.Run("present DATABASE_URL passes", func(t *testing.T) {
		c := config{databaseURL: "postgres://x"}
		if err := c.validate(); err != nil {
			t.Fatalf("validate() = %v, want nil", err)
		}
	})
}

func TestWriteJSON(t *testing.T) {
	rec := httptest.NewRecorder()
	writeJSON(rec, http.StatusCreated, map[string]any{"ok": true, "n": int64(7)})

	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusCreated)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("Content-Type = %q, want application/json", ct)
	}
	body := strings.TrimSpace(rec.Body.String())
	if body != `{"n":7,"ok":true}` {
		t.Fatalf("body = %q, want %q", body, `{"n":7,"ok":true}`)
	}
}

func TestHTTPError(t *testing.T) {
	rec := httptest.NewRecorder()
	httpError(rec, http.StatusBadRequest, "nope")

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusBadRequest)
	}
	body := strings.TrimSpace(rec.Body.String())
	if body != `{"error":"nope"}` {
		t.Fatalf("body = %q, want %q", body, `{"error":"nope"}`)
	}
}

func TestLogRequests(t *testing.T) {
	var called bool
	h := logRequests(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusTeapot)
	}))

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/health", nil)
	h.ServeHTTP(rec, req)

	if !called {
		t.Fatal("inner handler was not invoked")
	}
	if rec.Code != http.StatusTeapot {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusTeapot)
	}
}
