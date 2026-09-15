package raft

import (
	"encoding/json"
	"fmt"
	"sync"
	"testing"

	hraft "github.com/hashicorp/raft"

	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
)

func mustCommand(t *testing.T, cmd Command) []byte {
	t.Helper()
	b, err := json.Marshal(cmd)
	if err != nil {
		t.Fatalf("marshal command: %v", err)
	}
	return b
}

func TestApply_JoinThenLeave(t *testing.T) {
	fsm := NewClusterFSM()

	joinData := mustCommand(t, Command{Type: CommandJoinNode, Node: &cluster.Node{ID: "n1", Addr: "127.0.0.1:9443", Health: "healthy"}})
	if resp := fsm.Apply(&hraft.Log{Data: joinData}); resp != nil {
		t.Fatalf("apply join: unexpected error %v", resp)
	}
	state := fsm.State()
	if _, ok := state.Nodes["n1"]; !ok {
		t.Fatalf("expected node n1 present after join")
	}

	leaveData := mustCommand(t, Command{Type: CommandLeaveNode, NodeID: "n1"})
	if resp := fsm.Apply(&hraft.Log{Data: leaveData}); resp != nil {
		t.Fatalf("apply leave: unexpected error %v", resp)
	}
	state = fsm.State()
	if _, ok := state.Nodes["n1"]; ok {
		t.Fatalf("expected node n1 absent after leave")
	}
}

// TestApply_DeterministicGivenSameLogSequence proves the core Raft FSM
// contract: the SAME sequence of log entries, applied to a FRESH state,
// always yields byte-identical resulting state - required because every
// node in the cluster replays the same log independently and must converge
// to the same state without further coordination.
func TestApply_DeterministicGivenSameLogSequence(t *testing.T) {
	entries := []Command{
		{Type: CommandJoinNode, Node: &cluster.Node{ID: "n1", Addr: "10.0.0.1:9443", Health: "healthy"}},
		{Type: CommandJoinNode, Node: &cluster.Node{ID: "n2", Addr: "10.0.0.2:9443", Health: "healthy"}},
		{Type: CommandLeaveNode, NodeID: "n1"},
	}

	replay := func() *cluster.ClusterState {
		fsm := NewClusterFSM()
		for _, cmd := range entries {
			data := mustCommand(t, cmd)
			if resp := fsm.Apply(&hraft.Log{Data: data}); resp != nil {
				t.Fatalf("apply %+v: unexpected error %v", cmd, resp)
			}
		}
		return fsm.State()
	}

	s1 := replay()
	s2 := replay()

	b1, _ := json.Marshal(s1)
	b2, _ := json.Marshal(s2)
	if string(b1) != string(b2) {
		t.Fatalf("Apply is not deterministic: %s != %s", b1, b2)
	}
	if len(s1.Nodes) != 1 {
		t.Fatalf("expected exactly 1 node remaining, got %d", len(s1.Nodes))
	}
	if _, ok := s1.Nodes["n2"]; !ok {
		t.Fatalf("expected n2 present in final state")
	}
}

func TestApply_UnknownCommandRejected(t *testing.T) {
	fsm := NewClusterFSM()
	data := mustCommand(t, Command{Type: "bogus"})
	resp := fsm.Apply(&hraft.Log{Data: data})
	if resp == nil {
		t.Fatalf("expected an error for an unknown command type, got nil")
	}
}

// TestSnapshotRestore_RoundTrips proves a Snapshot taken from one FSM,
// restored into a fresh FSM, reproduces the exact same state - the
// mechanism a new/lagging node uses to catch up without replaying the
// entire log.
func TestSnapshotRestore_RoundTrips(t *testing.T) {
	source := NewClusterFSM()
	data := mustCommand(t, Command{Type: CommandJoinNode, Node: &cluster.Node{ID: "n1", Addr: "127.0.0.1:9443", Health: "healthy"}})
	if resp := source.Apply(&hraft.Log{Data: data}); resp != nil {
		t.Fatalf("apply: unexpected error %v", resp)
	}

	snap, err := source.Snapshot()
	if err != nil {
		t.Fatalf("Snapshot: %v", err)
	}

	sink := newMemorySink()
	if err := snap.Persist(sink); err != nil {
		t.Fatalf("Persist: %v", err)
	}

	restored := NewClusterFSM()
	if err := restored.Restore(sink.reader()); err != nil {
		t.Fatalf("Restore: %v", err)
	}

	got := restored.State()
	want := source.State()
	gotJSON, _ := json.Marshal(got)
	wantJSON, _ := json.Marshal(want)
	if string(gotJSON) != string(wantJSON) {
		t.Fatalf("restored state = %s, want %s", gotJSON, wantJSON)
	}
}

// TestApplyAndState_ConcurrentAccessIsRaceFree is a real, previously-
// undiscovered concurrency defect this project's Constitution (§11.4.102
// systematic debugging + the anti-bluff covenant's "never paper over a
// real race") requires be root-caused and fixed rather than silently
// avoided: State()'s own doc comment claims it is "safe for callers
// outside the Raft log-apply goroutine ... to read without racing further
// Apply calls" but NEITHER Apply NOR State ever actually synchronized
// access to f.state - a doc-comment safety claim the code did not keep.
// hashicorp/raft calls Apply from its own single-threaded FSM-apply
// goroutine while State() is called directly by HTTP handlers
// (routes_cluster.go's GET /v1/cluster/status -> node.State() ->
// fsm.State(), and lock.go's Locks() -> fsm.State().Locks) from
// whichever goroutine is serving that request - on any live cluster
// node, a status/locks query landing while a join/leave/lock command is
// being applied races on the exact same cluster.ClusterState map fields
// TestJoin_SecondNodeReplicatesRealAppliedCommand (this package's own
// existing real-process test) independently proved race under
// `go test -race`, found while root-causing an unrelated audit-log race
// during Phase 11's T073 (this project's real HTTP routes started
// receiving genuine concurrent load for the first time, and `-race`
// caught this pre-existing defect too).
//
// TDD RED (observed BEFORE the sync.Mutex fix, via `go test -race
// ./internal/raft/... -run TestApplyAndState_ConcurrentAccessIsRaceFree`):
// the Go race detector reported a genuine `DATA RACE` between Apply's
// map writes and State's Clone() map reads on every run - not a
// flaky/theoretical race, an actually-triggered one. This test stays in
// the suite permanently as the regression guard: it drives Apply calls
// concurrently with State() calls against the SAME FSM (mirroring how
// hashicorp/raft's own apply goroutine runs concurrently with an HTTP
// handler calling State()), and asserts the final state holds exactly
// the expected node count (a lost update under a real race would
// under/over-count) with no panic (a torn concurrent map read/write can
// panic outright, not merely race silently).
func TestApplyAndState_ConcurrentAccessIsRaceFree(t *testing.T) {
	fsm := NewClusterFSM()
	const concurrentApplies = 200

	var wg sync.WaitGroup
	wg.Add(concurrentApplies + concurrentApplies)
	for i := 0; i < concurrentApplies; i++ {
		go func(i int) {
			defer wg.Done()
			data := mustCommand(t, Command{Type: CommandJoinNode, Node: &cluster.Node{ID: fmt.Sprintf("n%d", i), Addr: "127.0.0.1:9443", Health: "healthy"}})
			fsm.Apply(&hraft.Log{Data: data})
		}(i)
	}
	for i := 0; i < concurrentApplies; i++ {
		go func() {
			defer wg.Done()
			_ = fsm.State()
		}()
	}
	wg.Wait()

	final := fsm.State()
	if len(final.Nodes) != concurrentApplies {
		t.Fatalf("expected exactly %d nodes after %d concurrent Apply calls, got %d (a lost update under a real race)", concurrentApplies, concurrentApplies, len(final.Nodes))
	}
}
