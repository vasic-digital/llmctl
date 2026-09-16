package raft

import (
	"encoding/json"
	"fmt"
	"sync"
	"testing"
	"time"

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
	// fixedAssignedAt is computed ONCE, outside replay(), and reused
	// verbatim in both the CommandAssignReplicationRole and
	// CommandReassignReplicationRole entries below - mirroring how a real
	// proposer computes AssignedAt exactly once and carries it inside the
	// log entry itself (state.go's ReplicationRole.AssignedAt doc
	// comment), so replaying the SAME entries slice twice must yield
	// byte-identical state even though this test - unlike a real
	// proposer - constructs the entries before either replay runs.
	fixedAssignedAt := time.Now()
	entries := []Command{
		{Type: CommandJoinNode, Node: &cluster.Node{ID: "n1", Addr: "10.0.0.1:9443", Health: "healthy", Resources: cluster.Resources{RAMAvailMB: 1000, VRAMAvailMB: 1000, CPUCores: 4, NetworkMbps: 1000}}},
		{Type: CommandJoinNode, Node: &cluster.Node{ID: "n2", Addr: "10.0.0.2:9443", Health: "healthy", Resources: cluster.Resources{RAMAvailMB: 2000, VRAMAvailMB: 2000, CPUCores: 8, NetworkMbps: 1000}}},
		{Type: CommandUpdateResources, NodeID: "n2", Resources: cluster.Resources{RAMAvailMB: 1500, VRAMAvailMB: 1500, CPUCores: 8, NetworkMbps: 1000}},
		{Type: CommandRecordRunningProfile, Profile: "small", TenantID: "tenant-a", NodeID: "n2", StartedAt: time.Unix(1000, 0), Footprint: cluster.PlacementRequest{RAMMB: 500, VRAMMB: 500, CPUCores: 2, NetworkMbps: 100}},
		{Type: CommandLeaveNode, NodeID: "n1"},
		{Type: CommandClearRunningProfile, Profile: "small", TenantID: "tenant-a", NodeID: "n2"},
		{Type: CommandAssignReplicationRole, ReplicationRole: &cluster.ReplicationRole{TenantID: "t1", PrimaryNodeID: "n2", AssignedAt: fixedAssignedAt}},
		{Type: CommandReassignReplicationRole, ReplicationRole: &cluster.ReplicationRole{TenantID: "t1", PrimaryNodeID: "n2", ReplicaNodeIDs: []string{}, AssignedAt: fixedAssignedAt}},
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

// TestApply_JoinNode_PopulatesClusterStateNodes is 002-cluster-model-
// scheduler's T003 verification task: confirms CommandJoinNode's Apply
// case already correctly populates ClusterState.Nodes (it does - this is
// a pre-existing, already-passing FSM behavior; the real gap this
// feature closes is that node.go's Join/Leave never actually SUBMIT this
// command against a real running cluster, not that Apply mishandles it
// when submitted). Named to match the task's own literal deliverable
// rather than only relying on the pre-existing TestApply_JoinThenLeave.
func TestApply_JoinNode_PopulatesClusterStateNodes(t *testing.T) {
	fsm := NewClusterFSM()
	data := mustCommand(t, Command{Type: CommandJoinNode, Node: &cluster.Node{ID: "n1", Addr: "127.0.0.1:9443", APIAddr: "127.0.0.1:8443", Health: "healthy"}})
	if resp := fsm.Apply(&hraft.Log{Data: data}); resp != nil {
		t.Fatalf("apply join_node: unexpected error %v", resp)
	}
	got, ok := fsm.State().Nodes["n1"]
	if !ok {
		t.Fatalf("expected node n1 present in ClusterState.Nodes after CommandJoinNode")
	}
	if got.APIAddr != "127.0.0.1:8443" {
		t.Fatalf("APIAddr = %q, want %q", got.APIAddr, "127.0.0.1:8443")
	}
}

// TestApply_LeaveNode_RemovesFromClusterStateNodes is T003's sibling
// verification test for CommandLeaveNode.
func TestApply_LeaveNode_RemovesFromClusterStateNodes(t *testing.T) {
	fsm := NewClusterFSM()
	joinData := mustCommand(t, Command{Type: CommandJoinNode, Node: &cluster.Node{ID: "n1", Addr: "127.0.0.1:9443", Health: "healthy"}})
	if resp := fsm.Apply(&hraft.Log{Data: joinData}); resp != nil {
		t.Fatalf("apply join_node: unexpected error %v", resp)
	}
	leaveData := mustCommand(t, Command{Type: CommandLeaveNode, NodeID: "n1"})
	if resp := fsm.Apply(&hraft.Log{Data: leaveData}); resp != nil {
		t.Fatalf("apply leave_node: unexpected error %v", resp)
	}
	if _, ok := fsm.State().Nodes["n1"]; ok {
		t.Fatalf("expected node n1 absent from ClusterState.Nodes after CommandLeaveNode")
	}
}

// TestApply_UpdateResources_RefreshesExistingNode is T007's RED test:
// CommandUpdateResources must replace an already-known node's Resources
// in place, leaving every other field (ID/Addr/APIAddr/Health)
// untouched.
func TestApply_UpdateResources_RefreshesExistingNode(t *testing.T) {
	fsm := NewClusterFSM()
	joinData := mustCommand(t, Command{Type: CommandJoinNode, Node: &cluster.Node{
		ID: "n1", Addr: "127.0.0.1:9443", APIAddr: "127.0.0.1:8443", Health: "healthy",
		Resources: cluster.Resources{RAMAvailMB: 1000},
	}})
	if resp := fsm.Apply(&hraft.Log{Data: joinData}); resp != nil {
		t.Fatalf("apply join_node: unexpected error %v", resp)
	}

	updateData := mustCommand(t, Command{Type: CommandUpdateResources, NodeID: "n1", Resources: cluster.Resources{RAMAvailMB: 500, VRAMAvailMB: 200, CPUCores: 4, NetworkMbps: 1000}})
	if resp := fsm.Apply(&hraft.Log{Data: updateData}); resp != nil {
		t.Fatalf("apply update_resources: unexpected error %v", resp)
	}

	got := fsm.State().Nodes["n1"]
	if got.Resources.RAMAvailMB != 500 || got.Resources.VRAMAvailMB != 200 || got.Resources.CPUCores != 4 || got.Resources.NetworkMbps != 1000 {
		t.Fatalf("Resources not refreshed: got %+v", got.Resources)
	}
	if got.APIAddr != "127.0.0.1:8443" || got.Addr != "127.0.0.1:9443" || got.Health != "healthy" {
		t.Fatalf("CommandUpdateResources must not touch ID/Addr/APIAddr/Health, got %+v", got)
	}
}

// TestApply_UpdateResources_UnknownNodeRefused is T007's second RED
// test: a resource update for a node that is not currently a cluster
// member is a real error condition, never silently accepted (a stale or
// mistargeted update must not fabricate a node entry).
func TestApply_UpdateResources_UnknownNodeRefused(t *testing.T) {
	fsm := NewClusterFSM()
	data := mustCommand(t, Command{Type: CommandUpdateResources, NodeID: "ghost", Resources: cluster.Resources{RAMAvailMB: 1}})
	resp := fsm.Apply(&hraft.Log{Data: data})
	if resp == nil {
		t.Fatalf("expected an error applying CommandUpdateResources for a node that was never joined, got nil")
	}
	if _, ok := fsm.State().Nodes["ghost"]; ok {
		t.Fatalf("CommandUpdateResources must never fabricate a node entry for an unknown NodeID")
	}
}

// TestApply_RecordRunningProfile_RefusedWhenNoLongerFits is T010's
// load-bearing race-closing RED test (FR-005/SC-004): a node at exactly
// its remaining capacity records one profile that fully consumes it;
// a second profile requesting ANY additional capacity on the SAME node
// must be refused - proving CommandRecordRunningProfile's Apply
// re-derives currently-uncommitted capacity from the log itself
// (existing RunningProfiles), never trusting the proposer's own
// pre-check, exactly mirroring CommandAcquireLock's re-validation
// pattern.
func TestApply_RecordRunningProfile_RefusedWhenNoLongerFits(t *testing.T) {
	fsm := NewClusterFSM()
	joinData := mustCommand(t, Command{Type: CommandJoinNode, Node: &cluster.Node{
		ID: "n1", Health: "healthy",
		Resources: cluster.Resources{RAMAvailMB: 1000, VRAMAvailMB: 1000, CPUCores: 4, NetworkMbps: 1000},
	}})
	if resp := fsm.Apply(&hraft.Log{Data: joinData}); resp != nil {
		t.Fatalf("apply join_node: unexpected error %v", resp)
	}

	first := mustCommand(t, Command{
		Type: CommandRecordRunningProfile, Profile: "small", TenantID: "tenant-a", NodeID: "n1",
		StartedAt: time.Unix(1000, 0),
		Footprint: cluster.PlacementRequest{RAMMB: 1000, VRAMMB: 1000, CPUCores: 4, NetworkMbps: 1000},
	})
	if resp := fsm.Apply(&hraft.Log{Data: first}); resp != nil {
		t.Fatalf("apply first record_running_profile (exact fit): unexpected error %v", resp)
	}

	second := mustCommand(t, Command{
		Type: CommandRecordRunningProfile, Profile: "large", TenantID: "tenant-a", NodeID: "n1",
		StartedAt: time.Unix(1001, 0),
		Footprint: cluster.PlacementRequest{RAMMB: 1, VRAMMB: 0, CPUCores: 0, NetworkMbps: 0},
	})
	resp := fsm.Apply(&hraft.Log{Data: second})
	if resp == nil {
		t.Fatalf("expected the second record_running_profile to be refused (node n1 has zero capacity left), got nil")
	}

	state := fsm.State()
	if len(state.RunningProfiles) != 1 {
		t.Fatalf("expected exactly 1 RunningProfile entry after the refused second attempt, got %d", len(state.RunningProfiles))
	}
}

// TestApply_RecordRunningProfile_MultipleDistinctNodesSucceed proves the
// refusal above is genuinely capacity-based, not a blanket "second
// record always fails" bug: two profiles on two DIFFERENT nodes, each
// individually fitting its own node, must both succeed.
func TestApply_RecordRunningProfile_MultipleDistinctNodesSucceed(t *testing.T) {
	fsm := NewClusterFSM()
	for _, id := range []string{"n1", "n2"} {
		data := mustCommand(t, Command{Type: CommandJoinNode, Node: &cluster.Node{
			ID: id, Health: "healthy",
			Resources: cluster.Resources{RAMAvailMB: 1000, VRAMAvailMB: 1000, CPUCores: 4, NetworkMbps: 1000},
		}})
		if resp := fsm.Apply(&hraft.Log{Data: data}); resp != nil {
			t.Fatalf("apply join_node(%s): unexpected error %v", id, resp)
		}
	}

	for i, id := range []string{"n1", "n2"} {
		cmd := mustCommand(t, Command{
			Type: CommandRecordRunningProfile, Profile: "small", TenantID: "tenant-a", NodeID: id,
			StartedAt: time.Unix(int64(1000+i), 0),
			Footprint: cluster.PlacementRequest{RAMMB: 500, VRAMMB: 500, CPUCores: 2, NetworkMbps: 100},
		})
		if resp := fsm.Apply(&hraft.Log{Data: cmd}); resp != nil {
			t.Fatalf("apply record_running_profile(%s): unexpected error %v", id, resp)
		}
	}

	if got := len(fsm.State().RunningProfiles); got != 2 {
		t.Fatalf("expected 2 RunningProfile entries (one per node), got %d", got)
	}
}

// TestApply_ClearRunningProfile_IdempotentOnAbsent proves
// CommandClearRunningProfile removing an entry that is already absent
// (or never existed) is a safe no-op - matching CommandReleaseLock's
// own already-established idempotent-release pattern, never an error a
// caller racing its own clear against a concurrent clear would be
// punished for.
func TestApply_ClearRunningProfile_IdempotentOnAbsent(t *testing.T) {
	fsm := NewClusterFSM()
	data := mustCommand(t, Command{Type: CommandClearRunningProfile, Profile: "ghost", TenantID: "tenant-a", NodeID: "n1"})
	if resp := fsm.Apply(&hraft.Log{Data: data}); resp != nil {
		t.Fatalf("clearing an absent RunningProfile must be a safe no-op, got error %v", resp)
	}
}

// TestApply_ClearRunningProfile_RemovesExactEntry proves a real,
// present entry is genuinely removed, and clearing frees capacity for a
// subsequent CommandRecordRunningProfile that would otherwise refuse.
func TestApply_ClearRunningProfile_RemovesExactEntry(t *testing.T) {
	fsm := NewClusterFSM()
	joinData := mustCommand(t, Command{Type: CommandJoinNode, Node: &cluster.Node{
		ID: "n1", Health: "healthy",
		Resources: cluster.Resources{RAMAvailMB: 1000, VRAMAvailMB: 1000, CPUCores: 4, NetworkMbps: 1000},
	}})
	if resp := fsm.Apply(&hraft.Log{Data: joinData}); resp != nil {
		t.Fatalf("apply join_node: unexpected error %v", resp)
	}

	record := mustCommand(t, Command{
		Type: CommandRecordRunningProfile, Profile: "small", TenantID: "tenant-a", NodeID: "n1",
		StartedAt: time.Unix(1000, 0),
		Footprint: cluster.PlacementRequest{RAMMB: 1000, VRAMMB: 1000, CPUCores: 4, NetworkMbps: 1000},
	})
	if resp := fsm.Apply(&hraft.Log{Data: record}); resp != nil {
		t.Fatalf("apply record_running_profile: unexpected error %v", resp)
	}

	clear := mustCommand(t, Command{Type: CommandClearRunningProfile, Profile: "small", TenantID: "tenant-a", NodeID: "n1"})
	if resp := fsm.Apply(&hraft.Log{Data: clear}); resp != nil {
		t.Fatalf("apply clear_running_profile: unexpected error %v", resp)
	}
	if got := len(fsm.State().RunningProfiles); got != 0 {
		t.Fatalf("expected 0 RunningProfile entries after clear, got %d", got)
	}

	// Capacity is genuinely freed: the exact same footprint that
	// previously fit (and was then cleared) must fit again.
	again := mustCommand(t, Command{
		Type: CommandRecordRunningProfile, Profile: "small", TenantID: "tenant-a", NodeID: "n1",
		StartedAt: time.Unix(1001, 0),
		Footprint: cluster.PlacementRequest{RAMMB: 1000, VRAMMB: 1000, CPUCores: 4, NetworkMbps: 1000},
	})
	if resp := fsm.Apply(&hraft.Log{Data: again}); resp != nil {
		t.Fatalf("re-recording after clear should succeed (capacity was freed), got error %v", resp)
	}
}

// TestApply_AssignReplicationRole_ExactlyOnePrimary proves
// CommandAssignReplicationRole writes/replaces a tenant's ReplicationRole
// atomically - a second assign for the same tenant with a DIFFERENT
// primary must fully replace the first, never leave two entries or any
// momentary dual-primary state visible, matching CommandJoinNode's own
// single-map-entry-replaced-atomically pattern (state.go's
// ReplicationRole doc comment, spec.md FR-011).
func TestApply_AssignReplicationRole_ExactlyOnePrimary(t *testing.T) {
	fsm := NewClusterFSM()
	role := &cluster.ReplicationRole{
		TenantID:       "tenant-a",
		PrimaryNodeID:  "node-a",
		ReplicaNodeIDs: []string{"node-b", "node-c"},
		AssignedAt:     time.Now(),
	}
	data := mustCommand(t, Command{Type: CommandAssignReplicationRole, ReplicationRole: role})
	if resp := fsm.Apply(&hraft.Log{Data: data}); resp != nil {
		t.Fatalf("apply assign_replication_role: unexpected error %v", resp)
	}

	state := fsm.State()
	got, ok := state.ReplicationRoles["tenant-a"]
	if !ok {
		t.Fatalf("expected tenant-a's role present after CommandAssignReplicationRole")
	}
	if got.PrimaryNodeID != "node-a" {
		t.Fatalf("PrimaryNodeID = %q, want node-a", got.PrimaryNodeID)
	}

	role2 := &cluster.ReplicationRole{
		TenantID:       "tenant-a",
		PrimaryNodeID:  "node-b",
		ReplicaNodeIDs: []string{"node-a", "node-c"},
		AssignedAt:     time.Now(),
	}
	data2 := mustCommand(t, Command{Type: CommandAssignReplicationRole, ReplicationRole: role2})
	if resp := fsm.Apply(&hraft.Log{Data: data2}); resp != nil {
		t.Fatalf("apply second assign_replication_role: unexpected error %v", resp)
	}

	state = fsm.State()
	if len(state.ReplicationRoles) != 1 {
		t.Fatalf("expected exactly one role entry for tenant-a after the second assign, got %d", len(state.ReplicationRoles))
	}
	got = state.ReplicationRoles["tenant-a"]
	if got.PrimaryNodeID != "node-b" {
		t.Fatalf("PrimaryNodeID after replace = %q, want node-b (exactly one primary at any time)", got.PrimaryNodeID)
	}
}

// TestApply_ReassignReplicationRole_ReplacesAtomically proves
// CommandReassignReplicationRole (the failover path - a new primary
// taking over from a dead one) applies with the SAME atomic-replace
// guarantee as CommandAssignReplicationRole - the two commands share one
// FSM code path (replication_roles.go's own doc comment: "Both commands
// apply identically in the FSM ... the distinction is kept for
// semantic/audit clarity").
func TestApply_ReassignReplicationRole_ReplacesAtomically(t *testing.T) {
	fsm := NewClusterFSM()
	initial := &cluster.ReplicationRole{TenantID: "tenant-a", PrimaryNodeID: "node-a", ReplicaNodeIDs: []string{"node-b"}, AssignedAt: time.Now()}
	data := mustCommand(t, Command{Type: CommandAssignReplicationRole, ReplicationRole: initial})
	if resp := fsm.Apply(&hraft.Log{Data: data}); resp != nil {
		t.Fatalf("apply initial assign: unexpected error %v", resp)
	}

	failover := &cluster.ReplicationRole{TenantID: "tenant-a", PrimaryNodeID: "node-b", ReplicaNodeIDs: nil, AssignedAt: time.Now()}
	data2 := mustCommand(t, Command{Type: CommandReassignReplicationRole, ReplicationRole: failover})
	if resp := fsm.Apply(&hraft.Log{Data: data2}); resp != nil {
		t.Fatalf("apply reassign_replication_role: unexpected error %v", resp)
	}

	state := fsm.State()
	if len(state.ReplicationRoles) != 1 {
		t.Fatalf("expected exactly one role entry for tenant-a after reassignment, got %d", len(state.ReplicationRoles))
	}
	got := state.ReplicationRoles["tenant-a"]
	if got.PrimaryNodeID != "node-b" {
		t.Fatalf("PrimaryNodeID after reassign = %q, want node-b (the failover target)", got.PrimaryNodeID)
	}
}

// TestApply_AssignReplicationRole_MissingRoleRejected proves a malformed
// CommandAssignReplicationRole/CommandReassignReplicationRole log entry
// (no ReplicationRole payload) is rejected with an error rather than
// silently no-op-ing or panicking - matching CommandJoinNode's own
// errCommandMissingNode discipline (fsm.go's Apply doc comment: "returns
// an error ... on a malformed or unrecognized command, so a single bad
// log entry cannot take down the FSM goroutine").
func TestApply_AssignReplicationRole_MissingRoleRejected(t *testing.T) {
	fsm := NewClusterFSM()
	data := mustCommand(t, Command{Type: CommandAssignReplicationRole})
	if resp := fsm.Apply(&hraft.Log{Data: data}); resp == nil {
		t.Fatalf("expected an error when CommandAssignReplicationRole carries a nil ReplicationRole")
	}

	data2 := mustCommand(t, Command{Type: CommandReassignReplicationRole})
	if resp := fsm.Apply(&hraft.Log{Data: data2}); resp == nil {
		t.Fatalf("expected an error when CommandReassignReplicationRole carries a nil ReplicationRole")
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
