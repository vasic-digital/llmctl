// Package cluster (placement_decision.go): the audit record for one
// automatic placement outcome - 002-cluster-model-scheduler T018,
// data-model.md's PlacementDecision/NodeCapacitySnapshot entities.
//
// A PlacementDecision is NOT part of Raft-replicated ClusterState (see
// data-model.md's "Concurrency-safety note (FR-005, SC-004)" section) - it
// is persisted via internal/audit/log.go's existing hash-chained mechanism
// instead, exactly like every other authz/tenant-lifecycle audit entry
// this codebase already records. This file only defines the shape;
// internal/api/routes_models.go's auto-placement handler constructs one
// per decision and serializes it into audit.Log.Append's own decision
// string field.
package cluster

import "time"

// NodeCapacitySnapshot records one candidate node's resource capacity AT
// THE MOMENT a placement decision considered it - the per-candidate detail
// both a successful PlacementDecision (every candidate, including the
// chosen one) and a refused one (every candidate, showing why each fell
// short) carry.
type NodeCapacitySnapshot struct {
	NodeID    string    `json:"node_id"`
	Resources Resources `json:"resources"`
}

// PlacementDecision is one automatic-placement outcome - success (a real
// node was chosen) or refusal (insufficient_capacity /
// placement_delivery_failed / cluster_unreachable, contracts/cluster-
// model-api.md's closed reason set) - carrying every node considered and a
// human-readable reason, per T018's own mandate.
type PlacementDecision struct {
	Profile         string                 `json:"profile"`
	ChosenNodeID    string                 `json:"chosen_node_id,omitempty"`
	ConsideredNodes []NodeCapacitySnapshot `json:"considered_nodes"`
	Reason          string                 `json:"reason"`
	DecidedAt       time.Time              `json:"decided_at"`
}
