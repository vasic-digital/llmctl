// Package auth implements llmctld's built-in authentication, authorization,
// and multi-tenancy layer (Phase 11, US9): JWT issuance/validation
// (jwt.go), role-based access control (rbac.go), and API key lifecycle
// (apikey.go).
package auth

import (
	"errors"
	"fmt"

	"github.com/golang-jwt/jwt/v5"
)

// Claims embeds jwt.RegisteredClaims (exp/iat/sub/etc.) plus the two
// llmctld-specific fields RBAC (rbac.go) and multi-tenancy consume:
// TenantID scopes a request to one tenant's resources, Roles is the set
// of role names Check (rbac.go) evaluates against. Both fields travel
// inside the signed token, never derived from an unsigned side-channel.
type Claims struct {
	jwt.RegisteredClaims
	TenantID string   `json:"tenant_id,omitempty"`
	Roles    []string `json:"roles,omitempty"`
}

// signingMethod is fixed to HS256 (symmetric HMAC), matching the
// project's documented deployment model: .env.example's
// LLMCTLD_JWT_SIGNING_KEY is generated via `openssl rand -base64 32` - a
// symmetric secret, not an asymmetric keypair - so RS256/ES256
// infrastructure would be unused scope this task never asked for.
var signingMethod = jwt.SigningMethodHS256

// IssueToken signs claims with signingKey using HS256 and returns the
// compact JWT string. Callers are expected to have already populated
// claims.RegisteredClaims.ExpiresAt (and any other registered claims);
// IssueToken does not invent an expiry - a token issued with no
// ExpiresAt never expires, which is the caller's explicit choice, not a
// silently-guessed default (Constitution §11.4.6).
func IssueToken(claims Claims, signingKey []byte) (string, error) {
	token := jwt.NewWithClaims(signingMethod, claims)
	signed, err := token.SignedString(signingKey)
	if err != nil {
		return "", fmt.Errorf("auth: sign token: %w", err)
	}
	return signed, nil
}

// ValidateToken parses and validates tokenString against signingKey,
// returning the embedded Claims on success.
//
// The parser is pinned to WithValidMethods([]string{"HS256"}) so it
// NEVER trusts the token's own "alg" header to pick the verification
// algorithm - accepting an attacker-chosen alg (including "none") is a
// well-known JWT vulnerability class, and jwt/v5's keyfunc-based API
// makes that mistake easy to make by omission. Any of the following
// fails validation: bad/missing signature, expired token (jwt/v5
// enforces exp automatically when present), malformed token structure,
// or a token signed with a key other than signingKey.
func ValidateToken(tokenString string, signingKey []byte) (*Claims, error) {
	claims := &Claims{}
	token, err := jwt.ParseWithClaims(tokenString, claims, func(t *jwt.Token) (interface{}, error) {
		return signingKey, nil
	}, jwt.WithValidMethods([]string{signingMethod.Alg()}))
	if err != nil {
		return nil, fmt.Errorf("auth: validate token: %w", err)
	}
	if !token.Valid {
		return nil, errors.New("auth: token is not valid")
	}
	return claims, nil
}
