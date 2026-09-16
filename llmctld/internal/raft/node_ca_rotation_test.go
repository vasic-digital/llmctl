// Package raft (node_ca_rotation_test.go): TDD RED-then-GREEN tests for
// Feature 004 Phase 5's Node.BeginCARotation/FinalizeCARotation/
// RecordCARotationTransition (T022) - a real single-node Raft instance
// (this package's own established in-process test style, distinct from
// test/integration's real-multi-OS-process style used for the full
// end-to-end T018-T021 scenarios), matching TestBootstrap_
// SingleNodeBecomesLeaderQuickly's exact construction pattern.
package raft

import (
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
)

func bootstrapSingleNode(t *testing.T, nodeID string) *Node {
	t.Helper()
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}
	node, err := Bootstrap(Config{
		NodeID:    nodeID,
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildNodeTLSConfig(t, ca, nodeID),
	})
	if err != nil {
		t.Fatalf("Bootstrap: %v", err)
	}
	t.Cleanup(func() { _ = node.Shutdown() })
	waitForLeader(t, node, 3*time.Second)
	return node
}

// TestBeginCARotation_AppliesRealLogEntry proves a real Raft Apply of
// CommandBeginCARotation lands in node.State().CARotation - not merely
// that fsm.go's Apply switch case compiles.
func TestBeginCARotation_AppliesRealLogEntry(t *testing.T) {
	node := bootstrapSingleNode(t, "node-a")

	if err := node.BeginCARotation(cluster.CARotationEvent{
		OutgoingCAFingerprint: "fp-old",
		IncomingCAFingerprint: "fp-new",
		Status:                "in_progress",
		BegunAt:               time.Now(),
	}); err != nil {
		t.Fatalf("BeginCARotation: %v", err)
	}

	got := node.State().CARotation
	if got == nil || got.Status != "in_progress" || got.IncomingCAFingerprint != "fp-new" {
		t.Fatalf("State().CARotation = %+v, want in_progress/fp-new", got)
	}
}

// TestFinalizeCARotation_RefusedWithoutMatchingBegin proves
// FinalizeCARotation genuinely propagates the FSM's real refusal (not a
// client-side check) when no matching rotation is in progress.
func TestFinalizeCARotation_RefusedWithoutMatchingBegin(t *testing.T) {
	node := bootstrapSingleNode(t, "node-a")

	err := node.FinalizeCARotation(cluster.CARotationEvent{
		OutgoingCAFingerprint: "fp-old",
		IncomingCAFingerprint: "fp-new",
		Status:                "finalized",
		FinalizedAt:           time.Now(),
	})
	if err == nil {
		t.Fatalf("FinalizeCARotation with no rotation in progress: want an error, got nil")
	}
}

// TestFinalizeCARotation_Succeeds proves a real begin-then-finalize cycle
// flips node.State().CARotation.Status to "finalized" via two real,
// separately-applied Raft log entries.
func TestFinalizeCARotation_Succeeds(t *testing.T) {
	node := bootstrapSingleNode(t, "node-a")

	if err := node.BeginCARotation(cluster.CARotationEvent{
		OutgoingCAFingerprint: "fp-old", IncomingCAFingerprint: "fp-new", Status: "in_progress", BegunAt: time.Now(),
	}); err != nil {
		t.Fatalf("BeginCARotation: %v", err)
	}
	if err := node.FinalizeCARotation(cluster.CARotationEvent{
		OutgoingCAFingerprint: "fp-old", IncomingCAFingerprint: "fp-new", Status: "finalized", FinalizedAt: time.Now(),
	}); err != nil {
		t.Fatalf("FinalizeCARotation: %v", err)
	}

	got := node.State().CARotation
	if got == nil || got.Status != "finalized" {
		t.Fatalf("State().CARotation = %+v, want finalized", got)
	}
}

// TestRecordCARotationTransition_AppliesRealLogEntry proves a real Raft
// Apply of CommandRecordCARotationTransition genuinely grows
// TransitionedNodeIDs.
func TestRecordCARotationTransition_AppliesRealLogEntry(t *testing.T) {
	node := bootstrapSingleNode(t, "node-a")

	if err := node.BeginCARotation(cluster.CARotationEvent{
		OutgoingCAFingerprint: "fp-old", IncomingCAFingerprint: "fp-new", Status: "in_progress", BegunAt: time.Now(),
	}); err != nil {
		t.Fatalf("BeginCARotation: %v", err)
	}
	if err := node.RecordCARotationTransition("node-a"); err != nil {
		t.Fatalf("RecordCARotationTransition: %v", err)
	}

	got := node.State().CARotation
	if got == nil || len(got.TransitionedNodeIDs) != 1 || got.TransitionedNodeIDs[0] != "node-a" {
		t.Fatalf("State().CARotation.TransitionedNodeIDs = %+v, want [node-a]", got)
	}
}

// TestSetRevocationHandler_FiresOnCARotationCommands proves the SAME
// SetRevocationHandler mechanism T011 wired for revocation ALSO fires
// through a real Node (not merely the bare ClusterFSM unit test in
// fsm_ca_rotation_test.go) for CommandBeginCARotation/
// CommandFinalizeCARotation - the exact wiring
// cmd/llmctld/main.go's wireRevocationHandler depends on in production.
func TestSetRevocationHandler_FiresOnCARotationCommands(t *testing.T) {
	node := bootstrapSingleNode(t, "node-a")

	fired := make(chan struct{}, 8)
	node.SetRevocationHandler(func() { fired <- struct{}{} })

	if err := node.BeginCARotation(cluster.CARotationEvent{
		OutgoingCAFingerprint: "fp-old", IncomingCAFingerprint: "fp-new", Status: "in_progress", BegunAt: time.Now(),
	}); err != nil {
		t.Fatalf("BeginCARotation: %v", err)
	}
	select {
	case <-fired:
	case <-time.After(2 * time.Second):
		t.Fatalf("revocation handler never fired after BeginCARotation")
	}

	if err := node.FinalizeCARotation(cluster.CARotationEvent{
		OutgoingCAFingerprint: "fp-old", IncomingCAFingerprint: "fp-new", Status: "finalized", FinalizedAt: time.Now(),
	}); err != nil {
		t.Fatalf("FinalizeCARotation: %v", err)
	}
	select {
	case <-fired:
	case <-time.After(2 * time.Second):
		t.Fatalf("revocation handler never fired after FinalizeCARotation")
	}
}
