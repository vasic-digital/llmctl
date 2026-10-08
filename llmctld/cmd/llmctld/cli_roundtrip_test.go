package main

import (
	"crypto/tls"
	"crypto/x509"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/quic-go/quic-go/http3"

	"github.com/vasic-digital/llmctl/llmctld/internal/api"
	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
	"github.com/vasic-digital/llmctl/llmctld/internal/raft"
)

// G-106 (OD-21 / T131): the opt-in llmctld cluster daemon is reached by
// lib/cluster.sh through curl --http3 with `--cacert ca.crt --cert client.crt
// --key client.key` and FULL verification (no -k). These tests perform the
// SAME round trip with a Go HTTP/3 client whose crypto/tls config is exactly
// what curl does: RootCAs = only the cluster CA, ServerName = the host in the
// URL (so SANs are enforced), client certificate presented from files on
// disk, InsecureSkipVerify never set. A real curl with an HTTP/3 build is
// not available on the development host (Features line has no HTTP3); the
// transport (QUIC + HTTP/3) and the TLS verification inputs are identical.

// startDaemonLikeServer boots a real raft node + the real api.Server with
// the SAME buildNodeTLSConfig the daemon uses for its API listener, after
// the daemon's own SAN configuration step (configureCertSANs) and returns
// the server address plus the directory holding the CLI material the daemon
// wrote for the shell client.
func startDaemonLikeServer(t *testing.T, apiBind string, advertise []string) (addr, cliDir string, ca *mtls.CA) {
	t.Helper()
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}
	if err := configureCertSANs(apiBind, advertise); err != nil {
		t.Fatalf("configureCertSANs: %v", err)
	}
	t.Cleanup(func() { mtls.SetExtraSANs() })

	raftTLS, _, err := buildNodeTLSConfig(ca, "node-a")
	if err != nil {
		t.Fatalf("buildNodeTLSConfig raft: %v", err)
	}
	node, err := raft.Bootstrap(raft.Config{NodeID: "node-a", BindAddr: "127.0.0.1:0", TLSConfig: raftTLS})
	if err != nil {
		t.Fatalf("raft.Bootstrap: %v", err)
	}
	t.Cleanup(func() { _ = node.Shutdown() })
	deadline := time.Now().Add(5 * time.Second)
	for !node.IsLeader() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if !node.IsLeader() {
		t.Fatal("node never became leader")
	}

	apiTLS, _, err := buildNodeTLSConfig(ca, "node-a-api")
	if err != nil {
		t.Fatalf("buildNodeTLSConfig api: %v", err)
	}
	srv := api.NewServer(node, apiTLS)
	if err := srv.Listen("127.0.0.1:0"); err != nil {
		t.Fatalf("Listen: %v", err)
	}
	t.Cleanup(func() { _ = srv.Close() })

	cliDir = filepath.Join(t.TempDir(), "cli")
	if err := writeCLIMaterial(cliDir, ca); err != nil {
		t.Fatalf("writeCLIMaterial: %v", err)
	}
	return srv.Addr, cliDir, ca
}

// curlLikeClient builds the client side exactly as lib/cluster.sh configures
// curl: trust ONLY ca.crt from disk, present client.crt/client.key from
// disk, verify the server name against the URL host. serverName is what the
// URL host would be (curl derives it from the URL).
func curlLikeClient(t *testing.T, caPath, certPath, keyPath, serverName string) *http.Client {
	t.Helper()
	caPEM, err := os.ReadFile(caPath)
	if err != nil {
		t.Fatalf("read ca: %v", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		t.Fatal("ca.crt contains no certificate")
	}
	cfg := &tls.Config{RootCAs: pool, ServerName: serverName, NextProtos: []string{"llmctld-api/1"}}
	if certPath != "" {
		cert, err := tls.LoadX509KeyPair(certPath, keyPath)
		if err != nil {
			t.Fatalf("load client keypair: %v", err)
		}
		cfg.Certificates = []tls.Certificate{cert}
	}
	if cfg.InsecureSkipVerify {
		t.Fatal("test bug: verification must stay on")
	}
	return &http.Client{Transport: &http3.Transport{TLSClientConfig: cfg}, Timeout: 5 * time.Second}
}

func get(t *testing.T, c *http.Client, url string) (int, string, error) {
	t.Helper()
	resp, err := c.Get(url)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b), nil
}

func TestCLIRoundTrip_StrictVerification_Succeeds(t *testing.T) {
	addr, dir, _ := startDaemonLikeServer(t, "127.0.0.1:0", nil)
	_, port, _ := net.SplitHostPort(addr)
	c := curlLikeClient(t, filepath.Join(dir, "ca.crt"), filepath.Join(dir, "client.crt"), filepath.Join(dir, "client.key"), "127.0.0.1")
	code, body, err := get(t, c, "https://127.0.0.1:"+port+"/v1/cluster/status")
	if err != nil {
		t.Fatalf("round trip with strict verification failed: %v", err)
	}
	if code != 200 || !strings.Contains(body, "is_leader") {
		t.Fatalf("status = %d body = %q, want 200 with is_leader", code, body)
	}
}

func TestCLIRoundTrip_AllLoopbackNamesAreCovered(t *testing.T) {
	addr, dir, _ := startDaemonLikeServer(t, "127.0.0.1:0", nil)
	_, port, _ := net.SplitHostPort(addr)
	for _, name := range []string{"127.0.0.1", "localhost", "[::1]"} {
		host := strings.Trim(name, "[]")
		c := curlLikeClient(t, filepath.Join(dir, "ca.crt"), filepath.Join(dir, "client.crt"), filepath.Join(dir, "client.key"), host)
		// ::1 may not route the UDP listener (bound on 127.0.0.1); the SAN is
		// asserted on the certificate itself in the mtls package tests. Dial
		// the 127.0.0.1 socket but verify against the name.
		u := "https://127.0.0.1:" + port + "/v1/cluster/status"
		tr := c.Transport.(*http3.Transport)
		tr.TLSClientConfig.ServerName = host
		if code, _, err := get(t, c, u); err != nil || code != 200 {
			t.Errorf("server name %q: code=%d err=%v, want verified 200", name, code, err)
		}
	}
}

func TestCLIRoundTrip_NoClientCertificateIsRefused(t *testing.T) {
	addr, dir, _ := startDaemonLikeServer(t, "127.0.0.1:0", nil)
	_, port, _ := net.SplitHostPort(addr)
	c := curlLikeClient(t, filepath.Join(dir, "ca.crt"), "", "", "127.0.0.1")
	if code, body, err := get(t, c, "https://127.0.0.1:"+port+"/v1/cluster/status"); err == nil {
		t.Fatalf("request without client cert succeeded: %d %q (mutual TLS not enforced)", code, body)
	}
}

func TestCLIRoundTrip_ClientCertFromAnotherCAIsRefused(t *testing.T) {
	addr, dir, _ := startDaemonLikeServer(t, "127.0.0.1:0", nil)
	_, port, _ := net.SplitHostPort(addr)
	other, err := mtls.GenerateCA()
	if err != nil {
		t.Fatal(err)
	}
	otherDir := filepath.Join(t.TempDir(), "cli")
	if err := writeCLIMaterial(otherDir, other); err != nil {
		t.Fatal(err)
	}
	// trusts the real CA (server verifies) but presents a cert from another CA
	c := curlLikeClient(t, filepath.Join(dir, "ca.crt"), filepath.Join(otherDir, "client.crt"), filepath.Join(otherDir, "client.key"), "127.0.0.1")
	if code, _, err := get(t, c, "https://127.0.0.1:"+port+"/v1/cluster/status"); err == nil {
		t.Fatalf("client cert from an untrusted CA was accepted (status %d)", code)
	}
}

func TestCLIRoundTrip_ServerFromAnotherCAIsRefusedByClient(t *testing.T) {
	addr, dir, _ := startDaemonLikeServer(t, "127.0.0.1:0", nil)
	_, port, _ := net.SplitHostPort(addr)
	other, err := mtls.GenerateCA()
	if err != nil {
		t.Fatal(err)
	}
	otherDir := filepath.Join(t.TempDir(), "cli")
	if err := writeCLIMaterial(otherDir, other); err != nil {
		t.Fatal(err)
	}
	// client trusts ONLY a different CA: must not accept this daemon
	c := curlLikeClient(t, filepath.Join(otherDir, "ca.crt"), filepath.Join(dir, "client.crt"), filepath.Join(dir, "client.key"), "127.0.0.1")
	if code, _, err := get(t, c, "https://127.0.0.1:"+port+"/v1/cluster/status"); err == nil {
		t.Fatalf("a client trusting a different CA accepted the daemon (status %d)", code)
	}
}

func TestCLIRoundTrip_UnlistedNameIsRefused(t *testing.T) {
	addr, dir, _ := startDaemonLikeServer(t, "127.0.0.1:0", nil)
	_, port, _ := net.SplitHostPort(addr)
	c := curlLikeClient(t, filepath.Join(dir, "ca.crt"), filepath.Join(dir, "client.crt"), filepath.Join(dir, "client.key"), "not-a-san.example")
	if code, _, err := get(t, c, "https://127.0.0.1:"+port+"/v1/cluster/status"); err == nil {
		t.Fatalf("server name outside the SAN set verified (status %d): name checking is off", code)
	}
}

func TestCLIRoundTrip_AdvertisedAddressBecomesSAN(t *testing.T) {
	addr, dir, _ := startDaemonLikeServer(t, "127.0.0.1:0", []string{"cluster.example.test", "10.9.8.7"})
	_, port, _ := net.SplitHostPort(addr)
	for _, name := range []string{"cluster.example.test", "10.9.8.7"} {
		c := curlLikeClient(t, filepath.Join(dir, "ca.crt"), filepath.Join(dir, "client.crt"), filepath.Join(dir, "client.key"), name)
		if code, _, err := get(t, c, "https://127.0.0.1:"+port+"/v1/cluster/status"); err != nil || code != 200 {
			t.Errorf("advertised name %q: code=%d err=%v, want verified 200", name, code, err)
		}
	}
}

func TestWriteCLIMaterial_PermissionsAndNoStrayKey(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatal(err)
	}
	parent := t.TempDir()
	dir := filepath.Join(parent, "cli")
	if err := writeCLIMaterial(dir, ca); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(dir)
	if err != nil || st.Mode().Perm() != 0o700 {
		t.Fatalf("cli dir mode = %v (err %v), want 0700", st.Mode().Perm(), err)
	}
	for _, f := range []string{"ca.crt", "client.crt", "client.key"} {
		fi, err := os.Stat(filepath.Join(dir, f))
		if err != nil {
			t.Fatalf("%s: %v", f, err)
		}
		if fi.Mode().Perm() != 0o600 {
			t.Errorf("%s mode = %v, want 0600", f, fi.Mode().Perm())
		}
	}
	// the CA PRIVATE key must never be copied into the CLI directory
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		b, _ := os.ReadFile(filepath.Join(dir, e.Name()))
		if strings.Contains(string(b), "BEGIN EC PRIVATE KEY") && e.Name() != "client.key" {
			t.Errorf("%s contains a private key", e.Name())
		}
		if strings.Contains(string(b), string(ca.KeyPEM)) {
			t.Errorf("%s contains the CA private key", e.Name())
		}
	}
	// an existing too-open directory is tightened, not trusted
	loose := filepath.Join(parent, "loose")
	if err := os.Mkdir(loose, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := writeCLIMaterial(loose, ca); err != nil {
		t.Fatal(err)
	}
	if st, _ := os.Stat(loose); st.Mode().Perm() != 0o700 {
		t.Errorf("pre-existing 0755 dir left at %v, want tightened to 0700", st.Mode().Perm())
	}
}
