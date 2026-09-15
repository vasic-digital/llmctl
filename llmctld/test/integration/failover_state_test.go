// Package integration (failover_state_test.go): T062, the real 3-node
// KV-cache failover test (SC-019, US8 Acceptance Scenario 1). Reuses
// cluster_bootstrap_test.go's testCluster harness in this same package -
// every real llmctld process this test drives already opens a real
// internal/replication.Store and serves it over the real
// POST /v1/replication/append, POST /v1/replication/checkpoint, and
// GET /v1/replication/state routes (cmd/llmctld's main.go wiring) the
// moment it starts, so no additional spawn machinery is needed here.
package integration

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
)

// replAppendEntry/replAppendRequest/replKVState/replCheckpointRequest
// mirror internal/api/routes_replication.go's JSON wire shapes
// (walEntryJSON/appendRequest/replication.KVState/checkpointRequest) -
// duplicated here as plain, decoupled local types (matching only the
// JSON contract, never importing internal/api's unexported types)
// exactly as this package already keeps its own nodesResponse/
// statusResponse types independent of internal/api's private response
// structs in cluster_bootstrap_test.go.
type replAppendEntry struct {
	Seq      uint64 `json:"seq"`
	TokenID  int32  `json:"token_id"`
	Position int32  `json:"position"`
}

type replAppendRequest struct {
	Entries []replAppendEntry `json:"entries"`
}

type replKVState struct {
	Tokens    []int32 `json:"tokens"`
	Positions []int32 `json:"positions"`
}

type replCheckpointRequest struct {
	Seq   uint64      `json:"seq"`
	State replKVState `json:"state"`
}

// replicationAppendBatchSize bounds how many WALEntry items one
// POST /v1/replication/append request carries. Batching avoids issuing
// one HTTP/3+mTLS round trip per simulated token - 5000 individual
// requests would let connection/handshake overhead dominate this test's
// wall-clock, measuring loopback QUIC connection-setup cost rather than
// the replication logic actually being proven. 500 keeps each request
// body small (a real production caller would tune this per its own
// latency/throughput tradeoff) while cutting round trips 500x versus
// one-per-token.
const replicationAppendBatchSize = 500

// replicationAppend POSTs entries to apiAddr's real
// /v1/replication/append route (bearing token as an
// "Authorization: Bearer" header - every /v1/replication/* route
// requires a valid JWT since T072-FU5 closed a real cross-tenant
// data-access gap; see internal/api/routes_replication.go's package doc
// comment), batched per replicationAppendBatchSize.
func replicationAppend(t *testing.T, client *http.Client, apiAddr, token string, entries []replAppendEntry) {
	t.Helper()
	for i := 0; i < len(entries); i += replicationAppendBatchSize {
		end := i + replicationAppendBatchSize
		if end > len(entries) {
			end = len(entries)
		}
		body, err := json.Marshal(replAppendRequest{Entries: entries[i:end]})
		if err != nil {
			t.Fatalf("marshal append batch [%d:%d]: %v", i, end, err)
		}
		req, err := http.NewRequest(http.MethodPost, "https://"+apiAddr+"/v1/replication/append", bytes.NewReader(body))
		if err != nil {
			t.Fatalf("new append request to %s: %v", apiAddr, err)
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+token)
		resp, err := client.Do(req)
		if err != nil {
			t.Fatalf("POST /v1/replication/append to %s: %v", apiAddr, err)
		}
		if resp.StatusCode != http.StatusOK {
			respBody, _ := io.ReadAll(resp.Body)
			_ = resp.Body.Close()
			t.Fatalf("POST /v1/replication/append to %s: status = %d, body = %s", apiAddr, resp.StatusCode, respBody)
		}
		_ = resp.Body.Close()
	}
}

// replicationCheckpoint POSTs a checkpoint request to apiAddr's real
// /v1/replication/checkpoint route, bearing token (see replicationAppend's
// doc comment for why a token is required).
func replicationCheckpoint(t *testing.T, client *http.Client, apiAddr, token string, seq uint64, state replKVState) {
	t.Helper()
	body, err := json.Marshal(replCheckpointRequest{Seq: seq, State: state})
	if err != nil {
		t.Fatalf("marshal checkpoint request (seq=%d): %v", seq, err)
	}
	req, err := http.NewRequest(http.MethodPost, "https://"+apiAddr+"/v1/replication/checkpoint", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("new checkpoint request to %s (seq=%d): %v", apiAddr, seq, err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("POST /v1/replication/checkpoint to %s (seq=%d): %v", apiAddr, seq, err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		t.Fatalf("POST /v1/replication/checkpoint to %s (seq=%d): status = %d, body = %s", apiAddr, seq, resp.StatusCode, respBody)
	}
}

// replicationState GETs apiAddr's real /v1/replication/state route,
// bearing token (see replicationAppend's doc comment for why a token is
// required) - the node's current reconstructed KVState.
func replicationState(t *testing.T, client *http.Client, apiAddr, token string) replKVState {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, "https://"+apiAddr+"/v1/replication/state", nil)
	if err != nil {
		t.Fatalf("new state request to %s: %v", apiAddr, err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("GET /v1/replication/state from %s: %v", apiAddr, err)
	}
	defer func() { _ = resp.Body.Close() }()
	var got replKVState
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatalf("decode /v1/replication/state response from %s: %v", apiAddr, err)
	}
	return got
}

// waitForRealLeaderAmong polls every node in candidates' real
// /v1/cluster/status until exactly one reports itself the Raft leader,
// or timeout elapses - the same "resolve dynamically, never assume which
// physical node wins election" discipline
// TestClusterBootstrap_ThreeRealProcessesElectLeaderWithin5s already
// applies, generalised here to return the winning node rather than only
// asserting success.
func waitForRealLeaderAmong(t *testing.T, tc *testCluster, client *http.Client, candidates []*spawnedNode, timeout time.Duration) *spawnedNode {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		for _, n := range candidates {
			status, err := tc.getStatus(client, n.apiAddr)
			if err == nil && status.IsLeader {
				return n
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	return nil
}

// TestFailoverState_KVCacheSurvivesPrimaryKill is T062 (SC-019, US8
// Acceptance Scenario 1): a real 3-node cluster, an active "conversation"
// of 5000 simulated tokens replicated to all 3 real nodes via real
// HTTP/3+mTLS calls to each node's real internal/replication-backed
// routes, periodic checkpoints matching FR-026's default 1000-token
// interval, kill the real current Raft primary process, and assert the
// surviving new primary's reconstructed KV cache is within SC-019's <=5%
// token-loss bound and recovery completes within SC-019's <=30s bound.
//
// Honest scope boundary (Constitution §11.4.223 provenance markers,
// disclosed rather than silently narrowed - mirrors
// TestClusterFailover_KillingLeaderElectsNewRealLeaderAmongSurvivors's
// own disclosed T054 scope-narrowing in cluster_bootstrap_test.go): a
// real daemon-side mechanism that automatically forwards a primary's
// live WAL appends/checkpoints to every replica as they happen is NOT
// wired into the running llmctld binary - cmd/llmctld's main.go opens
// one real internal/replication.Store per node and exposes it over the
// real HTTP routes this test drives, but nothing inside the running
// process yet calls those routes on ANOTHER node's behalf (that
// automatic forwarding daemon is a separate, unbuilt piece of future
// work). This test's own replicationAppend/replicationCheckpoint calls
// against ALL THREE real node addresses play that forwarding role
// directly - proving the REAL replication.Store + REAL HTTP routes
// genuinely reconstruct state correctly under a real process kill and
// real Raft re-election, while honestly not claiming an automatic
// cross-node replication daemon exists yet.
func TestFailoverState_KVCacheSurvivesPrimaryKill(t *testing.T) {
	tc := newTestCluster(t)

	nodeA := tc.bootstrap("node-a")
	nodeB := tc.join("node-b", nodeA)
	nodeC := tc.join("node-c", nodeA)
	allNodes := []*spawnedNode{nodeA, nodeB, nodeC}

	client := tc.httpClient()

	// Every /v1/replication/* route requires a valid JWT since T072-FU5
	// (a real cross-tenant data-access gap an independent review found -
	// see internal/api/routes_replication.go's package doc comment).
	// This test exercises the default (no X-Tenant-ID header) tenant
	// path, so an empty-TenantID token authorizes it: JWTs are stateless
	// HS256 tokens validated purely by signature against
	// tc.jwtSigningKey (the SAME known key every spawned node's
	// LLMCTLD_JWT_SIGNING_KEY carries, per spawn()), so minting one
	// directly via auth.IssueToken - rather than round-tripping through
	// the real /v1/auth/token API-key-exchange flow
	// multitenancy_isolation_test.go's bootstrapWithAdmin/exchangeToken
	// helpers establish - is the right scope here: this test is about
	// failover/replication persistence, not about re-proving the auth
	// exchange flow's own correctness (already covered elsewhere).
	token, err := auth.IssueToken(auth.Claims{}, []byte(tc.jwtSigningKey))
	if err != nil {
		t.Fatalf("issue test jwt: %v", err)
	}

	// Precondition: the full 3-node Raft configuration is durably
	// replicated to EVERY node before proceeding - the same discipline
	// TestClusterFailover_KillingLeaderElectsNewRealLeaderAmongSurvivors
	// already establishes is required before killing anything (a
	// leader's own view of its configuration updates locally before a
	// majority durably holds it).
	deadline := time.Now().Add(5 * time.Second)
	for _, n := range allNodes {
		for {
			nodes, err := tc.getNodes(client, n.apiAddr)
			if err == nil && len(nodes.Servers) == 3 {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("precondition failed: node %q never observed the full 3-node configuration before the failover test began", n.nodeID)
			}
			time.Sleep(50 * time.Millisecond)
		}
	}

	// Resolve which real node is currently the primary (the Raft leader)
	// dynamically - which physical node wins election is not guaranteed
	// to be node-a.
	primary := waitForRealLeaderAmong(t, tc, client, allNodes, 5*time.Second)
	if primary == nil {
		t.Fatalf("no node reported itself as the Raft leader within 5s")
	}
	t.Logf("primary (current Raft leader) is %q", primary.nodeID)

	// Simulate an active "conversation" of 5000 tokens: sequential Seq
	// 1..5000, Position = index (a real monotonic token-position
	// sequence), TokenID a deterministic function of Seq (arbitrary but
	// reproducible - the exact vocabulary values are irrelevant to this
	// test; what matters is every node ends up holding the IDENTICAL
	// sequence).
	const totalTokens = 5000
	entries := make([]replAppendEntry, totalTokens)
	for i := 0; i < totalTokens; i++ {
		seq := uint64(i + 1)
		entries[i] = replAppendEntry{
			Seq:      seq,
			TokenID:  int32((seq * 7) % 50000),
			Position: int32(i),
		}
	}

	// Checkpoint interval matches FR-026's real default (every 1000
	// tokens - replication.DefaultIntervalTokens) - checkpoint all 3
	// nodes at the same points in the sequence, replicating the
	// "conversation" to every node (playing the not-yet-built automatic
	// forwarding daemon's role directly, per this test's disclosed
	// honest scope boundary above).
	const checkpointInterval = 1000
	replicationStart := time.Now()
	for _, n := range allNodes {
		for cpEnd := checkpointInterval; cpEnd <= totalTokens; cpEnd += checkpointInterval {
			batch := entries[cpEnd-checkpointInterval : cpEnd]
			replicationAppend(t, client, n.apiAddr, token, batch)

			state := replKVState{
				Tokens:    make([]int32, cpEnd),
				Positions: make([]int32, cpEnd),
			}
			for i := 0; i < cpEnd; i++ {
				state.Tokens[i] = entries[i].TokenID
				state.Positions[i] = entries[i].Position
			}
			replicationCheckpoint(t, client, n.apiAddr, token, uint64(cpEnd), state)
		}
	}
	t.Logf("replicated + checkpointed %d simulated tokens to all 3 real nodes in %s", totalTokens, time.Since(replicationStart))

	// Verify durability BEFORE destroying anything: every node's real
	// GET /v1/replication/state must report the full 5000-token
	// sequence, proving replication genuinely reached everyone (not just
	// the primary) - the same "verify before destroy" discipline
	// TestClusterFailover_KillingLeaderElectsNewRealLeaderAmongSurvivors
	// already applies to Raft configuration, applied here to replicated
	// KV state.
	for _, n := range allNodes {
		got := replicationState(t, client, n.apiAddr, token)
		if len(got.Tokens) != totalTokens || len(got.Positions) != totalTokens {
			t.Fatalf("node %q reports %d tokens / %d positions before the kill, want %d/%d - replication did not durably reach every node", n.nodeID, len(got.Tokens), len(got.Positions), totalTokens, totalTokens)
		}
		for i := range got.Tokens {
			if got.Tokens[i] != entries[i].TokenID || got.Positions[i] != entries[i].Position {
				t.Fatalf("node %q token/position mismatch at index %d before the kill: got (token=%d,pos=%d), want (token=%d,pos=%d)", n.nodeID, i, got.Tokens[i], got.Positions[i], entries[i].TokenID, entries[i].Position)
			}
		}
	}
	t.Logf("verified all 3 real nodes durably hold the full %d-token state before the kill", totalTokens)

	// Kill the real primary process - a genuine OS-level SIGKILL, not a
	// graceful shutdown, matching
	// TestClusterFailover_KillingLeaderElectsNewRealLeaderAmongSurvivors's
	// own crash-not-graceful-shutdown discipline so survivors experience
	// a real heartbeat-timeout-driven election exactly as a real crash
	// would produce.
	killTime := time.Now()
	if err := primary.cmd.Process.Kill(); err != nil {
		t.Fatalf("kill primary %q: %v", primary.nodeID, err)
	}
	_, _ = primary.cmd.Process.Wait()
	delete(tc.nodes, primary.nodeID) // already dead; killAll must not try to signal it again

	survivors := make([]*spawnedNode, 0, 2)
	for _, n := range allNodes {
		if n.nodeID != primary.nodeID {
			survivors = append(survivors, n)
		}
	}

	// Wait for a new leader among the two survivors - bounded to a 10s
	// sub-window of the overall 30s recovery budget, matching the
	// observed real election times from
	// TestClusterFailover_KillingLeaderElectsNewRealLeaderAmongSurvivors
	// (~1-10s on this host).
	newPrimary := waitForRealLeaderAmong(t, tc, client, survivors, 10*time.Second)
	if newPrimary == nil {
		t.Fatalf("no new leader was elected among the surviving real processes within 10s of killing the primary %q", primary.nodeID)
	}
	t.Logf("new primary (elected Raft leader) is %q, %s after killing %q", newPrimary.nodeID, time.Since(killTime), primary.nodeID)

	// Query the new primary's real reconstructed KV cache state and
	// assert SC-019's two bounds: <=30s recovery, <=5% token loss.
	newState := replicationState(t, client, newPrimary.apiAddr, token)
	recoveryElapsed := time.Since(killTime)
	if recoveryElapsed > 30*time.Second {
		t.Fatalf("SC-019 violated: recovery took %s (from killing %q to querying the new primary %q's state), want <= 30s", recoveryElapsed, primary.nodeID, newPrimary.nodeID)
	}

	lostTokens := totalTokens - len(newState.Tokens)
	if lostTokens < 0 {
		lostTokens = 0
	}
	lossPct := float64(lostTokens) / float64(totalTokens) * 100
	t.Logf("new primary %q reports %d/%d tokens after failover (%.2f%% loss), recovery took %s", newPrimary.nodeID, len(newState.Tokens), totalTokens, lossPct, recoveryElapsed)

	// Since the "verify durability before destroying" step above already
	// proved EVERY node - including the killed primary and both
	// survivors - held the full 5000-token state BEFORE the kill, a
	// correctly-implemented survivor should show ZERO loss: nothing was
	// lost in a graceful pre-verified state, and there is no
	// architectural reason data already durably persisted in a
	// survivor's own bbolt-backed Store before the kill would vanish
	// when that same survivor is later queried (the survivor's own
	// Store was never touched by killing a DIFFERENT process). Assert
	// the stronger, more meaningful exact-equality claim rather than
	// merely the <=5% tolerance SC-019 permits, and only fall back to
	// the tolerance check as a secondary assertion.
	if len(newState.Tokens) != totalTokens || len(newState.Positions) != totalTokens {
		t.Fatalf("SC-019 violated: new primary %q reports %d tokens / %d positions after failover, want exactly %d/%d (0%% loss - durability was verified for every node, including %q, before the kill)", newPrimary.nodeID, len(newState.Tokens), len(newState.Positions), totalTokens, totalTokens, newPrimary.nodeID)
	}
	for i := range newState.Tokens {
		if newState.Tokens[i] != entries[i].TokenID || newState.Positions[i] != entries[i].Position {
			t.Fatalf("SC-019 violated: new primary %q token/position mismatch at index %d after failover: got (token=%d,pos=%d), want (token=%d,pos=%d)", newPrimary.nodeID, i, newState.Tokens[i], newState.Positions[i], entries[i].TokenID, entries[i].Position)
		}
	}

	if lossPct > 5.0 {
		t.Fatalf("SC-019 violated: %.2f%% token loss exceeds the 5%% bound", lossPct)
	}
}
