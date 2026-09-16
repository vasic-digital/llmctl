// Package cluster (replication_roles.go): pure decision logic for
// 003-kv-cache-replication's per-tenant ReplicationRole (state.go)
// reconciliation - deliberately free of any Raft/HTTP/network
// dependency, so it is unit-testable in isolation and reusable from more
// than one trigger signal without duplicating the decision itself
// (research.md Decision 2's "no second detector" applied at the
// function-boundary level: whichever signal calls this - Raft leadership
// change, in internal/raft/node.go's ReconcileReplicationRoles, or a
// cluster.Monitor Rescheduler callback wired to real HTTP health checks -
// both go through this SAME logic, never two independently-reasoned
// reassignment algorithms).
package cluster

import (
	"sort"
	"time"
)

// ReconcileTenantRole computes tenantID's ReplicationRole given the
// caller's current view of live and (if known) explicitly-dead node IDs,
// from selfID's point of view. The caller MUST already have confirmed it
// is entitled to propose a change (e.g. it currently holds Raft
// leadership) before acting on a changed=true result - this function
// performs no I/O and enforces no such precondition itself.
//
// existing/had is the tenant's current role, if any (a caller reads this
// from ClusterState.ReplicationRoles[tenantID] first). liveNodeIDs is
// every node currently considered reachable/voting; deadNodeIDs is any
// node ADDITIONALLY known to be down even if a caller's derivation of
// "live" would not otherwise exclude it (e.g. a health-check-detected
// unreachable node that Raft's own configuration has not yet removed as
// a voter) - a node in liveNodeIDs AND deadNodeIDs is treated as dead
// (deadNodeIDs is the stronger, more specific signal). now is the
// proposer's wall-clock reading, carried into the returned role's
// AssignedAt exactly as LockEntry.ExpiresAt already requires for
// FSM.Apply determinism (state.go's ReplicationRole doc comment).
//
// Returns changed=false (role is unchanged from existing) when no update
// is needed. When changed=true, isReassignment reports whether this is a
// FAILOVER (the previously-recorded primary is no longer live - the
// caller should propose CommandReassignReplicationRole) versus a
// fresh/refreshed ASSIGNMENT (no prior role existed, or only the replica
// set changed while the primary stayed the same - the caller should
// propose CommandAssignReplicationRole). Both commands apply identically
// in the FSM (internal/raft/fsm.go) - the distinction is kept for
// semantic/audit clarity, matching data-model.md's own
// Assigned->Reassigned state-transition naming.
func ReconcileTenantRole(existing ReplicationRole, had bool, tenantID, selfID string, liveNodeIDs, deadNodeIDs []string, now time.Time) (role ReplicationRole, changed bool, isReassignment bool) {
	liveSet := make(map[string]bool, len(liveNodeIDs))
	for _, id := range liveNodeIDs {
		liveSet[id] = true
	}
	deadSet := make(map[string]bool, len(deadNodeIDs))
	for _, id := range deadNodeIDs {
		deadSet[id] = true
	}
	isLive := func(id string) bool {
		return liveSet[id] && !deadSet[id]
	}

	replicasExcluding := func(primary string) []string {
		var reps []string
		for _, id := range liveNodeIDs {
			if id != primary && isLive(id) {
				reps = append(reps, id)
			}
		}
		sort.Strings(reps)
		return reps
	}

	if !had {
		return ReplicationRole{
			TenantID:       tenantID,
			PrimaryNodeID:  selfID,
			ReplicaNodeIDs: replicasExcluding(selfID),
			AssignedAt:     now,
		}, true, false
	}

	if !isLive(existing.PrimaryNodeID) {
		// The recorded primary is no longer live (a failover) - selfID
		// (the caller, already confirmed to be entitled to propose) takes
		// over.
		return ReplicationRole{
			TenantID:       tenantID,
			PrimaryNodeID:  selfID,
			ReplicaNodeIDs: replicasExcluding(selfID),
			AssignedAt:     now,
		}, true, true
	}

	wantReplicas := replicasExcluding(existing.PrimaryNodeID)
	if !stringSlicesEqual(existing.ReplicaNodeIDs, wantReplicas) {
		return ReplicationRole{
			TenantID:       tenantID,
			PrimaryNodeID:  existing.PrimaryNodeID,
			ReplicaNodeIDs: wantReplicas,
			AssignedAt:     existing.AssignedAt,
		}, true, false
	}

	return existing, false, false
}

func stringSlicesEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
