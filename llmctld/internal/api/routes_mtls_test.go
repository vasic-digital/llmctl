// Package api (routes_mtls_test.go): Feature 004 Phase 6 (T029, the
// full-feature independent code review) closes a genuine coverage gap
// found during that review - every OTHER RBAC-gated route family in this
// package (routes_tenants_test.go's TestCreateTenant_RequiresAdminRole,
// routes_models_test.go's forbidden-role assertions, routes_audit_test.go,
// routes_auth_test.go's escalation-refusal test) has a dedicated unit
// test proving a non-admin caller is genuinely rejected with 403, but
// routes_mtls.go (Feature 004: revoke/renew/rotate-begin/rotate-status/
// rotate-finalize) had NO such test anywhere in the tree - only
// test/integration/mtls_rotation_test.go's real 3-node cluster tests
// exercise these routes, and EVERY one of those uses tc.adminToken()
// exclusively (grep-confirmed against that file before writing this one).
// The production code (RegisterMTLSRoutes) was already correctly gating
// every operator action via decider.CheckRBAC(..., auth.ActionMTLSManage,
// "mtls") - this file's job is proving that gate, not building it.
//
// This test uses a SINGLE-NODE, self-leader *raft.Node (raft.Bootstrap,
// exactly like server_test.go's TestClusterStatus_RealHTTP3RequestOverMTLS
// reference shape) rather than test/integration's real 3-node cluster,
// because proving an RBAC gate needs no multi-node replication - the
// decider.CheckRBAC check runs and returns BEFORE any *raft.Node method is
// ever touched on the rejected path, matching every sibling *_test.go
// file's own choice to keep RBAC-gate tests in this lightweight,
// single-process gin.TestMode form (routes_models_test.go's own
// newModelRoutesTestEngine passes node=nil for the identical reason: RBAC
// is checked first).
package api

import (
	"crypto/tls"
	"crypto/x509"
	"net/http"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	jwtlib "github.com/golang-jwt/jwt/v5"

	"github.com/vasic-digital/llmctl/llmctld/internal/audit"
	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
	"github.com/vasic-digital/llmctl/llmctld/internal/authz"
	"github.com/vasic-digital/llmctl/llmctld/internal/mtls"
	"github.com/vasic-digital/llmctl/llmctld/internal/raft"
	"github.com/vasic-digital/llmctl/llmctld/internal/tenancy"
)

// mtlsRoutesTestFixture bundles everything TestMTLSRoutes_RequireAdminMTLSManageRole
// needs: a real single-node self-leader *raft.Node, real TrustStores for
// its raft-transport and api identities (mirroring cmd/llmctld/main.go's
// buildNodeTLSConfig naming), a real *mtls.RotationCAHolder seeded with a
// real CA, and the wired *gin.Engine.
type mtlsRoutesTestFixture struct {
	node   *raft.Node
	engine *gin.Engine
}

func newMTLSRoutesTestEngine(t *testing.T) *mtlsRoutesTestFixture {
	t.Helper()

	ca, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA: %v", err)
	}
	nodeCert, err := ca.IssueNodeCert("node-a")
	if err != nil {
		t.Fatalf("IssueNodeCert(node-a): %v", err)
	}
	cert, err := mtls.LoadTLSCertificate(nodeCert.CertPEM, nodeCert.KeyPEM)
	if err != nil {
		t.Fatalf("LoadTLSCertificate(node-a): %v", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(ca.CertPEM) {
		t.Fatalf("AppendCertsFromPEM: failed to add CA cert")
	}
	raftStore, err := mtls.NewTrustStore(pool, &cert)
	if err != nil {
		t.Fatalf("NewTrustStore(raft): %v", err)
	}
	apiCert := cert // a distinct *tls.Certificate value for the api-identity store, mirroring main.go's two-identity split
	apiStore, err := mtls.NewTrustStore(pool, &apiCert)
	if err != nil {
		t.Fatalf("NewTrustStore(api): %v", err)
	}

	node, err := raft.Bootstrap(raft.Config{
		NodeID:   "node-a",
		BindAddr: "127.0.0.1:0",
		TLSConfig: &tls.Config{
			GetCertificate:        raftStore.GetCertificate,
			GetClientCertificate:  raftStore.GetClientCertificate,
			RootCAs:               pool,
			ClientCAs:             pool,
			ClientAuth:            tls.RequireAnyClientCert,
			InsecureSkipVerify:    true,
			VerifyPeerCertificate: raft.VerifyPeerCertificateAgainstCA(raftStore),
		},
	})
	if err != nil {
		t.Fatalf("raft.Bootstrap: %v", err)
	}
	t.Cleanup(func() { _ = node.Shutdown() })
	waitForRealLeader(t, node, 3*time.Second)

	rotationHolder := mtls.NewRotationCAHolder(ca)

	gin.SetMode(gin.TestMode)
	engine := gin.New()
	decider := authz.NewDecider(audit.NewLog(), []byte("test-signing-key"), auth.NewRoleRegistry(), tenancy.NewEnforcer(), tenancy.NewRegistry())
	// forwardTLS is nil: every route this test exercises either returns
	// before reaching ForwardCARotationTransition (the RBAC-forbidden
	// path, checked first) or never enters that branch on the
	// RBAC-allowed path either - this single-node cluster is always its
	// own leader, so node.RecordCARotationTransition always succeeds
	// locally and the forward-to-leader fallback is never invoked (see
	// routes_mtls.go's renew handler: the forward branch is guarded by
	// !node.IsLeader()).
	RegisterMTLSRoutes(engine, node, decider, rotationHolder, nil, raftStore, apiStore)

	return &mtlsRoutesTestFixture{node: node, engine: engine}
}

func issueMTLSTestJWT(t *testing.T, signingKey []byte, roles []string) string {
	t.Helper()
	token, err := auth.IssueToken(auth.Claims{
		RegisteredClaims: jwtlib.RegisteredClaims{
			Subject:   "test-subject",
			ExpiresAt: jwtlib.NewNumericDate(time.Now().Add(time.Hour)),
		},
		Roles: roles,
	}, signingKey)
	if err != nil {
		t.Fatalf("issue jwt (roles=%v): %v", roles, err)
	}
	return token
}

// TestMTLSRoutes_RequireAdminMTLSManageRole is Feature 004 Phase 6 T029's
// own review finding, closed via TDD: EVERY operator-facing routes_mtls.go
// action (POST revoke, GET revocations, POST renew, POST rotate/begin, GET
// rotate/status, POST rotate/finalize) MUST reject a caller holding a
// role that does not grant auth.ActionMTLSManage with 403 Forbidden - the
// SAME "admin-RBAC-gated exactly like the others" guarantee
// routes_tenants_test.go/routes_models_test.go/routes_audit_test.go each
// already prove for their own action, now proven here for the first time
// for routes_mtls.go's six actions.
//
// Three distinct assertions per action (never merely "not 200"):
//  1. NO bearer token at all -> 401 (RequireJWT's own missing-token
//     rejection) - proves these routes genuinely require a caller
//     identity in the first place.
//  2. A validly-signed token bearing auth.RoleModelViewer (a REAL,
//     predefined role that grants no mtls:manage action per
//     internal/auth/rbac.go's predefinedRoles table) -> 403 - the core
//     finding this test closes.
//  3. A validly-signed token bearing auth.RoleAdmin -> NOT 403 (the
//     positive/negative control proving assertion 2 is genuinely testing
//     the RBAC gate, not merely "this route always refuses everything";
//     the business-level outcome for the admin case is deliberately left
//     unasserted beyond "cleared the RBAC gate", since driving every
//     action to full business-level success is test/integration's own
//     job, already covered by T007-T025's real-cluster tests).
func TestMTLSRoutes_RequireAdminMTLSManageRole(t *testing.T) {
	fx := newMTLSRoutesTestEngine(t)
	viewerToken := issueMTLSTestJWT(t, []byte("test-signing-key"), []string{auth.RoleModelViewer})
	adminToken := issueMTLSTestJWT(t, []byte("test-signing-key"), []string{auth.RoleAdmin})

	// Generate a second, distinct CA up front for the rotate/begin
	// action's body (both the viewer-role 403 attempt and the admin
	// positive-control attempt need a real incoming_ca_cert_pem/
	// incoming_ca_key_pem pair - ShouldBindJSON's own "required" tag
	// would otherwise turn an empty body into a 400 BEFORE the RBAC
	// check even runs for a MALFORMED body, muddying the 403 assertion
	// for anyone reading this test's failure output; using a real,
	// well-formed body isolates the assertion to RBAC alone).
	incomingCA, err := mtls.GenerateCA()
	if err != nil {
		t.Fatalf("GenerateCA(incoming): %v", err)
	}
	beginBody := map[string]string{
		"incoming_ca_cert_pem": string(incomingCA.CertPEM),
		"incoming_ca_key_pem":  string(incomingCA.KeyPEM),
	}

	type action struct {
		name   string
		method string
		path   string
		body   interface{}
	}
	actions := []action{
		{"revoke", http.MethodPost, "/v1/cluster/mtls/revoke", map[string]string{"serial_number": "123456789"}},
		{"get-revocations", http.MethodGet, "/v1/cluster/mtls/revocations", nil},
		{"renew", http.MethodPost, "/v1/cluster/mtls/renew", nil},
		{"rotate-begin", http.MethodPost, "/v1/cluster/mtls/rotate/begin", beginBody},
		{"get-rotate-status", http.MethodGet, "/v1/cluster/mtls/rotate/status", nil},
		{"rotate-finalize", http.MethodPost, "/v1/cluster/mtls/rotate/finalize", nil},
	}

	for _, a := range actions {
		t.Run(a.name, func(t *testing.T) {
			// Assertion 1: no bearer token at all -> 401, never 403 -
			// proves RequireJWT itself is wired on this route (a route
			// with NO auth middleware at all would happily proceed and
			// return something other than 401 here, silently masking a
			// far worse defect than a missing RBAC check).
			if rec := doJSON(t, fx.engine, a.method, a.path, a.body, ""); rec.Code != http.StatusUnauthorized {
				t.Fatalf("%s: no token: expected 401, got %d: %s", a.name, rec.Code, rec.Body.String())
			}

			// Assertion 2 (the core finding): a real, validly-signed
			// token bearing a real predefined role that grants no
			// mtls:manage action -> 403.
			if rec := doJSON(t, fx.engine, a.method, a.path, a.body, viewerToken); rec.Code != http.StatusForbidden {
				t.Fatalf("%s: model-viewer token: expected 403, got %d: %s", a.name, rec.Code, rec.Body.String())
			}

			// Assertion 3 (negative control): an admin token clears the
			// RBAC gate - MUST NOT be 403. Business-level outcome
			// (200/409/etc.) is intentionally not asserted here; a fresh
			// fixture per subtest (t.Run) keeps this action's own
			// admin-path state (e.g. rotate/begin's dual-trust
			// activation) from leaking into a sibling subtest's own
			// RBAC-only assertions above.
			if rec := doJSON(t, fx.engine, a.method, a.path, a.body, adminToken); rec.Code == http.StatusForbidden {
				t.Fatalf("%s: admin token: expected NOT 403 (RBAC should clear), got 403: %s", a.name, rec.Body.String())
			}
		})
	}
}

// TestMTLSRoutes_RotateTransition_IsPeerOnlyNotJWTGated is the sibling
// regression guard for routes_mtls.go's own documented design decision
// (package doc comment + POST /v1/cluster/mtls/rotate/transition's own
// handler-registration doc comment): UNLIKE the six operator actions
// above, this internal, peer-to-peer forwarding target deliberately
// carries NO RequireJWT/RBAC gate - mirroring routes_cluster.go's
// POST /v1/cluster/join and /v1/cluster/leave (gated by the real mTLS
// handshake alone, since those are peer-node calls, per that file's own
// package doc comment). A caller presenting NO bearer token at all MUST
// NOT receive 401 here (that would mean a future edit accidentally
// wrapped this route in RequireJWT, which would break T020's real
// leader-forwarding fallback - ForwardCARotationTransition never attaches
// an Authorization header, by design, since node-to-node calls are
// authenticated at the transport layer, not via JWT).
func TestMTLSRoutes_RotateTransition_IsPeerOnlyNotJWTGated(t *testing.T) {
	fx := newMTLSRoutesTestEngine(t)

	body := map[string]string{"node_id": fx.node.ID()}
	rec := doJSON(t, fx.engine, http.MethodPost, "/v1/cluster/mtls/rotate/transition", body, "")
	if rec.Code == http.StatusUnauthorized || rec.Code == http.StatusForbidden {
		t.Fatalf("rotate/transition with no bearer token: expected NOT 401/403 (peer-only route, no JWT gate by design), got %d: %s", rec.Code, rec.Body.String())
	}
	// No rotation is in progress on this fresh fixture, so
	// CommandRecordCARotationTransition's own idempotent no-op path
	// (fsm.go: "existing == nil ... return nil") makes this a genuine
	// 200 success, not merely "any non-401/403 code" - confirming the
	// request actually reached and was processed by the real handler,
	// not merely swallowed by some other unrelated middleware.
	if rec.Code != http.StatusOK {
		t.Fatalf("rotate/transition with no bearer token: expected 200 (idempotent no-op, no rotation in progress), got %d: %s", rec.Code, rec.Body.String())
	}
}
