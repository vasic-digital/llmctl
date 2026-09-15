package auth

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
)

// oidcFallbackWindow is the literal "5-minute local-auth fallback
// cache" duration this task names explicitly (Clarification 24,
// FR-055) - unlike the zero-means-unlimited numeric defaults elsewhere
// in this package (apikey.go's ExpiresAt, tenancy.Limits), 5 minutes
// is not a guessed value: it is the one concrete number the spec
// itself states, so it is hardcoded rather than left caller-
// configurable.
const oidcFallbackWindow = 5 * time.Minute

// ErrOIDCFallbackExpired is returned by Authenticate specifically when
// the 5-minute fallback cache has expired WHILE the OIDC provider
// remains unreachable (Clarification 24's literal scenario) - denying
// the request per FR-055 rather than extending the cache indefinitely.
// It is DISTINCT from the plain wrapped error Authenticate returns
// when no cache entry exists at all (either because the token was
// never successfully verified, or because it was genuinely rejected
// as invalid): a caller wiring this into an HTTP layer maps both to a
// 401, but errors.Is against ErrOIDCFallbackExpired lets it log or
// meter "OIDC outage denial" separately from "invalid credential
// denial" - operationally, "is OIDC down?" and "is this token bad?"
// are different questions an operator needs to answer differently.
var ErrOIDCFallbackExpired = errors.New("auth: OIDC provider unavailable and the 5-minute local-auth fallback cache has expired")

// TokenVerifierFunc verifies a raw OIDC ID token and returns the
// subject claim identifying the authenticated principal. It is a
// plain function type - not an interface - specifically so tests can
// inject a canned success or a canned "provider unreachable" failure
// without a real running IdP (FR-036 explicitly scopes OIDC as
// optional, no external IdP dependency, so this package cannot assume
// one is available even for its own tests). NewRealVerifier
// constructs the real go-oidc/v3-backed implementation of this type;
// NewOIDCAuthenticator accepts either.
type TokenVerifierFunc func(ctx context.Context, rawIDToken string) (subject string, err error)

// cachedVerification is one successfully-verified token's fallback
// record: the subject it resolved to, and the moment (per the caller-
// supplied "now", never time.Now() - see Authenticate) that
// verification succeeded. A fresh entry's age is measured from THIS
// timestamp, not from the ID token's own issuance time - the fallback
// window bounds how long llmctld will keep trusting its OWN last
// successful check of the provider, which is the actual outage-
// bridging guarantee FR-055 describes.
type cachedVerification struct {
	subject    string
	verifiedAt time.Time
	// tokenExpiresAt is the cached raw ID token's OWN "exp" claim, parsed
	// (never re-verified - see parseJWTExpiry's doc comment) at the moment
	// it was successfully verified. Zero when the raw token's own expiry
	// could not be determined (an unparseable non-JWT-shaped string, which
	// never occurs for a real OIDC provider's output since it must pass
	// real signature+claims verification to reach the cache at all) - a
	// zero value means "unknown", so the fallback eligibility check below
	// falls back to cache-freshness alone rather than inventing a denial
	// it cannot prove (Constitution §11.4.6).
	//
	// Added per T075's security review: WITHOUT this field, the fallback
	// window bridged an OIDC PROVIDER OUTAGE by trusting cache-freshness
	// alone, which also silently extended a legitimately-issued token's
	// USABLE life by up to oidcFallbackWindow past its own stated expiry,
	// entirely independent of whether the provider was actually
	// unreachable (see TestAuthenticate_FreshCacheEntryButTokenPastItsOwnExpClaim_Denied).
	tokenExpiresAt time.Time
}

// parseJWTExpiry extracts the "exp" claim from a raw JWT's payload segment
// WITHOUT verifying its signature - safe here ONLY because this is called
// exclusively on a rawIDToken that a.verify has JUST successfully verified
// (real signature + claims check) moments earlier in the SAME call to
// Authenticate; this function never makes a trust decision on its own, it
// only extracts a claim from an already-trusted token for the fallback
// cache's own bookkeeping. Returns ok=false for anything that is not a
// well-formed three-segment JWT with a numeric "exp" claim (a real OIDC ID
// token always is one; this package's own unit tests use non-JWT
// placeholder strings for cases where the exp check must not apply -
// see TestAuthenticate_ProviderDown_FreshCacheEntry_NonJWTToken_StillFallsBack).
func parseJWTExpiry(rawToken string) (time.Time, bool) {
	parts := strings.Split(rawToken, ".")
	if len(parts) != 3 {
		return time.Time{}, false
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return time.Time{}, false
	}
	var claims struct {
		Exp int64 `json:"exp"`
	}
	if err := json.Unmarshal(payload, &claims); err != nil || claims.Exp == 0 {
		return time.Time{}, false
	}
	return time.Unix(claims.Exp, 0), true
}

// OIDCAuthenticator wraps a TokenVerifierFunc with the 5-minute local-
// auth fallback cache FR-055/Clarification 24 mandates: while the
// verifier succeeds, every result is cached; when the verifier fails,
// a still-fresh cached result for the SAME raw token is served instead
// of denying the request outright, and once that cache entry goes
// stale (or never existed) the request is denied.
type OIDCAuthenticator struct {
	mu     sync.Mutex
	verify TokenVerifierFunc
	cache  map[string]cachedVerification
}

// NewOIDCAuthenticator returns an OIDCAuthenticator backed by verify.
// It takes no discovery-URL/client-ID configuration itself - that
// concern belongs to NewRealVerifier, which produces the
// TokenVerifierFunc this constructor is handed. Keeping the two
// separate is what makes the cache/fallback state machine (the part
// tasks.md's T068 acceptance criteria actually exercise) unit-testable
// without a running OIDC IdP.
func NewOIDCAuthenticator(verify TokenVerifierFunc) *OIDCAuthenticator {
	return &OIDCAuthenticator{
		verify: verify,
		cache:  make(map[string]cachedVerification),
	}
}

// Authenticate verifies rawIDToken, taking now as an explicit
// parameter (never time.Now() internally) so tests can drive the
// 5-minute fallback window deterministically without real sleeping -
// the same pattern internal/tenancy/quota.go's AllowRequest(tenantID,
// now) already establishes in this codebase.
//
// On a successful verifier call, the result is cached (keyed by a
// SHA-256 hash of rawIDToken, not the raw token itself - matching this
// package's established credential-hygiene convention in apikey.go of
// never holding a bearer credential in memory longer than the hash
// needs to, even though this cache is transient and in-process) and
// the subject is returned.
//
// On a FAILED verifier call, Authenticate falls back to the cached
// entry for this exact token IF one exists and is within
// oidcFallbackWindow of its last successful verification; otherwise it
// denies the request. Design decision, documented here because neither
// spec.md nor tasks.md's T068 text makes it explicit: Authenticate
// does NOT branch this fallback decision on WHAT KIND of error the
// verifier returned (e.g. "provider unreachable" vs. "token rejected
// as invalid"). Two reasons: (1) go-oidc/v3's real
// IDTokenVerifier.Verify returns plain fmt.Errorf-wrapped errors with
// no exported sentinel distinguishing a network/outage failure from a
// signature/expiry rejection, so reliably telling them apart would
// require guessing at error-string shapes (Constitution §11.4.6
// forbids exactly that kind of guess); (2) the fallback decision is
// already keyed on the EXACT raw token AND gated by cache freshness -
// a token that was never successfully verified, or was verified but
// the cache has since gone stale, is denied either way, so a
// genuinely-invalid token can only ever "succeed via fallback" if it
// was ALSO successfully verified within the last 5 minutes, which
// contradicts it being invalid. The narrower, safer invariant - only a
// SUCCESSFUL verification ever writes to the cache - is what actually
// prevents a rejected token from being laundered through a stale
// fallback, and that invariant holds regardless of failure-kind
// branching.
func (a *OIDCAuthenticator) Authenticate(ctx context.Context, rawIDToken string, now time.Time) (string, error) {
	subject, err := a.verify(ctx, rawIDToken)
	key := cacheKey(rawIDToken)

	if err == nil {
		tokenExpiresAt, _ := parseJWTExpiry(rawIDToken)
		a.mu.Lock()
		a.cache[key] = cachedVerification{subject: subject, verifiedAt: now, tokenExpiresAt: tokenExpiresAt}
		a.mu.Unlock()
		return subject, nil
	}

	a.mu.Lock()
	cached, ok := a.cache[key]
	a.mu.Unlock()

	if !ok {
		return "", fmt.Errorf("auth: OIDC verification failed and no cached identity is available for fallback: %w", err)
	}

	if now.Sub(cached.verifiedAt) > oidcFallbackWindow {
		return "", fmt.Errorf("%w (verifier error was: %v)", ErrOIDCFallbackExpired, err)
	}

	// Even within the cache-freshness window, the fallback MUST NOT extend
	// the token's own usable life past its own "exp" claim - the fallback
	// bridges a PROVIDER OUTAGE, it never overrides the token's own stated
	// expiry (T075 security review; see cachedVerification.tokenExpiresAt's
	// doc comment). A zero tokenExpiresAt means "could not be determined",
	// so this check is skipped rather than inventing an unprovable denial.
	if !cached.tokenExpiresAt.IsZero() && now.After(cached.tokenExpiresAt) {
		return "", fmt.Errorf("auth: OIDC fallback denied: the cached token's own expiry (%s) has passed (verifier error was: %v)", cached.tokenExpiresAt, err)
	}

	return cached.subject, nil
}

// cacheKey derives the fallback cache's map key from a raw ID token.
func cacheKey(rawIDToken string) string {
	sum := sha256.Sum256([]byte(rawIDToken))
	return hex.EncodeToString(sum[:])
}

// NewRealVerifier constructs a TokenVerifierFunc backed by a genuine
// go-oidc/v3 provider discovery + ID-token verification against a real
// OIDC identity provider at issuerURL, checking the token's audience
// against clientID.
//
// SCOPE BOUNDARY (documented per this project's established pattern,
// e.g. T060's checkpoint.go on its own real-engine integration gap):
// this package's tests do NOT exercise the SUCCESS path of this
// function end-to-end, because doing so genuinely requires a running
// OIDC identity provider to discover (oidc.NewProvider performs a real
// HTTP GET against "<issuerURL>/.well-known/openid-configuration") and
// to issue real signed ID tokens against - and FR-036 explicitly scopes
// OIDC integration as "optional, no external IdP dependency", meaning
// this project has no IdP configured or vendored to test against. The
// ONE part of this function this package's tests DO exercise directly
// is its error path: oidc.NewProvider's discovery HTTP call genuinely
// fails against an unreachable/malformed issuer URL (a real closed
// port, not a mock), which is real, deterministic, network-independent-
// of-any-specific-IdP behavior. The returned closure's OWN correctness
// (that it extracts the right subject from a real verified token) is
// exercised instead by OIDCAuthenticator's tests via the injectable
// TokenVerifierFunc fake, which is why TokenVerifierFunc is a function
// type rather than requiring callers to depend on a concrete go-oidc/v3
// type throughout this package.
func NewRealVerifier(ctx context.Context, issuerURL, clientID string) (TokenVerifierFunc, error) {
	provider, err := oidc.NewProvider(ctx, issuerURL)
	if err != nil {
		return nil, fmt.Errorf("auth: discover OIDC provider at %q: %w", issuerURL, err)
	}

	verifier := provider.Verifier(&oidc.Config{ClientID: clientID})

	return func(ctx context.Context, rawIDToken string) (string, error) {
		idToken, err := verifier.Verify(ctx, rawIDToken)
		if err != nil {
			return "", fmt.Errorf("auth: verify OIDC ID token: %w", err)
		}
		return idToken.Subject, nil
	}, nil
}
