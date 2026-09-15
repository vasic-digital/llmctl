// Package replication implements FR-026/FR-027/FR-028's async KV-cache
// replication: a durable write-ahead log (this file), periodic
// checkpoints (checkpoint.go), and LoRA adapter replication (lora.go).
//
// Honest scope boundary (Constitution §11.4.223 provenance markers): this
// package models a model's replicated state as the ORDERED SEQUENCE OF
// TOKENS + POSITIONS fed into it - a real, meaningful, and REPLAYABLE
// representation (feeding the identical token sequence back into a fresh
// inference-engine process reconstructs equivalent context, which is
// exactly what "restore the KV cache" needs to achieve for a
// conversation to continue correctly). It does NOT reach into a running
// llama.cpp/colibri engine process's internal memory to snapshot raw
// attention-weight bytes - llmctld's control-plane/data-plane split means
// the inference engine is always a separate OS process reached only via
// its OpenAI-compatible HTTP API (bin/llmctl's smoke-test payload,
// docs/api-reference.md), never something llmctld can memory-snapshot
// directly. Whether the pinned llama.cpp version's real llama-server
// exposes an HTTP-reachable slot-save/restore endpoint that could
// eventually back a genuinely lower-latency restore path is a separate,
// investigated question - see docs/cluster-architecture.md's persistence
// section for the current finding, honestly marked ✅/📋.
package replication

import (
	"encoding/binary"
	"fmt"
	"os"

	bolt "go.etcd.io/bbolt"
)

var walBucket = []byte("wal")

// WALEntry is one durable log entry: a single token appended to a
// model's replicated state, identified by a monotonically increasing
// Seq so entries replay in a well-defined order and a checkpoint can
// name exactly which entries it already incorporates (Truncate).
type WALEntry struct {
	Seq      uint64
	TokenID  int32
	Position int32
}

// WAL is a durable, bbolt-backed write-ahead log.
type WAL struct {
	db   *bolt.DB
	path string
	// key, when non-nil, encrypts every value at rest (FR-051,
	// Clarification 20) - see crypto.go. nil means plaintext, preserving
	// OpenWAL's original behavior exactly for callers that don't (yet)
	// have a tenant key.
	key []byte
}

// OpenWAL opens (creating if necessary) a WAL backed by the bbolt file at
// path, storing values in PLAINTEXT. Use OpenEncryptedWAL for per-tenant
// encryption at rest (FR-051).
func OpenWAL(path string) (*WAL, error) {
	return openWAL(path, nil)
}

// OpenEncryptedWAL is OpenWAL with per-tenant encryption at rest: every
// value is AES-256-GCM encrypted with key (from
// internal/tenancy.DeriveKey) before being persisted, and decrypted on
// read - so a bbolt file opened directly (bypassing this package,
// Clarification 20's "filesystem-level compromise or backup exposure"
// threat model) or reopened with the WRONG tenant key contains only
// ciphertext / fails to decrypt.
func OpenEncryptedWAL(path string, key []byte) (*WAL, error) {
	return openWAL(path, key)
}

func openWAL(path string, key []byte) (*WAL, error) {
	db, err := bolt.Open(path, 0o600, nil)
	if err != nil {
		return nil, fmt.Errorf("replication: open WAL %q: %w", path, err)
	}
	if err := db.Update(func(tx *bolt.Tx) error {
		_, err := tx.CreateBucketIfNotExists(walBucket)
		return err
	}); err != nil {
		db.Close()
		return nil, fmt.Errorf("replication: create WAL bucket in %q: %w", path, err)
	}
	return &WAL{db: db, path: path, key: key}, nil
}

// Size returns the WAL's real current on-disk file size in bytes - the
// input T063's WAL-too-large forced-checkpoint mechanism checks against
// a configured threshold (see checkpoint.go's
// CheckpointConfig.MaxWALSizeBytes / Store.ShouldForceCheckpoint).
func (w *WAL) Size() (int64, error) {
	info, err := os.Stat(w.path)
	if err != nil {
		return 0, fmt.Errorf("replication: stat WAL file %q: %w", w.path, err)
	}
	return info.Size(), nil
}

// Append durably persists entry.
func (w *WAL) Append(entry WALEntry) error {
	value := encodeEntry(entry)
	if w.key != nil {
		encrypted, err := encryptValue(w.key, value)
		if err != nil {
			return err
		}
		value = encrypted
	}
	return w.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket(walBucket)
		return b.Put(seqKey(entry.Seq), value)
	})
}

// ReadAll returns every currently-persisted entry, in ascending Seq
// order (bbolt's own B+tree keeps keys in byte-lexicographic order,
// which seqKey's fixed-width big-endian encoding makes equivalent to
// numeric order for uint64 sequence numbers).
func (w *WAL) ReadAll() ([]WALEntry, error) {
	var entries []WALEntry
	err := w.db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket(walBucket)
		return b.ForEach(func(k, v []byte) error {
			value := v
			if w.key != nil {
				decrypted, err := decryptValue(w.key, v)
				if err != nil {
					return err
				}
				value = decrypted
			}
			entry, err := decodeEntry(k, value)
			if err != nil {
				return err
			}
			entries = append(entries, entry)
			return nil
		})
	})
	if err != nil {
		return nil, fmt.Errorf("replication: read WAL: %w", err)
	}
	return entries, nil
}

// Truncate deletes every entry whose Seq is <= uptoSeq - the real
// mechanism a successful checkpoint uses to bound WAL growth
// (spec.md's "WAL grows too large -> checkpoint triggered, WAL truncated
// after successful checkpoint" edge case, T063).
func (w *WAL) Truncate(uptoSeq uint64) error {
	return w.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket(walBucket)
		c := b.Cursor()
		limit := seqKey(uptoSeq)
		for k, _ := c.First(); k != nil; k, _ = c.Next() {
			if compareKeys(k, limit) > 0 {
				break
			}
			if err := c.Delete(); err != nil {
				return err
			}
		}
		return nil
	})
}

// Close closes the underlying bbolt file.
func (w *WAL) Close() error {
	return w.db.Close()
}

func seqKey(seq uint64) []byte {
	buf := make([]byte, 8)
	binary.BigEndian.PutUint64(buf, seq)
	return buf
}

func compareKeys(a, b []byte) int {
	for i := range a {
		if a[i] != b[i] {
			if a[i] < b[i] {
				return -1
			}
			return 1
		}
	}
	return 0
}

func encodeEntry(e WALEntry) []byte {
	buf := make([]byte, 8)
	binary.BigEndian.PutUint32(buf[0:4], uint32(e.TokenID))
	binary.BigEndian.PutUint32(buf[4:8], uint32(e.Position))
	return buf
}

func decodeEntry(key, value []byte) (WALEntry, error) {
	if len(key) != 8 {
		return WALEntry{}, fmt.Errorf("replication: corrupt WAL key length %d, want 8", len(key))
	}
	if len(value) != 8 {
		return WALEntry{}, fmt.Errorf("replication: corrupt WAL value length %d, want 8", len(value))
	}
	return WALEntry{
		Seq:      binary.BigEndian.Uint64(key),
		TokenID:  int32(binary.BigEndian.Uint32(value[0:4])),
		Position: int32(binary.BigEndian.Uint32(value[4:8])),
	}, nil
}
