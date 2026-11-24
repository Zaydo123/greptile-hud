package main

// Decoding coverage for statusRow (statuses.go), the raw row behind the Crew
// status feed. Every column but login and started_at is nullable, and the
// handler used to fold them inline where nothing could reach them without a
// live Postgres. The mapping is what keeps three product rules honest:
//
//   - a shared status stays listed after its owner falls out of the five-minute
//     online window (AGENTS.md: presence and an explicitly running status are
//     separate states), so a stale last_seen must decode as offline *and* still
//     produce a row;
//   - a NULL name falls back to the login, so the HUD never shows a blank label;
//   - a NULL emoji/message decodes to "" rather than carrying a null through to
//     the client, which decodes those fields as non-optional strings.
//
// Stdlib only — no new dependency, no database.

import (
	"database/sql"
	"encoding/json"
	"testing"
	"time"
)

func TestStatusRowDecoding(t *testing.T) {
	now := time.Date(2026, 11, 24, 7, 0, 0, 0, time.UTC)
	started := now.Add(-42 * time.Minute)
	beaten := now.Add(-2 * time.Minute)
	avatarAt := time.Unix(1_700_000_000, 0).UTC()

	base := func() statusRow {
		return statusRow{
			login:     "zayd",
			name:      sql.NullString{String: "Zayd Alzein", Valid: true},
			emoji:     sql.NullString{String: "🏋️", Valid: true},
			message:   sql.NullString{String: "At the gym", Valid: true},
			startedAt: started,
			lastSeen:  sql.NullTime{Time: beaten, Valid: true},
		}
	}

	t.Run("full row copies through with online and avatar", func(t *testing.T) {
		row := base()
		row.avatarAt = sql.NullTime{Time: avatarAt, Valid: true}
		got := row.status(now)

		if got.Login != "zayd" || got.Name != "Zayd Alzein" {
			t.Fatalf("status() = (%q, %q), want (zayd, Zayd Alzein)", got.Login, got.Name)
		}
		if got.Emoji != "🏋️" || got.Message != "At the gym" {
			t.Fatalf("status() = (%q, %q), want the row's emoji and message", got.Emoji, got.Message)
		}
		if !got.StartedAt.Equal(started) {
			t.Fatalf("StartedAt = %v, want %v", got.StartedAt, started)
		}
		if !got.Online {
			t.Fatal("Online = false, want true for a heartbeat inside the online window")
		}
		want := "/api/avatar?login=zayd&v=1700000000"
		if got.AvatarURL == nil || *got.AvatarURL != want {
			t.Fatalf("AvatarURL = %v, want %q", got.AvatarURL, want)
		}
	})

	t.Run("away owner stays listed but reads offline", func(t *testing.T) {
		row := base()
		// NULL last_seen: a user who has never sent a heartbeat.
		row.lastSeen = sql.NullTime{}
		if got := row.status(now); got.Online {
			t.Fatal("Online = true for a NULL last_seen, want false")
		}
		if got := row.status(now); got.Login != "zayd" || got.Emoji != "🏋️" {
			t.Fatalf("status() = %+v, want the running status to survive an offline owner", got)
		}

		// A beat older than the window is the more common away case.
		row.lastSeen = sql.NullTime{Time: now.Add(-onlineWindow - time.Minute), Valid: true}
		if got := row.status(now); got.Online {
			t.Fatal("Online = true for a beat past the online window, want false")
		}
	})

	t.Run("NULL name falls back to login", func(t *testing.T) {
		row := base()
		row.name = sql.NullString{}
		if got := row.status(now); got.Name != "zayd" {
			t.Fatalf("Name = %q, want the login fallback", got.Name)
		}
	})

	t.Run("NULL emoji and message decode to empty strings", func(t *testing.T) {
		row := base()
		row.emoji = sql.NullString{}
		row.message = sql.NullString{}
		got := row.status(now)
		if got.Emoji != "" || got.Message != "" {
			t.Fatalf("status() = (%q, %q), want empty strings", got.Emoji, got.Message)
		}

		// The client decodes emoji/message/name as non-optional strings, so a
		// NULL must never reach the wire as JSON null.
		raw, err := json.Marshal(got)
		if err != nil {
			t.Fatalf("marshal crewStatus: %v", err)
		}
		var decoded map[string]any
		if err := json.Unmarshal(raw, &decoded); err != nil {
			t.Fatalf("unmarshal crewStatus: %v", err)
		}
		for _, key := range []string{"emoji", "message"} {
			if v, ok := decoded[key].(string); !ok || v != "" {
				t.Fatalf("%s = %#v in %s, want \"\" (never null)", key, decoded[key], raw)
			}
		}
	})

	t.Run("no avatar row means no avatar URL", func(t *testing.T) {
		got := base().status(now)
		if got.AvatarURL != nil {
			t.Fatalf("AvatarURL = %v, want nil without an avatars row", *got.AvatarURL)
		}
	})
}
