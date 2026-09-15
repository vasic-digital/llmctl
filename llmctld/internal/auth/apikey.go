package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"sync"
	"time"
)

// secretByteLength is the raw entropy of a generated API key secret
// before base64 encoding. 32 bytes (256 bits) matches this project's
// existing security posture for generated secrets (see
// internal/tenancy.DeriveKey's 32-byte AES-256 keys) and is far beyond
// brute-force range for a bearer credential.
const secretByteLength = 32

// APIKey is a single API key's metadata. The plaintext secret is never
// stored here or anywhere else after Create/Rotate return it to the
// caller - only SecretHash (a SHA-256 digest) is persisted, matching
// this project's established credential-handling pattern (T064's
// per-tenant encryption, T049's mTLS CA-chain verification never
// storing raw key material where it doesn't have to).
type APIKey struct {
	ID         string
	OwnerID    string
	Scopes     []string
	SecretHash string
	CreatedAt  time.Time
	// ExpiresAt is the zero time.Time when the key never expires - a
	// caller passing ttl==0 to Create gets a key with no forced
	// expiry, never a silently-invented default (Constitution
	// §11.4.6), matching CheckpointConfig's documented
	// zero-means-disabled pattern in internal/replication/checkpoint.go.
	ExpiresAt time.Time
	Revoked   bool
}

// Store is an in-memory API key store: create/rotate/expire/scope for
// users and service accounts (FR-032). A real backing store is out of
// scope for this task (tasks.md T067's file list names only
// apikey.go/apikey_test.go) - Store's map+mutex design is deliberately
// swappable behind the same method set if that scope grows later.
type Store struct {
	mu   sync.Mutex
	keys map[string]*APIKey
}

// NewKeyStore returns an empty, ready-to-use Store.
func NewKeyStore() *Store {
	return &Store{keys: make(map[string]*APIKey)}
}

// Create generates a new API key for ownerID (a user or service-account
// identifier - Store treats both identically, distinguished only by
// whatever string the caller supplies) with the given scopes, and
// returns the key's id plus its ONE-TIME plaintext secret. ttl==0 means
// the key never expires; a positive ttl sets ExpiresAt = now+ttl; a
// negative ttl (used by tests to construct an already-expired fixture,
// and legitimate for a caller backdating an expiry) sets ExpiresAt in
// the past.
//
// The plaintext secret is generated via crypto/rand (never math/rand -
// this is a security-sensitive credential) and is returned to the
// caller exactly once; only its SHA-256 hash is persisted in the
// returned key's record.
func (s *Store) Create(ownerID string, scopes []string, ttl time.Duration) (id string, plaintextSecret string, err error) {
	id, err = randomID()
	if err != nil {
		return "", "", fmt.Errorf("auth: generate key id: %w", err)
	}
	plaintextSecret, err = randomSecret()
	if err != nil {
		return "", "", fmt.Errorf("auth: generate key secret: %w", err)
	}

	now := time.Now()
	var expiresAt time.Time
	if ttl != 0 {
		expiresAt = now.Add(ttl)
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.keys[id] = &APIKey{
		ID:         id,
		OwnerID:    ownerID,
		Scopes:     scopes,
		SecretHash: hashSecret(plaintextSecret),
		CreatedAt:  now,
		ExpiresAt:  expiresAt,
	}
	return id, plaintextSecret, nil
}

// Validate returns the APIKey for id if plaintextSecret matches its
// stored hash and the key is neither revoked nor expired. It fails
// closed for every other case: unknown id, wrong secret, revoked key,
// or expired key.
func (s *Store) Validate(id, plaintextSecret string) (*APIKey, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	key, ok := s.keys[id]
	if !ok {
		return nil, errors.New("auth: unknown API key id")
	}
	if key.Revoked {
		return nil, errors.New("auth: API key has been revoked")
	}
	if !key.ExpiresAt.IsZero() && time.Now().After(key.ExpiresAt) {
		return nil, errors.New("auth: API key has expired")
	}
	if subtle.ConstantTimeCompare([]byte(hashSecret(plaintextSecret)), []byte(key.SecretHash)) != 1 {
		return nil, errors.New("auth: invalid API key secret")
	}
	return key, nil
}

// Rotate generates a NEW plaintext secret for the SAME key id,
// overwriting the stored hash so the old secret is immediately rejected
// by Validate (FR-032's literal requirement) - rotation changes the
// credential, not the key's identity, scopes, or expiry.
func (s *Store) Rotate(id string) (newPlaintextSecret string, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	key, ok := s.keys[id]
	if !ok {
		return "", errors.New("auth: unknown API key id")
	}

	newPlaintextSecret, err = randomSecret()
	if err != nil {
		return "", fmt.Errorf("auth: generate rotated key secret: %w", err)
	}
	key.SecretHash = hashSecret(newPlaintextSecret)
	return newPlaintextSecret, nil
}

// Revoke marks id as revoked; every subsequent Validate call against it
// fails, regardless of whether the secret presented is still correct.
func (s *Store) Revoke(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	key, ok := s.keys[id]
	if !ok {
		return errors.New("auth: unknown API key id")
	}
	key.Revoked = true
	return nil
}

// randomID generates a URL-safe, high-entropy key id via crypto/rand -
// distinct from the secret itself so a leaked id (e.g. in a log line)
// never on its own discloses anything usable for authentication.
func randomID() (string, error) {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}

// randomSecret generates the high-entropy plaintext API key secret.
func randomSecret() (string, error) {
	buf := make([]byte, secretByteLength)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}

// hashSecret returns the persisted form of a plaintext secret - SHA-256
// is sufficient here because the input is already a high-entropy
// crypto/rand-generated value (not a low-entropy human password needing
// a slow KDF like bcrypt/scrypt/argon2 to resist brute force).
func hashSecret(plaintextSecret string) string {
	sum := sha256.Sum256([]byte(plaintextSecret))
	return hex.EncodeToString(sum[:])
}
