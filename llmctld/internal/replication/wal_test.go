package replication

import (
	"path/filepath"
	"testing"
)

func openTestWAL(t *testing.T) *WAL {
	t.Helper()
	path := filepath.Join(t.TempDir(), "wal.db")
	w, err := OpenWAL(path)
	if err != nil {
		t.Fatalf("OpenWAL: %v", err)
	}
	t.Cleanup(func() { w.Close() })
	return w
}

// TestAppend_ThenReadBack proves entries appended to a real bbolt-backed
// WAL are genuinely persisted and read back in the exact order they were
// appended, with byte-identical payloads.
func TestAppend_ThenReadBack(t *testing.T) {
	w := openTestWAL(t)

	entries := []WALEntry{
		{Seq: 1, TokenID: 101, Position: 0},
		{Seq: 2, TokenID: 102, Position: 1},
		{Seq: 3, TokenID: 103, Position: 2},
	}
	for _, e := range entries {
		if err := w.Append(e); err != nil {
			t.Fatalf("Append(%+v): %v", e, err)
		}
	}

	got, err := w.ReadAll()
	if err != nil {
		t.Fatalf("ReadAll: %v", err)
	}
	if len(got) != len(entries) {
		t.Fatalf("ReadAll returned %d entries, want %d", len(got), len(entries))
	}
	for i, want := range entries {
		if got[i] != want {
			t.Fatalf("entry %d = %+v, want %+v", i, got[i], want)
		}
	}
}

// TestAppend_PersistsAcrossReopen proves the WAL is genuinely durable -
// closing and reopening the same file must not lose any appended entry
// (a real, on-disk bbolt file, not an in-memory fake).
func TestAppend_PersistsAcrossReopen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "wal.db")

	w1, err := OpenWAL(path)
	if err != nil {
		t.Fatalf("OpenWAL: %v", err)
	}
	if err := w1.Append(WALEntry{Seq: 1, TokenID: 42, Position: 0}); err != nil {
		t.Fatalf("Append: %v", err)
	}
	if err := w1.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	w2, err := OpenWAL(path)
	if err != nil {
		t.Fatalf("re-OpenWAL: %v", err)
	}
	defer w2.Close()

	got, err := w2.ReadAll()
	if err != nil {
		t.Fatalf("ReadAll after reopen: %v", err)
	}
	if len(got) != 1 || got[0].TokenID != 42 {
		t.Fatalf("ReadAll after reopen = %+v, want [{Seq:1 TokenID:42 Position:0}]", got)
	}
}

// TestTruncate_RemovesEntriesUpToAndIncludingSeq proves Truncate deletes
// exactly the entries whose Seq is <= uptoSeq, leaving later entries
// intact - the real mechanism a checkpoint uses to bound WAL growth
// (spec.md's "WAL grows too large -> checkpoint triggered, WAL truncated
// after successful checkpoint" edge case, T063).
func TestTruncate_RemovesEntriesUpToAndIncludingSeq(t *testing.T) {
	w := openTestWAL(t)

	for seq := uint64(1); seq <= 5; seq++ {
		if err := w.Append(WALEntry{Seq: seq, TokenID: int32(seq), Position: int32(seq - 1)}); err != nil {
			t.Fatalf("Append(seq=%d): %v", seq, err)
		}
	}

	if err := w.Truncate(3); err != nil {
		t.Fatalf("Truncate(3): %v", err)
	}

	got, err := w.ReadAll()
	if err != nil {
		t.Fatalf("ReadAll: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("ReadAll after Truncate(3) returned %d entries, want 2 (seq 4 and 5)", len(got))
	}
	if got[0].Seq != 4 || got[1].Seq != 5 {
		t.Fatalf("ReadAll after Truncate(3) = %+v, want entries with Seq 4 and 5", got)
	}
}

// TestTruncate_OfEverythingLeavesEmptyWAL proves truncating up to the
// highest sequence number genuinely empties the WAL, not merely most of
// it.
func TestTruncate_OfEverythingLeavesEmptyWAL(t *testing.T) {
	w := openTestWAL(t)
	for seq := uint64(1); seq <= 3; seq++ {
		if err := w.Append(WALEntry{Seq: seq, TokenID: int32(seq), Position: int32(seq - 1)}); err != nil {
			t.Fatalf("Append(seq=%d): %v", seq, err)
		}
	}
	if err := w.Truncate(3); err != nil {
		t.Fatalf("Truncate(3): %v", err)
	}
	got, err := w.ReadAll()
	if err != nil {
		t.Fatalf("ReadAll: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("ReadAll after truncating everything returned %d entries, want 0", len(got))
	}
}

// TestReadAll_OnFreshWALReturnsEmpty proves a freshly-opened WAL with no
// appended entries reads back as genuinely empty, never nil-vs-panic
// ambiguity.
func TestReadAll_OnFreshWALReturnsEmpty(t *testing.T) {
	w := openTestWAL(t)
	got, err := w.ReadAll()
	if err != nil {
		t.Fatalf("ReadAll: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("ReadAll on a fresh WAL returned %d entries, want 0", len(got))
	}
}
