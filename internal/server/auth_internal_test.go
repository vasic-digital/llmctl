package server

import (
	"net/http"
	"reflect"
	"testing"

	"github.com/vasic-digital/llmctl/internal/keyring"
)

// The key comparison is the constant-time keyring.KeyMatches and nothing else:
// a functional test cannot see timing, so the seam is pinned structurally.
func TestKeyComparisonIsKeyringKeyMatches(t *testing.T) {
	s := mustNewForInternal(t)
	got := reflect.ValueOf(s.keyMatch).Pointer()
	want := reflect.ValueOf(keyring.KeyMatches).Pointer()
	if got != want {
		t.Fatal("Server.keyMatch must be keyring.KeyMatches (constant time over every accepted key)")
	}
}

func TestAuthConsultsTheMatcherForEveryProtectedRequest(t *testing.T) {
	s := mustNewForInternal(t)
	calls := 0
	s.keyMatch = func(cand string, acc []keyring.Secret) bool {
		calls++
		return keyring.KeyMatches(cand, acc)
	}
	r, _ := http.NewRequest("GET", "/v1/models", nil)
	r.Header.Set("Authorization", "Bearer nope")
	rr := serveRecorded(s, r)
	if rr.Code != 401 || calls != 1 {
		t.Fatalf("code=%d calls=%d", rr.Code, calls)
	}
	// probes never consult it
	calls = 0
	r2, _ := http.NewRequest("GET", "/healthz", nil)
	if rr := serveRecorded(s, r2); rr.Code != 200 || calls != 0 {
		t.Fatalf("probe code=%d calls=%d", rr.Code, calls)
	}
}
