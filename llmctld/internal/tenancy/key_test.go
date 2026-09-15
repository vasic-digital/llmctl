package tenancy

import "testing"

// TestDeriveKey_IsDeterministic proves the same (masterSecret, tenantID)
// pair always re-derives the SAME key - required because a node must be
// able to decrypt its own previously-written checkpoint/WAL files after
// a restart, without persisting the derived key itself anywhere.
func TestDeriveKey_IsDeterministic(t *testing.T) {
	secret := []byte("master-secret-for-testing")
	k1 := DeriveKey(secret, "tenant-a")
	k2 := DeriveKey(secret, "tenant-a")
	if string(k1) != string(k2) {
		t.Fatalf("DeriveKey is not deterministic: %x != %x", k1, k2)
	}
}

// TestDeriveKey_DifferentTenantsGetDifferentKeys proves per-tenant key
// isolation (FR-051, Clarification 20): two tenants sharing the same
// master secret MUST get cryptographically distinct keys, so one
// tenant's key can never decrypt another tenant's data.
func TestDeriveKey_DifferentTenantsGetDifferentKeys(t *testing.T) {
	secret := []byte("master-secret-for-testing")
	ka := DeriveKey(secret, "tenant-a")
	kb := DeriveKey(secret, "tenant-b")
	if string(ka) == string(kb) {
		t.Fatalf("DeriveKey produced the SAME key for two different tenant IDs")
	}
}

// TestDeriveKey_DifferentMasterSecretsGetDifferentKeys proves the master
// secret is genuinely load-bearing in the derivation, not ignored.
func TestDeriveKey_DifferentMasterSecretsGetDifferentKeys(t *testing.T) {
	k1 := DeriveKey([]byte("secret-one"), "tenant-a")
	k2 := DeriveKey([]byte("secret-two"), "tenant-a")
	if string(k1) == string(k2) {
		t.Fatalf("DeriveKey produced the SAME key for two different master secrets")
	}
}

// TestDeriveKey_Is32Bytes proves the derived key is exactly AES-256's
// key size - a wrong-sized key would fail at the aes.NewCipher call site
// in internal/replication's encryption layer, not here, which would be a
// much less direct failure to diagnose.
func TestDeriveKey_Is32Bytes(t *testing.T) {
	k := DeriveKey([]byte("secret"), "tenant-a")
	if len(k) != 32 {
		t.Fatalf("DeriveKey returned a %d-byte key, want 32 (AES-256)", len(k))
	}
}
