package main

// Pure-logic coverage for the avatar, app-usage, status-history and richer
// /api/user features: the catalog contract, usage payload rules, avatar
// validation, history session validation, the dense daily series and activity
// clipping. Everything here runs without Postgres; handler cases stop at
// validation before touching s.db, so a nil db is safe. Stdlib only.

import (
	"bytes"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/color"
	"image/gif"
	"image/jpeg"
	"image/png"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// ---- catalog ----

func TestCatalogKeysUniqueAndComplete(t *testing.T) {
	// The catalog is part of the contract with the macOS client: 123 keys,
	// each unique, each with a label and category, and "other" present.
	if got := len(usageCatalog); got != 123 {
		t.Fatalf("usageCatalog has %d entries, want 123 (the contract's set)", got)
	}
	if len(usageCatalogByKey) != len(usageCatalog) {
		t.Fatalf("usageCatalog has duplicate keys: %d entries, %d unique", len(usageCatalog), len(usageCatalogByKey))
	}
	for _, e := range usageCatalog {
		if e.Key == "" || e.Label == "" || e.Category == "" {
			t.Errorf("incomplete catalog entry %+v", e)
		}
		if e.Key != strings.ToLower(e.Key) {
			t.Errorf("catalog key %q must be lowercase", e.Key)
		}
	}
	other := usageCatalogByKey[usageOtherKey]
	if other.Label != "Other" || other.Category != "Other" {
		t.Fatalf("other entry = %+v, want label/category Other", other)
	}
	for key, want := range map[string]catalogEntry{
		"youtube":    {Key: "youtube", Label: "YouTube", Category: "Video"},
		"jetbrains":  {Key: "jetbrains", Label: "JetBrains IDEs", Category: "Dev"},
		"disneyplus": {Key: "disneyplus", Label: "Disney+", Category: "Video"},
		"chess":      {Key: "chess", Label: "Chess.com", Category: "Games"},
		"goathud":    {Key: "goathud", Label: "GOAT HUD", Category: "Crew"},
		"x":          {Key: "x", Label: "X", Category: "Social"},
	} {
		if got := usageCatalogByKey[key]; got != want {
			t.Errorf("catalog[%q] = %+v, want %+v", key, got, want)
		}
	}
}

func TestCatalogKeyFoldsUnknownIntoOther(t *testing.T) {
	cases := map[string]string{
		"youtube":            "youtube",
		"other":              "other",
		"":                   "other",
		"YouTube":            "other", // keys are exact lowercase catalog keys
		"com.secret.app":     "other",
		"https://example.ai": "other",
	}
	for in, want := range cases {
		if got := catalogKey(in); got != want {
			t.Errorf("catalogKey(%q) = %q, want %q", in, got, want)
		}
	}
	if got := catalogLookup("nope"); got.Key != "other" {
		t.Errorf("catalogLookup(unknown) = %+v, want other", got)
	}
}

// ---- usage ----

func TestNormalizeUsage(t *testing.T) {
	got, err := normalizeUsage([]usageReportItem{
		{Key: "youtube", Seconds: 30},
		{Key: "youtube", Seconds: 25.9}, // fraction truncated, duplicate summed
		{Key: "secret-app", Seconds: 5}, // unknown folds into other
		{Key: "other", Seconds: 5},      // and sums with explicit other
		{Key: "slack", Seconds: 0},      // zero dropped
		{Key: "zoom", Seconds: -40},     // negative clamps to 0, dropped
		{Key: "cursor", Seconds: 5000},  // clamped to 600
	})
	if err != nil {
		t.Fatalf("normalizeUsage: %v", err)
	}
	want := []usageItem{
		{Key: "cursor", Seconds: 600},
		{Key: "other", Seconds: 10},
		{Key: "youtube", Seconds: 55},
	}
	if len(got) != len(want) {
		t.Fatalf("got %+v, want %+v", got, want)
	}
	for i := range want {
		if got[i].Key != want[i].Key || got[i].Seconds != want[i].Seconds {
			t.Fatalf("item %d = %+v, want %+v", i, got[i], want[i])
		}
	}
}

func TestNormalizeUsageRejections(t *testing.T) {
	tooMany := make([]usageReportItem, usageMaxItems+1)
	for i := range tooMany {
		tooMany[i] = usageReportItem{Key: "youtube", Seconds: 1}
	}
	if _, err := normalizeUsage(tooMany); err == nil {
		t.Error("65 items accepted, want rejection")
	}
	if _, err := normalizeUsage(tooMany[:usageMaxItems]); err != nil {
		t.Errorf("64 items rejected: %v", err)
	}
	// 600 + 300 = 900 is the inclusive ceiling; one more second is broken.
	if _, err := normalizeUsage([]usageReportItem{{Key: "a", Seconds: 600}, {Key: "b", Seconds: 300}}); err != nil {
		t.Errorf("900s total rejected: %v", err)
	}
	if _, err := normalizeUsage([]usageReportItem{{Key: "a", Seconds: 600}, {Key: "b", Seconds: 301}}); err == nil {
		t.Error("901s total accepted, want rejection")
	}
	// The ceiling applies after clamping, so 2×5000 → 1200 is still rejected.
	if _, err := normalizeUsage([]usageReportItem{{Key: "a", Seconds: 5000}, {Key: "a", Seconds: 5000}}); err == nil {
		t.Error("clamped 1200s total accepted, want rejection")
	}
	if got, err := normalizeUsage(nil); err != nil || len(got) != 0 {
		t.Errorf("empty usage = %+v, %v; want empty, nil", got, err)
	}
}

func TestBuildUsageItems(t *testing.T) {
	items, total := buildUsageItems([]usageRow{
		{Key: "slack", Seconds: 100, People: 2},
		{Key: "youtube", Seconds: 100, People: 3},
		{Key: "retired-key", Seconds: 40, People: 4}, // no longer in catalog
		{Key: "other", Seconds: 10, People: 1},
		{Key: "zoom", Seconds: 0, People: 1}, // empty rows dropped
	}, true)
	if total != 250 {
		t.Fatalf("total = %d, want 250", total)
	}
	wantKeys := []string{"slack", "youtube", "other"} // tie broken by key asc
	if len(items) != len(wantKeys) {
		t.Fatalf("items = %+v", items)
	}
	for i, key := range wantKeys {
		if items[i].Key != key {
			t.Fatalf("items[%d].Key = %q, want %q (%+v)", i, items[i].Key, key, items)
		}
	}
	if items[0].Label != "Slack" || items[0].Category != "Communication" {
		t.Errorf("slack labelled %+v", items[0])
	}
	if items[2].Seconds != 50 || items[2].People == nil || *items[2].People != 4 {
		t.Errorf("folded other = %+v, want 50s and people 4", items[2])
	}

	// The per-user view omits people entirely.
	items, _ = buildUsageItems([]usageRow{{Key: "youtube", Seconds: 5}}, false)
	raw, _ := json.Marshal(items)
	if strings.Contains(string(raw), "people") {
		t.Errorf("per-user items include people: %s", raw)
	}
	if want := `[{"key":"youtube","label":"YouTube","category":"Video","seconds":5}]`; string(raw) != want {
		t.Errorf("json = %s, want %s", raw, want)
	}
}

// ---- avatars ----

func encodeTestImage(t *testing.T, format string, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for x := 0; x < w; x++ {
		img.Set(x, 0, color.RGBA{R: 200, G: 100, B: 50, A: 255})
	}
	var buf bytes.Buffer
	var err error
	switch format {
	case "png":
		err = png.Encode(&buf, img)
	case "jpeg":
		err = jpeg.Encode(&buf, img, nil)
	case "gif":
		err = gif.Encode(&buf, img, nil)
	}
	if err != nil {
		t.Fatalf("encode %s: %v", format, err)
	}
	return buf.Bytes()
}

func TestValidateAvatar(t *testing.T) {
	cases := []struct {
		name     string
		data     []byte
		wantType string // "" means rejected
	}{
		{"png ok", encodeTestImage(t, "png", 64, 64), "image/png"},
		{"jpeg ok", encodeTestImage(t, "jpeg", 128, 96), "image/jpeg"},
		{"min side ok", encodeTestImage(t, "png", 16, 16), "image/png"},
		{"max side ok", encodeTestImage(t, "png", 1024, 16), "image/png"},
		{"too small", encodeTestImage(t, "png", 15, 64), ""},
		{"too wide", encodeTestImage(t, "png", 1025, 64), ""},
		{"too tall", encodeTestImage(t, "jpeg", 64, 1025), ""},
		{"gif rejected", encodeTestImage(t, "gif", 64, 64), ""},
		{"garbage rejected", []byte("not an image at all"), ""},
		{"empty rejected", nil, ""},
		{"oversized rejected", append(encodeTestImage(t, "png", 64, 64), make([]byte, avatarMaxBytes)...), ""},
	}
	// A valid PNG header followed by truncated data passes DecodeConfig but
	// must fail the full decode.
	full := encodeTestImage(t, "png", 64, 64)
	cases = append(cases, struct {
		name     string
		data     []byte
		wantType string
	}{"truncated png rejected", full[:40], ""})

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := validateAvatar(tc.data)
			if tc.wantType == "" {
				if err == nil {
					t.Fatalf("validateAvatar accepted (%q), want rejection", got)
				}
				return
			}
			if err != nil || got != tc.wantType {
				t.Fatalf("validateAvatar = %q, %v; want %q", got, err, tc.wantType)
			}
		})
	}
}

func TestDecodeAvatarBase64(t *testing.T) {
	raw := encodeTestImage(t, "png", 32, 32)
	got, err := decodeAvatarBase64(base64.StdEncoding.EncodeToString(raw))
	if err != nil || !bytes.Equal(got, raw) {
		t.Fatalf("round-trip failed: %v", err)
	}
	if _, err := decodeAvatarBase64("!!!not base64"); err == nil {
		t.Error("invalid base64 accepted")
	}
	if _, err := decodeAvatarBase64("  "); err == nil {
		t.Error("blank image accepted")
	}
	huge := base64.StdEncoding.EncodeToString(make([]byte, avatarMaxBytes+10))
	if _, err := decodeAvatarBase64(huge); err == nil {
		t.Error("oversized base64 accepted")
	}
}

func TestAvatarURL(t *testing.T) {
	if got := avatarURL("zayd", sql.NullTime{}); got != nil {
		t.Fatalf("no avatar = %q, want nil", *got)
	}
	at := time.Unix(1730100000, 0)
	got := avatarURL("zayd", sql.NullTime{Time: at, Valid: true})
	if got == nil || *got != "/api/avatar?login=zayd&v=1730100000" {
		t.Fatalf("avatarURL = %v", got)
	}
	// null (not omitted) when absent, so clients can rely on the key.
	raw, _ := json.Marshal(leaderboardEntry{Login: "a"})
	if !strings.Contains(string(raw), `"avatar_url":null`) {
		t.Fatalf("leaderboard entry json = %s, want avatar_url:null", raw)
	}
}

// ---- status history ----

func TestParseUUID(t *testing.T) {
	ok := map[string]string{
		"3F2504E0-4F89-11D3-9A0C-0305E82C3301":   "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
		" 3f2504e0-4f89-11d3-9a0c-0305e82c3301 ": "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
	}
	for in, want := range ok {
		if got, valid := parseUUID(in); !valid || got != want {
			t.Errorf("parseUUID(%q) = %q, %v; want %q", in, got, valid, want)
		}
	}
	for _, bad := range []string{"", "nope", "3f2504e0-4f89-11d3-9a0c-0305e82c330", "3f2504e0x4f89-11d3-9a0c-0305e82c3301", "3f2504e0-4f89-11d3-9a0c-0305e82c330g", "{3f2504e0-4f89-11d3-9a0c-0305e82c3301}"} {
		if _, valid := parseUUID(bad); valid {
			t.Errorf("parseUUID(%q) accepted", bad)
		}
	}
}

func TestValidateHistorySessions(t *testing.T) {
	now := time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC)
	session := func(id, emoji, message string, start, end time.Time) json.RawMessage {
		raw, _ := json.Marshal(historySession{ID: id, Emoji: emoji, Message: message, StartedAt: start, EndedAt: end})
		return raw
	}
	id := "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
	hourAgo := now.Add(-time.Hour)
	in := []json.RawMessage{
		session(id, " ☕️ ", " coffee ", hourAgo, now),                                            // valid
		session("not-a-uuid", "☕️", "", hourAgo, now),                                            // bad id
		session(id, "", "", hourAgo, now),                                                        // no emoji/message
		session(id, "☕️", strings.Repeat("a", statusMessageLimit+1), hourAgo, now),               // message too long
		session(id, "☕️", "", now, now),                                                          // zero length
		session(id, "☕️", "", now, hourAgo),                                                      // reversed
		session(id, "☕️", "", now.Add(-8*24*time.Hour), now),                                     // > 7 days
		session(id, "☕️", "", now.Add(10*time.Minute), now.Add(time.Hour)),                       // future start
		session(id, "🏋️", "", now.Add(4*time.Minute), now.Add(time.Hour)),                        // within skew window
		session(id, "☕️", "", now.Add(-7*24*time.Hour), now),                                     // exactly 7 days ok
		json.RawMessage(`{"id":"` + id + `","emoji":"x","started_at":"yesterday","ended_at":1}`), // malformed
	}
	valid, skipped := validateHistorySessions(in, now)
	if len(valid) != 3 || skipped != 8 {
		t.Fatalf("valid=%d skipped=%d, want 3 and 8 (%+v)", len(valid), skipped, valid)
	}
	first := valid[0]
	if first.ID != "3f2504e0-4f89-11d3-9a0c-0305e82c3301" || first.Emoji != "☕️" || first.Message != "coffee" {
		t.Fatalf("first session not normalized: %+v", first)
	}
}

func TestHistoryLimit(t *testing.T) {
	for in, want := range map[string]int{"": 100, "abc": 100, "0": 1, "-5": 1, "1": 1, "250": 250, "500": 500, "501": 500} {
		if got := historyLimit(in); got != want {
			t.Errorf("historyLimit(%q) = %d, want %d", in, got, want)
		}
	}
}

// ---- profile series & activities ----

func TestDenseDailySeries(t *testing.T) {
	// Wednesday 2026-10-28, mid-day Central.
	now := time.Date(2026, 10, 28, 12, 0, 0, 0, crewDayLocation)

	_, week := crewActivityPeriod(now, periodWeek)
	series := denseDailySeries(dailySeriesWindow(now, periodWeek, week), map[string]int64{
		"2026-10-27": 1234,
		"2026-11-05": 99, // outside the window: ignored
	})
	if len(series) != 7 || series[0].Day != "2026-10-26" || series[6].Day != "2026-11-01" {
		t.Fatalf("week series = %+v", series)
	}
	if series[1].Seconds != 1234 || series[0].Seconds != 0 {
		t.Fatalf("week series values = %+v", series)
	}

	_, today := crewActivityPeriod(now, periodToday)
	if s := denseDailySeries(dailySeriesWindow(now, periodToday, today), nil); len(s) != 1 || s[0].Day != "2026-10-28" {
		t.Fatalf("today series = %+v", s)
	}

	_, month := crewActivityPeriod(now, periodMonth)
	if s := denseDailySeries(dailySeriesWindow(now, periodMonth, month), nil); len(s) != 31 || s[0].Day != "2026-10-01" || s[30].Day != "2026-10-31" {
		t.Fatalf("october series has %d days (%v … %v)", len(s), s[0], s[len(s)-1])
	}

	// "all" is the last 30 crew days ending today.
	_, all := crewActivityPeriod(now, periodAll)
	s := denseDailySeries(dailySeriesWindow(now, periodAll, all), nil)
	if len(s) != 30 || s[29].Day != "2026-10-28" || s[0].Day != "2026-09-29" {
		t.Fatalf("all series has %d days (%v … %v)", len(s), s[0], s[len(s)-1])
	}

	// The DST fall-back day (2026-11-01, 25h) appears exactly once and the
	// following day isn't skipped.
	_, nov := crewActivityPeriod(time.Date(2026, 11, 15, 12, 0, 0, 0, crewDayLocation), periodMonth)
	s = denseDailySeries(nov, nil)
	if len(s) != 30 || s[0].Day != "2026-11-01" || s[1].Day != "2026-11-02" || s[29].Day != "2026-11-30" {
		t.Fatalf("november series = %d days (%v, %v … %v)", len(s), s[0], s[1], s[len(s)-1])
	}
}

func TestAggregateActivitiesClipsToPeriod(t *testing.T) {
	loc := crewDayLocation
	start := time.Date(2026, 10, 28, 0, 0, 0, 0, loc)
	end := start.AddDate(0, 0, 1)
	now := time.Date(2026, 10, 28, 12, 0, 0, 0, loc)

	spans := []activitySpan{
		// Straddles the period start: only the 30 minutes after midnight count.
		{Emoji: "☕️", StartedAt: start.Add(-30 * time.Minute), EndedAt: start.Add(30 * time.Minute)},
		// Fully inside.
		{Emoji: "☕️", StartedAt: start.Add(2 * time.Hour), EndedAt: start.Add(2*time.Hour + 15*time.Minute)},
		// Running status: started 11:00, clipped to now (12:00).
		{Emoji: "🏋️", StartedAt: now.Add(-time.Hour), EndedAt: now},
		// Ends past now (clock skew): clipped to now.
		{Emoji: "🎧", StartedAt: now.Add(-10 * time.Minute), EndedAt: now.Add(time.Hour)},
		// Entirely before the period: ignored, not counted.
		{Emoji: "📚", StartedAt: start.Add(-3 * time.Hour), EndedAt: start.Add(-2 * time.Hour)},
		// Ties with 🎧 on seconds to exercise the emoji tie-break.
		{Emoji: "🍕", StartedAt: start.Add(5 * time.Hour), EndedAt: start.Add(5*time.Hour + 10*time.Minute)},
	}
	got := aggregateActivities(spans, start, end, now)
	want := []activityTotal{
		{Emoji: "🏋️", Seconds: 3600, Count: 1},
		{Emoji: "☕️", Seconds: 45 * 60, Count: 2},
		{Emoji: "🍕", Seconds: 600, Count: 1},
		{Emoji: "🎧", Seconds: 600, Count: 1},
	}
	if "🍕" > "🎧" {
		want[2], want[3] = want[3], want[2]
	}
	if len(got) != len(want) {
		t.Fatalf("got %+v, want %+v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("activities[%d] = %+v, want %+v (all: %+v)", i, got[i], want[i], got)
		}
	}

	// Unbounded ("all") keeps the pre-period session but still stops at now.
	all := aggregateActivities(spans, time.Time{}, time.Time{}, now)
	var books *activityTotal
	for i := range all {
		if all[i].Emoji == "📚" {
			books = &all[i]
		}
	}
	if books == nil || books.Seconds != 3600 {
		t.Fatalf("all-period activities = %+v, want 📚 3600s", all)
	}

	if got := aggregateActivities(nil, start, end, now); got == nil || len(got) != 0 {
		t.Fatalf("no spans = %#v, want empty non-nil slice", got)
	}
}

// ---- handler validation (no DB) ----

func TestNewEndpointsRejectBadInput(t *testing.T) {
	s := &server{} // nil db: every case must reject before touching it.
	png64 := base64.StdEncoding.EncodeToString(encodeTestImage(t, "png", 8, 8))
	cases := []struct {
		name    string
		handler http.HandlerFunc
		method  string
		target  string
		body    string
		want    string
	}{
		{"avatar bad json", s.handlePutAvatar, http.MethodPut, "/api/avatar", `{`, "invalid avatar payload"},
		{"avatar bad user", s.handlePutAvatar, http.MethodPut, "/api/avatar", `{"user":"bad name","image":"x"}`, "missing or invalid user"},
		{"avatar bad base64", s.handlePutAvatar, http.MethodPut, "/api/avatar", `{"user":"zayd","image":"@@@"}`, "base64"},
		{"avatar too small", s.handlePutAvatar, http.MethodPut, "/api/avatar", `{"user":"zayd","image":"` + png64 + `"}`, "pixels"},
		{"avatar delete bad json", s.handleDeleteAvatar, http.MethodDelete, "/api/avatar", `nope`, "invalid avatar payload"},
		{"avatar get no login", s.handleGetAvatar, http.MethodGet, "/api/avatar", ``, "missing or invalid login"},
		{"usage bad json", s.handlePostUsage, http.MethodPost, "/api/usage", `{"user":`, "invalid usage payload"},
		{"usage bad user", s.handlePostUsage, http.MethodPost, "/api/usage", `{"user":"","usage":[]}`, "missing or invalid user"},
		{"usage too much", s.handlePostUsage, http.MethodPost, "/api/usage", `{"user":"zayd","usage":[{"key":"x","seconds":600},{"key":"y","seconds":600}]}`, "exceeds"},
		{"usage get no login", s.handleGetUsage, http.MethodGet, "/api/usage?period=week", ``, "missing or invalid login"},
		{"history bad json", s.handlePostStatusHistory, http.MethodPost, "/api/status/history", `[`, "invalid history payload"},
		{"history empty", s.handlePostStatusHistory, http.MethodPost, "/api/status/history", `{"user":"zayd","sessions":[]}`, "1 to 200"},
		{"history all invalid", s.handlePostStatusHistory, http.MethodPost, "/api/status/history", `{"user":"zayd","sessions":[{"id":"nope"}]}`, "no valid sessions"},
		{"history delete bad id", s.handleDeleteStatusHistory, http.MethodDelete, "/api/status/history", `{"user":"zayd","id":"nope"}`, "UUID"},
		{"history get no login", s.handleGetStatusHistory, http.MethodGet, "/api/status/history", ``, "missing or invalid login"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			tc.handler(rec, httptest.NewRequest(tc.method, tc.target, strings.NewReader(tc.body)))
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400 (body %s)", rec.Code, rec.Body.String())
			}
			if !strings.Contains(rec.Body.String(), tc.want) {
				t.Fatalf("body = %q, want it to contain %q", rec.Body.String(), tc.want)
			}
		})
	}
}

func TestHistoryRejectsTooManySessions(t *testing.T) {
	s := &server{}
	sessions := make([]string, statusHistoryMaxSessions+1)
	for i := range sessions {
		sessions[i] = `{}`
	}
	body := `{"user":"zayd","sessions":[` + strings.Join(sessions, ",") + `]}`
	rec := httptest.NewRecorder()
	s.handlePostStatusHistory(rec, httptest.NewRequest(http.MethodPost, "/api/status/history", strings.NewReader(body)))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", rec.Code)
	}
}

func TestNewRoutesRegistered(t *testing.T) {
	mux := newMux(brokenDB(t))
	for _, route := range []struct{ method, path string }{
		{http.MethodGet, "/api/avatar"},
		{http.MethodPut, "/api/avatar"},
		{http.MethodDelete, "/api/avatar"},
		{http.MethodPost, "/api/usage"},
		{http.MethodGet, "/api/usage"},
		{http.MethodGet, "/api/usage/crew"},
		{http.MethodGet, "/api/status/history"},
		{http.MethodPost, "/api/status/history"},
		{http.MethodDelete, "/api/status/history"},
	} {
		req := httptest.NewRequest(route.method, route.path, nil)
		if _, pattern := mux.Handler(req); pattern == "" {
			t.Errorf("%s %s is not routed", route.method, route.path)
		}
	}
	// Wrong method on a new path is rejected by the mux, not served.
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodPatch, "/api/usage", nil))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("PATCH /api/usage = %d, want 405", rec.Code)
	}
}
