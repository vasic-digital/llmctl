// Package api (routes_replication_test.go): proves the KV-cache
// replication routes (T062, FR-026/FR-028) work end-to-end over a real
// HTTP/3+mTLS round trip against a real *raft.Node + real
// *replication.Store - the same real-process, no-shortcuts pattern
// server_test.go already establishes for the cluster routes.
package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
	"github.com/vasic-digital/llmctl/llmctld/internal/raft"
	"github.com/vasic-digital/llmctl/llmctld/internal/replication"
)

// TestReplicationRoutes_AppendCheckpointStateRealHTTP3RoundTrip proves
// POST /v1/replication/append, POST /v1/replication/checkpoint, and
// GET /v1/replication/state genuinely drive a real *replication.Store
// over a real HTTP/3+mTLS connection: appended entries are visible via
// state, and a checkpoint correctly folds prior entries into the
// checkpoint's KVState while later WAL entries replay on top of it (the
// real Store.Checkpoint/Restore semantics, exercised here through the
// HTTP layer rather than called in-process).
func TestReplicationRoutes_AppendCheckpointStateRealHTTP3RoundTrip(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}

	node, err := raft.Bootstrap(raft.Config{
		NodeID:    "node-a",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildTestTLSConfig(t, ca, "node-a"),
	})
	if err != nil {
		t.Fatalf("raft.Bootstrap: %v", err)
	}
	defer func() { _ = node.Shutdown() }()
	waitForRealLeader(t, node, 3*time.Second)

	registry := replication.NewStoreRegistry(t.TempDir(), replication.CheckpointConfig{})
	defer func() { _ = registry.Close() }()

	srv := NewServer(node, buildTestTLSConfig(t, ca, "node-a-api"))
	RegisterReplicationRoutes(srv.Router(), registry)
	if err := srv.Listen("127.0.0.1:0"); err != nil {
		t.Fatalf("Listen: %v", err)
	}
	defer func() { _ = srv.Close() }()

	client := newTestClient(buildTestTLSConfig(t, ca, "test-client"))

	// Append 10 entries (Seq 1..10) in one batched request - real
	// production traffic batches many tokens per POST rather than one
	// HTTP round trip per token.
	appendBody, err := json.Marshal(map[string]any{
		"entries": []map[string]any{
			{"seq": 1, "token_id": 100, "position": 0},
			{"seq": 2, "token_id": 101, "position": 1},
			{"seq": 3, "token_id": 102, "position": 2},
			{"seq": 4, "token_id": 103, "position": 3},
			{"seq": 5, "token_id": 104, "position": 4},
			{"seq": 6, "token_id": 105, "position": 5},
			{"seq": 7, "token_id": 106, "position": 6},
			{"seq": 8, "token_id": 107, "position": 7},
			{"seq": 9, "token_id": 108, "position": 8},
			{"seq": 10, "token_id": 109, "position": 9},
		},
	})
	if err != nil {
		t.Fatalf("marshal append body: %v", err)
	}
	resp, err := client.Post("https://"+srv.Addr+"/v1/replication/append", "application/json", bytes.NewReader(appendBody))
	if err != nil {
		t.Fatalf("POST /v1/replication/append: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		t.Fatalf("POST /v1/replication/append: status = %d, body = %s", resp.StatusCode, body)
	}
	_ = resp.Body.Close()

	// GET /v1/replication/state must reflect all 10 appended entries.
	stateResp, err := client.Get("https://" + srv.Addr + "/v1/replication/state")
	if err != nil {
		t.Fatalf("GET /v1/replication/state: %v", err)
	}
	var got1 struct {
		Tokens    []int32 `json:"tokens"`
		Positions []int32 `json:"positions"`
	}
	if err := json.NewDecoder(stateResp.Body).Decode(&got1); err != nil {
		t.Fatalf("decode state response: %v", err)
	}
	_ = stateResp.Body.Close()
	if len(got1.Tokens) != 10 || len(got1.Positions) != 10 {
		t.Fatalf("GET /v1/replication/state after append = %+v, want 10 tokens/positions", got1)
	}
	for i := 0; i < 10; i++ {
		if got1.Tokens[i] != int32(100+i) || got1.Positions[i] != int32(i) {
			t.Fatalf("GET /v1/replication/state entry %d = (token=%d,pos=%d), want (token=%d,pos=%d)", i, got1.Tokens[i], got1.Positions[i], 100+i, i)
		}
	}

	// Checkpoint at seq=10 with the full 10-entry state, then append 2
	// more entries (seq 11,12) - Restore must fold the checkpoint's state
	// with the post-checkpoint WAL entries replayed on top.
	checkpointBody, err := json.Marshal(map[string]any{
		"seq": 10,
		"state": map[string]any{
			"tokens":    got1.Tokens,
			"positions": got1.Positions,
		},
	})
	if err != nil {
		t.Fatalf("marshal checkpoint body: %v", err)
	}
	cpResp, err := client.Post("https://"+srv.Addr+"/v1/replication/checkpoint", "application/json", bytes.NewReader(checkpointBody))
	if err != nil {
		t.Fatalf("POST /v1/replication/checkpoint: %v", err)
	}
	if cpResp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(cpResp.Body)
		_ = cpResp.Body.Close()
		t.Fatalf("POST /v1/replication/checkpoint: status = %d, body = %s", cpResp.StatusCode, body)
	}
	_ = cpResp.Body.Close()

	appendBody2, err := json.Marshal(map[string]any{
		"entries": []map[string]any{
			{"seq": 11, "token_id": 110, "position": 10},
			{"seq": 12, "token_id": 111, "position": 11},
		},
	})
	if err != nil {
		t.Fatalf("marshal second append body: %v", err)
	}
	resp2, err := client.Post("https://"+srv.Addr+"/v1/replication/append", "application/json", bytes.NewReader(appendBody2))
	if err != nil {
		t.Fatalf("POST /v1/replication/append (post-checkpoint): %v", err)
	}
	if resp2.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp2.Body)
		_ = resp2.Body.Close()
		t.Fatalf("POST /v1/replication/append (post-checkpoint): status = %d, body = %s", resp2.StatusCode, body)
	}
	_ = resp2.Body.Close()

	stateResp2, err := client.Get("https://" + srv.Addr + "/v1/replication/state")
	if err != nil {
		t.Fatalf("GET /v1/replication/state (post-checkpoint): %v", err)
	}
	defer func() { _ = stateResp2.Body.Close() }()
	var got2 struct {
		Tokens    []int32 `json:"tokens"`
		Positions []int32 `json:"positions"`
	}
	if err := json.NewDecoder(stateResp2.Body).Decode(&got2); err != nil {
		t.Fatalf("decode state response (post-checkpoint): %v", err)
	}
	if len(got2.Tokens) != 12 || len(got2.Positions) != 12 {
		t.Fatalf("GET /v1/replication/state after checkpoint+append = %+v, want 12 tokens/positions (10 from checkpoint + 2 replayed WAL entries)", got2)
	}
	for i := 0; i < 12; i++ {
		if got2.Tokens[i] != int32(100+i) || got2.Positions[i] != int32(i) {
			t.Fatalf("GET /v1/replication/state entry %d (post-checkpoint) = (token=%d,pos=%d), want (token=%d,pos=%d)", i, got2.Tokens[i], got2.Positions[i], 100+i, i)
		}
	}
}

// TestReplicationRoutes_DifferentTenantHeaders_AreIsolatedRealHTTP3RoundTrip
// is the direct HTTP-layer proof that RegisterReplicationRoutes' switch
// to *replication.StoreRegistry (T072-FU2) genuinely isolates tenants:
// two callers of the SAME running node, distinguished only by their
// X-Tenant-ID request header, must never observe each other's appended
// tokens - real requests, real HTTP/3+mTLS, real per-tenant
// internal/isolation.TenantStateDir subdirectories on disk, no mocks.
func TestReplicationRoutes_DifferentTenantHeaders_AreIsolatedRealHTTP3RoundTrip(t *testing.T) {
	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}

	node, err := raft.Bootstrap(raft.Config{
		NodeID:    "node-a",
		BindAddr:  "127.0.0.1:0",
		TLSConfig: buildTestTLSConfig(t, ca, "node-a"),
	})
	if err != nil {
		t.Fatalf("raft.Bootstrap: %v", err)
	}
	defer func() { _ = node.Shutdown() }()
	waitForRealLeader(t, node, 3*time.Second)

	registry := replication.NewStoreRegistry(t.TempDir(), replication.CheckpointConfig{})
	defer func() { _ = registry.Close() }()

	srv := NewServer(node, buildTestTLSConfig(t, ca, "node-a-api"))
	RegisterReplicationRoutes(srv.Router(), registry)
	if err := srv.Listen("127.0.0.1:0"); err != nil {
		t.Fatalf("Listen: %v", err)
	}
	defer func() { _ = srv.Close() }()

	client := newTestClient(buildTestTLSConfig(t, ca, "test-client"))

	appendForTenant := func(tenantID string, seq uint64, tokenID int32) {
		body, err := json.Marshal(map[string]any{
			"entries": []map[string]any{
				{"seq": seq, "token_id": tokenID, "position": 0},
			},
		})
		if err != nil {
			t.Fatalf("marshal append body for tenant %q: %v", tenantID, err)
		}
		req, err := http.NewRequest(http.MethodPost, "https://"+srv.Addr+"/v1/replication/append", bytes.NewReader(body))
		if err != nil {
			t.Fatalf("new request for tenant %q: %v", tenantID, err)
		}
		req.Header.Set("Content-Type", "application/json")
		if tenantID != "" {
			req.Header.Set("X-Tenant-ID", tenantID)
		}
		resp, err := client.Do(req)
		if err != nil {
			t.Fatalf("POST /v1/replication/append for tenant %q: %v", tenantID, err)
		}
		defer func() { _ = resp.Body.Close() }()
		if resp.StatusCode != http.StatusOK {
			respBody, _ := io.ReadAll(resp.Body)
			t.Fatalf("POST /v1/replication/append for tenant %q: status = %d, body = %s", tenantID, resp.StatusCode, respBody)
		}
	}

	stateForTenant := func(tenantID string) struct {
		Tokens    []int32 `json:"tokens"`
		Positions []int32 `json:"positions"`
	} {
		req, err := http.NewRequest(http.MethodGet, "https://"+srv.Addr+"/v1/replication/state", nil)
		if err != nil {
			t.Fatalf("new state request for tenant %q: %v", tenantID, err)
		}
		if tenantID != "" {
			req.Header.Set("X-Tenant-ID", tenantID)
		}
		resp, err := client.Do(req)
		if err != nil {
			t.Fatalf("GET /v1/replication/state for tenant %q: %v", tenantID, err)
		}
		defer func() { _ = resp.Body.Close() }()
		var got struct {
			Tokens    []int32 `json:"tokens"`
			Positions []int32 `json:"positions"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
			t.Fatalf("decode state response for tenant %q: %v", tenantID, err)
		}
		return got
	}

	// tenant-a appends token 111, tenant-b appends a DIFFERENT token 222 -
	// via the real HTTP layer of the SAME running node, distinguished
	// only by the X-Tenant-ID header.
	appendForTenant("tenant-a", 1, 111)
	appendForTenant("tenant-b", 1, 222)

	gotA := stateForTenant("tenant-a")
	if len(gotA.Tokens) != 1 || gotA.Tokens[0] != 111 {
		t.Fatalf("tenant-a GET /v1/replication/state = %+v, want exactly [111] (never tenant-b's 222)", gotA)
	}

	gotB := stateForTenant("tenant-b")
	if len(gotB.Tokens) != 1 || gotB.Tokens[0] != 222 {
		t.Fatalf("tenant-b GET /v1/replication/state = %+v, want exactly [222] (never tenant-a's 111)", gotB)
	}

	// The default (no header) tenant is its own SEPARATE store, still
	// empty - proving the two named tenants never leaked into it either.
	gotDefault := stateForTenant("")
	if len(gotDefault.Tokens) != 0 {
		t.Fatalf("default (no X-Tenant-ID header) GET /v1/replication/state = %+v, want empty (tenant-a/tenant-b traffic must never reach the default tenant's store)", gotDefault)
	}
}
