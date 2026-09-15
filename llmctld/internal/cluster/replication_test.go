package cluster

import "testing"

// TestDefaultTargetReplicaCount_IsThree proves the US7-pattern default of
// N=3 replicas per model (T052a) is a real, named constant callers can
// reference - not an unlabeled magic number scattered across call sites.
func TestDefaultTargetReplicaCount_IsThree(t *testing.T) {
	if DefaultTargetReplicaCount != 3 {
		t.Fatalf("DefaultTargetReplicaCount = %d, want 3", DefaultTargetReplicaCount)
	}
}

// TestReplicaState_UnderReplicated proves the ReplicaState helper method
// correctly identifies when a model has fewer live replicas than its
// target - the trigger condition health.go's reconciliation pass acts on.
func TestReplicaState_UnderReplicated(t *testing.T) {
	full := ReplicaState{Model: "llama-3-70b", TargetCount: 3, LiveNodeIDs: []string{"a", "b", "c"}}
	if full.UnderReplicated() {
		t.Fatalf("a model with 3/3 live replicas must not report under-replicated")
	}

	degraded := ReplicaState{Model: "llama-3-70b", TargetCount: 3, LiveNodeIDs: []string{"a", "b"}}
	if !degraded.UnderReplicated() {
		t.Fatalf("a model with 2/3 live replicas (SC-018: 1 of 3 failed) must report under-replicated")
	}
	if got, want := degraded.Deficit(), 1; got != want {
		t.Fatalf("Deficit() = %d, want %d", got, want)
	}
}
