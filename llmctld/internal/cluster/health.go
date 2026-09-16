// Package cluster (health.go): a periodic health-check loop against every
// known cluster node (FR-025) that triggers leader-driven rescheduling on
// failure (SC-015), plus a reconciliation pass that re-places a
// replacement replica whenever a model's live replica count drops below
// its target (T052a, SC-018).
package cluster

import (
	"sort"
	"sync"
	"time"
)

// StatusChecker reports whether the node reachable at addr is currently
// healthy. The real implementation (wired at T058) issues a real HTTP GET
// against that node's /v1/cluster/status; tests inject a fake so this
// file's loop/dedup logic is exercised without a real HTTP server -
// internal/cluster cannot import internal/api (or internal/raft) to call
// a concrete HTTP client directly without an import cycle (internal/raft
// already imports internal/cluster via fsm.go), so a function type is the
// correct decoupling here, matching lock.go's identical constraint.
type StatusChecker func(addr string) bool

// Rescheduler is invoked with the ID of a node just detected unhealthy.
// The real implementation (wired at T058/internal/executor) tells the
// leader to re-place that node's workloads elsewhere; tests inject a fake
// to assert it is called with the right ID exactly once per failure
// episode.
type Rescheduler func(failedNodeID string)

// Placer is the subset of Place()'s signature Reconcile needs, as a
// function type so tests can inject a fake without needing real
// candidate/resource fixtures for every reconciliation scenario. In
// production, callers pass Place itself.
type Placer func(candidates []Node, req PlacementRequest) (Node, error)

// DefaultHealthCheckInterval is FR-025's health-check cadence (10s).
const DefaultHealthCheckInterval = 10 * time.Second

// Monitor runs CheckOnce on a ticker against every registered node,
// deduplicating so Rescheduler fires exactly once per failure episode (a
// node that stays down across many CheckOnce calls does not re-trigger
// Rescheduler on every tick; recovering and later failing again is a
// fresh episode and does trigger it again).
type Monitor struct {
	mu        sync.Mutex
	nodes     map[string]string // nodeID -> health-check address
	unhealthy map[string]bool   // nodeID -> currently-reported-unhealthy

	checker    StatusChecker
	reschedule Rescheduler
	interval   time.Duration

	stopCh chan struct{}
	doneCh chan struct{}
}

// NewMonitor constructs a Monitor. checker and reschedule may be nil for
// a Monitor that will only ever be used for Reconcile (which needs
// neither) - CheckOnce/Start would panic on a nil checker if ever called,
// which is the correct fail-fast behavior for a genuine misconfiguration
// rather than silently no-op-ing.
func NewMonitor(checker StatusChecker, reschedule Rescheduler, interval time.Duration) *Monitor {
	if interval <= 0 {
		interval = DefaultHealthCheckInterval
	}
	return &Monitor{
		nodes:      make(map[string]string),
		unhealthy:  make(map[string]bool),
		checker:    checker,
		reschedule: reschedule,
		interval:   interval,
	}
}

// SetNodes replaces the set of nodes Monitor checks (nodeID -> health
// check address). Safe to call while Start()'s loop is running.
func (m *Monitor) SetNodes(nodes map[string]string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.nodes = make(map[string]string, len(nodes))
	for id, addr := range nodes {
		m.nodes[id] = addr
	}
}

// CheckOnce runs a single health-check pass over every currently
// registered node.
func (m *Monitor) CheckOnce() {
	m.mu.Lock()
	nodes := make(map[string]string, len(m.nodes))
	for id, addr := range m.nodes {
		nodes[id] = addr
	}
	m.mu.Unlock()

	for id, addr := range nodes {
		healthy := m.checker(addr)

		m.mu.Lock()
		wasUnhealthy := m.unhealthy[id]
		m.unhealthy[id] = !healthy
		m.mu.Unlock()

		if !healthy && !wasUnhealthy && m.reschedule != nil {
			m.reschedule(id)
		}
	}
}

// Start runs CheckOnce every interval on a background goroutine until
// Stop is called. Calling Start while already running is a safe no-op.
func (m *Monitor) Start() {
	m.mu.Lock()
	if m.stopCh != nil {
		m.mu.Unlock()
		return
	}
	m.stopCh = make(chan struct{})
	m.doneCh = make(chan struct{})
	stopCh := m.stopCh
	doneCh := m.doneCh
	interval := m.interval
	m.mu.Unlock()

	go func() {
		defer close(doneCh)
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				m.CheckOnce()
			case <-stopCh:
				return
			}
		}
	}()
}

// Stop halts a running Start() loop and waits for its goroutine to exit.
// Calling Stop when not running is a safe no-op.
func (m *Monitor) Stop() {
	m.mu.Lock()
	stopCh := m.stopCh
	doneCh := m.doneCh
	m.stopCh = nil
	m.mu.Unlock()

	if stopCh == nil {
		return
	}
	close(stopCh)
	<-doneCh
}

// ReconcileReplicationRoles recomputes, per tenant, the ReplicationRole
// for every tenant CURRENTLY primaried by failedNodeID - the node a
// Monitor.Rescheduler callback just reported unhealthy (T004: this reuses
// that SAME failure-detection signal, never a second, independently-
// reasoned unhealthy-node check, per research.md Decision 2).
//
// preferredPrimary, when non-empty and present in liveNodeIDs, is used as
// each affected tenant's new primary - research.md Decision 2's "natural
// default": if 002's own placement decision already chose a new host for
// that tenant's model instance, prefer that node. When preferredPrimary
// is empty, or is itself not live, the first (sorted) remaining live node
// other than failedNodeID is used instead, so a failure is never left
// unresolved merely because no placement preference was supplied.
//
// The decision itself is delegated entirely to ReconcileTenantRole (this
// package's own pure per-tenant reconciliation function) - this function
// is purely the per-tenant fan-out + preferred-primary selection layer
// over it, so there is exactly one place (ReconcileTenantRole) that
// decides what a reassigned role looks like.
//
// Returns only the tenants whose role actually CHANGED (never re-returns
// an unaffected tenant's untouched role) - the caller (internal/raft,
// which alone can issue a real Raft log entry) applies each returned
// role via CommandReassignReplicationRole.
func ReconcileReplicationRoles(roles map[string]ReplicationRole, failedNodeID string, liveNodeIDs []string, preferredPrimary string, now time.Time) map[string]ReplicationRole {
	changed := make(map[string]ReplicationRole)

	newPrimary := preferredPrimary
	if newPrimary == "" || !stringSliceContains(liveNodeIDs, newPrimary) {
		newPrimary = firstOtherLiveNode(liveNodeIDs, failedNodeID)
	}
	if newPrimary == "" {
		// No live candidate at all to take over - honestly report nothing
		// reassignable rather than fabricating a primary (Constitution
		// §11.4.6 no-guessing).
		return changed
	}

	for tenantID, existing := range roles {
		if existing.PrimaryNodeID != failedNodeID {
			continue
		}
		role, wasChanged, _ := ReconcileTenantRole(existing, true, tenantID, newPrimary, liveNodeIDs, []string{failedNodeID}, now)
		if wasChanged {
			changed[tenantID] = role
		}
	}

	return changed
}

func stringSliceContains(ids []string, target string) bool {
	for _, id := range ids {
		if id == target {
			return true
		}
	}
	return false
}

func firstOtherLiveNode(liveNodeIDs []string, exclude string) string {
	sorted := make([]string, len(liveNodeIDs))
	copy(sorted, liveNodeIDs)
	sort.Strings(sorted)
	for _, id := range sorted {
		if id != exclude {
			return id
		}
	}
	return ""
}

// Reconcile inspects each ReplicaState and, for every model that
// UnderReplicated()s, calls place (typically Place itself) to choose
// healthy candidates - excluding nodes already hosting a live replica of
// that model - for exactly Deficit() replacement replicas. It returns the
// chosen node IDs keyed by model name; a model with no deficit is simply
// absent from the result (never a zero-length-slice placeholder).
//
// Reconcile never fabricates a placement: if place refuses (no healthy
// candidate has capacity), it stops for that model and returns whatever
// it already placed - satisfying part of the deficit is honestly reported
// as partial, never silently padded to look fully reconciled.
func (m *Monitor) Reconcile(states []ReplicaState, candidates []Node, req PlacementRequest, place Placer) map[string][]string {
	result := make(map[string][]string)

	for _, s := range states {
		if !s.UnderReplicated() {
			continue
		}

		excluded := make(map[string]bool, len(s.LiveNodeIDs))
		for _, id := range s.LiveNodeIDs {
			excluded[id] = true
		}
		remaining := make([]Node, 0, len(candidates))
		for _, c := range candidates {
			if !excluded[c.ID] {
				remaining = append(remaining, c)
			}
		}

		var chosen []string
		for i := 0; i < s.Deficit(); i++ {
			n, err := place(remaining, req)
			if err != nil {
				break
			}
			chosen = append(chosen, n.ID)

			filtered := remaining[:0:0]
			for _, c := range remaining {
				if c.ID != n.ID {
					filtered = append(filtered, c)
				}
			}
			remaining = filtered
		}

		if len(chosen) > 0 {
			result[s.Model] = chosen
		}
	}

	return result
}
