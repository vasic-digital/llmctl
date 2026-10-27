package replication

import (
	"errors"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/vasic-digital/llmctl/llmctld/internal/tenancy"
)

// commitsDuring returns how many write transactions w committed while fn
// ran, read from bbolt's own transaction id (WAL.CommittedWriteTxID).
func commitsDuring(t *testing.T, w *WAL, fn func()) int {
	t.Helper()
	before, err := w.CommittedWriteTxID()
	if err != nil {
		t.Fatalf("CommittedWriteTxID (before): %v", err)
	}
	fn()
	after, err := w.CommittedWriteTxID()
	if err != nil {
		t.Fatalf("CommittedWriteTxID (after): %v", err)
	}
	return after - before
}

func seqRange(from, n uint64) []WALEntry {
	entries := make([]WALEntry, n)
	for i := uint64(0); i < n; i++ {
		seq := from + i
		entries[i] = WALEntry{Seq: seq, TokenID: int32(seq * 7), Position: int32(seq - 1)}
	}
	return entries
}

// retriedWithNewValues is seqRange with every TokenID changed, so a retry that
// overlaps earlier entries only matches the per-entry oracle when the retry
// overwrites them (identical values would hide a first-wins bug).
func retriedWithNewValues(from, n uint64) []WALEntry {
	entries := seqRange(from, n)
	for i := range entries {
		entries[i].TokenID += 1000
	}
	return entries
}

func openWALs(t *testing.T) map[string]*WAL {
	t.Helper()
	plain := openTestWAL(t)
	enc, err := OpenEncryptedWAL(filepath.Join(t.TempDir(), "wal.db"), tenancy.DeriveKey([]byte("master-secret"), "tenant-a"))
	if err != nil {
		t.Fatalf("OpenEncryptedWAL: %v", err)
	}
	t.Cleanup(func() { _ = enc.Close() })
	return map[string]*WAL{"plaintext": plain, "encrypted": enc}
}

// TestCommittedWriteTxID_CountsEveryCommit is the control needle for the
// commit-count instrument (§11.4.273): three separate Append calls must
// read as three commits, so a reading of 1 elsewhere is a real result and
// not a blind instrument.
func TestCommittedWriteTxID_CountsEveryCommit(t *testing.T) {
	w := openTestWAL(t)
	got := commitsDuring(t, w, func() {
		for _, e := range seqRange(1, 3) {
			if err := w.Append(e); err != nil {
				t.Fatalf("Append: %v", err)
			}
		}
	})
	if got != 3 {
		t.Fatalf("three Append calls read as %d commits, want 3", got)
	}
}

// TestAppendBatch_OneCommitForNEntries proves a batch of 500 entries is
// one bbolt transaction (one fsync), for plaintext and encrypted WALs,
// and that every entry reads back intact.
func TestAppendBatch_OneCommitForNEntries(t *testing.T) {
	for name, w := range openWALs(t) {
		t.Run(name, func(t *testing.T) {
			batch := seqRange(1, 500)
			commits := commitsDuring(t, w, func() {
				if err := w.AppendBatch(batch); err != nil {
					t.Fatalf("AppendBatch: %v", err)
				}
			})
			if commits != 1 {
				t.Fatalf("AppendBatch of %d entries made %d commits, want 1", len(batch), commits)
			}
			got, err := w.ReadAll()
			if err != nil {
				t.Fatalf("ReadAll: %v", err)
			}
			if !reflect.DeepEqual(got, batch) {
				t.Fatalf("ReadAll after AppendBatch: got %d entries, mismatch with the %d appended", len(got), len(batch))
			}
		})
	}
}

// TestAppendBatch_FailureMidBatchPersistsNothing proves all-or-nothing:
// a failure while writing entry 250 of 500 leaves the WAL exactly as it
// was before the call (no prefix, no commit) and returns the error.
func TestAppendBatch_FailureMidBatchPersistsNothing(t *testing.T) {
	for name, w := range openWALs(t) {
		t.Run(name, func(t *testing.T) {
			existing := WALEntry{Seq: 1, TokenID: 1, Position: 0}
			if err := w.Append(existing); err != nil {
				t.Fatalf("Append: %v", err)
			}
			injected := errors.New("injected mid-batch failure")
			w.beforeBatchPut = func(i int) error {
				if i == 250 {
					return injected
				}
				return nil
			}
			t.Cleanup(func() { w.beforeBatchPut = nil })

			var err error
			commits := commitsDuring(t, w, func() {
				err = w.AppendBatch(seqRange(2, 500))
			})
			if !errors.Is(err, injected) {
				t.Fatalf("AppendBatch error = %v, want the injected failure", err)
			}
			if commits != 0 {
				t.Fatalf("a failed AppendBatch made %d commits, want 0", commits)
			}
			got, rerr := w.ReadAll()
			if rerr != nil {
				t.Fatalf("ReadAll: %v", rerr)
			}
			if len(got) != 1 || got[0] != existing {
				t.Fatalf("WAL after failed AppendBatch = %d entries (%+v...), want only the pre-existing entry", len(got), firstOrZero(got))
			}
		})
	}
}

func firstOrZero(entries []WALEntry) WALEntry {
	if len(entries) == 0 {
		return WALEntry{}
	}
	return entries[0]
}

// TestAppendBatch_EmptyIsNoOp: an empty batch returns nil and commits
// nothing (the per-entry loop it replaces did not touch the file either).
func TestAppendBatch_EmptyIsNoOp(t *testing.T) {
	w := openTestWAL(t)
	for _, batch := range [][]WALEntry{nil, {}} {
		commits := commitsDuring(t, w, func() {
			if err := w.AppendBatch(batch); err != nil {
				t.Fatalf("AppendBatch(%v): %v", batch, err)
			}
		})
		if commits != 0 {
			t.Fatalf("AppendBatch(%v) made %d commits, want 0", batch, commits)
		}
	}
}

// TestAppendBatch_MatchesPerEntryAppend is a differential check against
// the per-entry Append it replaces in the append handler: for batches
// with duplicate Seq values (last write wins, as Put on the same key
// overwrites), out-of-order Seq values (read back ascending), and a
// retried range that overlaps entries already present (idempotent
// overwrite), the resulting WAL contents must be identical.
func TestAppendBatch_MatchesPerEntryAppend(t *testing.T) {
	cases := map[string][][]WALEntry{
		"duplicate seq, last wins": {{
			{Seq: 5, TokenID: 1, Position: 0},
			{Seq: 6, TokenID: 2, Position: 1},
			{Seq: 5, TokenID: 3, Position: 2},
		}},
		"out of order": {{
			{Seq: 9, TokenID: 9, Position: 8},
			{Seq: 2, TokenID: 2, Position: 1},
			{Seq: 5, TokenID: 5, Position: 4},
		}},
		"retried overlapping range": {seqRange(1, 10), retriedWithNewValues(5, 10)},
	}
	for name, batches := range cases {
		t.Run(name, func(t *testing.T) {
			batched := openTestWAL(t)
			oracle := openTestWAL(t)
			for _, b := range batches {
				if err := batched.AppendBatch(b); err != nil {
					t.Fatalf("AppendBatch: %v", err)
				}
				for _, e := range b {
					if err := oracle.Append(e); err != nil {
						t.Fatalf("Append: %v", err)
					}
				}
			}
			got, err := batched.ReadAll()
			if err != nil {
				t.Fatalf("ReadAll (batched): %v", err)
			}
			want, err := oracle.ReadAll()
			if err != nil {
				t.Fatalf("ReadAll (per-entry): %v", err)
			}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("AppendBatch result %+v differs from per-entry Append result %+v", got, want)
			}
		})
	}
}
