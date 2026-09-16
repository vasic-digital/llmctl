// Package cluster holds the Raft-replicated cluster state (node membership
// and health) that internal/raft's ClusterFSM applies log entries to.
package cluster

import "time"

// Node is one llmctld instance participating in the cluster.
type Node struct {
	ID     string `json:"id"`
	Addr   string `json:"addr"`
	Health string `json:"health"` // "healthy" | "unhealthy" | "unknown"

	// APIAddr is this node's own HTTP/3+mTLS cluster-API bind address
	// (internal/api.Server's real bound address, e.g. "127.0.0.1:54321") -
	// DISTINCT from Addr, which is this node's Raft transport address
	// (internal/raft's QUIC+mTLS transport, a different listener/port
	// entirely). Cross-node model-lifecycle forwarding (002-cluster-
	// model-scheduler's FR-001/FR-015) dials THIS address, never Addr -
	// forwarding a real HTTP request to a node's Raft transport port would
	// simply fail to speak HTTP at all. Populated at real join/bootstrap
	// time (raft.Node.Join/RegisterSelf), exactly like Addr and Resources.
	APIAddr string `json:"api_addr"`

	// Resources is this node's total capacity, as reported by its local
	// hardware probe (field names mirror lib/hardware.sh's JSON schema:
	// cpu.cores, memory.total_mb, gpu_total_vram_mb) - the inputs
	// placement.go's bin-packing needs (FR-020). Refreshed periodically
	// (002-cluster-model-scheduler's resource-heartbeat, health.go) so a
	// value more than one health-check interval stale never silently
	// persists.
	Resources Resources `json:"resources"`
}

// RunningProfile is one profile currently running on one node - the
// entity 002-cluster-model-scheduler's cluster-wide running-profile
// index is built from (spec.md's "Cluster-Wide Running-Profile Index").
// (Profile, TenantID) MAY map to more than one NodeID simultaneously
// (spec.md's Edge Cases explicitly requires this be reported, never
// silently collapsed to one) - the index is therefore a slice of entries,
// never a single-valued map keyed by profile name.
type RunningProfile struct {
	Profile  string `json:"profile"`
	TenantID string `json:"tenant_id"`
	NodeID   string `json:"node_id"`

	// StartedAt is computed ONCE by the proposer (never read from
	// time.Now() inside ClusterFSM.Apply) and carried in the Raft log
	// entry itself, so every replica applies the IDENTICAL value -
	// required for Apply's determinism guarantee (matching
	// CommandAcquireLock's LockExpiresAt/LockNow fields' exact rationale
	// in internal/raft/fsm.go).
	StartedAt time.Time `json:"started_at"`

	// Footprint is the resource footprint this instance reserved on
	// NodeID - required so CommandRecordRunningProfile's Apply can
	// re-derive "how much of this node's capacity is already spoken for"
	// purely from replicated state, without consulting anything outside
	// the log (the TOCTOU-closing mechanism FR-005/SC-004 require).
	Footprint PlacementRequest `json:"footprint"`
}

// Resources describes a node's (or a placement request's) resource
// footprint for bin-packing. NetworkMbps is a coarse per-node capacity
// hint, not a full network-topology model - no richer requirement exists
// in the spec for FR-020's "Network awareness" than that placement must
// consider it, so a single scalar is the minimal, defensible design
// (Constitution §11.4.101: safe, reversible, internal-only decision).
type Resources struct {
	CPUCores    int   `json:"cpu_cores"`
	RAMTotalMB  int64 `json:"ram_total_mb"`
	RAMAvailMB  int64 `json:"ram_avail_mb"`
	VRAMTotalMB int64 `json:"vram_total_mb"`
	VRAMAvailMB int64 `json:"vram_avail_mb"`
	NetworkMbps int   `json:"network_mbps"`
}

// LockEntry is one held distributed lock, replicated via the FSM.
// internal/raft's lock.go wraps this in a linearized Acquire/Release API
// so two nodes never race to concurrently download/load/update the same
// model into the shared pool (FR-029).
type LockEntry struct {
	Holder    string    `json:"holder"`
	ExpiresAt time.Time `json:"expires_at"`
}

// ClusterState is the FSM-applied cluster state, replicated identically
// across every Raft node via the log.
type ClusterState struct {
	Nodes map[string]Node      `json:"nodes"`
	Locks map[string]LockEntry `json:"locks"`

	// RunningProfiles is the cluster-wide running-profile index
	// (002-cluster-model-scheduler) - every profile instance currently
	// known to be running on some node, across the whole cluster.
	RunningProfiles []RunningProfile `json:"running_profiles"`
}

// NewClusterState returns an empty, ready-to-use ClusterState.
func NewClusterState() *ClusterState {
	return &ClusterState{Nodes: make(map[string]Node), Locks: make(map[string]LockEntry), RunningProfiles: []RunningProfile{}}
}

// Clone returns a deep copy so callers can read/serialize state without
// racing the FSM's own goroutine as it applies further log entries.
func (s *ClusterState) Clone() *ClusterState {
	clone := NewClusterState()
	for id, node := range s.Nodes {
		clone.Nodes[id] = node
	}
	for key, lock := range s.Locks {
		clone.Locks[key] = lock
	}
	clone.RunningProfiles = append(clone.RunningProfiles, s.RunningProfiles...)
	return clone
}
