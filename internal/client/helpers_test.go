package client

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/internal/keyring"
)

const testKey = "k3y-0123456789abcdefghijklmnopqrstuvwxyz-ABCDEFGH"

// caFile writes the certificate of an httptest TLS server as a PEM CA file (the server's
// self-signed leaf is its own trust anchor) and returns the path.
func caFile(t *testing.T, srv *httptest.Server) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "ca.crt")
	b := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: srv.Certificate().Raw})
	if err := os.WriteFile(p, b, 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

// newTestClient builds a client for srv trusting srv's own certificate, with a recording fake
// sleep so retry tests never wait.
func newTestClient(t *testing.T, srv *httptest.Server, mut func(*Config)) (*Client, *[]time.Duration) {
	t.Helper()
	slept := &[]time.Duration{}
	cfg := Config{
		Endpoint: srv.URL, CAFile: caFile(t, srv), Key: keyring.NewSecret(testKey), Retries: 2,
		Timeout: 5 * time.Second,
		Sleep: func(_ context.Context, d time.Duration) error {
			*slept = append(*slept, d)
			return nil
		},
	}
	if mut != nil {
		mut(&cfg)
	}
	c, err := New(cfg)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return c, slept
}

func jsonHandler(status int, body string, hdr map[string]string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		for k, v := range hdr {
			w.Header().Set(k, v)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}
}

func kindOf(err error) Kind {
	if e, ok := err.(*Error); ok {
		return e.Kind
	}
	return 0
}

func writeFile(p, s string) error { return os.WriteFile(p, []byte(s), 0o600) }

// otherCAFile writes an unrelated self-signed CA certificate (httptest servers all share one
// built-in certificate, so a second httptest server cannot play "the wrong CA").
func otherCAFile(t *testing.T) string {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{SerialNumber: big.NewInt(7), Subject: pkix.Name{CommonName: "unrelated CA"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true,
		KeyUsage: x509.KeyUsageCertSign}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &k.PublicKey, k)
	if err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(t.TempDir(), "other.crt")
	if err := os.WriteFile(p, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}
