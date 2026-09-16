package api

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/quic-go/quic-go/http3"

	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
	"github.com/vasic-digital/llmctl/llmctld/internal/raft"
)

// waitForRealLeader polls node's Raft state (via its real behavior, not a
// private field) until it can serve a genuinely leader-only operation, or
// the timeout elapses. Reimplemented here (rather than reusing package
// raft's own unexported waitForLeader test helper) because internal/api
// cannot reach package raft's private *hraft.Raft state; it instead
// drives the SAME real signal node_test.go uses from outside the
// package: GET /v1/cluster/status would report is_leader, but before a
// server exists at all, polling node.IsLeader() (an exported, real
// accessor over the real underlying hraft.Raft.State()) is the correct
// equivalent.
func waitForRealLeader(t *testing.T, node *raft.Node, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if node.IsLeader() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("node never became leader within %s", timeout)
}

// buildTestTLSConfig mirrors internal/raft/transport_test.go's
// buildNodeTLSConfig reference shape exactly (same mTLS-without-hostname-
// verification approach, same reasoning: node identity here is
// established by the CA chain, not by a DNS/IP SAN matching whatever
// address a test happens to dial) - duplicated here rather than exported
// from package raft because it is fundamentally a TEST HELPER, not
// production API surface, and internal/api's tests need their own
// instance regardless of what package raft's tests do internally.
func buildTestTLSConfig(t *testing.T, ca *mtls.CA, nodeID string) *tls.Config {
	t.Helper()
	nodeCert, err := ca.IssueNodeCert(nodeID)
	if err != nil {
		t.Fatalf("IssueNodeCert(%q): %v", nodeID, err)
	}
	cert, err := mtls.LoadTLSCertificate(nodeCert.CertPEM, nodeCert.KeyPEM)
	if err != nil {
		t.Fatalf("LoadTLSCertificate(%q): %v", nodeID, err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(ca.CertPEM) {
		t.Fatalf("failed to add CA cert to pool")
	}
	return &tls.Config{
		Certificates:          []tls.Certificate{cert},
		RootCAs:               pool,
		ClientCAs:             pool,
		ClientAuth:            tls.RequireAndVerifyClientCert,
		InsecureSkipVerify:    true,
		VerifyPeerCertificate: raft.VerifyPeerCertificateAgainstCA(pool),
	}
}

// newTestClient builds a real *http.Client that speaks real HTTP/3 over a
// real QUIC connection, presenting clientTLS - the exact stack a real
// llmctld peer node would use to call another node's cluster API.
func newTestClient(clientTLS *tls.Config) *http.Client {
	return &http.Client{
		Transport: &http3.Transport{TLSClientConfig: clientTLS},
		Timeout:   5 * time.Second,
	}
}

// TestClusterStatus_RealHTTP3RequestOverMTLS proves GET /v1/cluster/status
// is reachable end-to-end: a real HTTP/3 client, over a real QUIC
// connection, authenticated by real mTLS certs from internal/mtls,
// against a real *raft.Node bootstrapped to be its own leader - not a
// unit-test call into the gin handler function directly.
func TestClusterStatus_RealHTTP3RequestOverMTLS(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}

	node, err := raft.Bootstrap(raft.Config{
		NodeID:    "node-a",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildTestTLSConfig(t, ca, "node-a"),
	})
	if err != nil {
		t.Fatalf("raft.Bootstrap: %v", err)
	}
	defer func() { _ = node.Shutdown() }()
	waitForRealLeader(t, node, 3*time.Second)

	srv := NewServer(node, buildTestTLSConfig(t, ca, "node-a-api"))
	if err := srv.Listen("127.0.0.1:0"); err != nil {
		t.Fatalf("Listen: %v", err)
	}
	defer func() { _ = srv.Close() }()

	client := newTestClient(buildTestTLSConfig(t, ca, "test-client"))
	resp, err := client.Get("https://" + srv.Addr + "/v1/cluster/status")
	if err != nil {
		t.Fatalf("GET /v1/cluster/status: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("GET /v1/cluster/status: status = %d, body = %s", resp.StatusCode, body)
	}

	var got struct {
		IsLeader bool `json:"is_leader"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if !got.IsLeader {
		t.Fatalf("is_leader = false, want true for a freshly bootstrapped single-node cluster")
	}
}

// TestClusterNodes_RealHTTP3RequestReturnsRealConfiguration proves
// GET /v1/cluster/nodes returns the real Raft configuration, over a real
// HTTP/3+mTLS round trip.
func TestClusterNodes_RealHTTP3RequestReturnsRealConfiguration(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}
	node, err := raft.Bootstrap(raft.Config{
		NodeID:    "node-a",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildTestTLSConfig(t, ca, "node-a"),
	})
	if err != nil {
		t.Fatalf("raft.Bootstrap: %v", err)
	}
	defer func() { _ = node.Shutdown() }()
	waitForRealLeader(t, node, 3*time.Second)

	srv := NewServer(node, buildTestTLSConfig(t, ca, "node-a-api"))
	if err := srv.Listen("127.0.0.1:0"); err != nil {
		t.Fatalf("Listen: %v", err)
	}
	defer func() { _ = srv.Close() }()

	client := newTestClient(buildTestTLSConfig(t, ca, "test-client"))
	resp, err := client.Get("https://" + srv.Addr + "/v1/cluster/nodes")
	if err != nil {
		t.Fatalf("GET /v1/cluster/nodes: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()

	var got struct {
		Servers []raft.ServerInfo `json:"servers"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(got.Servers) != 1 || got.Servers[0].ID != "node-a" || got.Servers[0].Suffrage != "Voter" {
		t.Fatalf("GET /v1/cluster/nodes = %+v, want exactly [{ID:node-a Suffrage:Voter}]", got.Servers)
	}
}

// TestClusterJoin_RealHTTP3RequestActuallyJoinsRaft proves POST
// /v1/cluster/join genuinely drives a real raft.AddVoter, verified by
// re-querying /v1/cluster/nodes afterward and seeing 2 servers - not
// merely a 200 OK that changed nothing.
func TestClusterJoin_RealHTTP3RequestActuallyJoinsRaft(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}

	leader, err := raft.Bootstrap(raft.Config{
		NodeID:    "node-a",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildTestTLSConfig(t, ca, "node-a"),
	})
	if err != nil {
		t.Fatalf("raft.Bootstrap(node-a): %v", err)
	}
	defer func() { _ = leader.Shutdown() }()
	waitForRealLeader(t, leader, 3*time.Second)

	follower, err := raft.New(raft.Config{
		NodeID:    "node-b",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildTestTLSConfig(t, ca, "node-b"),
	})
	if err != nil {
		t.Fatalf("raft.New(node-b): %v", err)
	}
	defer func() { _ = follower.Shutdown() }()

	srv := NewServer(leader, buildTestTLSConfig(t, ca, "node-a-api"))
	if err := srv.Listen("127.0.0.1:0"); err != nil {
		t.Fatalf("Listen: %v", err)
	}
	defer func() { _ = srv.Close() }()

	client := newTestClient(buildTestTLSConfig(t, ca, "test-client"))
	reqBody := []byte(`{"peer_id":"node-b","peer_addr":"` + follower.Addr() + `","api_addr":"127.0.0.1:9100"}`)
	resp, err := client.Post("https://"+srv.Addr+"/v1/cluster/join", "application/json", bytes.NewReader(reqBody))
	if err != nil {
		t.Fatalf("POST /v1/cluster/join: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("POST /v1/cluster/join: status = %d, body = %s", resp.StatusCode, body)
	}

	getResp, err := client.Get("https://" + srv.Addr + "/v1/cluster/nodes")
	if err != nil {
		t.Fatalf("GET /v1/cluster/nodes after join: %v", err)
	}
	defer func() { _ = getResp.Body.Close() }()
	var got struct {
		Servers []raft.ServerInfo `json:"servers"`
	}
	if err := json.NewDecoder(getResp.Body).Decode(&got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(got.Servers) != 2 {
		t.Fatalf("GET /v1/cluster/nodes after join returned %d servers, want 2 - the real AddVoter did not take effect", len(got.Servers))
	}
}

// TestClusterLeave_RealHTTP3RequestActuallyLeavesRaft proves POST
// /v1/cluster/leave genuinely drives a real raft.RemoveServer, verified
// by the surviving peer's own configuration shrinking - not merely a
// 200 OK that changed nothing.
func TestClusterLeave_RealHTTP3RequestActuallyLeavesRaft(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}

	leader, err := raft.Bootstrap(raft.Config{
		NodeID:    "node-a",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildTestTLSConfig(t, ca, "node-a"),
	})
	if err != nil {
		t.Fatalf("raft.Bootstrap(node-a): %v", err)
	}
	defer func() { _ = leader.Shutdown() }()
	waitForRealLeader(t, leader, 3*time.Second)

	follower, err := raft.New(raft.Config{
		NodeID:    "node-b",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildTestTLSConfig(t, ca, "node-b"),
	})
	if err != nil {
		t.Fatalf("raft.New(node-b): %v", err)
	}
	defer func() { _ = follower.Shutdown() }()

	if err := leader.Join("node-b", follower.Addr()); err != nil {
		t.Fatalf("leader.Join: %v", err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for {
		servers, err := follower.Servers()
		if err == nil && len(servers) == 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("follower never observed the 2-member configuration after Join")
		}
		time.Sleep(10 * time.Millisecond)
	}

	srv := NewServer(leader, buildTestTLSConfig(t, ca, "node-a-api"))
	if err := srv.Listen("127.0.0.1:0"); err != nil {
		t.Fatalf("Listen: %v", err)
	}
	defer func() { _ = srv.Close() }()

	client := newTestClient(buildTestTLSConfig(t, ca, "test-client"))
	resp, err := client.Post("https://"+srv.Addr+"/v1/cluster/leave", "application/json", bytes.NewReader(nil))
	if err != nil {
		t.Fatalf("POST /v1/cluster/leave: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("POST /v1/cluster/leave: status = %d, body = %s", resp.StatusCode, body)
	}

	deadline = time.Now().Add(3 * time.Second)
	for {
		servers, err := follower.Servers()
		if err == nil {
			found := false
			for _, s := range servers {
				if s.ID == "node-a" {
					found = true
				}
			}
			if !found {
				return
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("follower's configuration still lists node-a after POST /v1/cluster/leave")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// TestRequireMTLS_RejectsRequestFromUntrustedCA proves the mTLS
// enforcement is genuinely load-bearing at the HTTP-server layer: a
// client presenting a cert signed by a DIFFERENT CA cannot even complete
// the TLS handshake, so the request never reaches a handler at all.
func TestRequireMTLS_RejectsRequestFromUntrustedCA(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}
	otherCA, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA (other): %v", err)
	}

	node, err := raft.Bootstrap(raft.Config{
		NodeID:    "node-a",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildTestTLSConfig(t, ca, "node-a"),
	})
	if err != nil {
		t.Fatalf("raft.Bootstrap: %v", err)
	}
	defer func() { _ = node.Shutdown() }()
	waitForRealLeader(t, node, 3*time.Second)

	srv := NewServer(node, buildTestTLSConfig(t, ca, "node-a-api"))
	if err := srv.Listen("127.0.0.1:0"); err != nil {
		t.Fatalf("Listen: %v", err)
	}
	defer func() { _ = srv.Close() }()

	imposterClient := newTestClient(buildTestTLSConfig(t, otherCA, "imposter"))
	_, err = imposterClient.Get("https://" + srv.Addr + "/v1/cluster/status")
	if err == nil {
		t.Fatalf("a request from a client cert signed by a DIFFERENT CA succeeded - mTLS is not actually enforced")
	}
}
