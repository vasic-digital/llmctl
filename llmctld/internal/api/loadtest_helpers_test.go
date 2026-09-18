// Package api (loadtest_helpers_test.go): shared support for
// stress_test.go and ddos_test.go (008-full-test-coverage Phase 4,
// spec.md FR-004/FR-005) - the real HTTP server wrapper, evidence-file
// path resolution, and host-summary line both test files' capacity/
// degradation observations are written under, kept in one place so the
// two tests describe an identical, honestly-documented transport
// boundary rather than two independently-drifting copies.
package api

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
)

// newHTTPTestServerImpl starts a real, locally-listening HTTP/1.1 server
// (a real TCP socket, real net/http.Server, real Accept loop) in front of
// handler - see stress_test.go's package doc comment for why this is the
// honest, deliberate transport substitution for the production
// HTTP/3+mTLS cluster API transport.
func newHTTPTestServerImpl(handler http.Handler) *httptest.Server {
	return httptest.NewServer(handler)
}

// repoRootForEvidence walks upward from the current working directory
// (go test's cwd is always the package directory, internal/api) to find
// the main repository root - identified by the presence of go.mod's
// parent directory ALSO containing a docs/ directory one level up from
// llmctld/ (i.e. the llmctl repo root, not the llmctld Go module root),
// so evidence lands at the SAME docs/qa/008-full-test-coverage/ path
// this feature's other phases write to, never a second, divergent
// evidence tree.
func repoRootForEvidence() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for i := 0; i < 12; i++ {
		// The llmctl repo root is identified by containing BOTH a
		// top-level "llmctld" directory (this Go module) and a
		// top-level "docs" directory - the same two facts a human
		// would use to recognise it, checked directly rather than
		// guessed from a relative "../.." offset that would silently
		// break if this test file ever moved to a different package
		// depth.
		if isDir(filepath.Join(dir, "llmctld")) && isDir(filepath.Join(dir, "docs")) {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return "", fmt.Errorf("repoRootForEvidence: could not find llmctl repo root (with sibling llmctld/ and docs/ directories) walking up from %s", mustGetwd())
}

func isDir(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func mustGetwd() string {
	wd, err := os.Getwd()
	if err != nil {
		return "(unknown)"
	}
	return wd
}

// hostSummary is a one-line, honest description of the host these
// numbers were captured on - GOMAXPROCS is the real, live value (never
// hardcoded), so a future re-run's evidence file is self-describing
// about why its numbers might differ from this one's (Constitution
// §11.4.6: capacity numbers are host-dependent, never a fixed universal
// figure).
func hostSummary() string {
	return fmt.Sprintf("GOOS=%s GOARCH=%s GOMAXPROCS=%d NumCPU=%d",
		runtime.GOOS, runtime.GOARCH, runtime.GOMAXPROCS(0), runtime.NumCPU())
}
