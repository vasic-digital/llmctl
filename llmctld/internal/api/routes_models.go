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
// Dispatch (002-cluster-model-scheduler Phase 4, US2): POST .../stop and
// GET .../status gain the IDENTICAL "node" request-body extension:
//   - node present and non-empty, OR node absent but no *raft.Node is
//     wired -> BYTE-IDENTICAL to this route's pre-Phase-4 behavior:
//     dispatched directly against THIS process's own real bin/llmctl,
//     never consulting the cluster-wide running-profile index at all -
//     the caller (or a forwarding node per the next bullet) has already
//     routed the request to the node meant to handle it.
//   - node absent, and a *raft.Node IS wired -> NEW: resolves EVERY
//     matching (Profile, TenantID) entry in
//     ClusterState.RunningProfiles (never limited to one, spec.md's Edge
//     Case/FR-008), and for EACH matched NodeID: stop is forwarded (or
//     dispatched locally) to that real node, and on real success a
//     CommandClearRunningProfile Apply removes that index entry
//     (dispatchNameOnlyStop); status is queried live from that real node
//     (dispatchNameOnlyStatus) and every result is returned as its own
//     entry naming its source node, never collapsed to a single value.
//     Because CommandClearRunningProfile - like T016's
//     CommandRecordRunningProfile - is a real Raft write only ever valid
//     on the current LEADER, a follower receiving a name-only stop
//     forwards the WHOLE decision to the leader first (mirroring
//     dispatchAutoPlacedStart's own forwardAutoPlaceToLeader exactly);
//     status needs no such forwarding, since it performs no Raft write
//     and any node's own locally-replicated State() is a valid read.
package api

import (
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
	"github.com/vasic-digital/llmctl/llmctld/internal/authz"
	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
	"github.com/vasic-digital/llmctl/llmctld/internal/executor"
	"github.com/vasic-digital/llmctl/llmctld/internal/raft"
)

// nodeOptionalRequest is the optional JSON request body shared by all
// three model-lifecycle routes' node-optional extension
// (002-cluster-model-scheduler, contracts/cluster-model-api.md: "Same
// node-optional extension" for stop/status as start's own POST
// .../start body) - an absent or empty body is valid and equivalent to
// Node == "" (Go's zero value), the pre-Phase-3/pre-Phase-4 caller
// shape, which never sent a body at all. Renamed from the Phase-3-only
// "startModelRequest" (Phase 4, T023) now that stop/status bind the
// identical shape too - the type was never start-specific, only its old
// name was.
type nodeOptionalRequest struct {
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

		var req nodeOptionalRequest
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

		var req nodeOptionalRequest
		if c.Request.ContentLength != 0 {
			if err := c.ShouldBindJSON(&req); err != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body: " + err.Error()})
				return
			}
		}

		if req.Node != "" || node == nil {
			// Explicit-node (or no-cluster-wiring) path: BYTE-IDENTICAL
			// to this route's pre-Phase-4 behavior - never consults the
			// running-profile index at all (mirrors POST .../start's
			// own T019 guarantee for the identical reason: the caller,
			// or a forwarding node per T023/dispatchNameOnlyStop below,
			// has already routed this exact request to the node meant
			// to handle it).
			if err := base.WithTenant(tenantID).Stop(model); err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
				return
			}
			c.JSON(http.StatusOK, gin.H{"status": "stopped", "model": model, "node": req.Node})
			return
		}

		dispatchNameOnlyStop(c, base, node, forwardTLS, tenantID, model)
	})

	r.GET("/v1/tenants/:id/models/:model/status", RequireJWT(decider), func(c *gin.Context) {
		_, tenantID, model, ok := authorizeModelAction(c, decider, auth.ActionModelView)
		if !ok {
			return
		}

		var req nodeOptionalRequest
		if c.Request.ContentLength != 0 {
			if err := c.ShouldBindJSON(&req); err != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": "invalid request body: " + err.Error()})
				return
			}
		}

		if req.Node != "" || node == nil {
			// Explicit-node (or no-cluster-wiring) path: BYTE-IDENTICAL
			// to this route's pre-Phase-4 behavior.
			status, err := base.WithTenant(tenantID).Status(model)
			if err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
				return
			}
			c.JSON(http.StatusOK, gin.H{"status": status})
			return
		}

		dispatchNameOnlyStatus(c, base, node, forwardTLS, tenantID, model)
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

// runningProfileMatches filters entries down to exactly those matching
// (profile, tenantID) - spec.md's Cluster-Wide Running-Profile Index
// resolution step every name-only status/stop request needs (FR-006/
// FR-007), sorted by ascending NodeID so a caller (and this file's own
// tests) never depends on ClusterState.RunningProfiles's own append
// order or on any map-iteration-derived ordering upstream of it. NEVER
// limited to the first match (spec.md's Edge Case/FR-008): a
// (profile, tenantID) pair genuinely CAN map to more than one NodeID
// simultaneously (cluster.RunningProfile's own doc comment), and both
// dispatchNameOnlyStop and dispatchNameOnlyStatus below iterate every
// entry this returns, never just entries[0].
func runningProfileMatches(entries []cluster.RunningProfile, profile, tenantID string) []cluster.RunningProfile {
	matches := make([]cluster.RunningProfile, 0, len(entries))
	for _, e := range entries {
		if e.Profile == profile && e.TenantID == tenantID {
			matches = append(matches, e)
		}
	}
	sort.Slice(matches, func(i, j int) bool { return matches[i].NodeID < matches[j].NodeID })
	return matches
}

// dispatchNameOnlyStop is T023's stop-side implementation
// (contracts/cluster-model-api.md: "When node is absent, resolves via
// the RunningProfile index ... if more than one node is running the
// named profile for this tenant, the stop is delivered to every one of
// them"). Every real per-node CommandClearRunningProfile Apply below is,
// like T016/T017's CommandRecordRunningProfile, ONLY ever valid on the
// current real Raft LEADER (internal/raft.Node.LeaderAddr's own doc
// comment) - so exactly like dispatchAutoPlacedStart's own
// forwardAutoPlaceToLeader, a follower receiving a name-only stop
// request cannot resolve+clear locally no matter which real node(s) it
// would find, and must instead forward the WHOLE decision to the
// leader, whose own (necessarily most-current) State() is what actually
// gets consulted and cleared.
func dispatchNameOnlyStop(c *gin.Context, base *executor.LocalExecutor, node *raft.Node, forwardTLS *tls.Config, tenantID, model string) {
	if !node.IsLeader() {
		forwardNameOnlyStopToLeader(c, node, forwardTLS, tenantID, model)
		return
	}

	state := node.State()
	matches := runningProfileMatches(state.RunningProfiles, model, tenantID)
	if len(matches) == 0 {
		c.JSON(http.StatusNotFound, gin.H{
			"error":  "profile_not_running",
			"reason": "no cluster node reports profile " + model + " running for this tenant",
		})
		return
	}

	stopped := make([]string, 0, len(matches))
	var failures []string
	for _, m := range matches {
		var dispatchErr error
		switch {
		case m.NodeID == node.ID():
			// This leader IS the real host - dispatch locally, exactly
			// like dispatchAutoPlacedStart's own local-dispatch branch.
			dispatchErr = base.WithTenant(tenantID).Stop(model)
		default:
			apiAddr := state.Nodes[m.NodeID].APIAddr
			if apiAddr == "" {
				dispatchErr = fmt.Errorf("node %q has no known cluster API address to forward stop to", m.NodeID)
			} else {
				dispatchErr = ForwardModelStop(forwardTLS, apiAddr, m.NodeID, tenantID, model, c.GetHeader("Authorization"))
			}
		}

		if dispatchErr != nil {
			failures = append(failures, m.NodeID+": "+dispatchErr.Error())
			continue
		}

		// T023: "on each real success submit CommandClearRunningProfile
		// for that entry" - only after the real stop genuinely
		// succeeded, never speculatively before it, so a failed
		// dispatch never leaves a stale index entry silently cleared
		// out from under a model that is, in fact, still running.
		if clearErr := node.ClearRunningProfile(model, tenantID, m.NodeID); clearErr != nil {
			failures = append(failures, m.NodeID+": stopped but failed to clear the running-profile index entry: "+clearErr.Error())
			continue
		}
		stopped = append(stopped, m.NodeID)
	}

	if len(stopped) == 0 {
		c.JSON(http.StatusBadGateway, gin.H{
			"error":  "stop_delivery_failed",
			"reason": strings.Join(failures, "; "),
		})
		return
	}

	resp := gin.H{"status": "stopped", "model": model, "nodes": stopped}
	if len(failures) > 0 {
		// Never silently drop a partial failure (spec.md's Edge Case:
		// "must not silently act on only one of them and hide the
		// other") - a caller sees BOTH which nodes were genuinely
		// stopped AND which ones were not, rather than a bare success.
		resp["partial_failures"] = failures
	}
	c.JSON(http.StatusOK, resp)
}

// forwardNameOnlyStopToLeader mirrors forwardAutoPlaceToLeader exactly
// (same real leader-address-to-API-address resolution via node's own
// replicated ClusterState, same "relay the leader's exact observed
// status code + body back onto c verbatim" discipline) - the leader is
// the one that actually resolves the running-profile index and clears
// it, so this node never re-wraps or re-decides its response.
func forwardNameOnlyStopToLeader(c *gin.Context, node *raft.Node, forwardTLS *tls.Config, tenantID, model string) {
	leaderAddr := node.LeaderAddr()
	if leaderAddr == "" {
		c.JSON(http.StatusServiceUnavailable, gin.H{
			"error":  "cluster_unreachable",
			"reason": "no known cluster raft leader to resolve the name-only stop against",
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
			"error":  "cluster_unreachable",
			"reason": "the cluster raft leader's own cluster API address is not yet known to this node",
		})
		return
	}

	status, body, err := ForwardNameOnlyStop(forwardTLS, leaderAPIAddr, tenantID, model, c.GetHeader("Authorization"))
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{
			"error":  "stop_delivery_failed",
			"reason": err.Error(),
		})
		return
	}
	c.Data(status, "application/json; charset=utf-8", body)
}

// dispatchNameOnlyStatus is T023's status-side implementation
// (contracts/cluster-model-api.md: "multi-node results are returned as a
// list, each entry naming its source node"). Unlike stop, resolving AND
// serving this request needs no Raft write at all - reading this node's
// OWN locally-replicated State() is the exact same eventually-consistent
// read GET /v1/cluster/status already performs with no leader
// requirement (routes_cluster.go) - so this runs on ANY node, leader or
// follower, with no forward-the-whole-decision-to-leader step; only the
// per-node LIVE status query itself is forwarded, to whichever real node
// each matched entry names.
func dispatchNameOnlyStatus(c *gin.Context, base *executor.LocalExecutor, node *raft.Node, forwardTLS *tls.Config, tenantID, model string) {
	state := node.State()
	matches := runningProfileMatches(state.RunningProfiles, model, tenantID)
	if len(matches) == 0 {
		c.JSON(http.StatusNotFound, gin.H{
			"error":  "profile_not_running",
			"reason": "no cluster node reports profile " + model + " running for this tenant",
		})
		return
	}

	instances := make([]gin.H, 0, len(matches))
	for _, m := range matches {
		var (
			liveStatus string
			queryErr   error
		)
		switch {
		case m.NodeID == node.ID():
			liveStatus, queryErr = base.WithTenant(tenantID).Status(model)
		default:
			apiAddr := state.Nodes[m.NodeID].APIAddr
			if apiAddr == "" {
				queryErr = fmt.Errorf("node %q has no known cluster API address to query status from", m.NodeID)
			} else {
				liveStatus, queryErr = ForwardModelStatus(forwardTLS, apiAddr, m.NodeID, tenantID, model, c.GetHeader("Authorization"))
			}
		}

		if queryErr != nil {
			// Never silently dropped (spec.md's Edge Case/FR-008): a
			// node this cluster's own index says IS running the
			// profile, but that this daemon could not reach right now,
			// is reported as its own instance entry naming the real
			// error, never quietly omitted from the list.
			instances = append(instances, gin.H{"node": m.NodeID, "error": queryErr.Error()})
			continue
		}
		instances = append(instances, gin.H{"node": m.NodeID, "status": liveStatus})
	}

	c.JSON(http.StatusOK, gin.H{"profile": model, "instances": instances})
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
