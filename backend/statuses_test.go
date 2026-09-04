package main

import (
	"strings"
	"testing"
)

func TestNormalizeStatus(t *testing.T) {
	tests := []struct {
		name        string
		emoji       string
		message     string
		wantEmoji   string
		wantMessage string
		wantError   bool
	}{
		{name: "emoji and message", emoji: " 🏋️ ", message: " At the gym ", wantEmoji: "🏋️", wantMessage: "At the gym"},
		{name: "message only", message: "Lunch", wantMessage: "Lunch"},
		{name: "emoji only", emoji: "🎯", wantEmoji: "🎯"},
		{name: "empty", emoji: " ", message: " ", wantError: true},
		{name: "message too long", emoji: "🙂", message: strings.Repeat("a", statusMessageLimit+1), wantError: true},
		{name: "emoji too long", emoji: strings.Repeat("🙂", 9), wantError: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			emoji, message, err := normalizeStatus(tt.emoji, tt.message)
			if (err != nil) != tt.wantError {
				t.Fatalf("normalizeStatus() error = %v, wantError %v", err, tt.wantError)
			}
			if emoji != tt.wantEmoji || message != tt.wantMessage {
				t.Fatalf("normalizeStatus() = (%q, %q), want (%q, %q)",
					emoji, message, tt.wantEmoji, tt.wantMessage)
			}
		})
	}
}
