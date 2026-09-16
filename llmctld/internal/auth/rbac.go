package auth

// Role names. These are plain strings (not a distinct Go type) because
// Claims.Roles (jwt.go) is []string - a claim decoded from a token
// arrives as raw strings, and RBAC has to evaluate exactly those
// strings without a lossy conversion step at the trust boundary.
const (
	RoleAdmin         = "admin"
	RoleModelOperator = "model-operator"
	RoleModelViewer   = "model-viewer"
	RoleTenantAdmin   = "tenant-admin"
)

// Action identifies a single permission-checkable operation this
// daemon exposes over its cluster API: model lifecycle management,
// model visibility, tenant administration, and mTLS certificate/CA
// management (docs/api-reference.md's cluster API surface).
type Action string

const (
	ActionModelStart   Action = "model:start"
	ActionModelStop    Action = "model:stop"
	ActionModelDelete  Action = "model:delete"
	ActionModelView    Action = "model:view"
	ActionTenantManage Action = "tenant:manage"
	// ActionMTLSManage gates Feature 004's operator-facing mTLS actions
	// (routes_mtls.go: revoke a certificate, query revocation status) -
	// a high-privilege, cluster-wide-effect action deliberately granted
	// ONLY to admin (unlike model/tenant actions, no dedicated
	// "mtls-operator" role exists, since spec.md names no such role and
	// inventing one here would be an unrequested constraint, Constitution
	// §11.4.6).
	ActionMTLSManage Action = "mtls:manage"
)

// predefinedRoles is the role -> allowed-actions table for the four
// FR-031 named roles. admin is a superset of every other role's
// actions (the escape hatch for full-access operators); model-operator
// covers the full model lifecycle including delete (US9 Acceptance
// Scenario 4); model-viewer is intentionally read-only;
// tenant-admin is scoped to tenant management, not general model
// operations - a distinct concern, not a synonym for "elevated
// model-operator".
var predefinedRoles = map[string]map[Action]bool{
	RoleAdmin: {
		ActionModelStart:   true,
		ActionModelStop:    true,
		ActionModelDelete:  true,
		ActionModelView:    true,
		ActionTenantManage: true,
		ActionMTLSManage:   true,
	},
	RoleModelOperator: {
		ActionModelStart:  true,
		ActionModelStop:   true,
		ActionModelDelete: true,
		ActionModelView:   true,
	},
	RoleModelViewer: {
		ActionModelView: true,
	},
	RoleTenantAdmin: {
		ActionTenantManage: true,
	},
}

// Check reports whether ANY of roles grants action, evaluated purely
// against the predefined role table. A role name absent from
// predefinedRoles (including an unrecognized custom-role name) grants
// nothing - permissions are opt-in and fail closed, never inferred from
// an unknown string. Combining multiple roles is a union: if any held
// role grants the action, access is allowed, so adding a broader role
// to a subject can only add permissions, never revoke ones another held
// role already granted.
func Check(roles []string, action Action) bool {
	for _, role := range roles {
		if predefinedRoles[role][action] {
			return true
		}
	}
	return false
}

// RoleRegistry adds CUSTOM role support on top of the predefined table:
// a role name not in predefinedRoles has no built-in permissions unless
// it has been explicitly registered here via RegisterCustomRole. A
// struct (rather than package-level global registration state) is used
// so tests - and, if ever needed, independent tenants or callers - can
// hold isolated registries without mutating shared process-wide state.
type RoleRegistry struct {
	custom map[string]map[Action]bool
}

// NewRoleRegistry returns an empty RoleRegistry: no custom roles
// registered yet, but Check still honors every predefined role.
func NewRoleRegistry() *RoleRegistry {
	return &RoleRegistry{custom: make(map[string]map[Action]bool)}
}

// RegisterCustomRole records that role name grants exactly
// allowedActions. Registering the same name again replaces its
// previous grant set (last write wins) rather than merging, so a
// caller re-registering a role gets exactly what it just declared, not
// an accumulation of every prior declaration.
func (r *RoleRegistry) RegisterCustomRole(name string, allowedActions []Action) {
	grants := make(map[Action]bool, len(allowedActions))
	for _, a := range allowedActions {
		grants[a] = true
	}
	r.custom[name] = grants
}

// Check reports whether ANY of roles grants action, checking the
// predefined table first and this registry's custom roles second -
// custom-role support is additive to, never a replacement for, the
// predefined roles.
func (r *RoleRegistry) Check(roles []string, action Action) bool {
	for _, role := range roles {
		if predefinedRoles[role][action] {
			return true
		}
		if r.custom[role][action] {
			return true
		}
	}
	return false
}
