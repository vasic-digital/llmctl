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
// Tenant resolution: the optional X-Tenant-ID request header, read once
// per request via resolveStore below. An absent header resolves to the
// empty tenant ID, which StoreRegistry.Get documents as opening baseDir
// directly - byte-identical to this file's pre-registry behavior, so an
// existing caller that never sends the header (every test/integration
// caller today) observes no change at all. This mirrors
// routes_cluster.go's peer_id/peer_addr JSON-field convention in spirit
// but uses a header rather than a body field, since GET /v1/replication/
// state has no request body to carry one in.
package api

import (
	"net/http"

	"github.com/gin-gonic/gin"

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
// the request's X-Tenant-ID header, writing a 400 response and
// returning ok=false if the tenant ID registry rejects (e.g. a
// malicious/malformed tenant ID internal/isolation.TenantStateDir's
// allow-list refuses) - callers return immediately on ok=false without
// writing any further response.
func resolveStore(c *gin.Context, registry *replication.StoreRegistry) (store *replication.Store, ok bool) {
	tenantID := c.GetHeader(tenantIDHeader)
	store, err := registry.Get(tenantID)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return nil, false
	}
	return store, true
}

// RegisterReplicationRoutes wires the KV-cache replication routes onto r,
// backed by registry (one *replication.Store per tenant, see this file's
// package doc comment). mTLS enforcement for these routes is the
// caller's route-group choice (applied by wrapping r in a group that
// already runs RequireMTLS, exactly as NewServer does for
// RegisterClusterRoutes) - never re-checked inside an individual handler
// here, matching routes_cluster.go's own documented enforcement-seam
// discipline.
func RegisterReplicationRoutes(r gin.IRoutes, registry *replication.StoreRegistry) {
	r.POST("/v1/replication/append", func(c *gin.Context) {
		store, ok := resolveStore(c, registry)
		if !ok {
			return
		}
		var req appendRequest
		if err := c.ShouldBindJSON(&req); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		for _, e := range req.Entries {
			entry := replication.WALEntry{Seq: e.Seq, TokenID: e.TokenID, Position: e.Position}
			if err := store.WAL().Append(entry); err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
				return
			}
		}
		c.JSON(http.StatusOK, gin.H{"status": "appended", "count": len(req.Entries)})
	})

	r.POST("/v1/replication/checkpoint", func(c *gin.Context) {
		store, ok := resolveStore(c, registry)
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
		c.JSON(http.StatusOK, gin.H{"status": "checkpointed", "seq": req.Seq})
	})

	r.GET("/v1/replication/state", func(c *gin.Context) {
		store, ok := resolveStore(c, registry)
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
