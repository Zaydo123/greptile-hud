package main

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const sessionCookie = "vc_session"
const stateCookie = "vc_oauth_state"
const sessionMaxAge = 30 * 24 * time.Hour

type auth struct {
	clientID     string
	clientSecret string
	redirectURL  string // empty = derive from request
	secret       []byte
}

func newAuth(clientID, clientSecret, redirectURL, sessionSecret string) *auth {
	return &auth{clientID: clientID, clientSecret: clientSecret, redirectURL: redirectURL, secret: []byte(sessionSecret)}
}

func (a *auth) sign(payload []byte) string {
	mac := hmac.New(sha256.New, a.secret)
	mac.Write(payload)
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func (a *auth) makeSessionCookie(userID int64) (*http.Cookie, error) {
	payload := strconv.FormatInt(userID, 10)
	sig := a.sign([]byte(payload))
	val := payload + "." + sig
	return &http.Cookie{
		Name:     sessionCookie,
		Value:    val,
		Path:     "/",
		MaxAge:   int(sessionMaxAge.Seconds()),
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	}, nil
}

func (a *auth) userIDFromCookie(r *http.Request) (int64, bool) {
	c, err := r.Cookie(sessionCookie)
	if err != nil {
		return 0, false
	}
	parts := strings.Split(c.Value, ".")
	if len(parts) != 2 {
		return 0, false
	}
	if !hmac.Equal([]byte(a.sign([]byte(parts[0]))), []byte(parts[1])) {
		return 0, false
	}
	id, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil || id <= 0 {
		return 0, false
	}
	return id, true
}

func (a *auth) redirectBase(r *http.Request) string {
	if a.redirectURL != "" {
		return a.redirectURL
	}
	scheme := "https"
	if strings.HasPrefix(r.Host, "localhost") && r.Header.Get("X-Forwarded-Proto") != "https" {
		scheme = "http"
	}
	return scheme + "://" + r.Host
}

// handleLogin redirects to GitHub OAuth.
func (a *auth) handleLogin(w http.ResponseWriter, r *http.Request) {
	state, err := randomHex(16)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not start login")
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name:     stateCookie,
		Value:    state,
		Path:     "/",
		MaxAge:   600,
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	})
	q := url.Values{}
	q.Set("client_id", a.clientID)
	q.Set("redirect_uri", a.redirectBase(r)+"/auth/callback")
	q.Set("scope", "read:org repo")
	q.Set("state", state)
	http.Redirect(w, r, githubAuthURL+"?"+q.Encode(), http.StatusFound)
}

func (s *server) handleCallback(w http.ResponseWriter, r *http.Request) {
	a := s.auth
	q := r.URL.Query()
	if c, err := r.Cookie(stateCookie); err != nil || c.Value != q.Get("state") {
		httpError(w, http.StatusBadRequest, "invalid OAuth state")
		return
	}
	if errMsg := q.Get("error"); errMsg != "" {
		httpError(w, http.StatusBadRequest, "github auth failed: "+errMsg)
		return
	}
	code := q.Get("code")
	if code == "" {
		httpError(w, http.StatusBadRequest, "missing authorization code")
		return
	}

	token, err := a.exchangeCode(r.Context(), code, a.redirectBase(r)+"/auth/callback")
	if err != nil {
		httpError(w, http.StatusBadGateway, "token exchange failed: "+err.Error())
		return
	}

	gh := newGHClient(token)
	var me struct {
		ID        int64  `json:"id"`
		Login     string `json:"login"`
		Name      string `json:"name"`
		AvatarURL string `json:"avatar_url"`
	}
	if err := gh.doJSON(r.Context(), http.MethodGet, "/user", nil, nil, &me); err != nil {
		httpError(w, http.StatusBadGateway, "could not fetch github user")
		return
	}
	orgs, err := gh.getOrgs(r.Context())
	if err != nil {
		logf("callback: %s: fetch orgs: %v", me.Login, err)
	}

	user, err := upsertUser(r.Context(), s.db, &User{
		GitHubID:  me.ID,
		Login:     me.Login,
		Name:      me.Name,
		AvatarURL: me.AvatarURL,
		Orgs:      orgs,
	}, token)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not save user")
		return
	}
	cookie, err := a.makeSessionCookie(user.ID)
	if err != nil {
		httpError(w, http.StatusInternalServerError, "could not create session")
		return
	}
	http.SetCookie(w, cookie)
	http.SetCookie(w, &http.Cookie{Name: stateCookie, Value: "", Path: "/", MaxAge: -1})

	// The Greptile HUD app is the frontend: hand it an API token via its
	// registered URL scheme instead of a browser redirect.
	apiToken, err := createToken(r.Context(), s.db, user.ID)
	if err != nil {
		logf("callback: %s: mint token: %v", user.Login, err)
	}
	scheme := envOr("OAUTH_REDIRECT_SCHEME", "greptilehud")
	cb := url.Values{}
	cb.Set("login", user.Login)
	if apiToken != "" {
		cb.Set("token", apiToken)
	}
	http.Redirect(w, r, scheme+"://oauth/callback?"+cb.Encode(), http.StatusFound)

	go s.syncs.syncUser(context.Background(), user)
}

func (a *auth) exchangeCode(ctx context.Context, code, redirectURI string) (string, error) {
	form := url.Values{}
	form.Set("client_id", a.clientID)
	form.Set("client_secret", a.clientSecret)
	form.Set("code", code)
	form.Set("redirect_uri", redirectURI)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, githubTokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	var out struct {
		AccessToken string `json:"access_token"`
		Error       string `json:"error"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&out); err != nil {
		return "", fmt.Errorf("decode token response: %w", err)
	}
	if out.Error != "" {
		return "", fmt.Errorf("github token error: %s", out.Error)
	}
	if out.AccessToken == "" {
		return "", fmt.Errorf("empty access token")
	}
	return out.AccessToken, nil
}

func (a *auth) handleLogout(w http.ResponseWriter, r *http.Request) {
	http.SetCookie(w, &http.Cookie{Name: sessionCookie, Value: "", Path: "/", MaxAge: -1})
	http.Error(w, "logged out", http.StatusOK)
}

func randomHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
