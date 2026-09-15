package cluster

import (
	"testing"
	"time"
)

// TestPartitionWatcher_LeaderNeverDrains proves a node that is currently
// the Raft leader never enters a drain state - hashicorp/raft's own
// quorum protocol would already have demoted it to follower the moment it
// genuinely lost quorum contact (FR-023: "Raft quorum prevents split-brain
// ... minority partition steps down"), so "is leader" is itself proof of
// live quorum contact.
func TestPartitionWatcher_LeaderNeverDrains(t *testing.T) {
	w := NewPartitionWatcher(
		func() bool { return true },                            // isLeader
		func() time.Time { return time.Now().Add(-time.Hour) }, // stale, but irrelevant while leader
		100*time.Millisecond, 30*time.Second,
	)
	w.Check()
	if w.Draining() {
		t.Fatalf("a leader must never be reported as draining")
	}
}

// TestPartitionWatcher_FollowerWithStaleContactDrains proves a follower
// that has not heard from a leader within staleAfter is treated as
// partitioned and begins draining (FR-023, SC-016: minority partition
// drains).
func TestPartitionWatcher_FollowerWithStaleContactDrains(t *testing.T) {
	w := NewPartitionWatcher(
		func() bool { return false },
		func() time.Time { return time.Now().Add(-time.Hour) }, // very stale
		100*time.Millisecond, 30*time.Second,
	)
	w.Check()
	if !w.Draining() {
		t.Fatalf("a follower with stale leader contact must be draining")
	}
}

// TestPartitionWatcher_FollowerWithFreshContactDoesNotDrain proves a
// follower that has heard from a leader recently is NOT considered
// partitioned - only staleness beyond the threshold triggers draining.
func TestPartitionWatcher_FollowerWithFreshContactDoesNotDrain(t *testing.T) {
	w := NewPartitionWatcher(
		func() bool { return false },
		func() time.Time { return time.Now() }, // fresh contact
		100*time.Millisecond, 30*time.Second,
	)
	w.Check()
	if w.Draining() {
		t.Fatalf("a follower with fresh leader contact must not be draining")
	}
}

// TestPartitionWatcher_RecoversWhenContactResumes proves draining clears
// once contact resumes - a healed partition must stop refusing requests,
// not remain stuck draining forever.
func TestPartitionWatcher_RecoversWhenContactResumes(t *testing.T) {
	lastContact := time.Now().Add(-time.Hour)
	w := NewPartitionWatcher(
		func() bool { return false },
		func() time.Time { return lastContact },
		100*time.Millisecond, 30*time.Second,
	)
	w.Check()
	if !w.Draining() {
		t.Fatalf("expected draining while contact is stale")
	}

	lastContact = time.Now() // contact resumes
	w.Check()
	if w.Draining() {
		t.Fatalf("expected draining to clear once leader contact resumed")
	}
}

// TestPartitionWatcher_GraceExpiresAfterDuration proves GraceExpired
// transitions from false to true once graceDuration has elapsed since
// draining began (Clarification 22: ~30s grace period for in-flight
// streams to finish before even those are cut off).
func TestPartitionWatcher_GraceExpiresAfterDuration(t *testing.T) {
	w := NewPartitionWatcher(
		func() bool { return false },
		func() time.Time { return time.Now().Add(-time.Hour) },
		100*time.Millisecond, 40*time.Millisecond,
	)
	w.Check()
	if !w.Draining() {
		t.Fatalf("expected draining immediately after Check() detects staleness")
	}
	if w.GraceExpired() {
		t.Fatalf("grace must not be expired immediately after draining begins")
	}

	time.Sleep(60 * time.Millisecond)
	if !w.GraceExpired() {
		t.Fatalf("expected grace to be expired after graceDuration has elapsed")
	}
}

// TestPartitionWatcher_GraceExpired_FalseWhenNotDraining proves
// GraceExpired never reports true for a node that isn't draining at all.
func TestPartitionWatcher_GraceExpired_FalseWhenNotDraining(t *testing.T) {
	w := NewPartitionWatcher(
		func() bool { return true },
		func() time.Time { return time.Now() },
		100*time.Millisecond, 30*time.Second,
	)
	w.Check()
	if w.GraceExpired() {
		t.Fatalf("GraceExpired must be false when the node is not draining")
	}
}
