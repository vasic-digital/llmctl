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

// ReplicationRole is one tenant's per-tenant KV-cache-replication
// forwarding-role assignment (003-kv-cache-replication data-model.md):
// which node is currently authoritative for forwarding TenantID's
// internal/replication.Store content, and which nodes are its current
// replicas. Distinct from ReplicaState (below), which models how many
// copies of a MODEL are running - see this feature's research.md
// Decision 2 for why these are two separate records rather than one
// merged structure: a tenant's replicated stream can outlive any single
// model-hosting decision, which is the whole point of surviving a
// model-instance failover.
type ReplicationRole struct {
	// TenantID is the tenant whose replicated stream this assignment
	// concerns. The empty string names the default/no-tenancy stream
	// every existing internal/replication.StoreRegistry.Get("") caller
	// already uses.
	TenantID string `json:"tenant_id"`
	// PrimaryNodeID is the one node currently authoritative for
	// forwarding this tenant's replication.Store content (spec.md
	// FR-011: exactly one at any time - guaranteed structurally here by
	// this being a single map entry per tenant, replaced atomically,
	// exactly like CommandJoinNode's own map-replace-in-place pattern
	// for Nodes above - two records for the same tenant can never
	// momentarily coexist).
	PrimaryNodeID string `json:"primary_node_id"`
	// ReplicaNodeIDs is every node that should be receiving forwarded
	// appends/checkpoints for this tenant.
	ReplicaNodeIDs []string `json:"replica_node_ids"`
	// AssignedAt is when this assignment took effect - computed ONCE by
	// the proposer and carried inside the log entry itself (matching
	// LockEntry.ExpiresAt's own determinism discipline: FSM.Apply must
	// produce identical state on every replica given the same log entry,
	// so a value like time.Now() is never read locally by Apply itself).
	AssignedAt time.Time `json:"assigned_at"`
}

// ClusterState is the FSM-applied cluster state, replicated identically
// across every Raft node via the log.
type ClusterState struct {
	Nodes            map[string]Node            `json:"nodes"`
	Locks            map[string]LockEntry       `json:"locks"`
	ReplicationRoles map[string]ReplicationRole `json:"replication_roles"`
}

// NewClusterState returns an empty, ready-to-use ClusterState.
func NewClusterState() *ClusterState {
	return &ClusterState{
		Nodes:            make(map[string]Node),
		Locks:            make(map[string]LockEntry),
		ReplicationRoles: make(map[string]ReplicationRole),
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
	for tenantID, role := range s.ReplicationRoles {
		replicas := make([]string, len(role.ReplicaNodeIDs))
		copy(replicas, role.ReplicaNodeIDs)
		role.ReplicaNodeIDs = replicas
		clone.ReplicationRoles[tenantID] = role
	}
	return clone
}
