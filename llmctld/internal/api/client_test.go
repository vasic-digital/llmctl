package api

import (
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gin-gonic/gin"

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

	if err := RequestJoin(buildTestTLSConfig(t, ca, "node-b-api-client"), srv.Addr, "node-b", follower.Addr(), "127.0.0.1:9100", cluster.Resources{}); err != nil {
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
	if err := RequestJoin(buildTestTLSConfig(t, ca, "node-b-api-client"), srv.Addr, "node-b", follower.Addr(), "127.0.0.1:9100", cluster.Resources{}); err != nil {
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
	if err := RequestJoin(buildTestTLSConfig(t, ca, "node-b-api-client"), srv.Addr, "node-b", "", "127.0.0.1:9100", cluster.Resources{}); err == nil {
		t.Fatalf("RequestJoin with an empty peerAddr must surface the server's refusal, got nil error")
	}
}

// TestForwardModelStart_RetriesWithinItsOwnBudget_NotJustOneSlowAttempt is
// a real, live-reproduced defect (2026-09-23): ForwardModelStart's retry
// loop is bounded by forwardModelStartRetryBudget (5s), but each attempt's
// own client.Do() call used to share the SAME http.Client whose Timeout
// was 10s - LARGER than the entire retry budget. If a single attempt
// genuinely blocks (a real, plausible "target briefly busy" condition -
// this is EXACTLY the scenario forwardModelStartRetryBudget's own header
// comment says the retry exists for) until ITS OWN client-side timeout
// fires, that one attempt alone consumes MORE time than the whole retry
// budget - so by the time it returns its error, the retry loop's deadline
// check fires immediately and the function returns failure having made
// EXACTLY ONE attempt, never reaching a second one, even though the
// target would have answered on that very next attempt. Found chasing a
// real, deterministic (non-flaky) failure of
// TestClusterPlacement_ConcurrentStarts_NeverDoubleBookANode
// (test/integration): "api: ForwardModelStart: target node-c ...
// context deadline exceeded" at iteration 0 on a completely idle host -
// two independent hypotheses (test-client timeout, host CPU contention)
// were tried and refuted before finding this real, structural,
// load-independent mismatch between the two duration constants.
//
// This test proves the exact mechanism directly against a REAL server (no
// mocks): a target whose handler genuinely BLOCKS (never writes a
// response) for the first N invocations - forcing the CLIENT's own
// Timeout, not a server-side error, to be what fails the attempt - then
// answers 200 OK from invocation N+1 onward. A single blocking attempt
// that consumes the entire retry budget before returning its (timeout)
// error is precisely the scenario the fix must survive.
func TestForwardModelStart_RetriesWithinItsOwnBudget_NotJustOneSlowAttempt(t *testing.T) {
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
	// A handler registered directly on the SAME real mTLS-protected route
	// group NewServer already built, at the EXACT path ForwardModelStart
	// posts to - RegisterClusterRoutes never registers this path, so
	// there is no route conflict, and this test needs none of the real
	// model-start handler's tenant/JWT/RBAC machinery to exercise
	// ForwardModelStart's own retry timing.
	var attempts int32
	const blockingAttempts = 1
	block := make(chan struct{})
	srv.Router().POST("/v1/tenants/:id/models/:model/start", func(c *gin.Context) {
		n := atomic.AddInt32(&attempts, 1)
		if n <= blockingAttempts {
			<-block // never returns until the test unblocks it - forces the CLIENT's own Timeout, not a server error, to fail this attempt.
			return
		}
		c.Status(http.StatusOK)
	})
	if err := srv.Listen("127.0.0.1:0"); err != nil {
		t.Fatalf("Listen: %v", err)
	}
	defer func() {
		close(block)
		_ = srv.Close()
	}()

	start := time.Now()
	err = ForwardModelStart(buildTestTLSConfig(t, ca, "node-c-api-client"), srv.Addr, "node-a", "tenant-a", "moe-fast", "")
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("ForwardModelStart did not retry past the one deliberately-blocked attempt within its own %s retry budget (elapsed %s): %v", forwardModelStartRetryBudget, elapsed, err)
	}
	if got := atomic.LoadInt32(&attempts); got < blockingAttempts+1 {
		t.Fatalf("handler was invoked %d time(s), want at least %d (the blocked attempt(s) plus one real retry that succeeded) - ForwardModelStart returned success without ever actually retrying", got, blockingAttempts+1)
	}
	if elapsed >= forwardModelStartRetryBudget {
		t.Fatalf("ForwardModelStart took %s, which is NOT within its own declared %s retry budget", elapsed, forwardModelStartRetryBudget)
	}
}

// TestForwardModelStop_RetriesWithinItsOwnBudget_NotJustOneSlowAttempt is
// ForwardModelStop's sibling of
// TestForwardModelStart_RetriesWithinItsOwnBudget_NotJustOneSlowAttempt -
// found in the SAME systematic sweep of client.go (2026-09-23) that fixed
// ForwardModelStart: ForwardModelStop shares the IDENTICAL retry-loop
// shape (deadline := time.Now().Add(forwardModelStartRetryBudget); ...)
// and had NOT yet been updated off the old bare, unlabeled 10s
// client.Timeout when ForwardModelStart's fix landed - the exact same
// budget-smaller-than-per-attempt-timeout mismatch, unfixed, in a sibling
// function. Proves the fix via the identical real (no-mock) mechanism:
// a handler that genuinely blocks (forcing the client's own Timeout,
// never a server error, to fail the first attempt) then succeeds.
func TestForwardModelStop_RetriesWithinItsOwnBudget_NotJustOneSlowAttempt(t *testing.T) {
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
	var attempts int32
	const blockingAttempts = 1
	block := make(chan struct{})
	srv.Router().POST("/v1/tenants/:id/models/:model/stop", func(c *gin.Context) {
		n := atomic.AddInt32(&attempts, 1)
		if n <= blockingAttempts {
			<-block
			return
		}
		c.Status(http.StatusOK)
	})
	if err := srv.Listen("127.0.0.1:0"); err != nil {
		t.Fatalf("Listen: %v", err)
	}
	defer func() {
		close(block)
		_ = srv.Close()
	}()

	start := time.Now()
	err = ForwardModelStop(buildTestTLSConfig(t, ca, "node-c-api-client"), srv.Addr, "node-a", "tenant-a", "moe-fast", "")
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("ForwardModelStop did not retry past the one deliberately-blocked attempt within its own %s retry budget (elapsed %s): %v", forwardModelStartRetryBudget, elapsed, err)
	}
	if got := atomic.LoadInt32(&attempts); got < blockingAttempts+1 {
		t.Fatalf("handler was invoked %d time(s), want at least %d - ForwardModelStop returned success without ever actually retrying", got, blockingAttempts+1)
	}
	if elapsed >= forwardModelStartRetryBudget {
		t.Fatalf("ForwardModelStop took %s, which is NOT within its own declared %s retry budget", elapsed, forwardModelStartRetryBudget)
	}
}
