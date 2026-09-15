package raft

import (
	"crypto/tls"
	"crypto/x509"
	"testing"
	"time"

	hraft "github.com/hashicorp/raft"

	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
)

// buildNodeTLSConfig issues a real leaf cert from the given CA for nodeID
// and returns a *tls.Config presenting that cert and trusting only the CA -
// the exact mTLS shape Clarification 11 requires for node-to-node traffic.
func buildNodeTLSConfig(t *testing.T, ca *mtls.CA, nodeID string) *tls.Config {
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
		Certificates: []tls.Certificate{cert},
		RootCAs:      pool,
		ClientCAs:    pool,
		ClientAuth:   tls.RequireAndVerifyClientCert,
		NextProtos:   []string{quicRaftALPN},
		// InsecureSkipVerify + VerifyPeerCertificate: node identity is
		// established by the CA chain, never by a DNS/IP SAN matching the
		// dial address (see VerifyPeerCertificateAgainstCA's doc comment
		// for why the standard hostname-checking path fails here).
		InsecureSkipVerify:    true,
		VerifyPeerCertificate: VerifyPeerCertificateAgainstCA(pool),
	}
}

// TestTransport_TwoNodesExchangeRealRaftRPCOverLoopback proves two
// in-process transports, each built from a REAL mTLS cert issued by the
// SAME CA (internal/mtls), can exchange a real hashicorp/raft RPC
// (AppendEntries) over a real QUIC connection on loopback - the exact
// property T049 requires: "two in-process transports can exchange RPCs
// over loopback with real TLS certs from internal/mtls".
func TestTransport_TwoNodesExchangeRealRaftRPCOverLoopback(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}

	serverTLS := buildNodeTLSConfig(t, ca, "node-server")
	clientTLS := buildNodeTLSConfig(t, ca, "node-client")

	serverTransport, err := NewTransport("127.0.0.1:0", serverTLS, 2, 2*time.Second)
	if err != nil {
		t.Fatalf("NewTransport(server): %v", err)
	}
	defer func() { _ = serverTransport.Close() }()

	serverAddr := serverTransport.LocalAddr()

	// The client dials the server's real address using its OWN transport
	// (a client node in a real cluster is itself a NetworkTransport that
	// both sends and receives - here we only exercise the send side).
	clientTransport, err := NewTransport("127.0.0.1:0", clientTLS, 2, 2*time.Second)
	if err != nil {
		t.Fatalf("NewTransport(client): %v", err)
	}
	defer func() { _ = clientTransport.Close() }()

	// Consume the server's inbound RPCs on a background goroutine and
	// respond, exactly as raft.Raft's main loop would.
	rpcCh := serverTransport.Consumer()
	done := make(chan struct{})
	go func() {
		defer close(done)
		select {
		case rpc := <-rpcCh:
			req, ok := rpc.Command.(*hraft.AppendEntriesRequest)
			if !ok {
				t.Errorf("unexpected RPC command type %T", rpc.Command)
				rpc.RespChan <- hraft.RPCResponse{Error: nil, Response: &hraft.AppendEntriesResponse{}}
				return
			}
			rpc.RespChan <- hraft.RPCResponse{
				Response: &hraft.AppendEntriesResponse{
					Term:    req.Term,
					Success: true,
				},
			}
		case <-time.After(5 * time.Second):
			t.Errorf("server transport never received the RPC within 5s")
		}
	}()

	req := &hraft.AppendEntriesRequest{
		RPCHeader: hraft.RPCHeader{ProtocolVersion: hraft.ProtocolVersionMax, Addr: []byte("node-client")},
		Term:      7,
	}
	var resp hraft.AppendEntriesResponse
	if err := clientTransport.AppendEntries(hraft.ServerID("node-server"), hraft.ServerAddress(string(serverAddr)), req, &resp); err != nil {
		t.Fatalf("client AppendEntries over real QUIC+mTLS loopback connection: %v", err)
	}

	<-done

	if resp.Term != 7 {
		t.Errorf("resp.Term = %d, want 7 (proves the REAL response round-tripped, not a zero-value default)", resp.Term)
	}
	if !resp.Success {
		t.Errorf("resp.Success = false, want true")
	}
}

// TestTransport_RejectsConnectionFromUntrustedCA proves the mTLS
// requirement is load-bearing: a client presenting a cert signed by a
// DIFFERENT CA must be rejected, not merely accepted-and-ignored - the
// same mutual-auth property internal/mtls's own tests already prove for
// bare certificates, now proven at the transport layer.
func TestTransport_RejectsConnectionFromUntrustedCA(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}
	otherCA, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA (other): %v", err)
	}

	serverTLS := buildNodeTLSConfig(t, ca, "node-server")
	untrustedClientTLS := buildNodeTLSConfig(t, otherCA, "node-imposter")

	serverTransport, err := NewTransport("127.0.0.1:0", serverTLS, 2, 2*time.Second)
	if err != nil {
		t.Fatalf("NewTransport(server): %v", err)
	}
	defer func() { _ = serverTransport.Close() }()
	serverAddr := serverTransport.LocalAddr()

	imposterTransport, err := NewTransport("127.0.0.1:0", untrustedClientTLS, 2, 2*time.Second)
	if err != nil {
		t.Fatalf("NewTransport(imposter): %v", err)
	}
	defer func() { _ = imposterTransport.Close() }()

	req := &hraft.AppendEntriesRequest{RPCHeader: hraft.RPCHeader{ProtocolVersion: hraft.ProtocolVersionMax}, Term: 1}
	var resp hraft.AppendEntriesResponse
	err = imposterTransport.AppendEntries(hraft.ServerID("node-server"), hraft.ServerAddress(string(serverAddr)), req, &resp)
	if err == nil {
		t.Fatalf("AppendEntries from a cert signed by a DIFFERENT CA succeeded - mTLS is not actually enforced")
	}
}
