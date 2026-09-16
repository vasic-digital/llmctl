// Package api (routes_models.go): the model-lifecycle dispatch routes
// (T072-FU4, FR-049/Clarification 18's "tenant model instances" phrase,
// closing internal/executor.LocalExecutor's last disclosed gap - T073's
// own evidence entry: "internal/executor.LocalExecutor ... was NOT
// constructed or called anywhere in cmd/llmctld or any other internal/
// package") - POST /v1/tenants/:id/models/:model/start, POST
// .../stop, GET .../status.
//
// These are the FIRST HTTP callers of internal/executor.LocalExecutor's
// real bin/llmctl subprocess dispatch. Every piece this file composes
// already existed, independently built and tested, before this file:
// auth.ActionModelStart/ActionModelStop/ActionModelView (rbac.go, T066 -
// defined in the predefinedRoles table but, before this file, consumed
// by no route anywhere); authorizeTenantOwnership + the
// RequireJWT/decider.CheckRBAC pattern (routes_tenants.go, T074/T075);
// decider.CheckTenantBoundary (authz/decide.go, T071 - the SAME audited
// tenant-visibility check GET .../visible already uses); and
// executor.LocalExecutor.WithTenant (T072-FU4's one small addition to
// internal/executor, needed because a single daemon process serves many
// tenants concurrently from one shared base executor, so tenant scoping
// cannot be a construction-time-only field).
//
// Every route requires, in this order (ALL must hold):
//  1. RequireJWT - a valid bearer token.
//  2. authorizeTenantOwnership(decider, claims, :id) - the caller may
//     act on behalf of tenant :id (its own tenant, or holds
//     ActionTenantManage). Composes with (3): a tenant-admin acting
//     within its OWN tenant does NOT thereby gain model-lifecycle
//     permissions - rbac.go's own doc comment: "tenant-admin is scoped
//     to tenant management ... a distinct concern, not a synonym for
//     elevated model-operator".
//  3. decider.CheckRBAC(..., action, :id) - the caller's role grants the
//     SPECIFIC action this route performs (ActionModelStart for
//     .../start, ActionModelStop for .../stop, ActionModelView - the
//     read-only action model-viewer already holds - for .../status).
//  4. decider.CheckTenantBoundary(..., :id, :model) - :model must be
//     VISIBLE to :id (registered by it via POST /v1/tenants/:id/models,
//     or shared with it) before this daemon dispatches a real
//     subprocess on the caller's behalf - a tenant can never
//     start/stop/query an arbitrary catalog profile name it never
//     registered.
//
// Dispatch (002-cluster-model-scheduler Phase 3, US1): POST .../start's
// request body accepts an optional "node" field.
//   - node present and non-empty, OR node absent but this daemon was
//     wired with no *raft.Node (RegisterModelRoutes's node parameter is
//     nil - a single, non-clustered deployment) -> BYTE-IDENTICAL to
//     this route's pre-Phase-3 behavior: dispatched directly against
//     THIS process's own real bin/llmctl via
//     base.WithTenant(:id).Start(:model), never entering cluster.Place()
//     at all (T019's own guarantee).
//   - node absent, and a *raft.Node IS wired -> NEW: cluster.Place()
//     selects a healthy candidate among the cluster's currently-known
//     nodes with sufficient capacity for :model's real resource
//     footprint (executor.LocalExecutor.Footprint), reserves that
//     capacity via a real CommandRecordRunningProfile Apply (closing the
//     FR-005/SC-004 TOCTOU race), and dispatches locally if the chosen
//     node is this process, or forwards the request to the chosen node's
//     real cluster API (ForwardModelStart) otherwise. Every automatic
//     placement outcome (success or refusal) is recorded as a
//     PlacementDecision audit entry (T018).
//
// Stop/status remain THIS NODE ONLY for now (Phase 4/US2's own,
// not-yet-implemented scope per tasks.md - multi-node resolution via the
// RunningProfile index) - an operator targets a specific node's API to
// stop/query a model instance, exactly as this package's routes always
// have.
package api

import (
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
	"github.com/vasic-digital/llmctl/llmctld/internal/authz"
	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
	"github.com/vasic-digital/llmctl/llmctld/internal/executor"
	"github.com/vasic-digital/llmctl/llmctld/internal/raft"
)

// startModelRequest is POST .../start's optional JSON request body
// (002-cluster-model-scheduler, contracts/cluster-model-api.md). An
// absent or empty body is valid and equivalent to Node == "" (Go's zero
// value) - the pre-Phase-3 caller shape, which never sent a body at all.
type startModelRequest struct {
	Node string `json:"node"`
}

// authorizeModelAction resolves a request's claims/:id/:model and runs
// the full ownership + RBAC-action + tenant-visibility gate common to
// all three model-lifecycle routes, writing the appropriate 403 (and
// returning ok=false) at whichever check first fails. Callers proceed to
// dispatch only when ok is true.
func authorizeModelAction(c *gin.Context, decider *authz.Decider, action auth.Action) (claims *auth.Claims, tenantID, model string, ok bool) {
	claims = ClaimsFromContext(c)
	tenantID = c.Param("id")
	model = c.Param("model")

	if !authorizeTenantOwnership(decider, claims, tenantID) {
		c.JSON(http.StatusForbidden, gin.H{"error": "caller may only operate on its own tenant's models"})
		return claims, tenantID, model, false
	}
	if !decider.CheckRBAC(claims.Subject, claims.Roles, action, tenantID) {
		c.JSON(http.StatusForbidden, gin.H{"error": "requires a role granting " + string(action)})
		return claims, tenantID, model, false
	}
	if !decider.CheckTenantBoundary(claims.Subject, tenantID, model) {
		c.JSON(http.StatusForbidden, gin.H{"error": "model is not registered to or shared with this tenant"})
		return claims, tenantID, model, false
	}
	return claims, tenantID, model, true
}

// RegisterModelRoutes wires the model-lifecycle dispatch routes onto r,
// backed by decider (RBAC/tenant-visibility decisions) and base (the
// shared, tenant-less LocalExecutor every request scopes via
// base.WithTenant(tenantID) before dispatching - see this file's package
// doc comment for the full authorization + dispatch contract).
//
// node and forwardTLS enable Phase 3's auto-placement path on
// POST .../start: node is this process's own *raft.Node (nil for a
// single, non-clustered deployment - callers still get the full,
// unmodified pre-Phase-3 local-only behavior, T019's own guarantee), and
// forwardTLS is the real mTLS client configuration ForwardModelStart uses
// to dial a DIFFERENT chosen node's cluster API (only ever read when node
// is non-nil AND the chosen node differs from this process).
func RegisterModelRoutes(r gin.IRoutes, decider *authz.Decider, base *executor.LocalExecutor, node *raft.Node, forwardTLS *tls.Config) {
	r.POST("/v1/tenants/:id/models/:model/start", RequireJWT(decider), func(c *gin.Context) {
		_, tenantID, model, ok := authorizeModelAction(c, decider, auth.ActionModelStart)
		if !ok {
			return
		}

		var req startModelRequest
		if c.Request.ContentLength != 0 {
			if err := c.ShouldBindJSON(&req); err != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body: " + err.Error()})
				return
			}
		}

		if req.Node != "" || node == nil {
			// Explicit-node (or no-cluster-wiring) path: BYTE-IDENTICAL
			// to this route's pre-Phase-3 behavior - never enters
			// cluster.Place() (T019).
			if err := base.WithTenant(tenantID).Start(model); err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
				return
			}
			c.JSON(http.StatusOK, gin.H{"status": "started", "model": model, "node": req.Node})
			return
		}

		dispatchAutoPlacedStart(c, decider, base, node, forwardTLS, tenantID, model)
	})

	r.POST("/v1/tenants/:id/models/:model/stop", RequireJWT(decider), func(c *gin.Context) {
		_, tenantID, model, ok := authorizeModelAction(c, decider, auth.ActionModelStop)
		if !ok {
			return
		}
		if err := base.WithTenant(tenantID).Stop(model); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusOK, gin.H{"status": "stopped", "model": model})
	})

	r.GET("/v1/tenants/:id/models/:model/status", RequireJWT(decider), func(c *gin.Context) {
		_, tenantID, model, ok := authorizeModelAction(c, decider, auth.ActionModelView)
		if !ok {
			return
		}
		status, err := base.WithTenant(tenantID).Status(model)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
			return
		}
		c.JSON(http.StatusOK, gin.H{"status": status})
	})
}

// dispatchAutoPlacedStart implements 002-cluster-model-scheduler's US1
// (T012-T018): a start request naming no node lands on a real cluster
// node that genuinely has capacity, or is refused with the exact
// shortfall - every outcome recorded as a PlacementDecision audit entry.
func dispatchAutoPlacedStart(c *gin.Context, decider *authz.Decider, base *executor.LocalExecutor, node *raft.Node, forwardTLS *tls.Config, tenantID, model string) {
	// T013's own real 3-node integration test found this as a genuine,
	// previously-undiscovered gap: node.RecordRunningProfile below is a
	// real Raft write, which can only ever succeed on the CURRENT
	// LEADER - a follower receiving a no-node start request cannot run
	// cluster.Place()+reserve locally no matter which node it would
	// choose (internal/raft.Node.LeaderAddr's own doc comment explains
	// why), so it must forward the WHOLE auto-placement decision to the
	// leader and relay the leader's exact response back verbatim, never
	// attempting Place()/RecordRunningProfile against its own state.
	if !node.IsLeader() {
		forwardAutoPlaceToLeader(c, node, forwardTLS, tenantID, model)
		return
	}

	ramMB, vramMB, err := base.Footprint(model)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "resolve resource footprint for profile " + model + ": " + err.Error()})
		return
	}
	req := cluster.PlacementRequest{RAMMB: ramMB, VRAMMB: vramMB}

	// excluded accumulates nodes T016's retry-once logic has already
	// tried and lost the capacity race on, so a retried Place() call
	// never re-chooses the exact candidate that just refused the
	// reservation.
	excluded := map[string]bool{}

	// T016: at most one retry against freshly-read State() - "retry
	// Place() once ... before giving up with insufficient_capacity".
	for attempt := 0; attempt < 2; attempt++ {
		state := node.State()
		candidates := make([]cluster.Node, 0, len(state.Nodes))
		for id, n := range state.Nodes {
			if excluded[id] {
				continue
			}
			candidates = append(candidates, n)
		}

		chosen, placeErr := cluster.Place(candidates, req)
		if placeErr != nil {
			considered := nodeCapacitySnapshots(state.Nodes)
			reason := "insufficient_capacity: " + placeErr.Error()
			recordPlacementDecision(decider, model, "", considered, reason)
			c.JSON(http.StatusServiceUnavailable, gin.H{
				"error":      "insufficient_capacity",
				"reason":     placeErr.Error(),
				"considered": considered,
			})
			return
		}

		// T016: reserve the chosen node's capacity BEFORE dispatching -
		// Apply's own re-validation (fsm.go's CommandRecordRunningProfile
		// handling) is what closes the FR-005/SC-004 TOCTOU race a
		// caller-side check alone never could.
		reserveErr := node.RecordRunningProfile(model, tenantID, chosen.ID, req)
		if reserveErr != nil {
			if errors.Is(reserveErr, raft.ErrInsufficientCapacity) && attempt == 0 {
				// Lost the race: retry once, excluding this now-known-full
				// node, against freshly-read State().
				excluded[chosen.ID] = true
				continue
			}
			considered := nodeCapacitySnapshots(state.Nodes)
			reason := "insufficient_capacity: reservation refused: " + reserveErr.Error()
			recordPlacementDecision(decider, model, "", considered, reason)
			c.JSON(http.StatusServiceUnavailable, gin.H{
				"error":      "insufficient_capacity",
				"reason":     reserveErr.Error(),
				"considered": considered,
			})
			return
		}

		// T017: dispatch - locally if the chosen node IS this process,
		// otherwise forward to the chosen node's real cluster API.
		var dispatchErr error
		switch {
		case chosen.ID == node.ID():
			dispatchErr = base.WithTenant(tenantID).Start(model)
		case chosen.APIAddr == "":
			dispatchErr = fmt.Errorf("chosen node %q has no known cluster API address to forward to", chosen.ID)
		default:
			dispatchErr = ForwardModelStart(forwardTLS, chosen.APIAddr, chosen.ID, tenantID, model, c.GetHeader("Authorization"))
		}

		if dispatchErr != nil {
			// T017's compensating action: a failed dispatch must never
			// leave a phantom reservation blocking future placement.
			_ = node.ClearRunningProfile(model, tenantID, chosen.ID)
			considered := nodeCapacitySnapshots(state.Nodes)
			reason := "placement_delivery_failed: " + dispatchErr.Error()
			recordPlacementDecision(decider, model, "", considered, reason)
			c.JSON(http.StatusBadGateway, gin.H{
				"error":  "placement_delivery_failed",
				"reason": dispatchErr.Error(),
			})
			return
		}

		considered := nodeCapacitySnapshots(state.Nodes)
		recordPlacementDecision(decider, model, chosen.ID, considered, "placed")
		c.JSON(http.StatusOK, gin.H{"status": "started", "model": model, "node": chosen.ID})
		return
	}

	// Unreachable in practice (every loop iteration above returns before
	// falling through - the retry branch is the only path that continues,
	// and it is gated on attempt == 0, so the second iteration always
	// returns) - kept only because Go's compiler cannot itself prove that
	// and requires a terminating statement after the loop.
	c.JSON(http.StatusServiceUnavailable, gin.H{"error": "insufficient_capacity", "reason": "placement retry exhausted"})
}

// forwardAutoPlaceToLeader resolves the cluster's current real Raft
// leader from node's own replicated ClusterState (matching
// node.LeaderAddr()'s real transport address against each known
// cluster.Node's own Addr field - the same field Join/RegisterSelf set
// from that node's own real Node.Addr()), forwards this no-node start
// request to that leader's real cluster API via ForwardAutoPlaceStart,
// and relays the leader's exact observed status code + body back onto c
// verbatim - the leader is the one that actually decided placement (or
// the exact refusal), so this node never re-wraps or re-decides it.
func forwardAutoPlaceToLeader(c *gin.Context, node *raft.Node, forwardTLS *tls.Config, tenantID, model string) {
	leaderAddr := node.LeaderAddr()
	if leaderAddr == "" {
		c.JSON(http.StatusServiceUnavailable, gin.H{
			"error":  "insufficient_capacity",
			"reason": "no known cluster raft leader to place against",
		})
		return
	}

	var leaderAPIAddr string
	for _, n := range node.State().Nodes {
		if n.Addr == leaderAddr {
			leaderAPIAddr = n.APIAddr
			break
		}
	}
	if leaderAPIAddr == "" {
		c.JSON(http.StatusServiceUnavailable, gin.H{
			"error":  "insufficient_capacity",
			"reason": "the cluster raft leader's own cluster API address is not yet known to this node",
		})
		return
	}

	status, body, err := ForwardAutoPlaceStart(forwardTLS, leaderAPIAddr, tenantID, model, c.GetHeader("Authorization"))
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{
			"error":  "placement_delivery_failed",
			"reason": err.Error(),
		})
		return
	}
	c.Data(status, "application/json; charset=utf-8", body)
}

// nodeCapacitySnapshots converts nodes into a deterministically-ordered
// (sorted by NodeID, never map-iteration order) []cluster.NodeCapacitySnapshot
// - the "considered" audit/response detail both a successful and a
// refused PlacementDecision carry (T018).
func nodeCapacitySnapshots(nodes map[string]cluster.Node) []cluster.NodeCapacitySnapshot {
	ids := make([]string, 0, len(nodes))
	for id := range nodes {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	out := make([]cluster.NodeCapacitySnapshot, 0, len(ids))
	for _, id := range ids {
		out = append(out, cluster.NodeCapacitySnapshot{NodeID: id, Resources: nodes[id].Resources})
	}
	return out
}

// recordPlacementDecision persists one automatic-placement outcome
// (T018) via internal/audit/log.go's existing hash-chained mechanism
// (decider.Log.Append) - never a new Raft-replicated command (data-
// model.md's own "Concurrency-safety note" explicitly places
// PlacementDecision outside ClusterState). A JSON-marshal failure (never
// observed for this fixed, non-cyclic shape, but never silently
// swallowed either) is recorded as an honest fallback string rather than
// dropping the audit entry entirely.
func recordPlacementDecision(decider *authz.Decider, profile, chosenNodeID string, considered []cluster.NodeCapacitySnapshot, reason string) {
	decision := cluster.PlacementDecision{
		Profile:         profile,
		ChosenNodeID:    chosenNodeID,
		ConsideredNodes: considered,
		Reason:          reason,
		DecidedAt:       time.Now(),
	}
	payload, err := json.Marshal(decision)
	if err != nil {
		payload = []byte(fmt.Sprintf(`{"marshal_error":%q,"profile":%q,"reason":%q}`, err.Error(), profile, reason))
	}
	decider.Log.Append("system", "placement_decision", profile, string(payload))
}
