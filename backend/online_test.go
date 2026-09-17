package main

import (
	"testing"
	"time"
)

func TestIsOnline(t *testing.T) {
	base := time.Now().UTC()
	lately := base.Add(-2 * time.Minute)
	stale := base.Add(-onlineWindow)

	tests := []struct {
		name   string
		user   *User
		wantOn bool
	}{
		{name: "nil last_seen is offline", user: &User{Login: "a", LastSeen: nil}, wantOn: false},
		{name: "recent beat is online", user: &User{Login: "a", LastSeen: &lately}, wantOn: true},
		{name: "window-exact beat is offline", user: &User{Login: "a", LastSeen: &stale}, wantOn: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := isOnline(tt.user); got != tt.wantOn {
				t.Fatalf("isOnline(LastSeen)%v = %v, want %v", tt.user.LastSeen, got, tt.wantOn)
			}
		})
	}
}
