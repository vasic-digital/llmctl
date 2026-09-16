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

	// ReplicationRole carries the full role assignment for
	// CommandAssignReplicationRole/CommandReassignReplicationRole -
	// computed ONCE by the proposer (cluster.ReconcileTenantRole,
	// including its own AssignedAt) and replicated verbatim, matching
	// LockExpiresAt/LockNow's determinism discipline above: FSM.Apply
	// must produce identical state on every replica given the same log
	// entry, so this value is never recomputed locally by Apply itself.
	ReplicationRole *cluster.ReplicationRole `json:"replication_role,omitempty"`
}

var (
	errCommandMissingNode            = errors.New("raft: join_node command missing Node")
	errUnknownCommand                = errors.New("raft: unknown command type")
	errLockHeldByAnother             = errors.New("raft: acquire_lock refused: key is held by another holder and its lease has not yet expired")
	errNotLockHolder                 = errors.New("raft: release_lock refused: caller is not the current holder of this lock")
	errCommandMissingReplicationRole = errors.New("raft: assign_replication_role/reassign_replication_role command missing ReplicationRole")
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
}

// NewClusterFSM returns a ClusterFSM starting from empty cluster state.
func NewClusterFSM() *ClusterFSM {
	return &ClusterFSM{state: cluster.NewClusterState()}
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
	if state.ReplicationRoles == nil {
		state.ReplicationRoles = make(map[string]cluster.ReplicationRole)
	}

	f.mu.Lock()
	defer f.mu.Unlock()
	f.state = &state
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
