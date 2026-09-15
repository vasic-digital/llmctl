package api

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	jwtlib "github.com/golang-jwt/jwt/v5"

	"github.com/vasic-digital/llmctl/llmctld/internal/audit"
	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
	"github.com/vasic-digital/llmctl/llmctld/internal/authz"
	"github.com/vasic-digital/llmctl/llmctld/internal/tenancy"
)

// testDecider builds a minimal *authz.Decider for middleware tests -
// only SigningKey and Log are exercised by RequireJWT, but a real Decider
// needs every field non-nil since CheckRBAC/CheckQuota/CheckTenantBoundary
// would nil-pointer-dereference on a nil RBAC/Quota/Tenants if a future
// test exercised them through this helper.
func testDecider(signingKey []byte) *authz.Decider {
	return authz.NewDecider(audit.NewLog(), signingKey, auth.NewRoleRegistry(), tenancy.NewEnforcer(), tenancy.NewRegistry())
}

func issueTestJWT(t *testing.T, signingKey []byte, tenantID string, roles []string, expiresAt time.Time) string {
	t.Helper()
	token, err := auth.IssueToken(auth.Claims{
		RegisteredClaims: jwtlib.RegisteredClaims{
			Subject:   "user-1",
			ExpiresAt: jwtlib.NewNumericDate(expiresAt),
		},
		TenantID: tenantID,
		Roles:    roles,
	}, signingKey)
	if err != nil {
		t.Fatalf("issue test jwt: %v", err)
	}
	return token
}

// newProtectedTestEngine builds a real gin.Engine (gin.TestMode, no real
// network) with a single GET /protected route behind RequireJWT(signingKey)
// - real gin routing + real middleware chain, driven via
// httptest.NewRecorder rather than a live HTTP/3 listener, since this
// middleware's behavior does not depend on the transport (server_test.go's
// real-HTTP/3+mTLS harness is reserved for tests that need to prove the
// transport-layer guarantee itself, e.g. RequireMTLS).
func newProtectedTestEngine(decider *authz.Decider, onSuccess func(c *gin.Context, claims *auth.Claims)) *gin.Engine {
	gin.SetMode(gin.TestMode)
	engine := gin.New()
	engine.GET("/protected", RequireJWT(decider), func(c *gin.Context) {
		onSuccess(c, ClaimsFromContext(c))
		c.JSON(http.StatusOK, gin.H{"status": "ok"})
	})
	return engine
}

func TestRequireJWT_ValidTokenSetsClaimsAndCallsNext(t *testing.T) {
	signingKey := []byte("test-signing-key")
	token := issueTestJWT(t, signingKey, "tenant-a", []string{auth.RoleModelViewer}, time.Now().Add(time.Hour))

	var gotClaims *auth.Claims
	engine := newProtectedTestEngine(testDecider(signingKey), func(_ *gin.Context, claims *auth.Claims) {
		gotClaims = claims
	})

	req := httptest.NewRequest(http.MethodGet, "/protected", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	engine.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	if gotClaims == nil {
		t.Fatal("expected ClaimsFromContext to return the validated claims")
	}
	if gotClaims.TenantID != "tenant-a" {
		t.Fatalf("expected TenantID=tenant-a, got %q", gotClaims.TenantID)
	}
}

func TestRequireJWT_MissingHeaderRejectedWith401(t *testing.T) {
	signingKey := []byte("test-signing-key")
	called := false
	engine := newProtectedTestEngine(testDecider(signingKey), func(_ *gin.Context, _ *auth.Claims) {
		called = true
	})

	req := httptest.NewRequest(http.MethodGet, "/protected", nil)
	rec := httptest.NewRecorder()
	engine.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
	if called {
		t.Fatal("expected the protected handler to never run without a token")
	}
}

func TestRequireJWT_MalformedTokenRejectedWith401(t *testing.T) {
	signingKey := []byte("test-signing-key")
	engine := newProtectedTestEngine(testDecider(signingKey), func(_ *gin.Context, _ *auth.Claims) {})

	req := httptest.NewRequest(http.MethodGet, "/protected", nil)
	req.Header.Set("Authorization", "Bearer not-a-real-token")
	rec := httptest.NewRecorder()
	engine.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}

func TestRequireJWT_ExpiredTokenRejectedWith401(t *testing.T) {
	signingKey := []byte("test-signing-key")
	token := issueTestJWT(t, signingKey, "tenant-a", nil, time.Now().Add(-time.Hour))
	engine := newProtectedTestEngine(testDecider(signingKey), func(_ *gin.Context, _ *auth.Claims) {})

	req := httptest.NewRequest(http.MethodGet, "/protected", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	engine.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}

func TestRequireJWT_WrongKeyRejectedWith401(t *testing.T) {
	token := issueTestJWT(t, []byte("actual-signing-key"), "tenant-a", nil, time.Now().Add(time.Hour))
	engine := newProtectedTestEngine(testDecider([]byte("a-different-key")), func(_ *gin.Context, _ *auth.Claims) {})

	req := httptest.NewRequest(http.MethodGet, "/protected", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	engine.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}
