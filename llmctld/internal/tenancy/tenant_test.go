package tenancy

import "testing"

// TestRegistry_CreateThenGet proves the basic CRUD round-trip: a created
// tenant is retrievable by ID with its fields intact.
func TestRegistry_CreateThenGet(t *testing.T) {
	r := NewRegistry()
	tenant, err := r.Create("tenant-a", "Tenant A")
	if err != nil {
		t.Fatalf("Create returned unexpected error: %v", err)
	}
	if tenant.ID != "tenant-a" || tenant.Name != "Tenant A" {
		t.Fatalf("Create returned wrong tenant: %+v", tenant)
	}

	got, ok := r.Get("tenant-a")
	if !ok {
		t.Fatal("Get did not find the tenant just created")
	}
	if got.ID != "tenant-a" || got.Name != "Tenant A" {
		t.Fatalf("Get returned wrong tenant: %+v", got)
	}
}

// TestRegistry_CreateDuplicateIDFails proves a second Create for an
// already-registered tenant ID is rejected rather than silently
// overwriting the existing tenant (which would let one tenant clobber
// another's registration).
func TestRegistry_CreateDuplicateIDFails(t *testing.T) {
	r := NewRegistry()
	if _, err := r.Create("tenant-a", "Tenant A"); err != nil {
		t.Fatalf("first Create returned unexpected error: %v", err)
	}
	if _, err := r.Create("tenant-a", "Tenant A (duplicate)"); err == nil {
		t.Fatal("Create with a duplicate ID succeeded, want an error")
	}
}

// TestRegistry_GetMissingReturnsFalse proves Get on an unregistered ID
// reports absence via its ok return rather than a zero-value tenant that
// could be mistaken for a real one.
func TestRegistry_GetMissingReturnsFalse(t *testing.T) {
	r := NewRegistry()
	if _, ok := r.Get("no-such-tenant"); ok {
		t.Fatal("Get on an unregistered ID returned ok=true")
	}
}

// TestRegistry_DeleteRemovesTenant proves Delete actually removes the
// tenant from the registry (subsequent Get fails) rather than merely
// marking it inactive.
func TestRegistry_DeleteRemovesTenant(t *testing.T) {
	r := NewRegistry()
	if _, err := r.Create("tenant-a", "Tenant A"); err != nil {
		t.Fatalf("Create returned unexpected error: %v", err)
	}
	if err := r.Delete("tenant-a"); err != nil {
		t.Fatalf("Delete returned unexpected error: %v", err)
	}
	if _, ok := r.Get("tenant-a"); ok {
		t.Fatal("Get found a tenant after it was Deleted")
	}
}

// TestRegistry_DeleteMissingFails proves Delete on an unregistered ID
// reports an error rather than silently succeeding, so a caller cannot
// mistake a no-op for a real deletion.
func TestRegistry_DeleteMissingFails(t *testing.T) {
	r := NewRegistry()
	if err := r.Delete("no-such-tenant"); err == nil {
		t.Fatal("Delete on an unregistered ID succeeded, want an error")
	}
}

// TestNamespaceIsolation_SharedModelVisibleOnlyToGrantedTenant is the
// literal T069 deliverable (FR-033, FR-037, US9 Acceptance Scenario 1):
// Tenant A's model is invisible to Tenant B without an explicit share,
// becomes visible to B once A shares it, and stays invisible to a third
// tenant C who was never granted the share - proving isolation is real
// (not a global unlock) and the share grant is scoped to exactly the
// tenant it names.
func TestNamespaceIsolation_SharedModelVisibleOnlyToGrantedTenant(t *testing.T) {
	r := NewRegistry()
	for _, id := range []string{"tenant-a", "tenant-b", "tenant-c"} {
		if _, err := r.Create(id, id); err != nil {
			t.Fatalf("Create(%s) returned unexpected error: %v", id, err)
		}
	}

	if err := r.RegisterModel("tenant-a", "llama-70b"); err != nil {
		t.Fatalf("RegisterModel returned unexpected error: %v", err)
	}

	// Before any share: A sees its own model, B and C do not.
	if !r.IsVisible("tenant-a", "llama-70b") {
		t.Fatal("owner tenant cannot see its own registered model")
	}
	if r.IsVisible("tenant-b", "llama-70b") {
		t.Fatal("tenant-b can see tenant-a's model before any share was granted")
	}
	if r.IsVisible("tenant-c", "llama-70b") {
		t.Fatal("tenant-c can see tenant-a's model before any share was granted")
	}
	if contains(r.ListVisibleModels("tenant-b"), "llama-70b") {
		t.Fatal("tenant-b's ListVisibleModels includes tenant-a's unshared model")
	}

	// A explicitly shares the model with B only.
	if err := r.ShareModel("tenant-a", "llama-70b", "tenant-b"); err != nil {
		t.Fatalf("ShareModel returned unexpected error: %v", err)
	}

	// After the share: B can now see it, C still cannot (scoped grant,
	// not a global unlock).
	if !r.IsVisible("tenant-b", "llama-70b") {
		t.Fatal("tenant-b cannot see the model after tenant-a explicitly shared it")
	}
	if !contains(r.ListVisibleModels("tenant-b"), "llama-70b") {
		t.Fatal("tenant-b's ListVisibleModels does not include the model shared with it")
	}
	if r.IsVisible("tenant-c", "llama-70b") {
		t.Fatal("tenant-c can see tenant-a's model despite never being granted a share")
	}
	if contains(r.ListVisibleModels("tenant-c"), "llama-70b") {
		t.Fatal("tenant-c's ListVisibleModels includes a model never shared with it")
	}
}

// TestNamespaceIsolation_ShareGrantsOnlyTheNamedModel proves a share of
// one model does not leak the owner's entire model set to the recipient
// - only the specifically shared model becomes visible.
func TestNamespaceIsolation_ShareGrantsOnlyTheNamedModel(t *testing.T) {
	r := NewRegistry()
	for _, id := range []string{"tenant-a", "tenant-b"} {
		if _, err := r.Create(id, id); err != nil {
			t.Fatalf("Create(%s) returned unexpected error: %v", id, err)
		}
	}
	if err := r.RegisterModel("tenant-a", "llama-70b"); err != nil {
		t.Fatalf("RegisterModel returned unexpected error: %v", err)
	}
	if err := r.RegisterModel("tenant-a", "mistral-7b"); err != nil {
		t.Fatalf("RegisterModel returned unexpected error: %v", err)
	}

	if err := r.ShareModel("tenant-a", "llama-70b", "tenant-b"); err != nil {
		t.Fatalf("ShareModel returned unexpected error: %v", err)
	}

	if !r.IsVisible("tenant-b", "llama-70b") {
		t.Fatal("tenant-b cannot see the model explicitly shared with it")
	}
	if r.IsVisible("tenant-b", "mistral-7b") {
		t.Fatal("tenant-b can see tenant-a's OTHER model, which was never shared - sharing leaked the whole namespace")
	}
}

// TestNamespaceIsolation_ListVisibleModelsIncludesOwnAndShared proves
// ListVisibleModels for a tenant with both its own registered models and
// a model shared to it by another tenant returns the union of both sets.
func TestNamespaceIsolation_ListVisibleModelsIncludesOwnAndShared(t *testing.T) {
	r := NewRegistry()
	for _, id := range []string{"tenant-a", "tenant-b"} {
		if _, err := r.Create(id, id); err != nil {
			t.Fatalf("Create(%s) returned unexpected error: %v", id, err)
		}
	}
	if err := r.RegisterModel("tenant-a", "llama-70b"); err != nil {
		t.Fatalf("RegisterModel returned unexpected error: %v", err)
	}
	if err := r.RegisterModel("tenant-b", "own-model"); err != nil {
		t.Fatalf("RegisterModel returned unexpected error: %v", err)
	}
	if err := r.ShareModel("tenant-a", "llama-70b", "tenant-b"); err != nil {
		t.Fatalf("ShareModel returned unexpected error: %v", err)
	}

	visible := r.ListVisibleModels("tenant-b")
	if !contains(visible, "own-model") {
		t.Fatalf("ListVisibleModels dropped tenant-b's own model: %v", visible)
	}
	if !contains(visible, "llama-70b") {
		t.Fatalf("ListVisibleModels dropped the model shared to tenant-b: %v", visible)
	}
}

// TestShareModel_UnknownOwnerModelFails proves ShareModel cannot be used
// to grant access to a model the purported owner never actually
// registered.
func TestShareModel_UnknownOwnerModelFails(t *testing.T) {
	r := NewRegistry()
	for _, id := range []string{"tenant-a", "tenant-b"} {
		if _, err := r.Create(id, id); err != nil {
			t.Fatalf("Create(%s) returned unexpected error: %v", id, err)
		}
	}
	if err := r.ShareModel("tenant-a", "never-registered", "tenant-b"); err == nil {
		t.Fatal("ShareModel succeeded for a model the owner never registered")
	}
}

func contains(models []string, name string) bool {
	for _, m := range models {
		if m == name {
			return true
		}
	}
	return false
}
