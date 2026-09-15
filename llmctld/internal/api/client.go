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
func RequestJoin(clientTLS *tls.Config, leaderAPIAddr, peerID, peerAddr string) error {
	client := &http.Client{
		Transport: &http3.Transport{TLSClientConfig: clientTLS},
		Timeout:   10 * time.Second,
	}

	body, err := json.Marshal(joinRequest{PeerID: peerID, PeerAddr: peerAddr})
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
			resp.Body.Close()
			return nil
		}

		respBody, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		lastErr = fmt.Errorf("api: RequestJoin: leader at %s returned %d: %s", leaderAPIAddr, resp.StatusCode, respBody)

		if resp.StatusCode != http.StatusConflict || time.Now().After(deadline) {
			return lastErr
		}
		time.Sleep(requestJoinRetryInterval)
	}
}
