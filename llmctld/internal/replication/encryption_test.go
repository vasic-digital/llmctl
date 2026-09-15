package replication

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/vasic-digital/llmctl/llmctld/internal/tenancy"
)

// TestOpenEncryptedWAL_CorrectKeyRoundTrips proves an encrypted WAL
// behaves identically to a plaintext one FOR THE CORRECT KEY - values
// round-trip exactly.
func TestOpenEncryptedWAL_CorrectKeyRoundTrips(t *testing.T) {
	key := tenancy.DeriveKey([]byte("master-secret"), "tenant-a")
	path := filepath.Join(t.TempDir(), "wal.db")

	w, err := OpenEncryptedWAL(path, key)
	if err != nil {
		t.Fatalf("OpenEncryptedWAL: %v", err)
	}
	defer w.Close()

	entry := WALEntry{Seq: 1, TokenID: 999, Position: 0}
	if err := w.Append(entry); err != nil {
		t.Fatalf("Append: %v", err)
	}

	got, err := w.ReadAll()
	if err != nil {
		t.Fatalf("ReadAll: %v", err)
	}
	if len(got) != 1 || got[0] != entry {
		t.Fatalf("ReadAll() = %+v, want [%+v]", got, entry)
	}
}

// TestOpenEncryptedWAL_WrongKeyFailsToDecrypt proves the core FR-051
// guarantee at the API level: reading with the WRONG tenant key produces
// a real error (AES-GCM authentication failure), never silently wrong
// data and never a lucky "wrong key happens to decrypt something".
func TestOpenEncryptedWAL_WrongKeyFailsToDecrypt(t *testing.T) {
	correctKey := tenancy.DeriveKey([]byte("master-secret"), "tenant-a")
	wrongKey := tenancy.DeriveKey([]byte("master-secret"), "tenant-b")
	path := filepath.Join(t.TempDir(), "wal.db")

	w1, err := OpenEncryptedWAL(path, correctKey)
	if err != nil {
		t.Fatalf("OpenEncryptedWAL (write): %v", err)
	}
	if err := w1.Append(WALEntry{Seq: 1, TokenID: 42, Position: 0}); err != nil {
		t.Fatalf("Append: %v", err)
	}
	if err := w1.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	w2, err := OpenEncryptedWAL(path, wrongKey)
	if err != nil {
		t.Fatalf("OpenEncryptedWAL (wrong-key reopen): %v", err)
	}
	defer w2.Close()

	if _, err := w2.ReadAll(); err == nil {
		t.Fatalf("ReadAll with the WRONG tenant key must fail, got nil error (encryption is not load-bearing)")
	}
}

// TestOpenEncryptedWAL_RawFileContentDoesNotContainPlaintextTokenID
// proves encryption at rest is real at the STORAGE layer, not merely
// "the API returns an error for the wrong key" - a raw byte-level scan
// of the on-disk bbolt file must NOT contain the plaintext TokenID value
// anywhere, since an attacker with raw filesystem access (Clarification
// 20's exact threat model: "a filesystem-level compromise or backup
// exposure") reads the file directly, bypassing this package's API
// entirely.
func TestOpenEncryptedWAL_RawFileContentDoesNotContainPlaintextTokenID(t *testing.T) {
	key := tenancy.DeriveKey([]byte("master-secret"), "tenant-a")
	path := filepath.Join(t.TempDir(), "wal.db")

	w, err := OpenEncryptedWAL(path, key)
	if err != nil {
		t.Fatalf("OpenEncryptedWAL: %v", err)
	}
	// A distinctive, unlikely-to-occur-by-chance TokenID value, encoded
	// big-endian exactly as encodeEntry would encode it in PLAINTEXT -
	// the exact byte pattern we assert is ABSENT from the raw file.
	const distinctiveTokenID int32 = 0x4F4B4159 // "OKAY" as bytes, arbitrary but recognizable
	if err := w.Append(WALEntry{Seq: 1, TokenID: distinctiveTokenID, Position: 0}); err != nil {
		t.Fatalf("Append: %v", err)
	}
	if err := w.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read raw WAL file: %v", err)
	}
	plaintextPattern := encodeEntry(WALEntry{TokenID: distinctiveTokenID, Position: 0})
	if bytes.Contains(raw, plaintextPattern) {
		t.Fatalf("raw on-disk WAL file contains the plaintext token encoding %x - encryption at rest is not real", plaintextPattern)
	}
}

// TestOpenWAL_UnencryptedStillWorks proves adding encryption support did
// not break the existing plaintext path (T059's original, still-used
// constructor) - backward compatibility for callers that genuinely do
// not need encryption (or haven't been given a tenant key yet).
func TestOpenWAL_UnencryptedStillWorks(t *testing.T) {
	path := filepath.Join(t.TempDir(), "wal.db")
	w, err := OpenWAL(path)
	if err != nil {
		t.Fatalf("OpenWAL: %v", err)
	}
	defer w.Close()
	if err := w.Append(WALEntry{Seq: 1, TokenID: 1, Position: 0}); err != nil {
		t.Fatalf("Append: %v", err)
	}
	got, err := w.ReadAll()
	if err != nil {
		t.Fatalf("ReadAll: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("ReadAll() returned %d entries, want 1", len(got))
	}
}

// TestOpenEncryptedStore_CheckpointRoundTripsWithCorrectKey proves the
// checkpoint side of encryption (not just the WAL side) works correctly
// for the right key.
func TestOpenEncryptedStore_CheckpointRoundTripsWithCorrectKey(t *testing.T) {
	key := tenancy.DeriveKey([]byte("master-secret"), "tenant-a")
	s, err := OpenEncryptedStore(t.TempDir(), CheckpointConfig{}, key)
	if err != nil {
		t.Fatalf("OpenEncryptedStore: %v", err)
	}
	defer s.Close()

	state := KVState{Tokens: []int32{1, 2, 3}, Positions: []int32{0, 1, 2}}
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

// TestOpenEncryptedStore_CheckpointUnreadableWithoutCorrectKey is T064's
// literal deliverable: "encryption_test.go proves a checkpoint file is
// unreadable without the correct tenant key."
func TestOpenEncryptedStore_CheckpointUnreadableWithoutCorrectKey(t *testing.T) {
	correctKey := tenancy.DeriveKey([]byte("master-secret"), "tenant-a")
	wrongKey := tenancy.DeriveKey([]byte("master-secret"), "tenant-b")
	dir := t.TempDir()

	s1, err := OpenEncryptedStore(dir, CheckpointConfig{}, correctKey)
	if err != nil {
		t.Fatalf("OpenEncryptedStore (write): %v", err)
	}
	if err := s1.Checkpoint(1, KVState{Tokens: []int32{7}, Positions: []int32{0}}); err != nil {
		t.Fatalf("Checkpoint: %v", err)
	}
	if err := s1.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	s2, err := OpenEncryptedStore(dir, CheckpointConfig{}, wrongKey)
	if err != nil {
		t.Fatalf("OpenEncryptedStore (wrong-key reopen): %v", err)
	}
	defer s2.Close()

	if _, err := s2.Restore(); err == nil {
		t.Fatalf("Restore with the WRONG tenant key must fail, got nil error - the checkpoint file must be unreadable without the correct key")
	}
}
