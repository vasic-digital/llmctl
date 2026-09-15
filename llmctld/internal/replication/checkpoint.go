// Package replication (checkpoint.go): periodic checkpointing on top of
// wal.go's durable log (FR-026, FR-028, SC-020).
package replication

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"time"

	bolt "go.etcd.io/bbolt"
)

// DefaultIntervalTokens is FR-026's default checkpoint token interval
// (N=1000) when CheckpointConfig.IntervalTokens is left zero.
const DefaultIntervalTokens = 1000

// DefaultIntervalTime is FR-026's default checkpoint time interval
// (T=30s) when CheckpointConfig.IntervalTime is left zero.
const DefaultIntervalTime = 30 * time.Second

// KVState represents a model's replicated token-cache state. See this
// package's doc comment (wal.go) for the honest scope boundary on what
// this models given llmctld's control-plane/data-plane split.
type KVState struct {
	Tokens    []int32
	Positions []int32
}

// CheckpointConfig configures the N-tokens-OR-T-seconds checkpoint
// trigger policy (FR-026). Zero values fall back to
// DefaultIntervalTokens/DefaultIntervalTime - "configurable, not
// hardcoded" (SC-020) means a caller CAN override either value, not that
// every caller MUST supply one.
type CheckpointConfig struct {
	IntervalTokens uint64
	IntervalTime   time.Duration
	// MaxWALSizeBytes is T063's WAL-too-large forced-checkpoint threshold
	// (spec.md edge case: "WAL grows too large -> checkpoint triggered;
	// WAL truncated after successful checkpoint"). spec.md gives no
	// specific number, so this is OPT-IN: zero (the default) disables
	// size-based forcing entirely, never a silently-guessed default
	// (Constitution §11.4.6 no-guessing) - a deployment wanting this
	// protection configures a real threshold for its own environment.
	MaxWALSizeBytes uint64
}

func (cfg CheckpointConfig) intervalTokens() uint64 {
	if cfg.IntervalTokens == 0 {
		return DefaultIntervalTokens
	}
	return cfg.IntervalTokens
}

func (cfg CheckpointConfig) intervalTime() time.Duration {
	if cfg.IntervalTime == 0 {
		return DefaultIntervalTime
	}
	return cfg.IntervalTime
}

// ShouldCheckpoint reports whether cfg's policy says a checkpoint is due
// now, given how many tokens and how much time have elapsed since the
// last checkpoint.
func (cfg CheckpointConfig) ShouldCheckpoint(tokensSinceLast uint64, timeSinceLast time.Duration) bool {
	return tokensSinceLast >= cfg.intervalTokens() || timeSinceLast >= cfg.intervalTime()
}

var checkpointBucket = []byte("checkpoints")
var latestCheckpointKey = []byte("latest")

// checkpointRecord is the JSON-serialized form persisted in the
// checkpoint bucket.
type checkpointRecord struct {
	Seq   uint64
	State KVState
}

// Store combines a WAL with periodic checkpointing: Checkpoint persists
// a snapshot and truncates the WAL entries it incorporates; Restore
// reconstructs the current KVState from the latest checkpoint plus any
// WAL entries logged after it (FR-028's failover-restore path).
type Store struct {
	db  *bolt.DB
	wal *WAL
	cfg CheckpointConfig
	// key, when non-nil, encrypts the persisted checkpoint record at
	// rest (FR-051) - see crypto.go. nil means plaintext, preserving
	// OpenStore's original behavior for callers without a tenant key.
	key []byte
}

// OpenStore opens (creating if necessary) a Store backed by two files
// under dir: wal.db (the durable log) and checkpoint.db (the latest
// checkpoint), storing both in PLAINTEXT. Use OpenEncryptedStore for
// per-tenant encryption at rest (FR-051). Kept as two separate bbolt
// files, matching this package's wal.go/checkpoint.go file split, rather
// than sharing one file's buckets - simpler to reason about
// independently and to test in isolation (wal_test.go already exercises
// WAL alone).
func OpenStore(dir string, cfg CheckpointConfig) (*Store, error) {
	return openStore(dir, cfg, nil)
}

// OpenEncryptedStore is OpenStore with per-tenant encryption at rest:
// both the WAL (via OpenEncryptedWAL) and the checkpoint record are
// AES-256-GCM encrypted with key (from internal/tenancy.DeriveKey), so
// neither file is readable without the correct tenant key.
func OpenEncryptedStore(dir string, cfg CheckpointConfig, key []byte) (*Store, error) {
	return openStore(dir, cfg, key)
}

func openStore(dir string, cfg CheckpointConfig, key []byte) (*Store, error) {
	wal, err := openWAL(filepath.Join(dir, "wal.db"), key)
	if err != nil {
		return nil, err
	}

	db, err := bolt.Open(filepath.Join(dir, "checkpoint.db"), 0o600, nil)
	if err != nil {
		wal.Close()
		return nil, fmt.Errorf("replication: open checkpoint store in %q: %w", dir, err)
	}
	if err := db.Update(func(tx *bolt.Tx) error {
		_, err := tx.CreateBucketIfNotExists(checkpointBucket)
		return err
	}); err != nil {
		db.Close()
		wal.Close()
		return nil, fmt.Errorf("replication: create checkpoint bucket in %q: %w", dir, err)
	}

	return &Store{db: db, wal: wal, cfg: cfg, key: key}, nil
}

// WAL returns s's underlying WAL, for callers that need to Append new
// entries directly (the checkpoint/restore path in this file never
// appends on its own behalf).
func (s *Store) WAL() *WAL {
	return s.wal
}

// Checkpoint persists state as the latest checkpoint at seq, then
// truncates the WAL up to and including seq - entries already
// incorporated into this checkpoint no longer need replaying (bounds WAL
// growth, spec.md's WAL-too-large edge case, T063).
func (s *Store) Checkpoint(seq uint64, state KVState) error {
	data, err := json.Marshal(checkpointRecord{Seq: seq, State: state})
	if err != nil {
		return fmt.Errorf("replication: marshal checkpoint: %w", err)
	}
	if s.key != nil {
		data, err = encryptValue(s.key, data)
		if err != nil {
			return err
		}
	}
	if err := s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket(checkpointBucket)
		return b.Put(latestCheckpointKey, data)
	}); err != nil {
		return fmt.Errorf("replication: persist checkpoint: %w", err)
	}
	return s.wal.Truncate(seq)
}

// Restore reconstructs the current KVState: the latest checkpoint (or an
// empty KVState if none exists yet), with every WAL entry whose Seq
// exceeds the checkpoint's Seq replayed on top, in ascending Seq order -
// a pure, deterministic fold over the persisted log, so a fresh Store
// instance loading the same on-disk files always reconstructs identical
// state (SC-020's "WAL replay deterministic").
func (s *Store) Restore() (KVState, error) {
	var rec checkpointRecord
	found := false
	if err := s.db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket(checkpointBucket)
		data := b.Get(latestCheckpointKey)
		if data == nil {
			return nil
		}
		found = true
		if s.key != nil {
			decrypted, err := decryptValue(s.key, data)
			if err != nil {
				return err
			}
			data = decrypted
		}
		return json.Unmarshal(data, &rec)
	}); err != nil {
		return KVState{}, fmt.Errorf("replication: load checkpoint: %w", err)
	}

	state := KVState{}
	baseSeq := uint64(0)
	if found {
		state = rec.State
		baseSeq = rec.Seq
	}

	entries, err := s.wal.ReadAll()
	if err != nil {
		return KVState{}, err
	}
	for _, e := range entries {
		if e.Seq <= baseSeq {
			continue
		}
		state.Tokens = append(state.Tokens, e.TokenID)
		state.Positions = append(state.Positions, e.Position)
	}
	return state, nil
}

// ShouldForceCheckpoint reports whether the WAL's real current on-disk
// size exceeds cfg.MaxWALSizeBytes (T063's WAL-too-large edge case).
// Always false when MaxWALSizeBytes is unset (0) - the mechanism is
// opt-in, never silently active on an un-configured default. A caller
// driving a checkpoint loop consults this ALONGSIDE
// CheckpointConfig.ShouldCheckpoint (the N-tokens-OR-T-seconds policy) so
// either condition can trigger an early checkpoint using whatever
// current state it has at that moment - Store itself does not track a
// live KVState (that is the caller's responsibility, per this package's
// pure-log design), so ShouldForceCheckpoint only reports the trigger
// condition, never performs the checkpoint itself.
func (s *Store) ShouldForceCheckpoint() (bool, error) {
	if s.cfg.MaxWALSizeBytes == 0 {
		return false, nil
	}
	size, err := s.wal.Size()
	if err != nil {
		return false, err
	}
	return uint64(size) > s.cfg.MaxWALSizeBytes, nil
}

// Close closes both underlying bbolt files.
func (s *Store) Close() error {
	walErr := s.wal.Close()
	dbErr := s.db.Close()
	if walErr != nil {
		return walErr
	}
	return dbErr
}
