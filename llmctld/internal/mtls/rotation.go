// Package mtls (rotation.go): Feature 004 Phase 5 (User Story 3)'s
// LOCAL, per-node, in-memory holder of which CA THIS node currently
// issues fresh certificates from and currently trusts - distinct from
// TrustStore (which is the live verification data source EVERY real TLS
// handshake reads from), because building the CertPool(s) a TrustStore
// should hold during/after a CA rotation requires the actual CA
// certificate material, which - per data-model.md's CARotationEvent
// security note - NEVER travels through the Raft-replicated log (only a
// stable fingerprint HASH of each CA's certificate does). A node
// therefore learns the incoming CA's real material ONLY out-of-band, via
// its own local POST /v1/cluster/mtls/rotate/begin API call (the SAME
// operator distribution pattern already used for -ca-cert/-ca-key at
// bootstrap - never a second coordination channel, per spec.md FR-014).
// RotationCAHolder is where that locally-loaded material lives, and
// Pools() is what internal/api/routes_mtls.go feeds into
// TrustStore.UpdateTrustedCAs to make it take effect.
package mtls

import (
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"sync"
)

// RotationCAHolder is mutex-protected because it is read (Pools/
// IssuingCA/InProgress) from HTTP handler goroutines and written
// (BeginLocalRotation/FinalizeLocalRotation) from the SAME handler
// goroutines PLUS the FSM's own notify-after-unlock handler
// (cmd/llmctld/main.go's wireRevocationHandler, invoked from
// hashicorp/raft's single FSM-apply goroutine per fsm.go's
// onRevocationApplied doc comment) - a genuinely concurrent-access
// shape, matching TrustStore's own sync.RWMutex rationale, though a
// plain sync.Mutex suffices here since RotationCAHolder's read path
// (Pools/IssuingCA/InProgress) is not the per-handshake hot path
// TrustStore.Verify/GetCertificate are - it is read once per API request,
// not once per TLS handshake.
type RotationCAHolder struct {
	mu sync.Mutex

	// issuingCA is the CA this node currently issues fresh certificates
	// from - the node's original CA in steady state, the INCOMING CA the
	// moment this node's own local BeginLocalRotation call loads it, so
	// every renewal that happens while a rotation is in progress issues
	// under the new CA (spec.md Acceptance Scenario 2/3).
	issuingCA *CA
	// outgoingCA is non-nil ONLY while THIS node has a locally-loaded,
	// in-progress rotation - the CA being retired, kept so this node can
	// build the dual-trust pool ([outgoing, incoming]) FR-008 requires
	// during the transition, and so FinalizeLocalRotation has something
	// concrete to drop.
	outgoingCA *CA
}

// NewRotationCAHolder returns a holder in steady state: issuing (and
// trusting) only initial, the CA every node starts with before any
// rotation is ever begun.
func NewRotationCAHolder(initial *CA) *RotationCAHolder {
	return &RotationCAHolder{issuingCA: initial}
}

// IssuingCA returns the CA this node currently issues fresh certificates
// from - read by internal/api/routes_mtls.go's POST
// /v1/cluster/mtls/renew handler in place of a bare captured *mtls.CA, so
// a renewal issued while a rotation is in progress genuinely uses the
// incoming CA.
func (h *RotationCAHolder) IssuingCA() *CA {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.issuingCA
}

// InProgress reports whether this node has a LOCALLY-loaded, in-progress
// rotation (i.e. whether its own "begin rotation" API call has already
// run) - distinct from the Raft-replicated ClusterState.CARotation.Status
// == "in_progress" fact, which every node observes identically regardless
// of whether IT has locally loaded the incoming CA's material yet (see
// this type's own package doc comment for why those two facts can
// legitimately differ).
func (h *RotationCAHolder) InProgress() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.outgoingCA != nil
}

// BeginLocalRotation records that THIS node has locally loaded incoming
// as the CA it will issue future certificates from, keeping its previous
// issuing CA as outgoing so Pools() can build the FR-008 dual-trust pool.
// Idempotent: a repeated call (e.g. a retried "begin rotation" API
// request, or the SAME rotation's begin action issued a second time)
// while a rotation is ALREADY locally in progress updates issuingCA but
// deliberately does NOT reset outgoingCA a second time - the ORIGINAL
// outgoing CA (the one nodes still presenting their pre-rotation
// certificate need to keep chain-validating against) must never be lost.
func (h *RotationCAHolder) BeginLocalRotation(incoming *CA) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.outgoingCA == nil {
		h.outgoingCA = h.issuingCA
	}
	h.issuingCA = incoming
}

// FinalizeLocalRotation clears the locally-tracked outgoing CA, so
// Pools() returns to a single-pool steady state trusting only the (now
// current) issuing CA. A no-op if this node never locally began a
// rotation (h.outgoingCA is already nil) - an HONEST, disclosed
// limitation (this type's own package doc comment): a node that was
// never told the incoming CA's real material out-of-band can never be
// made to trust it merely because the Raft-replicated
// ClusterState.CARotation.Status flipped to "finalized" elsewhere.
func (h *RotationCAHolder) FinalizeLocalRotation() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.outgoingCA = nil
}

// Pools returns the CertPool(s) this node should currently trust, given
// ONLY its own locally-known CA material: [outgoing, incoming] while a
// rotation is locally in progress (FR-008 dual trust), [issuing] alone
// otherwise (steady state, or after FinalizeLocalRotation) - fed
// directly into TrustStore.UpdateTrustedCAs by
// internal/api/routes_mtls.go's begin/finalize handlers and by
// cmd/llmctld/main.go's wireRevocationHandler (Feature 004 Phase 5,
// T023).
func (h *RotationCAHolder) Pools() []*x509.CertPool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.outgoingCA != nil {
		return []*x509.CertPool{caCertPool(h.outgoingCA), caCertPool(h.issuingCA)}
	}
	return []*x509.CertPool{caCertPool(h.issuingCA)}
}

func caCertPool(ca *CA) *x509.CertPool {
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(ca.CertPEM)
	return pool
}

// Fingerprint returns a stable, deterministic SHA-256 hex digest of ca's
// certificate PEM bytes - the value cluster.CARotationEvent's
// OutgoingCAFingerprint/IncomingCAFingerprint fields identify a CA by
// (research.md/data-model.md: "a stable hash of its cert, not the full
// PEM"). Deliberately a hash of the PEM bytes (never the private key,
// which this function never even receives - ca.KeyPEM is not read here)
// so the fingerprint can be freely carried through the Raft-replicated
// log without ever exposing - or even hashing - secret material.
func Fingerprint(ca *CA) string {
	sum := sha256.Sum256(ca.CertPEM)
	return hex.EncodeToString(sum[:])
}
