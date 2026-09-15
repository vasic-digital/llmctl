// Package replication (registry.go): StoreRegistry wires
// internal/isolation.TenantStateDir into a real, on-disk model-data path
// decision for this package's own Store - closing Clarification 18/
// FR-049's disclosed gap.
//
// wal.go's own doc comment already establishes what "KV cache/WAL
// storage" means for this codebase: the ORDERED SEQUENCE OF TOKENS +
// POSITIONS a Store durably replicates is genuinely a model's replicated
// conversation content, real enough that Clarification 18's per-tenant-
// directory requirement (and Clarification 20's per-tenant-encryption
// requirement, served by the separate, pre-existing
// OpenEncryptedStore/internal/tenancy.DeriveKey pair) apply to it
// directly - this is NOT llama.cpp's own in-process attention-weight KV
// cache (which this package deliberately never reaches into; see
// wal.go), and it is NOT the downloaded model weight files under
// LLMCTL_MODELS_DIR (a separate, shared, read-only resource on the bash
// side - confirmed via a full repository audit before writing this file:
// LLMCTL_MODELS_DIR is only ever written by lib/download.sh's download
// path, never per-tenant).
//
// Before this file, every caller (cmd/llmctld's two wiring sites,
// api.RegisterReplicationRoutes) opened exactly ONE Store per node,
// shared across every tenant that node might ever serve - a real
// Clarification-18 violation waiting to happen the moment more than one
// tenant's traffic reaches one node's /v1/replication/* routes, since
// every tenant's replicated tokens would land in the SAME wal.db/
// checkpoint.db pair with no isolation at all. StoreRegistry closes
// that gap while staying strictly additive: Get("") (the zero value)
// opens baseDir directly, byte-identical to the pre-existing single-
// Store-per-node behavior, so no existing caller that never supplies a
// tenant ID observes any behavior change.
package replication

import (
	"errors"
	"fmt"
	"sync"

	"github.com/vasic-digital/llmctl/llmctld/internal/isolation"
	"github.com/vasic-digital/llmctl/llmctld/internal/tenancy"
)

// StoreRegistry lazily opens and caches one *Store per tenant ID.
type StoreRegistry struct {
	baseDir      string
	cfg          CheckpointConfig
	masterSecret []byte

	mu     sync.Mutex
	stores map[string]*Store
}

// NewStoreRegistry returns a StoreRegistry rooted at baseDir that opens
// every tenant's Store in PLAINTEXT (via OpenStore) - the original,
// backward-compatible T072-FU2 behavior. It opens no Store itself - each
// tenant's Store is opened lazily, on its own first Get(tenantID) call,
// so a caller that never serves a given tenant never pays the cost (or
// risk) of opening that tenant's bbolt files.
func NewStoreRegistry(baseDir string, cfg CheckpointConfig) *StoreRegistry {
	return &StoreRegistry{baseDir: baseDir, cfg: cfg, stores: make(map[string]*Store)}
}

// NewEncryptedStoreRegistry is NewStoreRegistry with per-tenant
// encryption at rest (Clarification 20/FR-051, T072-FU3 - the disclosed
// scope boundary T072-FU2 left open): every NON-EMPTY tenant ID's Store
// is opened via OpenEncryptedStore under a key derived from masterSecret
// specifically for that tenant (internal/tenancy.DeriveKey), so no two
// tenants' data is ever readable under the same key even though they
// share one masterSecret - the exact per-tenant-key property
// Clarification 20 requires, applied here for the first time at the
// registry (wiring) layer rather than left as an independently-tested
// but unused capability.
//
// The empty ("") tenant ID is DELIBERATELY EXEMPT from encryption even
// under this constructor: it represents "no tenant" (the single-node/
// no-tenancy default path), not "a tenant whose ID happens to be
// empty", and T072-FU2's own established invariant - Get("") is
// byte-identical to a bare OpenStore(baseDir, cfg) call - stays true
// under EITHER constructor, so a deployment that never opts into
// multi-tenancy observes zero behavior change from this file existing.
//
// masterSecret's provenance (an env var, a secrets manager, etc.) is the
// caller's concern, exactly as internal/tenancy.DeriveKey's own doc
// comment already establishes - this constructor only wires the
// already-built DeriveKey/OpenEncryptedStore pair together at the
// correct place.
func NewEncryptedStoreRegistry(baseDir string, cfg CheckpointConfig, masterSecret []byte) *StoreRegistry {
	return &StoreRegistry{baseDir: baseDir, cfg: cfg, masterSecret: masterSecret, stores: make(map[string]*Store)}
}

// Get returns tenantID's Store, opening (and caching) it on first
// access. tenantID == "" opens baseDir directly via OpenStore - exactly
// the pre-existing single-store-per-node path, preserved byte-for-byte
// so no caller that never supplies a tenant ID observes any change.
//
// A non-empty tenantID is validated and isolated via
// internal/isolation.TenantStateDir - the SAME allow-list +
// verified-0700-permission mechanism T072 already established for
// per-tenant cgroup state directories, never a second, independently
// re-implemented isolation check - before its Store is opened under
// that real, permission-verified subdirectory of baseDir.
//
// If r was built via NewEncryptedStoreRegistry, a non-empty tenantID's
// Store is opened via OpenEncryptedStore under a key
// internal/tenancy.DeriveKey derives specifically for tenantID from r's
// masterSecret (Clarification 20/FR-051, T072-FU3); the empty tenant ID
// is always plaintext regardless of which constructor built r (see
// NewEncryptedStoreRegistry's doc comment for why). If r was built via
// NewStoreRegistry (masterSecret nil), every tenant is plaintext -
// T072-FU2's original behavior, unchanged.
func (r *StoreRegistry) Get(tenantID string) (*Store, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if s, ok := r.stores[tenantID]; ok {
		return s, nil
	}

	dir := r.baseDir
	if tenantID != "" {
		d, err := isolation.TenantStateDir(r.baseDir, tenantID)
		if err != nil {
			return nil, fmt.Errorf("replication: tenant state dir for tenant %q: %w", tenantID, err)
		}
		dir = d
	}

	var s *Store
	var err error
	if tenantID != "" && r.masterSecret != nil {
		key := tenancy.DeriveKey(r.masterSecret, tenantID)
		s, err = OpenEncryptedStore(dir, r.cfg, key)
	} else {
		s, err = OpenStore(dir, r.cfg)
	}
	if err != nil {
		return nil, fmt.Errorf("replication: open store for tenant %q: %w", tenantID, err)
	}
	r.stores[tenantID] = s
	return s, nil
}

// Close closes every Store this registry has opened so far. It closes
// all of them even if one fails, rather than stopping at the first
// error, so a single tenant's close failure never leaks every other
// tenant's bbolt file handles.
func (r *StoreRegistry) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()

	// errors.Join (not "keep only the first error") so a second or
	// later tenant's close failure is never silently dropped just
	// because an earlier one already failed - every failure is visible,
	// even though every store is still attempted regardless.
	var errs []error
	for tenantID, s := range r.stores {
		if err := s.Close(); err != nil {
			errs = append(errs, fmt.Errorf("replication: closing store for tenant %q: %w", tenantID, err))
		}
	}
	r.stores = make(map[string]*Store)
	return errors.Join(errs...)
}
