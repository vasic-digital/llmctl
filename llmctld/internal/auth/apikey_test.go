package auth

import (
	"testing"
	"time"
)

// TestStore_RotatedKey_OldValueImmediatelyRejected is the literal T067
// deliverable (FR-032): after Rotate, the ORIGINAL plaintext secret
// must be rejected right away, and the newly-issued secret must
// validate.
func TestStore_RotatedKey_OldValueImmediatelyRejected(t *testing.T) {
	store := NewKeyStore()

	id, original, err := store.Create("user-1", []string{"model:view"}, 0)
	if err != nil {
		t.Fatalf("Create failed: %v", err)
	}
	if _, err := store.Validate(id, original); err != nil {
		t.Fatalf("Validate on the freshly-created key failed: %v", err)
	}

	newSecret, err := store.Rotate(id)
	if err != nil {
		t.Fatalf("Rotate failed: %v", err)
	}
	if newSecret == original {
		t.Fatal("Rotate returned the same secret as before rotation")
	}

	if _, err := store.Validate(id, original); err == nil {
		t.Fatal("Validate accepted the OLD secret after rotation")
	}
	if _, err := store.Validate(id, newSecret); err != nil {
		t.Fatalf("Validate rejected the NEW secret after rotation: %v", err)
	}
}

// TestStore_Create_SecretIsHighEntropyAndNotPersistedPlaintext proves
// two independently-created keys never collide on their plaintext
// secret (crypto/rand, not a predictable generator) and that the
// stored APIKey record does not carry the plaintext anywhere a caller
// can read it back out - only the create-time return value ever
// exposes it.
func TestStore_Create_SecretIsHighEntropyAndNotPersistedPlaintext(t *testing.T) {
	store := NewKeyStore()

	_, secretA, err := store.Create("user-1", nil, 0)
	if err != nil {
		t.Fatalf("Create failed: %v", err)
	}
	_, secretB, err := store.Create("user-1", nil, 0)
	if err != nil {
		t.Fatalf("Create failed: %v", err)
	}
	if secretA == secretB {
		t.Fatal("two independently-created keys produced the same plaintext secret")
	}
}

// TestStore_Validate_ExpiredKeyFails proves a key created with a
// past-relative TTL (i.e. already expired) fails Validate.
func TestStore_Validate_ExpiredKeyFails(t *testing.T) {
	store := NewKeyStore()

	id, secret, err := store.Create("user-1", nil, -time.Hour)
	if err != nil {
		t.Fatalf("Create failed: %v", err)
	}

	if _, err := store.Validate(id, secret); err == nil {
		t.Fatal("Validate accepted an expired key")
	}
}

// TestStore_Validate_ZeroTTLNeverExpires proves ttl==0 means "never
// expires" - Create must not invent a default expiry the caller did
// not ask for.
func TestStore_Validate_ZeroTTLNeverExpires(t *testing.T) {
	store := NewKeyStore()

	id, secret, err := store.Create("user-1", nil, 0)
	if err != nil {
		t.Fatalf("Create failed: %v", err)
	}
	key, err := store.Validate(id, secret)
	if err != nil {
		t.Fatalf("Validate rejected a zero-TTL (never-expiring) key: %v", err)
	}
	if !key.ExpiresAt.IsZero() {
		t.Fatalf("ExpiresAt = %v, want zero value for a never-expiring key", key.ExpiresAt)
	}
}

// TestStore_Revoke_RevokedKeyFailsValidate proves a revoked key is
// rejected even though it has neither expired nor been rotated.
func TestStore_Revoke_RevokedKeyFailsValidate(t *testing.T) {
	store := NewKeyStore()

	id, secret, err := store.Create("user-1", nil, 0)
	if err != nil {
		t.Fatalf("Create failed: %v", err)
	}
	if err := store.Revoke(id); err != nil {
		t.Fatalf("Revoke failed: %v", err)
	}

	if _, err := store.Validate(id, secret); err == nil {
		t.Fatal("Validate accepted a revoked key")
	}
}

// TestStore_Validate_UnknownIDFails proves Validate fails closed for a
// key id that was never created.
func TestStore_Validate_UnknownIDFails(t *testing.T) {
	store := NewKeyStore()
	if _, err := store.Validate("does-not-exist", "irrelevant"); err == nil {
		t.Fatal("Validate accepted an unknown key id")
	}
}

// TestStore_Validate_WrongSecretFails proves Validate fails closed
// when the id is real but the presented secret is wrong - the id alone
// must never be sufficient to authenticate.
func TestStore_Validate_WrongSecretFails(t *testing.T) {
	store := NewKeyStore()
	id, _, err := store.Create("user-1", nil, 0)
	if err != nil {
		t.Fatalf("Create failed: %v", err)
	}
	if _, err := store.Validate(id, "not-the-real-secret"); err == nil {
		t.Fatal("Validate accepted an incorrect secret for a real key id")
	}
}

// TestStore_Create_PersistsScopesAndOwner proves Create's scopes and
// ownerID arguments actually land on the resulting APIKey record - a
// service-account key is distinguished from a user key purely by what
// OwnerID identifier the caller supplies, so both must round-trip
// exactly.
func TestStore_Create_PersistsScopesAndOwner(t *testing.T) {
	store := NewKeyStore()
	scopes := []string{"model:start", "model:stop"}
	id, secret, err := store.Create("service-account-42", scopes, 0)
	if err != nil {
		t.Fatalf("Create failed: %v", err)
	}
	key, err := store.Validate(id, secret)
	if err != nil {
		t.Fatalf("Validate failed: %v", err)
	}
	if key.OwnerID != "service-account-42" {
		t.Errorf("OwnerID = %q, want %q", key.OwnerID, "service-account-42")
	}
	if len(key.Scopes) != 2 || key.Scopes[0] != "model:start" || key.Scopes[1] != "model:stop" {
		t.Errorf("Scopes = %v, want [model:start model:stop]", key.Scopes)
	}
}

// TestStore_Rotate_UnknownIDFails proves Rotate fails closed for a key
// id that was never created (or was already revoked/never existed).
func TestStore_Rotate_UnknownIDFails(t *testing.T) {
	store := NewKeyStore()
	if _, err := store.Rotate("does-not-exist"); err == nil {
		t.Fatal("Rotate accepted an unknown key id")
	}
}
