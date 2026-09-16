// Package api (routes_cluster.go): the node-to-node cluster HTTP routes
// (T058, FR-019) - POST /v1/cluster/join, POST /v1/cluster/leave,
// GET /v1/cluster/nodes, GET /v1/cluster/status - backed by a real
// *raft.Node.
package api

import (
	"bytes"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/quic-go/quic-go/http3"

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
// APIAddr is the joining peer's own real HTTP/3+mTLS cluster-API bind
// address (its internal/api.Server's bound address - NOT PeerAddr, which
// is the peer's Raft transport address, a distinct listener/port
// entirely). Two consumers depend on it: 002-cluster-model-scheduler's
// T017 cross-node model-lifecycle forwarding dials this address to reach
// a peer, and 003-kv-cache-replication's T008 recorded it into
// raft.Node.RegisterNode so internal/replication.Forwarder's
// AddrResolver can find a replica to forward appends/checkpoints to (see
// client.go's RequestJoin doc comment for the caller side). Left OPTIONAL
// (no `binding:"required"`) rather than mandatory like PeerID/PeerAddr:
// RegisterNode's own call site below already treats a registration
// failure as best-effort-and-logged rather than fatal (an unregistered
// node is simply skipped by both consumers, FR-004's "an unresolvable
// replica is skipped, never blocking"), so rejecting the whole join at
// the JSON-binding layer for an empty APIAddr would be stricter than
// either consumer's own actual tolerance for its absence.
type joinRequest struct {
	PeerID    string            `json:"peer_id" binding:"required"`
	PeerAddr  string            `json:"peer_addr" binding:"required"`
	APIAddr   string            `json:"api_addr"`
	Resources cluster.Resources `json:"resources"`
}

// updateResourcesRequest is POST /v1/cluster/resources/update's JSON
// request body - the internal, peer-to-peer forwarding target
// ForwardUpdateResources (below) calls, naming which node's Resources to
// refresh (T072-FU6's resource-freshness heartbeat leader-forwarding
// fallback, cluster.Monitor.SetResourceReporting's ResourceSubmitter,
// cmd/llmctld's main.go wireHealthMonitor).
type updateResourcesRequest struct {
	NodeID    string            `json:"node_id" binding:"required"`
	Resources cluster.Resources `json:"resources"`
}

// ForwardUpdateResources is the cross-process half of the resource-
// heartbeat's leader-forwarding fallback (T072-FU6) - a real HTTP/3+mTLS
// POST to leaderAPIAddr's own /v1/cluster/resources/update route,
// mirroring ForwardCARotationTransition's (routes_mtls.go) and
// client.go's ForwardAutoPlaceStart's identical established shape for
// this "this write can only durably commit on the current Raft leader,
// but the caller (a Monitor tick running on ANY node) may not itself be
// the leader" constraint.
func ForwardUpdateResources(clientTLS *tls.Config, leaderAPIAddr, nodeID string, resources cluster.Resources) error {
	client := &http.Client{Transport: &http3.Transport{TLSClientConfig: clientTLS}, Timeout: 10 * time.Second}

	body, err := json.Marshal(updateResourcesRequest{NodeID: nodeID, Resources: resources})
	if err != nil {
		return fmt.Errorf("api: ForwardUpdateResources: marshal request: %w", err)
	}
	req, err := http.NewRequest(http.MethodPost, "https://"+leaderAPIAddr+"/v1/cluster/resources/update", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("api: ForwardUpdateResources: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("api: ForwardUpdateResources: leader at %s: %w", leaderAPIAddr, err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("api: ForwardUpdateResources: leader at %s: status = %d, body = %s", leaderAPIAddr, resp.StatusCode, respBody)
	}
	return nil
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
		if err := node.Join(req.PeerID, req.PeerAddr, req.APIAddr, req.Resources); err != nil {
			c.JSON(http.StatusConflict, gin.H{"error": err.Error()})
			return
		}
		// Join above already applies ONE CommandJoinNode carrying the
		// peer's real Addr, APIAddr, AND Resources - a separate
		// node.RegisterNode call here (003-kv-cache-replication's original
		// T008 wiring) is not merely redundant but actively harmful: found
		// during the 002/003 merge that CommandJoinNode's Apply fully
		// REPLACES a node's map entry rather than merging into it, so a
		// second, partial registration call immediately after Join would
		// silently wipe the Resources just recorded back to its zero
		// value - excluding this peer from every real placement decision
		// cluster.Place should have considered it eligible for. See
		// replication_commands.go's RegisterNode doc comment for the full
		// story (including the sibling Addr-vs-APIAddr field bug the same
		// investigation found in RegisterNode itself, independently of
		// this call site).
		c.JSON(http.StatusOK, gin.H{"status": "joined", "peer_id": req.PeerID, "peer_addr": req.PeerAddr})
	})

	// POST /v1/cluster/resources/update (T072-FU6): the internal,
	// peer-to-peer forwarding TARGET the resource-heartbeat's own
	// leader-forwarding fallback calls via ForwardUpdateResources when a
	// FOLLOWER node's own local node.UpdateResources attempt fails
	// because it is not the leader (main.go's wireHealthMonitor). A
	// caller (another cluster node's own Monitor tick, never an
	// operator) asks WHICHEVER node it believes is currently the leader
	// to refresh nodeID's Resources on its behalf - genuinely succeeds
	// ONLY when this node really is the leader
	// (node.UpdateResources's own FSM-enforced constraint), so a
	// stale/incorrect belief about who the leader is fails safely with a
	// 409, exactly like every other leader-only write in this codebase
	// (mirroring POST /v1/cluster/mtls/rotate/transition's identical
	// shape, routes_mtls.go).
	//
	// No RequireJWT/RBAC gate - this is a NODE-TO-NODE call, gated by the
	// SAME real mTLS handshake every connection to this server already
	// requires, exactly like /v1/cluster/join and /v1/cluster/leave
	// above (this file's own package doc comment already names those as
	// the node-to-node route set this file registers) and mirroring
	// routes_mtls.go's /v1/cluster/mtls/rotate/transition peer-forwarding
	// target's identical no-JWT rationale.
	r.POST("/v1/cluster/resources/update", func(c *gin.Context) {
		var req updateResourcesRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		if err := node.UpdateResources(req.NodeID, req.Resources); err != nil {
			c.JSON(http.StatusConflict, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusOK, gin.H{"status": "updated"})
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
		state := node.State()
		c.JSON(http.StatusOK, gin.H{
			"is_leader": node.IsLeader(),
			"state":     state,
			// running_profiles (002-cluster-model-scheduler T024,
			// contracts/cluster-model-api.md: "Response gains a
			// running_profiles field ... in addition to the existing
			// is_leader/state fields") - the SAME real,
			// Raft-replicated ClusterState.RunningProfiles slice
			// already nested inside "state" above, surfaced ALSO at
			// the top level per the contract's explicit requirement
			// (the cluster-wide status view spec.md FR-009 names),
			// never a second, independently-derived copy.
			"running_profiles": state.RunningProfiles,
		})
	})
}
