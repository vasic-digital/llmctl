package cluster

import (
	"testing"
	"time"
)

func TestReconcileTenantRole_NoExistingRole_AssignsSelfAsPrimary(t *testing.T) {
	now := time.Now()
	role, changed, isReassignment := ReconcileTenantRole(ReplicationRole{}, false, "", "node-a", []string{"node-a", "node-b", "node-c"}, nil, now)
	if !changed {
		t.Fatalf("expected changed=true when no role exists yet")
	}
	if isReassignment {
		t.Fatalf("a fresh assignment (no prior role) must not be reported as a reassignment")
	}
	if role.PrimaryNodeID != "node-a" {
		t.Fatalf("PrimaryNodeID = %q, want node-a (the caller)", role.PrimaryNodeID)
	}
	if got, want := role.ReplicaNodeIDs, []string{"node-b", "node-c"}; !stringSlicesEqual(got, want) {
		t.Fatalf("ReplicaNodeIDs = %v, want %v", got, want)
	}
	if !role.AssignedAt.Equal(now) {
		t.Fatalf("AssignedAt = %v, want %v (the caller-supplied instant, never a locally-read clock)", role.AssignedAt, now)
	}
}

func TestReconcileTenantRole_PrimaryStillLive_ReplicaSetUnchanged_NoOp(t *testing.T) {
	existing := ReplicationRole{TenantID: "", PrimaryNodeID: "node-a", ReplicaNodeIDs: []string{"node-b", "node-c"}, AssignedAt: time.Now()}
	role, changed, _ := ReconcileTenantRole(existing, true, "", "node-b", []string{"node-a", "node-b", "node-c"}, nil, time.Now())
	if changed {
		t.Fatalf("a role whose primary is still live and whose replica set already matches the live set must not change, got %+v", role)
	}
}

func TestReconcileTenantRole_DeadPrimary_ReassignsToSelf(t *testing.T) {
	existing := ReplicationRole{TenantID: "", PrimaryNodeID: "node-a", ReplicaNodeIDs: []string{"node-b", "node-c"}, AssignedAt: time.Now()}
	now := time.Now()
	role, changed, isReassignment := ReconcileTenantRole(existing, true, "", "node-b", []string{"node-b", "node-c"}, nil, now)
	if !changed {
		t.Fatalf("expected changed=true when the recorded primary is no longer live")
	}
	if !isReassignment {
		t.Fatalf("taking over from a dead primary MUST be reported as a reassignment (CommandReassignReplicationRole), got isReassignment=false")
	}
	if role.PrimaryNodeID != "node-b" {
		t.Fatalf("PrimaryNodeID = %q, want node-b (the new leader taking over)", role.PrimaryNodeID)
	}
	if got, want := role.ReplicaNodeIDs, []string{"node-c"}; !stringSlicesEqual(got, want) {
		t.Fatalf("ReplicaNodeIDs = %v, want %v (every OTHER live node, excluding the new primary itself)", got, want)
	}
}

func TestReconcileTenantRole_ExplicitlyDeadPrimary_OverridesLiveList(t *testing.T) {
	// A node health-checked unreachable but still present in the raw
	// live-voter list (Raft has not yet removed it as a voter) must still
	// be treated as dead when deadNodeIDs names it explicitly - the
	// health.Monitor-compatible trigger path (T004).
	existing := ReplicationRole{TenantID: "", PrimaryNodeID: "node-a", ReplicaNodeIDs: []string{"node-b", "node-c"}, AssignedAt: time.Now()}
	role, changed, isReassignment := ReconcileTenantRole(existing, true, "", "node-b", []string{"node-a", "node-b", "node-c"}, []string{"node-a"}, time.Now())
	if !changed || !isReassignment {
		t.Fatalf("an explicitly-dead primary (deadNodeIDs) must trigger a reassignment even though it is still in liveNodeIDs; changed=%v isReassignment=%v", changed, isReassignment)
	}
	if role.PrimaryNodeID != "node-b" {
		t.Fatalf("PrimaryNodeID = %q, want node-b", role.PrimaryNodeID)
	}
}

func TestReconcileTenantRole_NewReplicaJoins_ReplicaSetRefreshed_NotReassignment(t *testing.T) {
	existing := ReplicationRole{TenantID: "", PrimaryNodeID: "node-a", ReplicaNodeIDs: []string{"node-b"}, AssignedAt: time.Now()}
	role, changed, isReassignment := ReconcileTenantRole(existing, true, "", "node-a", []string{"node-a", "node-b", "node-c"}, nil, time.Now())
	if !changed {
		t.Fatalf("expected changed=true when a new live node is not yet reflected in ReplicaNodeIDs")
	}
	if isReassignment {
		t.Fatalf("adding a replica while the SAME primary stays live must be a refreshed assignment, not a reassignment")
	}
	if role.PrimaryNodeID != "node-a" {
		t.Fatalf("PrimaryNodeID must stay node-a (unchanged) when only the replica set refreshes, got %q", role.PrimaryNodeID)
	}
	if got, want := role.ReplicaNodeIDs, []string{"node-b", "node-c"}; !stringSlicesEqual(got, want) {
		t.Fatalf("ReplicaNodeIDs = %v, want %v", got, want)
	}
}

func TestReconcileTenantRole_DeadReplicaRemoved(t *testing.T) {
	existing := ReplicationRole{TenantID: "", PrimaryNodeID: "node-a", ReplicaNodeIDs: []string{"node-b", "node-c"}, AssignedAt: time.Now()}
	role, changed, isReassignment := ReconcileTenantRole(existing, true, "", "node-a", []string{"node-a", "node-b"}, nil, time.Now())
	if !changed || isReassignment {
		t.Fatalf("a dead replica dropping out of liveNodeIDs must refresh the replica set (changed=true, isReassignment=false), got changed=%v isReassignment=%v", changed, isReassignment)
	}
	if got, want := role.ReplicaNodeIDs, []string{"node-b"}; !stringSlicesEqual(got, want) {
		t.Fatalf("ReplicaNodeIDs = %v, want %v (node-c dropped)", got, want)
	}
}
