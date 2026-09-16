// Package api (routes_cluster.go): the node-to-node cluster HTTP routes
// (T058, FR-019) - POST /v1/cluster/join, POST /v1/cluster/leave,
// GET /v1/cluster/nodes, GET /v1/cluster/status - backed by a real
// *raft.Node.
package api

import (
	"fmt"
	"net/http"
	"os"

	"github.com/gin-gonic/gin"

	"github.com/vasic-digital/llmctl/llmctld/internal/raft"
)

// joinRequest is POST /v1/cluster/join's JSON request body. PeerID MUST be
// the joining node's own real NodeID (the same value it set as its own
// raft.Config.LocalID) - see internal/raft/node.go's Join doc comment for
// why using an address-derived ID instead is a real bug (found via T054's
// end-to-end failover test): hashicorp/raft's own election-eligibility
// check compares the configuration entry's ID against the node's real
// LocalID, so a mismatched ID makes a joined follower NEVER recognize
// itself as having a vote.
type joinRequest struct {
	PeerID   string `json:"peer_id" binding:"required"`
	PeerAddr string `json:"peer_addr" binding:"required"`
	// APIAddr is the joining node's own real HTTP API address (T008,
	// 003-kv-cache-replication) - recorded into the cluster's Raft-
	// replicated node registry (raft.Node.RegisterNode) the moment this
	// join succeeds, so internal/replication.Forwarder's AddrResolver can
	// later find this node's real address to forward appends/checkpoints
	// to it as a replica. See client.go's RequestJoin doc comment for the
	// caller side of this field.
	APIAddr string `json:"api_addr" binding:"required"`
}

// RegisterClusterRoutes wires the cluster routes onto r, backed by node.
// mTLS enforcement for node routes is RequireMTLS (middleware_auth.go),
// applied by the caller on the route group these handlers are registered
// on - it is never re-checked inside an individual handler, so the
// enforcement seam stays singular and auditable.
func RegisterClusterRoutes(r gin.IRoutes, node *raft.Node) {
	r.POST("/v1/cluster/join", func(c *gin.Context) {
		var req joinRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		if err := node.Join(req.PeerID, req.PeerAddr); err != nil {
			c.JSON(http.StatusConflict, gin.H{"error": err.Error()})
			return
		}
		// Best-effort + honest (T008, 003-kv-cache-replication): the join
		// itself already succeeded (the joining node IS a real Raft voter
		// now) - a registration failure here (e.g. a transient Apply
		// timeout) is logged to stderr rather than turning an otherwise-
		// successful join into a reported failure, matching this file's
		// own "join succeeded" as the operative outcome. An unregistered
		// node's Forwarder.AddrResolver simply skips it (FR-004: an
		// unresolvable replica is skipped, never blocking) until a later
		// successful registration (e.g. cmd/llmctld's own bootstrap/join
		// self-registration retry) catches up.
		if err := node.RegisterNode(req.PeerID, req.APIAddr); err != nil {
			fmt.Fprintf(os.Stderr, "llmctld: cluster join: register node %q's API address: %v\n", req.PeerID, err)
		}
		c.JSON(http.StatusOK, gin.H{"status": "joined", "peer_id": req.PeerID, "peer_addr": req.PeerAddr})
	})

	r.POST("/v1/cluster/leave", func(c *gin.Context) {
		if err := node.Leave(); err != nil {
			c.JSON(http.StatusConflict, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusOK, gin.H{"status": "left"})
	})

	r.GET("/v1/cluster/nodes", func(c *gin.Context) {
		servers, err := node.Servers()
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusOK, gin.H{"servers": servers})
	})

	r.GET("/v1/cluster/status", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{
			"is_leader": node.IsLeader(),
			"state":     node.State(),
		})
	})
}
