package tenancy

import (
	"fmt"
	"sync"
	"time"
)

// Tenant is a registered occupant of the cluster's multi-tenant scheduler
// (FR-033): every model namespace and quota in this package is scoped to
// a Tenant.ID.
type Tenant struct {
	ID        string
	Name      string
	CreatedAt time.Time
}

// Registry is the in-memory tenant directory plus per-tenant model
// namespace isolation (FR-033, FR-037). A real persistent backing store
// (e.g. etcd/bbolt) is out of scope for this task per tasks.md's file
// list (internal/tenancy/tenant.go only) - Registry's job here is the
// isolation semantics, not durability.
type Registry struct {
	mu sync.Mutex

	tenants map[string]*Tenant

	// ownedModels[tenantID] is the set of model names that tenant
	// registered itself. shares[tenantID][modelName] = ownerTenantID
	// records an explicit grant: modelName, owned by ownerTenantID, was
	// shared into tenantID's visible set. Keeping the owner alongside
	// the grant (rather than a bare set) is what lets IsVisible resolve
	// a shared entry back to its real source model without a second
	// lookup, and keeps the grant intrinsically scoped to one recipient
	// - there is no way to represent "shared with everyone" by
	// accident.
	ownedModels map[string]map[string]struct{}
	shares      map[string]map[string]string
}

// NewRegistry returns an empty Registry ready for use.
func NewRegistry() *Registry {
	return &Registry{
		tenants:     make(map[string]*Tenant),
		ownedModels: make(map[string]map[string]struct{}),
		shares:      make(map[string]map[string]string),
	}
}

// Create registers a new tenant. It fails if id is already registered -
// silently overwriting an existing tenant's registration would let one
// caller clobber another tenant's identity.
func (r *Registry) Create(id, name string) (*Tenant, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	if _, exists := r.tenants[id]; exists {
		return nil, fmt.Errorf("tenancy: tenant %q already exists", id)
	}

	t := &Tenant{ID: id, Name: name, CreatedAt: time.Now()}
	r.tenants[id] = t
	return t, nil
}

// Get returns the tenant registered under id, and whether it was found.
func (r *Registry) Get(id string) (*Tenant, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()

	t, ok := r.tenants[id]
	return t, ok
}

// Delete removes a tenant and everything it owns or was granted: its own
// registered models, and every share grant recorded for it (both as
// owner and as recipient). It fails if id is not registered, so a
// caller cannot mistake a no-op for a real deletion.
func (r *Registry) Delete(id string) error {
	r.mu.Lock()
	defer r.mu.Unlock()

	if _, exists := r.tenants[id]; !exists {
		return fmt.Errorf("tenancy: tenant %q does not exist", id)
	}

	delete(r.tenants, id)
	delete(r.ownedModels, id)
	delete(r.shares, id)
	return nil
}

// RegisterModel adds modelName to tenantID's own model namespace
// (FR-037). It does not itself grant visibility to any other tenant -
// that requires an explicit ShareModel call.
func (r *Registry) RegisterModel(tenantID, modelName string) error {
	r.mu.Lock()
	defer r.mu.Unlock()

	if _, exists := r.tenants[tenantID]; !exists {
		return fmt.Errorf("tenancy: tenant %q does not exist", tenantID)
	}

	if r.ownedModels[tenantID] == nil {
		r.ownedModels[tenantID] = make(map[string]struct{})
	}
	r.ownedModels[tenantID][modelName] = struct{}{}
	return nil
}

// ShareModel grants withTenantID visibility of modelName, which must
// already be registered by ownerTenantID. The grant is scoped to
// exactly modelName and exactly withTenantID: it does not expose any of
// ownerTenantID's other models, and it does not affect any other
// tenant's visibility.
func (r *Registry) ShareModel(ownerTenantID, modelName, withTenantID string) error {
	r.mu.Lock()
	defer r.mu.Unlock()

	if _, exists := r.tenants[withTenantID]; !exists {
		return fmt.Errorf("tenancy: recipient tenant %q does not exist", withTenantID)
	}
	if _, owns := r.ownedModels[ownerTenantID][modelName]; !owns {
		return fmt.Errorf("tenancy: tenant %q has not registered model %q", ownerTenantID, modelName)
	}

	if r.shares[withTenantID] == nil {
		r.shares[withTenantID] = make(map[string]string)
	}
	r.shares[withTenantID][modelName] = ownerTenantID
	return nil
}

// IsVisible reports whether tenantID can see modelName - either because
// tenantID registered it itself, or because another tenant explicitly
// shared it with tenantID. This is the boolean check an authorization
// path calls at request time.
func (r *Registry) IsVisible(tenantID, modelName string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	if _, owned := r.ownedModels[tenantID][modelName]; owned {
		return true
	}
	_, shared := r.shares[tenantID][modelName]
	return shared
}

// ListVisibleModels returns every model name visible to tenantID: its
// own registered models, plus every model explicitly shared with it by
// another tenant. It never returns a model belonging to another tenant
// unless that specific model was shared with tenantID.
func (r *Registry) ListVisibleModels(tenantID string) []string {
	r.mu.Lock()
	defer r.mu.Unlock()

	seen := make(map[string]struct{})
	var out []string

	for name := range r.ownedModels[tenantID] {
		if _, dup := seen[name]; !dup {
			seen[name] = struct{}{}
			out = append(out, name)
		}
	}
	for name := range r.shares[tenantID] {
		if _, dup := seen[name]; !dup {
			seen[name] = struct{}{}
			out = append(out, name)
		}
	}
	return out
}
