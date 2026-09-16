// Package api (routes_replication.go): the KV-cache replication HTTP
// routes (T062, FR-026/FR-028) - POST /v1/replication/append, POST
// /v1/replication/checkpoint, GET /v1/replication/state - backed by a
// real *replication.StoreRegistry (T072-FU2), one per running node,
// lazily opening one *replication.Store PER TENANT rather than one
// shared Store for the whole node (see registry.go's own doc comment
// for why: Clarification 18/FR-049 requires this replicated-conversation
// state to live in per-tenant directories). This does not attempt
// per-model multiplexing within a tenant (a single default/test model's
// Store per tenant is sufficient for this scope - see cmd/llmctld's
// wiring comment for the full honest boundary).
//
// Tenant resolution + authorization (T072-FU5, fixing a real gap an
// independent review found in T072-FU2/FU3's own diff): the optional
// X-Tenant-ID request header names which tenant's Store a request
// operates against, EXACTLY as before - but every route now ALSO
// requires RequireJWT plus authorizeTenantOwnership(decider, claims,
// tenantID) before resolveStore trusts that header at all. Before this
// fix, X-Tenant-ID was trusted with NO authorization check whatsoever:
// any caller reaching this mTLS-gated router (every JWT-gated route in
// this package shares the SAME router - server.go's RequireMTLS group,
// not a separate internal-only listener) could read/append/checkpoint
// ANY tenant's replicated conversation content simply by naming it in
// the header - the exact cross-tenant data-leakage class Clarification
// 18/FR-049 exists to prevent, on the one route surface T072-FU2/FU3
// touched without adding the authorization layer T072-FU4's sibling
// model-lifecycle routes got from the start. An absent header still
// resolves to the empty tenant ID (StoreRegistry.Get's documented
// default-baseDir path) - byte-identical to this file's pre-registry
// behavior for a caller entitled to the empty tenant (its own claims
// carry TenantID == "", or it holds ActionTenantManage).
package api

import (
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/vasic-digital/llmctl/llmctld/internal/authz"
	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
	"github.com/vasic-digital/llmctl/llmctld/internal/raft"
	"github.com/vasic-digital/llmctl/llmctld/internal/replication"
)

// walEntryJSON is one WAL entry's JSON wire shape - mirrors
// replication.WALEntry field-for-field under snake_case JSON keys,
// matching this codebase's existing convention (routes_cluster.go's
// joinRequest peer_id/peer_addr).
type walEntryJSON struct {
	Seq      uint64 `json:"seq"`
	TokenID  int32  `json:"token_id"`
	Position int32  `json:"position"`
}

// appendRequest is POST /v1/replication/append's JSON body. Entries are
// batched in one request rather than one HTTP round trip per token: a
// real "conversation" replicates thousands of tokens per checkpoint
// interval (FR-026's default 1000-token interval), and issuing one
// HTTP/3+mTLS request per token would let connection/handshake overhead
// dominate replication latency for no benefit - batching (e.g. a few
// hundred entries per request) amortizes that overhead while keeping
// each request body small. The exact batch size is a caller decision;
// this route accepts any non-empty batch.
type appendRequest struct {
	Entries []walEntryJSON `json:"entries" binding:"required,min=1"`
}

// checkpointRequest is POST /v1/replication/checkpoint's JSON body.
type checkpointRequest struct {
	Seq   uint64              `json:"seq"`
	State replication.KVState `json:"state"`
}

// stateResponse is GET /v1/replication/state's JSON response - the
// node's current reconstructed KVState (replication.Store.Restore's
// result).
type stateResponse struct {
	Tokens    []int32 `json:"tokens"`
	Positions []int32 `json:"positions"`
}

// tenantIDHeader is the optional per-request tenant identifier these
// routes read to resolve which tenant's Store a request operates
// against. Absent (or empty) resolves to the empty tenant ID.
const tenantIDHeader = "X-Tenant-ID"

// resolveStore resolves c's real *replication.Store from registry via
// the request's X-Tenant-ID header, FIRST requiring the caller
// (RequireJWT's validated claims, already run by the time this executes)
// is authorized to act as that tenant - authorizeTenantOwnership, the
// SAME check every sibling tenant/model route in this package already
// applies (routes_tenants.go, routes_models.go). Writes 403 and returns
// ok=false on an authorization failure, or 400 and ok=false if the
// tenant ID registry itself rejects (e.g. a malicious/malformed tenant
// ID internal/isolation.TenantStateDir's allow-list refuses) - callers
// return immediately on ok=false without writing any further response.
func resolveStore(c *gin.Context, registry *replication.StoreRegistry, decider *authz.Decider) (store *replication.Store, ok bool) {
	claims := ClaimsFromContext(c)
	tenantID := c.GetHeader(tenantIDHeader)
	if !authorizeTenantOwnership(decider, claims, tenantID) {
		c.JSON(http.StatusForbidden, gin.H{"error": "caller may only operate on its own tenant's replication state"})
		return nil, false
	}
	store, err := registry.Get(tenantID)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return nil, false
	}
	return store, true
}

// bearerTokenFromRequest extracts the raw bearer token from c's
// Authorization header (RequireJWT has already validated it by the time
// a handler runs) - the SAME token this call's own local
// append/checkpoint was authorized with is what gets forwarded onward
// (T008/T011): the receiving replica's own RequireJWT +
// authorizeTenantOwnership will independently re-validate it against its
// own X-Tenant-ID header (forwarder.go's forwardTenantIDHeader), so a
// caller entitled to write tenantID on this node is entitled to write
// the SAME tenantID's forwarded content on the replica too - never a
// separately-minted or elevated credential.
func bearerTokenFromRequest(c *gin.Context) string {
	return strings.TrimPrefix(c.GetHeader("Authorization"), "Bearer ")
}

// ensureReplicationRole makes sure tenantID has a current, Raft-
// replicated ReplicationRole naming this node as primary BEFORE this
// call's own forwarding decision is made (T008, 003-kv-cache-replication
// User Story 1) - the auto-establishment path spec.md requires: there is
// no separate "declare primary" API, so the first node to successfully
// append/checkpoint a tenant's content becomes that tenant's primary,
// exactly matching FR-011's "exactly one authoritative forwarding
// source" applied to the moment a stream begins. Reuses
// cluster.ReconcileTenantRole - the SAME pure decision function T004's
// health-driven failover path already funnels through (research.md
// Decision 2's "no second detector"), fed here by node.Servers() (n's
// own current real Raft voter set) as liveNodeIDs - the authoritative
// cluster-membership signal, never an independently-tracked view.
//
// Best-effort + honest: if this node is not currently the Raft leader,
// AssignReplicationRole/ReassignReplicationRole fails (hraft.ErrNotLeader,
// via applyCommand) and is silently ignored here - the append/checkpoint
// this call is part of has ALREADY succeeded locally against this node's
// own real Store by the time this runs, so a role-assignment failure
// never turns a successful local write into a reported failure.
// Forwarding simply does not begin from a non-leader node until a
// genuine leader (which every write eventually reaches, since only the
// leader can durably Apply) establishes the role itself - never a
// fabricated forwarding success.
func ensureReplicationRole(node *raft.Node, tenantID string) {
	state := node.State()
	existing, had := state.ReplicationRoles[tenantID]
	servers, err := node.Servers()
	if err != nil {
		return
	}
	liveNodeIDs := make([]string, 0, len(servers))
	for _, s := range servers {
		liveNodeIDs = append(liveNodeIDs, s.ID)
	}
	role, changed, isReassignment := cluster.ReconcileTenantRole(existing, had, tenantID, node.ID(), liveNodeIDs, nil, time.Now())
	if !changed {
		return
	}
	if isReassignment {
		_ = node.ReassignReplicationRole(role)
	} else {
		_ = node.AssignReplicationRole(role)
	}
}

// nodeRoleResolver returns a replication.RoleResolver reading node's own
// Raft-replicated ReplicationRoles map directly, fresh on every call -
// re-reading rather than caching is load-bearing for T005's race-
// condition analysis (forwarder.go's own package doc comment).
func nodeRoleResolver(node *raft.Node) replication.RoleResolver {
	return func(tenantID string) (primaryNodeID string, replicaNodeIDs []string, ok bool) {
		role, ok := node.State().ReplicationRoles[tenantID]
		if !ok {
			return "", nil, false
		}
		return role.PrimaryNodeID, role.ReplicaNodeIDs, true
	}
}

// nodeAddrResolver returns a replication.AddrResolver reading node's own
// Raft-replicated node registry (ClusterState.Nodes, CommandJoinNode) -
// the real HTTP API address every node registers for itself via
// raft.Node.Join/RegisterSelf (002-cluster-model-scheduler's T004/T017,
// cmd/llmctld's main.go). Reads n.APIAddr - NEVER n.Addr, which is a
// DIFFERENT field carrying the node's Raft QUIC-transport address (a
// separate listener with its own strict ALPN, internal/raft/transport.go's
// quicRaftALPN). A real, previously-undiscovered bug found during the
// 002/003 merge: an earlier version of this resolver read n.Addr,
// which - since the Raft transport listener does NOT go through
// quic-go/http3's client/server ALPN auto-coercion to "h3" the way this
// package's own HTTP/3+mTLS API server does - made every forwarded
// append/checkpoint dial the WRONG port and fail deterministically with
// a real TLS handshake error ("tls: server did not select an ALPN
// protocol"), never a silent misbehavior. See replication_commands.go's
// RegisterNode doc comment for the sibling instance of this same
// Addr-vs-APIAddr confusion, independently found in the same
// investigation. A node with no registered API address (never joined via
// the api_addr-carrying path, or a registration that has not yet
// replicated) resolves ok=false - Forwarder.forwardToReplicas skips it
// honestly (FR-004), never blocking on it.
func nodeAddrResolver(node *raft.Node) replication.AddrResolver {
	return func(nodeID string) (baseURL string, ok bool) {
		n, ok := node.State().Nodes[nodeID]
		if !ok || n.APIAddr == "" {
			return "", false
		}
		return "https://" + n.APIAddr, true
	}
}

// NewNodeForwarder builds a *replication.Forwarder wired against node's
// own real Raft-replicated ReplicationRole + node-registry state (T008),
// posting forwarded appends/checkpoints over httpClient - production
// callers (cmd/llmctld's main.go) supply a real HTTP/3+mTLS client;
// tests may supply any http.Client, since it is never actually dialed
// when a node has no other live/registered replicas.
func NewNodeForwarder(node *raft.Node, httpClient *http.Client) *replication.Forwarder {
	return replication.NewForwarder(node.ID(), nodeRoleResolver(node), nodeAddrResolver(node), httpClient)
}

// RegisterReplicationRoutes wires the KV-cache replication routes onto r,
// backed by registry (one *replication.Store per tenant, see this file's
// package doc comment), decider (the RequireJWT + tenant-ownership
// authorization every route now requires - see this file's package doc
// comment for why), node (T008: this node's own real *raft.Node, used to
// auto-establish + read each tenant's ReplicationRole), and forwarder
// (T008: the daemon-side automatic cross-node forwarding mechanism,
// typically constructed via NewNodeForwarder against the SAME node).
// mTLS enforcement for these routes is the caller's route-group choice
// (applied by wrapping r in a group that already runs RequireMTLS,
// exactly as NewServer does for RegisterClusterRoutes) - never re-checked
// inside an individual handler here, matching routes_cluster.go's own
// documented enforcement-seam discipline. JWT enforcement, unlike mTLS,
// IS applied per-route here (RequireJWT), not left to the caller's
// route-group choice - every route in this file requires one.
func RegisterReplicationRoutes(r gin.IRoutes, registry *replication.StoreRegistry, decider *authz.Decider, node *raft.Node, forwarder *replication.Forwarder) {
	r.POST("/v1/replication/append", RequireJWT(decider), func(c *gin.Context) {
		store, ok := resolveStore(c, registry, decider)
		if !ok {
			return
		}
		var req appendRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		entries := make([]replication.WALEntry, len(req.Entries))
		for i, e := range req.Entries {
			entries[i] = replication.WALEntry{Seq: e.Seq, TokenID: e.TokenID, Position: e.Position}
			if err := store.WAL().Append(entries[i]); err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
				return
			}
		}
		// T008/T009: forwarding runs AFTER this node's own local append has
		// already durably succeeded (above) - a forwarding failure/timeout
		// (bounded per FR-004) is never allowed to turn an already-durable
		// local write into a reported failure; it is honestly logged, not
		// surfaced as this request's own error, matching FR-004's "the
		// primary's own ability to keep serving the conversation" being the
		// thing that must never block.
		tenantID := c.GetHeader(tenantIDHeader)
		ensureReplicationRole(node, tenantID)
		if err := forwarder.ForwardAppend(tenantID, bearerTokenFromRequest(c), entries); err != nil {
			c.Header("X-Replication-Forward-Warning", err.Error())
		}
		c.JSON(http.StatusOK, gin.H{"status": "appended", "count": len(req.Entries)})
	})

	r.POST("/v1/replication/checkpoint", RequireJWT(decider), func(c *gin.Context) {
		store, ok := resolveStore(c, registry, decider)
		if !ok {
			return
		}
		var req checkpointRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		if err := store.Checkpoint(req.Seq, req.State); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		tenantID := c.GetHeader(tenantIDHeader)
		ensureReplicationRole(node, tenantID)
		if err := forwarder.ForwardCheckpoint(tenantID, bearerTokenFromRequest(c), req.Seq, req.State); err != nil {
			c.Header("X-Replication-Forward-Warning", err.Error())
		}
		c.JSON(http.StatusOK, gin.H{"status": "checkpointed", "seq": req.Seq})
	})

	r.GET("/v1/replication/state", RequireJWT(decider), func(c *gin.Context) {
		store, ok := resolveStore(c, registry, decider)
		if !ok {
			return
		}
		state, err := store.Restore()
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusOK, stateResponse{Tokens: state.Tokens, Positions: state.Positions})
	})
}
