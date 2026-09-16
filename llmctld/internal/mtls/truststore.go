// Package mtls (truststore.go): the live, mutex-protected mTLS
// verification data source Feature 004 introduces to close T012/T075's
// disclosed boundary - internal/mtls/certs.go issues a CA and per-node
// leaf certificates once, loaded once into each process's tls.Config at
// startup, with no revocation mechanism and no rotation mechanism.
// TrustStore is the missing live layer: which CA(s) are currently
// trusted, which certificate serial numbers are revoked, and which
// certificate a transport itself currently presents - all mutable at
// runtime, all read fresh on every real TLS handshake.
package mtls

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"sync"
)

// TrustStore is the live, mutex-protected, per-process mTLS verification
// data source every tls.Config-consuming transport in llmctld (internal/
// raft's QUIC transport, internal/api's HTTP/3 server) reads from on EVERY
// real TLS handshake via tls.Config.VerifyPeerCertificate/GetCertificate/
// GetClientCertificate - all three are re-invoked fresh per handshake
// (Go's own documented crypto/tls behavior, confirmed against the real
// package source before writing this file, exactly as this codebase's
// existing VerifyPeerCertificate closure already relied on for its own
// per-handshake CA-pool check in internal/raft/transport.go), so updating
// a TrustStore's data live takes effect for the very next connection
// attempt with zero process restart and zero tls.Config/listener rebuild -
// research.md Decision 2's confirmed mechanism.
//
// mu guards every field below with a sync.RWMutex, not the plain
// sync.Mutex internal/raft/fsm.go's ClusterFSM uses for its own,
// differently-shaped concurrency problem: TrustStore's read path (Verify,
// GetCertificate, GetClientCertificate) runs on EVERY real handshake -
// frequent, and read-only - while writes (UpdateRevoked, UpdateTrustedCAs,
// UpdateNodeCert) happen only on a Raft-applied revocation/renewal/
// rotation event - comparatively rare. A plain Mutex would needlessly
// serialize concurrent handshakes against each other; RWMutex lets them
// proceed in parallel while still fully serializing against a write. This
// is exactly the concurrency-safety property
// TestTrustStore_ConcurrentReadWriteIsRaceFree proves under `go test
// -race`, matching the discipline that caught (fsm.go's own doc comment)
// a real `fatal error: concurrent map writes` crash in the adjacent
// ClusterFSM during Phase 11's T073.
type TrustStore struct {
	mu sync.RWMutex

	// trustedCAPools holds exactly one entry in steady state, exactly two
	// during a CA-rotation transition (old + new, FR-008) - a presented
	// certificate chaining to ANY pool in this slice is chain-valid
	// (data-model.md).
	trustedCAPools []*x509.CertPool
	// revokedSerials is keyed by x509.Certificate.SerialNumber.String() -
	// checked FIRST in Verify, before chain validation, so a revoked
	// serial is rejected regardless of which pool it would otherwise
	// chain to (data-model.md, spec.md FR-001).
	revokedSerials map[string]struct{}
	// currentNodeCert is this transport's own currently-active
	// certificate+key, read by GetCertificate/GetClientCertificate on
	// every new handshake - swapped in place on renewal (User Story 2),
	// never requiring a new tls.Config or listener.
	currentNodeCert *tls.Certificate
}

// NewTrustStore returns a TrustStore trusting initialCAPool as its only
// currently-trusted CA and presenting initialCert as this transport's own
// certificate - the steady-state shape every node/transport starts in
// before any revocation/renewal/rotation action is ever issued.
// initialCert MUST NOT be nil - a TrustStore backing a real tls.Config's
// GetCertificate/GetClientCertificate callbacks with no certificate to
// return would make every real handshake fail, which is never a state
// this constructor should silently produce (Constitution §11.4.6: no
// invented default, fail fast on a genuine misconfiguration instead).
func NewTrustStore(initialCAPool *x509.CertPool, initialCert *tls.Certificate) (*TrustStore, error) {
	if initialCert == nil {
		return nil, fmt.Errorf("mtls: NewTrustStore: initialCert must not be nil")
	}
	return &TrustStore{
		trustedCAPools:  []*x509.CertPool{initialCAPool},
		revokedSerials:  make(map[string]struct{}),
		currentNodeCert: initialCert,
	}, nil
}

// UpdateRevoked REPLACES the entire set of currently-revoked certificate
// serial numbers. Callers pass the FULL current set (e.g. every serial the
// Raft-replicated cluster state currently lists as revoked), never a
// delta - so a lost or duplicated update can never leave a TrustStore out
// of sync with the replicated source of truth it mirrors.
func (s *TrustStore) UpdateRevoked(serials map[string]struct{}) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.revokedSerials = serials
}

// UpdateTrustedCAs REPLACES the set of currently-trusted CA pools -
// exactly one in steady state, exactly two during a CA-rotation
// transition (FR-008).
func (s *TrustStore) UpdateTrustedCAs(pools []*x509.CertPool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.trustedCAPools = pools
}

// UpdateNodeCert swaps this transport's own currently-presented
// certificate. Read by GetCertificate/GetClientCertificate on every NEW
// handshake going forward; an already-established connection is
// unaffected (neither callback is invoked again for a connection that
// already completed its handshake), which is exactly User Story 2's
// zero-downtime requirement.
func (s *TrustStore) UpdateNodeCert(cert *tls.Certificate) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.currentNodeCert = cert
}

// GetCertificate implements the tls.Config.GetCertificate signature -
// wire it directly: tlsConf.GetCertificate = store.GetCertificate.
func (s *TrustStore) GetCertificate(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.currentNodeCert == nil {
		return nil, fmt.Errorf("mtls: TrustStore has no current node certificate")
	}
	return s.currentNodeCert, nil
}

// GetClientCertificate implements the tls.Config.GetClientCertificate
// signature - wire it directly: tlsConf.GetClientCertificate =
// store.GetClientCertificate.
func (s *TrustStore) GetClientCertificate(*tls.CertificateRequestInfo) (*tls.Certificate, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.currentNodeCert == nil {
		return nil, fmt.Errorf("mtls: TrustStore has no current node certificate")
	}
	return s.currentNodeCert, nil
}

// Verify is the real certificate-verification logic
// internal/raft.VerifyPeerCertificateAgainstCA's closure now delegates to
// (data-model.md): parse the presented leaf certificate, reject
// immediately if its serial number is revoked - checked BEFORE chain
// validation, so a revoked certificate is rejected regardless of which
// trusted CA pool it would otherwise chain to - then verify the chain
// against ANY ONE of the currently-trusted CA pools (exactly one in
// steady state, exactly two during a CA-rotation transition, FR-008).
func (s *TrustStore) Verify(rawCerts [][]byte) error {
	if len(rawCerts) == 0 {
		return fmt.Errorf("mtls: no peer certificate presented")
	}
	leaf, err := x509.ParseCertificate(rawCerts[0])
	if err != nil {
		return fmt.Errorf("mtls: parse peer certificate: %w", err)
	}

	s.mu.RLock()
	_, revoked := s.revokedSerials[leaf.SerialNumber.String()]
	pools := s.trustedCAPools
	s.mu.RUnlock()

	if revoked {
		return fmt.Errorf("mtls: peer certificate serial %s is revoked", leaf.SerialNumber.String())
	}

	intermediates := x509.NewCertPool()
	for _, raw := range rawCerts[1:] {
		cert, err := x509.ParseCertificate(raw)
		if err != nil {
			return fmt.Errorf("mtls: parse peer intermediate certificate: %w", err)
		}
		intermediates.AddCert(cert)
	}

	var lastErr error
	for _, pool := range pools {
		if pool == nil {
			continue
		}
		if _, verr := leaf.Verify(x509.VerifyOptions{
			Roots:         pool,
			Intermediates: intermediates,
			KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
		}); verr == nil {
			return nil
		} else {
			lastErr = verr
		}
	}
	if lastErr == nil {
		lastErr = fmt.Errorf("no trusted CA pool configured")
	}
	return fmt.Errorf("mtls: peer certificate does not chain to any trusted CA: %w", lastErr)
}
