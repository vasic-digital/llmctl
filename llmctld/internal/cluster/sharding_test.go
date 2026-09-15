package cluster

import "testing"

// TestPlanShards_SelectsDistinctNodesCoveringEvenSplit proves PlanShards
// picks shardCount DISTINCT healthy nodes, each able to host an even
// fraction of the total requirement (FR-022, FR-024: models exceeding a
// single node's VRAM are split across multiple nodes).
func TestPlanShards_SelectsDistinctNodesCoveringEvenSplit(t *testing.T) {
	// Total requirement: 6000MB VRAM. No single candidate has that much,
	// but each candidate has enough for its 1/3 share (2000MB).
	req := PlacementRequest{RAMMB: 3000, VRAMMB: 6000, CPUCores: 6, NetworkMbps: 300}
	fit := Resources{RAMAvailMB: 1200, VRAMAvailMB: 2200, CPUCores: 3, NetworkMbps: 300}
	candidates := []Node{
		{ID: "node-a", Health: "healthy", Resources: fit},
		{ID: "node-b", Health: "healthy", Resources: fit},
		{ID: "node-c", Health: "healthy", Resources: fit},
	}

	plan, err := PlanShards(candidates, req, 3)
	if err != nil {
		t.Fatalf("PlanShards: unexpected error: %v", err)
	}
	if len(plan.ShardNodes) != 3 {
		t.Fatalf("plan.ShardNodes has %d entries, want 3", len(plan.ShardNodes))
	}
	seen := map[string]bool{}
	for _, id := range plan.ShardNodes {
		if seen[id] {
			t.Fatalf("PlanShards double-booked node %q for two shards of the same model", id)
		}
		seen[id] = true
	}
}

// TestPlanShards_RefusesWhenNotEnoughCapacity proves PlanShards refuses
// (never returns a partial/fabricated plan) when fewer healthy candidates
// have sufficient per-shard capacity than shardCount requires.
func TestPlanShards_RefusesWhenNotEnoughCapacity(t *testing.T) {
	req := PlacementRequest{RAMMB: 3000, VRAMMB: 6000, CPUCores: 6, NetworkMbps: 300}
	fit := Resources{RAMAvailMB: 1200, VRAMAvailMB: 2200, CPUCores: 3, NetworkMbps: 300}
	candidates := []Node{
		{ID: "node-a", Health: "healthy", Resources: fit},
		{ID: "node-b", Health: "healthy", Resources: fit},
		// only 2 candidates, but 3 shards requested
	}

	_, err := PlanShards(candidates, req, 3)
	if err == nil {
		t.Fatalf("PlanShards with only 2 fitting candidates for 3 shards must refuse, got nil error")
	}
}

// TestPlanShards_RefusesShardCountLessThanTwo proves a shardCount < 2 is
// refused - a single-shard "plan" is a placement decision Place() itself
// already handles.
func TestPlanShards_RefusesShardCountLessThanTwo(t *testing.T) {
	if _, err := PlanShards(nil, PlacementRequest{}, 1); err == nil {
		t.Fatalf("PlanShards with shardCount=1 must be refused, got nil error")
	}
	if _, err := PlanShards(nil, PlacementRequest{}, 0); err == nil {
		t.Fatalf("PlanShards with shardCount=0 must be refused, got nil error")
	}
}
