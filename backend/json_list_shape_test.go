package main

// Coverage for the JSON shape of empty lists on read endpoints.
//
// Every list the HUD decodes (`online`, `entries`, `statuses`, `banners`,
// `sessions`) is a non-optional Swift array, so a `null` in its place fails the
// whole decode — a quiet crew would see an error instead of an empty list.
// `encoding/json` only marshals `[]` for a slice that was allocated; a nil
// slice (a plain `var out []T`) marshals as `null`. handleLeaderboard and
// handleOnline were the last two handlers still doing that, so an empty
// leaderboard or a crew with nobody online during the last five minutes broke
// the Crew refresh. This test pins the rule for every JSON handler so a new
// endpoint can't quietly reintroduce `null`.
//
// Stdlib only — an AST walk like TestNoUncappedJSONBodyDecoders, since the
// handlers need Postgres to exercise at runtime.

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// isServerHandler reports whether fn is a `func (s *server) handle…` method —
// the handlers whose JSON body reaches the HUD.
func isServerHandler(fn *ast.FuncDecl) bool {
	if fn.Recv == nil || len(fn.Recv.List) != 1 || len(fn.Name.Name) < 6 {
		return false
	}
	if !strings.HasPrefix(fn.Name.Name, "handle") {
		return false
	}
	star, ok := fn.Recv.List[0].Type.(*ast.StarExpr)
	if !ok {
		return false
	}
	recv, ok := star.X.(*ast.Ident)
	return ok && recv.Name == "server"
}

// TestJSONHandlersNeverSendNilSlices fails on a handler that hands writeJSON a
// slice declared without an initializer (`var out []T`). Those marshal as
// `null`; `make([]T, 0)` marshals as `[]`, which is what the HUD decodes.
func TestJSONHandlersNeverSendNilSlices(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatalf("glob: %v", err)
	}
	handlers := 0
	for _, name := range files {
		if strings.HasSuffix(name, "_test.go") {
			continue
		}
		fset := token.NewFileSet()
		f, err := parser.ParseFile(fset, name, nil, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", name, err)
		}
		src, err := os.ReadFile(name)
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		for _, decl := range f.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Body == nil || !isServerHandler(fn) {
				continue
			}
			handlers++

			// Identifiers that reach writeJSON, directly or inside a response
			// map literal. Only those slices have to be non-nil.
			jsonVars := map[string]bool{}
			ast.Inspect(fn.Body, func(n ast.Node) bool {
				call, ok := n.(*ast.CallExpr)
				if !ok {
					return true
				}
				if id, ok := call.Fun.(*ast.Ident); !ok || id.Name != "writeJSON" {
					return true
				}
				for _, arg := range call.Args {
					ast.Inspect(arg, func(m ast.Node) bool {
						if id, ok := m.(*ast.Ident); ok {
							jsonVars[id.Name] = true
						}
						return true
					})
				}
				return true
			})
			if len(jsonVars) == 0 {
				continue
			}

			ast.Inspect(fn.Body, func(n ast.Node) bool {
				ds, ok := n.(*ast.DeclStmt)
				if !ok {
					return true
				}
				gd, ok := ds.Decl.(*ast.GenDecl)
				if !ok || gd.Tok != token.VAR {
					return true
				}
				for _, spec := range gd.Specs {
					vs, ok := spec.(*ast.ValueSpec)
					if !ok || vs.Type == nil || len(vs.Values) > 0 {
						continue
					}
					if _, ok := vs.Type.(*ast.ArrayType); !ok {
						continue
					}
					for _, id := range vs.Names {
						if !jsonVars[id.Name] {
							continue
						}
						typeText := string(src[fset.Position(vs.Type.Pos()).Offset:fset.Position(vs.Type.End()).Offset])
						t.Errorf("%s: %s sends %q to writeJSON from a nil slice (var %s %s); use make(%s, 0) so an empty list encodes as [] and not null",
							filepath.Base(name), fn.Name.Name, id.Name, id.Name, typeText, typeText)
					}
				}
				return true
			})
		}
	}
	if handlers == 0 {
		t.Fatal("scanned no server handlers, the glob or receiver check must be wrong")
	}
}
