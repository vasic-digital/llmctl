package replication

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

// fixtureAuthToken is a deliberately non-credential-shaped fixture value
// standing in for a real JWT in this file's tests - the forwarder's own
// logic (does it carry the caller-supplied token through as a Bearer
// header, unmodified) is what's under test, never a real secret.
const fixtureAuthToken = "fixture-jwt-abc123"

// startForwardTargetServer boots a plain httptest.Server exposing the
// SAME /v1/replication/append + /v1/replication/checkpoint wire contract
// internal/api/routes_replication.go's real routes expose, recording
// every request it receives - the forwarder's own logic (which replicas
// get called, with what body, honoring the role/addr resolvers) is fully
// testable against this without needing a real HTTP/3+mTLS listener;
// forwarder.go's httpClient field is caller-supplied specifically so a
// real production caller can inject http3.Transport while tests inject
// this plain server's default client (matching this codebase's existing
// "decouple the transport from the logic" convention).
type recordedForwardRequest struct {
	path  string
	token string
	body  []byte
}

func startForwardTargetServer(t *testing.T) (baseURL string, requests *[]recordedForwardRequest, mu *sync.Mutex) {
	t.Helper()
	var recorded []recordedForwardRequest
	var m sync.Mutex
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body := make([]byte, r.ContentLength)
		_, _ = r.Body.Read(body)
		m.Lock()
		recorded = append(recorded, recordedForwardRequest{path: r.URL.Path, token: r.Header.Get("Authorization"), body: body})
		m.Unlock()
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)
	return srv.URL, &recorded, &m
}

// TestForwarder_ForwardAppend_OnlyWhenSelfIsPrimary proves ForwardAppend
// is an honest no-op (never an error, never a spurious call) when
// SelfID is not the tenant's CURRENT recorded primary - a stale/replica
// node must never itself fan out (FR-011: exactly one authoritative
// forwarding source).
func TestForwarder_ForwardAppend_OnlyWhenSelfIsPrimary(t *testing.T) {
	baseURL, requests, mu := startForwardTargetServer(t)

	roles := RoleResolver(func(tenantID string) (primaryID string, replicaIDs []string, ok bool) {
		return "node-a", []string{"node-b"}, true
	})
	addrs := AddrResolver(func(nodeID string) (string, bool) {
		return baseURL, true
	})

	// selfID = node-b, but node-a is primary - node-b must NOT forward.
	fwd := NewForwarder("node-b", roles, addrs, http.DefaultClient)
	if err := fwd.ForwardAppend("tenant-a", fixtureAuthToken, []WALEntry{{Seq: 1, TokenID: 7, Position: 0}}); err != nil {
		t.Fatalf("ForwardAppend as a non-primary: unexpected error %v", err)
	}
	mu.Lock()
	got := len(*requests)
	mu.Unlock()
	if got != 0 {
		t.Fatalf("non-primary node-b forwarded %d request(s), want 0", got)
	}
}

// TestForwarder_ForwardAppend_PostsRealRequestToEveryReplica proves the
// primary forwards a real POST /v1/replication/append to EVERY replica
// address the RoleResolver names (excluding itself, if it appears in the
// list), carrying the entries as JSON and the caller-supplied token as an
// Authorization header - the exact wire contract routes_replication.go's
// real append handler expects.
func TestForwarder_ForwardAppend_PostsRealRequestToEveryReplica(t *testing.T) {
	baseURL, requests, mu := startForwardTargetServer(t)

	roles := RoleResolver(func(tenantID string) (string, []string, bool) {
		return "node-a", []string{"node-a", "node-b", "node-c"}, true
	})
	addrs := AddrResolver(func(nodeID string) (string, bool) {
		return baseURL, true
	})

	fwd := NewForwarder("node-a", roles, addrs, http.DefaultClient)
	entries := []WALEntry{{Seq: 1, TokenID: 7, Position: 0}, {Seq: 2, TokenID: 9, Position: 1}}
	if err := fwd.ForwardAppend("tenant-a", fixtureAuthToken, entries); err != nil {
		t.Fatalf("ForwardAppend: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()
	// node-a is itself the primary, so it must be excluded from its own
	// forward fan-out - exactly 2 requests (node-b, node-c), never 3.
	if got, want := len(*requests), 2; got != want {
		t.Fatalf("forwarded to %d replica(s), want %d (excluding self)", got, want)
	}
	wantAuthHeader := "Bearer " + fixtureAuthToken
	for _, req := range *requests {
		if req.path != "/v1/replication/append" {
			t.Fatalf("forwarded to path %q, want /v1/replication/append", req.path)
		}
		if req.token != wantAuthHeader {
			t.Fatalf("forwarded Authorization header = %q, want %q", req.token, wantAuthHeader)
		}
		var body forwardAppendRequest
		if err := json.Unmarshal(req.body, &body); err != nil {
			t.Fatalf("unmarshal forwarded body: %v", err)
		}
		if len(body.Entries) != 2 || body.Entries[0].Seq != 1 || body.Entries[1].TokenID != 9 {
			t.Fatalf("forwarded entries = %+v, want the original 2 entries", body.Entries)
		}
	}
}

// TestForwarder_ForwardCheckpoint_PostsRealRequest proves
// ForwardCheckpoint posts the real checkpoint wire contract to every
// replica, mirroring ForwardAppend's own proof.
func TestForwarder_ForwardCheckpoint_PostsRealRequest(t *testing.T) {
	baseURL, requests, mu := startForwardTargetServer(t)

	roles := RoleResolver(func(tenantID string) (string, []string, bool) {
		return "node-a", []string{"node-b"}, true
	})
	addrs := AddrResolver(func(nodeID string) (string, bool) { return baseURL, true })

	fwd := NewForwarder("node-a", roles, addrs, http.DefaultClient)
	state := KVState{Tokens: []int32{7, 9}, Positions: []int32{0, 1}}
	if err := fwd.ForwardCheckpoint("tenant-a", fixtureAuthToken, 2, state); err != nil {
		t.Fatalf("ForwardCheckpoint: %v", err)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(*requests) != 1 {
		t.Fatalf("forwarded %d checkpoint request(s), want 1", len(*requests))
	}
	if (*requests)[0].path != "/v1/replication/checkpoint" {
		t.Fatalf("forwarded to path %q, want /v1/replication/checkpoint", (*requests)[0].path)
	}
	var body forwardCheckpointRequest
	if err := json.Unmarshal((*requests)[0].body, &body); err != nil {
		t.Fatalf("unmarshal forwarded body: %v", err)
	}
	if body.Seq != 2 || len(body.State.Tokens) != 2 {
		t.Fatalf("forwarded checkpoint body = %+v, want Seq=2 and 2 tokens", body)
	}
}

// TestForwarder_UnresolvableReplicaAddr_SkippedNotBlocked proves a
// replica the AddrResolver cannot resolve is honestly skipped (never an
// error, never a hang) - a node this daemon does not know how to reach
// cannot be forwarded to no matter how long it waits (FR-004's
// bounded-not-indefinite guarantee, applied to the "no address at all"
// case specifically, distinct from "address known but unreachable").
func TestForwarder_UnresolvableReplicaAddr_SkippedNotBlocked(t *testing.T) {
	baseURL, requests, mu := startForwardTargetServer(t)

	roles := RoleResolver(func(tenantID string) (string, []string, bool) {
		return "node-a", []string{"node-b", "node-ghost"}, true
	})
	addrs := AddrResolver(func(nodeID string) (string, bool) {
		if nodeID == "node-ghost" {
			return "", false
		}
		return baseURL, true
	})

	fwd := NewForwarder("node-a", roles, addrs, http.DefaultClient)
	if err := fwd.ForwardAppend("tenant-a", fixtureAuthToken, []WALEntry{{Seq: 1}}); err != nil {
		t.Fatalf("ForwardAppend with one unresolvable replica: unexpected error %v", err)
	}
	mu.Lock()
	got := len(*requests)
	mu.Unlock()
	if got != 1 {
		t.Fatalf("forwarded to %d resolvable replica(s), want exactly 1 (node-ghost skipped)", got)
	}
}

// TestForwarder_UnreachableReplica_BoundedNotIndefinite proves a
// GENUINELY unreachable (address known, but nothing is listening)
// replica's forward attempt returns within a bounded time - spec.md
// FR-004: "the attempt must be retried (bounded, not indefinitely
// blocking the primary's own ability to keep serving the conversation)".
// A real closed TCP port (no listener) - not a mock - is used so this is
// a genuine network-failure reproduction, not a simulated one.
func TestForwarder_UnreachableReplica_BoundedNotIndefinite(t *testing.T) {
	// A real listener bound then immediately closed - the port is
	// guaranteed to have nothing listening on it, a real "connection
	// refused" condition rather than an assumed-unused port number.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("net.Listen: %v", err)
	}
	deadAddr := "http://" + ln.Addr().String()
	if err := ln.Close(); err != nil {
		t.Fatalf("close listener: %v", err)
	}

	roles := RoleResolver(func(tenantID string) (string, []string, bool) {
		return "node-a", []string{"node-b"}, true
	})
	addrs := AddrResolver(func(nodeID string) (string, bool) { return deadAddr, true })

	fwd := NewForwarder("node-a", roles, addrs, &http.Client{Timeout: 500 * time.Millisecond})
	start := time.Now()
	_ = fwd.ForwardAppend("tenant-a", fixtureAuthToken, []WALEntry{{Seq: 1}})
	elapsed := time.Since(start)
	// forwardRetryBudget bounds the retry loop - this must complete well
	// under a generous multiple of it, proving no indefinite/unbounded
	// blocking occurred (an actual hang would exceed this comfortably).
	if elapsed > 5*time.Second {
		t.Fatalf("ForwardAppend against an unreachable replica took %s, want well under 5s (FR-004 bounded, not indefinite)", elapsed)
	}
}
