// Command fixture is the host-side counterpart used by tests/test_vantage.sh:
// an HTTPS server bound on a NON-loopback host address with a throw-away CA
// (plus an unrelated "wrong" CA), a listener on 127.0.0.1 and one on 0.0.0.0.
// Test-only; nothing it produces is trusted anywhere.
//
// (internal/server/internal/{servetest,testpki} cannot be imported from here:
// Go's internal rule scopes them to internal/server/..., and servetest binds
// loopback only, which a separate network location cannot reach.)
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

func newCA(cn string) (*x509.Certificate, *ecdsa.PrivateKey, []byte, error) {
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, nil, err
	}
	t := &x509.Certificate{SerialNumber: big.NewInt(time.Now().UnixNano()), Subject: pkix.Name{CommonName: cn},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(24 * time.Hour), IsCA: true,
		BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	der, err := x509.CreateCertificate(rand.Reader, t, t, &k.PublicKey, k)
	if err != nil {
		return nil, nil, nil, err
	}
	c, err := x509.ParseCertificate(der)
	return c, k, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), err
}

func main() {
	dir := flag.String("dir", "", "directory for ca.pem / wrong-ca.pem")
	ip := flag.String("ip", "", "non-loopback host address to bind the HTTPS server on")
	flag.Parse()
	if *dir == "" || *ip == "" {
		fmt.Fprintln(os.Stderr, "fixture: -dir and -ip are required")
		os.Exit(2)
	}
	if err := run(*dir, *ip); err != nil {
		fmt.Fprintln(os.Stderr, "fixture:", err)
		os.Exit(1)
	}
}

func run(dir, ip string) error {
	ca, caKey, caPEM, err := newCA("vantage fixture CA")
	if err != nil {
		return err
	}
	_, _, wrongPEM, err := newCA("vantage fixture WRONG CA")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "ca.pem"), caPEM, 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "wrong-ca.pem"), wrongPEM, 0o644); err != nil {
		return err
	}
	lk, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	lt := &x509.Certificate{SerialNumber: big.NewInt(time.Now().UnixNano() + 1), Subject: pkix.Name{CommonName: "fixture"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(24 * time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames: []string{"localhost"}, IPAddresses: []net.IP{net.ParseIP(ip), net.ParseIP("127.0.0.1")}}
	der, err := x509.CreateCertificate(rand.Reader, lt, ca, &lk.PublicKey, caKey)
	if err != nil {
		return err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/ok", func(w http.ResponseWriter, r *http.Request) { fmt.Fprintf(w, "ok from %s", r.RemoteAddr) })
	mux.HandleFunc("/unauthorized", func(w http.ResponseWriter, r *http.Request) { http.Error(w, "no key", http.StatusUnauthorized) })
	ln, err := tls.Listen("tcp", net.JoinHostPort(ip, "0"), &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: lk}}, MinVersion: tls.VersionTLS12})
	if err != nil {
		return err
	}
	go func() { _ = (&http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}).Serve(ln) }()
	lo, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	wild, err := net.Listen("tcp", "0.0.0.0:0")
	if err != nil {
		return err
	}
	for _, l := range []net.Listener{lo, wild} {
		go func(l net.Listener) {
			for {
				c, err := l.Accept()
				if err != nil {
					return
				}
				_ = c.Close()
			}
		}(l)
	}
	fmt.Printf("READY https://%s %d %d\n", ln.Addr(), lo.Addr().(*net.TCPAddr).Port, wild.Addr().(*net.TCPAddr).Port)
	_, _ = io.Copy(io.Discard, os.Stdin) // exits when the test closes stdin
	return nil
}
