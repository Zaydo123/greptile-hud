package main

// Boundary coverage for normalizeStatus (statuses.go). The two limits are
// deliberately different units: the emoji field is capped by BYTES (a ZWJ
// emoji grapheme cluster can span several runes, so a rune count would wrongly
// reject a single visual character), while the message field is capped by
// RUNES (so a message of non-ASCII multi-byte characters isn't unfairly short).
// These tests pin the exact edges of both so a future edit can't drift the
// units apart. Tested with the stdlib only — no new dependency.

import (
	"strings"
	"testing"
)

func TestNormalizeStatusMessageLimitIsRunesNotBytes(t *testing.T) {
	// "é" is 2 bytes but 1 rune. A message of exactly statusMessageLimit runes
	// — even though it is 2x that many bytes — must be accepted, proving the
	// guard counts characters, not storage size.
	if statusMessageLimit < 1 {
		t.Fatalf("statusMessageLimit = %d, want >= 1", statusMessageLimit)
	}
	atLimit := strings.Repeat("é", statusMessageLimit)
	if _, _, err := normalizeStatus("🙂", atLimit); err != nil {
		t.Fatalf("normalizeStatus() rejected a %d-rune (%d-byte) message: %v",
			statusMessageLimit, len(atLimit), err)
	}
	over := strings.Repeat("é", statusMessageLimit+1)
	if _, _, err := normalizeStatus("🙂", over); err == nil {
		t.Fatalf("normalizeStatus() accepted a %d-rune message, want error",
			statusMessageLimit+1)
	}
}

func TestNormalizeStatusAcceptsMultiRuneEmojiCluster(t *testing.T) {
	// A ZWJ family emoji is a single visual glyph made of several runes and
	// bytes (25 bytes / 6 runes). It must be accepted as a valid emoji — the
	// byte ceiling exists to bound huge inputs, not to reject legitimate
	// grapheme clusters.
	family := "\U0001F468\u200D\U0001F469\u200D\U0001F467\u200D\U0001F466"
	if len(family) > statusEmojiByteMax {
		t.Fatalf("test assumes family emoji (%d bytes) fits statusEmojiByteMax=%d",
			len(family), statusEmojiByteMax)
	}
	if _, _, err := normalizeStatus(family, "coding with the fam"); err != nil {
		t.Fatalf("normalizeStatus() rejected a valid %d-byte emoji cluster: %v",
			len(family), err)
	}
}

func TestNormalizeStatusEmojiByteCeiling(t *testing.T) {
	// Pin the byte ceiling itself: statusEmojiByteMax bytes pass, one more
	// fails. Uses plain ASCII to hit the boundary exactly (bytes == runes), so
	// the test isolates the byte limit from the rune semantics.
	if statusEmojiByteMax < 1 {
		t.Fatalf("statusEmojiByteMax = %d, want >= 1", statusEmojiByteMax)
	}
	atCeiling := strings.Repeat("x", statusEmojiByteMax)
	if _, _, err := normalizeStatus(atCeiling, "msg"); err != nil {
		t.Fatalf("normalizeStatus() rejected a %d-byte emoji, want accept: %v",
			statusEmojiByteMax, err)
	}
	over := strings.Repeat("x", statusEmojiByteMax+1)
	if _, _, err := normalizeStatus(over, "msg"); err == nil {
		t.Fatalf("normalizeStatus() accepted a %d-byte emoji, want error",
			statusEmojiByteMax+1)
	}
}
