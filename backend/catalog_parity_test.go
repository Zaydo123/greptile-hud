package main

// Lockstep coverage for the app/site usage catalog. Sources/Usage.swift (the
// macOS client) and backend/catalog.go (this service) must expose the exact
// same set of keys: the client sends only lowercase catalog keys, and the
// server folds anything it doesn't recognise into "other" — so a key added on
// on one side only is silently lost (see AGENTS.md "App & site usage"). This
// test reads the Swift catalog out of the repo (relative to this package) and
// asserts it is identical to usageCatalog, in both directions. Stdlib only —
// no new dependency, no Postgres.

import (
	"os"
	"regexp"
	"testing"
)

// swiftKeyRe matches the Swift catalog entries in Sources/Usage.swift, e.g.
//
//	.init(key: "terminal", bundleIDs: ["com.apple.Terminal"])
var swiftKeyRe = regexp.MustCompile(`\.init\(key:\s*"([^"]+)"`)

// swiftOtherRe grabs the explicit "other" key so it stays in parity too.
var swiftOtherRe = regexp.MustCompile(`static let other\s*=\s*"([^"]+)"`)

// readSwiftCatalogKeys pulls every key out of Sources/Usage.swift. The file is
// at the repo root, one level above the backend package. Returns an error if
// it can't be read so a packaging change that moves it fails loudly here.
func readSwiftCatalogKeys(t *testing.T) map[string]bool {
	t.Helper()
	raw, err := os.ReadFile("../Sources/Usage.swift")
	if err != nil {
		t.Fatalf("read ../Sources/Usage.swift: %v", err)
	}
	keys := map[string]bool{}
	for _, m := range swiftKeyRe.FindAllStringSubmatch(string(raw), -1) {
		keys[m[1]] = true
	}
	if m := swiftOtherRe.FindStringSubmatch(string(raw)); m != nil {
		keys[m[1]] = true
	}
	return keys
}

func TestSwiftAndGoCatalogKeysAreIdentical(t *testing.T) {
	swift := readSwiftCatalogKeys(t)
	goKeys := map[string]bool{}
	for _, e := range usageCatalog {
		goKeys[e.Key] = true
	}
	goKeys[usageOtherKey] = true

	var swiftNotGo, goNotSwift []string
	for k := range swift {
		if !goKeys[k] {
			swiftNotGo = append(swiftNotGo, k)
		}
	}
	for k := range goKeys {
		if !swift[k] {
			goNotSwift = append(goNotSwift, k)
		}
	}

	if len(swiftNotGo) != 0 {
		t.Errorf("keys in Sources/Usage.swift but missing from backend/catalog.go (server folds them to \"other\", silently lost): %v", swiftNotGo)
	}
	if len(goNotSwift) != 0 {
		t.Errorf("keys in backend/catalog.go but missing from Sources/Usage.swift (client never sends them; always \"other\"): %v", goNotSwift)
	}
	if len(swiftNotGo) != 0 || len(goNotSwift) != 0 {
		t.Fatal("Swift and Go usage catalogs are out of sync; fix one side together (see AGENTS.md 'App & site usage')")
	}
	if len(swift) == 0 {
		t.Fatal("parsed zero Swift catalog keys; the read or regex may be wrong")
	}
}
