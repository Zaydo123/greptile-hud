package main

// statusOnline is the presence truth for a status row. handleStatuses scans
// the status columns without building a *User, so it must replicate isOnline()'s
// rule over a sql.NullTime last_seen. These tests pin that replication: a NULL
// last_seen, a beat at exactly the window edge, and a recent beat must all agree
// with the isOnline() behaviour a fully-loaded user row would produce.
import (
	"database/sql"
	"testing"
	"time"
)

func TestStatusOnline(t *testing.T) {
	base := time.Now().UTC()
	lately := base.Add(-2 * time.Minute)
	stale := base.Add(-onlineWindow)

	tests := []struct {
		name     string
		lastSeen sql.NullTime
		wantOn   bool
	}{
		{name: "NULL last_seen is offline", lastSeen: sql.NullTime{Valid: false}, wantOn: false},
		{name: "recent beat is online", lastSeen: sql.NullTime{Time: lately, Valid: true}, wantOn: true},
		{name: "window-exact beat is offline", lastSeen: sql.NullTime{Time: stale, Valid: true}, wantOn: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := statusOnline(tt.lastSeen, base); got != tt.wantOn {
				t.Fatalf("statusOnline(%v) = %v, want %v", tt.lastSeen, got, tt.wantOn)
			}
		})
	}
}

// The status row and a loaded *User must agree on presence for the same
// last_seen, so a drift in one rule can't silently split the UI's online feed.
func TestStatusOnlineAgreesWithIsOnline(t *testing.T) {
	base := time.Now().UTC()

	cases := []sql.NullTime{
		{Valid: false},
		{Time: base.Add(-1 * time.Second), Valid: true},
		{Time: base.Add(-onlineWindow), Valid: true},
		{Time: base.Add(-(onlineWindow + time.Minute)), Valid: true},
	}
	for _, cell := range cases {
		// Mirror what handleStatuses does: build a *User from the same time.
		var lu *time.Time
		if cell.Valid {
			tm := cell.Time
			lu = &tm
		}
		gotStatus := statusOnline(cell, base)
		gotUser := isOnline(&User{LastSeen: lu})
		if gotStatus != gotUser {
			t.Fatalf("statusOnline(%v) = %v but isOnline(user with same beat) = %v", cell, gotStatus, gotUser)
		}
	}
}
