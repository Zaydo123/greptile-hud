package main

// Lockstep coverage for the embedded landing page (site/index.html, glued in
// by go:embed in main.go). Nothing compiles this file, so a tag can vanish in
// an edit with no build error — and the two things that vanish quietly are the
// ones nobody sees in the page itself:
//
//   - The tab icon. Without a rel="icon" link every visitor's browser falls
//     back to GET /favicon.ico, which the root handler 404s; the tab shows a
//     blank sheet.
//   - The link-preview tags. Shared links then render as bare text in Slack,
//     Discord and X instead of a titled card.
//
// It also pins the icon's colour to the Tokyo Night palette rather than an
// arbitrary hex, since the app's mark is a fixed asset and a mismatched accent
// is the easiest thing to drift.
//
// Stdlib only — no new dependency.

import (
	"net/url"
	"os"
	"regexp"
	"strings"
	"testing"
)

const landingPagePath = "site/index.html"

func landingPage(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile(landingPagePath)
	if err != nil {
		t.Fatalf("read %s: %v", landingPagePath, err)
	}
	return string(raw)
}

// The head must advertise an SVG icon inline. A data URI keeps the page a
// single embedded file — no route, no extra committed asset, no 404.
func TestLandingPageHasInlineSVGFavicon(t *testing.T) {
	page := landingPage(t)
	m := regexp.MustCompile(`(?s)<link[^>]*rel="icon"[^>]*>`).FindString(page)
	if m == "" {
		t.Fatalf("%s has no rel=\"icon\" link; browsers will request /favicon.ico and get a 404", landingPagePath)
	}
	if !strings.Contains(m, `type="image/svg+xml"`) {
		t.Fatalf("icon link = %q, want type=\"image/svg+xml\"", m)
	}
	href, err := url.PathUnescape(m)
	if err != nil {
		t.Fatalf("icon href is not valid percent-encoding: %v", err)
	}
	if !strings.Contains(href, "data:image/svg+xml,") || !strings.Contains(href, "<svg") {
		t.Fatalf("icon href = %q, want an inline SVG data URI", href)
	}
	// Tokyo Night only (AGENTS.md: colours come from the palette).
	for _, hex := range []string{"#7AA2F7", "#7DCFFF", "#1A1B26"} {
		if !strings.Contains(href, hex) {
			t.Fatalf("icon href %q is missing Tokyo colour %s", href, hex)
		}
	}
	for _, hex := range regexp.MustCompile(`#[0-9a-fA-F]{6}`).FindAllString(href, -1) {
		if hex != "#7AA2F7" && hex != "#7DCFFF" && hex != "#1A1B26" {
			t.Fatalf("icon uses non-Tokyo colour %s", hex)
		}
	}
}

// A shared link is the page's front door on every chat app, so the preview
// tags are part of the page contract, not decoration.
func TestLandingPageHasLinkPreviewTags(t *testing.T) {
	page := landingPage(t)
	for _, want := range []string{
		`<link rel="canonical" href="https://goathud.com/">`,
		`<meta property="og:type" content="website">`,
		`<meta property="og:url" content="https://goathud.com/">`,
		`<meta property="og:site_name" content="Greptile HUD">`,
		`<meta property="og:title"`,
		`<meta property="og:description"`,
		`<meta name="twitter:card" content="summary">`,
	} {
		if !strings.Contains(page, want) {
			t.Fatalf("%s is missing %q", landingPagePath, want)
		}
	}

	// The card title and description must match the page's own, or previews
	// quietly disagree with the tab.
	title := regexp.MustCompile(`<title>(.*?)</title>`).FindStringSubmatch(page)
	desc := regexp.MustCompile(`<meta name="description" content="([^"]*)"`).FindStringSubmatch(page)
	ogTitle := regexp.MustCompile(`<meta property="og:title" content="([^"]*)"`).FindStringSubmatch(page)
	ogDesc := regexp.MustCompile(`<meta property="og:description" content="([^"]*)"`).FindStringSubmatch(page)
	if len(title) < 2 || len(ogTitle) < 2 || title[1] != ogTitle[1] {
		t.Fatalf("og:title does not match <title>")
	}
	if len(desc) < 2 || len(ogDesc) < 2 || desc[1] != ogDesc[1] {
		t.Fatalf("og:description does not match meta description")
	}
}
