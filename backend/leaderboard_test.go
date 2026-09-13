package main

import (
	"strings"
	"testing"
)

func TestNormalizeLogin(t *testing.T) {
	a32 := strings.Repeat("a", 32)
	a33 := strings.Repeat("a", 33)
	tests := []struct {
		name string
		raw  string
		want string
	}{
		{name: "valid plain name", raw: "zayd", want: "zayd"},
		{name: "trims", raw: "  Zayd123  ", want: "Zayd123"},
		{name: "leading @", raw: "@zayd", want: "zayd"},
		{name: "@ then space", raw: "@ zayd", want: "zayd"},
		{name: "inner - and _", raw: "a-b_c", want: "a-b_c"},
		{name: "digits", raw: "zayd123", want: "zayd123"},
		{name: "single char", raw: "x", want: "x"},
		{name: "max length", raw: a32, want: a32},
		{name: "empty", raw: "", want: ""},
		{name: "whitespace", raw: "   ", want: ""},
		{name: "bare @", raw: "@", want: ""},
		{name: "double @", raw: "@@zayd", want: ""},
		{name: "@ inside", raw: "a@b", want: ""},
		{name: "leading -", raw: "-abc", want: ""},
		{name: "leading _", raw: "_abc", want: ""},
		{name: "invalid char", raw: "zayd!", want: ""},
		{name: "too long", raw: a33, want: ""},
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