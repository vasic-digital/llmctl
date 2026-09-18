// Package api (jwt_adversarial_test.go): 008-full-test-coverage T024
// (spec.md FR-007) - closes the ONE genuinely-missing JWT adversarial
// case at the HTTP-enforcement (401) layer.
//
// Direct investigation this session (research.md R4 corrected -
// FR-007's stated cases are far more thoroughly covered than research.md
// assumed):
//   - internal/auth/jwt_test.go already unit-tests ValidateToken's
//     rejection of a tampered SIGNATURE (TestValidateToken_
//     RejectsTamperedSignature), a tampered PAYLOAD (TestValidateToken_
//     RejectsTamperedPayload), an EXPIRED token (TestValidateToken_
//     RejectsExpiredToken), a WRONG signing key (TestValidateToken_
//     RejectsWrongKey), and an alg=none attack (TestValidateToken_
//     RejectsAlgNone).
//   - internal/api/middleware_jwt_test.go already asserts, at the ACTUAL
//     HTTP-enforcement boundary (a real gin route behind RequireJWT
//     returning a real 401), a missing Authorization header
//     (TestRequireJWT_MissingHeaderRejectedWith401), a malformed token
//     (TestRequireJWT_MalformedTokenRejectedWith401), an expired token
//     (TestRequireJWT_ExpiredTokenRejectedWith401), and a
//     wrong-signing-key token - i.e. an invalid SIGNATURE
//     (TestRequireJWT_WrongKeyRejectedWith401).
//
// The one case FR-007 names ("a tampered payload, same signature") that
// existed only at the unit layer (ValidateToken returning an error) and
// was NEVER asserted at the HTTP 401 layer is added here, following
// jwt_test.go's own established tamper technique exactly (flip one byte
// of the base64url payload segment, leave header+signature untouched) so
// the SAME real, unmodified RequireJWT middleware this project ships is
// what is proven to reject it with 401 - never a new, parallel
// tampering mechanism.
package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/vasic-digital/llmctl/llmctld/internal/auth"
)

// flipByte returns b with its least-significant bit toggled - if that
// happens to reproduce the original byte for a byte with no low bit set,
// toggling twice is impossible here since flipByte is applied exactly
// once per call site, matching internal/auth/jwt_test.go's own flipByte
// helper's contract (a single-bit change is always sufficient to
// invalidate a base64url-decoded byte's meaning within its segment).
func flipByte(b byte) byte {
	return b ^ 0x01
}

// TestRequireJWT_TamperedPayloadRejectedWith401 proves that a token
// whose payload segment was altered AFTER issuance (the signature no
// longer covers the mutated bytes - e.g. an attacker trying to escalate
// Roles or switch TenantID post-issuance) is rejected with 401 by the
// REAL RequireJWT middleware wired onto a REAL gin route - the missing
// HTTP-enforcement-layer case identified by this feature's classification
// audit (docs/testing/TEST_TYPE_CLASSIFICATION.md, security row).
func TestRequireJWT_TamperedPayloadRejectedWith401(t *testing.T) {
	signingKey := []byte("test-signing-key")
	token := issueTestJWT(t, signingKey, "tenant-a", []string{"model-viewer"}, time.Now().Add(time.Hour))

	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("expected a 3-part JWT, got %d parts", len(parts))
	}
	payload := []byte(parts[1])
	payload[0] = flipByte(payload[0])
	tampered := strings.Join([]string{parts[0], string(payload), parts[2]}, ".")

	called := false
	engine := newProtectedTestEngine(testDecider(signingKey), func(_ *gin.Context, _ *auth.Claims) {
		called = true
	})

	req := httptest.NewRequest(http.MethodGet, "/protected", nil)
	req.Header.Set("Authorization", "Bearer "+tampered)
	rec := httptest.NewRecorder()
	engine.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for a tampered-payload token, got %d: %s", rec.Code, rec.Body.String())
	}
	if called {
		t.Fatal("expected the protected handler to never run for a tampered-payload token")
	}
}
