// Package replication (lag.go): 003-kv-cache-replication's replication-
// lag tracking (T018, data-model.md's ReplicationLagRecord, User Story 3,
// spec.md FR-010). LagTracker is fed EXCLUSIVELY from forwarder.go's own
// real per-replica forward attempts (T008's EXISTING forwarding-
// acknowledgment traffic - a real HTTP 200 response from a replica's
// /v1/replication/append or /v1/replication/checkpoint route IS the
// acknowledgment) - this file deliberately does NOT invent a second,
// parallel acknowledgment channel (Constitution §11.4.6/§11.4.227
// extend-don't-duplicate): Forwarder.forwardToReplicas (forwarder.go)
// calls LagTracker.recordAttempt before every real per-replica POST and
// LagTracker.recordConfirmed after every one that returns HTTP 200 -
// exactly mirroring the real acknowledgment signal already flowing
// through T008's code path, never a hand-fed/simulated one.
//
// Persistence (data-model.md's ReplicationLagRecord section): in-memory
// only, on the primary node, rebuilt from real forwarding traffic - NOT
// Raft-replicated (this is observability data about replication's
// progress, not state every node must agree on, matching 002's
// PlacementDecision precedent data-model.md itself cites).
package replication

import (
	"sort"
	"sync"
)

// ReplicationLagRecord is data-model.md's per-tenant, per-replica lag
// snapshot: how far behind a replica's last-confirmed-received WAL Seq
// (wal.go's existing field) is from the primary's own current highest
// Seq. Lag is the field data-model.md names explicitly as derived
// (PrimarySeq - LastConfirmedSeq; zero means fully caught up - SC-002/
// SC-005) - computed fresh on every read (Lag/TenantLag below), never
// itself stored, so it can never independently drift from its two real
// source fields.
type ReplicationLagRecord struct {
	TenantID         string `json:"tenant_id"`
	ReplicaNodeID    string `json:"replica_node_id"`
	LastConfirmedSeq uint64 `json:"last_confirmed_seq"`
	PrimarySeq       uint64 `json:"primary_seq"`
	Lag              uint64 `json:"lag"`
}

// lagState is the mutable per-(tenant,replica) state LagTracker keeps
// internally - deliberately unexported and distinct from the public
// ReplicationLagRecord (which also carries the derived Lag field) so the
// derived field can never itself be assigned out of sync with its two
// real source fields; it is always recomputed from lagState at read time
// (record method below).
type lagState struct {
	lastConfirmedSeq uint64
	primarySeq       uint64
}

// record derives tenantID/replicaID's current ReplicationLagRecord from
// s. A defensive floor at zero (rather than letting an unsigned
// subtraction underflow into a huge value) covers the case where
// LastConfirmedSeq has, for whatever reason, ever exceeded PrimarySeq -
// this should not normally happen (recordConfirmed also advances
// PrimarySeq defensively, see below), but a lag calculation must never
// report a nonsensical multi-exabyte "gap" if it ever did.
func (s lagState) record(tenantID, replicaID string) ReplicationLagRecord {
	lag := uint64(0)
	if s.primarySeq > s.lastConfirmedSeq {
		lag = s.primarySeq - s.lastConfirmedSeq
	}
	return ReplicationLagRecord{
		TenantID:         tenantID,
		ReplicaNodeID:    replicaID,
		LastConfirmedSeq: s.lastConfirmedSeq,
		PrimarySeq:       s.primarySeq,
		Lag:              lag,
	}
}

// LagTracker is the in-memory (never Raft-replicated - see this file's
// package doc comment) store of every tenant's per-replica
// ReplicationLagRecord, safe for concurrent use: Forwarder's own forward
// calls run on whatever goroutine handled the originating HTTP request,
// so multiple tenants'/replicas' updates can race with each other and
// with concurrent reads from the new GET /v1/replication/lag route
// (T019).
type LagTracker struct {
	mu    sync.Mutex
	byKey map[string]map[string]*lagState // tenantID -> replicaNodeID -> state
}

// NewLagTracker returns an empty LagTracker - a tenant/replica pair with
// no recorded state simply has no forward attempt yet (Lag/TenantLag
// report ok=false / an empty slice for it, never a fabricated zero -
// SC-005's "every reported 'caught up' state is real" bar applies to
// absence too: unknown is reported as unknown, never as caught up).
func NewLagTracker() *LagTracker {
	return &LagTracker{byKey: make(map[string]map[string]*lagState)}
}

// stateFor returns tenantID/replicaID's mutable lagState, creating it on
// first use. Callers MUST hold t.mu.
func (t *LagTracker) stateFor(tenantID, replicaID string) *lagState {
	byReplica, ok := t.byKey[tenantID]
	if !ok {
		byReplica = make(map[string]*lagState)
		t.byKey[tenantID] = byReplica
	}
	s, ok := byReplica[replicaID]
	if !ok {
		s = &lagState{}
		byReplica[replicaID] = s
	}
	return s
}

// recordAttempt advances tenantID/replicaID's known PrimarySeq to seq
// (never backward - a stale/out-of-order call must never make Lag appear
// smaller than it genuinely is). Called by forwarder.go BEFORE every real
// per-replica forward attempt (success or failure alike), so a replica
// that is currently unreachable - or whose address cannot even be
// resolved - still shows a growing, real lag the moment the primary has
// moved past it, matching spec.md's Edge Cases: "the replica's lag must
// become visible ... rather than silently dropped."
func (t *LagTracker) recordAttempt(tenantID, replicaID string, seq uint64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	s := t.stateFor(tenantID, replicaID)
	if seq > s.primarySeq {
		s.primarySeq = seq
	}
}

// recordConfirmed advances tenantID/replicaID's LastConfirmedSeq to seq
// (never backward). Called by forwarder.go ONLY after a real HTTP 200
// acknowledgment from that replica for a forward attempt carrying seq
// (T008's existing acknowledgment signal - see this file's package doc
// comment). Also advances PrimarySeq to at least seq, defensively, so a
// confirmation can never leave PrimarySeq < LastConfirmedSeq (which would
// otherwise depend entirely on lagState.record's underflow guard to avoid
// a nonsensical lag figure).
func (t *LagTracker) recordConfirmed(tenantID, replicaID string, seq uint64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	s := t.stateFor(tenantID, replicaID)
	if seq > s.lastConfirmedSeq {
		s.lastConfirmedSeq = seq
	}
	if seq > s.primarySeq {
		s.primarySeq = seq
	}
}

// Lag returns tenantID/replicaID's current ReplicationLagRecord, or
// ok=false if no forward attempt has ever been recorded for that exact
// pair (distinct from a real, confirmed zero lag).
func (t *LagTracker) Lag(tenantID, replicaID string) (ReplicationLagRecord, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	byReplica, ok := t.byKey[tenantID]
	if !ok {
		return ReplicationLagRecord{}, false
	}
	s, ok := byReplica[replicaID]
	if !ok {
		return ReplicationLagRecord{}, false
	}
	return s.record(tenantID, replicaID), true
}

// TenantLag returns every replica this tracker currently has a lag
// record for under tenantID, sorted by ReplicaNodeID for deterministic
// output (the read endpoint's JSON response, T019, and this file's own
// tests). Returns an empty (non-nil) slice, never nil, when tenantID has
// no recorded replicas yet - callers (routes_replication.go's JSON
// response) never need a nil-vs-empty special case.
func (t *LagTracker) TenantLag(tenantID string) []ReplicationLagRecord {
	t.mu.Lock()
	defer t.mu.Unlock()
	byReplica := t.byKey[tenantID]
	out := make([]ReplicationLagRecord, 0, len(byReplica))
	for replicaID, s := range byReplica {
		out = append(out, s.record(tenantID, replicaID))
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ReplicaNodeID < out[j].ReplicaNodeID })
	return out
}
