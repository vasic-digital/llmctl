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
	"net/http/httptrace"
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

// httpClientForTimeout builds a real HTTP/3+mTLS "test-observer" client
// identical to cluster_bootstrap_test.go's testCluster.httpClient()
// EXCEPT for its own Client.Timeout, which callers supply explicitly -
// needed by any test whose real call can legitimately take longer than
// httpClient()'s own fixed 5s (e.g.
// TestMTLSRotation_QuorumProtection_LiveHandshakeDetectsSIGKilledVoter's
// revoke call, which can take up to routes_mtls.go's own real
// liveVoterCheckTimeout while the leader's handler live-checks a
// SIGKILL'd voter before refusing).
func (tc *testCluster) httpClientForTimeout(timeout time.Duration) *http.Client {
	tc.t.Helper()
	nodeCert, err := tc.ca.IssueNodeCert("test-observer-long-timeout")
	if err != nil {
		tc.t.Fatalf("issue observer cert: %v", err)
	}
	cert, err := mtls.LoadTLSCertificate(nodeCert.CertPEM, nodeCert.KeyPEM)
	if err != nil {
		tc.t.Fatalf("load observer cert: %v", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(tc.ca.CertPEM) {
		tc.t.Fatalf("add CA cert to observer pool")
	}
	store, err := mtls.NewTrustStore(pool, &cert)
	if err != nil {
		tc.t.Fatalf("NewTrustStore(observer): %v", err)
	}
	tlsConf := &tls.Config{
		GetClientCertificate:  store.GetClientCertificate,
		RootCAs:               pool,
		InsecureSkipVerify:    true,
		VerifyPeerCertificate: raft.VerifyPeerCertificateAgainstCA(store),
	}
	return &http.Client{Transport: &http3.Transport{TLSClientConfig: tlsConf}, Timeout: timeout}
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

// renewResponse mirrors internal/api/routes_mtls.go's POST
// /v1/cluster/mtls/renew JSON response shape (T016) - duplicated here as a
// plain, decoupled local type matching only the JSON contract, exactly as
// this file's other response types (revocationsResponse) already do.
type renewResponse struct {
	Status           string `json:"status"`
	RaftSerialNumber string `json:"raft_serial_number"`
	APISerialNumber  string `json:"api_serial_number"`
}

// renewCertificate POSTs a real renew request (T016, spec.md FR-005/FR-006,
// User Story 2) to apiAddr's real POST /v1/cluster/mtls/renew route -
// TARGETING THAT SPECIFIC NODE'S OWN PROCESS, since renewal is a LOCAL,
// per-process TrustStore.UpdateNodeCert action (research.md/data-model.md's
// documented design: unlike revocation, renewal is never Raft-replicated -
// there is nothing to coordinate, since only the renewed node's own
// transports ever need to start presenting the fresh certificate). Bears
// token as an "Authorization: Bearer" header, mirroring revokeCertificate's
// identical RBAC-gated-action pattern, and fails the test loudly (never a
// silent skip) if the real HTTP response is not 200 OK.
func renewCertificate(t *testing.T, client *http.Client, apiAddr, token string) renewResponse {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, "https://"+apiAddr+"/v1/cluster/mtls/renew", nil)
	if err != nil {
		t.Fatalf("new renew request to %s: %v", apiAddr, err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("POST /v1/cluster/mtls/renew to %s: %v", apiAddr, err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		t.Fatalf("POST /v1/cluster/mtls/renew to %s: status = %d, body = %s", apiAddr, resp.StatusCode, respBody)
	}
	var got renewResponse
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatalf("decode /v1/cluster/mtls/renew response from %s: %v", apiAddr, err)
	}
	return got
}

// tracedGetResult carries everything doTracedGet observes about ONE real
// HTTP/3+mTLS request/response pair - both the ordinary response and the
// REAL connection-level facts httptrace.ClientTrace exposes, which is what
// lets T014/T015 below prove "the same underlying connection" or "a
// genuinely fresh connection" as CAPTURED EVIDENCE (Constitution
// §11.4.107/§11.4.5) rather than merely asserting "no error was returned".
type tracedGetResult struct {
	statusCode int
	// reused is httptrace.GotConnInfo.Reused - quic-go's http3.Transport
	// (confirmed against its real source, http3/transport.go's dial/
	// getConn and http3/trace.go's traceGotConn) sets this true ONLY when
	// an EXISTING, already-handshaked *quic.Conn from its own per-hostname
	// connection cache is reused for this request, and false when a
	// genuinely NEW dial+TLS-handshake occurred - the exact real signal
	// (never a guess) this file's own
	// TestMTLSRotation_RevokedCertificate_RejectedClusterWide already
	// relies on existing (its CloseIdleConnections() comment documents the
	// same underlying cache).
	reused bool
	// localAddr is the real local (client-side) address httptrace reports
	// for the connection this specific request used - a SEPARATE,
	// corroborating signal from reused: the SAME underlying QUIC
	// connection keeps the SAME local ephemeral UDP port for its entire
	// lifetime, while a fresh dial always gets a new one, so two requests
	// reporting the SAME localAddr is independent proof (not merely
	// trusting one boolean field) that no new connection was ever made.
	localAddr string
	// peerLeaf is the REAL x509 leaf certificate the SERVER actually
	// presented during this connection's TLS handshake (Go's own
	// tls.ConnectionState.PeerCertificates, populated by quic-go's http3
	// client - confirmed against its real source, http3/client.go's
	// `res.TLS = &connState` assignment) - inspected directly, never
	// inferred from what a JSON response body merely claims, per this
	// project's anti-bluff discipline and the task's explicit "inspect the
	// real serial/validity, not merely no error" requirement.
	peerLeaf *x509.Certificate
}

// doTracedGet issues a real GET to url over client, attaching a
// httptrace.ClientTrace to the request's own context so the REAL,
// connection-level facts above are captured for THIS specific request -
// never assumed from the surrounding test's own bookkeeping.
func doTracedGet(t *testing.T, client *http.Client, url string) tracedGetResult {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		t.Fatalf("new traced GET request to %s: %v", url, err)
	}
	var result tracedGetResult
	trace := &httptrace.ClientTrace{
		GotConn: func(info httptrace.GotConnInfo) {
			result.reused = info.Reused
			if info.Conn != nil {
				result.localAddr = info.Conn.LocalAddr().String()
			}
		},
	}
	req = req.WithContext(httptrace.WithClientTrace(req.Context(), trace))
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("traced GET %s: %v", url, err)
	}
	defer func() { _ = resp.Body.Close() }()
	_, _ = io.ReadAll(resp.Body) // drain fully so the connection is genuinely reusable for a subsequent request
	result.statusCode = resp.StatusCode
	if resp.TLS != nil && len(resp.TLS.PeerCertificates) > 0 {
		result.peerLeaf = resp.TLS.PeerCertificates[0]
	}
	return result
}

// TestMTLSRotation_LiveRenewal_ExistingConnectionSurvives is T014 (spec.md
// User Story 2, Acceptance Scenario 2, quickstart.md Scenario 2 steps 1-3;
// FR-006): a real, already-established connection to a node is NOT
// abruptly severed by that SAME node's own certificate renewal.
//
// Proof strategy (never merely "the second request returned no error" -
// that alone would pass even if the http3.Transport silently redialed a
// brand-new connection behind the scenes, which would prove NOTHING about
// whether the EXISTING connection specifically survived): the held
// client's SECOND request, made after renewal with NO
// CloseIdleConnections() call in between, must report
// httptrace.GotConnInfo.Reused == true AND the SAME real local address as
// the first request - two independent, real, connection-level signals
// that the underlying *quic.Conn from before renewal is the EXACT one
// still being used, never a fresh one.
func TestMTLSRotation_LiveRenewal_ExistingConnectionSurvives(t *testing.T) {
	tc := newTestCluster(t)

	nodeA := tc.bootstrap("node-a")
	nodeB := tc.join("node-b", nodeA)

	observer := tc.httpClient()
	token := tc.adminToken()

	// holder is a DEDICATED client whose own cached connection to node-b
	// this test tracks end to end - kept separate from observer (which
	// issues the renew request itself) so the act of TRIGGERING renewal
	// can never be confused with the connection being tested for survival.
	holder := tc.httpClient()

	statusURL := "https://" + nodeB.apiAddr + "/v1/cluster/status"

	// First request: establishes (and caches, per quic-go's documented
	// per-hostname connection pooling) a real QUIC connection to node-b.
	before := doTracedGet(t, holder, statusURL)
	if before.statusCode != http.StatusOK {
		t.Fatalf("initial request to node-b: status = %d", before.statusCode)
	}
	if before.reused {
		t.Fatalf("initial request unexpectedly reported Reused=true - holder should not have any prior connection to node-b yet")
	}
	if before.localAddr == "" {
		t.Fatalf("initial request reported no local address - httptrace.GotConnInfo was never observed, cannot prove connection identity")
	}

	// Renew node-b's own certificate(s) - a LOCAL action against node-b's
	// own process (T016), triggered here via observer, a SEPARATE client
	// from holder, so holder's cached connection is never touched by the
	// act of making this renew call itself.
	renewCertificate(t, observer, nodeB.apiAddr, token)

	// The core assertion: a SECOND request over holder - the SAME
	// http.Client, with NO CloseIdleConnections() call - succeeds AND
	// genuinely reuses the identical pre-renewal connection.
	after := doTracedGet(t, holder, statusURL)
	if after.statusCode != http.StatusOK {
		t.Fatalf("existing connection's request AFTER renewal: status = %d - the renewal severed it", after.statusCode)
	}
	if !after.reused {
		t.Fatalf("existing connection was NOT reused after renewal (httptrace reported Reused=false) - the renewal replaced it with a new connection instead of leaving it alone, violating FR-006's zero-downtime requirement")
	}
	if after.localAddr != before.localAddr {
		t.Fatalf("existing connection's local address changed after renewal (%q -> %q) - this is a DIFFERENT underlying connection, not the one that survived, violating FR-006", before.localAddr, after.localAddr)
	}
}

// TestMTLSRotation_LiveRenewal_NewConnectionsUseFreshCert is T015 (spec.md
// User Story 2, Acceptance Scenario 1/3, quickstart.md Scenario 2 step 4;
// FR-005): after a real renewal, a genuinely NEW connection attempt to
// that node presents the FRESH certificate - proven by inspecting the real
// x509 serial number and validity window Go's own tls.ConnectionState
// reports for the server's ACTUAL presented leaf certificate on that new
// connection, cross-checked against BOTH the pre-renewal serial (must
// differ) AND the renew action's own claimed new serial (must match) -
// never merely "the request succeeded with no error".
func TestMTLSRotation_LiveRenewal_NewConnectionsUseFreshCert(t *testing.T) {
	tc := newTestCluster(t)

	nodeA := tc.bootstrap("node-a")
	nodeB := tc.join("node-b", nodeA)

	observer := tc.httpClient()
	token := tc.adminToken()

	statusURL := "https://" + nodeB.apiAddr + "/v1/cluster/status"

	// BEFORE renewal: a real connection's real presented certificate -
	// captured as the "old" identity this test proves is retired for NEW
	// connections going forward.
	before := doTracedGet(t, tc.httpClient(), statusURL)
	if before.statusCode != http.StatusOK {
		t.Fatalf("before-renewal request to node-b: status = %d", before.statusCode)
	}
	if before.peerLeaf == nil {
		t.Fatalf("before-renewal request presented no peer certificate - cannot establish a baseline serial to compare against")
	}
	oldSerial := before.peerLeaf.SerialNumber.String()

	// Renew node-b's own certificate(s), capturing the renew action's OWN
	// claimed new API-transport serial number as one independent fact this
	// test will cross-check the ACTUALLY-PRESENTED certificate against.
	renewed := renewCertificate(t, observer, nodeB.apiAddr, token)
	if renewed.APISerialNumber == "" {
		t.Fatalf("renew response carried no api_serial_number - cannot verify what the fresh certificate's real identity should be")
	}
	if renewed.APISerialNumber == oldSerial {
		t.Fatalf("renew response's claimed new api_serial_number (%s) is IDENTICAL to the pre-renewal serial - the renewal did not actually issue a fresh certificate", renewed.APISerialNumber)
	}

	// AFTER renewal: a BRAND NEW http.Client (a fresh *http3.Transport with
	// its own empty connection cache, never sharing any state with
	// `before`'s client) forces a genuinely NEW TLS handshake - the exact
	// real-world shape of "a new connection attempt" this test must prove
	// presents the fresh certificate.
	after := doTracedGet(t, tc.httpClient(), statusURL)
	if after.statusCode != http.StatusOK {
		t.Fatalf("after-renewal new-connection request to node-b: status = %d", after.statusCode)
	}
	if after.peerLeaf == nil {
		t.Fatalf("after-renewal new-connection request presented no peer certificate")
	}

	newSerial := after.peerLeaf.SerialNumber.String()
	if newSerial == oldSerial {
		t.Fatalf("a NEW connection AFTER renewal still presented the OLD pre-renewal serial %s - node-b did not begin presenting the fresh certificate for new connections (FR-005 violated)", oldSerial)
	}
	if newSerial != renewed.APISerialNumber {
		t.Fatalf("a NEW connection's ACTUALLY-PRESENTED certificate serial (%s) does not match the renew action's OWN claimed new serial (%s) - the server is presenting a certificate other than the one it just issued", newSerial, renewed.APISerialNumber)
	}

	// Validity-window inspection (the task's explicit "...and validity"
	// requirement, not merely the serial number): certs.go's IssueNodeCert
	// always sets NotBefore = issuance-time-minus-1h (clock-skew
	// tolerance) and NotAfter = issuance-time-plus-365d (certValidity),
	// so NotAfter-NotBefore is an EXACT, non-guessed invariant of every
	// certificate this CA ever issues - proving `after.peerLeaf` really is
	// a certificate this CA freshly issued (not, say, some stale fixture
	// smuggled in), independent of wall-clock skew on the machine running
	// this test.
	const wantValidityWindow = 365*24*time.Hour + time.Hour
	gotValidityWindow := after.peerLeaf.NotAfter.Sub(after.peerLeaf.NotBefore)
	const tolerance = 5 * time.Second
	if diff := gotValidityWindow - wantValidityWindow; diff > tolerance || diff < -tolerance {
		t.Fatalf("fresh certificate's validity window (NotAfter-NotBefore = %s) does not match this CA's own IssueNodeCert invariant (want %s +/- %s)", gotValidityWindow, wantValidityWindow, tolerance)
	}
	if time.Until(after.peerLeaf.NotAfter) < 300*24*time.Hour {
		t.Fatalf("fresh certificate's NotAfter (%s) is less than 300 days from now - does not look like a freshly-issued 365-day certificate", after.peerLeaf.NotAfter)
	}
}

// --- Feature 004 Phase 5 (User Story 3): CA rotation - T018-T021 ---

// httpClientForCertTrustingCAs is httpClientForCert generalized to trust
// MULTIPLE CAs at once - needed for CA-rotation tests, where a real node
// may legitimately present a certificate signed by EITHER the outgoing
// or the incoming CA depending on whether it has renewed yet (FR-008
// dual trust), so a test client verifying that node's presented
// certificate must itself trust both.
func (tc *testCluster) httpClientForCertTrustingCAs(nodeCert *mtls.NodeCert, cas ...*mtls.CA) *http.Client {
	tc.t.Helper()
	cert, err := mtls.LoadTLSCertificate(nodeCert.CertPEM, nodeCert.KeyPEM)
	if err != nil {
		tc.t.Fatalf("load cert: %v", err)
	}
	pool := x509.NewCertPool()
	for _, ca := range cas {
		if !pool.AppendCertsFromPEM(ca.CertPEM) {
			tc.t.Fatalf("add CA cert to pool")
		}
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

// httpClientTrustingCAs builds a dual (or multi)-CA-trusting client
// presenting a fresh "test-observer-dual" identity signed by the FIRST
// named CA - used as this test's own driving/observing client once a CA
// rotation is in progress, since dual trust means a client presenting
// EITHER CA's identity is accepted by every real node's own server-side
// mutual-TLS verification throughout the transition (steady-state
// tc.httpClient() alone stops working the moment a node it talks to has
// renewed under the incoming CA, per FR-008's OWN symmetry: trust is
// mutual, not merely server-to-client).
func (tc *testCluster) httpClientTrustingCAs(cas ...*mtls.CA) *http.Client {
	tc.t.Helper()
	nodeCert, err := cas[0].IssueNodeCert("test-observer-dual")
	if err != nil {
		tc.t.Fatalf("issue dual-trust observer cert: %v", err)
	}
	return tc.httpClientForCertTrustingCAs(nodeCert, cas...)
}

// beginCARotationRequestJSON/caRotationResponseJSON/caRotationEventJSON/
// caRotationStatusResponseJSON mirror internal/api/routes_mtls.go's JSON
// wire shapes for the begin/status/finalize actions - duplicated here as
// plain, decoupled local types (matching only the JSON contract), exactly
// as this file's other request/response types already do.
type beginCARotationRequestJSON struct {
	IncomingCACertPEM string `json:"incoming_ca_cert_pem"`
	IncomingCAKeyPEM  string `json:"incoming_ca_key_pem"`
}

type caRotationResponseJSON struct {
	Status                string `json:"status"`
	OutgoingCAFingerprint string `json:"outgoing_ca_fingerprint"`
	IncomingCAFingerprint string `json:"incoming_ca_fingerprint"`
}

type caRotationEventJSON struct {
	OutgoingCAFingerprint string    `json:"outgoing_ca_fingerprint"`
	IncomingCAFingerprint string    `json:"incoming_ca_fingerprint"`
	TransitionedNodeIDs   []string  `json:"transitioned_node_ids"`
	Status                string    `json:"status"`
	BegunAt               time.Time `json:"begun_at"`
	FinalizedAt           time.Time `json:"finalized_at"`
}

type caRotationStatusResponseJSON struct {
	Rotation      *caRotationEventJSON `json:"rotation"`
	LocallyLoaded bool                 `json:"locally_loaded"`
}

// beginCARotation POSTs a real begin-rotation request (T024, spec.md
// FR-007/FR-008) to apiAddr, carrying incomingCA's real cert+key PEM -
// fails the test loudly (never a silent skip) on a non-200 response.
func beginCARotation(t *testing.T, client *http.Client, apiAddr, token string, incomingCA *mtls.CA) caRotationResponseJSON {
	t.Helper()
	body, err := json.Marshal(beginCARotationRequestJSON{
		IncomingCACertPEM: string(incomingCA.CertPEM),
		IncomingCAKeyPEM:  string(incomingCA.KeyPEM),
	})
	if err != nil {
		t.Fatalf("marshal begin rotation request: %v", err)
	}
	req, err := http.NewRequest(http.MethodPost, "https://"+apiAddr+"/v1/cluster/mtls/rotate/begin", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("new begin rotation request to %s: %v", apiAddr, err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("POST /v1/cluster/mtls/rotate/begin to %s: %v", apiAddr, err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		t.Fatalf("POST /v1/cluster/mtls/rotate/begin to %s: status = %d, body = %s", apiAddr, resp.StatusCode, respBody)
	}
	var got caRotationResponseJSON
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatalf("decode begin rotation response from %s: %v", apiAddr, err)
	}
	return got
}

// caRotationStatus GETs apiAddr's real rotate/status route.
func caRotationStatus(t *testing.T, client *http.Client, apiAddr, token string) caRotationStatusResponseJSON {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, "https://"+apiAddr+"/v1/cluster/mtls/rotate/status", nil)
	if err != nil {
		t.Fatalf("new rotate status request to %s: %v", apiAddr, err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("GET /v1/cluster/mtls/rotate/status to %s: %v", apiAddr, err)
	}
	defer func() { _ = resp.Body.Close() }()
	var got caRotationStatusResponseJSON
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatalf("decode rotate status response from %s: %v", apiAddr, err)
	}
	return got
}

// waitForRotationStatus polls apiAddr's real rotate/status route until
// its Rotation.Status equals wantStatus (tolerating real Raft-replication
// lag, matching waitForRevocationReplicated's identical polling pattern
// above), or fails the test if it never converges within timeout.
func waitForRotationStatus(t *testing.T, client *http.Client, apiAddr, token, wantStatus string, timeout time.Duration) caRotationStatusResponseJSON {
	t.Helper()
	deadline := time.Now().Add(timeout)
	var last caRotationStatusResponseJSON
	for time.Now().Before(deadline) {
		last = caRotationStatus(t, client, apiAddr, token)
		if last.Rotation != nil && last.Rotation.Status == wantStatus {
			return last
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("%s never observed rotation status %q within %s (last: %+v)", apiAddr, wantStatus, timeout, last.Rotation)
	return last
}

// finalizeCARotationAttempt POSTs a real finalize request and returns the
// raw status/body WITHOUT failing the test on a non-200 response -
// callers decide whether success or refusal is the expected outcome
// (T021's stranding test expects refusal; T020 expects success via the
// finalizeCARotation wrapper below).
func finalizeCARotationAttempt(t *testing.T, client *http.Client, apiAddr, token string) (int, []byte) {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, "https://"+apiAddr+"/v1/cluster/mtls/rotate/finalize", nil)
	if err != nil {
		t.Fatalf("new finalize request to %s: %v", apiAddr, err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("POST /v1/cluster/mtls/rotate/finalize to %s: %v", apiAddr, err)
	}
	defer func() { _ = resp.Body.Close() }()
	body, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, body
}

// finalizeCARotation is finalizeCARotationAttempt's fail-loudly-on-refusal
// counterpart, mirroring revokeCertificate's identical convention above.
func finalizeCARotation(t *testing.T, client *http.Client, apiAddr, token string) caRotationResponseJSON {
	t.Helper()
	status, body := finalizeCARotationAttempt(t, client, apiAddr, token)
	if status != http.StatusOK {
		t.Fatalf("POST /v1/cluster/mtls/rotate/finalize to %s: status = %d, body = %s", apiAddr, status, body)
	}
	var got caRotationResponseJSON
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("decode finalize response from %s: %v", apiAddr, err)
	}
	return got
}

// attemptRevoke is revokeCertificate's non-fatal-on-refusal counterpart
// (T021): returns the raw status/body instead of failing the test, so a
// test can assert a REFUSAL (FR-010) is the correct outcome.
func attemptRevoke(t *testing.T, client *http.Client, apiAddr, token, serialNumber, nodeID, reason string) (int, []byte) {
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
	respBody, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, respBody
}

// waitAndFindLeader polls every node's real GET /v1/cluster/status until
// exactly one reports IsLeader == true, returning that node - the same
// precondition TestMTLSRotation_RevokedNode_CannotRejoin's own comment
// documents as load-bearing for any leader-only write (begin/finalize/
// revoke's real hashicorp/raft Apply calls all require it).
func waitAndFindLeader(t *testing.T, tc *testCluster, client *http.Client, nodes []*spawnedNode, timeout time.Duration) *spawnedNode {
	t.Helper()
	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		for _, n := range nodes {
			status, err := tc.getStatus(client, n.apiAddr)
			if err != nil {
				lastErr = err
				continue
			}
			if status.IsLeader {
				return n
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("no leader elected among %d real nodes within %s (last error: %v)", len(nodes), timeout, lastErr)
	return nil
}

// waitForQuorumHealthy asserts EVERY node in nodes is reachable via
// client AND reports a CONSISTENT view of leadership (exactly one node
// among them currently believes it is the real Raft leader) - the
// concrete, real, observable signal T019 needs "leader election/quorum
// health is checked and holds" to mean, proven fresh at each call site
// (never assumed to still hold from an earlier check).
func waitForQuorumHealthy(t *testing.T, tc *testCluster, client *http.Client, nodes []*spawnedNode, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	var lastErr error
	for time.Now().Before(deadline) {
		leaders := 0
		allReachable := true
		for _, n := range nodes {
			status, err := tc.getStatus(client, n.apiAddr)
			if err != nil {
				allReachable = false
				lastErr = err
				break
			}
			if status.IsLeader {
				leaders++
			}
		}
		if allReachable && leaders == 1 {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("quorum not healthy (every node reachable + exactly one leader) within %s (last error: %v)", timeout, lastErr)
}

// waitForFullConfig is the "all N nodes durably observe the full
// configuration" precondition several existing tests in this package
// already establish inline (TestClusterBootstrap_*,
// TestMTLSRotation_RevokedCertificate_RejectedClusterWide) - factored out
// here since every T018-T021 test needs it identically.
func waitForFullConfig(t *testing.T, tc *testCluster, client *http.Client, nodes []*spawnedNode, want int, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for _, n := range nodes {
		for {
			got, err := tc.getNodes(client, n.apiAddr)
			if err == nil && len(got.Servers) == want {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("precondition failed: node %q never observed the full %d-node configuration", n.nodeID, want)
			}
			time.Sleep(50 * time.Millisecond)
		}
	}
}

// TestMTLSRotation_DualTrust_AcceptsBothOldAndNewCA is T018 (spec.md User
// Story 3, Acceptance Scenario 1, quickstart.md Scenario 3 step 2;
// FR-008): during an in-progress CA rotation, EVERY real node accepts a
// connection presenting a certificate signed by EITHER the outgoing CA-1
// or the incoming CA-2.
func TestMTLSRotation_DualTrust_AcceptsBothOldAndNewCA(t *testing.T) {
	tc := newTestCluster(t)
	nodeA := tc.bootstrap("node-a")
	nodeB := tc.join("node-b", nodeA)
	nodeC := tc.join("node-c", nodeA)
	nodes := []*spawnedNode{nodeA, nodeB, nodeC}

	observer := tc.httpClient()
	token := tc.adminToken()

	waitForFullConfig(t, tc, observer, nodes, 3, 5*time.Second)
	leader := waitAndFindLeader(t, tc, observer, nodes, 5*time.Second)

	newCA, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA (incoming): %v", err)
	}

	// Begin against the real leader FIRST (the durable, Raft-replicated
	// record), then against the two followers (pure local dual-trust
	// activation, per routes_mtls.go's own documented per-node
	// out-of-band distribution design) - the SAME operational recipe
	// quickstart.md Scenario 3 step 2 describes.
	beginCARotation(t, observer, leader.apiAddr, token, newCA)
	for _, n := range nodes {
		if n == leader {
			continue
		}
		beginCARotation(t, observer, n.apiAddr, token, newCA)
	}

	for _, n := range nodes {
		st := waitForRotationStatus(t, observer, n.apiAddr, token, "in_progress", 5*time.Second)
		if !st.LocallyLoaded {
			t.Fatalf("node %q: LocallyLoaded = false after this test called begin against it directly", n.nodeID)
		}
	}

	oldCert, err := tc.ca.IssueNodeCert("node-old-identity-during-rotation")
	if err != nil {
		t.Fatalf("issue old-CA cert: %v", err)
	}
	newCert, err := newCA.IssueNodeCert("node-new-identity-during-rotation")
	if err != nil {
		t.Fatalf("issue new-CA cert: %v", err)
	}
	oldClient := tc.httpClientForCertTrustingCAs(oldCert, tc.ca, newCA)
	newClient := tc.httpClientForCertTrustingCAs(newCert, tc.ca, newCA)

	for _, n := range nodes {
		if _, err := tc.getStatus(oldClient, n.apiAddr); err != nil {
			t.Fatalf("node %q rejected an OLD (CA-1)-signed identity during the dual-trust transition window - FR-008 violated: %v", n.nodeID, err)
		}
		if _, err := tc.getStatus(newClient, n.apiAddr); err != nil {
			t.Fatalf("node %q rejected a NEW (CA-2)-signed identity during the dual-trust transition window - FR-008 violated: %v", n.nodeID, err)
		}
	}
}

// TestMTLSRotation_FullRotation_NeverDropsQuorum is T019 (spec.md User
// Story 3, Acceptance Scenario 2, quickstart.md Scenario 3 step 3): every
// node's certificate is re-issued under the incoming CA ONE AT A TIME on
// a real 3-node cluster, with real leader-election/quorum health checked
// and proven to hold AFTER EACH INDIVIDUAL re-issuance step - the
// load-bearing test for this whole feature's "no availability-impacting
// outage" promise (SC-003).
func TestMTLSRotation_FullRotation_NeverDropsQuorum(t *testing.T) {
	tc := newTestCluster(t)
	nodeA := tc.bootstrap("node-a")
	nodeB := tc.join("node-b", nodeA)
	nodeC := tc.join("node-c", nodeA)
	nodes := []*spawnedNode{nodeA, nodeB, nodeC}

	observer := tc.httpClient()
	token := tc.adminToken()

	waitForFullConfig(t, tc, observer, nodes, 3, 5*time.Second)
	leader := waitAndFindLeader(t, tc, observer, nodes, 5*time.Second)
	waitForQuorumHealthy(t, tc, observer, nodes, 5*time.Second)

	newCA, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA (incoming): %v", err)
	}

	beginCARotation(t, observer, leader.apiAddr, token, newCA)
	for _, n := range nodes {
		if n == leader {
			continue
		}
		beginCARotation(t, observer, n.apiAddr, token, newCA)
	}
	for _, n := range nodes {
		waitForRotationStatus(t, observer, n.apiAddr, token, "in_progress", 5*time.Second)
	}

	// dualObserver trusts BOTH CAs - required from this point forward
	// since a renewed node's own presented certificate will chain to
	// CA-2, which the steady-state observer (CA-1 only) cannot verify
	// (see httpClientTrustingCAs's own doc comment).
	dualObserver := tc.httpClientTrustingCAs(tc.ca, newCA)

	// Quorum must already hold the instant dual trust is active
	// everywhere, BEFORE any certificate is actually re-issued.
	waitForQuorumHealthy(t, tc, dualObserver, nodes, 5*time.Second)

	// The load-bearing assertion (T019): re-issue EACH node's certificate
	// ONE AT A TIME, checking real leader-election/quorum health after
	// EVERY individual step - never only at the very end.
	for _, n := range nodes {
		renewed := renewCertificateDual(t, dualObserver, n.apiAddr, token)
		if n == leader && !renewed.CARotationTransitionRecorded {
			t.Fatalf("node %q (the real Raft leader) renewed but did NOT durably record its own CA-rotation transition - this write should always succeed when performed on the leader itself", n.nodeID)
		}
		waitForQuorumHealthy(t, tc, dualObserver, nodes, 5*time.Second)
	}
}

// renewCertificateDual is renewCertificate's own JSON-decoding logic,
// duplicated here (rather than reused) ONLY because it must decode the
// newly-added CARotationTransitionRecorded field this test needs to
// assert on - renewResponse (defined above, alongside renewCertificate)
// is left unchanged so TestMTLSRotation_LiveRenewal_* above keep
// decoding exactly the fields they already assert on, unaffected by this
// Phase 5 addition.
type renewResponseWithRotation struct {
	Status                       string `json:"status"`
	RaftSerialNumber             string `json:"raft_serial_number"`
	APISerialNumber              string `json:"api_serial_number"`
	CARotationTransitionRecorded bool   `json:"ca_rotation_transition_recorded"`
}

func renewCertificateDual(t *testing.T, client *http.Client, apiAddr, token string) renewResponseWithRotation {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, "https://"+apiAddr+"/v1/cluster/mtls/renew", nil)
	if err != nil {
		t.Fatalf("new renew request to %s: %v", apiAddr, err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("POST /v1/cluster/mtls/renew to %s: %v", apiAddr, err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		t.Fatalf("POST /v1/cluster/mtls/renew to %s: status = %d, body = %s", apiAddr, resp.StatusCode, respBody)
	}
	var got renewResponseWithRotation
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatalf("decode /v1/cluster/mtls/renew response from %s: %v", apiAddr, err)
	}
	return got
}

// TestMTLSRotation_Finalize_OldCARejectedAfterward is T020 (spec.md User
// Story 3, Acceptance Scenario 3, quickstart.md Scenario 3 step 4): after
// every node has transitioned and an operator finalizes the rotation, a
// connection attempt presenting a certificate signed by the now-retired
// CA-1 is genuinely rejected everywhere.
func TestMTLSRotation_Finalize_OldCARejectedAfterward(t *testing.T) {
	tc := newTestCluster(t)
	nodeA := tc.bootstrap("node-a")
	nodeB := tc.join("node-b", nodeA)
	nodeC := tc.join("node-c", nodeA)
	nodes := []*spawnedNode{nodeA, nodeB, nodeC}

	observer := tc.httpClient()
	token := tc.adminToken()

	waitForFullConfig(t, tc, observer, nodes, 3, 5*time.Second)
	leader := waitAndFindLeader(t, tc, observer, nodes, 5*time.Second)

	newCA, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA (incoming): %v", err)
	}

	beginCARotation(t, observer, leader.apiAddr, token, newCA)
	for _, n := range nodes {
		if n == leader {
			continue
		}
		beginCARotation(t, observer, n.apiAddr, token, newCA)
	}
	for _, n := range nodes {
		waitForRotationStatus(t, observer, n.apiAddr, token, "in_progress", 5*time.Second)
	}

	dualObserver := tc.httpClientTrustingCAs(tc.ca, newCA)

	// Renew every node under the new CA - performed against the LEADER
	// FIRST so its own transition is guaranteed durably recorded
	// (renewCertificateDual's real HTTP response proves this), then the
	// two followers (their certs are renewed identically; see this
	// file's own documented honest scope boundary on
	// CARotationTransitionRecorded for followers).
	renewed := renewCertificateDual(t, dualObserver, leader.apiAddr, token)
	if !renewed.CARotationTransitionRecorded {
		t.Fatalf("leader %q's own renewal did not durably record its transition", leader.nodeID)
	}
	for _, n := range nodes {
		if n == leader {
			continue
		}
		renewCertificateDual(t, dualObserver, n.apiAddr, token)
	}

	finalizeCARotation(t, dualObserver, leader.apiAddr, token)
	for _, n := range nodes {
		waitForRotationStatus(t, dualObserver, n.apiAddr, token, "finalized", 5*time.Second)
	}

	// Force fresh connections (quic-go's http3.Transport per-hostname
	// connection cache - see TestMTLSRotation_RevokedCertificate_
	// RejectedClusterWide's identical CloseIdleConnections() call for the
	// full root-cause explanation) before the core AFTER-finalize
	// rejection assertion.
	oldCert, err := tc.ca.IssueNodeCert("node-old-after-finalize")
	if err != nil {
		t.Fatalf("issue post-finalize old-CA cert: %v", err)
	}
	// Trusts ONLY the incoming CA (newCA) - so a connection FAILURE below
	// is unambiguously the SERVER rejecting this OLD-CA-signed CLIENT
	// identity (mutual TLS), never this client itself failing to verify
	// the server's own (now CA-2-only) certificate.
	oldClient := tc.httpClientForCertTrustingCAs(oldCert, newCA)

	for _, n := range nodes {
		if _, err := tc.getStatus(oldClient, n.apiAddr); err == nil {
			t.Fatalf("AFTER finalize, node %q still accepted a certificate signed by the retired outgoing CA - FR-008/Acceptance Scenario 3 violated", n.nodeID)
		}
	}
}

// TestMTLSRotation_QuorumProtection_RefusesStrandingAction is T021
// (quickstart.md Scenario 4, spec.md FR-010's shared Edge Case): an
// action that would leave the cluster without enough trusted, reachable
// voters to maintain its own operational quorum is refused, not silently
// executed. Exercised via the revoke path (quorumWouldBeStranded's own
// doc comment in routes_mtls.go: this is the SAME shared check finalize
// also uses) - deterministic and independent of any CA-rotation state.
func TestMTLSRotation_QuorumProtection_RefusesStrandingAction(t *testing.T) {
	tc := newTestCluster(t)
	nodeA := tc.bootstrap("node-a")
	nodeB := tc.join("node-b", nodeA)
	nodeC := tc.join("node-c", nodeA)
	nodes := []*spawnedNode{nodeA, nodeB, nodeC}

	observer := tc.httpClient()
	token := tc.adminToken()

	waitForFullConfig(t, tc, observer, nodes, 3, 5*time.Second)
	leader := waitAndFindLeader(t, tc, observer, nodes, 5*time.Second)

	// Negative control (proves the check does not ALWAYS refuse): revoke
	// node-b, ONE of 3 voters - remaining 2/3 STILL meets quorum(2) -
	// must SUCCEED.
	victimCertB, err := tc.ca.IssueNodeCert("node-b")
	if err != nil {
		t.Fatalf("issue node-b cert: %v", err)
	}
	serialB := certSerialNumber(t, victimCertB.CertPEM)
	revokeCertificate(t, observer, leader.apiAddr, token, serialB, "node-b", "test: still-quorum-safe")
	waitForRevocationReplicated(t, observer, leader.apiAddr, token, serialB, 5*time.Second)

	// The core assertion (T021/FR-010): attempting to ALSO revoke node-c
	// (a SECOND of the 3 voters) would leave only 1/3 trusted voters -
	// below the quorum(2) this 3-node cluster needs - and MUST be
	// refused.
	victimCertC, err := tc.ca.IssueNodeCert("node-c")
	if err != nil {
		t.Fatalf("issue node-c cert: %v", err)
	}
	serialC := certSerialNumber(t, victimCertC.CertPEM)
	status, body := attemptRevoke(t, observer, leader.apiAddr, token, serialC, "node-c", "test: would-strand-cluster")
	if status == http.StatusOK {
		t.Fatalf("revoking node-c (after node-b was already revoked) SUCCEEDED - this would leave only 1/3 trusted voters, below the quorum this 3-node cluster needs; FR-010 requires refusal. response body = %s", body)
	}

	// FR-012 (revocation is independent of membership eviction, already
	// proven for a SINGLE revocation by T013/TestMTLSRotation_
	// RevokedCertificate_RejectedClusterWide) still holds after a
	// REFUSED second revocation attempt: the refused action must not
	// have partially applied.
	for _, n := range nodes {
		got, err := tc.getNodes(observer, n.apiAddr)
		if err != nil {
			t.Fatalf("GET /v1/cluster/nodes on %q after the refused revocation: %v", n.nodeID, err)
		}
		if len(got.Servers) != 3 {
			t.Fatalf("node %q reports %d cluster members after a REFUSED revocation (want 3, unchanged)", n.nodeID, len(got.Servers))
		}
	}
}

// TestMTLSRotation_QuorumProtection_LiveHandshakeDetectsSIGKilledVoter is
// T072-FU8's own follow-up (spec.md FR-010, "trusted, REACHABLE nodes" -
// docs/CONTINUATION.md §10h's disclosed boundary): quorumWouldBeStranded
// (routes_mtls.go) used to approximate "trusted" ENTIRELY from Raft's own
// voter CONFIGURATION (raft.Node.Servers()) - a voter that is genuinely
// dead right now (crashed, partitioned) but has NOT been gracefully
// removed via Node.Leave() (the only real RemoveServer caller) stays
// listed as a configured voter forever, so the old check could approve
// an action that actually strands the cluster's REAL, live quorum. This
// test reproduces exactly that gap on a real 3-node cluster: a real,
// genuine OS-level SIGKILL (never a graceful leave) of one non-leader
// voter, still Raft-configured, then a revoke of a SECOND, different,
// never-revoked voter's certificate that the OLD config-only arithmetic
// alone would have counted as leaving 2 of 3 voters "trusted" - AT the
// quorum(2) this 3-node cluster needs - but which the cluster's REAL,
// live-right-now quorum (the leader ALONE, since the SIGKILL'd voter can
// no longer complete any real mTLS handshake for any purpose) is
// genuinely BELOW. quorumWouldBeStrandedLive's own real, bounded-timeout
// HTTP/3+mTLS handshake against the SIGKILL'd voter's own
// GET /v1/cluster/status (its real API port, now closed by the OS the
// instant the process died) is what must catch this - the shared FR-010
// check both revoke and finalize use, exercised here via revoke exactly
// as T021 above does.
func TestMTLSRotation_QuorumProtection_LiveHandshakeDetectsSIGKilledVoter(t *testing.T) {
	tc := newTestCluster(t)
	nodeA := tc.bootstrap("node-a")
	nodeB := tc.join("node-b", nodeA)
	nodeC := tc.join("node-c", nodeA)
	nodes := []*spawnedNode{nodeA, nodeB, nodeC}

	observer := tc.httpClient()
	token := tc.adminToken()

	// longObserver is a SECOND observer client, identical to observer
	// EXCEPT for its own Client.Timeout: this test's revoke call below
	// can legitimately take up to routes_mtls.go's own
	// liveVoterCheckTimeout (10s, T072-FU8's own disclosed real added
	// latency - quorumWouldBeStrandedLive's own doc comment) while the
	// leader's handler live-checks the just-SIGKILL'd voter before
	// refusing, which exceeds observer's own fixed 5s
	// (cluster_bootstrap_test.go's httpClient(), correctly sized for
	// every OTHER call in this file that never exercises this new
	// live-check path) - used ONLY for the one call genuinely expected
	// to take that long, never for this test's other, fast polling
	// calls.
	longObserver := tc.httpClientForTimeout(20 * time.Second)

	waitForFullConfig(t, tc, observer, nodes, 3, 5*time.Second)
	leader := waitAndFindLeader(t, tc, observer, nodes, 5*time.Second)

	// Pick two DISTINCT non-leader survivors: victim (the one this test
	// genuinely SIGKILLs) and target (the one this test then attempts to
	// revoke - a certificate victim itself never held, so the ONLY thing
	// that could refuse this specific revoke is victim's own real,
	// live-right-now unreachability, never a config-based revocation
	// count).
	var victim, target *spawnedNode
	for _, n := range nodes {
		if n == leader {
			continue
		}
		if victim == nil {
			victim = n
		} else {
			target = n
		}
	}
	if victim == nil || target == nil {
		t.Fatalf("test setup: expected 2 non-leader survivors among 3 nodes, got victim=%v target=%v", victim, target)
	}

	// Genuine OS-level SIGKILL - the SAME real mechanism
	// TestClusterFailover_KillingLeaderElectsNewRealLeaderAmongSurvivors
	// (cluster_bootstrap_test.go) already uses to prove a real crash,
	// never a graceful shutdown. victim's process is now genuinely dead;
	// Raft's own configuration is UNCHANGED (only Node.Leave() calls
	// RemoveServer, per quorumWouldBeStranded's own doc comment) - every
	// node in this cluster, including the leader that will process this
	// test's revoke request below, still lists victim as a Voter.
	if err := victim.cmd.Process.Kill(); err != nil {
		t.Fatalf("SIGKILL %q: %v", victim.nodeID, err)
	}
	_, _ = victim.cmd.Process.Wait()
	delete(tc.nodes, victim.nodeID) // already dead; killAll's own cleanup must not try to signal it again

	// The core assertion (T072-FU8/FR-010): revoking target's certificate
	// is a SINGLE revocation, config-untrusted = {target} only. Raft's
	// own configuration still reports 3 voters (leader, victim, target) -
	// the OLD, config-only quorumWouldBeStranded arithmetic would compute
	// remaining = 3 - 1 = 2, AT quorum(2), and APPROVE this action. The
	// cluster's REAL live quorum right now is only 1 (the leader itself -
	// victim is genuinely dead, target is the one being revoked) - BELOW
	// quorum(2). quorumWouldBeStrandedLive's own real mTLS handshake
	// against victim's (now-closed) API port must discover this and
	// refuse.
	victimCert, err := tc.ca.IssueNodeCert(target.nodeID)
	if err != nil {
		t.Fatalf("issue %s cert: %v", target.nodeID, err)
	}
	serial := certSerialNumber(t, victimCert.CertPEM)
	status, body := attemptRevoke(t, longObserver, leader.apiAddr, token, serial, target.nodeID, "test: SIGKILLed-voter-still-raft-configured")
	if status == http.StatusOK {
		t.Fatalf("revoking %q SUCCEEDED despite %q being genuinely SIGKILL'd (still Raft-voter-configured, never gracefully removed) - this leaves only 1 real live/trusted voter (the leader), below the quorum(2) this 3-node cluster needs; FR-010's live-trust-confirmation (T072-FU8) MUST have refused this. response body = %s", target.nodeID, victim.nodeID, body)
	}

	// The refused action must not have partially applied (mirrors T021's
	// own identical FR-012 check above): target's certificate is NOT
	// revoked on the surviving, reachable nodes.
	for _, n := range []*spawnedNode{leader, target} {
		got, err := getRevocations(t, observer, n.apiAddr, token)
		if err != nil {
			t.Fatalf("GET /v1/cluster/mtls/revocations on %q after the refused revocation: %v", n.nodeID, err)
		}
		if _, revoked := got.Revocations[serial]; revoked {
			t.Fatalf("node %q shows serial %s as revoked after a REFUSED revocation - the refused action partially applied", n.nodeID, serial)
		}
	}
}

// TestMTLSRotation_QuorumProtection_SurvivesFullPriorCARotation is
// T072-FU9's own disclosed-but-not-fixed follow-up (docs/CONTINUATION.md
// §10i, specs/001-llmctl-completion/tasks.md's T072-FU9 entry): "the
// forward-client mTLS identity (mtlsForwardTLS/mtlsForwardStore) is never
// reissued by any handler in [routes_mtls.go] across a completed CA
// rotation, so a revoke/finalize attempted after a full prior rotation
// could see every OTHER voter's live check spuriously fail (peers would
// have dropped trust in the CA that signed this node's own forward-client
// cert)". This test reproduces exactly that: a REAL 3-node cluster runs a
// REAL full CA rotation to completion (begin on every node, renew every
// node under the new CA - leader first, exactly mirroring
// TestMTLSRotation_Finalize_OldCARejectedAfterward's own established
// sequence - then finalize), so every node's TrustStore(s) (Raft-
// transport, HTTP-API, AND each node's own dedicated forward-client store)
// have dropped to single, newCA-only trust. ONLY THEN does this test
// attempt a SECOND, SUBSEQUENT quorum-protected action (a revoke, with a
// NodeID set so FR-010's live-per-voter-trust check -
// quorumWouldBeStrandedLive - genuinely runs) on the leader, and asserts
// it is APPROVED - never spuriously refused.
//
// Root cause this proves, pre-fix: quorumWouldBeStrandedLive dials every
// OTHER real voter using the LEADER's own forwardTLS (mtlsForwardTLS)
// client identity (voterIsLiveAndTrusting's own doc comment). If that
// identity's certificate is still signed by the now-retired outgoing CA
// (because nothing ever reissues it), every OTHER voter - which has
// ALREADY dropped trust in that CA via the finalize step above - genuinely
// rejects the leader's own outbound handshake at the mutual-TLS layer,
// exactly as TestMTLSRotation_Finalize_OldCARejectedAfterward proves for
// an ordinary client connection. quorumWouldBeStrandedLive then counts
// BOTH other real voters as untrusted, leaving only the leader itself (1
// of 3) "trusted" - genuinely below this 3-node cluster's quorum(2) - and
// wrongly refuses a revocation that is, in reality, completely safe: every
// voter is genuinely live and the cluster's real quorum is intact.
//
// This test's OWN observer client (dualObserver) is unaffected by, and
// proves nothing about, this bug: its calls into the leader all reuse
// QUIC/HTTP-3 connections already established earlier in this same test
// (during begin/renew/finalize, back when dual trust was still active -
// TestMTLSRotation_LiveRenewal_ExistingConnectionSurvives's own documented
// mechanism), so they succeed identically whether or not this bug is
// fixed. The bug is entirely SERVER-SIDE, inside the leader's own handler,
// on a BRAND-NEW outbound connection dialled fresh on every
// quorumWouldBeStrandedLive call - which is exactly what this test's core
// assertion (the revoke's real HTTP status code) observes.
func TestMTLSRotation_QuorumProtection_SurvivesFullPriorCARotation(t *testing.T) {
	tc := newTestCluster(t)
	nodeA := tc.bootstrap("node-a")
	nodeB := tc.join("node-b", nodeA)
	nodeC := tc.join("node-c", nodeA)
	nodes := []*spawnedNode{nodeA, nodeB, nodeC}

	observer := tc.httpClient()
	token := tc.adminToken()

	waitForFullConfig(t, tc, observer, nodes, 3, 5*time.Second)
	leader := waitAndFindLeader(t, tc, observer, nodes, 5*time.Second)

	newCA, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA (incoming): %v", err)
	}

	// Begin the rotation on every node - dual trust active everywhere,
	// mirroring TestMTLSRotation_FullRotation_NeverDropsQuorum's and
	// TestMTLSRotation_Finalize_OldCARejectedAfterward's own identical
	// setup sequence.
	beginCARotation(t, observer, leader.apiAddr, token, newCA)
	for _, n := range nodes {
		if n == leader {
			continue
		}
		beginCARotation(t, observer, n.apiAddr, token, newCA)
	}
	for _, n := range nodes {
		waitForRotationStatus(t, observer, n.apiAddr, token, "in_progress", 5*time.Second)
	}

	dualObserver := tc.httpClientTrustingCAs(tc.ca, newCA)
	waitForQuorumHealthy(t, tc, dualObserver, nodes, 5*time.Second)

	// Renew EVERY node's certificate under the new CA - leader first, so
	// its own transition is guaranteed durably recorded (renewCertificateDual's
	// real HTTP response proves this) - exactly
	// TestMTLSRotation_Finalize_OldCARejectedAfterward's own established
	// sequence. This is the step that, post-fix, ALSO reissues each
	// renewing node's own forward-client identity under the new CA.
	renewed := renewCertificateDual(t, dualObserver, leader.apiAddr, token)
	if !renewed.CARotationTransitionRecorded {
		t.Fatalf("leader %q's own renewal did not durably record its transition", leader.nodeID)
	}
	for _, n := range nodes {
		if n == leader {
			continue
		}
		renewCertificateDual(t, dualObserver, n.apiAddr, token)
	}

	// Finalize completes the rotation cluster-wide - every node's own
	// TrustStore(s) drop to single, newCA-only trust (T023's FSM-notify
	// mechanism on followers; the finalize handler itself on the leader).
	finalizeCARotation(t, dualObserver, leader.apiAddr, token)
	for _, n := range nodes {
		waitForRotationStatus(t, dualObserver, n.apiAddr, token, "finalized", 5*time.Second)
	}

	// The core assertion: a genuinely-safe, SUBSEQUENT revoke (with a
	// NodeID set, so FR-010's live-per-voter-trust check runs) issued
	// AFTER the CA rotation has FULLY completed must be APPROVED. The
	// NodeID named here ("post-rotation-revoke-target") deliberately does
	// NOT match any real voter's ID - the point of this test is the LIVE
	// CHECK against the two OTHER real voters (nodeB/nodeC from the
	// leader's own perspective), which quorumWouldBeStrandedLive performs
	// unconditionally regardless of what NodeID the request names, not
	// the configuration-based approximation any single named voter would
	// also exercise.
	victimCert, err := newCA.IssueNodeCert("post-rotation-revoke-target")
	if err != nil {
		t.Fatalf("issue post-rotation revoke-target cert: %v", err)
	}
	serial := certSerialNumber(t, victimCert.CertPEM)
	status, body := attemptRevoke(t, dualObserver, leader.apiAddr, token, serial, "post-rotation-revoke-target", "test: forward-client-identity-must-survive-a-full-prior-rotation")
	if status != http.StatusOK {
		t.Fatalf("revoking a certificate (NodeID set, so FR-010's live-per-voter-trust check genuinely runs) AFTER a fully completed CA rotation was refused (status = %d, body = %s) - the leader's own forward-client identity (mtlsForwardTLS/mtlsForwardStore) was not reissued across the rotation, so its live-check dial against every OTHER real voter spuriously failed at the mutual-TLS layer, wrongly reporting this cluster as quorum-stranded when every voter is genuinely live and the real quorum is intact", status, body)
	}

	// The approved revocation must have genuinely, durably applied -
	// mirrors every other test in this file's own post-action replication
	// check.
	waitForRevocationReplicated(t, dualObserver, leader.apiAddr, token, serial, 5*time.Second)
}
