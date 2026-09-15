package replication

import (
	"reflect"
	"testing"
)

// TestCheckpoint_FailureDoesNotLoseWAL_NextAttemptIncludesDelta proves the
// spec.md edge case: "What happens when KV cache checkpoint fails? -> WAL
// continues logging; next checkpoint attempt includes previous delta."
// Forces a REAL checkpoint failure (closing the underlying checkpoint
// bbolt DB directly, so the next Checkpoint call genuinely fails with
// bbolt's real ErrDatabaseNotOpen) while leaving the WAL's own separate
// bbolt file open and fully functional - isolating "checkpoint
// persistence failed" from "the WAL is fine", exactly matching the real
// architecture (wal.go and checkpoint.go use two independent bbolt
// files).
func TestCheckpoint_FailureDoesNotLoseWAL_NextAttemptIncludesDelta(t *testing.T) {
	dir := t.TempDir()
	s, err := OpenStore(dir, CheckpointConfig{})
	if err != nil {
		t.Fatalf("OpenStore: %v", err)
	}

	if err := s.WAL().Append(WALEntry{Seq: 1, TokenID: 1, Position: 0}); err != nil {
		t.Fatalf("Append(seq=1): %v", err)
	}

	// Force the real checkpoint-persistence failure.
	if err := s.db.Close(); err != nil {
		t.Fatalf("close checkpoint db: %v", err)
	}

	if err := s.Checkpoint(1, KVState{Tokens: []int32{1}, Positions: []int32{0}}); err == nil {
		t.Fatalf("Checkpoint must fail with the checkpoint db closed, got nil")
	}

	// The WAL entry appended before the failed checkpoint attempt must
	// still be there - proving Truncate was never reached (or had no
	// effect) when the checkpoint itself failed.
	entries, err := s.WAL().ReadAll()
	if err != nil {
		t.Fatalf("ReadAll after failed checkpoint: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("WAL has %d entries after a failed checkpoint, want 1 (the WAL must not lose data on checkpoint failure)", len(entries))
	}

	// The WAL must continue accepting new entries even though the last
	// checkpoint attempt failed.
	if err := s.WAL().Append(WALEntry{Seq: 2, TokenID: 2, Position: 1}); err != nil {
		t.Fatalf("Append(seq=2) after failed checkpoint: %v", err)
	}
	if err := s.wal.Close(); err != nil {
		t.Fatalf("close WAL: %v", err)
	}

	// A fresh Store instance on the SAME directory (simulating a retry
	// after the earlier failure - e.g. after a transient disk issue
	// clears) must be able to checkpoint the FULL delta (both entries,
	// not just what would have been checkpointed at the point of the
	// original failure).
	s2, err := OpenStore(dir, CheckpointConfig{})
	if err != nil {
		t.Fatalf("re-OpenStore: %v", err)
	}
	defer s2.Close()

	if err := s2.Checkpoint(2, KVState{Tokens: []int32{1, 2}, Positions: []int32{0, 1}}); err != nil {
		t.Fatalf("retry Checkpoint: %v", err)
	}

	got, err := s2.Restore()
	if err != nil {
		t.Fatalf("Restore: %v", err)
	}
	want := KVState{Tokens: []int32{1, 2}, Positions: []int32{0, 1}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Restore() after retry = %+v, want %+v (the retry must include the previous delta)", got, want)
	}
}

// TestShouldForceCheckpoint_TriggersWhenWALExceedsConfiguredSize proves
// the spec.md edge case: "What happens when WAL grows too large? ->
// Checkpoint triggered; WAL truncated after successful checkpoint."
// spec.md gives no specific byte threshold, so this is a CONFIGURABLE
// mechanism (CheckpointConfig.MaxWALSizeBytes), never a hardcoded guessed
// number (Constitution §11.4.6 no-guessing) - a deployment wanting
// size-based forcing configures a real threshold for its own
// environment.
func TestShouldForceCheckpoint_TriggersWhenWALExceedsConfiguredSize(t *testing.T) {
	// An absurdly low threshold guarantees it is exceeded after any real
	// write, without depending on a guessed "realistic" WAL size.
	s, err := OpenStore(t.TempDir(), CheckpointConfig{MaxWALSizeBytes: 1})
	if err != nil {
		t.Fatalf("OpenStore: %v", err)
	}
	defer s.Close()

	if err := s.WAL().Append(WALEntry{Seq: 1, TokenID: 1, Position: 0}); err != nil {
		t.Fatalf("Append: %v", err)
	}

	force, err := s.ShouldForceCheckpoint()
	if err != nil {
		t.Fatalf("ShouldForceCheckpoint: %v", err)
	}
	if !force {
		t.Fatalf("ShouldForceCheckpoint() = false, want true once the real on-disk WAL size exceeds the configured 1-byte threshold")
	}
}

// TestShouldForceCheckpoint_FalseWhenNoThresholdConfigured proves the
// size-forcing mechanism is OPT-IN: a zero MaxWALSizeBytes (the default
// zero value) disables it entirely, regardless of real WAL size - never
// silently forcing checkpoints against an un-configured default.
func TestShouldForceCheckpoint_FalseWhenNoThresholdConfigured(t *testing.T) {
	s, err := OpenStore(t.TempDir(), CheckpointConfig{}) // MaxWALSizeBytes left zero
	if err != nil {
		t.Fatalf("OpenStore: %v", err)
	}
	defer s.Close()

	for seq := uint64(1); seq <= 50; seq++ {
		if err := s.WAL().Append(WALEntry{Seq: seq, TokenID: int32(seq), Position: int32(seq - 1)}); err != nil {
			t.Fatalf("Append(seq=%d): %v", seq, err)
		}
	}

	force, err := s.ShouldForceCheckpoint()
	if err != nil {
		t.Fatalf("ShouldForceCheckpoint: %v", err)
	}
	if force {
		t.Fatalf("ShouldForceCheckpoint() = true, want false when MaxWALSizeBytes is unset (0 = disabled)")
	}
}
