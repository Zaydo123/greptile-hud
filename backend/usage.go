package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"sort"
	"time"
)

const (
	// usageItemSecondsMax clamps one item: the client flushes about once a
	// minute, so ten minutes leaves room for a delayed flush without letting a
	// single item claim hours.
	usageItemSecondsMax = 600
	// usageRequestSecondsMax rejects a whole request. More than ~15 minutes of
	// usage per one-minute flush means the client is broken, and storing it
	// would only pollute the stats.
	usageRequestSecondsMax = 900
	usageMaxItems          = 64
	usageCrewTopItems      = 25
)

type usageReportItem struct {
	Key     string  `json:"key"`
	Seconds float64 `json:"seconds"`
}

// normalizeUsage applies the POST /api/usage rules to a payload and returns
// the per-key seconds to add, ordered by key (a stable order keeps the upsert
// lock order deterministic). Unknown keys fold into "other"; seconds are
// clamped to 0…600 per item (fractions truncated); zero items are dropped;
// duplicate keys (including several unknown keys folded into "other") are
// summed. More than 64 items, or a total above 900 seconds, is an error.
func normalizeUsage(items []usageReportItem) ([]usageItem, error) {
	if len(items) > usageMaxItems {
		return nil, fmt.Errorf("at most %d usage items per request", usageMaxItems)
	}
	sums := map[string]int64{}
	var total int64
	for _, item := range items {
		seconds := clampUsageSeconds(item.Seconds)
		if seconds == 0 {
			continue
		}
		sums[catalogKey(item.Key)] += seconds
		total += seconds
	}
	if total > usageRequestSecondsMax {
		return nil, fmt.Errorf("usage total exceeds %d seconds", usageRequestSecondsMax)
	}
	out := make([]usageItem, 0, len(sums))
	for key, seconds := range sums {
		out = append(out, usageItem{Key: key, Seconds: seconds})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Key < out[j].Key })
	return out, nil
}

func clampUsageSeconds(v float64) int64 {
	if math.IsNaN(v) || v <= 0 {
		return 0
	}
	if v >= usageItemSecondsMax {
		return usageItemSecondsMax
	}
	return int64(v)
}

type usageItem struct {
	Key      string `json:"key"`
	Label    string `json:"label"`
	Category string `json:"category"`
	Seconds  int64  `json:"seconds"`
	People   *int64 `json:"people,omitempty"`
}

// usageRow is one aggregated (key, seconds[, people]) row as read from SQL.
type usageRow struct {
	Key     string
	Seconds int64
	People  int64
}

// buildUsageItems turns aggregated rows into the response items: labels and
// categories from the catalog, any key no longer in the catalog folded into
// "other", sorted by seconds desc then key asc. withPeople attaches the
// distinct-user count (crew view); when rows fold together their people count
// is the max of the parts, a lower bound since the same person may appear in
// several. Returns the items and the summed total.
func buildUsageItems(rows []usageRow, withPeople bool) ([]usageItem, int64) {
	merged := map[string]*usageRow{}
	var total int64
	for _, row := range rows {
		if row.Seconds <= 0 {
			continue
		}
		key := catalogKey(row.Key)
		m := merged[key]
		if m == nil {
			m = &usageRow{Key: key}
			merged[key] = m
		}
		m.Seconds += row.Seconds
		m.People = max(m.People, row.People)
		total += row.Seconds
	}
	out := make([]usageItem, 0, len(merged))
	for key, m := range merged {
		entry := catalogLookup(key)
		item := usageItem{Key: entry.Key, Label: entry.Label, Category: entry.Category, Seconds: m.Seconds}
		if withPeople {
			people := m.People
			item.People = &people
		}
		out = append(out, item)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Seconds != out[j].Seconds {
			return out[i].Seconds > out[j].Seconds
		}
		return out[i].Key < out[j].Key
	})
	return out, total
}

// handlePostUsage records app/site usage for the current crew day:
//
//	POST /api/usage {"user": "name", "usage": [{"key": "youtube", "seconds": 55}]}
//
// Usage is not presence: this never touches last_seen.
func (s *server) handlePostUsage(w http.ResponseWriter, r *http.Request) {
	var body struct {
		User  string            `json:"user"`
		Usage []usageReportItem `json:"usage"`
	}
	if r.Body == nil || json.NewDecoder(http.MaxBytesReader(w, r.Body, 64*1024)).Decode(&body) != nil {
		httpError(w, http.StatusBadRequest, "invalid usage payload")
		return
	}
	login := normalizeLogin(body.User)
	if login == "" {
		httpError(w, http.StatusBadRequest, "missing or invalid user")
		return
	}
	items, err := normalizeUsage(body.Usage)
	if err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	if len(items) == 0 {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	u, err := getOrCreateUser(r.Context(), s.db, login)
	if err != nil {
		logf("usage: %s: user lookup: %v", login, err)
		httpError(w, http.StatusInternalServerError, "could not record usage")
		return
	}
	day := crewDayPeriod(time.Now()).dateKey()
	if err := addUsage(r.Context(), s.db, u.ID, day, items); err != nil {
		logf("usage: %s: %v", login, err)
		httpError(w, http.StatusInternalServerError, "could not record usage")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func addUsage(ctx context.Context, db *sql.DB, userID int64, day string, items []usageItem) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, item := range items {
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO app_usage (user_id, day, key, seconds)
			VALUES ($1, $2::date, $3, $4)
			ON CONFLICT (user_id, day, key) DO UPDATE
			SET seconds = app_usage.seconds + EXCLUDED.seconds`,
			userID, day, item.Key, item.Seconds); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// handleGetUsage returns one user's usage breakdown for a period:
//
//	GET /api/usage?login=name&period=today|week|month|all
func (s *server) handleGetUsage(w http.ResponseWriter, r *http.Request) {
	login := normalizeLogin(r.URL.Query().Get("login"))
	if login == "" {
		httpError(w, http.StatusBadRequest, "missing or invalid login")
		return
	}
	period, window := crewActivityPeriod(time.Now(), r.URL.Query().Get("period"))
	u, err := findUser(r.Context(), s.db, login)
	if err != nil {
		logf("usage: %s: user lookup: %v", login, err)
		httpError(w, http.StatusInternalServerError, "usage query failed")
		return
	}
	if u == nil {
		httpError(w, http.StatusNotFound, "unknown user")
		return
	}
	query := `
		SELECT key, SUM(seconds), 1
		FROM app_usage
		WHERE user_id = $1`
	args := []any{u.ID}
	if period != periodAll {
		query += ` AND day >= $2::date AND day < $3::date`
		args = append(args, window.dateKey(), window.endDateKey())
	}
	query += `
		GROUP BY key
		ORDER BY 2 DESC, key`
	rows, err := queryUsageRows(r.Context(), s.db, query, args...)
	if err != nil {
		logf("usage: %s: %v", login, err)
		httpError(w, http.StatusInternalServerError, "usage query failed")
		return
	}
	items, total := buildUsageItems(rows, false)
	response := map[string]any{
		"login":         u.Login,
		"period":        period,
		"total_seconds": total,
		"items":         items,
	}
	if period != periodAll {
		addDayPeriod(response, window)
	}
	writeJSON(w, http.StatusOK, response)
}

// handleGetCrewUsage aggregates usage across every user:
//
//	GET /api/usage/crew?period=today|week|month|all
//
// total_seconds covers every item; only the top 25 items are listed.
func (s *server) handleGetCrewUsage(w http.ResponseWriter, r *http.Request) {
	period, window := crewActivityPeriod(time.Now(), r.URL.Query().Get("period"))
	query := `
		SELECT key, SUM(seconds), COUNT(DISTINCT user_id)
		FROM app_usage`
	var args []any
	if period != periodAll {
		query += `
		WHERE day >= $1::date AND day < $2::date`
		args = append(args, window.dateKey(), window.endDateKey())
	}
	query += `
		GROUP BY key
		ORDER BY 2 DESC, key`
	rows, err := queryUsageRows(r.Context(), s.db, query, args...)
	if err != nil {
		logf("crew usage: %v", err)
		httpError(w, http.StatusInternalServerError, "usage query failed")
		return
	}
	items, total := buildUsageItems(rows, true)
	if len(items) > usageCrewTopItems {
		items = items[:usageCrewTopItems]
	}
	response := map[string]any{
		"period":        period,
		"total_seconds": total,
		"items":         items,
	}
	if period != periodAll {
		addDayPeriod(response, window)
	}
	writeJSON(w, http.StatusOK, response)
}

func queryUsageRows(ctx context.Context, db *sql.DB, query string, args ...any) ([]usageRow, error) {
	rows, err := db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []usageRow
	for rows.Next() {
		var row usageRow
		if err := rows.Scan(&row.Key, &row.Seconds, &row.People); err != nil {
			return nil, err
		}
		out = append(out, row)
	}
	return out, rows.Err()
}

// findUser looks a user up without creating one: exact login first (rides the
// plain unique index), then case-insensitively so "Zayd" finds "zayd". Returns
// nil, nil when there is no such user. Read-only endpoints use this so a typo
// in a query string can't mint a new account.
func findUser(ctx context.Context, db *sql.DB, login string) (*User, error) {
	if u, err := getUserByLogin(ctx, db, login); err != nil || u != nil {
		return u, err
	}
	u, err := scanUser(db.QueryRowContext(ctx,
		"SELECT "+userCols+" FROM users WHERE lower(login) = lower($1) ORDER BY id LIMIT 1", login))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return u, err
}
