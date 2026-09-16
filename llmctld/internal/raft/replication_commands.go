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

// ID returns n's own stable Raft/mTLS identity (the same value it was
// constructed with as Config.NodeID) - exposed for callers (T008's
// forwarder wiring in internal/api) that cannot reach n's private
// localID field directly.
func (n *Node) ID() string {
	return string(n.localID)
}

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
// field). Like every other Apply-backed method in this package
// (Join/Acquire/Release), this MUST be called against the current
// leader - hashicorp/raft's own Apply enforces that itself
// (hraft.ErrNotLeader otherwise), so a follower calling this fails
// honestly rather than silently no-op-ing.
func (n *Node) RegisterNode(id, apiAddr string) error {
	return n.applyCommand(Command{Type: CommandJoinNode, Node: &cluster.Node{ID: id, Addr: apiAddr, Health: "healthy"}})
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
