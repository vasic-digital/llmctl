package cluster

import (
	"sync"
	"testing"
	"time"
)

// TestMonitor_CheckOnce_ReschedulesOnFirstFailureOnly proves Rescheduler
// fires exactly once when a node is first detected unhealthy, not once
// per subsequent CheckOnce call while it remains down (FR-025).
func TestMonitor_CheckOnce_ReschedulesOnFirstFailureOnly(t *testing.T) {
	var mu sync.Mutex
	rescheduled := map[string]int{}

	healthy := map[string]bool{"node-a": true}
	checker := func(addr string) bool {
		mu.Lock()
		defer mu.Unlock()
		return healthy[addr]
	}
	reschedule := func(id string) {
		mu.Lock()
		defer mu.Unlock()
		rescheduled[id]++
	}

	m := NewMonitor(checker, reschedule, time.Hour)
	m.SetNodes(map[string]string{"node-a": "node-a"})

	m.CheckOnce() // healthy, no reschedule
	mu.Lock()
	healthy["node-a"] = false
	mu.Unlock()

	m.CheckOnce() // first failure -> reschedule
	m.CheckOnce() // still failing -> must NOT reschedule again
	m.CheckOnce()

	mu.Lock()
	got := rescheduled["node-a"]
	mu.Unlock()
	if got != 1 {
		t.Fatalf("rescheduled[node-a] = %d, want exactly 1 (fire once per failure episode)", got)
	}
}

// TestMonitor_CheckOnce_ReschedulesAgainAfterRecovery proves a node that
// recovers and later fails again triggers a FRESH reschedule (each
// failure episode is independent).
func TestMonitor_CheckOnce_ReschedulesAgainAfterRecovery(t *testing.T) {
	var mu sync.Mutex
	rescheduled := 0
	healthy := true

	checker := func(addr string) bool {
		mu.Lock()
		defer mu.Unlock()
		return healthy
	}
	reschedule := func(id string) {
		mu.Lock()
		defer mu.Unlock()
		rescheduled++
	}

	m := NewMonitor(checker, reschedule, time.Hour)
	m.SetNodes(map[string]string{"node-a": "node-a"})

	mu.Lock()
	healthy = false
	mu.Unlock()
	m.CheckOnce() // failure 1

	mu.Lock()
	healthy = true
	mu.Unlock()
	m.CheckOnce() // recovers

	mu.Lock()
	healthy = false
	mu.Unlock()
	m.CheckOnce() // failure 2 - a fresh episode

	mu.Lock()
	got := rescheduled
	mu.Unlock()
	if got != 2 {
		t.Fatalf("rescheduled count = %d, want 2 (one per independent failure episode)", got)
	}
}

// TestMonitor_StartStop_RunsPeriodically proves Start() really drives
// CheckOnce on a ticker (real time.Ticker, not a stub), and Stop() really
// halts it.
func TestMonitor_StartStop_RunsPeriodically(t *testing.T) {
	var mu sync.Mutex
	checks := 0
	checker := func(addr string) bool {
		mu.Lock()
		defer mu.Unlock()
		checks++
		return true
	}

	m := NewMonitor(checker, nil, 20*time.Millisecond)
	m.SetNodes(map[string]string{"node-a": "node-a"})
	m.Start()
	time.Sleep(110 * time.Millisecond)
	m.Stop()

	mu.Lock()
	got := checks
	mu.Unlock()
	if got < 3 {
		t.Fatalf("checks = %d after ~110ms at a 20ms interval, want at least 3 real ticks observed", got)
	}

	mu.Lock()
	afterStop := checks
	mu.Unlock()
	time.Sleep(60 * time.Millisecond)
	mu.Lock()
	final := checks
	mu.Unlock()
	if final != afterStop {
		t.Fatalf("checks continued incrementing (%d -> %d) after Stop() - the loop did not really stop", afterStop, final)
	}
}

// TestReconcile_ReplacesUnderReplicatedModel proves the reconciliation
// pass places exactly the deficit count of replacement replicas, on
// healthy candidates not already hosting a live replica (SC-018: 1 of 3
// replicas failed -> availability must hold via a replacement).
func TestReconcile_ReplacesUnderReplicatedModel(t *testing.T) {
	m := NewMonitor(nil, nil, time.Hour)

	states := []ReplicaState{
		{Model: "llama-3-70b", TargetCount: 3, LiveNodeIDs: []string{"node-a", "node-b"}},
	}
	req := PlacementRequest{RAMMB: 1000, VRAMMB: 500, CPUCores: 2, NetworkMbps: 100}
	fit := Resources{RAMAvailMB: 1000, VRAMAvailMB: 500, CPUCores: 2, NetworkMbps: 100}
	candidates := []Node{
		{ID: "node-a", Health: "healthy", Resources: fit}, // already hosts a replica - must be excluded
		{ID: "node-b", Health: "healthy", Resources: fit}, // already hosts a replica - must be excluded
		{ID: "node-c", Health: "healthy", Resources: fit}, // the only real candidate for the replacement
	}

	result := m.Reconcile(states, candidates, req, Place)
	got := result["llama-3-70b"]
	if len(got) != 1 {
		t.Fatalf("Reconcile placed %d replacement(s), want exactly 1 (the deficit)", len(got))
	}
	if got[0] != "node-c" {
		t.Fatalf("Reconcile placed the replacement on %q, want the only non-already-hosting candidate %q", got[0], "node-c")
	}
}

// TestReconcile_NoOpWhenAtTarget proves a fully-replicated model produces
// no placement calls / no result entry - reconciliation must not "fix"
// what isn't broken.
func TestReconcile_NoOpWhenAtTarget(t *testing.T) {
	m := NewMonitor(nil, nil, time.Hour)
	states := []ReplicaState{
		{Model: "llama-3-70b", TargetCount: 3, LiveNodeIDs: []string{"a", "b", "c"}},
	}
	called := false
	fakePlace := func(candidates []Node, req PlacementRequest) (Node, error) {
		called = true
		return Node{}, nil
	}

	result := m.Reconcile(states, nil, PlacementRequest{}, fakePlace)
	if called {
		t.Fatalf("Reconcile invoked place() for a fully-replicated model - must be a no-op")
	}
	if _, present := result["llama-3-70b"]; present {
		t.Fatalf("Reconcile returned a result entry for a fully-replicated model, want none")
	}
}

// TestReconcile_StopsWhenNoHealthyCandidateLeft proves Reconcile never
// fabricates a placement: if Place() genuinely refuses (no capacity left),
// Reconcile returns fewer than the needed count rather than inventing one.
func TestReconcile_StopsWhenNoHealthyCandidateLeft(t *testing.T) {
	m := NewMonitor(nil, nil, time.Hour)
	states := []ReplicaState{
		{Model: "llama-3-70b", TargetCount: 3, LiveNodeIDs: []string{"a"}},
	}
	alwaysRefuse := func(candidates []Node, req PlacementRequest) (Node, error) {
		return Node{}, errPlacementRefusedFixture
	}

	result := m.Reconcile(states, nil, PlacementRequest{}, alwaysRefuse)
	if got := len(result["llama-3-70b"]); got != 0 {
		t.Fatalf("Reconcile fabricated %d placement(s) despite Place() always refusing, want 0", got)
	}
}

var errPlacementRefusedFixture = &placementRefusedFixtureError{}

type placementRefusedFixtureError struct{}

func (*placementRefusedFixtureError) Error() string { return "fixture: no capacity" }
