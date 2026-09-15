package auth

import (
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

var testSigningKey = []byte("test-signing-key-32-bytes-long!")

func newTestClaims() Claims {
	now := time.Now()
	return Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   "user-123",
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(time.Hour)),
		},
		TenantID: "tenant-a",
		Roles:    []string{"model-operator"},
	}
}

// TestIssueThenValidate_RoundTripsClaims proves a validly-issued token
// round-trips through IssueToken -> ValidateToken with every custom
// claim (TenantID, Roles) and registered claim (Subject) intact -
// FR-030's basic contract.
func TestIssueThenValidate_RoundTripsClaims(t *testing.T) {
	claims := newTestClaims()

	tokenString, err := IssueToken(claims, testSigningKey)
	if err != nil {
		t.Fatalf("IssueToken failed: %v", err)
	}
	if tokenString == "" {
		t.Fatal("IssueToken returned an empty token string")
	}

	got, err := ValidateToken(tokenString, testSigningKey)
	if err != nil {
		t.Fatalf("ValidateToken failed on a validly-issued token: %v", err)
	}

	if got.Subject != claims.Subject {
		t.Errorf("Subject = %q, want %q", got.Subject, claims.Subject)
	}
	if got.TenantID != claims.TenantID {
		t.Errorf("TenantID = %q, want %q", got.TenantID, claims.TenantID)
	}
	if len(got.Roles) != 1 || got.Roles[0] != "model-operator" {
		t.Errorf("Roles = %v, want [model-operator]", got.Roles)
	}
}

// TestValidateToken_RejectsTamperedSignature proves a token whose
// signature has been altered after issuance fails validation - a
// tampered token must never be accepted (FR-030).
func TestValidateToken_RejectsTamperedSignature(t *testing.T) {
	claims := newTestClaims()
	tokenString, err := IssueToken(claims, testSigningKey)
	if err != nil {
		t.Fatalf("IssueToken failed: %v", err)
	}

	parts := strings.Split(tokenString, ".")
	if len(parts) != 3 {
		t.Fatalf("expected a 3-part JWT, got %d parts", len(parts))
	}
	// Flip one character in the signature segment - any single-byte
	// mutation there must break the HMAC check.
	sig := []byte(parts[2])
	sig[0] = flipByte(sig[0])
	tampered := strings.Join([]string{parts[0], parts[1], string(sig)}, ".")

	if _, err := ValidateToken(tampered, testSigningKey); err == nil {
		t.Fatal("ValidateToken accepted a token with a tampered signature")
	}
}

// TestValidateToken_RejectsTamperedPayload proves a token whose payload
// segment has been altered after issuance (e.g. to escalate Roles)
// fails validation, since the signature no longer covers the mutated
// bytes.
func TestValidateToken_RejectsTamperedPayload(t *testing.T) {
	claims := newTestClaims()
	tokenString, err := IssueToken(claims, testSigningKey)
	if err != nil {
		t.Fatalf("IssueToken failed: %v", err)
	}

	parts := strings.Split(tokenString, ".")
	if len(parts) != 3 {
		t.Fatalf("expected a 3-part JWT, got %d parts", len(parts))
	}
	payload := []byte(parts[1])
	payload[0] = flipByte(payload[0])
	tampered := strings.Join([]string{parts[0], string(payload), parts[2]}, ".")

	if _, err := ValidateToken(tampered, testSigningKey); err == nil {
		t.Fatal("ValidateToken accepted a token with a tampered payload")
	}
}

// TestValidateToken_RejectsExpiredToken proves a token past its
// ExpiresAt fails validation (FR-030).
func TestValidateToken_RejectsExpiredToken(t *testing.T) {
	claims := newTestClaims()
	past := time.Now().Add(-time.Hour)
	claims.ExpiresAt = jwt.NewNumericDate(past)
	claims.IssuedAt = jwt.NewNumericDate(past.Add(-time.Minute))

	tokenString, err := IssueToken(claims, testSigningKey)
	if err != nil {
		t.Fatalf("IssueToken failed: %v", err)
	}

	if _, err := ValidateToken(tokenString, testSigningKey); err == nil {
		t.Fatal("ValidateToken accepted an expired token")
	}
}

// TestValidateToken_RejectsWrongKey proves a token signed with one key
// fails validation against a different key - the basic guarantee that
// makes the signing key meaningful at all (FR-030).
func TestValidateToken_RejectsWrongKey(t *testing.T) {
	claims := newTestClaims()
	tokenString, err := IssueToken(claims, testSigningKey)
	if err != nil {
		t.Fatalf("IssueToken failed: %v", err)
	}

	wrongKey := []byte("a-completely-different-key-value")
	if _, err := ValidateToken(tokenString, wrongKey); err == nil {
		t.Fatal("ValidateToken accepted a token against the wrong signing key")
	}
}

// TestValidateToken_RejectsAlgNone proves the parser refuses the
// classic "alg: none" JWT attack - a hand-crafted unsigned token must
// never be accepted regardless of what its own header claims.
func TestValidateToken_RejectsAlgNone(t *testing.T) {
	claims := newTestClaims()
	token := jwt.NewWithClaims(jwt.SigningMethodNone, claims)
	tokenString, err := token.SignedString(jwt.UnsafeAllowNoneSignatureType)
	if err != nil {
		t.Fatalf("failed to construct alg=none token fixture: %v", err)
	}

	if _, err := ValidateToken(tokenString, testSigningKey); err == nil {
		t.Fatal("ValidateToken accepted an alg=none token")
	}
}

func flipByte(b byte) byte {
	if b == 'A' {
		return 'B'
	}
	return 'A'
}
