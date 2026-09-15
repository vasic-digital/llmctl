package replication

import (
	"reflect"
	"testing"
	"time"
)

func openTestStore(t *testing.T, cfg CheckpointConfig) *Store {
	t.Helper()
	s, err := OpenStore(t.TempDir(), cfg)
	if err != nil {
		t.Fatalf("OpenStore: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

// TestShouldCheckpoint_TriggersOnTokenIntervalOrTimeInterval proves the
// N-tokens-OR-T-seconds policy (FR-026, SC-020) and that both N and T are
// read from CheckpointConfig, never hardcoded - a config with different
// values genuinely changes the trigger point.
func TestShouldCheckpoint_TriggersOnTokenIntervalOrTimeInterval(t *testing.T) {
	cfg := CheckpointConfig{IntervalTokens: 100, IntervalTime: 5 * time.Second}

	if cfg.ShouldCheckpoint(50, 1*time.Second) {
		t.Fatalf("ShouldCheckpoint(50 tokens, 1s) with N=100/T=5s must be false")
	}
	if !cfg.ShouldCheckpoint(100, 1*time.Second) {
		t.Fatalf("ShouldCheckpoint(100 tokens, 1s) with N=100/T=5s must be true (token interval reached)")
	}
	if !cfg.ShouldCheckpoint(10, 5*time.Second) {
		t.Fatalf("ShouldCheckpoint(10 tokens, 5s) with N=100/T=5s must be true (time interval reached)")
	}

	// A DIFFERENT config genuinely changes the trigger point - proves N/T
	// are read from config, not hardcoded constants.
	looser := CheckpointConfig{IntervalTokens: 1000, IntervalTime: 30 * time.Second}
	if looser.ShouldCheckpoint(100, 1*time.Second) {
		t.Fatalf("ShouldCheckpoint(100 tokens, 1s) with N=1000/T=30s must be false")
	}
}

// TestShouldCheckpoint_DefaultsWhenZero proves an unset CheckpointConfig
// falls back to FR-026's documented defaults (N=1000, T=30s) rather than
// panicking or checkpointing on every call.
func TestShouldCheckpoint_DefaultsWhenZero(t *testing.T) {
	var cfg CheckpointConfig // zero value

	if cfg.ShouldCheckpoint(999, 29*time.Second) {
		t.Fatalf("zero-value config must default to N=1000/T=30s and NOT trigger at 999 tokens/29s")
	}
	if !cfg.ShouldCheckpoint(1000, 0) {
		t.Fatalf("zero-value config must default to N=1000 and trigger at exactly 1000 tokens")
	}
	if !cfg.ShouldCheckpoint(0, 30*time.Second) {
		t.Fatalf("zero-value config must default to T=30s and trigger at exactly 30s")
	}
}

// TestCheckpointThenRestore_ReconstructsKVState proves Restore()
// reconstructs the same KVState that was Checkpoint()ed, when there are
// no further WAL entries beyond the checkpoint.
func TestCheckpointThenRestore_ReconstructsKVState(t *testing.T) {
	s := openTestStore(t, CheckpointConfig{})

	state := KVState{Tokens: []int32{10, 11, 12}, Positions: []int32{0, 1, 2}}
	if err := s.Checkpoint(3, state); err != nil {
		t.Fatalf("Checkpoint: %v", err)
	}

	got, err := s.Restore()
	if err != nil {
		t.Fatalf("Restore: %v", err)
	}
	if !reflect.DeepEqual(got, state) {
		t.Fatalf("Restore() = %+v, want %+v", got, state)
	}
}

// TestRestore_ReplaysWALEntriesAfterCheckpoint proves the real failover
// path (FR-028): a checkpoint plus WAL entries logged AFTER it must
// reconstruct the FULL up-to-date state, not just the checkpointed
// prefix - the whole reason a WAL exists alongside checkpoints.
func TestRestore_ReplaysWALEntriesAfterCheckpoint(t *testing.T) {
	s := openTestStore(t, CheckpointConfig{})

	checkpointState := KVState{Tokens: []int32{10, 11}, Positions: []int32{0, 1}}
	if err := s.Checkpoint(2, checkpointState); err != nil {
		t.Fatalf("Checkpoint: %v", err)
	}

	// Tokens appended to the WAL AFTER the checkpoint (seq 3, 4) - not yet
	// incorporated into any checkpoint.
	if err := s.WAL().Append(WALEntry{Seq: 3, TokenID: 12, Position: 2}); err != nil {
		t.Fatalf("Append(seq=3): %v", err)
	}
	if err := s.WAL().Append(WALEntry{Seq: 4, TokenID: 13, Position: 3}); err != nil {
		t.Fatalf("Append(seq=4): %v", err)
	}

	got, err := s.Restore()
	if err != nil {
		t.Fatalf("Restore: %v", err)
	}
	want := KVState{Tokens: []int32{10, 11, 12, 13}, Positions: []int32{0, 1, 2, 3}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Restore() = %+v, want %+v", got, want)
	}
}

// TestRestore_IsDeterministic proves replaying the SAME WAL sequence
// twice (from a fresh Store loading the same on-disk files) yields
// byte-identical KVState - required because a real failover scenario
// restores independently on a different node from the same replicated
// checkpoint+WAL data and MUST reconstruct identical state (SC-020: "WAL
// replay deterministic").
func TestRestore_IsDeterministic(t *testing.T) {
	dir := t.TempDir()
	s1, err := OpenStore(dir, CheckpointConfig{})
	if err != nil {
		t.Fatalf("OpenStore: %v", err)
	}

	if err := s1.Checkpoint(1, KVState{Tokens: []int32{1}, Positions: []int32{0}}); err != nil {
		t.Fatalf("Checkpoint: %v", err)
	}
	if err := s1.WAL().Append(WALEntry{Seq: 2, TokenID: 2, Position: 1}); err != nil {
		t.Fatalf("Append: %v", err)
	}
	if err := s1.WAL().Append(WALEntry{Seq: 3, TokenID: 3, Position: 2}); err != nil {
		t.Fatalf("Append: %v", err)
	}

	first, err := s1.Restore()
	if err != nil {
		t.Fatalf("first Restore: %v", err)
	}
	if err := s1.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	// A FRESH Store instance, opening the SAME on-disk files (simulating
	// a different node restoring from replicated data) - not a second
	// call to the same in-memory object.
	s2, err := OpenStore(dir, CheckpointConfig{})
	if err != nil {
		t.Fatalf("re-OpenStore: %v", err)
	}
	defer func() { _ = s2.Close() }()

	second, err := s2.Restore()
	if err != nil {
		t.Fatalf("second Restore: %v", err)
	}

	if !reflect.DeepEqual(first, second) {
		t.Fatalf("Restore() is not deterministic across a fresh Store instance: first=%+v, second=%+v", first, second)
	}
}

// TestCheckpoint_TruncatesWALUpToCheckpointSeq proves a successful
// Checkpoint call bounds WAL growth by truncating entries it has already
// incorporated (spec.md's WAL-too-large edge case, T063's mechanism).
func TestCheckpoint_TruncatesWALUpToCheckpointSeq(t *testing.T) {
	s := openTestStore(t, CheckpointConfig{})

	for seq := uint64(1); seq <= 3; seq++ {
		if err := s.WAL().Append(WALEntry{Seq: seq, TokenID: int32(seq), Position: int32(seq - 1)}); err != nil {
			t.Fatalf("Append(seq=%d): %v", seq, err)
		}
	}

	if err := s.Checkpoint(3, KVState{Tokens: []int32{1, 2, 3}, Positions: []int32{0, 1, 2}}); err != nil {
		t.Fatalf("Checkpoint: %v", err)
	}

	remaining, err := s.WAL().ReadAll()
	if err != nil {
		t.Fatalf("ReadAll: %v", err)
	}
	if len(remaining) != 0 {
		t.Fatalf("WAL has %d entries after Checkpoint(3) truncation, want 0 (all incorporated)", len(remaining))
	}
}

// TestRestore_OnFreshStoreWithNoCheckpointReturnsEmptyState proves
// Restore on a brand-new Store (no checkpoint ever taken, no WAL
// entries) returns a genuinely empty KVState rather than an error or a
// nil-vs-zero-value ambiguity.
func TestRestore_OnFreshStoreWithNoCheckpointReturnsEmptyState(t *testing.T) {
	s := openTestStore(t, CheckpointConfig{})
	got, err := s.Restore()
	if err != nil {
		t.Fatalf("Restore: %v", err)
	}
	if len(got.Tokens) != 0 || len(got.Positions) != 0 {
		t.Fatalf("Restore() on a fresh Store = %+v, want empty KVState", got)
	}
}
