package mtls

import (
	"crypto/x509"
	"encoding/pem"
	"testing"
)

func parseCertPEM(t *testing.T, certPEM []byte) *x509.Certificate {
	t.Helper()
	block, _ := pem.Decode(certPEM)
	if block == nil {
		t.Fatalf("failed to PEM-decode certificate")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatalf("failed to parse certificate: %v", err)
	}
	return cert
}

// TestIssueNodeCert_ValidatesAgainstItsOwnCA proves the basic mTLS
// precondition: a leaf certificate issued by a CA verifies successfully
// against that same CA's certificate.
func TestIssueNodeCert_ValidatesAgainstItsOwnCA(t *testing.T) {
	ca, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}

	nodeCert, err := ca.IssueNodeCert("node-1")
	if err != nil {
		t.Fatalf("IssueNodeCert: %v", err)
	}

	pool := x509.NewCertPool()
	if ok := pool.AppendCertsFromPEM(ca.CertPEM); !ok {
		t.Fatalf("failed to add CA cert to pool")
	}

	leaf := parseCertPEM(t, nodeCert.CertPEM)
	if _, err := leaf.Verify(x509.VerifyOptions{
		Roots:     pool,
		KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
	}); err != nil {
		t.Fatalf("expected node cert to verify against its own CA, got error: %v", err)
	}
}

// TestIssueNodeCert_RejectedByADifferentCA proves the negative case: the
// same leaf certificate MUST NOT verify against an unrelated CA's pool -
// this is what makes mutual TLS meaningful (a node cannot fake membership
// by presenting a cert signed by a different, untrusted authority).
func TestIssueNodeCert_RejectedByADifferentCA(t *testing.T) {
	ca1, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA (ca1): %v", err)
	}
	ca2, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA (ca2): %v", err)
	}

	nodeCert, err := ca1.IssueNodeCert("node-1")
	if err != nil {
		t.Fatalf("IssueNodeCert: %v", err)
	}

	otherPool := x509.NewCertPool()
	if ok := otherPool.AppendCertsFromPEM(ca2.CertPEM); !ok {
		t.Fatalf("failed to add ca2 cert to pool")
	}

	leaf := parseCertPEM(t, nodeCert.CertPEM)
	if _, err := leaf.Verify(x509.VerifyOptions{
		Roots:     otherPool,
		KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
	}); err == nil {
		t.Fatalf("expected node cert signed by ca1 to be REJECTED by ca2's pool, but it verified")
	}
}

// TestIssueNodeCert_KeyPEMIsUsableTLSKeyPair proves the issued cert+key can
// actually be loaded as a tls.Certificate (the real consumption path in
// internal/raft/transport.go and internal/api/server.go), not just
// structurally-valid-looking PEM.
func TestIssueNodeCert_KeyPEMIsUsableTLSKeyPair(t *testing.T) {
	ca, err := GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}
	nodeCert, err := ca.IssueNodeCert("node-1")
	if err != nil {
		t.Fatalf("IssueNodeCert: %v", err)
	}
	if _, err := LoadTLSCertificate(nodeCert.CertPEM, nodeCert.KeyPEM); err != nil {
		t.Fatalf("issued cert/key pair is not a usable tls.Certificate: %v", err)
	}
}
