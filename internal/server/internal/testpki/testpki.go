// Package testpki generates a throw-away certificate authority and a server
// certificate (standard library only) for tests of the TLS server. It is never
// used outside tests and test helpers; nothing it produces is trusted anywhere.
package testpki

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"time"
)

// PKI is a CA plus a leaf (server) certificate it signed.
type PKI struct {
	CAPEM []byte            // PEM of the CA certificate (what a client trusts)
	Pool  *x509.CertPool    // pool containing the CA
	Cert  tls.Certificate   // leaf + key, ready for tls.Config.Certificates
	Leaf  *x509.Certificate // parsed leaf
}

// Options tune New.
type Options struct {
	NotBefore time.Time // zero = one hour ago
	NotAfter  time.Time // zero = 24 h from now
	DNS       []string  // default: localhost
	IPs       []net.IP  // default: 127.0.0.1, ::1
}

// New creates a CA and a leaf signed by it.
func New(o Options) (*PKI, error) {
	if o.NotBefore.IsZero() {
		o.NotBefore = time.Now().Add(-time.Hour)
	}
	if o.NotAfter.IsZero() {
		o.NotAfter = time.Now().Add(24 * time.Hour)
	}
	if o.DNS == nil {
		o.DNS = []string{"localhost"}
	}
	if o.IPs == nil {
		o.IPs = []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")}
	}
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	caTmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "llmctl test CA"},
		NotBefore:             o.NotBefore,
		NotAfter:              o.NotAfter,
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTmpl, caTmpl, &caKey.PublicKey, caKey)
	if err != nil {
		return nil, err
	}
	ca, err := x509.ParseCertificate(caDER)
	if err != nil {
		return nil, err
	}
	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	leafTmpl := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: "llmctl test server"},
		NotBefore:    o.NotBefore,
		NotAfter:     o.NotAfter,
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     o.DNS,
		IPAddresses:  o.IPs,
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTmpl, ca, &leafKey.PublicKey, caKey)
	if err != nil {
		return nil, err
	}
	leaf, err := x509.ParseCertificate(leafDER)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	pool.AddCert(ca)
	return &PKI{
		CAPEM: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER}),
		Pool:  pool,
		Cert:  tls.Certificate{Certificate: [][]byte{leafDER}, PrivateKey: leafKey, Leaf: leaf},
		Leaf:  leaf,
	}, nil
}
