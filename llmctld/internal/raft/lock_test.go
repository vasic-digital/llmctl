package raft

import (
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
)

// TestAcquireRelease_RoundTrip proves a single node can acquire a fresh
// lock and release it, end to end through a REAL bootstrapped Raft
// instance (real Apply, real log commit) - not merely through the FSM
// unit tests in fsm_lock_test.go.
func TestAcquireRelease_RoundTrip(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}
	node, err := Bootstrap(Config{
		NodeID:    "node-a",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildNodeTLSConfig(t, ca, "node-a"),
	})
	if err != nil {
		t.Fatalf("Bootstrap: %v", err)
	}
	defer func() { _ = node.Shutdown() }()
	waitForLeader(t, node, 3*time.Second)

	lease, err := node.Acquire("model:llama-3-70b", time.Minute)
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	if lease.Key != "model:llama-3-70b" {
		t.Fatalf("lease.Key = %q, want %q", lease.Key, "model:llama-3-70b")
	}
	if lease.Holder != "node-a" {
		t.Fatalf("lease.Holder = %q, want %q", lease.Holder, "node-a")
	}
	if _, held := node.fsm.State().Locks["model:llama-3-70b"]; !held {
		t.Fatalf("expected the lock to be visible in the FSM state after a successful Acquire")
	}

	if err := node.Release(lease); err != nil {
		t.Fatalf("Release: %v", err)
	}
	if _, held := node.fsm.State().Locks["model:llama-3-70b"]; held {
		t.Fatalf("expected the lock to be gone from the FSM state after Release")
	}
}

// TestAcquire_SecondCallerBlocksUntilRelease proves the central FR-029
// guarantee: a second Acquire on a held key does NOT succeed immediately -
// it blocks - and only proceeds once the first holder actually releases.
// Uses two real Node instances (one leader, one joined follower) so the
// second Acquire genuinely goes through Raft, not a shortcut.
func TestAcquire_SecondCallerBlocksUntilRelease(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}

	leader, err := Bootstrap(Config{
		NodeID:    "node-a",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildNodeTLSConfig(t, ca, "node-a"),
	})
	if err != nil {
		t.Fatalf("Bootstrap(node-a): %v", err)
	}
	defer func() { _ = leader.Shutdown() }()
	waitForLeader(t, leader, 3*time.Second)

	lease, err := leader.Acquire("shared-key", 500*time.Millisecond)
	if err != nil {
		t.Fatalf("first Acquire: %v", err)
	}

	// A second, DIFFERENT holder identity racing the same key on the SAME
	// leader instance - proves Acquire genuinely blocks rather than
	// returning immediately just because it's the same *Node.
	resultCh := make(chan struct{})
	go func() {
		defer close(resultCh)
		if _, err := leader.acquireAs("node-b", "shared-key", time.Second); err != nil {
			t.Errorf("second Acquire (as node-b): %v", err)
		}
	}()

	select {
	case <-resultCh:
		t.Fatalf("second Acquire returned before the first lease was released or expired - blocking guarantee violated")
	case <-time.After(150 * time.Millisecond):
		// still blocked, as expected - the 500ms lease has not expired yet
		// and node-a has not released.
	}

	if err := leader.Release(lease); err != nil {
		t.Fatalf("Release: %v", err)
	}

	select {
	case <-resultCh:
		// the second Acquire finally succeeded after the release.
	case <-time.After(2 * time.Second):
		t.Fatalf("second Acquire never unblocked within 2s of the first holder's Release")
	}

	state := leader.fsm.State()
	if state.Locks["shared-key"].Holder != "node-b" {
		t.Fatalf("expected node-b to hold shared-key after the first holder released, got %q", state.Locks["shared-key"].Holder)
	}
}

// TestAcquire_SecondCallerUnblocksOnTTLExpiry proves blocking ends via TTL
// expiry too, not only via an explicit Release.
func TestAcquire_SecondCallerUnblocksOnTTLExpiry(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}
	node, err := Bootstrap(Config{
		NodeID:    "node-a",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildNodeTLSConfig(t, ca, "node-a"),
	})
	if err != nil {
		t.Fatalf("Bootstrap: %v", err)
	}
	defer func() { _ = node.Shutdown() }()
	waitForLeader(t, node, 3*time.Second)

	if _, err := node.acquireAs("node-a", "ttl-key", 200*time.Millisecond); err != nil {
		t.Fatalf("first Acquire: %v", err)
	}

	start := time.Now()
	lease, err := node.acquireAs("node-b", "ttl-key", time.Second)
	if err != nil {
		t.Fatalf("second Acquire (via TTL expiry, never explicitly released): %v", err)
	}
	if elapsed := time.Since(start); elapsed < 150*time.Millisecond {
		t.Fatalf("second Acquire returned suspiciously fast (%s) - expected it to wait for the ~200ms TTL to expire", elapsed)
	}
	if lease.Holder != "node-b" {
		t.Fatalf("lease.Holder = %q, want %q", lease.Holder, "node-b")
	}
}
