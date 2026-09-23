// Package api (client.go): the cross-process half of Join. internal/raft's
// Node.Join is called BY an existing leader against a target address; a
// brand-new process that wants to join an EXISTING cluster instead calls
// RequestJoin against that leader's own api.Server, naming its own
// transport address as the peer to add.
package api

import (
	"bytes"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/quic-go/quic-go/http3"

	"github.com/vasic-digital/llmctl/llmctld/internal/cluster"
)

// requestJoinRetryBudget bounds how long RequestJoin retries a 409
// ("node is not the leader") response before giving up. A freshly
// bootstrapped single-node cluster does NOT elect itself leader
// instantly - hashicorp/raft's own randomized heartbeat/election timeout
// (its DefaultConfig() values) takes up to ~1-2s - so a join attempt made
// the moment the leader's API starts listening, before its own election
// completes, genuinely needs to retry past that race. This was found as
// a real bug (a genuine 409 observed end-to-end via cmd/llmctld's real
// "cluster join" subcommand against a real "cluster bootstrap" process),
// not invented defensively.
const requestJoinRetryBudget = 10 * time.Second

// requestJoinRetryInterval is how long RequestJoin waits between retries.
const requestJoinRetryInterval = 100 * time.Millisecond

// RequestJoin asks the leader reachable at leaderAPIAddr to add peerID
// (reachable at peerAddr) as a new Raft voter, via a real HTTP/3+mTLS
// POST to /v1/cluster/join - clientTLS must carry a certificate signed by
// the SAME CA as the target cluster (the same mTLS discipline every other
// node-to-node call in this codebase uses). peerID MUST be the joining
// node's own real NodeID (see internal/raft/node.go's Join doc comment
// for why this matters - an address-derived ID is a real, found bug).
//
// peerAPIAddr is the joining node's own real HTTP API address (T008,
// 003-kv-cache-replication) - propagated into joinRequest.APIAddr so the
// leader can durably record it in the cluster's node registry
// (raft.Node.RegisterNode, CommandJoinNode) the moment the join succeeds,
// which is what internal/replication.Forwarder's AddrResolver needs to
// find a replica's real address to forward appends/checkpoints to. Unlike
// peerAddr (the Raft transport address), peerAPIAddr is never used by
// hashicorp/raft itself - it exists purely for this cross-node HTTP
// forwarding concern.
//
// A 409 response (node.Join's own real failure, almost always
// hraft.ErrNotLeader wrapped by routes_cluster.go - see its own handler)
// is retried for up to requestJoinRetryBudget before RequestJoin gives
// up: the target may simply not have completed its own leader election
// yet. Any OTHER failure (a malformed request, a network error, a
// timeout) is NOT retried and surfaces immediately - only the specific,
// expected "not yet the leader" race is tolerated.
//
// resources (002-cluster-model-scheduler T006, contracts/cluster-model-
// api.md) is the joining node's own real hardware-probe-derived capacity,
// forwarded verbatim as joinRequest's own required Resources field - the
// caller (cmd/llmctld's "cluster join" subcommand) is responsible for
// sourcing it from the real local hardware probe; RequestJoin itself
// never probes hardware, it only transports whatever resources it is
// given.
//
// apiAddr (002-cluster-model-scheduler T017's prerequisite; also
// consumed by 003-kv-cache-replication's T008 via
// raft.Node.RegisterNode) is the joining node's own real HTTP/3+mTLS
// cluster-API bind address (its own internal/api.Server's bound address,
// obtained AFTER that server has started listening - never a
// placeholder), forwarded as joinRequest's optional APIAddr field so
// cross-node model-lifecycle forwarding AND internal/replication.Forwarder's
// AddrResolver can both later dial this node directly.
func RequestJoin(clientTLS *tls.Config, leaderAPIAddr, peerID, peerAddr, apiAddr string, resources cluster.Resources) error {
	client := &http.Client{
		Transport: &http3.Transport{TLSClientConfig: clientTLS},
		Timeout:   10 * time.Second,
	}

	body, err := json.Marshal(joinRequest{PeerID: peerID, PeerAddr: peerAddr, APIAddr: apiAddr, Resources: resources})
	if err != nil {
		return fmt.Errorf("api: RequestJoin: marshal request: %w", err)
	}

	deadline := time.Now().Add(requestJoinRetryBudget)
	var lastErr error
	for {
		resp, err := client.Post("https://"+leaderAPIAddr+"/v1/cluster/join", "application/json", bytes.NewReader(body))
		if err != nil {
			return fmt.Errorf("api: RequestJoin: %w", err)
		}

		if resp.StatusCode == http.StatusOK {
			_ = resp.Body.Close()
			return nil
		}

		respBody, _ := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		lastErr = fmt.Errorf("api: RequestJoin: leader at %s returned %d: %s", leaderAPIAddr, resp.StatusCode, respBody)

		if resp.StatusCode != http.StatusConflict || time.Now().After(deadline) {
			return lastErr
		}
		time.Sleep(requestJoinRetryInterval)
	}
}

// forwardModelStartRetryBudget/forwardModelStartRetryInterval bound
// ForwardModelStart's narrow, explicit retry for the SPECIFIC "target
// briefly unreachable" case spec.md's Edge Cases names (a connection
// refused/timeout in the brief window right after this cluster's own
// membership view chose a node - e.g. it is mid-restart) - deliberately
// NOT a generic unbounded retry (spec.md's own explicit constraint,
// mirroring requestJoinRetryBudget's identical narrow-retry discipline
// but on network-level errors rather than a specific HTTP status, since
// the receiving node's own handler never has a reason to return 409 for
// this route the way a not-yet-elected leader does for /v1/cluster/join).
//
// forwardModelStartAttemptTimeout bounds each INDIVIDUAL attempt's own
// http.Client.Timeout, and MUST stay meaningfully SMALLER than
// forwardModelStartRetryBudget - real, live-reproduced defect (2026-09-23):
// this client's Timeout used to be a bare, unlabeled 10s, LARGER than the
// entire 5s retry budget. A single attempt against a target that is
// genuinely, briefly busy (exactly the condition this retry exists for)
// can block for the client's own full Timeout before erroring - if that
// Timeout exceeds the retry budget, ONE slow attempt alone consumes more
// time than the whole budget, so the loop's own deadline check fires
// immediately after that first error and the function returns failure
// having made EXACTLY ONE attempt - the "narrow, explicit retry" this
// whole mechanism exists to provide never actually happens. Proven
// directly (TestForwardModelStart_RetriesWithinItsOwnBudget_
// NotJustOneSlowAttempt, client_test.go): a single deliberately-blocked
// attempt consumed the full old 10s Timeout and returned failure at
// exactly that mark, 2x over the declared 5s budget, having never
// retried. 1s leaves comfortable room for several genuine retries (at
// the 100ms interval below) within the unchanged 5s overall bound.
const (
	forwardModelStartRetryBudget    = 5 * time.Second
	forwardModelStartRetryInterval  = 100 * time.Millisecond
	forwardModelStartAttemptTimeout = 1 * time.Second
)

// ForwardModelStart forwards a model-start request that THIS node's own
// cluster.Place() chose for a DIFFERENT node (targetAPIAddr,
// targetNodeID) to that node's real cluster HTTP API - a real HTTP/3+mTLS
// POST to the SAME /v1/tenants/:id/models/:model/start route a
// directly-addressed caller would use, structurally parallel to
// RequestJoin (same http3.Transport+mTLS pattern).
//
// The request body names targetNodeID as the request's own "node" field,
// so the receiving node's handler takes the explicit-node LOCAL-dispatch
// path (routes_models.go's own T019 guarantee: a request naming a node
// never enters Place() itself) rather than re-running its own placement
// decision against a request this cluster already decided.
//
// authorizationHeader is the ORIGINAL caller's own, verbatim
// "Authorization: Bearer <token>" header value, forwarded unchanged as
// the receiving node's own Authorization header - the receiving node
// re-runs its OWN full RequireJWT + authorizeTenantOwnership + CheckRBAC
// + CheckTenantBoundary gate chain against it (never trusting "the
// sending node already authorized this"), exactly matching every other
// per-request authorization check already established across this
// cluster.
func ForwardModelStart(clientTLS *tls.Config, targetAPIAddr, targetNodeID, tenantID, model, authorizationHeader string) error {
	client := &http.Client{
		Transport: &http3.Transport{TLSClientConfig: clientTLS},
		Timeout:   forwardModelStartAttemptTimeout,
	}

	body, err := json.Marshal(nodeOptionalRequest{Node: targetNodeID})
	if err != nil {
		return fmt.Errorf("api: ForwardModelStart: marshal request: %w", err)
	}
	url := "https://" + targetAPIAddr + "/v1/tenants/" + tenantID + "/models/" + model + "/start"

	deadline := time.Now().Add(forwardModelStartRetryBudget)
	for {
		req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
		if err != nil {
			return fmt.Errorf("api: ForwardModelStart: build request: %w", err)
		}
		req.Header.Set("Content-Type", "application/json")
		if authorizationHeader != "" {
			req.Header.Set("Authorization", authorizationHeader)
		}

		resp, err := client.Do(req)
		if err != nil {
			if time.Now().After(deadline) {
				return fmt.Errorf("api: ForwardModelStart: target %s at %s: %w", targetNodeID, targetAPIAddr, err)
			}
			time.Sleep(forwardModelStartRetryInterval)
			continue
		}

		if resp.StatusCode == http.StatusOK {
			_ = resp.Body.Close()
			return nil
		}
		respBody, _ := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		return fmt.Errorf("api: ForwardModelStart: target %s at %s returned %d: %s", targetNodeID, targetAPIAddr, resp.StatusCode, respBody)
	}
}

// ForwardAutoPlaceStart forwards an auto-placement start request (one
// naming NO "node" field) from a FOLLOWER node to leaderAPIAddr - found
// necessary as a real, previously-undiscovered gap
// (002-cluster-model-scheduler T013's own real 3-node integration test):
// dispatchAutoPlacedStart's own reservation step (node.RecordRunningProfile)
// is a real Raft write, which can only ever succeed on the CURRENT LEADER
// (see internal/raft.Node.LeaderAddr's own doc comment) - a follower
// receiving a no-node start request cannot run cluster.Place()+reserve
// locally no matter which node it would choose, and must instead forward
// the WHOLE decision to the leader, unlike ForwardModelStart (which
// forwards an ALREADY-DECIDED, explicit-node request to whichever node
// cluster.Place() chose - that node need not be the leader at all).
//
// Unlike ForwardModelStart, the caller needs the leader's EXACT response
// (status code + body) relayed back verbatim - the leader is the one that
// actually ran cluster.Place() and knows which node was chosen, or the
// exact "insufficient_capacity"/"considered" shortfall - so this function
// returns the real observed status code + body rather than a bare error,
// and the caller (routes_models.go) copies both directly onto its own
// gin.Context response, never re-deciding or re-wrapping them.
func ForwardAutoPlaceStart(clientTLS *tls.Config, leaderAPIAddr, tenantID, model, authorizationHeader string) (statusCode int, body []byte, err error) {
	client := &http.Client{
		Transport: &http3.Transport{TLSClientConfig: clientTLS},
		Timeout:   10 * time.Second,
	}

	reqBody, err := json.Marshal(nodeOptionalRequest{})
	if err != nil {
		return 0, nil, fmt.Errorf("api: ForwardAutoPlaceStart: marshal request: %w", err)
	}
	url := "https://" + leaderAPIAddr + "/v1/tenants/" + tenantID + "/models/" + model + "/start"

	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(reqBody))
	if err != nil {
		return 0, nil, fmt.Errorf("api: ForwardAutoPlaceStart: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if authorizationHeader != "" {
		req.Header.Set("Authorization", authorizationHeader)
	}

	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, fmt.Errorf("api: ForwardAutoPlaceStart: leader at %s: %w", leaderAPIAddr, err)
	}
	defer func() { _ = resp.Body.Close() }()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return resp.StatusCode, nil, fmt.Errorf("api: ForwardAutoPlaceStart: read leader response from %s: %w", leaderAPIAddr, err)
	}
	return resp.StatusCode, respBody, nil
}

// ForwardModelStop forwards a model-stop request that THIS node's own
// running-profile-index resolution (routes_models.go's
// dispatchNameOnlyStop, 002-cluster-model-scheduler T023) found running
// on a DIFFERENT node (targetAPIAddr, targetNodeID) to that node's real
// cluster HTTP API - a real HTTP/3+mTLS POST to the SAME
// /v1/tenants/:id/models/:model/stop route a directly-addressed caller
// would use, structurally parallel to ForwardModelStart (same
// http3.Transport+mTLS pattern, same narrow "target briefly unreachable"
// retry discipline spec.md's Edge Cases name for cross-node model-
// lifecycle forwarding generally, not merely the start case).
//
// The request body names targetNodeID as the request's own "node"
// field, so the receiving node's handler takes the explicit-node LOCAL-
// dispatch path (routes_models.go's own byte-identical-to-pre-Phase-4
// guarantee for stop, mirroring T019's identical guarantee for start)
// rather than re-resolving a decision this cluster's leader already
// made.
//
// authorizationHeader is forwarded unchanged exactly as ForwardModelStart
// documents: the receiving node re-runs its OWN full RequireJWT +
// authorizeTenantOwnership + CheckRBAC + CheckTenantBoundary gate chain
// against it, never trusting "the sending node already authorized this"
// (T025's own authorization-parity review target).
func ForwardModelStop(clientTLS *tls.Config, targetAPIAddr, targetNodeID, tenantID, model, authorizationHeader string) error {
	client := &http.Client{
		Transport: &http3.Transport{TLSClientConfig: clientTLS},
		Timeout:   10 * time.Second,
	}

	body, err := json.Marshal(nodeOptionalRequest{Node: targetNodeID})
	if err != nil {
		return fmt.Errorf("api: ForwardModelStop: marshal request: %w", err)
	}
	url := "https://" + targetAPIAddr + "/v1/tenants/" + tenantID + "/models/" + model + "/stop"

	deadline := time.Now().Add(forwardModelStartRetryBudget)
	for {
		req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
		if err != nil {
			return fmt.Errorf("api: ForwardModelStop: build request: %w", err)
		}
		req.Header.Set("Content-Type", "application/json")
		if authorizationHeader != "" {
			req.Header.Set("Authorization", authorizationHeader)
		}

		resp, err := client.Do(req)
		if err != nil {
			if time.Now().After(deadline) {
				return fmt.Errorf("api: ForwardModelStop: target %s at %s: %w", targetNodeID, targetAPIAddr, err)
			}
			time.Sleep(forwardModelStartRetryInterval)
			continue
		}

		if resp.StatusCode == http.StatusOK {
			_ = resp.Body.Close()
			return nil
		}
		respBody, _ := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		return fmt.Errorf("api: ForwardModelStop: target %s at %s returned %d: %s", targetNodeID, targetAPIAddr, resp.StatusCode, respBody)
	}
}

// ForwardModelStatus forwards a real, live status query for a profile
// the calling node's own running-profile-index resolution
// (dispatchNameOnlyStatus, T023) found running on a DIFFERENT node
// (targetAPIAddr, targetNodeID), returning that node's OWN real,
// currently-observed status string - structurally parallel to
// ForwardModelStop/ForwardModelStart (same transport pattern), naming
// targetNodeID in the request body for the identical reason (the
// receiving node's explicit-node path dispatches locally, never
// re-resolving).
//
// Unlike ForwardModelStop, the caller needs the DECODED status string
// itself (not merely success/failure) to build its own per-node
// instances list, so this returns (string, error) rather than a bare
// error - a non-200 response, or a response this function cannot decode
// as {"status": "..."}, is surfaced as an error the caller reports per
// its own instance entry, never silently treated as an empty status.
func ForwardModelStatus(clientTLS *tls.Config, targetAPIAddr, targetNodeID, tenantID, model, authorizationHeader string) (string, error) {
	client := &http.Client{
		Transport: &http3.Transport{TLSClientConfig: clientTLS},
		Timeout:   10 * time.Second,
	}

	body, err := json.Marshal(nodeOptionalRequest{Node: targetNodeID})
	if err != nil {
		return "", fmt.Errorf("api: ForwardModelStatus: marshal request: %w", err)
	}
	url := "https://" + targetAPIAddr + "/v1/tenants/" + tenantID + "/models/" + model + "/status"

	req, err := http.NewRequest(http.MethodGet, url, bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("api: ForwardModelStatus: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if authorizationHeader != "" {
		req.Header.Set("Authorization", authorizationHeader)
	}

	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("api: ForwardModelStatus: target %s at %s: %w", targetNodeID, targetAPIAddr, err)
	}
	defer func() { _ = resp.Body.Close() }()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("api: ForwardModelStatus: read response from target %s at %s: %w", targetNodeID, targetAPIAddr, err)
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("api: ForwardModelStatus: target %s at %s returned %d: %s", targetNodeID, targetAPIAddr, resp.StatusCode, respBody)
	}

	var decoded struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal(respBody, &decoded); err != nil {
		return "", fmt.Errorf("api: ForwardModelStatus: decode response from target %s at %s: %w", targetNodeID, targetAPIAddr, err)
	}
	return decoded.Status, nil
}

// ForwardNameOnlyStop forwards a name-only stop request (one naming NO
// "node" field) from a FOLLOWER node to leaderAPIAddr - the stop-side
// analogue of ForwardAutoPlaceStart, needed for the identical structural
// reason (002-cluster-model-scheduler T023's own real gap, found by
// applying T013's exact lesson to the stop path before it could recur
// there too): dispatchNameOnlyStop's own CommandClearRunningProfile
// calls are real Raft writes, which can only ever succeed on the CURRENT
// LEADER (internal/raft.Node.LeaderAddr's own doc comment) - a follower
// receiving a name-only stop request cannot resolve+clear the running-
// profile index locally no matter which real node(s) it would find, and
// must instead forward the WHOLE decision to the leader.
//
// Exactly like ForwardAutoPlaceStart, the caller needs the leader's
// EXACT response (status code + body) relayed back verbatim - the leader
// is the one that actually resolved the index and cleared it, or hit the
// exact "profile_not_running"/"stop_delivery_failed" failure - so this
// returns the real observed status code + body rather than a bare error.
func ForwardNameOnlyStop(clientTLS *tls.Config, leaderAPIAddr, tenantID, model, authorizationHeader string) (statusCode int, body []byte, err error) {
	client := &http.Client{
		Transport: &http3.Transport{TLSClientConfig: clientTLS},
		Timeout:   10 * time.Second,
	}

	reqBody, err := json.Marshal(nodeOptionalRequest{})
	if err != nil {
		return 0, nil, fmt.Errorf("api: ForwardNameOnlyStop: marshal request: %w", err)
	}
	url := "https://" + leaderAPIAddr + "/v1/tenants/" + tenantID + "/models/" + model + "/stop"

	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(reqBody))
	if err != nil {
		return 0, nil, fmt.Errorf("api: ForwardNameOnlyStop: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if authorizationHeader != "" {
		req.Header.Set("Authorization", authorizationHeader)
	}

	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, fmt.Errorf("api: ForwardNameOnlyStop: leader at %s: %w", leaderAPIAddr, err)
	}
	defer func() { _ = resp.Body.Close() }()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return resp.StatusCode, nil, fmt.Errorf("api: ForwardNameOnlyStop: read leader response from %s: %w", leaderAPIAddr, err)
	}
	return resp.StatusCode, respBody, nil
}
