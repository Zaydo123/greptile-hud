package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

const githubAPI = "https://api.github.com"
const githubAuthURL = "https://github.com/login/oauth/authorize"
const githubTokenURL = "https://github.com/login/oauth/access_token"

const (
	// Stats are collected from the default branch over this window plus all time.
	syncMaxCommitsPerRepo = 500
	syncMaxReposPerOrg    = 100
	statsWindow           = 30 * 24 * time.Hour
)

type ghClient struct {
	token  string
	client *http.Client
}

func newGHClient(token string) *ghClient {
	return &ghClient{token: token, client: &http.Client{Timeout: 30 * time.Second}}
}

func (g *ghClient) doJSON(ctx context.Context, method, path string, query url.Values, body any, out any) error {
	u, err := url.Parse(githubAPI + path)
	if err != nil {
		return err
	}
	if query != nil {
		u.RawQuery = query.Encode()
	}
	var rdr io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rdr = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, u.String(), rdr)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+g.token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := g.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("github %s %s: %s", method, u.Path, strings.TrimSpace(string(data)))
	}
	if out != nil {
		if err := json.Unmarshal(data, out); err != nil {
			return fmt.Errorf("decode github response: %w", err)
		}
	}
	return nil
}

func (g *ghClient) getOrgs(ctx context.Context) ([]string, error) {
	var orgs []string
	for page := 1; ; page++ {
		var batch []struct {
			Login string `json:"login"`
		}
		if err := g.doJSON(ctx, http.MethodGet, "/user/orgs",
			url.Values{"per_page": {"100"}, "page": {fmt.Sprint(page)}}, nil, &batch); err != nil {
			return nil, err
		}
		for _, o := range batch {
			orgs = append(orgs, o.Login)
		}
		if len(batch) < 100 {
			break
		}
	}
	return orgs, nil
}

func (g *ghClient) getOrgRepos(ctx context.Context, org string) ([]string, error) {
	var repos []string
	for page := 1; page <= 10; page++ {
		var batch []struct {
			Name     string `json:"name"`
			Archived bool   `json:"archived"`
		}
		if err := g.doJSON(ctx, http.MethodGet, "/orgs/"+url.PathEscape(org)+"/repos",
			url.Values{"per_page": {"100"}, "page": {fmt.Sprint(page)}, "sort": {"pushed"}}, nil, &batch); err != nil {
			return nil, err
		}
		for _, r := range batch {
			if !r.Archived {
				repos = append(repos, r.Name)
			}
		}
		if len(batch) < 100 {
			break
		}
	}
	if len(repos) > syncMaxReposPerOrg {
		repos = repos[:syncMaxReposPerOrg]
	}
	return repos, nil
}

// ---- GraphQL commit history ----

const commitHistoryQuery = `query($owner: String!, $name: String!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    defaultBranchRef {
      target {
        ... on Commit {
          history(first: 100, after: $cursor) {
            pageInfo { hasNextPage endCursor }
            nodes {
              committedDate
              additions
              deletions
              author { user { login } name }
            }
          }
        }
      }
    }
  }
}`

type gqlCommit struct {
	CommittedDate string `json:"committedDate"`
	Additions     int    `json:"additions"`
	Deletions     int    `json:"deletions"`
	Author        struct {
		User struct {
			Login string `json:"login"`
		} `json:"user"`
		Name string `json:"name"`
	} `json:"author"`
}

func (g *ghClient) repoCommitHistory(ctx context.Context, owner, repo string, max int, emit func(c gqlCommit) bool) error {
	cursor := ""
	fetched := 0
	for {
		variables := map[string]string{"owner": owner, "name": repo}
		// GitHub rejects an explicit empty cursor ("... does not appear to be a
		// valid cursor"), so omit it until we have a real page cursor.
		if cursor != "" {
			variables["cursor"] = cursor
		}
		payload := map[string]any{
			"query":     commitHistoryQuery,
			"variables": variables,
		}
		body, err := json.Marshal(payload)
		if err != nil {
			return err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, githubAPI+"/graphql", bytes.NewReader(body))
		if err != nil {
			return err
		}
		req.Header.Set("Authorization", "Bearer "+g.token)
		req.Header.Set("Content-Type", "application/json")
		resp, err := g.client.Do(req)
		if err != nil {
			return err
		}
		data, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
		resp.Body.Close()
		if err != nil {
			return err
		}
		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("graphql %s/%s: %s", owner, repo, strings.TrimSpace(string(data)))
		}
		var out struct {
			Data struct {
				Repository struct {
					DefaultBranchRef struct {
						Target struct {
							History struct {
								PageInfo struct {
									HasNextPage bool   `json:"hasNextPage"`
									EndCursor   string `json:"endCursor"`
								} `json:"pageInfo"`
								Nodes []gqlCommit `json:"nodes"`
							} `json:"history"`
						} `json:"target"`
					} `json:"defaultBranchRef"`
				} `json:"repository"`
			} `json:"data"`
			Errors []struct {
				Message string `json:"message"`
			} `json:"errors"`
		}
		if err := json.Unmarshal(data, &out); err != nil {
			return fmt.Errorf("decode graphql response: %w", err)
		}
		if len(out.Errors) > 0 {
			return fmt.Errorf("graphql error: %s", out.Errors[0].Message)
		}
		nodes := out.Data.Repository.DefaultBranchRef.Target.History.Nodes
		for _, c := range nodes {
			if !emit(c) {
				return nil
			}
		}
		fetched += len(nodes)
		if !out.Data.Repository.DefaultBranchRef.Target.History.PageInfo.HasNextPage || fetched >= max {
			return nil
		}
		cursor = out.Data.Repository.DefaultBranchRef.Target.History.PageInfo.EndCursor
	}
}

// ---- PR counts via search ----

var (
	searchMu   sync.Mutex
	lastSearch time.Time
)

// paceSearch enforces a minimum 2s gap between GitHub search API calls, globally
// across concurrent syncs, to stay under the 30/min search rate limit.
func (g *ghClient) paceSearch() {
	searchMu.Lock()
	defer searchMu.Unlock()
	if d := 2*time.Second - time.Since(lastSearch); d > 0 {
		time.Sleep(d)
	}
	lastSearch = time.Now()
}

func (g *ghClient) mergedPRCount(ctx context.Context, org, login string, since time.Time) (int64, error) {
	g.paceSearch()
	q := fmt.Sprintf("org:%s is:pr author:%s is:merged", org, login)
	if !since.IsZero() {
		q += " merged:>=" + since.Format("2006-01-02")
	}
	var out struct {
		TotalCount int64 `json:"total_count"`
	}
	err := g.doJSON(ctx, http.MethodGet, "/search/issues",
		url.Values{"q": {q}, "per_page": {"1"}}, nil, &out)
	return out.TotalCount, err
}

// ---- org helpers ----

func parseOrgs(s string) []string {
	var orgs []string
	if err := json.Unmarshal([]byte(s), &orgs); err != nil {
		return nil
	}
	return orgs
}

func marshalOrgs(orgs []string) string {
	if orgs == nil {
		orgs = []string{}
	}
	b, _ := json.Marshal(orgs)
	return string(b)
}

// ---- sync ----

type syncManager struct {
	db      *sql.DB
	orgs    map[string]bool // optional filter; nil = all orgs
	mu      sync.Mutex
	running map[int64]bool
}

func newSyncManager(db *sql.DB, orgFilter []string) *syncManager {
	m := &syncManager{db: db, running: map[int64]bool{}}
	if len(orgFilter) > 0 {
		m.orgs = map[string]bool{}
		for _, o := range orgFilter {
			m.orgs[strings.TrimSpace(o)] = true
		}
	}
	return m
}

func (m *syncManager) syncUser(ctx context.Context, u *User) {
	if !m.begin(u.ID) {
		return
	}
	defer m.end(u.ID)

	var accessToken string
	if err := m.db.QueryRowContext(ctx,
		"SELECT access_token FROM users WHERE id = $1", u.ID).Scan(&accessToken); err != nil {
		logf("sync: %s: load token: %v", u.Login, err)
		return
	}

	logf("sync: starting for %s", u.Login)
	gh := newGHClient(accessToken)
	var me struct {
		ID        int64  `json:"id"`
		Login     string `json:"login"`
		Name      string `json:"name"`
		AvatarURL string `json:"avatar_url"`
	}
	if err := gh.doJSON(ctx, http.MethodGet, "/user", nil, nil, &me); err != nil {
		logf("sync: %s: fetch profile: %v", u.Login, err)
	} else if err := updateUserProfile(ctx, m.db, u.ID, me.Name, me.AvatarURL); err != nil {
		logf("sync: %s: save profile: %v", u.Login, err)
	}
	orgs, err := gh.getOrgs(ctx)
	if err != nil {
		logf("sync: %s: get orgs: %v", u.Login, err)
		return
	}
	if m.orgs != nil {
		var kept []string
		for _, o := range orgs {
			if m.orgs[o] {
				kept = append(kept, o)
			}
		}
		orgs = kept
	}
	if err := m.updateUserOrgs(ctx, u.ID, orgs); err != nil {
		logf("sync: %s: save orgs: %v", u.Login, err)
		return
	}

	var st Stats
	since := time.Now().UTC().Add(-statsWindow)
	matches := func(login string, c gqlCommit) bool {
		return strings.EqualFold(login, u.Login) || strings.EqualFold(c.Author.Name, u.Login)
	}

	var pairs [][2]string
	seen := map[string]bool{}
	for _, org := range orgs {
		repos, err := gh.getOrgRepos(ctx, org)
		if err != nil {
			logf("sync: %s: repos for %s: %v", u.Login, org, err)
			continue
		}
		for _, repo := range repos {
			key := org + "/" + repo
			if seen[key] {
				continue
			}
			seen[key] = true
			pairs = append(pairs, [2]string{org, repo})
		}
	}

	var computedAny bool
	for _, p := range pairs {
		org, repo := p[0], p[1]
		err := gh.repoCommitHistory(ctx, org, repo, syncMaxCommitsPerRepo, func(c gqlCommit) bool {
			if !matches(u.Login, c) {
				return true
			}
			st.CommitsAll++
			st.LOCAll += int64(c.Additions)
			if t, err := time.Parse(time.RFC3339, c.CommittedDate); err == nil && t.After(since) {
				st.Commits30D++
				st.LOC30D += int64(c.Additions)
			}
			return true
		})
		if err != nil {
			logf("sync: %s: history for %s/%s: %v", u.Login, org, repo, err)
			continue
		}
		computedAny = true
	}

	for _, org := range orgs {
		if all, err := gh.mergedPRCount(ctx, org, u.Login, time.Time{}); err == nil {
			st.PRsAll += all
			computedAny = true
		} else {
			logf("sync: %s: pr count for %s: %v", u.Login, org, err)
		}
		if recent, err := gh.mergedPRCount(ctx, org, u.Login, since); err == nil {
			st.PRs30D += recent
			computedAny = true
		} else {
			logf("sync: %s: pr count 30d for %s: %v", u.Login, org, err)
		}
	}

	if !computedAny {
		logf("sync: %s: no data computed, skipping stats save", u.Login)
		return
	}
	if err := saveStats(ctx, m.db, u.ID, st); err != nil {
		logf("sync: %s: save stats: %v", u.Login, err)
		return
	}
	if err := setUserSyncTime(ctx, m.db, u.ID); err != nil {
		logf("sync: %s: set sync time: %v", u.Login, err)
		return
	}
	logf("sync: %s done: commits=%d (30d %d) loc=%d (30d %d) prs=%d (30d %d)",
		u.Login, st.CommitsAll, st.Commits30D, st.LOCAll, st.LOC30D, st.PRsAll, st.PRs30D)
}

func (m *syncManager) updateUserOrgs(ctx context.Context, userID int64, orgs []string) error {
	_, err := m.db.ExecContext(ctx,
		"UPDATE users SET orgs = $2, updated_at = now() WHERE id = $1", userID, marshalOrgs(orgs))
	return err
}

func (m *syncManager) begin(userID int64) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.running[userID] {
		return false
	}
	m.running[userID] = true
	return true
}

func (m *syncManager) end(userID int64) {
	m.mu.Lock()
	delete(m.running, userID)
	m.mu.Unlock()
}

// syncAll runs a sync for every registered user. Returns immediately; runs in background.
func (m *syncManager) syncAll() {
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Hour)
	defer cancel()
	users, err := allUsers(ctx, m.db)
	if err != nil {
		logf("sync: list users: %v", err)
		return
	}
	for _, u := range users {
		m.syncUser(ctx, u)
	}
}

// runPeriodicSync blocks; call from a goroutine.
func (m *syncManager) runPeriodicSync(interval time.Duration) {
	for range time.Tick(interval) {
		go m.syncAll()
	}
}
