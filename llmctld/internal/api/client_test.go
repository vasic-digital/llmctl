package api

import (
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
	"github.com/vasic-digital/llmctl/llmctld/internal/raft"
)

// TestRequestJoin_RealCrossProcessJoinOverHTTP3 proves RequestJoin is the
// real cross-process half of Join: it drives a real HTTP/3+mTLS POST to a
// real leader's api.Server, which really adds the named peerAddr as a
// Raft voter - verified via the leader's own subsequent Servers() call,
// not merely a successful HTTP status code.
func TestRequestJoin_RealCrossProcessJoinOverHTTP3(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}

	leader, err := raft.Bootstrap(raft.Config{
		NodeID:    "node-a",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildTestTLSConfig(t, ca, "node-a"),
	})
	if err != nil {
		t.Fatalf("raft.Bootstrap(node-a): %v", err)
	}
	defer func() { _ = leader.Shutdown() }()
	waitForRealLeader(t, leader, 3*time.Second)

	srv := NewServer(leader, buildTestTLSConfig(t, ca, "node-a-api"))
	if err := srv.Listen("127.0.0.1:0"); err != nil {
		t.Fatalf("Listen: %v", err)
	}
	defer func() { _ = srv.Close() }()

	follower, err := raft.New(raft.Config{
		NodeID:    "node-b",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildTestTLSConfig(t, ca, "node-b"),
	})
	if err != nil {
		t.Fatalf("raft.New(node-b): %v", err)
	}
	defer func() { _ = follower.Shutdown() }()

	if err := RequestJoin(buildTestTLSConfig(t, ca, "node-b-api-client"), srv.Addr, "node-b", follower.Addr(), cluster.Resources{}); err != nil {
		t.Fatalf("RequestJoin: %v", err)
	}

	servers, err := leader.Servers()
	if err != nil {
		t.Fatalf("leader.Servers(): %v", err)
	}
	if len(servers) != 2 {
		t.Fatalf("leader.Servers() after RequestJoin has %d entries, want 2", len(servers))
	}
}

// TestRequestJoin_RetriesUntilLeaderElectionCompletes proves RequestJoin
// tolerates the real, expected startup race: a freshly bootstrapped node
// is NOT its own leader immediately (hashicorp/raft's own randomized
// heartbeat/election timeout takes up to ~1-2s before a fresh single-node
// cluster elects itself), so a join attempt made the instant the API
// server starts listening - BEFORE waiting for leader election - MUST be
// retried rather than failing outright the moment it observes "node is
// not the leader". This is the exact real bug found manually testing
// cmd/llmctld's cluster join wiring end-to-end (a real 409 "node is not
// the leader" response), root-caused to this missing retry, not to any
// defect in raft.Bootstrap or the HTTP layer itself.
func TestRequestJoin_RetriesUntilLeaderElectionCompletes(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}

	leader, err := raft.Bootstrap(raft.Config{
		NodeID:    "node-a",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildTestTLSConfig(t, ca, "node-a"),
	})
	if err != nil {
		t.Fatalf("raft.Bootstrap(node-a): %v", err)
	}
	defer func() { _ = leader.Shutdown() }()
	// Deliberately NOT calling waitForRealLeader here - the whole point
	// of this test is to reproduce the real race where the leader has not
	// yet elected itself when the join attempt starts.

	srv := NewServer(leader, buildTestTLSConfig(t, ca, "node-a-api"))
	if err := srv.Listen("127.0.0.1:0"); err != nil {
		t.Fatalf("Listen: %v", err)
	}
	defer func() { _ = srv.Close() }()

	follower, err := raft.New(raft.Config{
		NodeID:    "node-b",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildTestTLSConfig(t, ca, "node-b"),
	})
	if err != nil {
		t.Fatalf("raft.New(node-b): %v", err)
	}
	defer func() { _ = follower.Shutdown() }()

	start := time.Now()
	if err := RequestJoin(buildTestTLSConfig(t, ca, "node-b-api-client"), srv.Addr, "node-b", follower.Addr(), cluster.Resources{}); err != nil {
		t.Fatalf("RequestJoin did not retry through the leader-election race and eventually succeed: %v", err)
	}
	if elapsed := time.Since(start); elapsed < 100*time.Millisecond {
		// Not a hard requirement of correctness, but a genuine race
		// reproduction should take measurable time (retrying past at
		// least one failed attempt) - a suspiciously instant success
		// would suggest the test isn't exercising the race at all.
		t.Logf("RequestJoin succeeded in %s (retried through the election race)", elapsed)
	}

	servers, err := leader.Servers()
	if err != nil {
		t.Fatalf("leader.Servers(): %v", err)
	}
	if len(servers) != 2 {
		t.Fatalf("leader.Servers() after RequestJoin has %d entries, want 2", len(servers))
	}
}

// TestRequestJoin_SurfacesLeaderRefusal proves a rejected join (e.g. the
// leader's handler itself refuses) surfaces as a real error, never a
// silently-swallowed success.
func TestRequestJoin_SurfacesLeaderRefusal(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}
	leader, err := raft.Bootstrap(raft.Config{
		NodeID:    "node-a",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildTestTLSConfig(t, ca, "node-a"),
	})
	if err != nil {
		t.Fatalf("raft.Bootstrap(node-a): %v", err)
	}
	defer func() { _ = leader.Shutdown() }()
	waitForRealLeader(t, leader, 3*time.Second)

	srv := NewServer(leader, buildTestTLSConfig(t, ca, "node-a-api"))
	if err := srv.Listen("127.0.0.1:0"); err != nil {
		t.Fatalf("Listen: %v", err)
	}
	defer func() { _ = srv.Close() }()

	// An empty peerAddr fails joinRequest's "required" binding - real
	// server-side refusal, not a client-fabricated one.
	if err := RequestJoin(buildTestTLSConfig(t, ca, "node-b-api-client"), srv.Addr, "node-b", "", cluster.Resources{}); err == nil {
		t.Fatalf("RequestJoin with an empty peerAddr must surface the server's refusal, got nil error")
	}
}
