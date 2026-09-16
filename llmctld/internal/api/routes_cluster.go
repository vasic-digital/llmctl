// Package api (routes_cluster.go): the node-to-node cluster HTTP routes
// (T058, FR-019) - POST /v1/cluster/join, POST /v1/cluster/leave,
// GET /v1/cluster/nodes, GET /v1/cluster/status - backed by a real
// *raft.Node.
package api

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
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
//
// Resources (002-cluster-model-scheduler T006, contracts/cluster-model-
// api.md) mirrors cluster.Resources's own JSON field names exactly and is
// REQUIRED - it is the joining node's own real hardware-probe-derived
// capacity, the exact payload internal/raft.Node.Join's own T004 fix now
// carries into a real CommandJoinNode Apply so ClusterState.Nodes[PeerID]
// is never left at Resources's zero value (which cluster.Place would then
// read as "this node has zero of everything", excluding it from every
// real placement decision it should have been eligible for).
type joinRequest struct {
	PeerID    string            `json:"peer_id" binding:"required"`
	PeerAddr  string            `json:"peer_addr" binding:"required"`
	Resources cluster.Resources `json:"resources"`
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
		if err := node.Join(req.PeerID, req.PeerAddr, req.Resources); err != nil {
			c.JSON(http.StatusConflict, gin.H{"error": err.Error()})
			return
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
