// Package api (routes_mtls.go): Feature 004's operator-facing mTLS
// certificate revocation actions (spec.md FR-004: POST
// /v1/cluster/mtls/revoke) and status query (GET
// /v1/cluster/mtls/revocations) - backed by a real *raft.Node, routed
// through the SAME audited *authz.Decider (T071) RequireJWT+RBAC pattern
// routes_tenants.go and routes_models.go already establish (T074/T075),
// reusing the existing authorization mechanism rather than inventing a
// second one for this feature.
//
// Unlike routes_cluster.go's node-to-node routes (POST /v1/cluster/join,
// POST /v1/cluster/leave - gated by RequireMTLS only, no JWT, since those
// are peer-node calls), revoking a certificate is a high-privilege,
// cluster-wide-effect OPERATOR action - the caller here is a human/
// automation acting through the daemon's authenticated API, not another
// cluster node, so RequireJWT + auth.ActionMTLSManage (admin-only, see
// internal/auth/rbac.go) is the correct enforcement layer, matching
// routes_tenants.go's POST /v1/tenants precedent exactly.
package api

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
	"github.com/vasic-digital/llmctl/llmctld/internal/authz"
	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
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

// RegisterMTLSRoutes wires Feature 004's mTLS management routes onto r,
// backed by node and authorized through decider.
func RegisterMTLSRoutes(r gin.IRoutes, node *raft.Node, decider *authz.Decider) {
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
}
