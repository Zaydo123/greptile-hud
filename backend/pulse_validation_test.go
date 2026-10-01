package main

// HTTP-layer coverage for handlePulse's request-validation path (the reject
// branch that runs before any database access). The pulse endpoint is the
// app's heartbeat entry point and trusts the client's chosen username, so a
// regression here (untrimmed login, a lone "@", malformed JSON) would accept
// garbage into the devtime pipeline instead of rejecting it. Tested with the
// stdlib only — no new dependency. Every case below rejects before reaching
// s.db, so a nil server is safe.

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHandlePulseRejectsBadUserBeforeDB(t *testing.T) {
	s := &server{} // nil db: each case must reject before touching it.

	tests := []struct {
		name      string
		body      string
		wantError string
	}{
		{name: "malformed JSON rejected", body: `{"user": broken`, wantError: "missing or invalid user"},
		{name: "empty body rejected", body: "", wantError: "missing or invalid user"},
		{name: "missing user rejected", body: `{"app":"editor"}`, wantError: "missing or invalid user"},
		{name: "lone at-sign rejected", body: `{"user":"@"}`, wantError: "missing or invalid user"},
		{name: "invalid user rejected", body: `{"user":"not valid!"}`, wantError: "missing or invalid user"},
		{name: "whitespace-only user rejected", body: `{"user":"   "}`, wantError: "missing or invalid user"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/api/pulse", strings.NewReader(tt.body))
			rec := httptest.NewRecorder()
			s.handlePulse(rec, req)

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
