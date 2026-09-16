package mtls

import (
	"crypto/tls"
	"crypto/x509"
	"sync"
	"testing"
)

// buildStoreFixture issues a real leaf cert from ca for nodeID and returns a
// *TrustStore trusting ONLY caPool and presenting that cert - the steady-
// state shape every TrustStore starts in.
func buildStoreFixture(t *testing.T, ca *CA, nodeID string) (*TrustStore, *x509.CertPool) {
	t.Helper()
	nodeCert, err := ca.IssueNodeCert(nodeID)
	if err != nil {
		t.Fatalf("IssueNodeCert(%q): %v", nodeID, err)
	}
	cert, err := LoadTLSCertificate(nodeCert.CertPEM, nodeCert.KeyPEM)
	if err != nil {
		t.Fatalf("LoadTLSCertificate(%q): %v", nodeID, err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(ca.CertPEM) {
		t.Fatalf("failed to add CA cert to pool")
	}
	store, err := NewTrustStore(pool, &cert)
	if err != nil {
		t.Fatalf("NewTrustStore(%q): %v", nodeID, err)
	}
	return store, pool
}

// TestTrustStore_Verify_RejectsRevokedSerial proves revocation is checked
// BEFORE chain validation (data-model.md): a certificate that would
// otherwise chain-validate cleanly against the store's trusted CA pool MUST
// be rejected once its serial number is added to the revoked set - the
// load-bearing property spec.md FR-001 needs ("every other node rejects a
// connection attempt presenting that identity").
func TestTrustStore_Verify_RejectsRevokedSerial(t *testing.T) {
	ca, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}
	store, _ := buildStoreFixture(t, ca, "node-owner")

	nodeCert, err := ca.IssueNodeCert("node-victim")
	if err != nil {
		t.Fatalf("IssueNodeCert(node-victim): %v", err)
	}
	leaf := parseCertPEM(t, nodeCert.CertPEM)
	rawCerts := [][]byte{leaf.Raw}

	if err := store.Verify(rawCerts); err != nil {
		t.Fatalf("Verify before revocation: unexpected error %v (cert should validate cleanly)", err)
	}

	store.UpdateRevoked(map[string]struct{}{leaf.SerialNumber.String(): {}})

	if err := store.Verify(rawCerts); err == nil {
		t.Fatalf("Verify after revoking serial %s: expected an error, got nil - a revoked certificate must be rejected", leaf.SerialNumber.String())
	}
}

// TestTrustStore_Verify_AcceptsEitherPoolDuringDualTrust proves FR-008: a
// certificate signed by EITHER the old or the new CA validates while the
// store is configured with both pools (the CA-rotation transition window).
func TestTrustStore_Verify_AcceptsEitherPoolDuringDualTrust(t *testing.T) {
	oldCA, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA (old): %v", err)
	}
	newCA, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA (new): %v", err)
	}

	store, oldPool := buildStoreFixture(t, oldCA, "node-a")
	newPool := x509.NewCertPool()
	if !newPool.AppendCertsFromPEM(newCA.CertPEM) {
		t.Fatalf("failed to add new CA cert to pool")
	}

	// Steady state: only oldPool is trusted, so a cert signed by newCA is
	// rejected.
	newCert, err := newCA.IssueNodeCert("node-b")
	if err != nil {
		t.Fatalf("IssueNodeCert(node-b) under newCA: %v", err)
	}
	newLeaf := parseCertPEM(t, newCert.CertPEM)
	if err := store.Verify([][]byte{newLeaf.Raw}); err == nil {
		t.Fatalf("expected a cert signed by newCA to be rejected before dual-trust is configured")
	}

	// Enter the dual-trust transition: both pools are now trusted.
	store.UpdateTrustedCAs([]*x509.CertPool{oldPool, newPool})

	if err := store.Verify([][]byte{newLeaf.Raw}); err != nil {
		t.Fatalf("Verify(newCA cert) during dual-trust: unexpected error %v", err)
	}

	oldCert, err := oldCA.IssueNodeCert("node-c")
	if err != nil {
		t.Fatalf("IssueNodeCert(node-c) under oldCA: %v", err)
	}
	oldLeaf := parseCertPEM(t, oldCert.CertPEM)
	if err := store.Verify([][]byte{oldLeaf.Raw}); err != nil {
		t.Fatalf("Verify(oldCA cert) during dual-trust: unexpected error %v", err)
	}
}

// TestTrustStore_ConcurrentReadWriteIsRaceFree drives concurrent Verify
// calls (the real handshake read path) against concurrent UpdateRevoked/
// UpdateTrustedCAs/UpdateNodeCert calls (the real FSM-driven write path) on
// the SAME TrustStore, matching the exact discipline that caught Phase 11's
// T073 concurrent-map-write bug in the adjacent ClusterFSM. Run under
// `go test -race`.
func TestTrustStore_ConcurrentReadWriteIsRaceFree(t *testing.T) {
	ca, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}
	store, pool := buildStoreFixture(t, ca, "node-concurrent")

	nodeCert, err := ca.IssueNodeCert("node-reader")
	if err != nil {
		t.Fatalf("IssueNodeCert: %v", err)
	}
	leaf := parseCertPEM(t, nodeCert.CertPEM)
	rawCerts := [][]byte{leaf.Raw}

	const iterations = 200
	var wg sync.WaitGroup
	wg.Add(4)

	go func() {
		defer wg.Done()
		for i := 0; i < iterations; i++ {
			_ = store.Verify(rawCerts)
		}
	}()
	go func() {
		defer wg.Done()
		for i := 0; i < iterations; i++ {
			store.UpdateRevoked(map[string]struct{}{})
		}
	}()
	go func() {
		defer wg.Done()
		for i := 0; i < iterations; i++ {
			store.UpdateTrustedCAs([]*x509.CertPool{pool})
		}
	}()
	go func() {
		defer wg.Done()
		for i := 0; i < iterations; i++ {
			cert, err := LoadTLSCertificate(nodeCert.CertPEM, nodeCert.KeyPEM)
			if err != nil {
				t.Errorf("LoadTLSCertificate: %v", err)
				return
			}
			store.UpdateNodeCert(&cert)
		}
	}()

	wg.Wait()
}

// TestTrustStore_GetCertificate_ReturnsCurrentNodeCert proves GetCertificate
// (the tls.Config.GetCertificate signature) returns the store's current
// node certificate, and that UpdateNodeCert swaps it for the NEXT call -
// the mechanism User Story 2's live renewal depends on.
func TestTrustStore_GetCertificate_ReturnsCurrentNodeCert(t *testing.T) {
	ca, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}
	firstCert, err := ca.IssueNodeCert("node-first")
	if err != nil {
		t.Fatalf("IssueNodeCert(node-first): %v", err)
	}
	first, err := LoadTLSCertificate(firstCert.CertPEM, firstCert.KeyPEM)
	if err != nil {
		t.Fatalf("LoadTLSCertificate(node-first): %v", err)
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(ca.CertPEM)
	store, err := NewTrustStore(pool, &first)
	if err != nil {
		t.Fatalf("NewTrustStore: %v", err)
	}

	got, err := store.GetCertificate(&tls.ClientHelloInfo{})
	if err != nil {
		t.Fatalf("GetCertificate: %v", err)
	}
	gotLeaf, err := x509.ParseCertificate(got.Certificate[0])
	if err != nil {
		t.Fatalf("parse returned cert: %v", err)
	}
	firstLeaf, err := x509.ParseCertificate(first.Certificate[0])
	if err != nil {
		t.Fatalf("parse expected cert: %v", err)
	}
	if gotLeaf.SerialNumber.Cmp(firstLeaf.SerialNumber) != 0 {
		t.Fatalf("GetCertificate returned a different cert than the one NewTrustStore was given")
	}

	secondCert, err := ca.IssueNodeCert("node-second")
	if err != nil {
		t.Fatalf("IssueNodeCert(node-second): %v", err)
	}
	second, err := LoadTLSCertificate(secondCert.CertPEM, secondCert.KeyPEM)
	if err != nil {
		t.Fatalf("LoadTLSCertificate(node-second): %v", err)
	}
	store.UpdateNodeCert(&second)

	got2, err := store.GetClientCertificate(&tls.CertificateRequestInfo{})
	if err != nil {
		t.Fatalf("GetClientCertificate after UpdateNodeCert: %v", err)
	}
	leaf2, err := x509.ParseCertificate(got2.Certificate[0])
	if err != nil {
		t.Fatalf("parse returned cert: %v", err)
	}
	leafExpected, err := x509.ParseCertificate(second.Certificate[0])
	if err != nil {
		t.Fatalf("parse expected cert: %v", err)
	}
	if leaf2.SerialNumber.Cmp(leafExpected.SerialNumber) != 0 {
		t.Fatalf("GetClientCertificate did not return the swapped-in cert after UpdateNodeCert")
	}
}

// TestNewTrustStore_RejectsNilCert proves the constructor fails fast on a
// genuine misconfiguration (Constitution §11.4.6: no invented default)
// rather than silently constructing a TrustStore that would make every real
// handshake fail once wired into a tls.Config.
func TestNewTrustStore_RejectsNilCert(t *testing.T) {
	pool := x509.NewCertPool()
	if _, err := NewTrustStore(pool, nil); err == nil {
		t.Fatalf("expected NewTrustStore(pool, nil) to fail, got nil error")
	}
}
