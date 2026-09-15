package auth

import "testing"

// TestCheck_ModelOperatorCanDeleteModel_ModelViewerCannot is the literal
// T066 deliverable (FR-031, US9 Acceptance Scenario 4): model-operator
// carries ActionModelDelete, model-viewer does not.
func TestCheck_ModelOperatorCanDeleteModel_ModelViewerCannot(t *testing.T) {
	if !Check([]string{RoleModelOperator}, ActionModelDelete) {
		t.Fatal("model-operator should be allowed to delete a model")
	}
	if Check([]string{RoleModelViewer}, ActionModelDelete) {
		t.Fatal("model-viewer should NOT be allowed to delete a model")
	}
}

// TestCheck_ModelViewerCanView proves model-viewer retains its intended
// (non-destructive) permission - a role denying delete must not have
// been implemented by denying it everything.
func TestCheck_ModelViewerCanView(t *testing.T) {
	if !Check([]string{RoleModelViewer}, ActionModelView) {
		t.Fatal("model-viewer should be allowed to view a model")
	}
}

// TestCheck_AdminGrantsEverythingDefined proves the admin role is a
// superset covering every action this package defines, since admin is
// the escape hatch for operations no other predefined role grants.
func TestCheck_AdminGrantsEverythingDefined(t *testing.T) {
	for _, action := range []Action{
		ActionModelStart, ActionModelStop, ActionModelDelete,
		ActionModelView, ActionTenantManage,
	} {
		if !Check([]string{RoleAdmin}, action) {
			t.Errorf("admin should grant %q, but did not", action)
		}
	}
}

// TestCheck_TenantAdminCanManageTenantsButNotModels proves tenant-admin
// is scoped to tenant management, not general model lifecycle - roles
// are distinct permission sets, not synonyms for "elevated".
func TestCheck_TenantAdminCanManageTenants(t *testing.T) {
	if !Check([]string{RoleTenantAdmin}, ActionTenantManage) {
		t.Fatal("tenant-admin should be allowed to manage tenants")
	}
	if Check([]string{RoleTenantAdmin}, ActionModelDelete) {
		t.Fatal("tenant-admin should NOT be allowed to delete a model")
	}
}

// TestCheck_AnyMatchingRoleGrantsAccess proves Check evaluates the
// UNION of a subject's roles - a subject holding both a denying and a
// granting role for the same action is granted (an ANY-match model, the
// conservative choice for combining roles a subject was explicitly
// given, versus an ALL-match model that would make adding a second role
// to a subject able to silently revoke access the first role granted).
func TestCheck_AnyMatchingRoleGrantsAccess(t *testing.T) {
	roles := []string{RoleModelViewer, RoleModelOperator}
	if !Check(roles, ActionModelDelete) {
		t.Fatal("a subject holding model-operator among several roles should be granted ActionModelDelete")
	}
}

// TestCheck_UnknownRoleGrantsNothing proves a role string that is
// neither predefined nor registered as a custom role carries zero
// permissions - permissions are opt-in, never assumed from an unknown
// name.
func TestCheck_UnknownRoleGrantsNothing(t *testing.T) {
	if Check([]string{"totally-made-up-role"}, ActionModelView) {
		t.Fatal("an unknown role should not grant any action")
	}
}

// TestCheck_EmptyRolesGrantsNothing proves a subject with no roles at
// all is denied every action - the fail-closed default.
func TestCheck_EmptyRolesGrantsNothing(t *testing.T) {
	if Check(nil, ActionModelView) {
		t.Fatal("no roles should grant no actions")
	}
	if Check([]string{}, ActionModelView) {
		t.Fatal("no roles should grant no actions")
	}
}

// TestRegistry_CustomRoleGrantsOnlyItsRegisteredActions proves a custom
// role registered via RegisterCustomRole grants exactly the actions it
// was registered with - nothing more, nothing less.
func TestRegistry_CustomRoleGrantsOnlyItsRegisteredActions(t *testing.T) {
	reg := NewRoleRegistry()
	reg.RegisterCustomRole("model-starter-only", []Action{ActionModelStart})

	if !reg.Check([]string{"model-starter-only"}, ActionModelStart) {
		t.Fatal("custom role should grant its registered action")
	}
	if reg.Check([]string{"model-starter-only"}, ActionModelDelete) {
		t.Fatal("custom role should NOT grant an action it was never registered with")
	}
}

// TestRegistry_UnregisteredCustomRoleGrantsNothing proves a role name
// that was never passed to RegisterCustomRole (and is not predefined)
// grants nothing when checked through a RoleRegistry, mirroring the
// package-level Check's fail-closed behavior.
func TestRegistry_UnregisteredCustomRoleGrantsNothing(t *testing.T) {
	reg := NewRoleRegistry()
	if reg.Check([]string{"never-registered"}, ActionModelView) {
		t.Fatal("an unregistered custom role should grant nothing")
	}
}

// TestRegistry_StillHonorsPredefinedRoles proves a RoleRegistry with no
// custom roles registered still evaluates the predefined roles
// correctly - custom-role support is additive, it does not replace the
// predefined table.
func TestRegistry_StillHonorsPredefinedRoles(t *testing.T) {
	reg := NewRoleRegistry()
	if !reg.Check([]string{RoleModelOperator}, ActionModelDelete) {
		t.Fatal("registry should still honor predefined role model-operator")
	}
	if reg.Check([]string{RoleModelViewer}, ActionModelDelete) {
		t.Fatal("registry should still deny predefined role model-viewer ActionModelDelete")
	}
}
