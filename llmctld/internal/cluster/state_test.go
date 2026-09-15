package cluster

import "testing"

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

func TestNewClusterState_StartsEmpty(t *testing.T) {
	s := NewClusterState()
	if s.Nodes == nil {
		t.Fatalf("NewClusterState must initialize a non-nil Nodes map")
	}
	if len(s.Nodes) != 0 {
		t.Fatalf("a freshly constructed ClusterState must have zero nodes, got %d", len(s.Nodes))
	}
}
