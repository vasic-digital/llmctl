// Package raft wraps hashicorp/raft to replicate llmctld's cluster state
// (node membership and health) across every node via an embedded Raft log -
// no external etcd/consul dependency (Clarification 10).
package raft

import (
	"encoding/json"
	"errors"
	"io"
	"sync"
	"time"

	hraft "github.com/hashicorp/raft"

	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
)

// CommandType identifies the kind of state mutation a Raft log entry
// carries. Closed set: an unrecognized type is rejected by Apply, never
// silently ignored.
type CommandType string

const (
	CommandJoinNode    CommandType = "join_node"
	CommandLeaveNode   CommandType = "leave_node"
	CommandAcquireLock CommandType = "acquire_lock"
	CommandReleaseLock CommandType = "release_lock"

	// CommandUpdateResources refreshes an already-known node's Resources
	// in place (002-cluster-model-scheduler's resource-heartbeat) -
	// keeps placement.go's candidate-capacity view from going stale the
	// moment any model starts/stops consuming budget on that node.
	CommandUpdateResources CommandType = "update_resources"
	// CommandRecordRunningProfile records one profile instance as running
	// on one node, AFTER re-validating (inside Apply, never trusting the
	// proposer's own pre-check) that the footprint still genuinely fits
	// the node's currently-uncommitted capacity - the mechanism that
	// closes 002-cluster-model-scheduler's FR-005/SC-004 TOCTOU race,
	// mirroring CommandAcquireLock's own re-validation pattern exactly.
	CommandRecordRunningProfile CommandType = "record_running_profile"
	// CommandClearRunningProfile removes one (Profile, TenantID, NodeID)
	// RunningProfile entry - idempotent no-op if already absent, matching
	// CommandReleaseLock's own established idempotent-release pattern.
	CommandClearRunningProfile CommandType = "clear_running_profile"

	// CommandAssignReplicationRole and CommandReassignReplicationRole
	// both write cluster.ClusterState.ReplicationRoles[tenantID] via the
	// SAME atomic map-replace-in-place code path as CommandJoinNode's own
	// Nodes map write (003-kv-cache-replication data-model.md,
	// replication_roles.go's ReconcileTenantRole doc comment) - two
	// distinct CommandTypes exist only for semantic/audit clarity
	// (a fresh/refreshed assignment vs. a failover taking over from a
	// dead primary), never because the FSM treats them differently.
	CommandAssignReplicationRole   CommandType = "assign_replication_role"
	CommandReassignReplicationRole CommandType = "reassign_replication_role"

	// CommandRevokeCertificate records one revoked mTLS certificate
	// identity (Feature 004, data-model.md) - see RevocationRecord's own
	// doc comment for why revocation is keyed by certificate serial
	// number, never by NodeID.
	CommandRevokeCertificate CommandType = "revoke_certificate"

	// CommandBeginCARotation and CommandFinalizeCARotation record the
	// start and the operator-explicit completion of a CA (root-of-trust)
	// rotation (Feature 004 Phase 5, User Story 3, data-model.md's
	// CARotationEvent) - see cluster.CARotationEvent's own doc comment
	// for why only a FINGERPRINT hash of each CA's certificate travels
	// through this replicated log, never the certificate or key material
	// itself.
	CommandBeginCARotation    CommandType = "begin_ca_rotation"
	CommandFinalizeCARotation CommandType = "finalize_ca_rotation"

	// CommandRecordCARotationTransition records that ONE node (cmd.NodeID
	// - the same field CommandJoinNode/CommandLeaveNode already use, no
	// new Command field needed) has confirmed re-issuance under the
	// currently in_progress rotation's incoming CA (spec.md FR-009/SC-004
	// visibility) - submitted by that node's own POST
	// /v1/cluster/mtls/renew handler (internal/api/routes_mtls.go) the
	// moment its local renewal completes while a rotation is in progress.
	// This is the mechanism that makes POST /v1/cluster/mtls/rotate/
	// finalize's FR-010 quorum-protection check possible: without a
	// durable, cluster-wide-agreed record of which voters have already
	// transitioned, finalize could not distinguish "safe to retire the
	// outgoing CA" from "would strand every not-yet-transitioned voter."
	CommandRecordCARotationTransition CommandType = "record_ca_rotation_transition"
)

// Command is the structure serialized into every Raft log entry's Data.
type Command struct {
	Type   CommandType   `json:"type"`
	Node   *cluster.Node `json:"node,omitempty"`
	NodeID string        `json:"node_id,omitempty"`

	// Lock* fields are used only by CommandAcquireLock/CommandReleaseLock
	// - the FR-029 distributed-lock commands internal/raft's lock.go
	// submits (Node ID membership above is unrelated to lock holder
	// identity, though a holder is typically a Node's ID string).
	LockKey    string `json:"lock_key,omitempty"`
	LockHolder string `json:"lock_holder,omitempty"`
	// LockExpiresAt is computed ONCE by the proposer (lock.go's Acquire,
	// via time.Now().Add(ttl)) and carried inside the log entry itself, so
	// every replica applies the IDENTICAL expiry value. This is required,
	// not stylistic: FSM.Apply must be deterministic (same log entry ->
	// same result on every node, per ClusterFSM's own doc comment and
	// TestApply_DeterministicGivenSameLogSequence), and each node's own
	// wall clock is emphatically NOT "the same input" across replicas.
	LockExpiresAt time.Time `json:"lock_expires_at,omitempty"`
	// LockNow is the proposer's wall-clock reading at the moment THIS
	// acquire attempt was submitted, likewise carried in the log entry so
	// every replica's "has the existing hold already expired" comparison
	// uses the same reference instant - never each node's own local
	// clock, for the identical determinism reason as LockExpiresAt.
	LockNow time.Time `json:"lock_now,omitempty"`

	// Resources carries the payload for CommandUpdateResources (a node's
	// freshly re-probed capacity).
	Resources cluster.Resources `json:"resources,omitempty"`

	// Profile/TenantID/StartedAt/Footprint carry
	// CommandRecordRunningProfile/CommandClearRunningProfile's payload.
	// NodeID (declared above, shared with join/leave) names which node
	// the entry belongs to. StartedAt, like LockExpiresAt/LockNow above,
	// is computed ONCE by the proposer and carried in the log entry - Apply
	// never reads time.Now() (the identical determinism requirement).
	Profile   string                   `json:"profile,omitempty"`
	TenantID  string                   `json:"tenant_id,omitempty"`
	StartedAt time.Time                `json:"started_at,omitempty"`
	Footprint cluster.PlacementRequest `json:"footprint,omitempty"`

	// ReplicationRole carries the full role assignment for
	// CommandAssignReplicationRole/CommandReassignReplicationRole -
	// computed ONCE by the proposer (cluster.ReconcileTenantRole,
	// including its own AssignedAt) and replicated verbatim, matching
	// LockExpiresAt/LockNow's determinism discipline above: FSM.Apply
	// must produce identical state on every replica given the same log
	// entry, so this value is never recomputed locally by Apply itself.
	ReplicationRole *cluster.ReplicationRole `json:"replication_role,omitempty"`

	// Revocation is used only by CommandRevokeCertificate (Feature 004) -
	// the full record is carried inside the log entry itself (rather than
	// just a bare serial number) so every replica applies the IDENTICAL
	// RevokedAt/RevokedBy/Reason audit fields, for the same determinism
	// reason LockExpiresAt/LockNow are carried above rather than computed
	// independently by each node.
	Revocation *cluster.RevocationRecord `json:"revocation,omitempty"`

	// CARotation carries the full record for
	// CommandBeginCARotation/CommandFinalizeCARotation (Feature 004 Phase
	// 5) - computed ONCE by the proposer (BegunAt/FinalizedAt, matching
	// LockExpiresAt/LockNow/RevokedAt's identical determinism discipline
	// above) and replicated verbatim. CommandRecordCARotationTransition
	// does NOT use this field - it reuses the NodeID field already
	// declared above (shared with join/leave), naming which node has
	// transitioned.
	CARotation *cluster.CARotationEvent `json:"ca_rotation,omitempty"`
}

var (
	errCommandMissingNode              = errors.New("raft: join_node command missing Node")
	errUnknownCommand                  = errors.New("raft: unknown command type")
	errLockHeldByAnother               = errors.New("raft: acquire_lock refused: key is held by another holder and its lease has not yet expired")
	errNotLockHolder                   = errors.New("raft: release_lock refused: caller is not the current holder of this lock")
	errUpdateResourcesUnknownNode      = errors.New("raft: update_resources refused: node is not currently a cluster member")
	errRecordRunningProfileUnknownNode = errors.New("raft: record_running_profile refused: node is not currently a cluster member")
	errCommandMissingReplicationRole   = errors.New("raft: assign_replication_role/reassign_replication_role command missing ReplicationRole")
	errCommandMissingRevocation        = errors.New("raft: revoke_certificate command missing Revocation")
	errCommandMissingCARotation        = errors.New("raft: begin_ca_rotation/finalize_ca_rotation command missing CARotation")
	errCARotationAlreadyInProgress     = errors.New("raft: begin_ca_rotation refused: a DIFFERENT rotation is already in progress - finalize it first")
	errCARotationNotInProgress         = errors.New("raft: finalize_ca_rotation refused: no CA rotation is currently in progress")
	errCARotationFingerprintMismatch   = errors.New("raft: finalize_ca_rotation refused: fingerprints do not match the currently in-progress rotation")

	// ErrInsufficientCapacity is CommandRecordRunningProfile's Apply-time
	// re-validation refusal (FR-005/SC-004's TOCTOU-closing mechanism) -
	// exported (unlike its sibling errRecordRunningProfileUnknownNode) so
	// callers outside this package (running_profile.go's
	// Node.RecordRunningProfile, and in turn 002-cluster-model-scheduler
	// T016's placement-retry logic in internal/api) can distinguish "the
	// reservation lost a capacity race, re-place against fresh state" from
	// any other, genuinely unexpected failure via errors.Is.
	ErrInsufficientCapacity = errors.New("raft: record_running_profile refused: node no longer has sufficient uncommitted capacity for this footprint")
)

// ClusterFSM implements hashicorp/raft's FSM interface, applying replicated
// log entries to a cluster.ClusterState. Apply is deterministic: replaying
// the same sequence of log entries into a fresh FSM always produces
// byte-identical resulting state (proven by
// TestApply_DeterministicGivenSameLogSequence) - required because every
// node in the cluster replays the same log independently and must converge
// without further coordination.
//
// mu guards every access to state. This was NOT true when ClusterFSM was
// first implemented (Phase 9) - a real, previously-undiscovered data race
// (confirmed as a genuine `fatal error: concurrent map writes` crash under
// `go test -race`, not merely a benign-looking warning) was found and
// root-caused during Phase 11's T073: hashicorp/raft calls Apply from its
// own single-threaded FSM-apply goroutine while State() is called directly
// by HTTP handlers (routes_cluster.go's GET /v1/cluster/status and
// lock.go's Locks()) from whichever goroutine is serving that request - on
// any live cluster node, a status/locks query landing while a join/leave/
// lock command is being applied raced on the same cluster.ClusterState map
// fields. See fsm_test.go's TestApplyAndState_ConcurrentAccessIsRaceFree
// (added first as the RED, then fixed here as the GREEN) and
// internal/audit/log.go's own sibling fix (the same defect class, found
// moments earlier in the same investigation) for the full story.
type ClusterFSM struct {
	mu    sync.Mutex
	state *cluster.ClusterState

	// onRevocationApplied, when non-nil, is invoked every time a
	// CommandRevokeCertificate entry is applied OR a Restore replaces
	// f.state wholesale (Feature 004, T011) - the mechanism that keeps
	// every node's own live *mtls.TrustStore(s) synchronized with the
	// cluster's Raft-replicated revocation state, on EVERY node, with
	// zero polling. It takes no arguments (rather than the specific
	// RevocationRecord just applied) deliberately: the registered
	// handler's job is "go re-read node.State().Revocations and push the
	// FULL current set into TrustStore.UpdateRevoked" (see node.go's
	// SetRevocationHandler + cmd/llmctld/main.go's wiring) - a
	// REPLACE-with-the-full-set operation, not an incremental one, so a
	// generic "state changed" signal is both sufficient and, unlike a
	// per-record signature, forward-compatible with Phase 5's future
	// CA-rotation event without a second handler mechanism.
	//
	// Feature 004 Phase 5 (T023) exercises exactly that forward
	// compatibility: CommandBeginCARotation and CommandFinalizeCARotation
	// ALSO set notifyRevocation below, firing this SAME handler - the
	// registered closure (cmd/llmctld/main.go's wireRevocationHandler)
	// re-reads node.State().CARotation in addition to .Revocations, so
	// one handler mechanism, not two, keeps both revocation state AND
	// CA-rotation state synchronized on every node.
	//
	// CRITICAL (root-caused via Constitution §11.4.102 systematic
	// debugging while investigating an indefinitely-hanging integration
	// test, Feature 004 T007-T009): this handler MUST be invoked ONLY
	// AFTER f.mu has been released - see notifyRevocationApplied below,
	// which both Apply and Restore call for exactly this reason. An
	// earlier version of this code (and this doc comment) invoked the
	// handler while STILL HOLDING f.mu, on the theory that the callback
	// "observes a state that cannot change underneath it mid-callback."
	// That was a genuine, previously-undiscovered self-deadlock, not a
	// race: the ONLY handler this codebase registers
	// (cmd/llmctld/main.go's wireRevocationHandler) calls node.State(),
	// which calls ClusterFSM.State(), which itself calls f.mu.Lock() - on
	// the SAME goroutine (hashicorp/raft's single FSM-apply goroutine)
	// that was still holding f.mu when it invoked the handler. Go's
	// sync.Mutex is not reentrant, so every single revocation
	// deterministically deadlocked the FSM-apply goroutine forever, which
	// in turn meant Raft's Apply future for that log entry never
	// resolved, which in turn meant RevokeCertificate's future.Error()
	// blocked forever - manifesting as an indefinitely-hanging `go test`
	// process with no panic, no log line, and no timeout (the 5s
	// raftApplyTimeout in node.go bounds only the FSM's enqueue phase,
	// not waiting for its already-enqueued response).
	onRevocationApplied func()
}

// NewClusterFSM returns a ClusterFSM starting from empty cluster state.
func NewClusterFSM() *ClusterFSM {
	return &ClusterFSM{state: cluster.NewClusterState()}
}

// SetRevocationHandler registers fn to be invoked whenever this FSM's
// revocation-replicated state changes (see onRevocationApplied's doc
// comment for exactly when). Safe to call at any time - a nil fn is a
// valid "no handler registered" state (the zero value already means
// this), so tests / callers with no revocation-consuming logic (e.g.
// every pre-existing fsm_test.go test) are unaffected.
func (f *ClusterFSM) SetRevocationHandler(fn func()) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.onRevocationApplied = fn
}

// Apply implements hraft.FSM. It returns an error (never panics) on a
// malformed or unrecognized command, so a single bad log entry cannot take
// down the FSM goroutine.
func (f *ClusterFSM) Apply(log *hraft.Log) interface{} {
	var cmd Command
	if err := json.Unmarshal(log.Data, &cmd); err != nil {
		return err
	}

	f.mu.Lock()
	// notifyRevocation is set inside the locked switch below and consumed
	// by this deferred call - which, by Go's LIFO defer-execution order,
	// runs BEFORE the "defer f.mu.Unlock()" registered further down (that
	// defer is registered SECOND, so it executes FIRST). This guarantees
	// f.mu is already released by the time notifyRevocationApplied - and
	// therefore any registered handler - actually runs, closing the
	// self-deadlock documented on ClusterFSM.onRevocationApplied above.
	var notifyRevocation bool
	defer func() {
		if notifyRevocation {
			f.notifyRevocationApplied()
		}
	}()
	defer f.mu.Unlock()

	switch cmd.Type {
	case CommandJoinNode:
		if cmd.Node == nil {
			return errCommandMissingNode
		}
		f.state.Nodes[cmd.Node.ID] = *cmd.Node
	case CommandLeaveNode:
		delete(f.state.Nodes, cmd.NodeID)
	case CommandAcquireLock:
		existing, held := f.state.Locks[cmd.LockKey]
		if held && existing.Holder != cmd.LockHolder && cmd.LockNow.Before(existing.ExpiresAt) {
			return errLockHeldByAnother
		}
		f.state.Locks[cmd.LockKey] = cluster.LockEntry{Holder: cmd.LockHolder, ExpiresAt: cmd.LockExpiresAt}
	case CommandReleaseLock:
		existing, held := f.state.Locks[cmd.LockKey]
		if !held {
			// Idempotent no-op: a caller racing its own release against a
			// TTL expiry (or retrying a release whose Apply already
			// committed but whose response was lost) must never be
			// punished with an error for releasing something already gone.
			return nil
		}
		if existing.Holder != cmd.LockHolder {
			return errNotLockHolder
		}
		delete(f.state.Locks, cmd.LockKey)
	case CommandUpdateResources:
		existing, known := f.state.Nodes[cmd.NodeID]
		if !known {
			return errUpdateResourcesUnknownNode
		}
		existing.Resources = cmd.Resources
		f.state.Nodes[cmd.NodeID] = existing
	case CommandRecordRunningProfile:
		node, known := f.state.Nodes[cmd.NodeID]
		if !known {
			return errRecordRunningProfileUnknownNode
		}
		// Re-derive the node's CURRENTLY-uncommitted capacity purely from
		// already-committed log state (never from the proposer's own
		// pre-check) - the exact mechanism that closes the FR-005/SC-004
		// TOCTOU race: two concurrent proposers may both have observed
		// "node fits" against a stale snapshot, but hashicorp/raft applies
		// log entries strictly one at a time, so the SECOND Apply to run
		// here always sees the FIRST one's committed reservation.
		var usedRAM, usedVRAM int64
		var usedCPU, usedNetwork int
		for _, rp := range f.state.RunningProfiles {
			if rp.NodeID != cmd.NodeID {
				continue
			}
			usedRAM += rp.Footprint.RAMMB
			usedVRAM += rp.Footprint.VRAMMB
			usedCPU += rp.Footprint.CPUCores
			usedNetwork += rp.Footprint.NetworkMbps
		}
		availRAM := node.Resources.RAMAvailMB - usedRAM
		availVRAM := node.Resources.VRAMAvailMB - usedVRAM
		availCPU := node.Resources.CPUCores - usedCPU
		availNetwork := node.Resources.NetworkMbps - usedNetwork
		if availRAM < cmd.Footprint.RAMMB || availVRAM < cmd.Footprint.VRAMMB || availCPU < cmd.Footprint.CPUCores || availNetwork < cmd.Footprint.NetworkMbps {
			return ErrInsufficientCapacity
		}
		f.state.RunningProfiles = append(f.state.RunningProfiles, cluster.RunningProfile{
			Profile: cmd.Profile, TenantID: cmd.TenantID, NodeID: cmd.NodeID,
			StartedAt: cmd.StartedAt, Footprint: cmd.Footprint,
		})
	case CommandClearRunningProfile:
		filtered := f.state.RunningProfiles[:0:0]
		for _, rp := range f.state.RunningProfiles {
			if rp.Profile == cmd.Profile && rp.TenantID == cmd.TenantID && rp.NodeID == cmd.NodeID {
				continue
			}
			filtered = append(filtered, rp)
		}
		f.state.RunningProfiles = filtered
	case CommandAssignReplicationRole, CommandReassignReplicationRole:
		if cmd.ReplicationRole == nil {
			return errCommandMissingReplicationRole
		}
		// Atomic map-replace-in-place, exactly like CommandJoinNode's own
		// f.state.Nodes[cmd.Node.ID] = *cmd.Node write above: a single
		// map-entry assignment can never leave two ReplicationRole
		// entries for the same tenant momentarily visible, so
		// spec.md FR-011's "exactly one primary at any time" holds
		// structurally, not merely by convention.
		f.state.ReplicationRoles[cmd.ReplicationRole.TenantID] = *cmd.ReplicationRole
	case CommandRevokeCertificate:
		if cmd.Revocation == nil {
			return errCommandMissingRevocation
		}
		f.state.Revocations[cmd.Revocation.SerialNumber] = *cmd.Revocation
		notifyRevocation = true
	case CommandBeginCARotation:
		if cmd.CARotation == nil {
			return errCommandMissingCARotation
		}
		if existing := f.state.CARotation; existing != nil && existing.Status == "in_progress" {
			if existing.OutgoingCAFingerprint == cmd.CARotation.OutgoingCAFingerprint &&
				existing.IncomingCAFingerprint == cmd.CARotation.IncomingCAFingerprint {
				// Idempotent no-op (TestApply_BeginCARotation_
				// IdempotentOnMatchingFingerprints): a DIFFERENT node's
				// own local "begin rotation" API call submitting the
				// SAME rotation that is already in progress - the
				// canonical record (including its original BegunAt) is
				// left untouched.
				return nil
			}
			return errCARotationAlreadyInProgress
		}
		rec := *cmd.CARotation
		rec.TransitionedNodeIDs = append([]string(nil), cmd.CARotation.TransitionedNodeIDs...)
		f.state.CARotation = &rec
		notifyRevocation = true
	case CommandFinalizeCARotation:
		if cmd.CARotation == nil {
			return errCommandMissingCARotation
		}
		existing := f.state.CARotation
		if existing == nil || existing.Status != "in_progress" {
			return errCARotationNotInProgress
		}
		if existing.OutgoingCAFingerprint != cmd.CARotation.OutgoingCAFingerprint ||
			existing.IncomingCAFingerprint != cmd.CARotation.IncomingCAFingerprint {
			return errCARotationFingerprintMismatch
		}
		finalized := *existing
		finalized.TransitionedNodeIDs = append([]string(nil), existing.TransitionedNodeIDs...)
		finalized.Status = "finalized"
		finalized.FinalizedAt = cmd.CARotation.FinalizedAt
		f.state.CARotation = &finalized
		notifyRevocation = true
	case CommandRecordCARotationTransition:
		existing := f.state.CARotation
		if existing == nil || existing.Status != "in_progress" {
			// Idempotent no-op (TestApply_RecordCARotationTransition_
			// NoOpWhenNoneInProgress), mirroring CommandReleaseLock's own
			// idempotent-no-op-on-already-gone precedent above: a
			// renewal reporting a transition after the rotation already
			// finalized (or one that was never begun, e.g. a stale
			// retry) has nothing to record.
			return nil
		}
		already := false
		for _, id := range existing.TransitionedNodeIDs {
			if id == cmd.NodeID {
				already = true
				break
			}
		}
		if !already {
			updated := *existing
			updated.TransitionedNodeIDs = append(append([]string(nil), existing.TransitionedNodeIDs...), cmd.NodeID)
			f.state.CARotation = &updated
		}
		// No notify: TrustStore pool contents depend only on Status/
		// fingerprints (both unchanged by this command), never on
		// TransitionedNodeIDs - see wireRevocationHandler's own doc
		// comment for exactly which fields drive a pool update.
	default:
		return errUnknownCommand
	}
	return nil
}

// Snapshot implements hraft.FSM.
func (f *ClusterFSM) Snapshot() (hraft.FSMSnapshot, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return &fsmSnapshot{state: f.state.Clone()}, nil
}

// notifyRevocationApplied safely invokes the currently-registered
// onRevocationApplied handler (if any) WITHOUT holding f.mu while the
// handler itself runs - see onRevocationApplied's doc comment for the
// self-deadlock this specifically avoids. It briefly re-acquires f.mu
// only to copy the handler pointer (so a concurrent SetRevocationHandler
// call can never race the read of f.onRevocationApplied under -race),
// then releases f.mu before calling the copied handler.
func (f *ClusterFSM) notifyRevocationApplied() {
	f.mu.Lock()
	handler := f.onRevocationApplied
	f.mu.Unlock()
	if handler != nil {
		handler()
	}
}

// Restore implements hraft.FSM.
func (f *ClusterFSM) Restore(rc io.ReadCloser) error {
	defer func() { _ = rc.Close() }()
	var state cluster.ClusterState
	if err := json.NewDecoder(rc).Decode(&state); err != nil {
		return err
	}
	if state.Nodes == nil {
		state.Nodes = make(map[string]cluster.Node)
	}
	if state.Locks == nil {
		state.Locks = make(map[string]cluster.LockEntry)
	}
	if state.RunningProfiles == nil {
		state.RunningProfiles = []cluster.RunningProfile{}
	}
	if state.ReplicationRoles == nil {
		state.ReplicationRoles = make(map[string]cluster.ReplicationRole)
	}
	if state.Revocations == nil {
		state.Revocations = make(map[string]cluster.RevocationRecord)
	}

	f.mu.Lock()
	f.state = &state
	f.mu.Unlock()
	// A node catching up via a Raft SNAPSHOT (rather than replaying every
	// individual log entry) never goes through Apply's
	// CommandRevokeCertificate case at all - Restore is the ONLY point at
	// which such a node's revocation-replicated state changes, so the
	// handler MUST also fire here (Feature 004, T011) or a
	// snapshot-catch-up node's own TrustStore would silently never learn
	// about a revocation that happened before it caught up - exactly the
	// T009 "previously-unreachable node learns the revocation on
	// reconnect" property.
	//
	// f.mu is deliberately released (above) BEFORE this call - see
	// onRevocationApplied's doc comment for the self-deadlock this
	// avoids; notifyRevocationApplied re-acquires f.mu only briefly to
	// safely read the handler pointer.
	f.notifyRevocationApplied()
	return nil
}

// State returns a deep-copied snapshot of the current cluster state, safe
// for callers outside the Raft log-apply goroutine (e.g. HTTP handlers) to
// read without racing further Apply calls - a guarantee this doc comment
// now actually keeps (see the ClusterFSM.mu doc comment for the real,
// previously-undiscovered race this fixed).
func (f *ClusterFSM) State() *cluster.ClusterState {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.state.Clone()
}

type fsmSnapshot struct {
	state *cluster.ClusterState
}

func (s *fsmSnapshot) Persist(sink hraft.SnapshotSink) error {
	data, err := json.Marshal(s.state)
	if err != nil {
		_ = sink.Cancel()
		return err
	}
	if _, err := sink.Write(data); err != nil {
		_ = sink.Cancel()
		return err
	}
	return sink.Close()
}

func (s *fsmSnapshot) Release() {}
