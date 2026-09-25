package main

// logRequests silently drops heartbeats from the access log so a devtime
// pulse every few seconds does not flood stderr, while every other request is
// logged with method, path, and duration. The middleware's whole reason for
// existing is that pulse suppression, so it deserves its own test that
// captures the actual log output rather than only the passthrough path.

import (
	"bytes"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestLogRequestsSuppressesPulse(t *testing.T) {
	var buf bytes.Buffer
	orig := logger
	logger = log.New(&buf, "", 0)
	defer func() { logger = orig }()

	h := logRequests(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	// A /api/pulse heartbeat must never be written to the log.
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/pulse", nil))
	if buf.Len() != 0 {
		t.Fatalf("pulse request was logged, want suppression; got %q", buf.String())
	}

	// A normal request is logged with method and path.
	buf.Reset()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/health", nil))
	line := buf.String()
	if line == "" {
		t.Fatal("non-pulse request was not logged")
	}
	if !strings.Contains(line, "GET") || !strings.Contains(line, "/api/health") {
		t.Fatalf("log line = %q, want method and path present", line)
	}
}
