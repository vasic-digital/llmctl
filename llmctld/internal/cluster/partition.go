// Package cluster (partition.go): detects loss of Raft quorum contact and
// exposes a drain state an HTTP layer (T058, not yet built) can consult to
// refuse new requests immediately while letting in-flight streams finish
// within a bounded grace period (FR-023, FR-053, Clarification 22,
// SC-016).
//
// Honest scope boundary (Constitution §11.4.223 provenance markers): this
// file implements DETECTION + the drain STATE MACHINE only - ✅
// IMPLEMENTED. The actual HTTP-request-refusal and in-flight-stream
// tracking that CONSULTS Draining()/GraceExpired() is an internal/api
// concern (T058) - 📋 PLANNED, not yet built. Raft's own quorum protocol
// (hashicorp/raft demoting a leader that loses contact with quorum,
// FR-023's "Raft quorum prevents split-brain") is what actually prevents
// split-brain; PartitionWatcher only decides WHEN this node should start
// refusing new work, it does not itself implement quorum.
package cluster

import (
	"sync"
	"time"
)

// IsLeaderFunc reports whether this node is currently the Raft leader.
// A leader is, by construction, in contact with a live quorum -
// hashicorp/raft demotes a leader to follower the moment it loses that
// contact - so "is leader" alone is sufficient proof this node is not
// partitioned; PartitionWatcher never needs to second-guess it.
type IsLeaderFunc func() bool

// LastContactFunc returns the time this node (as a follower) last heard
// from a leader. Defined as a function type (not a direct dependency on
// *raft.Node) because internal/cluster cannot import internal/raft
// without creating an import cycle - internal/raft already imports
// internal/cluster via fsm.go - matching the same constraint documented
// in lock.go and health.go's StatusChecker/Rescheduler.
type LastContactFunc func() time.Time

// PartitionWatcher detects when this node can no longer reach a
// functioning Raft leader (the practical, testable proxy for "this node
// is in a minority partition") and exposes a Draining/GraceExpired state
// machine.
type PartitionWatcher struct {
	mu            sync.Mutex
	isLeader      IsLeaderFunc
	lastContact   LastContactFunc
	staleAfter    time.Duration
	graceDuration time.Duration

	draining     bool
	drainStarted time.Time
}

// NewPartitionWatcher constructs a PartitionWatcher. staleAfter is how
// long without leader contact before a follower is considered
// partitioned; graceDuration is Clarification 22's ~30s in-flight-stream
// grace period, measured from the moment draining begins.
func NewPartitionWatcher(isLeader IsLeaderFunc, lastContact LastContactFunc, staleAfter, graceDuration time.Duration) *PartitionWatcher {
	return &PartitionWatcher{
		isLeader:      isLeader,
		lastContact:   lastContact,
		staleAfter:    staleAfter,
		graceDuration: graceDuration,
	}
}

// Check re-evaluates quorum contact now, updating the drain state.
// Callers run this on the same kind of periodic loop as Monitor.CheckOnce
// (a future wiring point may share one ticker across both).
func (w *PartitionWatcher) Check() {
	w.mu.Lock()
	defer w.mu.Unlock()

	partitioned := !w.isLeader() && time.Since(w.lastContact()) > w.staleAfter

	switch {
	case partitioned && !w.draining:
		w.draining = true
		w.drainStarted = time.Now()
	case !partitioned && w.draining:
		w.draining = false
	}
}

// Draining reports whether this node is currently refusing new requests
// due to a detected partition (Clarification 22: new requests refused
// immediately once draining begins).
func (w *PartitionWatcher) Draining() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.draining
}

// GraceExpired reports whether the bounded grace period has elapsed since
// draining began. False whenever the node is not currently draining -
// grace has no meaning outside a drain episode.
func (w *PartitionWatcher) GraceExpired() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	if !w.draining {
		return false
	}
	return time.Since(w.drainStarted) >= w.graceDuration
}
