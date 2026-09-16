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
}

var (
	errCommandMissingNode              = errors.New("raft: join_node command missing Node")
	errUnknownCommand                  = errors.New("raft: unknown command type")
	errLockHeldByAnother               = errors.New("raft: acquire_lock refused: key is held by another holder and its lease has not yet expired")
	errNotLockHolder                   = errors.New("raft: release_lock refused: caller is not the current holder of this lock")
	errUpdateResourcesUnknownNode      = errors.New("raft: update_resources refused: node is not currently a cluster member")
	errRecordRunningProfileUnknownNode = errors.New("raft: record_running_profile refused: node is not currently a cluster member")

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
	if state.RunningProfiles == nil {
		state.RunningProfiles = []cluster.RunningProfile{}
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
