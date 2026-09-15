// Package replication (registry_test.go): proves StoreRegistry wires
// internal/isolation.TenantStateDir into a real, on-disk per-tenant
// directory decision for llmctld's own KV-cache checkpoint/WAL storage
// (Clarification 18/FR-049) - the thing this package's own wal.go/
// checkpoint.go doc comments already identify as what that Clarification
// requires isolating, since it persists actual replicated conversation
// content (tokens).
package replication

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/vasic-digital/llmctl/llmctld/internal/tenancy"
)

// TestStoreRegistry_EmptyTenantID_OpensBaseDirDirectly proves Get("")
// is byte-identical to calling OpenStore(baseDir, cfg) directly - the
// exact backward-compatible path every pre-existing caller (cmd/llmctld's
// wiring, every integration test) uses, so introducing StoreRegistry
// changes nothing for a caller that never supplies a tenant ID.
func TestStoreRegistry_EmptyTenantID_OpensBaseDirDirectly(t *testing.T) {
	baseDir := t.TempDir()
	reg := NewStoreRegistry(baseDir, CheckpointConfig{})
	defer func() { _ = reg.Close() }()

	store, err := reg.Get("")
	if err != nil {
		t.Fatalf("Get(\"\"): %v", err)
	}

	if err := store.Checkpoint(1, KVState{Tokens: []int32{7}, Positions: []int32{0}}); err != nil {
		t.Fatalf("Checkpoint: %v", err)
	}

	if _, err := os.Stat(filepath.Join(baseDir, "checkpoint.db")); err != nil {
		t.Fatalf("expected checkpoint.db directly inside baseDir (no tenant subdirectory) for the empty tenant ID: %v", err)
	}
}

// TestStoreRegistry_DifferentTenants_AreIsolatedStores proves two
// different tenant IDs resolve to two genuinely separate *Store
// instances, each rooted at its own internal/isolation.TenantStateDir
// subdirectory - a checkpoint written for one tenant must never appear
// in another tenant's Restore.
func TestStoreRegistry_DifferentTenants_AreIsolatedStores(t *testing.T) {
	baseDir := t.TempDir()
	reg := NewStoreRegistry(baseDir, CheckpointConfig{})
	defer func() { _ = reg.Close() }()

	storeA, err := reg.Get("tenant-a")
	if err != nil {
		t.Fatalf("Get(tenant-a): %v", err)
	}
	storeB, err := reg.Get("tenant-b")
	if err != nil {
		t.Fatalf("Get(tenant-b): %v", err)
	}

	if err := storeA.Checkpoint(1, KVState{Tokens: []int32{100}, Positions: []int32{0}}); err != nil {
		t.Fatalf("tenant-a Checkpoint: %v", err)
	}
	if err := storeB.Checkpoint(1, KVState{Tokens: []int32{200}, Positions: []int32{0}}); err != nil {
		t.Fatalf("tenant-b Checkpoint: %v", err)
	}

	gotA, err := storeA.Restore()
	if err != nil {
		t.Fatalf("tenant-a Restore: %v", err)
	}
	if len(gotA.Tokens) != 1 || gotA.Tokens[0] != 100 {
		t.Fatalf("tenant-a Restore = %+v, want Tokens=[100] (never tenant-b's 200)", gotA)
	}

	gotB, err := storeB.Restore()
	if err != nil {
		t.Fatalf("tenant-b Restore: %v", err)
	}
	if len(gotB.Tokens) != 1 || gotB.Tokens[0] != 200 {
		t.Fatalf("tenant-b Restore = %+v, want Tokens=[200] (never tenant-a's 100)", gotB)
	}

	// Real on-disk proof, not merely an in-memory separation: each
	// tenant's checkpoint.db lives under its OWN TenantStateDir
	// subdirectory, verified-0700-permissioned by the same real
	// mechanism T072 already established for per-tenant cgroup state.
	dirA := filepath.Join(baseDir, "tenant-a")
	dirB := filepath.Join(baseDir, "tenant-b")
	for _, dir := range []string{dirA, dirB} {
		info, err := os.Stat(dir)
		if err != nil {
			t.Fatalf("expected real tenant state directory %s to exist: %v", dir, err)
		}
		if got := info.Mode().Perm(); got != 0o700 {
			t.Fatalf("tenant state directory %s has permission bits %o, want 0700", dir, got)
		}
	}
	if _, err := os.Stat(filepath.Join(dirA, "checkpoint.db")); err != nil {
		t.Fatalf("expected tenant-a's checkpoint.db under its own TenantStateDir subdirectory: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dirB, "checkpoint.db")); err != nil {
		t.Fatalf("expected tenant-b's checkpoint.db under its own TenantStateDir subdirectory: %v", err)
	}
}

// TestStoreRegistry_Get_CachesStoreAcrossCalls proves a second Get call
// for the same tenant ID returns the SAME already-open *Store rather
// than attempting to reopen its bbolt files (which would deadlock/error
// on the file lock bbolt already holds).
func TestStoreRegistry_Get_CachesStoreAcrossCalls(t *testing.T) {
	reg := NewStoreRegistry(t.TempDir(), CheckpointConfig{})
	defer func() { _ = reg.Close() }()

	first, err := reg.Get("tenant-a")
	if err != nil {
		t.Fatalf("first Get: %v", err)
	}
	second, err := reg.Get("tenant-a")
	if err != nil {
		t.Fatalf("second Get: %v", err)
	}
	if first != second {
		t.Fatalf("second Get(tenant-a) returned a different *Store than the first call - expected the cached instance")
	}
}

// TestStoreRegistry_InvalidTenantID_ReturnsError proves a malicious/
// malformed tenant ID is rejected via the same allow-list
// internal/isolation.TenantStateDir already enforces, never silently
// passed through to a filesystem path.
func TestStoreRegistry_InvalidTenantID_ReturnsError(t *testing.T) {
	reg := NewStoreRegistry(t.TempDir(), CheckpointConfig{})
	defer func() { _ = reg.Close() }()

	if _, err := reg.Get("../../etc"); err == nil {
		t.Fatal("Get(\"../../etc\") unexpectedly succeeded - path-traversal tenant ID must be rejected")
	}
}

// TestNewEncryptedStoreRegistry_NonEmptyTenant_DataIsGenuinelyEncrypted
// proves NewEncryptedStoreRegistry (T072-FU3, closing Clarification 20's
// remaining half of the isolation requirement) derives a real per-tenant
// key via internal/tenancy.DeriveKey and actually applies it -
// re-opening the SAME on-disk directory via a bare, keyless OpenStore
// afterward must FAIL to Restore (AES-GCM's auth-tag check fails closed
// on the wrong "key" of no-decryption-at-all, per crypto.go), which is
// only possible if the persisted bytes are genuinely ciphertext, not
// merely "some wrapper" around the plaintext JSON checkpoint record.
func TestNewEncryptedStoreRegistry_NonEmptyTenant_DataIsGenuinelyEncrypted(t *testing.T) {
	baseDir := t.TempDir()
	masterSecret := []byte("test-master-secret-32-bytes-long!!")
	reg := NewEncryptedStoreRegistry(baseDir, CheckpointConfig{}, masterSecret)
	defer func() { _ = reg.Close() }()

	store, err := reg.Get("tenant-a")
	if err != nil {
		t.Fatalf("Get(tenant-a): %v", err)
	}
	if err := store.Checkpoint(1, KVState{Tokens: []int32{999}, Positions: []int32{0}}); err != nil {
		t.Fatalf("Checkpoint: %v", err)
	}

	// The registry's own Store can still read back its own data
	// correctly (proves encrypt+decrypt round-trips, not just that it
	// writes something).
	got, err := store.Restore()
	if err != nil {
		t.Fatalf("Restore via the registry's own Store: %v", err)
	}
	if len(got.Tokens) != 1 || got.Tokens[0] != 999 {
		t.Fatalf("Restore via the registry's own Store = %+v, want Tokens=[999]", got)
	}

	// Close so the on-disk bbolt files are released before reopening
	// them independently below.
	if err := reg.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	tenantDir := filepath.Join(baseDir, "tenant-a")
	plainStore, err := OpenStore(tenantDir, CheckpointConfig{})
	if err != nil {
		t.Fatalf("re-open tenant-a's directory with a bare OpenStore: %v", err)
	}
	defer func() { _ = plainStore.Close() }()
	if _, err := plainStore.Restore(); err == nil {
		t.Fatal("bare OpenStore (no key) successfully restored tenant-a's data - it was NOT genuinely encrypted")
	}
}

// TestNewEncryptedStoreRegistry_DifferentTenants_UseDifferentDerivedKeys
// proves two tenants under the SAME master secret get genuinely
// DIFFERENT derived keys (internal/tenancy.DeriveKey's own documented
// per-tenantID independence property, exercised here through the
// registry's real wiring rather than asserted only at the DeriveKey
// unit-test layer): opening tenant-a's on-disk directory directly with
// tenant-b's derived key must fail to decrypt.
func TestNewEncryptedStoreRegistry_DifferentTenants_UseDifferentDerivedKeys(t *testing.T) {
	baseDir := t.TempDir()
	masterSecret := []byte("shared-master-secret-for-both-tenants")
	reg := NewEncryptedStoreRegistry(baseDir, CheckpointConfig{}, masterSecret)

	storeA, err := reg.Get("tenant-a")
	if err != nil {
		t.Fatalf("Get(tenant-a): %v", err)
	}
	if err := storeA.Checkpoint(1, KVState{Tokens: []int32{111}, Positions: []int32{0}}); err != nil {
		t.Fatalf("tenant-a Checkpoint: %v", err)
	}
	if err := reg.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	keyB := tenancy.DeriveKey(masterSecret, "tenant-b")
	wrongKeyStore, err := OpenEncryptedStore(filepath.Join(baseDir, "tenant-a"), CheckpointConfig{}, keyB)
	if err != nil {
		t.Fatalf("OpenEncryptedStore(tenant-a's dir, tenant-b's key): %v", err)
	}
	defer func() { _ = wrongKeyStore.Close() }()
	if _, err := wrongKeyStore.Restore(); err == nil {
		t.Fatal("tenant-b's derived key successfully decrypted tenant-a's data - DeriveKey per-tenant independence was not genuinely applied by the registry")
	}
}

// TestStoreRegistry_PlaintextRegistry_EmptyTenant_NeverEncrypted proves
// NewStoreRegistry (the plain, non-encrypting constructor) is completely
// unaffected by this task: the default/no-tenant ("") path always stays
// plaintext, exactly as every pre-existing caller already relies on.
func TestStoreRegistry_PlaintextRegistry_EmptyTenant_NeverEncrypted(t *testing.T) {
	reg := NewStoreRegistry(t.TempDir(), CheckpointConfig{})
	defer func() { _ = reg.Close() }()

	store, err := reg.Get("")
	if err != nil {
		t.Fatalf("Get(\"\"): %v", err)
	}
	if err := store.Checkpoint(1, KVState{Tokens: []int32{7}, Positions: []int32{0}}); err != nil {
		t.Fatalf("Checkpoint: %v", err)
	}
	got, err := store.Restore()
	if err != nil {
		t.Fatalf("Restore: %v", err)
	}
	if len(got.Tokens) != 1 || got.Tokens[0] != 7 {
		t.Fatalf("Restore = %+v, want Tokens=[7]", got)
	}
}

// TestStoreRegistry_Close_ClosesEveryOpenedStore proves Close() closes
// every tenant Store the registry has opened, not just one.
func TestStoreRegistry_Close_ClosesEveryOpenedStore(t *testing.T) {
	baseDir := t.TempDir()
	reg := NewStoreRegistry(baseDir, CheckpointConfig{})

	if _, err := reg.Get("tenant-a"); err != nil {
		t.Fatalf("Get(tenant-a): %v", err)
	}
	if _, err := reg.Get("tenant-b"); err != nil {
		t.Fatalf("Get(tenant-b): %v", err)
	}

	if err := reg.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	// Re-opening the same directories via a fresh registry after Close
	// must succeed - proof the bbolt file locks were genuinely released
	// for BOTH tenants, not just the first one closed.
	reg2 := NewStoreRegistry(baseDir, CheckpointConfig{})
	defer func() { _ = reg2.Close() }()
	if _, err := reg2.Get("tenant-a"); err != nil {
		t.Fatalf("re-Get(tenant-a) after Close: %v (tenant-a's Store was not genuinely released)", err)
	}
	if _, err := reg2.Get("tenant-b"); err != nil {
		t.Fatalf("re-Get(tenant-b) after Close: %v (tenant-b's Store was not genuinely released)", err)
	}
}
