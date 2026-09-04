package main

import (
	"database/sql"
	_ "embed"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"
)

//go:embed site/index.html
var landingHTML []byte

var logger = log.New(os.Stderr, "", log.LstdFlags)

func logf(format string, args ...any) {
	logger.Printf(format, args...)
}

type config struct {
	port        string
	databaseURL string
}

func loadConfig() config {
	return config{
		port:        envOr("PORT", "8080"),
		databaseURL: os.Getenv("DATABASE_URL"),
	}
}

func (c config) validate() error {
	if c.databaseURL == "" {
		return fmt.Errorf("DATABASE_URL is required")
	}
	return nil
}

type server struct {
	db *sql.DB
}

func main() {
	cfg := loadConfig()
	if err := cfg.validate(); err != nil {
		logger.Fatalf("config error: %v", err)
	}

	db, err := openDB(cfg.databaseURL)
	if err != nil {
		logger.Fatalf("database: %v", err)
	}
	defer db.Close()

	s := &server{db: db}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/health", func(w http.ResponseWriter, r *http.Request) {
		if err := db.PingContext(r.Context()); err != nil {
			httpError(w, http.StatusServiceUnavailable, "db unavailable")
			return
		}
		// "version" distinguishes the trust-based backend from the legacy
		// authenticated one when verifying a deploy.
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "version": "trust-based"})
	})
	mux.HandleFunc("GET /api/user", s.handleUser)
	mux.HandleFunc("GET /api/online", s.handleOnline)
	mux.HandleFunc("GET /api/leaderboard", s.handleLeaderboard)
	mux.HandleFunc("GET /api/statuses", s.handleStatuses)
	mux.HandleFunc("POST /api/status", s.handleSetStatus)
	mux.HandleFunc("DELETE /api/status", s.handleClearStatus)
	mux.HandleFunc("POST /api/pulse", s.handlePulse)

	// Landing page (site/), embedded into the binary so goathud.com serves the
	// marketing site and the API from one service.
	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		w.Write(landingHTML)
	})

	handler := logRequests(mux)
	addr := ":" + cfg.port
	logf("vibecoders server listening on %s", addr)
	if err := http.ListenAndServe(addr, handler); err != nil {
		logger.Fatalf("server: %v", err)
	}
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		if r.URL.Path != "/api/pulse" {
			logf("%s %s %s", r.Method, r.URL.Path, time.Since(start).Round(time.Millisecond))
		}
	})
}

// ---- helpers ----

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func httpError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]any{"error": msg})
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
