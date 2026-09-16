package main

import "testing"

func TestNormalizeLogin(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want string
	}{
		{name: "plain lowercase", raw: "zayd", want: "zayd"},
		{name: "trims surrounding spaces", raw: "  zayd  ", want: "zayd"},
		{name: "strips leading @", raw: "@zayd", want: "zayd"},
		{name: "strips leading @ then space", raw: " @ zayd ", want: "zayd"},
		{name: "allows digits and underscore", raw: "zayd_123", want: "zayd_123"},
		{name: "allows leading digit", raw: "1zayd", want: "1zayd"},
		{name: "rejects empty", raw: "   ", want: ""},
		{name: "rejects bare @", raw: "@", want: ""},
		{name: "rejects inner space", raw: "zay d", want: ""},
		{name: "rejects dots", raw: "zayd.x", want: ""},
		{name: "rejects non-ASCII", raw: "zaydé", want: ""},
		{name: "rejects emoji", raw: "🛠️", want: ""},
		{name: "allows 32 chars", raw: "abcdefghijklmnopqrstuvwxyz123456", want: "abcdefghijklmnopqrstuvwxyz123456"},
		{name: "rejects 33 chars", raw: "abcdefghijklmnopqrstuvwxyz1234567", want: ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := normalizeLogin(tt.raw); got != tt.want {
				t.Fatalf("normalizeLogin(%q) = %q, want %q", tt.raw, got, tt.want)
			}
		})
	}
}
