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

	"github.com/vasic-digital/llmctl/llmctld/internal/audit"
	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
	"github.com/vasic-digital/llmctl/llmctld/internal/authz"
	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
	"github.com/vasic-digital/llmctl/llmctld/internal/raft"
	"github.com/vasic-digital/llmctl/llmctld/internal/replication"
	"github.com/vasic-digital/llmctl/llmctld/internal/tenancy"
)

// newReplicationTestDecider builds a fresh *authz.Decider for this
// file's real-process tests, mirroring newDeciderAndEngine's exact
// construction (routes_tenants_test.go) so both test files' deciders
// are built identically.
func newReplicationTestDecider() *authz.Decider {
	return authz.NewDecider(audit.NewLog(), []byte("test-signing-key"), auth.NewRoleRegistry(), tenancy.NewEnforcer(), tenancy.NewRegistry())
}

// issueReplicationTestJWT mints a real JWT for tenantID against
// decider's own signing key - mirrors routes_tenants_test.go's
// issueTenantJWT exactly (duplicated here rather than shared across
// files, matching this package's existing per-file helper convention).
func issueReplicationTestJWT(t *testing.T, decider *authz.Decider, tenantID string) string {
	t.Helper()
	token, err := auth.IssueToken(auth.Claims{
		TenantID: tenantID,
	}, decider.SigningKey)
	if err != nil {
		t.Fatalf("issue jwt for tenant %q: %v", tenantID, err)
	}
	return token
}

// doAuthedReplicationRequest issues a real HTTP request against apiAddr
// carrying bearerToken (via the standard Authorization: Bearer header)
// and tenantIDHeaderVal (via X-Tenant-ID, empty means omit the header
// entirely) - the shared low-level request helper every test below uses
// so token/tenant-header placement is identical across append/
// checkpoint/state calls.
func doAuthedReplicationRequest(t *testing.T, client *http.Client, method, apiAddr, path, bearerToken, tenantIDHeaderVal string, body []byte) *http.Response {
	t.Helper()
	var reader *bytes.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	} else {
		reader = bytes.NewReader(nil)
	}
	req, err := http.NewRequest(method, "https://"+apiAddr+path, reader)
	if err != nil {
		t.Fatalf("new request %s %s: %v", method, path, err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if bearerToken != "" {
		req.Header.Set("Authorization", "Bearer "+bearerToken)
	}
	if tenantIDHeaderVal != "" {
		req.Header.Set(tenantIDHeader, tenantIDHeaderVal)
	}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	return resp
}

// TestReplicationRoutes_RequireJWTAndTenantOwnership is the security
// fix's own proof: before this fix, RegisterReplicationRoutes required
// NO authentication at all, so any caller reaching this mTLS-gated
// router could read/append/checkpoint ANY tenant's replicated
// conversation state simply by setting X-Tenant-ID to whatever it
// wanted - the exact cross-tenant data-leakage class Clarification 18/
// FR-049 exists to prevent. This test proves that gap is closed: (1) no
// bearer token at all is rejected outright; (2) a valid token for
// tenant-b attempting to address tenant-a's data (via the header) is
// rejected; (3) a valid token for tenant-a addressing its OWN data
// succeeds.
func TestReplicationRoutes_RequireJWTAndTenantOwnership(t *testing.T) {
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
	decider := newReplicationTestDecider()

	srv := NewServer(node, buildTestTLSConfig(t, ca, "node-a-api"))
	RegisterReplicationRoutes(srv.Router(), registry, decider, node, NewNodeForwarder(node, http.DefaultClient))
	if err := srv.Listen("127.0.0.1:0"); err != nil {
		t.Fatalf("Listen: %v", err)
	}
	defer func() { _ = srv.Close() }()

	client := newTestClient(buildTestTLSConfig(t, ca, "test-client"))

	// (1) No bearer token at all -> 401.
	resp := doAuthedReplicationRequest(t, client, http.MethodGet, srv.Addr, "/v1/replication/state", "", "tenant-a", nil)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no-token GET /v1/replication/state (X-Tenant-ID: tenant-a): status = %d, want 401", resp.StatusCode)
	}

	// (2) A valid tenant-b token attempting to address tenant-a's data
	// via the header -> 403, never 200.
	tenantBToken := issueReplicationTestJWT(t, decider, "tenant-b")
	resp2 := doAuthedReplicationRequest(t, client, http.MethodGet, srv.Addr, "/v1/replication/state", tenantBToken, "tenant-a", nil)
	_ = resp2.Body.Close()
	if resp2.StatusCode != http.StatusForbidden {
		t.Fatalf("tenant-b token addressing tenant-a's state: status = %d, want 403 (cross-tenant access must be denied)", resp2.StatusCode)
	}

	// (3) tenant-a's own token addressing its own data -> 200.
	tenantAToken := issueReplicationTestJWT(t, decider, "tenant-a")
	resp3 := doAuthedReplicationRequest(t, client, http.MethodGet, srv.Addr, "/v1/replication/state", tenantAToken, "tenant-a", nil)
	body3, _ := io.ReadAll(resp3.Body)
	_ = resp3.Body.Close()
	if resp3.StatusCode != http.StatusOK {
		t.Fatalf("tenant-a token addressing its own state: status = %d, want 200, body = %s", resp3.StatusCode, body3)
	}
}

// TestReplicationRoutes_LagEndpoint_RequiresJWTAndTenantOwnership is
// T019's own authorization proof, mirroring
// TestReplicationRoutes_RequireJWTAndTenantOwnership EXACTLY (same 3
// assertions, same real *raft.Node + real HTTP/3+mTLS round trip) for
// the NEW GET /v1/replication/lag route (User Story 3, spec.md FR-010) -
// proving it follows the identical RequireJWT + tenant-ownership pattern
// every other route in this file already enforces, rather than a
// differently-scoped endpoint.
func TestReplicationRoutes_LagEndpoint_RequiresJWTAndTenantOwnership(t *testing.T) {
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
	decider := newReplicationTestDecider()

	srv := NewServer(node, buildTestTLSConfig(t, ca, "node-a-api"))
	RegisterReplicationRoutes(srv.Router(), registry, decider, node, NewNodeForwarder(node, http.DefaultClient))
	if err := srv.Listen("127.0.0.1:0"); err != nil {
		t.Fatalf("Listen: %v", err)
	}
	defer func() { _ = srv.Close() }()

	client := newTestClient(buildTestTLSConfig(t, ca, "test-client"))

	// (1) No bearer token at all -> 401.
	resp := doAuthedReplicationRequest(t, client, http.MethodGet, srv.Addr, "/v1/replication/lag", "", "tenant-a", nil)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no-token GET /v1/replication/lag (X-Tenant-ID: tenant-a): status = %d, want 401", resp.StatusCode)
	}

	// (2) A valid tenant-b token attempting to view tenant-a's lag via
	// the header -> 403, never 200 (T011's tenant-scoping discipline
	// applied identically to this new observability route).
	tenantBToken := issueReplicationTestJWT(t, decider, "tenant-b")
	resp2 := doAuthedReplicationRequest(t, client, http.MethodGet, srv.Addr, "/v1/replication/lag", tenantBToken, "tenant-a", nil)
	_ = resp2.Body.Close()
	if resp2.StatusCode != http.StatusForbidden {
		t.Fatalf("tenant-b token viewing tenant-a's lag: status = %d, want 403 (cross-tenant lag visibility must be denied)", resp2.StatusCode)
	}

	// (3) tenant-a's own token viewing its own lag -> 200, with an empty
	// (never null, never fabricated) replica list: this single-node
	// harness has never forwarded anything anywhere.
	tenantAToken := issueReplicationTestJWT(t, decider, "tenant-a")
	resp3 := doAuthedReplicationRequest(t, client, http.MethodGet, srv.Addr, "/v1/replication/lag", tenantAToken, "tenant-a", nil)
	body3, _ := io.ReadAll(resp3.Body)
	_ = resp3.Body.Close()
	if resp3.StatusCode != http.StatusOK {
		t.Fatalf("tenant-a token viewing its own lag: status = %d, want 200, body = %s", resp3.StatusCode, body3)
	}
	var got lagResponse
	if err := json.Unmarshal(body3, &got); err != nil {
		t.Fatalf("decode lag response: %v, body = %s", err, body3)
	}
	if got.TenantID != "tenant-a" {
		t.Fatalf("lag response TenantID = %q, want %q", got.TenantID, "tenant-a")
	}
	if got.Replicas == nil || len(got.Replicas) != 0 {
		t.Fatalf("lag response Replicas = %+v, want a non-nil empty slice (no forwarding has ever occurred in this single-node harness)", got.Replicas)
	}
}

// TestReplicationRoutes_AppendEndpoint_RequiresJWTAndTenantOwnership is
// 008-full-test-coverage T026 (spec.md FR-007's RBAC-route audit):
// mirrors TestReplicationRoutes_LagEndpoint_RequiresJWTAndTenantOwnership
// EXACTLY for POST /v1/replication/append - before this test, append's
// happy-path + tenant-isolation behavior was proven
// (TestReplicationRoutes_AppendCheckpointStateRealHTTP3RoundTrip,
// TestReplicationRoutes_DifferentTenantHeaders_AreIsolatedRealHTTP3RoundTrip
// below), but no test asserted the adversarial case directly: a valid
// token for one tenant attempting to APPEND to a DIFFERENT tenant's log
// via the X-Tenant-ID header must be refused with 403, never silently
// accepted. resolveStore's own ownership check runs BEFORE JSON body
// binding (routes_replication.go), so this adversarial case needs no
// request body, exactly like the /state and /lag siblings above.
func TestReplicationRoutes_AppendEndpoint_RequiresJWTAndTenantOwnership(t *testing.T) {
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
	decider := newReplicationTestDecider()

	srv := NewServer(node, buildTestTLSConfig(t, ca, "node-a-api"))
	RegisterReplicationRoutes(srv.Router(), registry, decider, node, NewNodeForwarder(node, http.DefaultClient))
	if err := srv.Listen("127.0.0.1:0"); err != nil {
		t.Fatalf("Listen: %v", err)
	}
	defer func() { _ = srv.Close() }()

	client := newTestClient(buildTestTLSConfig(t, ca, "test-client"))

	// (1) No bearer token at all -> 401.
	resp := doAuthedReplicationRequest(t, client, http.MethodPost, srv.Addr, "/v1/replication/append", "", "tenant-a", nil)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no-token POST /v1/replication/append (X-Tenant-ID: tenant-a): status = %d, want 401", resp.StatusCode)
	}

	// (2) A valid tenant-b token attempting to APPEND to tenant-a's log
	// via the header -> 403, never 200.
	tenantBToken := issueReplicationTestJWT(t, decider, "tenant-b")
	resp2 := doAuthedReplicationRequest(t, client, http.MethodPost, srv.Addr, "/v1/replication/append", tenantBToken, "tenant-a", nil)
	_ = resp2.Body.Close()
	if resp2.StatusCode != http.StatusForbidden {
		t.Fatalf("tenant-b token appending to tenant-a's log: status = %d, want 403 (cross-tenant append must be denied)", resp2.StatusCode)
	}
}

// TestReplicationRoutes_CheckpointEndpoint_RequiresJWTAndTenantOwnership
// is 008-full-test-coverage T026's sibling case for POST
// /v1/replication/checkpoint, mirroring the append test above exactly -
// a valid token for one tenant attempting to CHECKPOINT a DIFFERENT
// tenant's store via the header must be refused with 403.
func TestReplicationRoutes_CheckpointEndpoint_RequiresJWTAndTenantOwnership(t *testing.T) {
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
	decider := newReplicationTestDecider()

	srv := NewServer(node, buildTestTLSConfig(t, ca, "node-a-api"))
	RegisterReplicationRoutes(srv.Router(), registry, decider, node, NewNodeForwarder(node, http.DefaultClient))
	if err := srv.Listen("127.0.0.1:0"); err != nil {
		t.Fatalf("Listen: %v", err)
	}
	defer func() { _ = srv.Close() }()

	client := newTestClient(buildTestTLSConfig(t, ca, "test-client"))

	// (1) No bearer token at all -> 401.
	resp := doAuthedReplicationRequest(t, client, http.MethodPost, srv.Addr, "/v1/replication/checkpoint", "", "tenant-a", nil)
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no-token POST /v1/replication/checkpoint (X-Tenant-ID: tenant-a): status = %d, want 401", resp.StatusCode)
	}

	// (2) A valid tenant-b token attempting to CHECKPOINT tenant-a's
	// store via the header -> 403, never 200.
	tenantBToken := issueReplicationTestJWT(t, decider, "tenant-b")
	resp2 := doAuthedReplicationRequest(t, client, http.MethodPost, srv.Addr, "/v1/replication/checkpoint", tenantBToken, "tenant-a", nil)
	_ = resp2.Body.Close()
	if resp2.StatusCode != http.StatusForbidden {
		t.Fatalf("tenant-b token checkpointing tenant-a's store: status = %d, want 403 (cross-tenant checkpoint must be denied)", resp2.StatusCode)
	}
}

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
	decider := newReplicationTestDecider()
	// This test exercises the default (no X-Tenant-ID header) tenant
	// path, so its token carries an empty TenantID - authorizeTenantOwnership
	// grants access because claims.TenantID ("") == the resolved tenant
	// ID (also "").
	token := issueReplicationTestJWT(t, decider, "")

	srv := NewServer(node, buildTestTLSConfig(t, ca, "node-a-api"))
	RegisterReplicationRoutes(srv.Router(), registry, decider, node, NewNodeForwarder(node, http.DefaultClient))
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
	resp := doAuthedReplicationRequest(t, client, http.MethodPost, srv.Addr, "/v1/replication/append", token, "", appendBody)
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		t.Fatalf("POST /v1/replication/append: status = %d, body = %s", resp.StatusCode, body)
	}
	_ = resp.Body.Close()

	// GET /v1/replication/state must reflect all 10 appended entries.
	stateResp := doAuthedReplicationRequest(t, client, http.MethodGet, srv.Addr, "/v1/replication/state", token, "", nil)
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
	cpResp := doAuthedReplicationRequest(t, client, http.MethodPost, srv.Addr, "/v1/replication/checkpoint", token, "", checkpointBody)
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
	resp2 := doAuthedReplicationRequest(t, client, http.MethodPost, srv.Addr, "/v1/replication/append", token, "", appendBody2)
	if resp2.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp2.Body)
		_ = resp2.Body.Close()
		t.Fatalf("POST /v1/replication/append (post-checkpoint): status = %d, body = %s", resp2.StatusCode, body)
	}
	_ = resp2.Body.Close()

	stateResp2 := doAuthedReplicationRequest(t, client, http.MethodGet, srv.Addr, "/v1/replication/state", token, "", nil)
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
	decider := newReplicationTestDecider()

	srv := NewServer(node, buildTestTLSConfig(t, ca, "node-a-api"))
	RegisterReplicationRoutes(srv.Router(), registry, decider, node, NewNodeForwarder(node, http.DefaultClient))
	if err := srv.Listen("127.0.0.1:0"); err != nil {
		t.Fatalf("Listen: %v", err)
	}
	defer func() { _ = srv.Close() }()

	client := newTestClient(buildTestTLSConfig(t, ca, "test-client"))

	// Each tenant authenticates with ITS OWN token, matching the
	// tenant ID it addresses via X-Tenant-ID - proving isolation holds
	// under real per-tenant authorization, not merely under one shared,
	// unauthenticated client identity (the exact gap an independent
	// review found in this test's own pre-fix form: it previously used
	// ONE client identity with NO token at all to freely address both
	// tenants).
	appendForTenant := func(tenantID string, seq uint64, tokenID int32) {
		body, err := json.Marshal(map[string]any{
			"entries": []map[string]any{
				{"seq": seq, "token_id": tokenID, "position": 0},
			},
		})
		if err != nil {
			t.Fatalf("marshal append body for tenant %q: %v", tenantID, err)
		}
		resp := doAuthedReplicationRequest(t, client, http.MethodPost, srv.Addr, "/v1/replication/append", issueReplicationTestJWT(t, decider, tenantID), tenantID, body)
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
		resp := doAuthedReplicationRequest(t, client, http.MethodGet, srv.Addr, "/v1/replication/state", issueReplicationTestJWT(t, decider, tenantID), tenantID, nil)
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
