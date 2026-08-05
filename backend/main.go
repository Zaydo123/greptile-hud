package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

var logger = log.New(os.Stderr, "", log.LstdFlags)

func logf(format string, args ...any) {
	logger.Printf(format, args...)
}

type config struct {
	port           string
	databaseURL    string
	githubClientID string
	githubSecret   string
	redirectURL    string
	sessionSecret  string
	orgFilter      []string
}

func loadConfig() config {
	return config{
		port:           envOr("PORT", "8080"),
		databaseURL:    os.Getenv("DATABASE_URL"),
		githubClientID: os.Getenv("GITHUB_CLIENT_ID"),
		githubSecret:   os.Getenv("GITHUB_CLIENT_SECRET"),
		redirectURL:    os.Getenv("GITHUB_REDIRECT_URL"),
		sessionSecret:  os.Getenv("SESSION_SECRET"),
		orgFilter:      splitCSV(os.Getenv("GITHUB_ORGS")),
	}
}

func (c config) validate() error {
	switch {
	case c.databaseURL == "":
		return fmt.Errorf("DATABASE_URL is required")
	case c.githubClientID == "":
		return fmt.Errorf("GITHUB_CLIENT_ID is required")
	case c.githubSecret == "":
		return fmt.Errorf("GITHUB_CLIENT_SECRET is required")
	case c.sessionSecret == "":
		return fmt.Errorf("SESSION_SECRET is required")
	}
	return nil
}

type server struct {
	db    *sql.DB
	auth  *auth
	syncs *syncManager
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

	s := &server{
		db:    db,
		auth:  newAuth(cfg.githubClientID, cfg.githubSecret, cfg.redirectURL, cfg.sessionSecret),
		syncs: newSyncManager(db, cfg.orgFilter),
	}

	go s.syncs.runPeriodicSync(6 * time.Hour)
	go s.syncs.syncAll() // refresh stats for existing users on boot

	mux := http.NewServeMux()
	mux.HandleFunc("GET /auth/login", s.auth.handleLogin)
	mux.HandleFunc("GET /auth/callback", s.handleCallback)
	mux.HandleFunc("GET /auth/logout", s.auth.handleLogout)

	mux.HandleFunc("GET /api/health", func(w http.ResponseWriter, r *http.Request) {
		if err := db.PingContext(r.Context()); err != nil {
			httpError(w, http.StatusServiceUnavailable, "db unavailable")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	})
	mux.HandleFunc("GET /api/me", s.handleMe)
	mux.HandleFunc("GET /api/online", s.handleOnline)
	mux.HandleFunc("GET /api/leaderboard", s.handleLeaderboard)
	mux.HandleFunc("GET /api/profile/", s.handleProfile)
	mux.HandleFunc("POST /api/pulse", s.handlePulse)
	mux.HandleFunc("POST /api/sync", s.handleSync)
	mux.HandleFunc("GET /api/tokens", s.handleListTokens)
	mux.HandleFunc("POST /api/tokens", s.handleCreateToken)
	mux.HandleFunc("DELETE /api/tokens/", s.handleDeleteToken)

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

// handleSync triggers a background GitHub sync for the current user.
func (s *server) handleSync(w http.ResponseWriter, r *http.Request) {
	user, ok := s.currentUser(r)
	if !ok {
		httpError(w, http.StatusUnauthorized, "not authenticated")
		return
	}
	go s.syncs.syncUser(r.Context(), user)
	writeJSON(w, http.StatusAccepted, map[string]any{
		"ok":           true,
		"sync_started": true,
	})
}

// ---- API tokens ----

func (s *server) handleListTokens(w http.ResponseWriter, r *http.Request) {
	user, ok := s.currentUser(r)
	if !ok {
		httpError(w, http.StatusUnauthorized, "not authenticated")
		return
	}
	tokens, err := tokensForUser(r.Context(), s.db, user.ID)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not list tokens")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"api_tokens": tokens})
}

func (s *server) handleCreateToken(w http.ResponseWriter, r *http.Request) {
	user, ok := s.currentUser(r)
	if !ok {
		httpError(w, http.StatusUnauthorized, "not authenticated")
		return
	}
	token, err := createToken(r.Context(), s.db, user.ID)
	if err != nil {
		logf("create token: %v", err)
		httpError(w, http.StatusInternalServerError, "could not create token")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"token": token})
}

func (s *server) handleDeleteToken(w http.ResponseWriter, r *http.Request) {
	user, ok := s.currentUser(r)
	if !ok {
		httpError(w, http.StatusUnauthorized, "not authenticated")
		return
	}
	token := strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/tokens/"), "/")
	if err := deleteToken(r.Context(), s.db, user.ID, token); err != nil {
		httpError(w, http.StatusInternalServerError, "could not delete token")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
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

func splitCSV(s string) []string {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	var out []string
	for _, part := range strings.Split(s, ",") {
		if p := strings.TrimSpace(part); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func nullIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}
