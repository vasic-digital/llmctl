// Package integration (replication_health_test.go): T020
// (003-kv-cache-replication, User Story 3; quickstart.md Scenario 2 +
// Scenario 4 combined) - the real 3-node proof that GET
// /v1/replication/lag (T019) genuinely reflects real forwarding-
// acknowledgment traffic (T008/T018): every replica shows zero lag while
// fully caught up, a genuinely-blocked replica shows a real, non-zero
// lag naming exactly which replica is behind, and lag returns to zero
// once that replica is caught back up.
//
// Reuses cluster_bootstrap_test.go's testCluster harness and
// failover_state_test.go's replAppendEntry/replKVState/replicationAppend/
// replicationCheckpoint/replicationState/waitForRealLeaderAmong helpers
// in this same package - no new spawn machinery is needed.
package integration

import (
	"encoding/json"
	"io"
	"net/http"
	"syscall"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
)

// replLagRecord/replLagResponse mirror
// internal/api/routes_replication.go's lagRecordJSON/lagResponse JSON
// wire shapes field-for-field - duplicated here as plain, decoupled
// local types, matching this package's own replAppendEntry/replKVState
// precedent (failover_state_test.go's doc comment) rather than importing
// internal/api's unexported types.
type replLagRecord struct {
	ReplicaNodeID    string `json:"replica_node_id"`
	LastConfirmedSeq uint64 `json:"last_confirmed_seq"`
	PrimarySeq       uint64 `json:"primary_seq"`
	Lag              uint64 `json:"lag"`
}

type replLagResponse struct {
	TenantID string          `json:"tenant_id"`
	Replicas []replLagRecord `json:"replicas"`
}

// replicationLag GETs apiAddr's real /v1/replication/lag route (T019),
// bearing token (see replicationAppend's doc comment in
// failover_state_test.go for why a token is required - every
// /v1/replication/* route requires a valid JWT since T072-FU5).
func replicationLag(t *testing.T, client *http.Client, apiAddr, token string) replLagResponse {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, "https://"+apiAddr+"/v1/replication/lag", nil)
	if err != nil {
		t.Fatalf("new lag request to %s: %v", apiAddr, err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("GET /v1/replication/lag from %s: %v", apiAddr, err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("GET /v1/replication/lag from %s: status = %d, body = %s", apiAddr, resp.StatusCode, body)
	}
	var got replLagResponse
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatalf("decode /v1/replication/lag response from %s: %v", apiAddr, err)
	}
	return got
}

// lagFor returns replicaID's record from resp, or ok=false if resp has
// no entry for it yet.
func lagFor(resp replLagResponse, replicaID string) (replLagRecord, bool) {
	for _, rec := range resp.Replicas {
		if rec.ReplicaNodeID == replicaID {
			return rec, true
		}
	}
	return replLagRecord{}, false
}

// TestReplicationHealth_LagVisibleThenClearsOnRecovery is T020
// (quickstart.md Scenario 2 + Scenario 4 combined, User Story 3, SC-002/
// SC-005): block one real replica's network reachability by PAUSING its
// real OS process (a real SIGSTOP, never a mock) - SIGSTOP leaves the
// replica's real QUIC/UDP socket bound but unable to service any packet
// until resumed, reproducing "the replica is unreachable" from a
// caller's perspective exactly as a real network partition would, while
// remaining cleanly reversible via SIGCONT (unlike killing the process,
// which Scenario 2 step 4's "restore reachability" explicitly requires
// NOT doing - a killed process cannot be un-killed). Append further data
// on the primary while the replica is paused, confirm the new GET
// /v1/replication/lag route (T019) shows the paused replica genuinely
// behind while naming the OTHER, never-paused replica as fully caught
// up, then resume the paused replica and confirm both its own real
// state and its reported lag genuinely recover.
//
// Honest mechanism note (Constitution §11.4.6): forwarder.go's own
// package doc comment establishes there is no background retry/resync
// queue - a forward attempt that fails during the paused window is never
// automatically resent later. The real, in-band mechanism this codebase
// already ships for a resumed replica to genuinely catch up is a FRESH
// CHECKPOINT (checkpoint.go's Store.Checkpoint persists the FULL
// KVState as of its Seq, unlike an append's incremental entries) -
// exactly matching FR-026's own periodic full-resync design and
// TestFailoverState_KVCacheSurvivesPrimaryKill's established checkpoint
// cadence. This test issues that fresh checkpoint after SIGCONT and
// verifies BOTH the resumed replica's own real reconstructed state
// (never merely its reported lag figure) and its lag genuinely reach
// zero - proving the recovery is real, not merely reported (SC-005).
func TestReplicationHealth_LagVisibleThenClearsOnRecovery(t *testing.T) {
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
	blocked, other := survivors[0], survivors[1]
	t.Logf("blocked replica will be %q; other (never-blocked) replica is %q", blocked.nodeID, other.nodeID)

	// A small BASE, fully forwarded to BOTH replicas before anything is
	// blocked - the precondition for Scenario 4 step 1 ("every replica is
	// fully caught up").
	const baseTokens = 20
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
	t.Logf("base %d-token state fully forwarded to both survivors", baseTokens)

	// Scenario 4 step 1: query replication health while every replica is
	// caught up - assert zero lag for BOTH survivors.
	zeroLagDeadline := time.Now().Add(10 * time.Second)
	for {
		lag := replicationLag(t, client, primary.apiAddr, token)
		blockedRec, blockedOK := lagFor(lag, blocked.nodeID)
		otherRec, otherOK := lagFor(lag, other.nodeID)
		if blockedOK && otherOK && blockedRec.Lag == 0 && otherRec.Lag == 0 {
			t.Logf("SC-002: every replica reports zero lag while genuinely caught up: %+v", lag)
			break
		}
		if time.Now().After(zeroLagDeadline) {
			t.Fatalf("replication health never reported zero lag for both replicas after the base append within 10s: %+v", lag)
		}
		time.Sleep(50 * time.Millisecond)
	}

	// Scenario 2 step 1: block network reachability to ONE replica - a
	// real SIGSTOP against its real OS process (see this test's own doc
	// comment).
	if err := blocked.cmd.Process.Signal(syscall.SIGSTOP); err != nil {
		t.Fatalf("SIGSTOP the blocked replica %q: %v", blocked.nodeID, err)
	}
	resumed := false
	defer func() {
		if !resumed {
			_ = blocked.cmd.Process.Signal(syscall.SIGCONT)
		}
	}()

	// Scenario 2 step 2: append further data on the primary. The
	// forward attempt to the paused replica will genuinely fail
	// (bounded, per FR-004 - see forwarder.go's own retry-budget
	// constants), while the forward to the OTHER, never-paused replica
	// succeeds normally. routes_replication.go's handler calls
	// forwarder.ForwardAppend SYNCHRONOUSLY before responding, so THIS
	// call's own response is genuinely delayed by however long the
	// doomed forward attempt to the paused replica takes - up to
	// cmd/llmctld's own real forwardClientRequestTimeout (10s) PLUS the
	// paused replica's un-drained TCP/QUIC handshake wait, per a single
	// failed httpClient.Do() call already exceeding forwarder.go's own
	// 2s retry budget on its first attempt. tc.httpClient()'s default 5s
	// Timeout is too short to observe this call succeed - a dedicated,
	// longer-timeout client (sharing the SAME real mTLS transport) is
	// used for this ONE call only, so THIS test's own client never times
	// out before the primary's real, bounded (never indefinite, FR-004)
	// internal retry genuinely completes.
	longClient := &http.Client{Transport: client.Transport, Timeout: 30 * time.Second}
	const extraTokens = 5
	extraEntries := make([]replAppendEntry, extraTokens)
	for i := 0; i < extraTokens; i++ {
		seq := uint64(baseTokens + i + 1)
		extraEntries[i] = replAppendEntry{Seq: seq, TokenID: int32((seq * 7) % 50000), Position: int32(baseTokens + i)}
	}
	appendStart := time.Now()
	replicationAppend(t, longClient, primary.apiAddr, token, extraEntries)
	t.Logf("append with one paused replica took %s (expected to be slower than normal - the paused replica's forward attempt must genuinely fail before this call returns)", time.Since(appendStart))

	// Scenario 2 step 3 / Scenario 4 step 2: query replication-lag -
	// assert the blocked replica shows a real, non-zero lag while the
	// OTHER replica still shows zero, naming EXACTLY which replica is
	// behind and by how much (spec.md Acceptance Scenario 2).
	blockedLagDeadline := time.Now().Add(20 * time.Second)
	var lastLag replLagResponse
	for {
		lastLag = replicationLag(t, client, primary.apiAddr, token)
		blockedRec, blockedOK := lagFor(lastLag, blocked.nodeID)
		otherRec, otherOK := lagFor(lastLag, other.nodeID)
		if blockedOK && otherOK && blockedRec.Lag > 0 && otherRec.Lag == 0 {
			t.Logf("SC-002/SC-005: blocked replica %q shows real lag=%d (primary_seq=%d, last_confirmed_seq=%d) while %q shows zero: %+v",
				blocked.nodeID, blockedRec.Lag, blockedRec.PrimarySeq, blockedRec.LastConfirmedSeq, other.nodeID, lastLag)
			break
		}
		if time.Now().After(blockedLagDeadline) {
			t.Fatalf("replication-lag never showed the blocked replica %q behind while %q stayed caught up within 20s: %+v", blocked.nodeID, other.nodeID, lastLag)
		}
		time.Sleep(100 * time.Millisecond)
	}

	// The non-blocked replica's OWN real state must show the extra data
	// too - not merely its reported lag - proving the extra append
	// genuinely reached it (never silently dropped for an unrelated
	// replica just because a DIFFERENT replica was blocked).
	otherState := replicationState(t, client, other.apiAddr, token)
	if len(otherState.Tokens) != baseTokens+extraTokens {
		t.Fatalf("non-blocked replica %q reports %d tokens, want %d (extra data must still reach an unblocked replica while another is paused)", other.nodeID, len(otherState.Tokens), baseTokens+extraTokens)
	}

	// Scenario 2 step 4: restore reachability.
	if err := blocked.cmd.Process.Signal(syscall.SIGCONT); err != nil {
		t.Fatalf("SIGCONT the blocked replica %q: %v", blocked.nodeID, err)
	}
	resumed = true

	// A fresh checkpoint carrying the FULL, correct state re-syncs the
	// resumed replica for real (see this test's own doc comment for why
	// a checkpoint, not another append, is the honest recovery
	// mechanism this codebase already ships).
	fullState := replKVState{Tokens: make([]int32, baseTokens+extraTokens), Positions: make([]int32, baseTokens+extraTokens)}
	allEntries := append(append([]replAppendEntry{}, baseEntries...), extraEntries...)
	for i, e := range allEntries {
		fullState.Tokens[i] = e.TokenID
		fullState.Positions[i] = e.Position
	}
	replicationCheckpoint(t, client, primary.apiAddr, token, uint64(baseTokens+extraTokens), fullState)

	// The resumed replica's OWN real reconstructed state must genuinely
	// catch up - the actual durable proof behind the lag figure, never
	// merely trusting the reported number.
	catchUpDeadline := time.Now().Add(15 * time.Second)
	for {
		got := replicationState(t, client, blocked.apiAddr, token)
		if len(got.Tokens) == baseTokens+extraTokens {
			match := true
			for i := range got.Tokens {
				if got.Tokens[i] != allEntries[i].TokenID || got.Positions[i] != allEntries[i].Position {
					match = false
					break
				}
			}
			if match {
				break
			}
		}
		if time.Now().After(catchUpDeadline) {
			t.Fatalf("resumed replica %q never genuinely caught up to the full %d-token state within 15s of SIGCONT (has %d tokens)", blocked.nodeID, baseTokens+extraTokens, len(got.Tokens))
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Logf("resumed replica %q genuinely caught up to the full %d-token state after SIGCONT + a fresh checkpoint", blocked.nodeID, baseTokens+extraTokens)

	// Scenario 2 step 4 (continued): lag must ALSO return to zero -
	// completing the visibility loop (SC-002/SC-005: the reported state
	// must track the real recovery, not lag behind it forever).
	recoveredLagDeadline := time.Now().Add(10 * time.Second)
	for {
		lag := replicationLag(t, client, primary.apiAddr, token)
		blockedRec, ok := lagFor(lag, blocked.nodeID)
		if ok && blockedRec.Lag == 0 {
			t.Logf("SC-002/SC-005: previously-blocked replica %q reports zero lag again after genuine recovery: %+v", blocked.nodeID, lag)
			break
		}
		if time.Now().After(recoveredLagDeadline) {
			t.Fatalf("replication-lag never returned to zero for the recovered replica %q within 10s: %+v", blocked.nodeID, lag)
		}
		time.Sleep(50 * time.Millisecond)
	}
}
