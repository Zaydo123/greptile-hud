package main

import (
	"strings"
	"testing"
)

func TestNormalizeLogin(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want string
	}{
		{name: "valid plain name", raw: "zayd", want: "zayd"},
		{name: "trims surrounding whitespace", raw: "  Zayd123  ", want: "Zayd123"},
		{name: "strips one leading @", raw: "@zayd", want: "zayd"},
		{name: "strips whitespace after @", raw: "@ zayd", want: "zayd"},
		{name: "allows hyphen and underscore inside", raw: "a-b_c", want: "a-b_c"},
		{name: "allows digits", raw: "zayd123", want: "zayd123"},
		{name: "allows single character", raw: "x", want: "x"},
		{name: "allows max length", raw: strings.Repeat("a", 32), want: strings.Repeat("a", 32)},
		{name: "rejects empty", raw: "", want: ""},
		{name: "rejects whitespace only", raw: "   ", want: ""},
		{name: "rejects bare @", raw: "@", want: ""},
		{name: "rejects doubled @", raw: "@@zayd", want: ""},
		{name: "rejects @ inside", raw: "a@b", want: ""},
		{name: "rejects leading hyphen", raw: "-abc", want: ""},
		{name: "rejects leading underscore", raw: "_abc", want: ""},
		{name: "rejects invalid characters", raw: "zayd!", want: ""},
		{name: "rejects too long", raw: strings.Repeat("a", 33), want: ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := normalizeLogin(tt.raw)
			if got != tt.want {
				t.Fatalf("normalizeLogin(%q) = %q, want %q", tt.raw, got, tt.want)
			}
		})
	}
}