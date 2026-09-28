package main

import "testing"

func TestDisplayName(t *testing.T) {
	tests := []struct {
		login string
		name  string
		want  string
	}{
		{login: "zayd", name: "Zayd Alzein", want: "Zayd Alzein"},
		{login: "zayd", name: "", want: "zayd"},
		{login: "unaesthetic", name: "unaesthetic", want: "unaesthetic"},
	}

	for _, tt := range tests {
		t.Run(tt.login, func(t *testing.T) {
			if got := displayName(tt.login, tt.name); got != tt.want {
				t.Fatalf("displayName(%q, %q) = %q, want %q", tt.login, tt.name, got, tt.want)
			}
		})
	}
}
