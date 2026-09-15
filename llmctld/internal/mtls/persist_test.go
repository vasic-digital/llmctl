package mtls

import (
	"crypto/x509"
	"testing"
)

// TestCA_KeyPEM_IsPresentAndUsableToReloadTheCA proves a CA exposes its
// private-key PEM (needed to PERSIST + later RELOAD a CA across process
// boundaries - the real requirement multiple llmctld processes sharing
// one trust root have: each process self-issues its own node cert from
// the SAME CA, which requires that CA's private key, not merely its
// public certificate).
func TestCA_KeyPEM_IsPresentAndUsableToReloadTheCA(t *testing.T) {
	ca, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}
	if len(ca.KeyPEM) == 0 {
		t.Fatalf("ca.KeyPEM is empty - a generated CA must expose its private key for persistence")
	}
}

// TestLoadCA_ReloadedCAIssuesCertsIndistinguishableFromTheOriginal proves
// LoadCA reconstructs a fully-functional CA: a cert issued by the
// RELOADED CA verifies against a pool built from the ORIGINAL CA's
// CertPEM (they are the same CA, just reconstructed from its own PEM
// bytes) - the real end-to-end proof, not merely "LoadCA returns no
// error".
func TestLoadCA_ReloadedCAIssuesCertsIndistinguishableFromTheOriginal(t *testing.T) {
	original, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}

	reloaded, err := LoadCA(original.CertPEM, original.KeyPEM)
	if err != nil {
		t.Fatalf("LoadCA: %v", err)
	}

	nodeCert, err := reloaded.IssueNodeCert("node-from-reloaded-ca")
	if err != nil {
		t.Fatalf("reloaded.IssueNodeCert: %v", err)
	}

	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(original.CertPEM) {
		t.Fatalf("failed to add original CA cert to pool")
	}
	leaf := parseCertPEM(t, nodeCert.CertPEM)
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: pool, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny}}); err != nil {
		t.Fatalf("a cert issued by the RELOADED CA does not verify against the ORIGINAL CA's cert pool: %v", err)
	}
}

// TestLoadCA_RejectsMismatchedKeyAndCert proves LoadCA does not silently
// accept a cert/key pair that do not actually belong together.
func TestLoadCA_RejectsMismatchedKeyAndCert(t *testing.T) {
	ca1, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA (ca1): %v", err)
	}
	ca2, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA (ca2): %v", err)
	}

	if _, err := LoadCA(ca1.CertPEM, ca2.KeyPEM); err == nil {
		t.Fatalf("LoadCA accepted a cert and key from two DIFFERENT CAs without error")
	}
}
