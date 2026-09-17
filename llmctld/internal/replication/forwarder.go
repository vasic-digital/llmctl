// Package replication (forwarder.go): 003-kv-cache-replication's
// automatic cross-node forwarding daemon (T008, spec.md FR-002/FR-004,
// User Story 1) - the piece failover_state_test.go's own
// TestFailoverState_KVCacheSurvivesPrimaryKill (T062) disclosed as
// missing: "nothing inside the running process yet calls those routes on
// ANOTHER node's behalf." Forwarder closes that gap by posting a
// primary's own real appends/checkpoints to every current replica's real
// /v1/replication/append and /v1/replication/checkpoint HTTP routes
// (internal/api's RegisterReplicationRoutes) the moment they land on the
// primary's own Store.
//
// Decoupling (Constitution §11.4.28): this file does NOT import
// internal/cluster or internal/raft - RoleResolver/AddrResolver are
// plain function types the wiring layer (internal/api, which already
// depends on both) supplies as closures, so internal/replication stays
// exactly as reusable/project-decoupled as wal.go/checkpoint.go already
// are. The real HTTP transport (HTTP/3+mTLS in production,
// http.DefaultClient/httptest in forwarder_test.go) is likewise
// caller-injected via httpClient, never hardcoded here - see
// forwarder_test.go's own doc comment.
//
// Race-condition analysis (T005, spec.md's Edge Cases: "the system must
// never have two nodes simultaneously believing they are the
// authoritative forwarding source for the same conversation in a way
// that could apply the same append twice or in conflicting order"):
//
//  1. ReplicationRole is Raft-replicated COMMITTED state
//     (internal/raft/fsm.go's CommandAssignReplicationRole/
//     CommandReassignReplicationRole) - at any given committed log
//     index, EXACTLY ONE ReplicationRole record exists per tenant (a
//     single map entry, replaced atomically - state.go's own doc
//     comment), so two nodes can never both be the COMMITTED primary at
//     once.
//  2. The remaining risk is STALENESS, not split-brain: a node that WAS
//     primary keeps forwarding for the brief window between (a) a
//     reassignment committing elsewhere and (b) this node's own next
//     role lookup observing it. This is why RoleResolver is called ONCE
//     PER FORWARD ATTEMPT (ForwardAppend/ForwardCheckpoint each call it
//     fresh, never cache it across calls or read it once at
//     construction) - it bounds the staleness window to "at most the
//     forward calls already in flight when the reassignment committed",
//     never unbounded.
//  3. Within that bounded window, a duplicate/overlapping append landing
//     on a replica is HARMLESS: wal.go's WAL.Append is keyed by Seq
//     (bbolt Put on seqKey(entry.Seq)) - re-applying the SAME
//     (Seq, TokenID, Position) twice is an idempotent overwrite, not a
//     duplicate entry, and the token sequence a genuine (non-split-
//     brain) primary produces for a given Seq is deterministic - so two
//     consecutive primaries forwarding around a reassignment can only
//     ever disagree on Seq values NEITHER has forwarded yet, never on an
//     already-committed Seq's content.
//  4. Honest boundary (Constitution §11.4.6) - what this analysis does
//     NOT cover: a genuine split-brain where TWO nodes independently
//     accept NEW user requests (not merely forward already-decided
//     content) for the SAME tenant at once. Which node accepts a new
//     inference request for a tenant is a request-ROUTING decision this
//     feature's ReplicationRole does not make and is explicitly out of
//     this feature's scope (spec.md assigns this feature ONLY the
//     forwarding-authority-tracking concern).
package replication

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"
)

// forwardWALEntry/forwardAppendRequest/forwardCheckpointRequest mirror
// internal/api/routes_replication.go's real JSON wire shapes
// (walEntryJSON/appendRequest/checkpointRequest) field-for-field, as
// plain, independent local types - this package MUST NOT import
// internal/api (internal/api already imports internal/replication;
// importing back would be a cycle), matching
// test/integration/failover_state_test.go's own documented reason for
// doing the identical duplication.
type forwardWALEntry struct {
	Seq      uint64 `json:"seq"`
	TokenID  int32  `json:"token_id"`
	Position int32  `json:"position"`
}

type forwardAppendRequest struct {
	Entries []forwardWALEntry `json:"entries"`
}

type forwardCheckpointRequest struct {
	Seq   uint64  `json:"seq"`
	State KVState `json:"state"`
}

// forwardRetryBudget/forwardRetryInterval bound how long Forwarder
// retries ONE unreachable replica before giving up on that forward
// attempt - spec.md FR-004: forwarding to one replica's failure MUST NOT
// block the primary's own response to its caller indefinitely, so this
// budget is deliberately short. A replica down longer than this shows up
// as real, growing lag (User Story 3's lag.go, T018) rather than as a
// hung caller request.
//
// forwardRequestTimeout bounds EACH INDIVIDUAL attempt inside that
// budget (postWithRetry, below) via a real per-request context.Context
// deadline - independent of whatever Timeout the CALLER's own
// f.httpClient happens to carry (production: cmd/llmctld/main.go's
// newForwardingHTTPClient, 10s; forwarder_test.go's own tests, anywhere
// from 500ms to unset/default). Found as a genuine, previously-latent
// bug via 001-llmctl-completion's T072-FU7 real 3-node integration test
// (a genuinely-crashed replica's real QUIC/UDP dial attempt has no
// ICMP-equivalent fast failure the way a closed TCP port does, so it
// blocks for the full CLIENT Timeout, not forwardRetryBudget) - this
// constant was declared with exactly this intent but was never actually
// wired into a request, so forwardRetryBudget's own "bounded, never
// indefinite" promise silently depended on every caller happening to
// supply a short enough client Timeout, which production's own real
// http.Client does not. Each attempt is bounded to
// min(forwardRequestTimeout, time remaining in the retry budget) - since
// forwardRequestTimeout (5s) is itself LARGER than forwardRetryBudget
// (2s), the remaining-budget bound is what actually governs at today's
// values (a single attempt can never exceed ~forwardRetryBudget total),
// while forwardRequestTimeout still defends against a future
// forwardRetryBudget increase making one attempt alone exceed a sane
// upper bound.
const (
	forwardRetryBudget    = 2 * time.Second
	forwardRetryInterval  = 100 * time.Millisecond
	forwardRequestTimeout = 5 * time.Second
)

// RoleResolver returns tenantID's CURRENT primary node ID and replica
// node IDs, or ok=false if no role is recorded for that tenant yet -
// re-read on EVERY forward call, never cached (see forwarder.go's
// package doc comment, T005's race-condition analysis point 2).
type RoleResolver func(tenantID string) (primaryNodeID string, replicaNodeIDs []string, ok bool)

// AddrResolver returns nodeID's real, currently-known HTTP base URL
// (e.g. "https://10.0.0.2:8443", no trailing slash), or ok=false if this
// caller has no address on record for it. Forwarder skips (never blocks
// or errors on) a replica it cannot resolve an address for - a replica
// this node genuinely does not know how to reach cannot be forwarded to
// no matter how long it waits.
type AddrResolver func(nodeID string) (baseURL string, ok bool)

// Forwarder posts a primary's own real appends/checkpoints to every
// CURRENT replica's real replication routes. See this file's package
// doc comment for the full race-condition analysis (T005) this design
// is built against.
type Forwarder struct {
	selfID     string
	roles      RoleResolver
	addrs      AddrResolver
	httpClient *http.Client
	// lag is T018's (User Story 3) replication-lag tracker - ALWAYS
	// present (never nil), fed exclusively as a side effect of this
	// Forwarder's own real per-replica forward attempts (forwardToReplicas
	// below) rather than an optional/opt-in mechanism, since lag.go's own
	// package doc comment requires it be fed from THIS existing
	// forwarding-acknowledgment traffic, never a second parallel channel.
	lag *LagTracker
}

// NewForwarder constructs a Forwarder identifying itself as selfID
// (compared against RoleResolver's returned primaryNodeID to decide
// whether THIS node should forward at all). httpClient is the caller's
// own real transport (production: HTTP/3+mTLS via quic-go/http3;
// tests: a plain http.Client against an httptest.Server - see
// forwarder_test.go's own doc comment for why the transport is
// deliberately decoupled from this file's forwarding logic).
func NewForwarder(selfID string, roles RoleResolver, addrs AddrResolver, httpClient *http.Client) *Forwarder {
	return &Forwarder{selfID: selfID, roles: roles, addrs: addrs, httpClient: httpClient, lag: NewLagTracker()}
}

// LagTracker returns f's own internal replication-lag tracker (T018,
// User Story 3, spec.md FR-010) - the SAME tracker every
// ForwardAppend/ForwardCheckpoint call below updates as a side effect of
// its own real per-replica forward attempts, so a caller reading it
// (internal/api's new GET /v1/replication/lag route, T019) always sees
// state derived from real forwarding-acknowledgment traffic, never a
// parallel/independently-fed signal.
func (f *Forwarder) LagTracker() *LagTracker {
	return f.lag
}

// ForwardAppend forwards entries to every current replica of tenantID
// via real POST <replica-base-url>/v1/replication/append calls, IF
// selfID is CURRENTLY tenantID's recorded primary - a node that is not
// (or no longer) primary forwards nothing (an honest no-op, never an
// error): FR-011's "exactly one authoritative forwarding source" means
// only the primary fans out.
func (f *Forwarder) ForwardAppend(tenantID, bearerToken string, entries []WALEntry) error {
	primaryID, replicaIDs, ok := f.roles(tenantID)
	if !ok || primaryID != f.selfID {
		return nil
	}
	wireEntries := make([]forwardWALEntry, len(entries))
	var maxSeq uint64
	for i, e := range entries {
		wireEntries[i] = forwardWALEntry(e)
		if e.Seq > maxSeq {
			maxSeq = e.Seq
		}
	}
	body, err := json.Marshal(forwardAppendRequest{Entries: wireEntries})
	if err != nil {
		return fmt.Errorf("replication: forward append for tenant %q: %w", tenantID, err)
	}
	return f.forwardToReplicas(replicaIDs, "/v1/replication/append", tenantID, bearerToken, maxSeq, body)
}

// ForwardCheckpoint is ForwardAppend's checkpoint sibling - same
// primary-only gating, same per-replica fan-out.
func (f *Forwarder) ForwardCheckpoint(tenantID, bearerToken string, seq uint64, state KVState) error {
	primaryID, replicaIDs, ok := f.roles(tenantID)
	if !ok || primaryID != f.selfID {
		return nil
	}
	body, err := json.Marshal(forwardCheckpointRequest{Seq: seq, State: state})
	if err != nil {
		return fmt.Errorf("replication: forward checkpoint for tenant %q: %w", tenantID, err)
	}
	return f.forwardToReplicas(replicaIDs, "/v1/replication/checkpoint", tenantID, bearerToken, seq, body)
}

// forwardToReplicas fans body out to every replicaID other than selfID,
// skipping (never erroring on) any replica AddrResolver cannot resolve,
// and collecting every genuine per-replica failure into one combined
// error (a caller learns EVERY replica that failed, not just the first).
//
// seq is this forward call's own highest WAL Seq (the batch's max Seq for
// an append, or the checkpoint's own Seq) - T018's LagTracker records it
// against EVERY named replica BEFORE the per-replica attempt even begins
// (f.lag.recordAttempt), so a replica this loop never manages to reach
// (unresolvable address OR a genuine per-replica failure below) still
// shows a real, growing lag rather than silently staying at its last-known
// value (spec.md's Edge Cases: "the replica's lag must become visible ...
// rather than silently dropped"). f.lag.recordConfirmed is called ONLY
// after a real per-replica success (postWithRetry returning nil) - the
// SAME real forwarding-acknowledgment traffic T008 already produces
// (lag.go's own package doc comment), never an independently-fed signal.
//
// tenantID is carried onto every forwarded request as an X-Tenant-ID
// header (T011 tenant-scoping review) - EXACTLY the header
// internal/api/routes_replication.go's resolveStore reads to pick which
// tenant's Store a request operates against (T072-FU5): without this,
// a non-default tenant's forwarded content would silently land in the
// receiving node's DEFAULT tenant Store instead of the originating
// tenant's, a real cross-tenant data-misrouting bug. The default ("")
// tenant OMITS the header entirely rather than sending an empty value -
// matching routes_replication.go's own "an absent header resolves to the
// empty tenant ID" contract exactly (its doc comment), never relying on
// an empty-string header value behaving identically by accident.
func (f *Forwarder) forwardToReplicas(replicaIDs []string, path, tenantID, bearerToken string, seq uint64, body []byte) error {
	var errs []error
	for _, id := range replicaIDs {
		if id == f.selfID {
			continue
		}
		f.lag.recordAttempt(tenantID, id, seq)
		baseURL, ok := f.addrs(id)
		if !ok {
			continue // FR-004: an unresolvable replica is skipped, never blocking.
		}
		if err := f.postWithRetry(baseURL, path, tenantID, bearerToken, body); err != nil {
			errs = append(errs, fmt.Errorf("replica %q (%s): %w", id, baseURL, err))
			continue
		}
		f.lag.recordConfirmed(tenantID, id, seq)
	}
	if len(errs) > 0 {
		return errors.Join(errs...)
	}
	return nil
}

// forwardTenantIDHeader is the header name forwarded requests carry
// tenantID under - MUST match internal/api/routes_replication.go's
// tenantIDHeader constant exactly (both packages independently define
// this literal rather than one importing the other, matching this file's
// own package doc comment on decoupling from internal/api).
const forwardTenantIDHeader = "X-Tenant-ID"

// postWithRetry POSTs body to baseURL+path, retrying a failure for up to
// forwardRetryBudget (FR-004: bounded, never indefinite) before
// returning the last observed error. Each individual attempt is bounded
// by postOnce's own per-request context deadline (see forwardRequestTimeout's
// doc comment above for why this is load-bearing, not merely defensive) -
// the retry loop's own between-attempts deadline check below is no longer
// the ONLY bound, closing the gap where a single slow-to-fail attempt
// could alone exceed the whole documented budget.
func (f *Forwarder) postWithRetry(baseURL, path, tenantID, bearerToken string, body []byte) error {
	deadline := time.Now().Add(forwardRetryBudget)
	var lastErr error
	for {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return lastErr
		}
		attemptTimeout := remaining
		if forwardRequestTimeout < attemptTimeout {
			attemptTimeout = forwardRequestTimeout
		}

		lastErr = f.postOnce(baseURL, path, tenantID, bearerToken, body, attemptTimeout)
		if lastErr == nil {
			return nil
		}

		if time.Now().After(deadline) {
			return lastErr
		}
		time.Sleep(forwardRetryInterval)
	}
}

// postOnce performs exactly ONE POST attempt, bounded by timeout via a
// real context.Context deadline - independent of whatever Timeout the
// caller's own f.httpClient happens to carry (see forwardRequestTimeout's
// doc comment above). cancel is deferred so it fires only after the
// response body has been fully read+closed below, never mid-read (which
// would surface as a spurious read error rather than this attempt's real
// outcome).
func (f *Forwarder) postOnce(baseURL, path, tenantID, bearerToken string, body []byte, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+path, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("build forward request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if bearerToken != "" {
		req.Header.Set("Authorization", "Bearer "+bearerToken)
	}
	if tenantID != "" {
		req.Header.Set(forwardTenantIDHeader, tenantID)
	}

	resp, err := f.httpClient.Do(req)
	if err != nil {
		return err
	}
	respBody, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("status %d: %s", resp.StatusCode, respBody)
	}
	return nil
}
