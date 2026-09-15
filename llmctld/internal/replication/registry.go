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
	"fmt"
	"sync"

	"github.com/vasic-digital/llmctl/llmctld/internal/isolation"
)

// StoreRegistry lazily opens and caches one *Store per tenant ID.
type StoreRegistry struct {
	baseDir string
	cfg     CheckpointConfig

	mu     sync.Mutex
	stores map[string]*Store
}

// NewStoreRegistry returns a StoreRegistry rooted at baseDir. It opens no
// Store itself - each tenant's Store is opened lazily, on its own first
// Get(tenantID) call, so a caller that never serves a given tenant never
// pays the cost (or risk) of opening that tenant's bbolt files.
func NewStoreRegistry(baseDir string, cfg CheckpointConfig) *StoreRegistry {
	return &StoreRegistry{baseDir: baseDir, cfg: cfg, stores: make(map[string]*Store)}
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
// Honest scope boundary (disclosed, not silently narrowed): Get always
// opens a PLAINTEXT Store (OpenStore), never OpenEncryptedStore -
// Clarification 20's per-tenant encryption-at-rest requirement is a
// distinct, separate threat model ("protects against a filesystem-level
// compromise or backup exposure", per spec.md) from Clarification 18's
// per-tenant-directory requirement this file closes, and wiring it needs
// its own decision about where a master encryption secret is sourced
// from (mirroring how LLMCTLD_JWT_SIGNING_KEY is sourced today) - real,
// tracked follow-up work, not invented speculatively here.
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

	s, err := OpenStore(dir, r.cfg)
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

	var firstErr error
	for tenantID, s := range r.stores {
		if err := s.Close(); err != nil && firstErr == nil {
			firstErr = fmt.Errorf("replication: closing store for tenant %q: %w", tenantID, err)
		}
	}
	r.stores = make(map[string]*Store)
	return firstErr
}
