package main

import (
	"bytes"
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

func TestNormalizeStatusRejectsInvalidUtf8Emoji(t *testing.T) {
	// The byte ceiling and the UTF-8 validity check are independent guards:
	// a short but malformed byte sequence (a lone lead byte with no
	// continuation) must be rejected here, not only when it overflows the
	// statusEmojiByteMax limit already covered above.
	var b bytes.Buffer
	b.Write([]byte{0xC3})
	bad := b.String()

	if _, _, err := normalizeStatus(bad, "hi"); err == nil {
		t.Fatalf("normalizeStatus() accepted malformed emoji %q, want error", bad)
	}
}
