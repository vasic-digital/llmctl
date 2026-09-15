// Package cluster (sharding.go): tensor/model-parallelism PLACEMENT HINTS
// for models exceeding a single node's VRAM capacity (FR-022, FR-024).
//
// Honest scope boundary (Constitution §11.4.223 provenance markers): this
// file implements the PLACEMENT-HINT half of tensor/model parallelism only
// - ✅ IMPLEMENTED. It decides WHICH set of nodes could jointly host a
// sharded model's shards. It does NOT implement the actual cross-node
// tensor-parallel EXECUTION (splitting a model's layers/tensors across
// those nodes' llama.cpp/colibri engine processes and coordinating
// inference across them at runtime) - that is 📋 OPEN, honestly marked
// deferred past this round: no multi-GPU-node hardware exists in this
// development sandbox to build and genuinely validate real cross-node
// tensor-parallel inference against (see docs/cluster-architecture.md's
// sharding-contract section for the full documented status). SC-017's
// "sharded throughput within 15% of single-node baseline" benchmark is
// UNCONFIRMED for the identical reason: measuring it requires real
// execution that does not exist yet, and asserting a specific percentage
// without ever having run it would itself be the bluff Constitution
// §11.4/§11.4.6 forbid.
package cluster

import "fmt"

// ShardPlan is the result of planning a tensor/model-parallel placement
// across multiple nodes for a workload whose resource requirement exceeds
// any single node's capacity.
type ShardPlan struct {
	ShardNodes []string // one node ID per shard, in placement order
}

// PlanShards selects shardCount DISTINCT healthy candidate nodes from
// candidates, each able to host an even 1/shardCount fraction of req's
// RAM/VRAM/CPU requirement (network bandwidth is NOT divided - each shard
// still needs the full inter-shard bandwidth req specifies, since shards
// communicate with each other, not merely with a single caller).
//
// PlanShards reuses Place()'s own best-fit selection repeatedly,
// excluding already-chosen nodes each round, so no node is ever
// double-booked for two shards of the same model - the same
// exclude-and-repeat pattern health.go's Reconcile uses for replica
// placement. It refuses (never returns a partial or fabricated plan) if
// fewer than shardCount candidates have sufficient per-shard capacity.
func PlanShards(candidates []Node, req PlacementRequest, shardCount int) (ShardPlan, error) {
	if shardCount < 2 {
		return ShardPlan{}, fmt.Errorf("cluster: PlanShards requires shardCount >= 2 (got %d) - a single-shard model needs only Place(), not sharding", shardCount)
	}

	perShard := PlacementRequest{
		RAMMB:       ceilDivInt64(req.RAMMB, int64(shardCount)),
		VRAMMB:      ceilDivInt64(req.VRAMMB, int64(shardCount)),
		CPUCores:    ceilDivInt(req.CPUCores, shardCount),
		NetworkMbps: req.NetworkMbps,
	}

	remaining := append([]Node(nil), candidates...)
	var chosen []string
	for i := 0; i < shardCount; i++ {
		n, err := Place(remaining, perShard)
		if err != nil {
			return ShardPlan{}, fmt.Errorf("cluster: PlanShards: could not find shard %d of %d: %w", i+1, shardCount, err)
		}
		chosen = append(chosen, n.ID)

		filtered := remaining[:0:0]
		for _, c := range remaining {
			if c.ID != n.ID {
				filtered = append(filtered, c)
			}
		}
		remaining = filtered
	}

	return ShardPlan{ShardNodes: chosen}, nil
}

func ceilDivInt64(a, b int64) int64 {
	if b == 0 {
		return 0
	}
	return (a + b - 1) / b
}

func ceilDivInt(a, b int) int {
	if b == 0 {
		return 0
	}
	return (a + b - 1) / b
}
