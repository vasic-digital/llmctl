// Package api (routes_mtls.go): Feature 004's operator-facing mTLS
// certificate revocation actions (spec.md FR-004: POST
// /v1/cluster/mtls/revoke) and status query (GET
// /v1/cluster/mtls/revocations), plus User Story 2's zero-downtime
// certificate renewal action (spec.md FR-005/FR-006, T016: POST
// /v1/cluster/mtls/renew) - backed by a real *raft.Node, routed through
// the SAME audited *authz.Decider (T071) RequireJWT+RBAC pattern
// routes_tenants.go and routes_models.go already establish (T074/T075),
// reusing the existing authorization mechanism rather than inventing a
// second one for this feature.
//
// Unlike routes_cluster.go's node-to-node routes (POST /v1/cluster/join,
// POST /v1/cluster/leave - gated by RequireMTLS only, no JWT, since those
// are peer-node calls), revoking or renewing a certificate is a
// high-privilege OPERATOR action - the caller here is a human/automation
// acting through the daemon's authenticated API, not another cluster node,
// so RequireJWT + auth.ActionMTLSManage (admin-only, see
// internal/auth/rbac.go) is the correct enforcement layer, matching
// routes_tenants.go's POST /v1/tenants precedent exactly.
//
// Renewal is architecturally DIFFERENT from revocation, per research.md's
// documented design (deliberately followed here, not re-derived): a
// revocation is a Raft-replicated, cluster-wide-agreed fact (every node
// must independently learn of it, so it goes through node.RevokeCertificate
// -> CommandRevokeCertificate), while a renewal only ever needs to affect
// THIS node's OWN two live mTLS transports (its Raft-transport identity and
// its HTTP-API identity) - there is nothing for the rest of the cluster to
// durably agree on, so POST /v1/cluster/mtls/renew is answered ENTIRELY
// locally: issue two fresh mtls.NodeCerts from the shared CA (the SAME,
// UNMODIFIED ca.IssueNodeCert every existing cert in this codebase is
// issued through) and call mtls.TrustStore.UpdateNodeCert on each of this
// node's own two TrustStore instances - exactly mirroring
// cmd/llmctld/main.go's buildNodeTLSConfig/wireRevocationHandler naming
// convention (node.ID() for the Raft-transport identity, node.ID()+"-api"
// for the HTTP-API identity), so an operator renewing "node X" genuinely
// renews every certificate identity that node presents to its peers, not
// only the one this route happens to be easiest to test against.
//
// Feature 004 Phase 5 (User Story 3) additionally wires the CA (root-of-
// trust) rotation actions - POST /v1/cluster/mtls/rotate/begin, GET
// /v1/cluster/mtls/rotate/status, POST /v1/cluster/mtls/rotate/finalize -
// and the FR-010 quorum-protection refusal check shared by both the
// revoke and the finalize actions (quorumWouldBeStrandedLive, written
// once - T072-FU8 follow-up: this now REALLY confirms every other voter
// is live and currently trusting via a real bounded-timeout mTLS
// handshake, not merely still-listed in Raft's own voter configuration;
// see quorumWouldBeStrandedLive's own doc comment for the full design
// and its disclosed honest boundary, and quorumWouldBeStranded's for the
// pure quorum-arithmetic it still delegates to).
//
// "begin" is deliberately DESIGNED to be called against EVERY node
// individually (each call carrying the operator's new CA cert+key PEM
// out-of-band, exactly mirroring how -ca-cert/-ca-key are already
// distributed to every node at bootstrap, per data-model.md's
// CARotationEvent security note: only a fingerprint HASH of each CA's
// certificate ever travels through the Raft-replicated log, never the
// certificate or key material itself) - see mtls.RotationCAHolder's own
// package doc comment for why a node's own dual-trust pool activation
// genuinely requires this per-node, out-of-band step and cannot be
// derived from the Raft-replicated record alone. "finalize", by
// contrast, needs no new material and is called ONCE (any single
// reachable node) - the SAME event-handler pattern T011 wires for
// revocation (fsm.go's onRevocationApplied, extended in Phase 5, see
// cmd/llmctld/main.go's wireRevocationHandler) then propagates the
// "finalized" status to every OTHER node that already locally loaded the
// incoming CA, dropping their own dual-trust pool to single-trust with
// zero additional per-node API call.
package api

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/quic-go/quic-go/http3"

	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
	"github.com/vasic-digital/llmctl/llmctld/internal/authz"
	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
	"github.com/vasic-digital/llmctl/llmctld/internal/raft"
)

// revokeCertificateRequest is POST /v1/cluster/mtls/revoke's JSON request
// body. SerialNumber MUST be the real x509 serial number (decimal string,
// as produced by x509.Certificate.SerialNumber.String()) of the
// certificate to revoke - research.md Decision 4's keying choice, NOT a
// node ID (NodeID is carried separately, purely as an audit/display
// label - see cluster.RevocationRecord's doc comment).
type revokeCertificateRequest struct {
	SerialNumber string `json:"serial_number" binding:"required"`
	NodeID       string `json:"node_id"`
	Reason       string `json:"reason"`
}

// revocationsResponse is GET /v1/cluster/mtls/revocations's JSON response
// body: this node's own current, Raft-replicated revocation set (keyed by
// serial number), read fresh from its ClusterFSM on every call - never
// cached, so a caller polling this endpoint (as
// test/integration/mtls_rotation_test.go's waitForRevocationReplicated
// does) observes genuine replication progress.
type revocationsResponse struct {
	Revocations map[string]cluster.RevocationRecord `json:"revocations"`
}

// renewResponse is POST /v1/cluster/mtls/renew's (T016) JSON response body:
// the real x509 serial numbers of the two freshly-issued certificates this
// node just started presenting - RaftSerialNumber for its Raft-transport
// identity, APISerialNumber for its HTTP-API identity (see this file's own
// package doc comment for why both, and why the naming mirrors
// cmd/llmctld/main.go's buildNodeTLSConfig convention exactly). Surfaced so
// an operator (or a test harness, e.g.
// test/integration/mtls_rotation_test.go's
// TestMTLSRotation_LiveRenewal_NewConnectionsUseFreshCert) can independently
// cross-check the claimed new identity against what a real NEW connection
// actually presents - spec.md Acceptance Scenario 3 ("an operator checks
// that node's active certificate, it reflects the new one").
type renewResponse struct {
	Status           string `json:"status"`
	RaftSerialNumber string `json:"raft_serial_number"`
	APISerialNumber  string `json:"api_serial_number"`
	// CARotationTransitionRecorded is Feature 004 Phase 5's own
	// addition: true only when this renewal ALSO durably recorded (via a
	// real CommandRecordCARotationTransition Raft Apply) that this node
	// has transitioned under an in-progress CA rotation - false in
	// steady state (no rotation in progress, so there is nothing to
	// record) OR when this node's local rotation state shows a rotation
	// in progress but the durable-record Apply itself failed (a
	// DEGRADED-but-successful renewal, per this field's own honest
	// scope: the renewal itself already succeeded and took effect
	// before this field is ever computed - see the renew handler's own
	// comment for why that failure is never treated as fatal to the
	// renewal response).
	CARotationTransitionRecorded bool `json:"ca_rotation_transition_recorded"`
}

// beginCARotationRequest is POST /v1/cluster/mtls/rotate/begin's JSON
// request body (Feature 004 Phase 5, T024): the operator's new CA's real
// cert+key PEM, distributed to THIS node out-of-band via this
// authenticated call - never through the Raft-replicated log (see this
// file's own package doc comment).
type beginCARotationRequest struct {
	IncomingCACertPEM string `json:"incoming_ca_cert_pem" binding:"required"`
	IncomingCAKeyPEM  string `json:"incoming_ca_key_pem" binding:"required"`
}

// caRotationResponse is POST /v1/cluster/mtls/rotate/begin's and POST
// /v1/cluster/mtls/rotate/finalize's shared JSON response shape.
type caRotationResponse struct {
	Status                string `json:"status"`
	OutgoingCAFingerprint string `json:"outgoing_ca_fingerprint"`
	IncomingCAFingerprint string `json:"incoming_ca_fingerprint"`
}

// caRotationStatusResponse is GET /v1/cluster/mtls/rotate/status's JSON
// response body (spec.md FR-009 visibility): Rotation is THIS node's own
// current, Raft-replicated view of cluster.ClusterState.CARotation (nil
// if no rotation has ever been begun), read fresh on every call exactly
// like revocationsResponse above. LocallyLoaded reports whether THIS
// specific node has ALSO locally loaded the incoming CA's real material
// (mtls.RotationCAHolder.InProgress()) - an honest, disclosed scope
// boundary mirroring GET /v1/cluster/mtls/revocations's own documented
// per-node-only visibility: an operator determines cluster-wide
// transition progress by querying EVERY node's own LocallyLoaded field
// individually, exactly as they already do for revocation-propagation
// confirmation.
type caRotationStatusResponse struct {
	Rotation      *cluster.CARotationEvent `json:"rotation"`
	LocallyLoaded bool                     `json:"locally_loaded"`
}

// leafSerialNumber returns cert's real, parsed x509 leaf serial number
// (decimal string, matching certSerialNumber's identical parsing logic in
// test/integration/mtls_rotation_test.go and TrustStore.Verify's own
// x509.ParseCertificate(rawCerts[0]) call) - the ground-truth identity of a
// tls.Certificate this handler just built via mtls.LoadTLSCertificate,
// never guessed or reconstructed from the NodeCert's PEM bytes a second
// way.
func leafSerialNumber(cert tls.Certificate) (string, error) {
	if len(cert.Certificate) == 0 {
		return "", fmt.Errorf("mtls: certificate has no leaf DER bytes")
	}
	leaf, err := x509.ParseCertificate(cert.Certificate[0])
	if err != nil {
		return "", fmt.Errorf("mtls: parse leaf certificate: %w", err)
	}
	return leaf.SerialNumber.String(), nil
}

// quorumWouldBeStranded is FR-010's shared quorum-protection check
// (spec.md's shared Edge Case), written ONCE and used by BOTH the revoke
// action (below) and the finalize action (T024): total is every CURRENT
// Raft voter (raft.Node.Servers(), filtered to Suffrage == "Voter" -
// non-voters/staging servers are not part of the quorum calculation);
// untrustedNodeIDs names every voter this specific action would leave
// untrusted (for revoke: already-revoked voters plus the ONE being
// revoked now; for finalize: every voter that has NOT yet transitioned
// under the incoming CA, since finalize retires the outgoing CA those
// nodes are presumably still presenting). Refuses (returns true) when
// fewer than a strict majority of voters would remain trusted.
//
// Honest scope boundary (Constitution §11.4.223 provenance markers,
// disclosed rather than silently narrowed, mirroring GET
// /v1/cluster/mtls/revocations's own documented per-node-only visibility
// above): "trusted" here is approximated from what this call CAN
// reliably determine without a live per-voter mTLS handshake. For
// revoke, RevocationRecord.NodeID is an audit/display field (never the
// enforcement key, per its own doc comment) - a voter whose certificate
// was revoked and has SINCE been re-issued a fresh one under a
// DIFFERENT serial is not distinguished from a genuinely still-revoked
// voter by this heuristic. This is the same disclosed limitation
// NodeID's own doc comment already names; it is conservative (it can
// only ever OVER-refuse, never under-refuse, a genuinely safe action),
// matching Constitution §11.4.101's reversible-safe-default discipline.
func quorumWouldBeStranded(voters []raft.ServerInfo, untrustedNodeIDs map[string]struct{}) bool {
	total, remaining := 0, 0
	for _, v := range voters {
		if v.Suffrage != "Voter" {
			continue
		}
		total++
		if _, untrusted := untrustedNodeIDs[v.ID]; !untrusted {
			remaining++
		}
	}
	if total == 0 {
		return false
	}
	quorum := total/2 + 1
	return remaining < quorum
}

// liveVoterCheckTimeout bounds ONE voter's own real, live mTLS-handshake
// reachability+trust confirmation inside quorumWouldBeStrandedLive below
// (T072-FU8 follow-up, closing this file's own previously-disclosed
// FR-010 honest-scope-boundary above, on quorumWouldBeStranded) - the
// SAME 10-second value this codebase's every other real cross-node
// HTTP/3+mTLS client already uses for exactly this purpose
// (cmd/llmctld/main.go's forwardClientRequestTimeout; this file's own
// ForwardCARotationTransition above; api/client.go's
// RequestJoin/ForwardModelStart) - reused, never reinvented, per
// Constitution §11.4.74. A genuinely live, currently-trusting peer
// answers its own GET /v1/cluster/status well within this; a peer that
// does not is exactly the "not currently live and trusting" signal
// quorumWouldBeStrandedLive needs, whether that peer is merely slow or
// genuinely unreachable.
const liveVoterCheckTimeout = 10 * time.Second

// voterIsLiveAndTrusting performs ONE real, bounded-timeout HTTP/3+mTLS
// GET against voterAPIAddr's own GET /v1/cluster/status
// (routes_cluster.go's RegisterClusterRoutes) - confirmed the right
// target for this purpose: it is gated ONLY by the real mTLS handshake
// this check exists to exercise (RequireMTLS at the route-group level,
// no JWT - routes_cluster.go's own package doc comment: "gated by
// RequireMTLS only ... since those are peer-node calls", exactly this
// call's own shape), it is already wired and answered by every real node
// in every running cluster today (no new endpoint to add, version, or
// keep in sync across nodes), and it is among the lightest handlers this
// codebase exposes (one State() snapshot read, zero Raft Apply).
//
// clientTLS MUST be a real mTLS client identity signed by a CA this
// cluster's target voters currently trust - callers pass THIS node's own
// existing "forward client" identity (RegisterMTLSRoutes's own forwardTLS
// parameter, already backing every other cross-node call made from this
// file: ForwardCARotationTransition above), reused rather than a second,
// purpose-built client identity (Constitution §11.4.74 extend-don't-
// reimplement). A non-nil return means voterAPIAddr did NOT just prove
// itself live-and-currently-trusted RIGHT NOW: a network-level error
// (unreachable, connection refused, timed out) OR a TLS handshake
// failure means the peer's own presented certificate is revoked or does
// not chain to any CA clientTLS currently trusts - via clientTLS's own
// VerifyPeerCertificate callback (raft.VerifyPeerCertificateAgainstCA,
// wired once at construction time in cmd/llmctld/main.go's
// buildNodeTLSConfig) this is the SAME real x509 chain+revocation check
// (mtls.TrustStore.Verify) every genuine handshake in this codebase
// already performs - NEVER reimplemented here - or, less commonly, a
// non-200 HTTP response from a peer that IS reachable and trusted but
// answered abnormally.
func voterIsLiveAndTrusting(clientTLS *tls.Config, voterAPIAddr string) error {
	if voterAPIAddr == "" {
		return fmt.Errorf("mtls: live-trust check: no known API address for this voter")
	}
	client := &http.Client{Transport: &http3.Transport{TLSClientConfig: clientTLS}, Timeout: liveVoterCheckTimeout}
	resp, err := client.Get("https://" + voterAPIAddr + "/v1/cluster/status")
	if err != nil {
		return fmt.Errorf("mtls: live-trust check: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("mtls: live-trust check: peer returned status %d", resp.StatusCode)
	}
	return nil
}

// quorumWouldBeStrandedLive is FR-010's REAL, live-trust-confirming
// entry point (T072-FU8 follow-up - closes this file's own previously-
// disclosed honest scope boundary: "trusted" was approximated from what
// a call CAN reliably determine WITHOUT a live per-voter mTLS handshake;
// this function performs that handshake). The revoke and finalize
// handlers below call THIS, and only this, function for their FR-010
// check - quorumWouldBeStranded above remains the shared, pure quorum-
// ARITHMETIC helper this function itself delegates to, so there is still
// exactly ONE function deciding "would this leave fewer than a quorum of
// trusted voters", per this file's own original package-doc-comment
// discipline (revoke and finalize sharing ONE check, never two
// independently-maintained copies), and quorumWouldBeStranded's own
// arithmetic stays independently correct/testable/unchanged.
//
// configUntrusted is EXACTLY what each caller already computes today
// (revoke's already-revoked-plus-the-one-being-revoked-now set;
// finalize's not-yet-transitioned set) - the pre-existing,
// CONFIGURATION-based approximation, left entirely as-is. This
// function's addition: every OTHER current voter (from voters,
// raft.Node.Servers()'s own real output) not already in configUntrusted
// must ALSO prove itself LIVE AND CURRENTLY TRUSTING right now, via a
// real bounded-timeout HTTP/3+mTLS handshake against its own
// GET /v1/cluster/status (voterIsLiveAndTrusting above) - run
// CONCURRENTLY across every such voter, so the total added latency this
// adds to the revoke/finalize handler is bounded by
// liveVoterCheckTimeout regardless of cluster size, never
// (number of voters) * liveVoterCheckTimeout. THIS node (node.ID()) is
// never itself dialled over the network - it is, by construction, the
// very process currently executing this check (the Raft Apply call both
// revoke and finalize make immediately after this check passes only
// ever succeeds on the current leader - applyCommand's own doc comment -
// so the process running this code IS a live, reachable, trusted
// cluster member by definition); dialling itself would add nothing but
// latency and a spurious self-loop failure mode.
//
// Honest, DELIBERATE design decision (Constitution
// §11.4.6/§11.4.101/§11.4.201 - point 4 of this follow-up's own design
// brief, stated here rather than silently assumed): a voter whose live
// check TIMES OUT, ERRORS for any reason, or cannot even be attempted
// (no known APIAddr) is treated IDENTICALLY to a config-untrusted voter
// - excluded from "remaining" - NEVER as "the live-check mechanism
// itself is broken, silently fall back to the config-only count". This
// is a fail-CLOSED choice: FR-010's own requirement text is "trusted,
// REACHABLE nodes", so an unreachable voter is squarely inside what this
// check exists to refuse on, and quorumWouldBeStranded's own
// pre-existing doc comment already commits this whole mechanism to "can
// only ever OVER-refuse, never under-refuse, a genuinely safe action" -
// this function extends that SAME discipline to the live-reachability
// axis; it does not introduce a new one.
//
// The disclosed cost of this choice: approving an action that silently
// strands the cluster's REAL quorum (the exact defect this whole
// follow-up closes) leaves the cluster non-functional and requires
// manual, out-of-band recovery; refusing an action that was actually
// safe merely costs the operator a retry (the SAME "confirm each
// not_yet_transitioned node's own GET .../rotate/status directly before
// retrying" recovery path the finalize handler's own pre-existing doc
// comment already prescribes for its own, narrower config-based
// over-refusal case, below). That asymmetry is why this function fails
// closed rather than falling back.
//
// A SEPARATE, narrower, genuinely disclosed limitation this decision
// does NOT paper over: clientTLS itself (this node's own "forward
// client" identity) is never reissued by ANY handler in this file across
// a CA rotation - the SAME pre-existing gap the renew handler's own
// ForwardCARotationTransition fallback above has always silently
// carried - so a revoke/finalize action attempted after a FULLY
// COMPLETED prior CA rotation could find clientTLS's own certificate no
// longer trusted by peers that already dropped the CA that signed it,
// making every OTHER voter's live check spuriously fail. This is a
// real, pre-existing limitation of this node's own forward-client
// certificate lifecycle, not newly introduced here (mtlsForwardStore's
// own currentNodeCert is never touched by UpdateNodeCert anywhere in
// this codebase); fixing it is out of this specific follow-up's scope
// and is tracked as further follow-up work.
//
// Returns (stranded, liveUntrusted): stranded is quorumWouldBeStranded's
// own verdict computed against liveUntrusted; liveUntrusted is the FULL
// augmented set (configUntrusted plus every voter this call's own live
// check additionally excluded) - the finalize handler below uses it to
// report a distinct "not_currently_reachable" list to the operator
// alongside its own pre-existing, narrower "not_yet_transitioned" list
// (configUntrusted), rather than silently conflating "never transitioned"
// with "transitioned but not reachable right now" under one label.
func quorumWouldBeStrandedLive(node *raft.Node, voters []raft.ServerInfo, configUntrusted map[string]struct{}, clientTLS *tls.Config) (bool, map[string]struct{}) {
	liveUntrusted := make(map[string]struct{}, len(configUntrusted))
	for id := range configUntrusted {
		liveUntrusted[id] = struct{}{}
	}

	selfID := node.ID()
	state := node.State()

	var toCheck []raft.ServerInfo
	for _, v := range voters {
		if v.Suffrage != "Voter" || v.ID == selfID {
			continue
		}
		if _, already := liveUntrusted[v.ID]; already {
			continue
		}
		toCheck = append(toCheck, v)
	}

	type liveCheckResult struct {
		id  string
		err error
	}
	results := make(chan liveCheckResult, len(toCheck))
	for _, v := range toCheck {
		go func(v raft.ServerInfo) {
			results <- liveCheckResult{id: v.ID, err: voterIsLiveAndTrusting(clientTLS, state.Nodes[v.ID].APIAddr)}
		}(v)
	}
	for range toCheck {
		r := <-results
		if r.err != nil {
			liveUntrusted[r.id] = struct{}{}
		}
	}

	return quorumWouldBeStranded(voters, liveUntrusted), liveUntrusted
}

// recordCARotationTransitionRequest is POST
// /v1/cluster/mtls/rotate/transition's JSON request body - the internal,
// peer-to-peer forwarding target ForwardCARotationTransition (below)
// calls, naming which node has transitioned.
type recordCARotationTransitionRequest struct {
	NodeID string `json:"node_id" binding:"required"`
}

// ForwardCARotationTransition is the cross-process half of the renew
// handler's leader-forwarding fallback below - a real HTTP/3+mTLS POST
// to leaderAPIAddr's own /v1/cluster/mtls/rotate/transition route,
// mirroring client.go's ForwardAutoPlaceStart's exact established
// shape (built for 002-cluster-model-scheduler's structurally identical
// "this write can only durably commit on the current Raft leader, but
// the HTTP request may have landed on any node" constraint).
func ForwardCARotationTransition(clientTLS *tls.Config, leaderAPIAddr, nodeID string) error {
	client := &http.Client{Transport: &http3.Transport{TLSClientConfig: clientTLS}, Timeout: 10 * time.Second}

	body, err := json.Marshal(recordCARotationTransitionRequest{NodeID: nodeID})
	if err != nil {
		return fmt.Errorf("api: ForwardCARotationTransition: marshal request: %w", err)
	}
	req, err := http.NewRequest(http.MethodPost, "https://"+leaderAPIAddr+"/v1/cluster/mtls/rotate/transition", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("api: ForwardCARotationTransition: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("api: ForwardCARotationTransition: leader at %s: %w", leaderAPIAddr, err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("api: ForwardCARotationTransition: leader at %s: status = %d, body = %s", leaderAPIAddr, resp.StatusCode, respBody)
	}
	return nil
}

// RegisterMTLSRoutes wires Feature 004's mTLS management routes onto r,
// backed by node and authorized through decider.
//
// rotationHolder and (raftTrustStore, apiTrustStore) back THIS node's
// own renewal (POST /v1/cluster/mtls/renew, T016) AND CA-rotation
// (POST/GET /v1/cluster/mtls/rotate/*, Feature 004 Phase 5) actions -
// rotationHolder (internal/mtls.RotationCAHolder) is the LOCAL,
// per-node holder of which CA this node currently issues fresh
// certificates from (the node's original shared CA in steady state, the
// operator-supplied incoming CA the moment this node's own "begin
// rotation" call loads it - see that type's own package doc comment),
// and raftTrustStore/apiTrustStore are the exact SAME two
// *mtls.TrustStore instances cmd/llmctld/main.go's buildNodeTLSConfig
// already constructed for THIS node's own Raft-transport and HTTP-API
// tls.Config - the SAME pair wireRevocationHandler (T011, extended in
// Phase 5) already updates in lockstep for revocation and finalize,
// passed here so renewal/begin can update them in lockstep too.
//
// forwardTLS is THIS node's own DEDICATED mTLS CLIENT configuration for
// this feature's leader-forwarding fallback (cmd/llmctld/main.go's
// mtlsForwardTLS - deliberately DISTINCT from RegisterModelRoutes's own
// forwardTLS/002-cluster-model-scheduler auto-placement forwarding,
// an unrelated concern this feature does not touch) - used to durably
// record a FOLLOWER's own CA-rotation transition on whichever node IS
// the real Raft leader (see POST /v1/cluster/mtls/rotate/transition's
// own doc comment below).
//
// additionalCATrustStores are extra *mtls.TrustStore instances (Feature
// 004 Phase 5) that must ALSO have their trusted-CA pools kept in
// lockstep with raftTrustStore/apiTrustStore during begin/finalize -
// currently just forwardTLS's own backing store (main.go's
// mtlsForwardStore, kept in sync here so the SAME node's own outbound
// leader-forwarding client can verify a peer already presenting the
// incoming CA) - variadic so a future additional live transport never
// needs this function's own signature to change again.
func RegisterMTLSRoutes(r gin.IRoutes, node *raft.Node, decider *authz.Decider, rotationHolder *mtls.RotationCAHolder, forwardTLS *tls.Config, raftTrustStore, apiTrustStore *mtls.TrustStore, additionalCATrustStores ...*mtls.TrustStore) {
	r.POST("/v1/cluster/mtls/revoke", RequireJWT(decider), func(c *gin.Context) {
		claims := ClaimsFromContext(c)
		if !decider.CheckRBAC(claims.Subject, claims.Roles, auth.ActionMTLSManage, "mtls") {
			c.JSON(http.StatusForbidden, gin.H{"error": "requires a role granting mtls:manage"})
			return
		}
		var req revokeCertificateRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}

		// FR-010 quorum-protection refusal check (shared with finalize,
		// see quorumWouldBeStrandedLive's own doc comment) - only
		// meaningful when the request names a NodeID (revocation is
		// keyed by serial per research.md Decision 4; NodeID is the
		// audit/display field this heuristic reuses to identify which
		// VOTER, if any, this action is about).
		if req.NodeID != "" {
			voters, err := node.Servers()
			if err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("read cluster configuration: %v", err)})
				return
			}
			untrusted := map[string]struct{}{req.NodeID: {}}
			for _, existing := range node.State().Revocations {
				if existing.NodeID != "" {
					untrusted[existing.NodeID] = struct{}{}
				}
			}
			if stranded, _ := quorumWouldBeStrandedLive(node, voters, untrusted, forwardTLS); stranded {
				c.JSON(http.StatusConflict, gin.H{"error": "refusing to revoke: this would leave fewer than a quorum of trusted, reachable voters (spec.md FR-010)"})
				return
			}
		}

		rec := cluster.RevocationRecord{
			SerialNumber: req.SerialNumber,
			NodeID:       req.NodeID,
			Reason:       req.Reason,
			RevokedBy:    claims.Subject,
			RevokedAt:    time.Now(),
		}
		if err := node.RevokeCertificate(rec); err != nil {
			c.JSON(http.StatusConflict, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusOK, gin.H{"status": "revoked", "serial_number": req.SerialNumber})
	})

	// Honest scope boundary (Constitution §11.4.223 provenance markers,
	// disclosed rather than silently narrowed): this endpoint reports
	// ONLY the responding node's OWN confirmed revocation state - it is
	// NOT a single cluster-wide aggregate view of "which OTHER nodes have
	// confirmed" (spec.md FR-004's literal phrasing). An operator (or a
	// test harness, e.g.
	// test/integration/mtls_rotation_test.go's waitForRevocationReplicated)
	// satisfies FR-004's "which currently-reachable nodes have confirmed
	// applying it" requirement by calling this SAME per-node endpoint
	// against every node individually and comparing results - no
	// dedicated cross-node status-aggregation daemon exists yet, and
	// building one is out of this task's scope (no other part of this
	// codebase has such a mechanism either; GET /v1/cluster/nodes/status
	// is likewise always answered by the single node it was called
	// against).
	r.GET("/v1/cluster/mtls/revocations", RequireJWT(decider), func(c *gin.Context) {
		claims := ClaimsFromContext(c)
		if !decider.CheckRBAC(claims.Subject, claims.Roles, auth.ActionMTLSManage, "mtls") {
			c.JSON(http.StatusForbidden, gin.H{"error": "requires a role granting mtls:manage"})
			return
		}
		c.JSON(http.StatusOK, revocationsResponse{Revocations: node.State().Revocations})
	})

	// POST /v1/cluster/mtls/renew (T016, spec.md FR-005/FR-006, User Story
	// 2): zero-downtime certificate renewal - issues THIS node two fresh
	// mtls.NodeCerts via the EXISTING, UNMODIFIED ca.IssueNodeCert (never
	// redesigning issuance itself, per research.md), then calls
	// mtls.TrustStore.UpdateNodeCert on the target node's own two live
	// TrustStore instances. Unlike revoke above, this is answered ENTIRELY
	// LOCALLY - no node.RevokeCertificate-style Raft Apply call, since
	// renewal has nothing for the rest of the cluster to durably agree on
	// (research.md/data-model.md/plan.md's documented design: the SAME
	// TrustStore.UpdateNodeCert swap T005's GetCertificate/
	// GetClientCertificate callback wiring already makes take effect for
	// the very next handshake with zero process restart and zero dropped
	// in-flight connection, per Go's own documented per-handshake
	// re-invocation of those callback fields).
	r.POST("/v1/cluster/mtls/renew", RequireJWT(decider), func(c *gin.Context) {
		claims := ClaimsFromContext(c)
		if !decider.CheckRBAC(claims.Subject, claims.Roles, auth.ActionMTLSManage, "mtls") {
			c.JSON(http.StatusForbidden, gin.H{"error": "requires a role granting mtls:manage"})
			return
		}

		// Feature 004 Phase 5: issue from whichever CA THIS node
		// currently issues under - the node's original shared CA in
		// steady state, or the INCOMING CA once this node's own local
		// "begin rotation" call has loaded it (rotationHolder.IssuingCA's
		// own doc comment) - so a renewal issued while a rotation is in
		// progress genuinely re-issues under the new CA (spec.md
		// Acceptance Scenario 2/3), with zero change to Phase 4's own
		// steady-state renewal behavior.
		issuingCA := rotationHolder.IssuingCA()

		raftNodeCert, err := issuingCA.IssueNodeCert(node.ID())
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("issue renewed raft-transport cert: %v", err)})
			return
		}
		raftCert, err := mtls.LoadTLSCertificate(raftNodeCert.CertPEM, raftNodeCert.KeyPEM)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("load renewed raft-transport cert: %v", err)})
			return
		}
		raftSerial, err := leafSerialNumber(raftCert)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("parse renewed raft-transport cert: %v", err)})
			return
		}

		apiNodeCert, err := issuingCA.IssueNodeCert(node.ID() + "-api")
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("issue renewed api cert: %v", err)})
			return
		}
		apiCert, err := mtls.LoadTLSCertificate(apiNodeCert.CertPEM, apiNodeCert.KeyPEM)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("load renewed api cert: %v", err)})
			return
		}
		apiSerial, err := leafSerialNumber(apiCert)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("parse renewed api cert: %v", err)})
			return
		}

		// Both fresh certs are fully issued and parsed successfully BEFORE
		// either live TrustStore is touched - a failure above never leaves
		// this node in a half-renewed state (one transport swapped, the
		// other not), matching this codebase's existing fail-fast-before-
		// mutating-shared-state discipline.
		raftTrustStore.UpdateNodeCert(&raftCert)
		apiTrustStore.UpdateNodeCert(&apiCert)

		// Feature 004 Phase 5 (FR-009 visibility): if this node has a
		// LOCALLY in-progress rotation, durably record that it has now
		// transitioned - the mechanism POST /v1/cluster/mtls/rotate/
		// finalize's own FR-010 quorum-protection check depends on.
		// Deliberately NON-FATAL to this response: the renewal itself
		// (both certs issued + swapped, above) has ALREADY succeeded and
		// taken effect by this point, so a failure recording the
		// cluster-wide transition-visibility fact is a DEGRADED-but-
		// successful renewal, never a reason to report the renewal as
		// having failed (the certs are already live; there is nothing to
		// roll back).
		//
		// Like every other Raft write in this codebase,
		// node.RecordCARotationTransition can only durably commit on the
		// CURRENT RAFT LEADER - if THIS specific node (the one that
		// happened to receive the renew HTTP request) is a FOLLOWER, the
		// local Apply attempt fails and this block FORWARDS the same
		// fact to whichever node IS the leader, mirroring
		// routes_models.go's dispatchAutoPlacedStart/
		// forwardAutoPlaceToLeader established pattern (built for
		// 002-cluster-model-scheduler's structurally identical
		// must-run-on-leader-only constraint) via
		// ForwardCARotationTransition (above) against POST
		// /v1/cluster/mtls/rotate/transition (below). If NEITHER the
		// local attempt NOR the forward succeeds (e.g. no leader is
		// currently known, or the leader is genuinely unreachable),
		// CARotationTransitionRecorded honestly reports false - never a
		// reason to fail or roll back this renewal itself, which has
		// ALREADY succeeded and taken effect above.
		transitionRecorded := false
		if rotationHolder.InProgress() {
			if node.RecordCARotationTransition(node.ID()) == nil {
				transitionRecorded = true
			} else if !node.IsLeader() {
				if leaderAddr := node.LeaderAddr(); leaderAddr != "" {
					var leaderAPIAddr string
					for _, peer := range node.State().Nodes {
						if peer.Addr == leaderAddr {
							leaderAPIAddr = peer.APIAddr
							break
						}
					}
					if leaderAPIAddr != "" {
						if err := ForwardCARotationTransition(forwardTLS, leaderAPIAddr, node.ID()); err == nil {
							transitionRecorded = true
						}
					}
				}
			}
		}

		c.JSON(http.StatusOK, renewResponse{
			Status:                       "renewed",
			RaftSerialNumber:             raftSerial,
			APISerialNumber:              apiSerial,
			CARotationTransitionRecorded: transitionRecorded,
		})
	})

	// POST /v1/cluster/mtls/rotate/begin (Feature 004 Phase 5, T024,
	// spec.md FR-007/FR-008): loads the operator-supplied incoming CA's
	// real cert+key material LOCALLY on THIS node (out-of-band, never
	// through Raft - see this file's own package doc comment) and
	// activates dual trust ([outgoing, incoming]) on THIS node's own two
	// live TrustStore instances immediately. Only the Raft LEADER's call
	// durably records the cluster-wide fact (mirroring
	// routes_models.go's dispatchAutoPlacedStart's own node.IsLeader()
	// check before a write) - a non-leader node calling this endpoint
	// still performs every local step above regardless, so an operator
	// distributing the new CA node-by-node (exactly mirroring how
	// -ca-cert/-ca-key are already distributed at bootstrap) achieves the
	// SAME end state (every called node has dual trust active) whichever
	// node they call FIRST, and whichever order they call the rest in.
	r.POST("/v1/cluster/mtls/rotate/begin", RequireJWT(decider), func(c *gin.Context) {
		claims := ClaimsFromContext(c)
		if !decider.CheckRBAC(claims.Subject, claims.Roles, auth.ActionMTLSManage, "mtls") {
			c.JSON(http.StatusForbidden, gin.H{"error": "requires a role granting mtls:manage"})
			return
		}
		var req beginCARotationRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		incomingCA, err := mtls.LoadCA([]byte(req.IncomingCACertPEM), []byte(req.IncomingCAKeyPEM))
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": fmt.Sprintf("load incoming CA: %v", err)})
			return
		}

		outgoingFP := mtls.Fingerprint(rotationHolder.IssuingCA())
		incomingFP := mtls.Fingerprint(incomingCA)
		if outgoingFP == incomingFP {
			c.JSON(http.StatusBadRequest, gin.H{"error": "incoming CA is identical to the currently active CA"})
			return
		}

		// T025 concurrency review (spec.md Edge Case/FR-011): a
		// NON-LEADER node's local activation below is NOT itself gated
		// on a Raft Apply (only the leader branch submits one) - without
		// this check, two DIFFERENT concurrent "begin" requests naming
		// DIFFERENT incoming CAs, landing on DIFFERENT nodes at nearly
		// the same instant, could make a follower locally trust a CA
		// that never wins the real Raft race, silently diverging from
		// the cluster's eventual durably-agreed rotation. Cross-checking
		// against the CURRENTLY REPLICATED cluster.CARotation (Raft's
		// own total-ordering source of truth, read fresh via
		// node.State() on every call) closes the common case: once ANY
		// conflicting rotation has ALREADY been durably recorded
		// (whether by this node or any other), a later request naming
		// different fingerprints is refused here exactly as fsm.go's own
		// CommandBeginCARotation Apply case would refuse it. Honest
		// boundary (Constitution §11.4.6): a TRULY simultaneous pair of
		// requests that BOTH read node.State() before EITHER's Raft
		// entry has replicated is not caught by this check alone - it is
		// resolved by Raft's own total log ordering the moment the
		// LOSING request's leader-side Apply (or a subsequent retry of
		// this same check once replication catches up) is attempted;
		// this check narrows, rather than eliminates, that residual
		// window.
		if existing := node.State().CARotation; existing != nil && existing.Status == "in_progress" &&
			(existing.OutgoingCAFingerprint != outgoingFP || existing.IncomingCAFingerprint != incomingFP) {
			c.JSON(http.StatusConflict, gin.H{"error": "a DIFFERENT CA rotation is already in progress cluster-wide - finalize it first"})
			return
		}

		if node.IsLeader() {
			rec := cluster.CARotationEvent{
				OutgoingCAFingerprint: outgoingFP,
				IncomingCAFingerprint: incomingFP,
				Status:                "in_progress",
				BegunAt:               time.Now(),
			}
			if err := node.BeginCARotation(rec); err != nil {
				c.JSON(http.StatusConflict, gin.H{"error": err.Error()})
				return
			}
		}

		rotationHolder.BeginLocalRotation(incomingCA)
		beginPools := rotationHolder.Pools()
		raftTrustStore.UpdateTrustedCAs(beginPools)
		apiTrustStore.UpdateTrustedCAs(beginPools)
		for _, store := range additionalCATrustStores {
			store.UpdateTrustedCAs(beginPools)
		}

		c.JSON(http.StatusOK, caRotationResponse{
			Status:                "in_progress",
			OutgoingCAFingerprint: outgoingFP,
			IncomingCAFingerprint: incomingFP,
		})
	})

	// GET /v1/cluster/mtls/rotate/status (Feature 004 Phase 5, T024,
	// spec.md FR-009 - see caRotationStatusResponse's own doc comment for
	// the disclosed per-node visibility scope this mirrors from GET
	// /v1/cluster/mtls/revocations above).
	r.GET("/v1/cluster/mtls/rotate/status", RequireJWT(decider), func(c *gin.Context) {
		claims := ClaimsFromContext(c)
		if !decider.CheckRBAC(claims.Subject, claims.Roles, auth.ActionMTLSManage, "mtls") {
			c.JSON(http.StatusForbidden, gin.H{"error": "requires a role granting mtls:manage"})
			return
		}
		c.JSON(http.StatusOK, caRotationStatusResponse{
			Rotation:      node.State().CARotation,
			LocallyLoaded: rotationHolder.InProgress(),
		})
	})

	// POST /v1/cluster/mtls/rotate/finalize (Feature 004 Phase 5, T024,
	// spec.md FR-009/FR-010): explicit, operator-triggered completion of
	// an in-progress CA rotation - refused (per FR-010) when finalizing
	// would leave fewer than a quorum of voters trusted AND currently
	// reachable (every voter that has NOT yet transitioned under the
	// incoming CA would become untrusted the instant the outgoing CA is
	// retired; T072-FU8 follow-up: every voter that HAS transitioned
	// must ALSO prove itself live right now, quorumWouldBeStrandedLive's
	// own doc comment above). Unlike begin, this call needs no new
	// material and durably records ONCE via Raft (must be called against
	// the current leader, mirroring revoke's own leader-only write
	// pattern above); every OTHER node that already locally loaded the
	// incoming CA (via its own prior "begin" call) converges
	// automatically via wireRevocationHandler's SAME FSM-notify
	// mechanism (T023) - see this file's own package doc comment.
	//
	// Honest scope boundary (mirrors the renew handler's own identical
	// disclosure above): TransitionedNodeIDs is only as complete as POST
	// /v1/cluster/mtls/renew's own recording of it - a leader's own
	// renewal records directly, a follower's own renewal FORWARDS the
	// same fact to the leader (ForwardCARotationTransition), and only
	// when NEITHER the direct write NOR the forward can succeed (e.g. no
	// leader currently known, or it is genuinely unreachable from that
	// follower) does CARotationTransitionRecorded honestly report false
	// and this field stay incomplete. This quorum-protection check can
	// therefore be MORE conservative than the cluster's true (but
	// not-yet-durably-visible) transition state in that rare case - it
	// can only ever OVER-refuse a genuinely-safe finalize, never
	// under-refuse an unsafe one (Constitution §11.4.101
	// reversible-safe-default) - a property quorumWouldBeStrandedLive's
	// own added live-reachability check preserves and extends, never
	// weakens. An operator whose finalize is refused despite believing
	// every node has transitioned should confirm each
	// "not_yet_transitioned" node's own GET /v1/cluster/mtls/rotate/status
	// directly before retrying, and each "not_currently_reachable" node's
	// own liveness independently (T072-FU8: a node reported here HAS
	// transitioned per the replicated record but did not answer this
	// call's own live check just now).
	r.POST("/v1/cluster/mtls/rotate/finalize", RequireJWT(decider), func(c *gin.Context) {
		claims := ClaimsFromContext(c)
		if !decider.CheckRBAC(claims.Subject, claims.Roles, auth.ActionMTLSManage, "mtls") {
			c.JSON(http.StatusForbidden, gin.H{"error": "requires a role granting mtls:manage"})
			return
		}

		st := node.State()
		if st.CARotation == nil || st.CARotation.Status != "in_progress" {
			c.JSON(http.StatusConflict, gin.H{"error": "no CA rotation is currently in progress"})
			return
		}

		voters, err := node.Servers()
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": fmt.Sprintf("read cluster configuration: %v", err)})
			return
		}
		transitioned := make(map[string]struct{}, len(st.CARotation.TransitionedNodeIDs))
		for _, id := range st.CARotation.TransitionedNodeIDs {
			transitioned[id] = struct{}{}
		}
		untrusted := map[string]struct{}{}
		for _, v := range voters {
			if v.Suffrage != "Voter" {
				continue
			}
			if _, ok := transitioned[v.ID]; !ok {
				untrusted[v.ID] = struct{}{}
			}
		}
		if stranded, liveUntrusted := quorumWouldBeStrandedLive(node, voters, untrusted, forwardTLS); stranded {
			notYet := make([]string, 0, len(untrusted))
			for id := range untrusted {
				notYet = append(notYet, id)
			}
			// notCurrentlyReachable (T072-FU8 follow-up) is DISTINCT from
			// notYet above: it names every voter this call's OWN live
			// mTLS-handshake check additionally excluded RIGHT NOW - a
			// voter that HAS durably recorded its own transition
			// (present in st.CARotation.TransitionedNodeIDs, so absent
			// from notYet) but did not answer a real, bounded-timeout
			// GET /v1/cluster/status just now (quorumWouldBeStrandedLive's
			// own doc comment: dead, partitioned, or its certificate no
			// longer trusted). Reported separately rather than merged
			// into notYet so an operator is never told a genuinely
			// transitioned node "has not yet transitioned" when the real
			// problem is that it is not currently reachable.
			var notCurrentlyReachable []string
			for id := range liveUntrusted {
				if _, alreadyConfigUntrusted := untrusted[id]; !alreadyConfigUntrusted {
					notCurrentlyReachable = append(notCurrentlyReachable, id)
				}
			}
			c.JSON(http.StatusConflict, gin.H{
				"error":                   "refusing to finalize: this would leave fewer than a quorum of trusted, reachable voters (spec.md FR-010)",
				"not_yet_transitioned":    notYet,
				"not_currently_reachable": notCurrentlyReachable,
			})
			return
		}

		rec := cluster.CARotationEvent{
			OutgoingCAFingerprint: st.CARotation.OutgoingCAFingerprint,
			IncomingCAFingerprint: st.CARotation.IncomingCAFingerprint,
			TransitionedNodeIDs:   st.CARotation.TransitionedNodeIDs,
			Status:                "finalized",
			BegunAt:               st.CARotation.BegunAt,
			FinalizedAt:           time.Now(),
		}
		if err := node.FinalizeCARotation(rec); err != nil {
			c.JSON(http.StatusConflict, gin.H{"error": err.Error()})
			return
		}

		// This node's OWN local trust pools drop to single-new-pool
		// immediately - the SAME action every OTHER node's own
		// FSM-notify handler independently performs the moment ITS OWN
		// replicated state reflects "finalized" (T023).
		rotationHolder.FinalizeLocalRotation()
		finalizePools := rotationHolder.Pools()
		raftTrustStore.UpdateTrustedCAs(finalizePools)
		apiTrustStore.UpdateTrustedCAs(finalizePools)
		for _, store := range additionalCATrustStores {
			store.UpdateTrustedCAs(finalizePools)
		}

		c.JSON(http.StatusOK, caRotationResponse{
			Status:                "finalized",
			OutgoingCAFingerprint: rec.OutgoingCAFingerprint,
			IncomingCAFingerprint: rec.IncomingCAFingerprint,
		})
	})

	// POST /v1/cluster/mtls/rotate/transition (Feature 004 Phase 5): the
	// internal, peer-to-peer forwarding TARGET the renew handler's own
	// leader-forwarding fallback (above) calls via
	// ForwardCARotationTransition when a FOLLOWER's own local
	// node.RecordCARotationTransition attempt fails because it is not
	// the leader. A caller (another cluster node, never an operator)
	// asks WHICHEVER node it believes is currently the leader to record
	// nodeID's transition on its behalf - genuinely succeeds ONLY when
	// this node really is the leader (node.RecordCARotationTransition's
	// own FSM-enforced constraint), so a stale/incorrect belief about
	// who the leader is fails safely with a 409, exactly like every
	// other leader-only write in this codebase.
	//
	// No RequireJWT/RBAC gate - this is a NODE-TO-NODE call, gated by
	// the SAME real mTLS handshake every connection to this server
	// already requires (ClientAuth: RequireAnyClientCert +
	// VerifyPeerCertificate, enforced unconditionally at the TLS layer
	// regardless of route), mirroring routes_cluster.go's join/leave
	// peer routes exactly (that file's own package doc comment: "gated
	// by RequireMTLS only, no JWT, since those are peer-node calls").
	r.POST("/v1/cluster/mtls/rotate/transition", func(c *gin.Context) {
		var req recordCARotationTransitionRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		if err := node.RecordCARotationTransition(req.NodeID); err != nil {
			c.JSON(http.StatusConflict, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusOK, gin.H{"status": "recorded"})
	})
}
