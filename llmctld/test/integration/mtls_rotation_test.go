// Package integration (mtls_rotation_test.go): real multi-process
// integration tests for Feature 004 (mTLS certificate and CA rotation with
// revocation) - closes T012/T075's disclosed boundary. Every test in this
// file reuses cluster_bootstrap_test.go's testCluster harness (real
// llmctld OS processes, real QUIC+mTLS transports, real HTTP/3 API
// servers - nothing mocked or run in-process), per this project's
// Constitution §11.4.27 (no fakes beyond unit tests).
package integration

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/quic-go/quic-go/http3"

	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
	"github.com/vasic-digital/llmctl/llmctld/internal/raft"
)

// httpClientForCert builds a real HTTP/3+mTLS client presenting nodeCert -
// unlike cluster_bootstrap_test.go's httpClient() (which always issues a
// fresh "test-observer" identity per call), this lets a test drive
// requests using a SPECIFIC, already-issued certificate whose serial
// number the test independently tracks (e.g. one it is about to revoke),
// so "was THIS identity's connection genuinely rejected" is provable
// against a known real serial, not merely "some connection failed".
func (tc *testCluster) httpClientForCert(nodeCert *mtls.NodeCert) *http.Client {
	tc.t.Helper()
	cert, err := mtls.LoadTLSCertificate(nodeCert.CertPEM, nodeCert.KeyPEM)
	if err != nil {
		tc.t.Fatalf("load cert: %v", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(tc.ca.CertPEM) {
		tc.t.Fatalf("add CA cert to pool")
	}
	store, err := mtls.NewTrustStore(pool, &cert)
	if err != nil {
		tc.t.Fatalf("NewTrustStore: %v", err)
	}
	tlsConf := &tls.Config{
		GetClientCertificate:  store.GetClientCertificate,
		RootCAs:               pool,
		InsecureSkipVerify:    true,
		VerifyPeerCertificate: raft.VerifyPeerCertificateAgainstCA(store),
	}
	return &http.Client{Transport: &http3.Transport{TLSClientConfig: tlsConf}, Timeout: 5 * time.Second}
}

// certSerialNumber parses certPEM (a real x509 leaf certificate, PEM
// encoded, as returned by mtls.NodeCert.CertPEM) and returns its real
// serial number as a decimal string - the exact key data-model.md's
// revocation design uses (research.md Decision 4: keyed by certificate
// SERIAL NUMBER, not node ID).
func certSerialNumber(t *testing.T, certPEM []byte) string {
	t.Helper()
	block, _ := pem.Decode(certPEM)
	if block == nil {
		t.Fatalf("certSerialNumber: failed to decode PEM block")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatalf("certSerialNumber: parse certificate: %v", err)
	}
	return cert.SerialNumber.String()
}

// adminToken issues a real, validly-signed JWT bearing the admin role,
// signed with tc's own jwtSigningKey - the SAME key every spawned node
// was started with (cluster_bootstrap_test.go's spawn() sets
// LLMCTLD_JWT_SIGNING_KEY), so this token is genuinely accepted by any
// real node's RequireJWT middleware, exactly as a real operator's token
// would be.
func (tc *testCluster) adminToken() string {
	tc.t.Helper()
	token, err := auth.IssueToken(auth.Claims{Roles: []string{auth.RoleAdmin}}, []byte(tc.jwtSigningKey))
	if err != nil {
		tc.t.Fatalf("issue admin token: %v", err)
	}
	return token
}

// revokeRequest/revocationsResponse mirror internal/api/routes_mtls.go's
// JSON wire shapes - duplicated here as plain, decoupled local types
// (matching only the JSON contract, never importing internal/api's
// private types), exactly as this package's other test files already do
// for /v1/cluster/* and /v1/replication/* (nodesResponse/statusResponse in
// cluster_bootstrap_test.go, replAppendRequest/replKVState in
// failover_state_test.go).
type revokeRequest struct {
	SerialNumber string `json:"serial_number"`
	NodeID       string `json:"node_id"`
	Reason       string `json:"reason"`
}

type revocationRecordJSON struct {
	SerialNumber string    `json:"serial_number"`
	NodeID       string    `json:"node_id"`
	Reason       string    `json:"reason"`
	RevokedBy    string    `json:"revoked_by"`
	RevokedAt    time.Time `json:"revoked_at"`
}

type revocationsResponse struct {
	Revocations map[string]revocationRecordJSON `json:"revocations"`
}

// revokeCertificate POSTs a real revoke request to apiAddr's real
// POST /v1/cluster/mtls/revoke route, bearing token as an
// "Authorization: Bearer" header, and fails the test loudly if the real
// HTTP response is not 200 OK - a genuine, visible failure (never a
// silent skip) if the revoke capability does not exist or refuses the
// call for any reason.
func revokeCertificate(t *testing.T, client *http.Client, apiAddr, token, serialNumber, nodeID, reason string) {
	t.Helper()
	body, err := json.Marshal(revokeRequest{SerialNumber: serialNumber, NodeID: nodeID, Reason: reason})
	if err != nil {
		t.Fatalf("marshal revoke request: %v", err)
	}
	req, err := http.NewRequest(http.MethodPost, "https://"+apiAddr+"/v1/cluster/mtls/revoke", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("new revoke request to %s: %v", apiAddr, err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("POST /v1/cluster/mtls/revoke to %s: %v", apiAddr, err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		t.Fatalf("POST /v1/cluster/mtls/revoke to %s: status = %d, body = %s", apiAddr, resp.StatusCode, respBody)
	}
}

// getRevocations GETs apiAddr's real GET /v1/cluster/mtls/revocations
// route, bearing token, returning the real replicated revocation set THAT
// SPECIFIC node's own TrustStore-backing FSM state currently holds.
func getRevocations(t *testing.T, client *http.Client, apiAddr, token string) (revocationsResponse, error) {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, "https://"+apiAddr+"/v1/cluster/mtls/revocations", nil)
	if err != nil {
		t.Fatalf("new revocations request to %s: %v", apiAddr, err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := client.Do(req)
	if err != nil {
		return revocationsResponse{}, err
	}
	defer func() { _ = resp.Body.Close() }()
	var got revocationsResponse
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		return revocationsResponse{}, err
	}
	return got, nil
}

// waitForRevocationReplicated polls apiAddr's real GET
// /v1/cluster/mtls/revocations until it lists serialNumber (proving the
// CommandRevokeCertificate Raft log entry has been durably applied on
// THAT specific node, not merely accepted by whichever node the original
// revoke request happened to land on), or fails the test if it never
// appears within timeout.
func waitForRevocationReplicated(t *testing.T, client *http.Client, apiAddr, token, serialNumber string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		got, err := getRevocations(t, client, apiAddr, token)
		if err == nil {
			if _, ok := got.Revocations[serialNumber]; ok {
				return
			}
		} else {
			lastErr = err
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("serial %s was never observed as revoked on %s within %s (last error: %v)", serialNumber, apiAddr, timeout, lastErr)
}

// TestMTLSRotation_RevokedCertificate_RejectedClusterWide is T007
// (spec.md User Story 1, quickstart.md Scenario 1): a real 3-node
// cluster, a real revoke action against the leader, and a real connection
// attempt presenting the revoked identity is genuinely rejected by EVERY
// real node in the cluster - not just the one that processed the revoke
// request - with zero restart of any process, proving the FSM-replicated
// revocation state (T010/T011) actually reaches and is actually consumed
// by every node's own live TrustStore.
func TestMTLSRotation_RevokedCertificate_RejectedClusterWide(t *testing.T) {
	tc := newTestCluster(t)

	nodeA := tc.bootstrap("node-a")
	nodeB := tc.join("node-b", nodeA)
	nodeC := tc.join("node-c", nodeA)

	observer := tc.httpClient()
	token := tc.adminToken()

	// Confirm the full 3-node configuration is durably replicated before
	// proceeding (the same precondition TestClusterFailover_* already
	// establishes is necessary for a meaningful cluster-wide claim).
	deadline := time.Now().Add(5 * time.Second)
	for _, n := range []*spawnedNode{nodeA, nodeB, nodeC} {
		for {
			nodes, err := tc.getNodes(observer, n.apiAddr)
			if err == nil && len(nodes.Servers) == 3 {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("precondition failed: node %q never observed the full 3-node configuration", n.nodeID)
			}
			time.Sleep(50 * time.Millisecond)
		}
	}

	// Issue a REAL certificate for a victim identity from the cluster's
	// own CA, and confirm it is genuinely trusted BEFORE revocation - the
	// control proving this is a real mTLS-layer identity, not a client
	// that was never going to be accepted anyway.
	victimCert, err := tc.ca.IssueNodeCert("node-victim")
	if err != nil {
		t.Fatalf("issue victim cert: %v", err)
	}
	victimSerial := certSerialNumber(t, victimCert.CertPEM)
	victimClient := tc.httpClientForCert(victimCert)

	for _, n := range []*spawnedNode{nodeA, nodeB, nodeC} {
		if _, err := tc.getStatus(victimClient, n.apiAddr); err != nil {
			t.Fatalf("BEFORE revocation, node-victim's cert was rejected by %q (should have been trusted): %v", n.nodeID, err)
		}
	}

	// Revoke the victim's serial via the leader's real, RBAC-protected
	// admin endpoint.
	revokeCertificate(t, observer, nodeA.apiAddr, token, victimSerial, "node-victim", "compromised")

	// Confirm the revocation genuinely propagates to EVERY node (cluster
	// wide, via normal Raft log replication - zero restart) before
	// checking rejection, so a later rejection-check failure cannot be
	// confused with "the revoke call itself silently no-op'd".
	for _, n := range []*spawnedNode{nodeA, nodeB, nodeC} {
		waitForRevocationReplicated(t, observer, n.apiAddr, token, victimSerial, 5*time.Second)
	}

	// Force a FRESH QUIC connection (and therefore a fresh TLS handshake,
	// and therefore a fresh VerifyPeerCertificate/TrustStore check) for
	// the rejection assertion below - found as a genuine test-authoring
	// bug via root-cause investigation: quic-go's http3.Transport caches
	// one QUIC connection per hostname (transport.go's t.clients map) and
	// reuses it across requests, exactly like net/http's own connection
	// pooling. victimClient already made a genuinely-authenticated
	// connection to each of nodeA/nodeB/nodeC in the BEFORE-revocation
	// loop above; without this call, the AFTER-revocation loop below
	// would silently reuse those same already-authenticated connections
	// instead of re-running the TLS handshake, making the assertion pass
	// trivially regardless of whether revocation is actually enforced -
	// exactly the false-negative class Constitution §11.4.201(7)(c) (the
	// path is part of the instrument) warns against. http.Client.
	// CloseIdleConnections() forwards to the underlying *http3.Transport's
	// own CloseIdleConnections (Go stdlib's documented closeIdler
	// interface), so no change to httpClientForCert's return type is
	// needed.
	victimClient.CloseIdleConnections()

	// The core assertion: a fresh connection attempt presenting the
	// REVOKED identity is genuinely rejected by EVERY real node - proving
	// the FSM-applied revocation event actually reached and is actually
	// enforced by each node's own live TrustStore, with none of the 3
	// real processes ever restarted.
	for _, n := range []*spawnedNode{nodeA, nodeB, nodeC} {
		if _, err := tc.getStatus(victimClient, n.apiAddr); err == nil {
			t.Fatalf("AFTER revocation, node-victim's cert was still accepted by %q - revocation is not enforced cluster-wide", n.nodeID)
		}
	}

	// T013 (spec.md FR-012): revocation is independent of cluster
	// membership - CommandRevokeCertificate's Apply case touches ONLY
	// ClusterState.Revocations, never ClusterState.Nodes nor any Raft
	// voter-configuration change, so the real, already-joined 3-node
	// membership (proven durably replicated at the top of this test) MUST
	// remain completely unaffected by the revoke action above.
	for _, n := range []*spawnedNode{nodeA, nodeB, nodeC} {
		nodes, err := tc.getNodes(observer, n.apiAddr)
		if err != nil {
			t.Fatalf("FR-012 check: GET /v1/cluster/nodes on %q after revocation: %v", n.nodeID, err)
		}
		if len(nodes.Servers) != 3 {
			t.Fatalf("FR-012 violated: node %q reports %d cluster members after a certificate revocation (want 3, unchanged) - revocation must be independent of membership eviction", n.nodeID, len(nodes.Servers))
		}
	}
}

// TestMTLSRotation_RevokedNode_CannotRejoin is T008 (spec.md Acceptance
// Scenario 2): a real attempted join using an identity whose certificate
// has just been revoked is refused - VISIBLY (a real, prompt TLS-layer
// error returned well within the client's bounded timeout), never a
// silent hang.
func TestMTLSRotation_RevokedNode_CannotRejoin(t *testing.T) {
	tc := newTestCluster(t)
	nodeA := tc.bootstrap("node-a")

	observer := tc.httpClient()
	token := tc.adminToken()

	// Wait for node-a to actually become Raft leader before issuing any
	// leader-only command against it - the same precondition
	// cluster_bootstrap_test.go's own
	// TestClusterBootstrap_ThreeRealProcessesElectLeaderWithin5s polls
	// for. bootstrap() only waits for the process to report READY (it has
	// started Raft and begun an election), NOT for that election to have
	// actually completed - found as a genuine test-authoring bug via
	// root-cause investigation of a real "node is not the leader" 409
	// response: revokeCertificate below is a leader-only RBAC-protected
	// write (routes_mtls.go -> node.RevokeCertificate ->
	// hraft.Raft.Apply, which real hashicorp/raft refuses on a
	// non-leader), and a freshly-bootstrapped single-node Raft instance
	// has a real, non-zero election-timeout window before it wins its own
	// election.
	deadline := time.Now().Add(5 * time.Second)
	for {
		status, err := tc.getStatus(observer, nodeA.apiAddr)
		if err == nil && status.IsLeader {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("precondition failed: node-a never became Raft leader within 5s (last status err: %v)", err)
		}
		time.Sleep(50 * time.Millisecond)
	}

	victimCert, err := tc.ca.IssueNodeCert("node-victim")
	if err != nil {
		t.Fatalf("issue victim cert: %v", err)
	}
	victimSerial := certSerialNumber(t, victimCert.CertPEM)
	victimClient := tc.httpClientForCert(victimCert)

	// clusterJoinRequest mirrors internal/api/routes_cluster.go's private
	// joinRequest JSON wire shape (matching only the contract, never
	// importing an unexported type - the same decoupling this file's
	// other request/response types already follow).
	type clusterJoinRequest struct {
		PeerID   string `json:"peer_id"`
		PeerAddr string `json:"peer_addr"`
	}
	joinBody, err := json.Marshal(clusterJoinRequest{PeerID: "node-victim", PeerAddr: "127.0.0.1:0"})
	if err != nil {
		t.Fatalf("marshal join request: %v", err)
	}
	attemptJoin := func() error {
		req, err := http.NewRequest(http.MethodPost, "https://"+nodeA.apiAddr+"/v1/cluster/join", bytes.NewReader(joinBody))
		if err != nil {
			t.Fatalf("new join request: %v", err)
		}
		req.Header.Set("Content-Type", "application/json")
		start := time.Now()
		resp, err := victimClient.Do(req)
		elapsed := time.Since(start)
		if elapsed > 5*time.Second {
			t.Fatalf("join attempt took %s - longer than the client's own 5s timeout should ever allow (a hang, not a visible refusal)", elapsed)
		}
		if err != nil {
			return err
		}
		_ = resp.Body.Close()
		return nil
	}

	// BEFORE revocation: node-victim's identity is trusted at the mTLS
	// layer - proven via a non-mutating status check (the SAME control
	// TestMTLSRotation_RevokedCertificate_RejectedClusterWide already
	// uses), NOT a real join attempt. An earlier version of this test
	// used attemptJoin() itself as the BEFORE control, which is a real
	// bug found via root-cause investigation of a genuine, reproducible
	// cluster-quorum failure: POST /v1/cluster/join really calls
	// raft.Join -> hraft.Raft.AddVoter("node-victim", "127.0.0.1:0", ...),
	// and hashicorp/raft accepts ANY syntactically-valid address as a new
	// voter without verifying reachability first - so node-victim was
	// added as a REAL second voter in a now-2-member configuration,
	// requiring 2/2 for quorum. Because "127.0.0.1:0" can never actually
	// receive a UDP packet (real captured error: "write udp
	// [::]:PORT->127.0.0.1:0: sendmsg: invalid argument"), node-a
	// immediately lost contact with its own newly-required quorum member
	// and stepped down as leader - corrupting the cluster for the rest of
	// the test, well before revocation was ever attempted (observed as a
	// "leadership lost while committing log" 409 on the SUBSEQUENT
	// revokeCertificate call, not on the join itself). The BEFORE control
	// only needs to prove node-victim's certificate is genuinely trusted
	// pre-revocation, which a read-only status call establishes without
	// this side effect.
	if _, err := tc.getStatus(victimClient, nodeA.apiAddr); err != nil {
		t.Fatalf("BEFORE revocation, node-victim's cert was rejected at the mTLS layer (should have been trusted): %v", err)
	}

	revokeCertificate(t, observer, nodeA.apiAddr, token, victimSerial, "node-victim", "compromised")
	waitForRevocationReplicated(t, observer, nodeA.apiAddr, token, victimSerial, 5*time.Second)

	// Force a fresh QUIC connection for the second attemptJoin() call
	// below - see TestMTLSRotation_RevokedCertificate_RejectedClusterWide's
	// identical CloseIdleConnections() call for the full root-cause
	// explanation (quic-go's http3.Transport reuses one cached connection
	// per hostname, so without this the "BEFORE revocation" attemptJoin()
	// call above would leave an already-authenticated connection to
	// nodeA.apiAddr that the "AFTER revocation" call would silently
	// reuse, bypassing the TLS handshake this test exists to prove is
	// refused).
	victimClient.CloseIdleConnections()

	// AFTER revocation: the SAME identity's rejoin attempt is refused,
	// visibly (an explicit non-nil error, returned promptly - see
	// attemptJoin's own elapsed-time assertion above) - never a silent
	// hang or timeout.
	if err := attemptJoin(); err == nil {
		t.Fatalf("AFTER revocation, node-victim's rejoin attempt succeeded - a revoked identity must never be allowed back into the cluster")
	}
}

// TestMTLSRotation_UnreachableNode_LearnsRevocationOnReconnect is T009
// (spec.md Edge Case): a node that was NOT YET part of the cluster at the
// moment a revocation event was applied - the same "missed the original
// event" property a genuinely partitioned-then-healed node would also
// exhibit - still converges to the correct revoked state via normal Raft
// log replication once it joins/reconnects, BEFORE it is allowed to
// participate. This proves the T011 event-handler wiring fires not only
// on the FSM's live Apply path but is genuinely reflected in whatever
// state a newly-joining node replays/restores - exactly the mechanism a
// reconnecting-after-partition node would also rely on.
//
// Honest scope boundary (Constitution §11.4.223 provenance markers,
// disclosed rather than silently narrowed, mirroring
// TestClusterFailover_*'s own disclosed-scope pattern): this test does
// NOT simulate a literal OS/network-level partition (no iptables/netns
// manipulation) - it tests the identical underlying convergence property
// (a node absent from the cluster during a revocation event ends up with
// the correct revoked state once it joins and catches up via Raft log
// replication) without the flakiness risk of process-suspension-based
// partition simulation.
func TestMTLSRotation_UnreachableNode_LearnsRevocationOnReconnect(t *testing.T) {
	tc := newTestCluster(t)
	nodeA := tc.bootstrap("node-a")

	observer := tc.httpClient()
	token := tc.adminToken()

	// Wait for node-a to actually become Raft leader before issuing the
	// leader-only revokeCertificate call below - see
	// TestMTLSRotation_RevokedNode_CannotRejoin's identical precondition
	// for the full root-cause explanation (bootstrap() only waits for the
	// process to report READY, not for its own single-node election to
	// have completed).
	deadline := time.Now().Add(5 * time.Second)
	for {
		status, err := tc.getStatus(observer, nodeA.apiAddr)
		if err == nil && status.IsLeader {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("precondition failed: node-a never became Raft leader within 5s (last status err: %v)", err)
		}
		time.Sleep(50 * time.Millisecond)
	}

	victimCert, err := tc.ca.IssueNodeCert("node-victim")
	if err != nil {
		t.Fatalf("issue victim cert: %v", err)
	}
	victimSerial := certSerialNumber(t, victimCert.CertPEM)
	victimClient := tc.httpClientForCert(victimCert)

	// Revoke BEFORE node-b ever exists - node-b is, by construction,
	// "not there" for this event, the same property a partitioned node
	// would exhibit for an event applied while it was unreachable.
	revokeCertificate(t, observer, nodeA.apiAddr, token, victimSerial, "node-victim", "compromised")
	waitForRevocationReplicated(t, observer, nodeA.apiAddr, token, victimSerial, 5*time.Second)

	// node-b now joins - a real Raft join, catching up via real log
	// replication (the log already contains the CommandRevokeCertificate
	// entry applied above).
	nodeB := tc.join("node-b", nodeA)

	// The core assertion: node-b's OWN TrustStore reflects the revocation
	// - proven by node-b itself REJECTING a connection presenting the
	// revoked identity - even though node-b was never running when the
	// original revoke request was made.
	waitForRevocationReplicated(t, observer, nodeB.apiAddr, token, victimSerial, 5*time.Second)
	if _, err := tc.getStatus(victimClient, nodeB.apiAddr); err == nil {
		t.Fatalf("node-b (which joined AFTER the revocation event) still accepted the revoked identity - its own TrustStore did not converge via log replication")
	}
}
