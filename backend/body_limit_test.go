package main

// Coverage for the request-body cap every small JSON write endpoint shares.
// The service is public and unauthenticated (trust-based usernames), so an
// uncapped decode is a cheap way to make the box read an arbitrary body into
// memory and then to disk. usage.go, avatar.go and status_history.go's upload
// already capped themselves; statuses.go, banners.go, the history delete and
// pulse.go did not until decodeJSONBody centralised it.
//
// These tests pin the cap itself (a counting reader proves the read stops at
// the limit rather than at EOF), the endpoints that rely on it (each must
// answer 400 for an oversized body instead of decoding it), and the invariant
// that no handler can drift back to a bare json.NewDecoder(r.Body).
// Stdlib only — no new dependency.

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

// countingReader reports how many bytes were pulled from it, so a test can tell
// "the decoder stopped at the cap" from "the decoder read the whole body".
type countingReader struct {
	data []byte
	off  int
}

func (c *countingReader) Read(p []byte) (int, error) {
	if c.off >= len(c.data) {
		return 0, io.EOF
	}
	n := copy(p, c.data[c.off:])
	c.off += n
	return n, nil
}

// oversizedJSON builds a JSON object with a single huge string value: valid
// JSON, far past maxJSONBodyBytes.
func oversizedJSON(size int) string {
	return `{"pad":"` + strings.Repeat("a", size) + `"}`
}

func TestDecodeJSONBodyStopsAtTheCap(t *testing.T) {
	body := oversizedJSON(maxJSONBodyBytes * 4)
	cr := &countingReader{data: []byte(body)}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/status", nil)
	req.Body = io.NopCloser(cr)

	var out struct {
		Pad string `json:"pad"`
	}
	if err := decodeJSONBody(rec, req, &out); err == nil {
		t.Fatal("decodeJSONBody accepted a body well past maxJSONBodyBytes")
	}

	// MaxBytesReader reads at most limit+1 bytes before refusing, so the whole
	// body (4x the cap) must never be drained.
	if cr.off > maxJSONBodyBytes+1 {
		t.Fatalf("decodeJSONBody read %d bytes, want at most %d", cr.off, maxJSONBodyBytes+1)
	}
}

func TestDecodeJSONBodyAcceptsBodyUnderTheCap(t *testing.T) {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/status", strings.NewReader(`{"user":"zayd"}`))

	var out struct {
		User string `json:"user"`
	}
	if err := decodeJSONBody(rec, req, &out); err != nil {
		t.Fatalf("decodeJSONBody(small body) = %v, want nil", err)
	}
	if out.User != "zayd" {
		t.Fatalf("decoded user = %q, want zayd", out.User)
	}
}

func TestDecodeJSONBodyRejectsMissingBody(t *testing.T) {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/status", nil)
	req.Body = nil

	var out map[string]any
	if err := decodeJSONBody(rec, req, &out); err != errNoBody {
		t.Fatalf("decodeJSONBody(nil body) = %v, want errNoBody", err)
	}
}

// Every handler that decodes a small JSON write payload must refuse an
// oversized body with 400 before it touches the database — s is a bare
// &server{} here on purpose: if a handler got past the decode it would panic
// on the nil db, which fails the test loudly instead of passing quietly.
func TestWriteHandlersRejectOversizedBody(t *testing.T) {
	s := &server{}
	big := oversizedJSON(maxJSONBodyBytes * 2)

	cases := []struct {
		name    string
		handler http.HandlerFunc
		method  string
		want    string
	}{
		{"post status", s.handleSetStatus, http.MethodPost, "invalid status payload"},
		{"delete status", s.handleClearStatus, http.MethodDelete, "invalid status payload"},
		{"post banner", s.handlePostBanner, http.MethodPost, "invalid banner payload"},
		{"delete banner", s.handleDeleteBanner, http.MethodDelete, "invalid banner payload"},
		{"delete history", s.handleDeleteStatusHistory, http.MethodDelete, "invalid history payload"},
		{"delete avatar", s.handleDeleteAvatar, http.MethodDelete, "invalid avatar payload"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			req := httptest.NewRequest(tc.method, "/api/x", strings.NewReader(big))
			tc.handler(rec, req)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want %d", rec.Code, http.StatusBadRequest)
			}
			if body := rec.Body.String(); !strings.Contains(body, tc.want) {
				t.Fatalf("body = %q, want it to contain %q", body, tc.want)
			}
		})
	}
}

// pulse.go is deliberately lenient about a bad body — it still answers 400
// because the username is missing — but the read must be capped all the same.
func TestPulseRejectsOversizedBody(t *testing.T) {
	s := &server{}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/pulse",
		strings.NewReader(oversizedJSON(maxJSONBodyBytes*2)))
	s.handlePulse(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusBadRequest)
	}
}

// No handler may decode r.Body without a cap. A new endpoint copying the old
// `json.NewDecoder(r.Body)` line would silently reopen the hole, so walk the
// package's own AST looking for a json.NewDecoder call whose argument is not
// an http.MaxBytesReader (the inline cap the big-payload endpoints use).
func TestNoUncappedJSONBodyDecoders(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatalf("glob: %v", err)
	}
	checked := 0
	for _, name := range files {
		if strings.HasSuffix(name, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(token.NewFileSet(), name, nil, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", name, err)
		}
		checked++
		// Idents bound from http.MaxBytesReader count as capped, so a handler
		// that stages the reader in a variable first (as handlePutAvatar does)
		// satisfies the rule.
		capped := map[string]bool{}
		ast.Inspect(f, func(n ast.Node) bool {
			as, ok := n.(*ast.AssignStmt)
			if !ok || len(as.Lhs) != len(as.Rhs) {
				return true
			}
			for i, lhs := range as.Lhs {
				call, ok := as.Rhs[i].(*ast.CallExpr)
				if !ok {
					continue
				}
				sel, ok := call.Fun.(*ast.SelectorExpr)
				if !ok || sel.Sel.Name != "MaxBytesReader" {
					continue
				}
				if id, ok := lhs.(*ast.Ident); ok {
					capped[id.Name] = true
				}
			}
			return true
		})
		ast.Inspect(f, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok || len(call.Args) != 1 {
				return true
			}
			sel, ok := call.Fun.(*ast.SelectorExpr)
			if !ok || sel.Sel.Name != "NewDecoder" {
				return true
			}
			if pkg, ok := sel.X.(*ast.Ident); !ok || pkg.Name != "json" {
				return true
			}
			if inner, ok := call.Args[0].(*ast.CallExpr); ok {
				if isel, ok := inner.Fun.(*ast.SelectorExpr); ok && isel.Sel.Name == "MaxBytesReader" {
					return true
				}
			}
			if id, ok := call.Args[0].(*ast.Ident); ok && capped[id.Name] {
				return true
			}
			t.Errorf("%s: json.NewDecoder on an uncapped body; use decodeJSONBody or http.MaxBytesReader", name)
			return true
		})
	}
	if checked == 0 {
		t.Fatal("scanned no sources, the glob must be wrong")
	}
}
