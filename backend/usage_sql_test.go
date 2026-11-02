package main

// Lockstep coverage for the app_usage statements in usage.go. App/site usage
// is the crew-activity signal behind the leaderboard-adjacent stats: the Mac
// flushes per-key seconds about once a minute and the server folds them into
// per-user, per-day, per-key rows. These statements are inline literals, so
// they can drift silently with no compiler error:
//
//   - addUsage's upsert keys its ON CONFLICT on (user_id, day, key) — the
//     schema's PRIMARY KEY, and the whole grain of the table. A drift to
//     conflict on key alone would let one user's minutes overwrite another's;
//     the SET must add (seconds + EXCLUDED.seconds), never assign, or every
//     flush would erase the previous one instead of accumulating.
//   - handleGetUsage must scope to the user (WHERE user_id = $1) and, only for
//     a bounded period, apply the half-open day window >= $2::date AND day <
//     $3::date — endDateKey exists precisely so the upper bound can stay
//     exclusive; a <= drift double-counts the boundary day, a day = drift
//     collapses the window to one day, and a filter that leaks into the "all"
//     query starts dropping rows.
//   - handleGetCrewUsage must keep COUNT(DISTINCT user_id) — that is the
//     crew's people count — and cap the response at usageCrewTopItems.
//   - Both GET queries must end in GROUP BY key, ORDER BY 2 DESC, key: the key
//     tie-break keeps equal-second items from swapping places between polls.
//
// This test reads the actual query text back out of usage.go and pins each
// property, mirroring the guards leaderboard_sql_test.go,
// status_history_sql_test.go and devtime_sql_test.go apply. Stdlib only — no
// new dependency.

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

func usageSource(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile("usage.go")
	if err != nil {
		t.Fatalf("read usage.go: %v", err)
	}
	return string(raw)
}

// The upsert must keep merging on the (user_id, day, key) grain the schema's
// PRIMARY KEY declares. That triple is the whole "per person, per day, per
// app" contract — a drift to a coarser conflict target would make one user's
// minutes silently overwrite another's.
func TestUsageUpsertKeepsPerUserPerDayPerKeyGrain(t *testing.T) {
	src := usageSource(t)

	const insert = "INSERT INTO app_usage (user_id, day, key, seconds)"
	if got := strings.Count(src, insert); got != 1 {
		t.Fatalf("usage.go contains %q %d times, want exactly 1 (the upsert)", insert, got)
	}

	const conflict = "ON CONFLICT (user_id, day, key) DO UPDATE"
	if got := strings.Count(src, conflict); got != 1 {
		t.Fatalf("usage.go contains %q %d times, want exactly 1", conflict, got)
	}

	// A UPSERT that stopped updating (DO NOTHING) would silently drop late
	// flushes instead of merging them into the running total.
	if strings.Contains(src, "DO NOTHING") {
		t.Fatal("usage upsert must DO UPDATE, never DO NOTHING")
	}
}

// Each flush carries a partial total for the minute, so the upsert must add
// into the stored seconds, never assign. An overwrite would reset everyone's
// day total to the last flush and lose the rest.
func TestUsageUpsertAccumulatesNotOverwrites(t *testing.T) {
	src := usageSource(t)

	const accumulate = "SET seconds = app_usage.seconds + EXCLUDED.seconds"
	if got := strings.Count(src, accumulate); got != 1 {
		t.Fatalf("usage.go contains the accumulate fragment %q %d times, want exactly 1", accumulate, got)
	}

	// The day arrives as a date key string from crewDayPeriod; the ::date cast
	// is what makes it match the DATE column. $2::date appears exactly three
	// times: the upsert VALUES cast, the per-user list window's lower bound,
	// and the crew window's upper bound — nowhere else.
	if got := strings.Count(src, "$2::date"); got != 3 {
		t.Fatalf("usage.go contains $2::date %d times, want exactly 3 (upsert day cast + list window lower + crew window upper)", got)
	}
}

// The per-user list must scope through the user's id and keep its calendar
// filter on the half-open [start, end) window — day >= lower AND day < upper —
// so a bounded period never shares a boundary day with its neighbor.
func TestGetUsageWindowIsHalfOpenAndUserScoped(t *testing.T) {
	src := usageSource(t)

	if got := strings.Count(src, "WHERE user_id = $1"); got != 1 {
		t.Fatalf("usage.go contains %q %d times, want exactly 1 (the per-user list)", "WHERE user_id = $1", got)
	}

	const window = "AND day >= $2::date AND day < $3::date"
	if got := strings.Count(src, window); got != 1 {
		t.Fatalf("usage.go contains the half-open window `%s` %d times, want exactly 1", window, got)
	}

	// A closed upper bound would double-count the last day of every window.
	if strings.Contains(src, "day <= $3::date") {
		t.Fatal("usage list window must stay half-open (day < upper), never closed (day <=)")
	}
}

// The crew aggregate is the only query that filters directly on day (the
// per-user one filters on user_id first), and it must keep counting distinct
// users — that number is the crew view's people column.
func TestCrewUsageCountsDistinctUsers(t *testing.T) {
	src := usageSource(t)

	const crewQuery = "SELECT key, SUM(seconds), COUNT(DISTINCT user_id)"
	if got := strings.Count(src, crewQuery); got != 1 {
		t.Fatalf("usage.go contains %q %d times, want exactly 1 (the crew aggregate)", crewQuery, got)
	}

	const crewWindow = "WHERE day >= $1::date AND day < $2::date"
	if got := strings.Count(src, crewWindow); got != 1 {
		t.Fatalf("usage.go contains the crew window `%s` %d times, want exactly 1", crewWindow, got)
	}

	// The per-user query feeds queryUsageRows a constant 1 for the people
	// column; only the crew query may count distinct users.
	if got := strings.Count(src, "SELECT key, SUM(seconds), 1"); got != 1 {
		t.Fatalf("usage.go contains %q %d times, want exactly 1 (the per-user list select)", "SELECT key, SUM(seconds), 1", got)
	}
}

// Both aggregates must group by key and sort seconds desc with the key as the
// final tie-break, so equal-second items hold a stable order across polls.
func TestUsageQueriesKeepStableOrderAndGrouping(t *testing.T) {
	src := usageSource(t)

	if got := strings.Count(src, "GROUP BY key"); got != 2 {
		t.Fatalf("usage.go contains GROUP BY key %d times, want exactly 2 (per-user and crew queries)", got)
	}
	if got := strings.Count(src, "ORDER BY 2 DESC, key"); got != 2 {
		t.Fatalf("usage.go contains ORDER BY 2 DESC, key %d times, want exactly 2", got)
	}
}

// The crew response must stay capped at the top 25 items; the cap lives in Go
// code (the SQL has no LIMIT, matching the per-user endpoint), so pin both the
// constant and the truncation that applies it.
func TestCrewUsageStaysCappedAtTopItems(t *testing.T) {
	src := usageSource(t)

	if got := len(regexp.MustCompile(`usageCrewTopItems\s*=\s*25`).FindAllStringIndex(src, -1)); got != 1 {
		t.Fatalf("usage.go contains the usageCrewTopItems = 25 declaration %d times, want exactly 1", got)
	}
	if got := strings.Count(src, "items[:usageCrewTopItems]"); got != 1 {
		t.Fatalf("usage.go contains %q %d times, want exactly 1 (the cap application)", "items[:usageCrewTopItems]", got)
	}
}

// The payload contract the Mac client is built against: 64 items, 600s per
// item, 900s per request. These surface in normalizeUsage's error text, so a
// drift changes user-visible messages. The const block is gofmt-aligned, so
// match the declarations loosely across whitespace.
func TestUsagePayloadConstantsStayAtContract(t *testing.T) {
	src := usageSource(t)

	for _, decl := range []string{
		`usageItemSecondsMax\s*=\s*600`,
		`usageRequestSecondsMax\s*=\s*900`,
		`usageMaxItems\s*=\s*64`,
	} {
		if got := len(regexp.MustCompile(decl).FindAllStringIndex(src, -1)); got != 1 {
			t.Fatalf("usage.go contains the declaration %q %d times, want exactly 1", decl, got)
		}
	}
}
