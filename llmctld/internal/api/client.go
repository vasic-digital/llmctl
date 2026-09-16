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
// apiAddr (002-cluster-model-scheduler T017's prerequisite) is the
// joining node's own real HTTP/3+mTLS cluster-API bind address (its own
// internal/api.Server's bound address, obtained AFTER that server has
// started listening - never a placeholder), forwarded as joinRequest's
// optional APIAddr field so cross-node model-lifecycle forwarding can
// later dial this node directly.
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
const (
	forwardModelStartRetryBudget   = 5 * time.Second
	forwardModelStartRetryInterval = 100 * time.Millisecond
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
		Timeout:   10 * time.Second,
	}

	body, err := json.Marshal(startModelRequest{Node: targetNodeID})
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
