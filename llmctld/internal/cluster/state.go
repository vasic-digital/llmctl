// Package cluster holds the Raft-replicated cluster state (node membership
// and health) that internal/raft's ClusterFSM applies log entries to.
package cluster

import "time"

// Node is one llmctld instance participating in the cluster.
type Node struct {
	ID     string `json:"id"`
	Addr   string `json:"addr"`
	Health string `json:"health"` // "healthy" | "unhealthy" | "unknown"

	// Resources is this node's total capacity, as reported by its local
	// hardware probe (field names mirror lib/hardware.sh's JSON schema:
	// cpu.cores, memory.total_mb, gpu_total_vram_mb) - the inputs
	// placement.go's bin-packing needs (FR-020).
	Resources Resources `json:"resources"`
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

// RevocationRecord is one revoked mTLS certificate identity, replicated
// via the FSM (Feature 004, data-model.md). Keyed by the certificate's
// real x509 SERIAL NUMBER (research.md Decision 4) rather than by NodeID:
// a node whose certificate is revoked and is later re-issued a FRESH
// certificate (a new serial) is unaffected by this record - revocation
// targets one specific compromised credential, never a node identity in
// the abstract, and is deliberately independent of cluster-membership
// eviction (spec.md FR-012).
type RevocationRecord struct {
	// SerialNumber is the revoked leaf certificate's real
	// x509.Certificate.SerialNumber.String() - the ClusterState.Revocations
	// map key, duplicated here so a RevocationRecord is self-describing
	// when read out of that map or serialized on its own.
	SerialNumber string `json:"serial_number"`
	// NodeID is the node identity the revoked certificate was issued for
	// (an audit/display label - revocation enforcement itself keys
	// exclusively on SerialNumber, never on this field).
	NodeID string `json:"node_id"`
	// Reason is a free-text operator-supplied justification (e.g.
	// "compromised") - never validated against a closed vocabulary, since
	// spec.md does not define one and inventing one here would be an
	// unrequested constraint (Constitution §11.4.6: no invented default).
	Reason string `json:"reason"`
	// RevokedBy is the authenticated caller (JWT claims.Subject) who
	// issued the revoke action - an audit trail, not an enforcement input.
	RevokedBy string `json:"revoked_by"`
	// RevokedAt is the moment the revoke action was accepted, set ONCE by
	// the proposing node (mirroring LockEntry/Command's own
	// proposer-computes-the-timestamp discipline in internal/raft/fsm.go's
	// Command.LockNow doc comment) and carried inside the replicated log
	// entry, so every node's FSM applies the IDENTICAL timestamp.
	RevokedAt time.Time `json:"revoked_at"`
}

// ClusterState is the FSM-applied cluster state, replicated identically
// across every Raft node via the log.
type ClusterState struct {
	Nodes       map[string]Node             `json:"nodes"`
	Locks       map[string]LockEntry        `json:"locks"`
	Revocations map[string]RevocationRecord `json:"revocations"`
}

// NewClusterState returns an empty, ready-to-use ClusterState.
func NewClusterState() *ClusterState {
	return &ClusterState{
		Nodes:       make(map[string]Node),
		Locks:       make(map[string]LockEntry),
		Revocations: make(map[string]RevocationRecord),
	}
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
	for serial, rec := range s.Revocations {
		clone.Revocations[serial] = rec
	}
	return clone
}
