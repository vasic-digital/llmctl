// Package raft (running_profile.go): real Raft-log wrappers around
// fsm.go's CommandRecordRunningProfile/CommandClearRunningProfile handling
// (002-cluster-model-scheduler T016/T017) - the primitives Phase 3's
// auto-placement HTTP handler (internal/api/routes_models.go) uses to
// reserve a chosen node's capacity BEFORE dispatching a model start, and to
// release that reservation again if the dispatch itself then fails
// (T017's compensating action).
package raft

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
)

// RecordRunningProfile submits a real CommandRecordRunningProfile Raft log
// entry recording that profile (for tenantID) is now running on nodeID,
// reserving footprint's resources against that node's currently-uncommitted
// capacity. Every replica's Apply independently re-validates capacity from
// already-committed replicated state (fsm.go's own doc comment) - never
// from this caller's own pre-check - which is what closes the FR-005/
// SC-004 TOCTOU race: two concurrent proposers may both have observed "node
// fits" against a stale snapshot, but hashicorp/raft applies log entries
// strictly one at a time, so whichever Apply runs second always sees the
// first one's committed reservation.
//
// Returns ErrInsufficientCapacity (checkable via errors.Is) specifically
// when that re-validation finds the node no longer has room - T016's own
// retry-once-against-fresh-state logic depends on being able to distinguish
// this from any other, genuinely unexpected failure.
func (n *Node) RecordRunningProfile(profile, tenantID, nodeID string, footprint cluster.PlacementRequest) error {
	cmd := Command{
		Type:      CommandRecordRunningProfile,
		Profile:   profile,
		TenantID:  tenantID,
		NodeID:    nodeID,
		StartedAt: time.Now(),
		Footprint: footprint,
	}
	return n.applyRunningProfileCommand(cmd, "record_running_profile")
}

// ClearRunningProfile submits a real CommandClearRunningProfile Raft log
// entry removing the (profile, tenantID, nodeID) RunningProfile entry.
// Idempotent: clearing an already-absent entry (already cleared, or never
// successfully recorded) is a safe no-op, matching fsm.go's
// CommandClearRunningProfile handling and CommandReleaseLock's own
// established idempotent-release pattern exactly - required so T017's
// forwarding-failure compensating action can always call this without
// first needing to prove the reservation is still present.
func (n *Node) ClearRunningProfile(profile, tenantID, nodeID string) error {
	cmd := Command{Type: CommandClearRunningProfile, Profile: profile, TenantID: tenantID, NodeID: nodeID}
	return n.applyRunningProfileCommand(cmd, "clear_running_profile")
}

// applyRunningProfileCommand marshals cmd, submits it via a real
// n.raft.Apply, and surfaces the FSM's own returned error (if any) as this
// call's error - mirroring lock.go's acquireAs/Release's identical
// future.Error() / future.Response() handling pattern (a raft-level error
// from Apply itself vs. the FSM's own application-level refusal are
// distinct failure classes, and only the latter is ever a plain error
// value inside Response()).
func (n *Node) applyRunningProfileCommand(cmd Command, label string) error {
	data, err := json.Marshal(cmd)
	if err != nil {
		return fmt.Errorf("raft: %s: marshal command: %w", label, err)
	}
	future := n.raft.Apply(data, applyTimeout)
	if err := future.Error(); err != nil {
		return fmt.Errorf("raft: %s: %w", label, err)
	}
	if resp := future.Response(); resp != nil {
		if respErr, isErr := resp.(error); isErr {
			return respErr
		}
		return fmt.Errorf("raft: %s: unexpected FSM response type %T", label, resp)
	}
	return nil
}
