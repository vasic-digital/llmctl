// Package replication (enginecache.go): 003-kv-cache-replication's User
// Story 2 - real engine cache save/restore orchestration + cross-node
// transfer (T016), additive to (never a replacement for) User Story 1's
// correctness-bearing WAL/checkpoint mechanism (research.md Decision 4,
// spec.md FR-006/FR-007/FR-008/FR-009). See data-model.md's
// EngineCacheFile entity for the field-level design this file
// implements.
//
// Decoupling (Constitution §11.4.28), matching forwarder.go's own
// package doc comment exactly: this file does NOT import
// internal/cluster, internal/raft, or internal/executor -
// EngineSaver/EngineRestorer are caller-injected function types (the
// wiring layer, internal/api and internal/executor, supplies the real
// implementations that call the real llama-server /slots/:id_slot
// endpoint), and the cross-node transfer reuses lora.go's own
// AdapterSink function type (func(name string, data []byte) error)
// rather than inventing a second file-sink abstraction - HTTPCacheSink
// below is this package's own real, HTTP-based implementation of that
// SAME type, mirroring FileAdapterSink's file-based one, and
// TransferEngineCache reuses ReplicateAdapter directly rather than
// duplicating its read-once-deliver-to-every-sink logic (FR-012: "MUST
// NOT introduce a second, parallel transport mechanism").
//
// Non-blocking-for-correctness discipline (research.md Decision 4,
// spec.md FR-008/FR-009): every function in this file that can fail
// (MaybeSaveEngineCache, RestoreOrFallback) is designed so a real engine
// cache failure NEVER prevents or delays User Story 1's own recovery
// path - MaybeSaveEngineCache never returns an error at all (a save
// failure is recorded, never propagated) and RestoreOrFallback's only
// possible returned error comes from the caller-supplied fallback
// itself, never from the optimization it is falling back from.
package replication

import (
	"bytes"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Validity's closed vocabulary (data-model.md's EngineCacheFile.Validity
// field: "intact" | "stale" | "unavailable").
const (
	EngineCacheIntact      = "intact"
	EngineCacheStale       = "stale"
	EngineCacheUnavailable = "unavailable"
)

// EngineCacheFile is the real, engine-produced artifact representing an
// inference engine's actual on-disk cache for one tenant's replicated
// stream (data-model.md) - distinct from and additional to KVState (the
// replayable token-sequence checkpoint, checkpoint.go).
type EngineCacheFile struct {
	TenantID string
	NodeID   string
	Path     string
	Validity string
	SavedAt  time.Time
}

// EngineCacheRegistry tracks the most-recently-known EngineCacheFile per
// tenant, IN MEMORY ONLY - never Raft-replicated (data-model.md: "large
// binary artifact reference, not small consensus state", matching
// ReplicationLagRecord's own persistence choice in the sibling lag.go
// design). Rebuilt from real save/transfer confirmations as this node
// observes them; never assumed durable across a process restart.
type EngineCacheRegistry struct {
	mu    sync.Mutex
	files map[string]EngineCacheFile
}

// NewEngineCacheRegistry returns an empty EngineCacheRegistry.
func NewEngineCacheRegistry() *EngineCacheRegistry {
	return &EngineCacheRegistry{files: make(map[string]EngineCacheFile)}
}

// Set records f as tenantID's current EngineCacheFile, replacing any
// prior record for that tenant.
func (r *EngineCacheRegistry) Set(f EngineCacheFile) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.files[f.TenantID] = f
}

// Get returns tenantID's currently-recorded EngineCacheFile, if any.
func (r *EngineCacheRegistry) Get(tenantID string) (EngineCacheFile, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	f, ok := r.files[tenantID]
	return f, ok
}

// EngineSaver triggers a real save of the LOCAL inference engine's own
// cache for tenantID (T016: internal/executor.LocalExecutor.SaveSlot,
// injected here as a plain function so this package stays
// engine/executor-decoupled, matching forwarder.go's RoleResolver/
// AddrResolver injection pattern exactly), returning the real absolute
// on-disk path the engine wrote to. Returns ErrEngineCacheUnsupported
// (or any error wrapping it, checkable via errors.Is) when the running
// engine/model does not support this capability at all (spec.md's Edge
// Case: "the real engine's cache-save/restore mechanism is unavailable
// for a given model or platform").
type EngineSaver func(tenantID string) (path string, err error)

// ErrEngineCacheUnsupported is EngineSaver/EngineRestorer's sentinel for
// "this model/engine genuinely does not support real cache save/
// restore" - distinct from a transient failure. MaybeSaveEngineCache
// currently records the SAME "unavailable" validity either way (FR-008
// makes no closure-vocabulary distinction at the SAVE side - only
// RestoreOrFallback's returned outcome distinguishes "fell_back" from
// "unsupported", and it does so via restorer being nil, not via this
// sentinel) - ErrEngineCacheUnsupported exists so a caller wiring a real
// EngineSaver CAN report this distinctly (e.g. in logs) via errors.Is,
// without this package itself needing to interpret engine-specific error
// shapes.
var ErrEngineCacheUnsupported = errors.New("replication: real engine cache save/restore is unsupported for this model/engine")

// MaybeSaveEngineCache is User Story 2's checkpoint-time hook (T016,
// spec.md FR-006/FR-009): triggers a real engine cache save via saver,
// recording the outcome in registry. NEVER returns an error and is SAFE
// TO CALL IN A GOROUTINE (spec.md's Edge Case: "the system must not make
// correctness wait on a slow, large-file... save" - the caller, e.g.
// internal/api/routes_replication.go's checkpoint handler, is expected
// to invoke this via `go MaybeSaveEngineCache(...)` AFTER its own
// store.Checkpoint() has already durably succeeded, exactly mirroring
// how Forwarder.ForwardCheckpoint is already invoked there for User
// Story 1). saver == nil (or registry == nil) is an honest no-op (the
// feature is not configured for this tenant/profile) - MaybeSaveEngineCache
// never invents a save attempt saver did not offer.
func MaybeSaveEngineCache(registry *EngineCacheRegistry, tenantID, nodeID string, saver EngineSaver) {
	if saver == nil || registry == nil {
		return
	}
	now := time.Now()
	path, err := saver(tenantID)
	if err != nil {
		// A failed (or unsupported) save is recorded honestly as
		// unavailable, not silently dropped - a later RestoreOrFallback
		// call reads this and correctly falls back rather than trying
		// (and failing again) to restore from a file that never existed.
		registry.Set(EngineCacheFile{TenantID: tenantID, NodeID: nodeID, Validity: EngineCacheUnavailable, SavedAt: now})
		return
	}
	registry.Set(EngineCacheFile{TenantID: tenantID, NodeID: nodeID, Path: path, Validity: EngineCacheIntact, SavedAt: now})
}

// EngineRestorer attempts a real warm-restore of the LOCAL engine's cache
// from path for tenantID (T016: internal/executor.LocalExecutor.RestoreSlot).
type EngineRestorer func(tenantID, path string) error

// FallbackFunc performs User Story 1's correctness-bearing recovery
// (replay the replicated token-sequence checkpoint, checkpoint.go's own
// Store.Restore) - ALWAYS available, and ALWAYS what RestoreOrFallback
// calls whenever the real engine cache is unavailable, stale, unusable,
// or fails to restore (research.md Decision 4).
type FallbackFunc func() error

// RestoreOutcome's closed vocabulary (spec.md FR-008: "succeeded / fell
// back / unsupported" - the outcome MUST always be reported as exactly
// one of these three, never silently only success or only failure).
const (
	RestoreOutcomeSucceeded   = "succeeded"
	RestoreOutcomeFellBack    = "fell_back"
	RestoreOutcomeUnsupported = "unsupported"
)

// statFileNonEmpty reports whether path exists as a real, non-empty,
// non-directory file on the local filesystem - the real, on-disk "is
// this the file the engine actually wrote, or is it missing/corrupted-
// to-empty" check T013 exercises directly with genuinely deleted/
// truncated fixture files; no live engine process is required for THIS
// specific check. The real engine's own restore endpoint (called by
// restorer below, when this check passes) is the SECOND, independent
// line of defense against a file that passes this check but is corrupt
// in a way only the engine's own binary-format parser can detect (a
// non-empty file with garbled/truncated content) - RestoreOrFallback
// treats a restorer error identically to failing this check, so BOTH
// corruption classes fall back the same way.
func statFileNonEmpty(path string) bool {
	if path == "" {
		return false
	}
	info, err := os.Stat(path)
	if err != nil || info.IsDir() || info.Size() == 0 {
		return false
	}
	return true
}

// RestoreOrFallback implements User Story 2's non-negotiable ordering
// constraint (spec.md FR-008/FR-009, research.md Decision 4): a real
// engine warm-restore is attempted ONLY when cache is known, recorded
// "intact", and its real on-disk file genuinely exists and is non-empty
// (statFileNonEmpty) - a missing or empty (corrupted-to-zero-bytes) file
// is caught HERE, without ever calling restorer, and falls back
// immediately (T013's "missing" case). If the file passes that check but
// restorer itself still fails (a corruption statFileNonEmpty cannot see
// - e.g. a truncated-but-non-empty or bit-flipped file the engine's own
// parser rejects - T013's "corrupt" case), this ALSO falls back, never
// propagating the engine's restore error to the caller as this
// conversation's own failure.
//
// Correctness (whether fallback itself succeeds) is the ONLY outcome
// this function's own returned error can ever report - a warm-restore
// failure is captured in the returned outcome string, NOT surfaced as
// err, because reporting a performance-optimization's failure as a
// correctness failure would be exactly the bluff FR-008 forbids.
// restorer == nil means the running engine/model does not support this
// capability at all - reported as RestoreOutcomeUnsupported (a
// DIFFERENT outcome than RestoreOutcomeFellBack, even though both fall
// back via the identical fallback() call, so an operator sees FR-008's
// exact three-way outcome vocabulary rather than one being conflated
// with the other).
func RestoreOrFallback(cache EngineCacheFile, cacheKnown bool, restorer EngineRestorer, fallback FallbackFunc) (outcome string, err error) {
	if fallback == nil {
		return "", fmt.Errorf("replication: RestoreOrFallback: fallback is required (User Story 1's correctness guarantee must always be available)")
	}
	if restorer == nil {
		if fbErr := fallback(); fbErr != nil {
			return RestoreOutcomeUnsupported, fbErr
		}
		return RestoreOutcomeUnsupported, nil
	}
	if !cacheKnown || cache.Validity != EngineCacheIntact || !statFileNonEmpty(cache.Path) {
		if fbErr := fallback(); fbErr != nil {
			return RestoreOutcomeFellBack, fbErr
		}
		return RestoreOutcomeFellBack, nil
	}
	if rErr := restorer(cache.TenantID, cache.Path); rErr != nil {
		if fbErr := fallback(); fbErr != nil {
			return RestoreOutcomeFellBack, fbErr
		}
		return RestoreOutcomeFellBack, nil
	}
	return RestoreOutcomeSucceeded, nil
}

// --- Cross-node transfer (spec.md FR-007/FR-012) ---------------------------

// engineCacheTenantIDHeader/engineCacheFilenameHeader are the wire
// headers HTTPCacheSink and the receiving route
// (internal/api/routes_replication.go's /v1/replication/enginecache
// route) agree on - matching forwarder.go's own forwardTenantIDHeader
// convention (independently defined in each package rather than one
// importing the other, per this package's decoupling doc comment).
const (
	engineCacheTenantIDHeader = "X-Tenant-ID"
	engineCacheFilenameHeader = "X-Engine-Cache-Filename"
)

// engineCacheRetryBudget/engineCacheRetryInterval mirror forwarder.go's
// own bounded-retry constants (FR-004's sibling constraint for THIS
// transfer, spec.md's Edge Case: "the failover needs to happen quickly
// ... the warm-restore optimization completes independently ... never
// blocking the user-visible recovery" - a slow/failed cache-file
// transfer must never hang the caller that kicked it off).
const (
	engineCacheRetryBudget   = 5 * time.Second
	engineCacheRetryInterval = 200 * time.Millisecond
)

// HTTPCacheSink returns an AdapterSink (lora.go's own type, reused rather
// than duplicated - see this file's package doc comment) that POSTs
// data as filename's real bytes to baseURL's own
// /v1/replication/enginecache route, carrying tenantID + bearerToken
// exactly as forwarder.go's postWithRetry already does for appends/
// checkpoints (T011's tenant-scoping discipline applied identically
// here) over the SAME existing HTTP/3+mTLS channel (FR-012: "MUST NOT
// introduce a second, parallel transport mechanism") httpClient is the
// caller's own real transport, exactly as Forwarder's httpClient field
// is - production callers inject HTTP/3+mTLS, tests inject a plain
// http.Client against an httptest.Server (see enginecache_test.go).
func HTTPCacheSink(baseURL, tenantID, bearerToken string, httpClient *http.Client) AdapterSink {
	return func(filename string, data []byte) error {
		deadline := time.Now().Add(engineCacheRetryBudget)
		var lastErr error
		for {
			if err := postEngineCacheOnce(httpClient, baseURL, tenantID, bearerToken, filename, data); err != nil {
				lastErr = err
			} else {
				return nil
			}
			if time.Now().After(deadline) {
				return lastErr
			}
			time.Sleep(engineCacheRetryInterval)
		}
	}
}

func postEngineCacheOnce(httpClient *http.Client, baseURL, tenantID, bearerToken, filename string, data []byte) error {
	req, err := http.NewRequest(http.MethodPost, baseURL+"/v1/replication/enginecache", bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("replication: build engine-cache transfer request: %w", err)
	}
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set(engineCacheFilenameHeader, filename)
	if bearerToken != "" {
		req.Header.Set("Authorization", "Bearer "+bearerToken)
	}
	if tenantID != "" {
		req.Header.Set(engineCacheTenantIDHeader, tenantID)
	}
	resp, doErr := httpClient.Do(req)
	if doErr != nil {
		return doErr
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("engine-cache transfer to %s: status %d", baseURL, resp.StatusCode)
	}
	return nil
}

// TransferEngineCache delivers cache's real on-disk file bytes to every
// sink (typically one HTTPCacheSink per replica/new-primary that needs
// it) by reusing ReplicateAdapter (lora.go) directly: an engine cache
// file and a LoRA adapter are both "a real file this package reads once
// and delivers to every sink over the existing channel" in exactly the
// same shape, so this is the SAME mechanism, never a duplicated one
// (FR-012). Per research.md Decision 4/FR-009, TransferEngineCache is
// meant to be invoked asynchronously by its caller (e.g. `go
// TransferEngineCache(...)`) - it never blocks User Story 1's own
// recovery path itself, since it only ever runs as an independent,
// caller-scheduled upgrade step.
func TransferEngineCache(cache EngineCacheFile, sinks []AdapterSink) error {
	return ReplicateAdapter(LoraAdapter{Name: filepath.Base(cache.Path), Path: cache.Path}, sinks)
}
