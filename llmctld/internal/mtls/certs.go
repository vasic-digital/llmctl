// Package mtls bootstraps an internal certificate authority and issues
// per-node leaf certificates for llmctld's node-to-node Raft/replication
// traffic (Clarification 11: mutual TLS for internal traffic, JWT bearer
// tokens for client-facing traffic).
package mtls

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"time"
)

// certValidity is deliberately generous for a first implementation;
// rotation is a tracked follow-up (see the "New Files This Plan
// Introduces" design note in tasks.md - Phase 2 lands the primitive,
// rotation is not yet wired into the node lifecycle).
const certValidity = 365 * 24 * time.Hour

// CA is a self-signed internal certificate authority used to sign every
// node's leaf certificate, so node-to-node mTLS trusts exactly this CA and
// nothing else.
type CA struct {
	cert    *x509.Certificate
	key     *ecdsa.PrivateKey
	CertPEM []byte
	// KeyPEM is the CA's private-key PEM encoding, exposed so a CA can be
	// PERSISTED to disk and RELOADED via LoadCA - the real requirement
	// multiple llmctld processes sharing one trust root have (each
	// process self-issues its own node cert from the SAME CA, which
	// requires that CA's private key, not merely its public certificate).
	KeyPEM []byte
}

// NodeCert is one node's leaf certificate + private key, both PEM-encoded
// and ready to load via LoadTLSCertificate.
type NodeCert struct {
	CertPEM []byte
	KeyPEM  []byte
}

// GenerateCA creates a new self-signed CA (ECDSA P-256 - fast to generate,
// fully supported by crypto/tls).
func GenerateCA() (*CA, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("mtls: generate CA key: %w", err)
	}

	serial, err := randomSerial()
	if err != nil {
		return nil, err
	}

	template := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "llmctld internal CA"},
		NotBefore:             time.Now().Add(-time.Hour), // clock-skew tolerance
		NotAfter:              time.Now().Add(certValidity),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}

	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return nil, fmt.Errorf("mtls: create CA certificate: %w", err)
	}

	cert, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, fmt.Errorf("mtls: parse freshly-created CA certificate: %w", err)
	}

	keyBytes, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return nil, fmt.Errorf("mtls: marshal CA key: %w", err)
	}

	return &CA{
		cert:    cert,
		key:     key,
		CertPEM: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		KeyPEM:  pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyBytes}),
	}, nil
}

// LoadCA reconstructs a CA from its previously-persisted CertPEM/KeyPEM
// (e.g. GenerateCA's own output, written to disk by one process and read
// back by another so multiple llmctld processes can share one trust
// root). Returns an error if certPEM/keyPEM are malformed OR if the key
// genuinely does not belong to the certificate - verified via
// tls.X509KeyPair, which Go's own crypto/tls source confirms compares the
// private key's public half against the certificate's public key
// (crypto/tls/tls.go's X509KeyPair, not assumed).
func LoadCA(certPEM, keyPEM []byte) (*CA, error) {
	if _, err := tls.X509KeyPair(certPEM, keyPEM); err != nil {
		return nil, fmt.Errorf("mtls: load CA: certificate and key do not match: %w", err)
	}

	certBlock, _ := pem.Decode(certPEM)
	if certBlock == nil {
		return nil, fmt.Errorf("mtls: load CA: failed to PEM-decode certificate")
	}
	cert, err := x509.ParseCertificate(certBlock.Bytes)
	if err != nil {
		return nil, fmt.Errorf("mtls: load CA: parse certificate: %w", err)
	}

	keyBlock, _ := pem.Decode(keyPEM)
	if keyBlock == nil {
		return nil, fmt.Errorf("mtls: load CA: failed to PEM-decode private key")
	}
	key, err := x509.ParseECPrivateKey(keyBlock.Bytes)
	if err != nil {
		return nil, fmt.Errorf("mtls: load CA: parse EC private key: %w", err)
	}

	return &CA{cert: cert, key: key, CertPEM: certPEM, KeyPEM: keyPEM}, nil
}

// IssueNodeCert issues a leaf certificate for nodeID, signed by this CA.
// The returned certificate validates against a pool containing ONLY this
// CA's certificate - it is rejected by any other CA's pool (proven by
// TestIssueNodeCert_RejectedByADifferentCA), which is the property that
// makes node-to-node mTLS meaningful.
func (ca *CA) IssueNodeCert(nodeID string) (*NodeCert, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("mtls: generate node key for %q: %w", nodeID, err)
	}

	serial, err := randomSerial()
	if err != nil {
		return nil, err
	}

	template := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: nodeID},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(certValidity),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth},
	}

	der, err := x509.CreateCertificate(rand.Reader, template, ca.cert, &key.PublicKey, ca.key)
	if err != nil {
		return nil, fmt.Errorf("mtls: sign node certificate for %q: %w", nodeID, err)
	}

	keyBytes, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return nil, fmt.Errorf("mtls: marshal node key for %q: %w", nodeID, err)
	}

	return &NodeCert{
		CertPEM: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		KeyPEM:  pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyBytes}),
	}, nil
}

// LoadTLSCertificate loads a PEM cert+key pair into a tls.Certificate,
// ready for tls.Config.Certificates - the real consumption path in
// internal/raft/transport.go and internal/api/server.go.
func LoadTLSCertificate(certPEM, keyPEM []byte) (tls.Certificate, error) {
	return tls.X509KeyPair(certPEM, keyPEM)
}

func randomSerial() (*big.Int, error) {
	limit := new(big.Int).Lsh(big.NewInt(1), 128)
	serial, err := rand.Int(rand.Reader, limit)
	if err != nil {
		return nil, fmt.Errorf("mtls: generate serial number: %w", err)
	}
	return serial, nil
}
