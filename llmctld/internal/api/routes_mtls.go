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
package api

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"

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

// RegisterMTLSRoutes wires Feature 004's mTLS management routes onto r,
// backed by node and authorized through decider.
//
// ca, raftTrustStore, and apiTrustStore back THIS node's own renewal action
// (POST /v1/cluster/mtls/renew, T016) - ca is the shared CA every existing
// certificate in this cluster is already issued from (reused UNMODIFIED,
// per research.md's "issuance logic itself is untouched"), and
// raftTrustStore/apiTrustStore are the exact SAME two *mtls.TrustStore
// instances cmd/llmctld/main.go's buildNodeTLSConfig already constructed
// for THIS node's own Raft-transport and HTTP-API tls.Config - the SAME
// pair wireRevocationHandler (T011) already updates in lockstep for
// revocation, passed here so renewal can update them in lockstep too.
func RegisterMTLSRoutes(r gin.IRoutes, node *raft.Node, decider *authz.Decider, ca *mtls.CA, raftTrustStore, apiTrustStore *mtls.TrustStore) {
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

		raftNodeCert, err := ca.IssueNodeCert(node.ID())
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

		apiNodeCert, err := ca.IssueNodeCert(node.ID() + "-api")
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

		c.JSON(http.StatusOK, renewResponse{
			Status:           "renewed",
			RaftSerialNumber: raftSerial,
			APISerialNumber:  apiSerial,
		})
	})
}
