package auth

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"testing"
	"time"
)

// errUnreachable and errInvalidToken are two DIFFERENT shapes of
// verifier failure used across these tests: errUnreachable stands in
// for "the OIDC provider could not be reached" (a network/outage
// failure - the case FR-055/Clarification 24 names), errInvalidToken
// stands in for "the provider was reached and genuinely rejected this
// token" (a plain validation failure, e.g. bad signature or expired
// token). See Authenticate's doc comment for why this package
// deliberately does NOT branch its fallback behavior on which of these
// two a TokenVerifierFunc returns.
var (
	errUnreachable  = errors.New("oidc: provider unreachable: dial tcp: connection refused")
	errInvalidToken = errors.New("oidc: id token signature invalid: crypto/rsa: verification error")
)

// fakeVerifier returns a TokenVerifierFunc that always returns
// (subject, err) for any raw token - a stand-in for the real go-oidc/v3
// call so these tests never need a running IdP.
func fakeVerifier(subject string, err error) TokenVerifierFunc {
	return func(_ context.Context, _ string) (string, error) {
		return subject, err
	}
}

// TestAuthenticate_SuccessfulVerification_ReturnsSubjectAndPopulatesCache
// proves the basic success path: a verifier call that succeeds returns
// the subject and (implicitly, per subsequent tests) becomes available
// for fallback.
func TestAuthenticate_SuccessfulVerification_ReturnsSubjectAndPopulatesCache(t *testing.T) {
	authr := NewOIDCAuthenticator(fakeVerifier("user-42", nil))

	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	subject, err := authr.Authenticate(context.Background(), "raw-id-token-1", now)
	if err != nil {
		t.Fatalf("Authenticate failed on a successful verification: %v", err)
	}
	if subject != "user-42" {
		t.Errorf("subject = %q, want %q", subject, "user-42")
	}
}

// TestAuthenticate_ProviderDown_FreshCacheEntry_FallsBackSuccessfully
// proves the literal T068/FR-055 fallback path: once a token has been
// successfully verified, a LATER verifier failure for the SAME token,
// while the cached entry is still within the 5-minute window, must
// fall back to the cached subject rather than denying the request.
func TestAuthenticate_ProviderDown_FreshCacheEntry_FallsBackSuccessfully(t *testing.T) {
	// callCount lets one authenticator's verifier succeed on the first
	// call (to populate the cache) and fail on every call after that
	// (simulating the provider going down immediately afterward).
	callCount := 0
	authr := NewOIDCAuthenticator(func(_ context.Context, _ string) (string, error) {
		callCount++
		if callCount == 1 {
			return "user-42", nil
		}
		return "", errUnreachable
	})

	t0 := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	if _, err := authr.Authenticate(context.Background(), "raw-id-token-1", t0); err != nil {
		t.Fatalf("initial successful verification failed: %v", err)
	}

	// 1 minute later - well within the 5-minute fallback window - the
	// provider is down (callCount > 1) but the cached entry is fresh.
	oneMinuteLater := t0.Add(1 * time.Minute)
	subject, err := authr.Authenticate(context.Background(), "raw-id-token-1", oneMinuteLater)
	if err != nil {
		t.Fatalf("Authenticate should have fallen back to the fresh cache entry, got error: %v", err)
	}
	if subject != "user-42" {
		t.Errorf("fallback subject = %q, want %q", subject, "user-42")
	}
}

// TestAuthenticate_ProviderDown_CacheExpired_Denied is the literal
// T068/FR-055/Clarification 24 acceptance requirement: once the
// 5-minute fallback cache has expired WHILE the provider is still
// unreachable, the request MUST be denied (mapped by callers to HTTP
// 401) rather than extending the cache indefinitely.
func TestAuthenticate_ProviderDown_CacheExpired_Denied(t *testing.T) {
	callCount := 0
	authr := NewOIDCAuthenticator(func(_ context.Context, _ string) (string, error) {
		callCount++
		if callCount == 1 {
			return "user-42", nil
		}
		return "", errUnreachable
	})

	t0 := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	if _, err := authr.Authenticate(context.Background(), "raw-id-token-1", t0); err != nil {
		t.Fatalf("initial successful verification failed: %v", err)
	}

	// 6 minutes later - past the 5-minute fallback window - the
	// provider is still down. This MUST be denied, not served from a
	// stale cache entry.
	sixMinutesLater := t0.Add(6 * time.Minute)
	subject, err := authr.Authenticate(context.Background(), "raw-id-token-1", sixMinutesLater)
	if err == nil {
		t.Fatalf("expected denial once the fallback cache expired, got subject %q with no error", subject)
	}
	if !errors.Is(err, ErrOIDCFallbackExpired) {
		t.Errorf("error = %v, want it to match ErrOIDCFallbackExpired via errors.Is", err)
	}
}

// TestAuthenticate_ProviderDown_NoCacheEntry_DeniedOutright proves a
// verifier failure for a token that was NEVER successfully verified
// (so no cache entry exists at all) is denied immediately - there is
// nothing to fall back to. The returned error must be distinguishable
// from ErrOIDCFallbackExpired: this is "never verified", not "fallback
// window expired" - a caller wiring this into metrics/logging needs to
// tell those two denial reasons apart even though both currently map
// to the same HTTP 401.
func TestAuthenticate_ProviderDown_NoCacheEntry_DeniedOutright(t *testing.T) {
	authr := NewOIDCAuthenticator(fakeVerifier("", errUnreachable))

	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	subject, err := authr.Authenticate(context.Background(), "never-seen-before-token", now)
	if err == nil {
		t.Fatalf("expected denial with no cache entry, got subject %q with no error", subject)
	}
	if errors.Is(err, ErrOIDCFallbackExpired) {
		t.Error("a never-cached token's denial must NOT match ErrOIDCFallbackExpired - there was no fallback window to expire")
	}
}

// TestAuthenticate_InvalidToken_DeniedAndNeverCached proves two things
// at once: (1) a genuinely-invalid token (the provider was reached and
// rejected it, not "unreachable") is denied, and (2) a FAILED
// verification - regardless of which failure shape it is - never
// populates the cache. If it did, a since-rejected token could later
// succeed via stale "fallback" during the 5-minute window, which is
// not what Clarification 24 describes (the cache exists to bridge an
// OUTAGE for an identity that was genuinely verified once, not to
// remember a token as valid after a rejection).
//
// See Authenticate's doc comment for why this package does not
// attempt to distinguish "unreachable" from "invalid" verifier
// failures when deciding whether to consult the fallback cache - both
// this test and TestAuthenticate_ProviderDown_NoCacheEntry_DeniedOutright
// exercise the SAME "no fresh cache entry -> deny" code path, one via
// an "unreachable"-shaped error and one via an "invalid"-shaped error,
// to prove the denial path does not accidentally depend on the error's
// wording.
func TestAuthenticate_InvalidToken_DeniedAndNeverCached(t *testing.T) {
	authr := NewOIDCAuthenticator(fakeVerifier("", errInvalidToken))

	now := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	if _, err := authr.Authenticate(context.Background(), "genuinely-invalid-token", now); err == nil {
		t.Fatal("expected denial for a genuinely invalid token")
	}

	// Immediately afterward (well within any fallback window, if one
	// had been created), the SAME token must still be denied - proving
	// the failed verification above did not populate the cache.
	if _, err := authr.Authenticate(context.Background(), "genuinely-invalid-token", now); err == nil {
		t.Fatal("a failed verification must never populate the fallback cache")
	}
}

// TestAuthenticate_DifferentTokens_HaveIndependentCacheEntries proves
// the fallback cache is keyed per-token: a fresh cache entry for one
// token must not be usable as a fallback for a different token whose
// own verification just failed.
func TestAuthenticate_DifferentTokens_HaveIndependentCacheEntries(t *testing.T) {
	authr := NewOIDCAuthenticator(func(_ context.Context, raw string) (string, error) {
		if raw == "token-a" {
			return "user-a", nil
		}
		return "", errUnreachable
	})

	t0 := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	if _, err := authr.Authenticate(context.Background(), "token-a", t0); err != nil {
		t.Fatalf("verifying token-a failed: %v", err)
	}

	// token-b was never successfully verified, so its own failure must
	// deny outright, never borrowing token-a's cache entry.
	if _, err := authr.Authenticate(context.Background(), "token-b", t0.Add(1*time.Minute)); err == nil {
		t.Fatal("token-b must not fall back using token-a's cache entry")
	}
}

// fakeJWTWithExpiry builds a realistic JWT-SHAPED (three dot-separated
// base64url segments) raw ID token whose payload segment carries only an
// "exp" claim set to exp.Unix() - enough for parseJWTExpiry to extract,
// without needing a real signature (the fallback-cache logic under test
// here never re-verifies the signature; a REAL raw ID token from a genuine
// OIDC provider is always at least this JWT-shaped, since it must pass
// go-oidc's own real signature+claims verification to ever populate the
// cache in the first place).
func fakeJWTWithExpiry(exp time.Time) string {
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none","typ":"JWT"}`))
	payload := base64.RawURLEncoding.EncodeToString([]byte(fmt.Sprintf(`{"exp":%d}`, exp.Unix())))
	return header + "." + payload + ".signature"
}

// TestAuthenticate_FreshCacheEntryButTokenPastItsOwnExpClaim_Denied is
// T075's RED-before-GREEN proof for a genuine security weakening found
// during this security review: the 5-minute fallback cache (FR-055,
// Clarification 24) is meant to bridge an OIDC PROVIDER OUTAGE by trusting
// a recently-successful verification - but as originally implemented, it
// consulted ONLY cache-freshness (verifiedAt within the last 5 minutes),
// never the cached token's OWN "exp" claim. That let a legitimately
// short-lived ID token (e.g. a 30-second-lived token, issued deliberately
// short to bound the blast radius of theft) be replayed successfully via
// fallback for up to 5 EXTRA minutes past its own stated expiry - entirely
// independent of whether the OIDC provider was actually unreachable, since
// Authenticate's fallback branch fires on ANY verifier failure, including
// the ordinary, expected "token expired" rejection a fully healthy,
// fully-reachable provider would correctly return. This directly weakens
// the token's own security boundary rather than merely bridging an
// outage. This test proves a token whose own exp claim has passed is
// DENIED even while comfortably within the 5-minute cache-freshness
// window.
func TestAuthenticate_FreshCacheEntryButTokenPastItsOwnExpClaim_Denied(t *testing.T) {
	t0 := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	rawToken := fakeJWTWithExpiry(t0.Add(30 * time.Second))

	callCount := 0
	authr := NewOIDCAuthenticator(func(_ context.Context, _ string) (string, error) {
		callCount++
		if callCount == 1 {
			return "user-42", nil
		}
		return "", errUnreachable
	})

	if _, err := authr.Authenticate(context.Background(), rawToken, t0); err != nil {
		t.Fatalf("initial successful verification failed: %v", err)
	}

	// 1 minute later: well within the 5-minute cache-freshness window, but
	// PAST the token's own 30-second exp claim - and the provider is
	// (simulated) unreachable, so a real healthy provider would ALSO have
	// rejected this exact replay as expired.
	oneMinuteLater := t0.Add(1 * time.Minute)
	if subject, err := authr.Authenticate(context.Background(), rawToken, oneMinuteLater); err == nil {
		t.Fatalf("SECURITY WEAKENING: fallback served a token %v past its own exp claim, subject=%q (want denial)", oneMinuteLater.Sub(t0.Add(30*time.Second)), subject)
	}
}

// TestAuthenticate_ProviderDown_FreshCacheEntry_NonJWTToken_StillFallsBack
// proves the exp-claim check is additive, not a regression: a raw token
// that does not parse as a JWT (this package's OTHER fallback tests all
// use plain placeholder strings like "raw-id-token-1", never a real OIDC
// provider's output) still falls back exactly as before - the exp check
// only takes effect when it CAN determine the token's own expiry; it never
// invents a denial it cannot prove.
func TestAuthenticate_ProviderDown_FreshCacheEntry_NonJWTToken_StillFallsBack(t *testing.T) {
	callCount := 0
	authr := NewOIDCAuthenticator(func(_ context.Context, _ string) (string, error) {
		callCount++
		if callCount == 1 {
			return "user-42", nil
		}
		return "", errUnreachable
	})

	t0 := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	if _, err := authr.Authenticate(context.Background(), "not-a-jwt-shaped-token", t0); err != nil {
		t.Fatalf("initial successful verification failed: %v", err)
	}

	subject, err := authr.Authenticate(context.Background(), "not-a-jwt-shaped-token", t0.Add(1*time.Minute))
	if err != nil {
		t.Fatalf("expected a non-JWT-shaped token (unknown expiry) to still fall back on cache-freshness alone, got error: %v", err)
	}
	if subject != "user-42" {
		t.Errorf("fallback subject = %q, want %q", subject, "user-42")
	}
}

// TestNewRealVerifier_UnreachableIssuer_ReturnsError proves the real
// go-oidc/v3 wiring's error path without requiring a running OIDC
// IdP: oidc.NewProvider performs a genuine HTTP discovery request
// against "<issuer>/.well-known/openid-configuration", so pointing it
// at an address nothing listens on genuinely fails. This is the ONE
// part of NewRealVerifier this package tests directly - see
// NewRealVerifier's doc comment for why the success path (a real
// token verified against a real IdP) is out of this package's test
// scope.
func TestNewRealVerifier_UnreachableIssuer_ReturnsError(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Port 1 is a privileged, essentially-never-listening TCP port on
	// the loopback interface - a real closed port, not a mock.
	_, err := NewRealVerifier(ctx, "http://127.0.0.1:1/nonexistent", "test-client-id")
	if err == nil {
		t.Fatal("NewRealVerifier succeeded against an unreachable issuer URL")
	}
}
