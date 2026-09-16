package cluster

import (
	"testing"
	"time"
)

func TestClone_IsIndependentCopy(t *testing.T) {
	original := NewClusterState()
	original.Nodes["n1"] = Node{ID: "n1", Addr: "10.0.0.1:9443", Health: "healthy"}

	clone := original.Clone()
	clone.Nodes["n1"] = Node{ID: "n1", Addr: "10.0.0.1:9443", Health: "unhealthy"}
	clone.Nodes["n2"] = Node{ID: "n2", Addr: "10.0.0.2:9443", Health: "healthy"}

	if got := original.Nodes["n1"].Health; got != "healthy" {
		t.Fatalf("mutating the clone must not affect the original: original n1.Health = %q, want %q", got, "healthy")
	}
	if _, present := original.Nodes["n2"]; present {
		t.Fatalf("adding a node to the clone must not affect the original")
	}
	if len(clone.Nodes) != 2 {
		t.Fatalf("clone should have 2 nodes, got %d", len(clone.Nodes))
	}
}

// TestClone_RunningProfilesIsIndependentCopy is 002-cluster-model-
// scheduler's T009 RED test: mutating a clone's RunningProfiles slice
// (append) must never affect the original - the exact independent-copy
// guarantee Clone already provides for Nodes/Locks, extended to the new
// field.
func TestClone_RunningProfilesIsIndependentCopy(t *testing.T) {
	original := NewClusterState()
	original.RunningProfiles = append(original.RunningProfiles, RunningProfile{
		Profile: "small", TenantID: "tenant-a", NodeID: "node-a",
		StartedAt: time.Unix(1000, 0),
		Footprint: PlacementRequest{RAMMB: 2048, VRAMMB: 4096, CPUCores: 2, NetworkMbps: 100},
	})

	clone := original.Clone()
	clone.RunningProfiles = append(clone.RunningProfiles, RunningProfile{Profile: "large", TenantID: "tenant-b", NodeID: "node-b"})

	if len(original.RunningProfiles) != 1 {
		t.Fatalf("appending to the clone must not affect the original: original has %d entries, want 1", len(original.RunningProfiles))
	}
	if len(clone.RunningProfiles) != 2 {
		t.Fatalf("clone should have 2 entries after its own append, got %d", len(clone.RunningProfiles))
	}
	if got := original.RunningProfiles[0]; got.Profile != "small" || got.NodeID != "node-a" || got.Footprint.RAMMB != 2048 {
		t.Fatalf("original's own entry was corrupted: %+v", got)
	}
}

func TestNewClusterState_StartsEmpty(t *testing.T) {
	s := NewClusterState()
	if s.Nodes == nil {
		t.Fatalf("NewClusterState must initialize a non-nil Nodes map")
	}
	if len(s.Nodes) != 0 {
		t.Fatalf("a freshly constructed ClusterState must have zero nodes, got %d", len(s.Nodes))
	}
	if s.ReplicationRoles == nil {
		t.Fatalf("NewClusterState must initialize a non-nil ReplicationRoles map (003-kv-cache-replication)")
	}
	if len(s.ReplicationRoles) != 0 {
		t.Fatalf("a freshly constructed ClusterState must have zero replication roles, got %d", len(s.ReplicationRoles))
	}
}

// TestClone_ReplicationRolesIsIndependentCopy proves ReplicationRoles
// (003-kv-cache-replication) gets the SAME deep-copy guarantee Nodes/Locks
// already have (Clone's own doc comment) - a caller mutating a clone's
// role or its ReplicaNodeIDs slice must never affect the original.
func TestClone_ReplicationRolesIsIndependentCopy(t *testing.T) {
	original := NewClusterState()
	original.ReplicationRoles[""] = ReplicationRole{TenantID: "", PrimaryNodeID: "node-a", ReplicaNodeIDs: []string{"node-b"}}

	clone := original.Clone()
	clone.ReplicationRoles[""] = ReplicationRole{TenantID: "", PrimaryNodeID: "node-c", ReplicaNodeIDs: []string{"node-d"}}
	clone.ReplicationRoles[""].ReplicaNodeIDs[0] = "mutated"

	if got := original.ReplicationRoles[""].PrimaryNodeID; got != "node-a" {
		t.Fatalf("mutating the clone's role must not affect the original: original PrimaryNodeID = %q, want node-a", got)
	}
	if got := original.ReplicationRoles[""].ReplicaNodeIDs[0]; got != "node-b" {
		t.Fatalf("mutating the clone's ReplicaNodeIDs slice must not affect the original: got %q, want node-b", got)
	}
}

// TestClone_CARotationIsNilByDefault proves a freshly-constructed
// ClusterState (and its clone) both start with CARotation == nil - "no
// rotation has ever been begun" (Feature 004 Phase 5, data-model.md).
func TestClone_CARotationIsNilByDefault(t *testing.T) {
	original := NewClusterState()
	if original.CARotation != nil {
		t.Fatalf("NewClusterState must start with CARotation == nil, got %+v", original.CARotation)
	}
	clone := original.Clone()
	if clone.CARotation != nil {
		t.Fatalf("Clone of a CARotation-nil state must also be nil, got %+v", clone.CARotation)
	}
}

// TestClone_CARotationIsIndependentCopy proves CARotation (Feature 004
// Phase 5) gets the SAME deep-copy guarantee ReplicationRoles/
// RunningProfiles already have: mutating a clone's CARotation pointer, or
// its TransitionedNodeIDs slice, must never affect the original.
func TestClone_CARotationIsIndependentCopy(t *testing.T) {
	original := NewClusterState()
	original.CARotation = &CARotationEvent{
		OutgoingCAFingerprint: "fp-old",
		IncomingCAFingerprint: "fp-new",
		TransitionedNodeIDs:   []string{"node-a"},
		Status:                "in_progress",
		BegunAt:               time.Unix(1000, 0),
	}

	clone := original.Clone()
	clone.CARotation.Status = "finalized"
	clone.CARotation.TransitionedNodeIDs[0] = "mutated"
	clone.CARotation.TransitionedNodeIDs = append(clone.CARotation.TransitionedNodeIDs, "node-b")

	if got := original.CARotation.Status; got != "in_progress" {
		t.Fatalf("mutating the clone's CARotation must not affect the original: original Status = %q, want in_progress", got)
	}
	if got := original.CARotation.TransitionedNodeIDs[0]; got != "node-a" {
		t.Fatalf("mutating the clone's TransitionedNodeIDs slice must not affect the original: got %q, want node-a", got)
	}
	if got := len(original.CARotation.TransitionedNodeIDs); got != 1 {
		t.Fatalf("appending to the clone's TransitionedNodeIDs must not affect the original: original has %d entries, want 1", got)
	}
}
