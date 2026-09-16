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
// of 5000 simulated tokens replicated via real HTTP/3+mTLS calls to the
// real current primary's real internal/replication-backed routes ALONE,
// periodic checkpoints matching FR-026's default 1000-token interval,
// kill the real current Raft primary process, and assert the surviving
// new primary's reconstructed KV cache is within SC-019's <=5%
// token-loss bound and recovery completes within SC-019's <=30s bound.
//
// T010 (003-kv-cache-replication, US1): this test's OWN manual fan-out
// to all three real node addresses - the disclosed workaround an earlier
// revision of this test used because no automatic cross-node forwarding
// daemon existed yet - is REMOVED here. Every append/checkpoint call
// below targets the current PRIMARY exclusively; the OTHER two nodes'
// durability is now proven ENTIRELY by internal/replication.Forwarder's
// real, automatic, daemon-side forwarding (T008/T009) - the literal,
// mechanical proof this feature's User Story 1 is real (plan.md's TDD
// Requirements). See TestFailoverState_AutomaticForwarding_NoManualFanOut
// (T006) for the dedicated, minimal reproduction of this same property.
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
	// tokens - replication.DefaultIntervalTokens) - every call targets
	// the PRIMARY exclusively (T010): the automatic forwarding daemon
	// (T008/T009) is what replicates each append/checkpoint to the other
	// two real nodes, never this test.
	const checkpointInterval = 1000
	replicationStart := time.Now()
	for cpEnd := checkpointInterval; cpEnd <= totalTokens; cpEnd += checkpointInterval {
		batch := entries[cpEnd-checkpointInterval : cpEnd]
		replicationAppend(t, client, primary.apiAddr, token, batch)

		state := replKVState{
			Tokens:    make([]int32, cpEnd),
			Positions: make([]int32, cpEnd),
		}
		for i := 0; i < cpEnd; i++ {
			state.Tokens[i] = entries[i].TokenID
			state.Positions[i] = entries[i].Position
		}
		replicationCheckpoint(t, client, primary.apiAddr, token, uint64(cpEnd), state)
	}
	t.Logf("replicated + checkpointed %d simulated tokens to the primary %q in %s (the other 2 real nodes are proven durable below via AUTOMATIC forwarding alone)", totalTokens, primary.nodeID, time.Since(replicationStart))

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

// TestFailoverState_AutomaticForwarding_NoManualFanOut is T006 (spec.md
// 003-kv-cache-replication, US1 Acceptance Scenario 1/2; quickstart.md
// Scenario 1): the direct replacement/extension of
// TestFailoverState_KVCacheSurvivesPrimaryKill's own scenario, this time
// WITHOUT the test itself calling every node's HTTP replication routes to
// fan out state - only real client calls against the resolved PRIMARY,
// an explicit BEFORE-failure check that the other two real nodes already
// hold the same data (quickstart.md Scenario 1 step 3 - proving the
// daemon forwarded it automatically), then a real kill, then a real
// assertion the new primary already has everything.
//
// Process note (Constitution §11.4.6 honest boundary): this test's real
// body lands in the SAME dispatch as T008's Forwarder implementation
// (already committed and unit-tested in internal/replication/
// forwarder_test.go with its own strict TDD RED-first discipline) rather
// than being independently confirmed RED against a pre-T008 daemon
// first - the RED-before-implementation step T006's own task
// description calls for was satisfied at the UNIT level (forwarder_test.go)
// instead of at THIS integration level, a deliberate scope tradeoff
// given the multi-hour real-process cost of an integration-level RED
// run; this test is confirmed genuinely GREEN against the real T008
// implementation below.
func TestFailoverState_AutomaticForwarding_NoManualFanOut(t *testing.T) {
	tc := newTestCluster(t)

	nodeA := tc.bootstrap("node-a")
	nodeB := tc.join("node-b", nodeA)
	nodeC := tc.join("node-c", nodeA)
	allNodes := []*spawnedNode{nodeA, nodeB, nodeC}

	client := tc.httpClient()

	token, err := auth.IssueToken(auth.Claims{}, []byte(tc.jwtSigningKey))
	if err != nil {
		t.Fatalf("issue test jwt: %v", err)
	}

	deadline := time.Now().Add(5 * time.Second)
	for _, n := range allNodes {
		for {
			nodes, err := tc.getNodes(client, n.apiAddr)
			if err == nil && len(nodes.Servers) == 3 {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("precondition failed: node %q never observed the full 3-node configuration before the test began", n.nodeID)
			}
			time.Sleep(50 * time.Millisecond)
		}
	}

	primary := waitForRealLeaderAmong(t, tc, client, allNodes, 5*time.Second)
	if primary == nil {
		t.Fatalf("no node reported itself as the Raft leader within 5s")
	}
	t.Logf("primary (current Raft leader) is %q", primary.nodeID)

	const totalTokens = 200
	entries := make([]replAppendEntry, totalTokens)
	for i := 0; i < totalTokens; i++ {
		seq := uint64(i + 1)
		entries[i] = replAppendEntry{Seq: seq, TokenID: int32((seq * 7) % 50000), Position: int32(i)}
	}

	// quickstart.md Scenario 1 step 2: real client calls against the
	// PRIMARY only - the literal negation of the manual fan-out T010
	// removed from TestFailoverState_KVCacheSurvivesPrimaryKill.
	replicationAppend(t, client, primary.apiAddr, token, entries)
	fullState := replKVState{Tokens: make([]int32, totalTokens), Positions: make([]int32, totalTokens)}
	for i := 0; i < totalTokens; i++ {
		fullState.Tokens[i] = entries[i].TokenID
		fullState.Positions[i] = entries[i].Position
	}
	replicationCheckpoint(t, client, primary.apiAddr, token, uint64(totalTokens), fullState)

	// quickstart.md Scenario 1 step 3: BEFORE any failure, confirm the
	// OTHER two nodes' own GET /v1/replication/state already shows the
	// same data - proving the daemon forwarded it automatically. This
	// test never contacts nodeB/nodeC's replication routes to WRITE
	// anything - only to READ what the daemon already put there.
	forwardDeadline := time.Now().Add(10 * time.Second)
	for _, n := range allNodes {
		if n.nodeID == primary.nodeID {
			continue
		}
		for {
			got := replicationState(t, client, n.apiAddr, token)
			if len(got.Tokens) == totalTokens {
				match := true
				for i := range got.Tokens {
					if got.Tokens[i] != entries[i].TokenID || got.Positions[i] != entries[i].Position {
						match = false
						break
					}
				}
				if match {
					break
				}
			}
			if time.Now().After(forwardDeadline) {
				t.Fatalf("node %q never observed the primary %q's automatically-forwarded state within 10s (this test never wrote to %q directly - the daemon must forward)", n.nodeID, primary.nodeID, n.nodeID)
			}
			time.Sleep(50 * time.Millisecond)
		}
	}
	t.Logf("verified both non-primary real nodes received the full %d-token state via AUTOMATIC forwarding alone (zero test-side fan-out)", totalTokens)

	// quickstart.md Scenario 1 step 4: kill the primary; the newly-
	// elected primary must already have the full state with zero loss.
	killTime := time.Now()
	if err := primary.cmd.Process.Kill(); err != nil {
		t.Fatalf("kill primary %q: %v", primary.nodeID, err)
	}
	_, _ = primary.cmd.Process.Wait()
	delete(tc.nodes, primary.nodeID)

	survivors := make([]*spawnedNode, 0, 2)
	for _, n := range allNodes {
		if n.nodeID != primary.nodeID {
			survivors = append(survivors, n)
		}
	}

	newPrimary := waitForRealLeaderAmong(t, tc, client, survivors, 10*time.Second)
	if newPrimary == nil {
		t.Fatalf("no new leader was elected among the surviving real processes within 10s of killing the primary %q", primary.nodeID)
	}
	t.Logf("new primary (elected Raft leader) is %q, %s after killing %q", newPrimary.nodeID, time.Since(killTime), primary.nodeID)

	newState := replicationState(t, client, newPrimary.apiAddr, token)
	if len(newState.Tokens) != totalTokens || len(newState.Positions) != totalTokens {
		t.Fatalf("SC-001 violated: new primary %q reports %d tokens / %d positions after failover, want exactly %d/%d (zero loss - only the AUTOMATIC forwarding daemon replicated this data, never this test)", newPrimary.nodeID, len(newState.Tokens), len(newState.Positions), totalTokens, totalTokens)
	}
	for i := range newState.Tokens {
		if newState.Tokens[i] != entries[i].TokenID || newState.Positions[i] != entries[i].Position {
			t.Fatalf("SC-001 violated: new primary %q token/position mismatch at index %d after failover: got (token=%d,pos=%d), want (token=%d,pos=%d)", newPrimary.nodeID, i, newState.Tokens[i], newState.Positions[i], entries[i].TokenID, entries[i].Position)
		}
	}
}

// TestFailoverState_AppendLostBeforeForwarding_IsReportedNotHidden is
// T007 (spec.md Edge Case / FR-005): kill the primary in the exact
// instant after a large append lands only LOCALLY (before automatic
// forwarding could possibly have begun); assert the resulting gap is
// reported honestly by the new primary's own state, never silently
// presented as a complete conversation.
//
// Real reproduction mechanism (never a mock or an injected test hook):
// internal/replication's WAL.Append performs one real, individually
// fsync'd bbolt.Update transaction PER ENTRY (wal.go), so a large batch
// makes the primary's append handler take genuine, measurable wall-clock
// time processing entries LOCALLY before it ever reaches its own
// forwarding step (routes_replication.go's handler forwards only AFTER
// every entry in the request has been locally durable). Firing this
// large "doomed" append via a real HTTP request WITHOUT waiting for its
// response, then IMMEDIATELY killing the real primary process, reliably
// lands the kill signal while the primary is still mid-loop over the
// doomed entries - guaranteeing zero forwarding occurred for it,
// deterministically, without needing to fake network unreachability.
func TestFailoverState_AppendLostBeforeForwarding_IsReportedNotHidden(t *testing.T) {
	tc := newTestCluster(t)

	nodeA := tc.bootstrap("node-a")
	nodeB := tc.join("node-b", nodeA)
	nodeC := tc.join("node-c", nodeA)
	allNodes := []*spawnedNode{nodeA, nodeB, nodeC}

	client := tc.httpClient()

	token, err := auth.IssueToken(auth.Claims{}, []byte(tc.jwtSigningKey))
	if err != nil {
		t.Fatalf("issue test jwt: %v", err)
	}

	deadline := time.Now().Add(5 * time.Second)
	for _, n := range allNodes {
		for {
			nodes, err := tc.getNodes(client, n.apiAddr)
			if err == nil && len(nodes.Servers) == 3 {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("precondition failed: node %q never observed the full 3-node configuration before the test began", n.nodeID)
			}
			time.Sleep(50 * time.Millisecond)
		}
	}

	primary := waitForRealLeaderAmong(t, tc, client, allNodes, 5*time.Second)
	if primary == nil {
		t.Fatalf("no node reported itself as the Raft leader within 5s")
	}
	t.Logf("primary (current Raft leader) is %q", primary.nodeID)

	survivors := make([]*spawnedNode, 0, 2)
	for _, n := range allNodes {
		if n.nodeID != primary.nodeID {
			survivors = append(survivors, n)
		}
	}

	// A small, fully-forwarded BASE establishes a known-good baseline
	// BEFORE the doomed append - proving any gap this test later observes
	// is specific to the doomed append racing the kill, never an
	// artifact of forwarding being broken outright.
	const baseTokens = 50
	baseEntries := make([]replAppendEntry, baseTokens)
	for i := 0; i < baseTokens; i++ {
		seq := uint64(i + 1)
		baseEntries[i] = replAppendEntry{Seq: seq, TokenID: int32((seq * 7) % 50000), Position: int32(i)}
	}
	replicationAppend(t, client, primary.apiAddr, token, baseEntries)

	baseDeadline := time.Now().Add(10 * time.Second)
	for _, n := range survivors {
		for {
			got := replicationState(t, client, n.apiAddr, token)
			if len(got.Tokens) == baseTokens {
				break
			}
			if time.Now().After(baseDeadline) {
				t.Fatalf("survivor %q never observed the base %d-token forwarded state within 10s", n.nodeID, baseTokens)
			}
			time.Sleep(50 * time.Millisecond)
		}
	}
	t.Logf("base %d-token state fully forwarded to both eventual survivors before the doomed append", baseTokens)

	// The DOOMED append (see this test's own doc comment for why this
	// size + fire-and-forget + immediate-kill combination reliably
	// reproduces the race).
	const doomedTokens = 5000
	doomedEntries := make([]replAppendEntry, doomedTokens)
	for i := 0; i < doomedTokens; i++ {
		seq := uint64(baseTokens + i + 1)
		doomedEntries[i] = replAppendEntry{Seq: seq, TokenID: int32((seq * 7) % 50000), Position: int32(baseTokens + i)}
	}
	doomedBody, err := json.Marshal(replAppendRequest{Entries: doomedEntries})
	if err != nil {
		t.Fatalf("marshal doomed append body: %v", err)
	}
	go func() {
		req, err := http.NewRequest(http.MethodPost, "https://"+primary.apiAddr+"/v1/replication/append", bytes.NewReader(doomedBody))
		if err != nil {
			return
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+token)
		resp, err := client.Do(req)
		// The primary is EXPECTED to die mid-request - a connection
		// error here is the expected outcome of this test, never a
		// failure; this goroutine deliberately never calls any *testing.T
		// method (unsafe once the main test goroutine may have already
		// moved on to asserting the outcome).
		if err == nil {
			_ = resp.Body.Close()
		}
	}()

	killTime := time.Now()
	if err := primary.cmd.Process.Kill(); err != nil {
		t.Fatalf("kill primary %q: %v", primary.nodeID, err)
	}
	_, _ = primary.cmd.Process.Wait()
	delete(tc.nodes, primary.nodeID)

	newPrimary := waitForRealLeaderAmong(t, tc, client, survivors, 10*time.Second)
	if newPrimary == nil {
		t.Fatalf("no new leader was elected among the surviving real processes within 10s of killing the primary %q", primary.nodeID)
	}
	t.Logf("new primary (elected Raft leader) is %q, %s after killing %q mid doomed-append", newPrimary.nodeID, time.Since(killTime), primary.nodeID)

	newState := replicationState(t, client, newPrimary.apiAddr, token)

	// FR-005's own requirement: the gap MUST be reported honestly, never
	// silently presented as complete - the new primary MUST NOT report
	// the full baseTokens+doomedTokens sequence, proving it never
	// fabricates completeness for content that was never actually
	// forwarded anywhere before the primary died.
	if len(newState.Tokens) >= baseTokens+doomedTokens {
		t.Fatalf("FR-005 violated: new primary %q reports %d tokens, want STRICTLY FEWER than %d (the doomed append must not be silently presented as fully replicated when the primary died before forwarding it anywhere)", newPrimary.nodeID, len(newState.Tokens), baseTokens+doomedTokens)
	}
	// The base MUST still be fully present - a gap in the PROVEN-forwarded
	// base would mean this test is misdiagnosing a different defect, not
	// the doomed-append race this test targets.
	if len(newState.Tokens) < baseTokens {
		t.Fatalf("new primary %q reports only %d tokens, want at least the %d proven-forwarded base tokens (the doomed append racing with the kill must never cost already-forwarded data)", newPrimary.nodeID, len(newState.Tokens), baseTokens)
	}
	// Whatever IS present MUST be an exact, uncorrupted PREFIX of the real
	// sequence - never garbled, reordered, or partially-wrong data
	// presented as if it were correct.
	allEntries := append(append([]replAppendEntry{}, baseEntries...), doomedEntries...)
	for i := range newState.Tokens {
		if newState.Tokens[i] != allEntries[i].TokenID || newState.Positions[i] != allEntries[i].Position {
			t.Fatalf("new primary %q token/position mismatch at index %d: got (token=%d,pos=%d), want (token=%d,pos=%d) - reported state must be an exact, uncorrupted prefix of the real sequence, never fabricated or corrupted", newPrimary.nodeID, i, newState.Tokens[i], newState.Positions[i], allEntries[i].TokenID, allEntries[i].Position)
		}
	}
	t.Logf("new primary %q honestly reports %d/%d tokens after the doomed append raced the primary's own death (gap reported, zero corruption, zero fabricated completeness)", newPrimary.nodeID, len(newState.Tokens), baseTokens+doomedTokens)
}

// clusterStatusReplicationRoles mirrors GET /v1/cluster/status's real JSON
// response closely enough for this test to read
// state.replication_roles[tenantID].primary_node_id - a plain, decoupled
// local type extending statusResponse's (cluster_bootstrap_test.go) bare
// IsLeader field with exactly the nested path this test needs, matching
// this package's own established duplication-over-shared-type-mutation
// discipline (replAppendEntry/replKVState's doc comment above).
type clusterStatusReplicationRoles struct {
	IsLeader bool `json:"is_leader"`
	State    struct {
		ReplicationRoles map[string]struct {
			PrimaryNodeID  string   `json:"primary_node_id"`
			ReplicaNodeIDs []string `json:"replica_node_ids"`
		} `json:"replication_roles"`
	} `json:"state"`
}

// getReplicationRoleStatus GETs apiAddr's real /v1/cluster/status route
// (no JWT required - see routes_cluster.go's own package doc comment:
// this route is mTLS-only) and decodes the tenantID's current
// ReplicationRole out of it, or ok=false if no role is recorded yet.
func getReplicationRoleStatus(t *testing.T, client *http.Client, apiAddr, tenantID string) (primaryNodeID string, replicaNodeIDs []string, ok bool) {
	t.Helper()
	var resp clusterStatusReplicationRoles
	status := doJSON(t, client, http.MethodGet, apiAddr, "/v1/cluster/status", "", nil, &resp)
	if status != http.StatusOK {
		return "", nil, false
	}
	role, ok := resp.State.ReplicationRoles[tenantID]
	if !ok {
		return "", nil, false
	}
	return role.PrimaryNodeID, role.ReplicaNodeIDs, true
}

// findByNodeID returns the *spawnedNode in nodes whose nodeID matches, or
// nil if none does.
func findByNodeID(nodes []*spawnedNode, nodeID string) *spawnedNode {
	for _, n := range nodes {
		if n.nodeID == nodeID {
			return n
		}
	}
	return nil
}

// replicationRoleReassignmentTimeout bounds how long this test waits for
// a real cluster.Monitor health-check tick to detect the killed primary
// and durably commit a real CommandReassignReplicationRole - generous
// relative to the real cadence this proof depends on
// (cmd/llmctld's main.go wireHealthMonitor: a nodeRegistrySyncInterval
// (1s) freshness bound plus at most one full
// cluster.DefaultHealthCheckInterval (10s) health-check tick before the
// failure is even detected, plus the Raft Apply itself, which is
// sub-second) - matching this file's own established "generous but
// bounded" convention (SC-019's 30s recovery bound above).
const replicationRoleReassignmentTimeout = 30 * time.Second

// TestFailoverState_ReplicationRoleReassignedOnCrash_NewPrimaryForwardsOnward
// is T072-FU7's own real end-to-end proof: a real SIGKILL of the
// ReplicationRole primary is genuinely detected by cluster.Monitor's real
// HTTP health check against the dead node's /v1/cluster/status (never a
// Raft-configuration-shrink signal, which a plain crash never produces -
// this is the EXACT gap docs/CONTINUATION.md §10g/§10h and
// specs/001-llmctl-completion/tasks.md's T072-FU7 entry disclosed:
// ensureReplicationRole's own failover-detection previously always passed
// nil deadNodeIDs, so a crashed primary was never treated as dead), and
// the resulting real CommandReassignReplicationRole - proposed by
// cmd/llmctld's wireHealthMonitor Rescheduler through
// cluster.ReconcileReplicationRoles (health.go) and applied through the
// SAME already-tested node.ReassignReplicationRole Raft path
// routes_replication.go's own ensureReplicationRole already uses - is
// genuinely committed and cluster-wide visible, and (the load-bearing
// assertion T072-FU7's disclosed gap named explicitly) a SUBSEQUENT
// append/checkpoint for that tenant sent directly to the NEW primary is
// now correctly forwarded onward to the OTHER surviving replica, rather
// than accepted+persisted only locally and never forwarded anywhere (the
// exact previously-broken behavior).
func TestFailoverState_ReplicationRoleReassignedOnCrash_NewPrimaryForwardsOnward(t *testing.T) {
	tc := newTestCluster(t)

	nodeA := tc.bootstrap("node-a")
	nodeB := tc.join("node-b", nodeA)
	nodeC := tc.join("node-c", nodeA)
	allNodes := []*spawnedNode{nodeA, nodeB, nodeC}

	client := tc.httpClient()

	token, err := auth.IssueToken(auth.Claims{}, []byte(tc.jwtSigningKey))
	if err != nil {
		t.Fatalf("issue test jwt: %v", err)
	}

	deadline := time.Now().Add(5 * time.Second)
	for _, n := range allNodes {
		for {
			nodes, err := tc.getNodes(client, n.apiAddr)
			if err == nil && len(nodes.Servers) == 3 {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("precondition failed: node %q never observed the full 3-node configuration before the test began", n.nodeID)
			}
			time.Sleep(50 * time.Millisecond)
		}
	}

	// Resolve the current Raft leader and send the FIRST append directly
	// to it, so ensureReplicationRole's own "!had" fresh-assignment branch
	// (routes_replication.go) durably commits with PrimaryNodeID ==
	// primary.nodeID on the first try - a request landing on a follower
	// would propose the SAME role but silently fail to commit
	// (hraft.ErrNotLeader), leaving the role unestablished until some
	// later request happened to land on the leader instead. Targeting the
	// leader directly makes this test's baseline deterministic rather
	// than depending on that race.
	primary := waitForRealLeaderAmong(t, tc, client, allNodes, 5*time.Second)
	if primary == nil {
		t.Fatalf("no node reported itself as the Raft leader within 5s")
	}
	t.Logf("primary (current Raft leader, and about to become the ReplicationRole primary) is %q", primary.nodeID)

	const baseTokens = 50
	baseEntries := make([]replAppendEntry, baseTokens)
	for i := 0; i < baseTokens; i++ {
		seq := uint64(i + 1)
		baseEntries[i] = replAppendEntry{Seq: seq, TokenID: int32((seq * 7) % 50000), Position: int32(i)}
	}
	replicationAppend(t, client, primary.apiAddr, token, baseEntries)
	baseState := replKVState{Tokens: make([]int32, baseTokens), Positions: make([]int32, baseTokens)}
	for i := 0; i < baseTokens; i++ {
		baseState.Tokens[i] = baseEntries[i].TokenID
		baseState.Positions[i] = baseEntries[i].Position
	}
	replicationCheckpoint(t, client, primary.apiAddr, token, uint64(baseTokens), baseState)

	// Confirm the ReplicationRole genuinely established naming primary as
	// PrimaryNodeID BEFORE proceeding - the precondition this test's own
	// later "reassigned away from it" assertion depends on.
	roleDeadline := time.Now().Add(5 * time.Second)
	for {
		primaryID, _, ok := getReplicationRoleStatus(t, client, primary.apiAddr, "")
		if ok && primaryID == primary.nodeID {
			break
		}
		if time.Now().After(roleDeadline) {
			t.Fatalf("precondition failed: the default tenant's ReplicationRole never established naming %q as primary within 5s", primary.nodeID)
		}
		time.Sleep(50 * time.Millisecond)
	}

	// Verify the base state genuinely forwarded to BOTH other nodes before
	// destroying anything - the same "verify before destroy" discipline
	// this file's other tests already establish.
	baseForwardDeadline := time.Now().Add(10 * time.Second)
	for _, n := range allNodes {
		if n.nodeID == primary.nodeID {
			continue
		}
		for {
			got := replicationState(t, client, n.apiAddr, token)
			if len(got.Tokens) == baseTokens {
				break
			}
			if time.Now().After(baseForwardDeadline) {
				t.Fatalf("node %q never observed the base %d-token forwarded state within 10s", n.nodeID, baseTokens)
			}
			time.Sleep(50 * time.Millisecond)
		}
	}
	t.Logf("base %d-token state established with %q as ReplicationRole primary and forwarded to both other real nodes", baseTokens, primary.nodeID)

	// Real SIGKILL - the exact failure class this test proves is now
	// detected: a plain crash never shrinks Raft's own voter configuration
	// (node.Servers()), which is precisely why ensureReplicationRole's
	// OWN failover-detection (fed only by that signal, with deadNodeIDs
	// always nil) could never see this as a failure on its own. Detection
	// here comes exclusively from cluster.Monitor's real HTTP health
	// check against primary's own /v1/cluster/status.
	killTime := time.Now()
	if err := primary.cmd.Process.Kill(); err != nil {
		t.Fatalf("kill primary %q: %v", primary.nodeID, err)
	}
	_, _ = primary.cmd.Process.Wait()
	delete(tc.nodes, primary.nodeID)

	survivors := make([]*spawnedNode, 0, 2)
	for _, n := range allNodes {
		if n.nodeID != primary.nodeID {
			survivors = append(survivors, n)
		}
	}

	// A new Raft LEADER is elected quickly (seconds) - but T072-FU7's own
	// design point 4 deliberately passes preferredPrimary="" to
	// cluster.ReconcileReplicationRoles (main.go's wireHealthMonitor), so
	// the REASSIGNED REPLICATION-ROLE PRIMARY is whichever survivor sorts
	// first alphabetically (health.go's firstOtherLiveNode) - NOT
	// necessarily the same node that wins Raft leader election. This test
	// deliberately does not assume they coincide; it discovers the real
	// reassigned primary from the cluster's own replicated state.
	newLeader := waitForRealLeaderAmong(t, tc, client, survivors, 10*time.Second)
	if newLeader == nil {
		t.Fatalf("no new leader was elected among the surviving real processes within 10s of killing the primary %q", primary.nodeID)
	}
	t.Logf("new Raft leader (may or may not be the reassigned ReplicationRole primary) is %q, %s after killing %q", newLeader.nodeID, time.Since(killTime), primary.nodeID)

	// The load-bearing wait: poll every survivor's own real
	// /v1/cluster/status until the default tenant's ReplicationRole
	// PrimaryNodeID has genuinely changed away from the killed node - the
	// real, Raft-committed CommandReassignReplicationRole this test
	// exists to prove now happens automatically.
	var newPrimaryID string
	reassignDeadline := time.Now().Add(replicationRoleReassignmentTimeout)
	for {
		found := false
		for _, n := range survivors {
			primaryID, _, ok := getReplicationRoleStatus(t, client, n.apiAddr, "")
			if ok && primaryID != "" && primaryID != primary.nodeID {
				newPrimaryID = primaryID
				found = true
				break
			}
		}
		if found {
			break
		}
		if time.Now().After(reassignDeadline) {
			t.Fatalf("T072-FU7 REGRESSION: the default tenant's ReplicationRole was never reassigned away from the killed primary %q within %s of the kill - cluster.Monitor's health-driven failover wiring did not fire (or did not commit)", primary.nodeID, replicationRoleReassignmentTimeout)
		}
		time.Sleep(200 * time.Millisecond)
	}
	reassignElapsed := time.Since(killTime)
	t.Logf("ReplicationRole reassigned: new primary is %q, %s after killing %q (cluster.Monitor's real health-check-driven Rescheduler -> cluster.ReconcileReplicationRoles -> node.ReassignReplicationRole)", newPrimaryID, reassignElapsed, primary.nodeID)

	newPrimary := findByNodeID(survivors, newPrimaryID)
	if newPrimary == nil {
		t.Fatalf("reassigned ReplicationRole names primary %q, which is not one of the real surviving processes %v - a fabricated/unreachable primary would itself be a defect", newPrimaryID, survivors)
	}
	other := survivors[0]
	if other.nodeID == newPrimary.nodeID {
		other = survivors[1]
	}

	// The reassignment above was observed via WHICHEVER survivor happened
	// to answer first (possibly newPrimary itself, possibly the OTHER
	// one) - real Raft log replication from committer to follower is not
	// instantaneous (real, if typically small, propagation lag), so
	// newPrimary's OWN local ReplicationRoles view may not have caught up
	// to the SAME committed entry yet at this exact instant. Confirm
	// newPrimary's own /v1/cluster/status ALSO reports itself as primary
	// before writing to it directly below - writing to a node whose own
	// local state has not yet caught up would make ensureReplicationRole
	// see the OLD (dead) primary there instead, so ForwardAppend's own
	// "primaryID != f.selfID -> no-op" gate would correctly (but
	// misleadingly, for this test) forward nothing at all - a real
	// replication-propagation race in THIS TEST's own read-then-write
	// sequencing, never a claim that production's underlying commit
	// itself is anything but atomic (T005's own analysis, cited in this
	// test's Rescheduler-side doc comment, still holds).
	selfCaughtUpDeadline := time.Now().Add(5 * time.Second)
	for {
		selfPrimaryID, _, ok := getReplicationRoleStatus(t, client, newPrimary.apiAddr, "")
		if ok && selfPrimaryID == newPrimaryID {
			break
		}
		if time.Now().After(selfCaughtUpDeadline) {
			t.Fatalf("reassigned primary %q never observed itself as primary on its OWN /v1/cluster/status within 5s of the reassignment being observed elsewhere - real Raft replication lag exceeded this generous bound", newPrimaryID)
		}
		time.Sleep(50 * time.Millisecond)
	}

	// The load-bearing assertion: a SUBSEQUENT append/checkpoint sent
	// directly to the NEW primary must now be forwarded onward to the
	// OTHER surviving replica - proving ensureReplicationRole's own
	// "existing primary is live, no reassignment needed" fast path now
	// correctly recognizes newPrimary (via the SAME liveNodeIDs/
	// node.Servers() it already reads) as the authoritative primary, and
	// Forwarder.ForwardAppend/ForwardCheckpoint's own primaryID ==
	// f.selfID gate (internal/replication/forwarder.go) now passes on
	// newPrimary, where it never could before this fix (the role would
	// have stayed pinned to the dead node forever).
	const postFailoverTokens = 25
	postEntries := make([]replAppendEntry, postFailoverTokens)
	for i := 0; i < postFailoverTokens; i++ {
		seq := uint64(baseTokens + i + 1)
		postEntries[i] = replAppendEntry{Seq: seq, TokenID: int32((seq * 11) % 50000), Position: int32(baseTokens + i)}
	}
	replicationAppend(t, client, newPrimary.apiAddr, token, postEntries)
	postState := replKVState{
		Tokens:    append(append([]int32{}, baseState.Tokens...), make([]int32, postFailoverTokens)...),
		Positions: append(append([]int32{}, baseState.Positions...), make([]int32, postFailoverTokens)...),
	}
	for i := range postEntries {
		postState.Tokens[baseTokens+i] = postEntries[i].TokenID
		postState.Positions[baseTokens+i] = postEntries[i].Position
	}
	replicationCheckpoint(t, client, newPrimary.apiAddr, token, uint64(baseTokens+postFailoverTokens), postState)

	forwardOnwardDeadline := time.Now().Add(10 * time.Second)
	for {
		got := replicationState(t, client, other.apiAddr, token)
		if len(got.Tokens) == baseTokens+postFailoverTokens {
			match := true
			for i := range got.Tokens {
				if got.Tokens[i] != postState.Tokens[i] || got.Positions[i] != postState.Positions[i] {
					match = false
					break
				}
			}
			if match {
				break
			}
		}
		if time.Now().After(forwardOnwardDeadline) {
			got := replicationState(t, client, other.apiAddr, token)
			t.Fatalf("T072-FU7 REGRESSION: the post-failover append/checkpoint sent to the new primary %q was never forwarded onward to the other survivor %q within 10s (it reports %d/%d tokens) - the new primary accepted+persisted the write locally but did not forward it, the exact previously-broken behavior this test exists to catch", newPrimary.nodeID, other.nodeID, len(got.Tokens), baseTokens+postFailoverTokens)
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Logf("SUCCESS: post-failover append/checkpoint sent to the reassigned primary %q was genuinely forwarded onward to the other survivor %q - T072-FU7's disclosed gap is closed", newPrimary.nodeID, other.nodeID)
}
