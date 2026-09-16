// Package mtls (rotation_test.go): TDD RED-then-GREEN unit tests for
// Feature 004 Phase 5 (User Story 3)'s RotationCAHolder + Fingerprint -
// the LOCAL, per-node, in-memory holder of which CA a node currently
// issues fresh certificates from, and the mechanism by which a node
// rebuilds its own dual-trust (or single-trust) CertPool set from
// out-of-band-loaded CA material, matching truststore_test.go's exact
// real-cert-issuance test style (no mocks - genuine *CA/*tls.Certificate
// values throughout, per Constitution §11.4.27).
package mtls

import (
	"crypto/x509"
	"testing"
)

// TestFingerprint_StableForSameCert proves Fingerprint is deterministic:
// the same CA's certificate always hashes to the same value.
func TestFingerprint_StableForSameCert(t *testing.T) {
	ca, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}
	fp1 := Fingerprint(ca)
	fp2 := Fingerprint(ca)
	if fp1 == "" {
		t.Fatalf("Fingerprint returned an empty string")
	}
	if fp1 != fp2 {
		t.Fatalf("Fingerprint(ca) is not stable across calls: %q != %q", fp1, fp2)
	}
}

// TestFingerprint_DiffersForDifferentCAs proves two independently
// generated CAs never collide - the property data-model.md's "identifies
// the CA being retired/incoming" relies on.
func TestFingerprint_DiffersForDifferentCAs(t *testing.T) {
	ca1, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA (1): %v", err)
	}
	ca2, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA (2): %v", err)
	}
	if Fingerprint(ca1) == Fingerprint(ca2) {
		t.Fatalf("Fingerprint collided for two independently generated CAs")
	}
}

// TestRotationCAHolder_SteadyStateReturnsSinglePool proves a freshly
// constructed holder (before any local rotation begins) returns exactly
// one CertPool - the pre-rotation steady state every node starts in.
func TestRotationCAHolder_SteadyStateReturnsSinglePool(t *testing.T) {
	ca, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}
	h := NewRotationCAHolder(ca)

	if got := h.IssuingCA(); got != ca {
		t.Fatalf("IssuingCA() before any rotation must be the constructor's initial CA")
	}
	if h.InProgress() {
		t.Fatalf("InProgress() must be false before BeginLocalRotation is ever called")
	}
	pools := h.Pools()
	if len(pools) != 1 {
		t.Fatalf("Pools() in steady state = %d pools, want exactly 1", len(pools))
	}
	if !poolTrusts(t, pools[0], ca) {
		t.Fatalf("the single steady-state pool does not trust the constructor's own CA")
	}
}

// TestRotationCAHolder_BeginLocalRotation_ReturnsDualPools proves
// BeginLocalRotation activates dual trust: BOTH the outgoing (previous)
// and incoming CA's pools are returned, and IssuingCA() switches to the
// incoming CA (so future renewals issue under the NEW CA - Acceptance
// Scenario 2/3's "each node individually re-issued under the new CA").
func TestRotationCAHolder_BeginLocalRotation_ReturnsDualPools(t *testing.T) {
	oldCA, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA (old): %v", err)
	}
	newCA, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA (new): %v", err)
	}
	h := NewRotationCAHolder(oldCA)

	h.BeginLocalRotation(newCA)

	if !h.InProgress() {
		t.Fatalf("InProgress() must be true after BeginLocalRotation")
	}
	if got := h.IssuingCA(); got != newCA {
		t.Fatalf("IssuingCA() after BeginLocalRotation must be the INCOMING CA - future renewals must issue under the new CA")
	}
	pools := h.Pools()
	if len(pools) != 2 {
		t.Fatalf("Pools() during an in-progress rotation = %d pools, want exactly 2 (FR-008 dual trust)", len(pools))
	}
	trustsOld, trustsNew := false, false
	for _, p := range pools {
		if poolTrusts(t, p, oldCA) {
			trustsOld = true
		}
		if poolTrusts(t, p, newCA) {
			trustsNew = true
		}
	}
	if !trustsOld || !trustsNew {
		t.Fatalf("dual-trust pools must trust BOTH the old CA (%v) and the new CA (%v)", trustsOld, trustsNew)
	}
}

// TestRotationCAHolder_BeginLocalRotation_IdempotentPreservesOutgoing
// proves calling BeginLocalRotation a second time (e.g. an operator's
// begin-rotation API call retried, or issued a second time by mistake
// against the same rotation) never clobbers the ORIGINAL outgoing CA -
// only the very first outgoing CA is the one dual trust must keep
// accepting.
func TestRotationCAHolder_BeginLocalRotation_IdempotentPreservesOutgoing(t *testing.T) {
	oldCA, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA (old): %v", err)
	}
	newCA, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA (new): %v", err)
	}
	h := NewRotationCAHolder(oldCA)
	h.BeginLocalRotation(newCA)
	// A second call with the SAME incoming CA must not treat newCA as the
	// new "outgoing" CA - it must remain oldCA.
	h.BeginLocalRotation(newCA)

	pools := h.Pools()
	found := false
	for _, p := range pools {
		if poolTrusts(t, p, oldCA) {
			found = true
		}
	}
	if !found {
		t.Fatalf("a repeated BeginLocalRotation call must not lose trust in the ORIGINAL outgoing CA")
	}
}

// TestRotationCAHolder_FinalizeLocalRotation_DropsToSinglePool proves
// FinalizeLocalRotation returns the holder to a single-pool steady state
// trusting ONLY the (now-current) incoming CA - the outgoing CA is no
// longer trusted, per spec.md Acceptance Scenario 3 ("the old CA is no
// longer trusted by any node").
func TestRotationCAHolder_FinalizeLocalRotation_DropsToSinglePool(t *testing.T) {
	oldCA, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA (old): %v", err)
	}
	newCA, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA (new): %v", err)
	}
	h := NewRotationCAHolder(oldCA)
	h.BeginLocalRotation(newCA)

	h.FinalizeLocalRotation()

	if h.InProgress() {
		t.Fatalf("InProgress() must be false after FinalizeLocalRotation")
	}
	pools := h.Pools()
	if len(pools) != 1 {
		t.Fatalf("Pools() after finalize = %d pools, want exactly 1", len(pools))
	}
	if poolTrusts(t, pools[0], oldCA) {
		t.Fatalf("the single post-finalize pool must NOT trust the retired outgoing CA")
	}
	if !poolTrusts(t, pools[0], newCA) {
		t.Fatalf("the single post-finalize pool must trust the (now current) incoming CA")
	}
}

// TestRotationCAHolder_FinalizeLocalRotation_NoOpWhenNeverBegun proves
// finalizing a holder that never locally began a rotation is a harmless
// no-op - the honest limitation this type's own doc comment discloses: a
// node that was never told the incoming CA's material out-of-band cannot
// be made to trust it merely by a Raft-replicated "finalized" status.
func TestRotationCAHolder_FinalizeLocalRotation_NoOpWhenNeverBegun(t *testing.T) {
	ca, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}
	h := NewRotationCAHolder(ca)

	h.FinalizeLocalRotation()

	if h.InProgress() {
		t.Fatalf("InProgress() must stay false")
	}
	pools := h.Pools()
	if len(pools) != 1 || !poolTrusts(t, pools[0], ca) {
		t.Fatalf("Pools() after a no-op finalize must be unchanged (single pool trusting the original CA), got %d pools", len(pools))
	}
}

// poolTrusts reports whether pool contains ca's own certificate, proven
// by real x509 verification (never by pointer/string comparison) - a
// leaf issued by ca must chain-validate against pool. Reuses
// certs_test.go's own parseCertPEM helper (this package's established
// PEM-to-*x509.Certificate test pattern).
func poolTrusts(t *testing.T, pool *x509.CertPool, ca *CA) bool {
	t.Helper()
	leaf, err := ca.IssueNodeCert("pool-trust-probe")
	if err != nil {
		t.Fatalf("IssueNodeCert(pool-trust-probe): %v", err)
	}
	cert := parseCertPEM(t, leaf.CertPEM)
	_, err = cert.Verify(x509.VerifyOptions{Roots: pool, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny}})
	return err == nil
}
