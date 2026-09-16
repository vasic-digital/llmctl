// Package raft (fsm_ca_rotation_test.go): TDD RED-then-GREEN unit tests
// for Feature 004 Phase 5 (User Story 3)'s new FSM commands -
// CommandBeginCARotation, CommandFinalizeCARotation, and
// CommandRecordCARotationTransition - matching the existing
// per-command-class test-file convention (fsm_lock_test.go) and the
// exact mustCommand/hraft.Log-driven Apply-testing pattern
// fsm_test.go/fsm_lock_test.go already establish. Unlike
// CommandRevokeCertificate (T010/T011), which is exercised only via
// test/integration/mtls_rotation_test.go's real multi-process tests,
// these three commands' Apply-level edge cases (idempotent begin,
// conflicting begin refused, finalize/transition requiring an
// in-progress rotation, fingerprint-mismatch refusal) are cheap and fast
// to prove at the unit level - real multi-process coverage for the
// end-to-end behavior these commands enable still lives in
// mtls_rotation_test.go's T018-T021.
package raft

import (
	"sync"
	"testing"
	"time"

	hraft "github.com/hashicorp/raft"

	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
)

// TestApply_BeginCARotation_StartsInProgress proves a fresh
// CommandBeginCARotation populates ClusterState.CARotation with the
// exact fingerprints/timestamp the proposer carried in the log entry
// (never recomputed by Apply - the same determinism discipline every
// other timestamp-carrying command in this file already follows).
func TestApply_BeginCARotation_StartsInProgress(t *testing.T) {
	fsm := NewClusterFSM()
	begunAt := time.Unix(1000, 0)
	rec := cluster.CARotationEvent{
		OutgoingCAFingerprint: "fp-old",
		IncomingCAFingerprint: "fp-new",
		Status:                "in_progress",
		BegunAt:               begunAt,
	}
	data := mustCommand(t, Command{Type: CommandBeginCARotation, CARotation: &rec})
	if resp := fsm.Apply(&hraft.Log{Data: data}); resp != nil {
		t.Fatalf("apply begin_ca_rotation: unexpected error %v", resp)
	}

	got := fsm.State().CARotation
	if got == nil {
		t.Fatalf("CARotation is nil after CommandBeginCARotation")
	}
	if got.Status != "in_progress" || got.OutgoingCAFingerprint != "fp-old" || got.IncomingCAFingerprint != "fp-new" {
		t.Fatalf("CARotation = %+v, want in_progress/fp-old/fp-new", got)
	}
	if !got.BegunAt.Equal(begunAt) {
		t.Fatalf("BegunAt = %v, want the proposer-carried value %v (never recomputed by Apply)", got.BegunAt, begunAt)
	}
}

// TestApply_BeginCARotation_MissingRecordRejected mirrors
// CommandAssignReplicationRole's errCommandMissingReplicationRole
// precedent: a malformed command carrying no CARotation payload must be
// rejected, never silently ignored.
func TestApply_BeginCARotation_MissingRecordRejected(t *testing.T) {
	fsm := NewClusterFSM()
	data := mustCommand(t, Command{Type: CommandBeginCARotation})
	if resp := fsm.Apply(&hraft.Log{Data: data}); resp == nil {
		t.Fatalf("apply begin_ca_rotation with no CARotation payload: want an error, got nil")
	}
}

// TestApply_BeginCARotation_IdempotentOnMatchingFingerprints proves a
// SECOND CommandBeginCARotation carrying the IDENTICAL outgoing/incoming
// fingerprints as an already-in-progress rotation is a harmless no-op -
// the mechanism that lets EVERY node in the cluster call its own local
// "begin rotation" API action (each one loading the incoming CA's actual
// material out-of-band, per data-model.md's security note) without the
// second-and-later callers' own Raft submission being treated as a
// conflict.
func TestApply_BeginCARotation_IdempotentOnMatchingFingerprints(t *testing.T) {
	fsm := NewClusterFSM()
	rec := cluster.CARotationEvent{OutgoingCAFingerprint: "fp-old", IncomingCAFingerprint: "fp-new", Status: "in_progress", BegunAt: time.Unix(1000, 0)}
	data := mustCommand(t, Command{Type: CommandBeginCARotation, CARotation: &rec})
	if resp := fsm.Apply(&hraft.Log{Data: data}); resp != nil {
		t.Fatalf("first apply: unexpected error %v", resp)
	}

	// A second, IDENTICAL begin (as a different node's own local call
	// would submit) must succeed silently.
	rec2 := cluster.CARotationEvent{OutgoingCAFingerprint: "fp-old", IncomingCAFingerprint: "fp-new", Status: "in_progress", BegunAt: time.Unix(2000, 0)}
	data2 := mustCommand(t, Command{Type: CommandBeginCARotation, CARotation: &rec2})
	if resp := fsm.Apply(&hraft.Log{Data: data2}); resp != nil {
		t.Fatalf("second, matching-fingerprint apply: want idempotent success, got error %v", resp)
	}

	// The FIRST BegunAt must be preserved - a later idempotent call must
	// never silently rewrite the canonical record's timestamp.
	got := fsm.State().CARotation
	if !got.BegunAt.Equal(time.Unix(1000, 0)) {
		t.Fatalf("BegunAt = %v after an idempotent second begin, want the FIRST call's timestamp %v preserved", got.BegunAt, time.Unix(1000, 0))
	}
}

// TestApply_BeginCARotation_ConflictingRotationRejected proves a SECOND
// CommandBeginCARotation naming DIFFERENT fingerprints while a rotation
// is already in_progress is refused - a genuine safety conflict, never
// silently overwritten (which would strand nodes that already loaded the
// FIRST incoming CA's material).
func TestApply_BeginCARotation_ConflictingRotationRejected(t *testing.T) {
	fsm := NewClusterFSM()
	rec := cluster.CARotationEvent{OutgoingCAFingerprint: "fp-old", IncomingCAFingerprint: "fp-new", Status: "in_progress", BegunAt: time.Unix(1000, 0)}
	data := mustCommand(t, Command{Type: CommandBeginCARotation, CARotation: &rec})
	if resp := fsm.Apply(&hraft.Log{Data: data}); resp != nil {
		t.Fatalf("first apply: unexpected error %v", resp)
	}

	conflicting := cluster.CARotationEvent{OutgoingCAFingerprint: "fp-old", IncomingCAFingerprint: "fp-DIFFERENT", Status: "in_progress", BegunAt: time.Unix(2000, 0)}
	data2 := mustCommand(t, Command{Type: CommandBeginCARotation, CARotation: &conflicting})
	if resp := fsm.Apply(&hraft.Log{Data: data2}); resp == nil {
		t.Fatalf("conflicting begin (different incoming fingerprint while one is already in_progress): want an error, got nil")
	}

	// The ORIGINAL rotation must be untouched by the rejected conflict.
	got := fsm.State().CARotation
	if got.IncomingCAFingerprint != "fp-new" {
		t.Fatalf("a rejected conflicting begin must not mutate the existing rotation: IncomingCAFingerprint = %q, want fp-new", got.IncomingCAFingerprint)
	}
}

// TestApply_BeginCARotation_AllowedAfterPriorFinalize proves a NEW
// rotation may legitimately begin once the previous one finalized (CA
// rotation is not a one-time-only capability).
func TestApply_BeginCARotation_AllowedAfterPriorFinalize(t *testing.T) {
	fsm := NewClusterFSM()
	first := cluster.CARotationEvent{OutgoingCAFingerprint: "fp-1", IncomingCAFingerprint: "fp-2", Status: "in_progress", BegunAt: time.Unix(1000, 0)}
	if resp := fsm.Apply(&hraft.Log{Data: mustCommand(t, Command{Type: CommandBeginCARotation, CARotation: &first})}); resp != nil {
		t.Fatalf("begin first rotation: %v", resp)
	}
	finalizeFirst := cluster.CARotationEvent{OutgoingCAFingerprint: "fp-1", IncomingCAFingerprint: "fp-2", Status: "finalized", FinalizedAt: time.Unix(1500, 0)}
	if resp := fsm.Apply(&hraft.Log{Data: mustCommand(t, Command{Type: CommandFinalizeCARotation, CARotation: &finalizeFirst})}); resp != nil {
		t.Fatalf("finalize first rotation: %v", resp)
	}

	second := cluster.CARotationEvent{OutgoingCAFingerprint: "fp-2", IncomingCAFingerprint: "fp-3", Status: "in_progress", BegunAt: time.Unix(2000, 0)}
	if resp := fsm.Apply(&hraft.Log{Data: mustCommand(t, Command{Type: CommandBeginCARotation, CARotation: &second})}); resp != nil {
		t.Fatalf("begin second rotation after prior finalize: want success, got %v", resp)
	}
	got := fsm.State().CARotation
	if got.Status != "in_progress" || got.IncomingCAFingerprint != "fp-3" {
		t.Fatalf("second rotation = %+v, want in_progress/fp-3", got)
	}
}

// TestApply_FinalizeCARotation_RequiresInProgress proves finalize is
// refused when no rotation is currently in_progress (never begun, or
// already finalized) - spec.md FR-009's "explicit finalization" cannot
// finalize nothing.
func TestApply_FinalizeCARotation_RequiresInProgress(t *testing.T) {
	fsm := NewClusterFSM()
	rec := cluster.CARotationEvent{OutgoingCAFingerprint: "fp-old", IncomingCAFingerprint: "fp-new", Status: "finalized", FinalizedAt: time.Unix(1000, 0)}
	data := mustCommand(t, Command{Type: CommandFinalizeCARotation, CARotation: &rec})
	if resp := fsm.Apply(&hraft.Log{Data: data}); resp == nil {
		t.Fatalf("finalize with no rotation ever begun: want an error, got nil")
	}
}

// TestApply_FinalizeCARotation_FingerprintMismatchRejected proves a
// finalize command naming fingerprints that do NOT match the currently
// in-progress rotation is refused - guards against a stale/racing
// finalize request finalizing the WRONG rotation.
func TestApply_FinalizeCARotation_FingerprintMismatchRejected(t *testing.T) {
	fsm := NewClusterFSM()
	begin := cluster.CARotationEvent{OutgoingCAFingerprint: "fp-old", IncomingCAFingerprint: "fp-new", Status: "in_progress", BegunAt: time.Unix(1000, 0)}
	if resp := fsm.Apply(&hraft.Log{Data: mustCommand(t, Command{Type: CommandBeginCARotation, CARotation: &begin})}); resp != nil {
		t.Fatalf("begin: %v", resp)
	}

	mismatched := cluster.CARotationEvent{OutgoingCAFingerprint: "fp-old", IncomingCAFingerprint: "fp-STALE", Status: "finalized", FinalizedAt: time.Unix(2000, 0)}
	data := mustCommand(t, Command{Type: CommandFinalizeCARotation, CARotation: &mismatched})
	if resp := fsm.Apply(&hraft.Log{Data: data}); resp == nil {
		t.Fatalf("finalize with mismatched fingerprints: want an error, got nil")
	}
	got := fsm.State().CARotation
	if got.Status != "in_progress" {
		t.Fatalf("a rejected mismatched finalize must not mutate the existing rotation: Status = %q, want in_progress", got.Status)
	}
}

// TestApply_FinalizeCARotation_Succeeds proves a matching finalize
// transitions Status to "finalized", preserving TransitionedNodeIDs and
// setting FinalizedAt to the proposer-carried value.
func TestApply_FinalizeCARotation_Succeeds(t *testing.T) {
	fsm := NewClusterFSM()
	begin := cluster.CARotationEvent{OutgoingCAFingerprint: "fp-old", IncomingCAFingerprint: "fp-new", Status: "in_progress", BegunAt: time.Unix(1000, 0)}
	if resp := fsm.Apply(&hraft.Log{Data: mustCommand(t, Command{Type: CommandBeginCARotation, CARotation: &begin})}); resp != nil {
		t.Fatalf("begin: %v", resp)
	}
	if resp := fsm.Apply(&hraft.Log{Data: mustCommand(t, Command{Type: CommandRecordCARotationTransition, NodeID: "node-a"})}); resp != nil {
		t.Fatalf("record transition: %v", resp)
	}

	finalizedAt := time.Unix(3000, 0)
	finalize := cluster.CARotationEvent{OutgoingCAFingerprint: "fp-old", IncomingCAFingerprint: "fp-new", Status: "finalized", FinalizedAt: finalizedAt}
	if resp := fsm.Apply(&hraft.Log{Data: mustCommand(t, Command{Type: CommandFinalizeCARotation, CARotation: &finalize})}); resp != nil {
		t.Fatalf("finalize: unexpected error %v", resp)
	}

	got := fsm.State().CARotation
	if got.Status != "finalized" {
		t.Fatalf("Status = %q, want finalized", got.Status)
	}
	if !got.FinalizedAt.Equal(finalizedAt) {
		t.Fatalf("FinalizedAt = %v, want the proposer-carried value %v", got.FinalizedAt, finalizedAt)
	}
	if len(got.TransitionedNodeIDs) != 1 || got.TransitionedNodeIDs[0] != "node-a" {
		t.Fatalf("TransitionedNodeIDs = %v, want [node-a] preserved across finalize", got.TransitionedNodeIDs)
	}
}

// TestApply_RecordCARotationTransition_AppendsIdempotently proves the
// transition-tracking command adds a node exactly once, even if applied
// twice for the same node (a retried renewal reporting the same
// transition again must never duplicate the entry).
func TestApply_RecordCARotationTransition_AppendsIdempotently(t *testing.T) {
	fsm := NewClusterFSM()
	begin := cluster.CARotationEvent{OutgoingCAFingerprint: "fp-old", IncomingCAFingerprint: "fp-new", Status: "in_progress", BegunAt: time.Unix(1000, 0)}
	if resp := fsm.Apply(&hraft.Log{Data: mustCommand(t, Command{Type: CommandBeginCARotation, CARotation: &begin})}); resp != nil {
		t.Fatalf("begin: %v", resp)
	}

	for i := 0; i < 2; i++ {
		if resp := fsm.Apply(&hraft.Log{Data: mustCommand(t, Command{Type: CommandRecordCARotationTransition, NodeID: "node-a"})}); resp != nil {
			t.Fatalf("record transition (iteration %d): %v", i, resp)
		}
	}
	if resp := fsm.Apply(&hraft.Log{Data: mustCommand(t, Command{Type: CommandRecordCARotationTransition, NodeID: "node-b"})}); resp != nil {
		t.Fatalf("record transition for node-b: %v", resp)
	}

	got := fsm.State().CARotation.TransitionedNodeIDs
	if len(got) != 2 {
		t.Fatalf("TransitionedNodeIDs = %v, want exactly 2 entries (node-a once, node-b once)", got)
	}
}

// TestApply_RecordCARotationTransition_NoOpWhenNoneInProgress proves the
// transition command is a harmless no-op (never an error) when no
// rotation is currently in_progress - mirrors CommandReleaseLock's own
// idempotent-no-op-on-already-gone precedent (fsm.go): a renewal
// reporting a transition after the rotation already finalized, or one
// that was never begun, has nothing to record.
func TestApply_RecordCARotationTransition_NoOpWhenNoneInProgress(t *testing.T) {
	fsm := NewClusterFSM()
	if resp := fsm.Apply(&hraft.Log{Data: mustCommand(t, Command{Type: CommandRecordCARotationTransition, NodeID: "node-a"})}); resp != nil {
		t.Fatalf("record transition with no rotation ever begun: want nil (idempotent no-op), got %v", resp)
	}
	if got := fsm.State().CARotation; got != nil {
		t.Fatalf("CARotation must stay nil when no rotation was ever begun, got %+v", got)
	}
}

// TestApply_CARotation_NotifiesHandlerAfterUnlock proves
// CommandBeginCARotation/CommandFinalizeCARotation fire the SAME
// onRevocationApplied notify mechanism T011 wired for
// CommandRevokeCertificate (fsm.go's own doc comment: "forward-
// compatible with Phase 5's future CA-rotation event without a second
// handler mechanism") - and that the handler is invoked with f.mu
// already released (the exact self-deadlock T011's own doc comment
// documents finding and fixing): the handler below calls fsm.State(),
// which itself locks f.mu - if Apply still held the lock while invoking
// the handler, this test would hang forever rather than fail cleanly.
func TestApply_CARotation_NotifiesHandlerAfterUnlock(t *testing.T) {
	fsm := NewClusterFSM()
	var mu sync.Mutex
	fired := 0
	fsm.SetRevocationHandler(func() {
		mu.Lock()
		fired++
		mu.Unlock()
		// Reentrant call into the FSM from inside the handler - hangs
		// forever (rather than erroring) if f.mu is still held by Apply
		// at this point, exactly like the real
		// cmd/llmctld/main.go/wireRevocationHandler handler does.
		_ = fsm.State()
	})

	begin := cluster.CARotationEvent{OutgoingCAFingerprint: "fp-old", IncomingCAFingerprint: "fp-new", Status: "in_progress", BegunAt: time.Unix(1000, 0)}
	if resp := fsm.Apply(&hraft.Log{Data: mustCommand(t, Command{Type: CommandBeginCARotation, CARotation: &begin})}); resp != nil {
		t.Fatalf("begin: %v", resp)
	}

	finalize := cluster.CARotationEvent{OutgoingCAFingerprint: "fp-old", IncomingCAFingerprint: "fp-new", Status: "finalized", FinalizedAt: time.Unix(2000, 0)}
	if resp := fsm.Apply(&hraft.Log{Data: mustCommand(t, Command{Type: CommandFinalizeCARotation, CARotation: &finalize})}); resp != nil {
		t.Fatalf("finalize: %v", resp)
	}

	mu.Lock()
	got := fired
	mu.Unlock()
	if got != 2 {
		t.Fatalf("handler fired %d times, want 2 (once for begin, once for finalize)", got)
	}
}
