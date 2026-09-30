package main

// HTTP-layer coverage for the status and user handlers' request-validation
// paths (the reject branches that run before any database access). These are
// the first line of defence for untrusted client input, and a regression here
// (untrimmed login, oversized message, malformed JSON) would silently start
// serving garbage rows. Tested with the stdlib only — no new dependency. The
// handlers stop before touching s.db on every case, so a nil server is safe.

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestHandleSetStatusValidation(t *testing.T) {
	s := &server{} // nil db: every case below must reject before touching it.

	tests := []struct {
		name      string
		body      string
		wantError string
	}{
		{name: "malformed JSON rejected", body: `{"user": broken`, wantError: "invalid status payload"},
		{name: "empty body rejected", body: "", wantError: "invalid status payload"},
		{name: "missing user rejected", body: `{"emoji":"🏋️","message":"gym"}`, wantError: "missing or invalid user"},
		{name: "invalid user rejected", body: `{"user":"not valid!","emoji":"🏋️"}`, wantError: "missing or invalid user"},
		{name: "empty emoji and message rejected", body: `{"user":"zayd","emoji":" ","message":" "}`, wantError: "emoji or message is required"},
		{name: "message too long rejected", body: `{"user":"zayd","emoji":"🙂","message":"` + strings.Repeat("a", statusMessageLimit+1) + `"}`, wantError: "message is too long"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/api/status", strings.NewReader(tt.body))
			rec := httptest.NewRecorder()
			s.handleSetStatus(rec, req)

			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want %d", rec.Code, http.StatusBadRequest)
			}
			if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
				t.Fatalf("Content-Type = %q, want application/json", ct)
			}
			if !strings.Contains(rec.Body.String(), tt.wantError) {
				t.Fatalf("body = %q, want it to contain %q", rec.Body.String(), tt.wantError)
			}
		})
	}
}

func TestHandleClearStatusValidation(t *testing.T) {
	s := &server{}

	tests := []struct {
		name      string
		body      string
		wantError string
	}{
		{name: "malformed JSON rejected", body: `{"user": broken`, wantError: "invalid status payload"},
		{name: "missing user rejected", body: `{}`, wantError: "missing or invalid user"},
		{name: "invalid user rejected", body: `{"user":"bad name!"}`, wantError: "missing or invalid user"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodDelete, "/api/status", strings.NewReader(tt.body))
			rec := httptest.NewRecorder()
			s.handleClearStatus(rec, req)

			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want %d", rec.Code, http.StatusBadRequest)
			}
			if !strings.Contains(rec.Body.String(), tt.wantError) {
				t.Fatalf("body = %q, want it to contain %q", rec.Body.String(), tt.wantError)
			}
		})
	}
}

func TestHandleUserValidation(t *testing.T) {
	s := &server{}

	vals := func(vals map[string]string) string {
		q := url.Values{}
		for k, v := range vals {
			q.Set(k, v)
		}
		return q.Encode()
	}

	tests := []struct {
		name      string
		query     string
		wantError string
	}{
		{name: "missing login rejected", query: "", wantError: "missing or invalid login"},
		{name: "blank login rejected", query: vals(map[string]string{"login": ""}), wantError: "missing or invalid login"},
		{name: "invalid login rejected", query: vals(map[string]string{"login": "has space"}), wantError: "missing or invalid login"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/api/user?"+tt.query, nil)
			rec := httptest.NewRecorder()
			s.handleUser(rec, req)

			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want %d", rec.Code, http.StatusBadRequest)
			}
			if !strings.Contains(rec.Body.String(), tt.wantError) {
				t.Fatalf("body = %q, want it to contain %q", rec.Body.String(), tt.wantError)
			}
		})
	}
}
