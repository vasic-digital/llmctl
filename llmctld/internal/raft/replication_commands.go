// Package raft (replication_commands.go): the Node-level API for
// 003-kv-cache-replication's per-tenant ReplicationRole assignment
// (T003's CommandAssignReplicationRole/CommandReassignReplicationRole)
// plus the node-registry-with-real-API-address registration
// (CommandJoinNode's Addr field) internal/replication's Forwarder (T008)
// needs to resolve a replica NodeID to a real HTTP address it can POST
// to. Mirrors lock.go's own Acquire/Release pattern exactly: a thin,
// honestly-erroring wrapper around n.raft.Apply, never a second command-
// submission mechanism.
package raft

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
)

const replicationApplyTimeout = 5 * time.Second

// Node.ID() (this file's own callers, e.g. T008's forwarder wiring in
// internal/api, need it exactly as described here) is declared once, in
// node.go - see that file's doc comment (shared with 002-cluster-model-
// scheduler's T015/T016 auto-placement handler, which needs the identical
// method for the identical reason: telling whether a chosen node IS this
// process or a different one to forward to).

// applyCommand is the shared apply-and-interpret-response helper every
// method in this file uses - matching lock.go's Acquire/Release's own
// "marshal, Apply, interpret future.Response()" shape exactly, factored
// out here since three new methods (RegisterNode, AssignReplicationRole,
// ReassignReplicationRole) would otherwise duplicate it three times.
func (n *Node) applyCommand(cmd Command) error {
	data, err := json.Marshal(cmd)
	if err != nil {
		return fmt.Errorf("raft: marshal %s command: %w", cmd.Type, err)
	}
	future := n.raft.Apply(data, replicationApplyTimeout)
	if err := future.Error(); err != nil {
		return fmt.Errorf("raft: apply %s command: %w", cmd.Type, err)
	}
	if resp := future.Response(); resp != nil {
		if respErr, isErr := resp.(error); isErr {
			return fmt.Errorf("raft: apply %s command: %w", cmd.Type, respErr)
		}
		return fmt.Errorf("raft: apply %s command: unexpected FSM response type %T", cmd.Type, resp)
	}
	return nil
}

// RegisterNode records id as reachable at apiAddr in the cluster's
// Raft-replicated node registry (fsm.go's CommandJoinNode,
// cluster.ClusterState.Nodes) - the real HTTP API address every OTHER
// node needs to forward a tenant's replicated content to it (T008's
// internal/replication.Forwarder's AddrResolver reads exactly this
// field). Sets cluster.Node.APIAddr specifically - NEVER Addr, which is
// a DIFFERENT field carrying the node's Raft transport address (a real,
// found bug during the 002/003 merge: an earlier version of this method
// wrote apiAddr into Addr, which - since CommandJoinNode's Apply fully
// REPLACES a node's map entry rather than merging into it - would also
// silently wipe out any already-registered Resources/real Addr the very
// next time it ran against an already-joined node).
//
// Because of that same full-replace Apply semantic, RegisterNode is only
// safe to call for a node with NO other real registry entry yet (its
// intended use: 002-cluster-model-scheduler's node.Join/RegisterSelf
// already register a node's FULL entry - Addr, APIAddr, and Resources -
// in one CommandJoinNode, so neither call site needs this method
// afterward; calling it there would only re-introduce the clobbering bug
// this comment documents). Like every other Apply-backed method in this
// package (Join/Acquire/Release), this MUST be called against the
// current leader - hashicorp/raft's own Apply enforces that itself
// (hraft.ErrNotLeader otherwise), so a follower calling this fails
// honestly rather than silently no-op-ing.
func (n *Node) RegisterNode(id, apiAddr string) error {
	return n.applyCommand(Command{Type: CommandJoinNode, Node: &cluster.Node{ID: id, APIAddr: apiAddr, Health: "healthy"}})
}

// AssignReplicationRole proposes a fresh/refreshed per-tenant
// ReplicationRole (fsm.go's CommandAssignReplicationRole) - the caller
// (internal/api's ensureReplicationRole, T008) is expected to have
// already produced role via cluster.ReconcileTenantRole; this method
// performs no reconciliation decision itself, matching lock.go's own
// separation between "decide" (a caller's own logic) and "durably
// commit" (this thin Apply wrapper).
func (n *Node) AssignReplicationRole(role cluster.ReplicationRole) error {
	return n.applyCommand(Command{Type: CommandAssignReplicationRole, ReplicationRole: &role})
}

// ReassignReplicationRole is AssignReplicationRole's failover-path
// sibling (fsm.go's CommandReassignReplicationRole) - the two commands
// apply identically in the FSM (fsm.go's own doc comment); which one a
// caller uses is purely for semantic/audit clarity (data-model.md's
// Assigned->Reassigned state-transition naming).
func (n *Node) ReassignReplicationRole(role cluster.ReplicationRole) error {
	return n.applyCommand(Command{Type: CommandReassignReplicationRole, ReplicationRole: &role})
}
