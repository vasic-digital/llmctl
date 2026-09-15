package isolation

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// TestWrapCommand_ArgvShape proves WrapCommand produces the exact real
// `systemd-run` argv shape for representative inputs - pure string/slice
// assertions, no subprocess needed. Confirmed real systemd-run flag
// semantics before writing this (man systemd-run, systemd 259, this build
// host): --user selects the caller's user-session manager rather than the
// system manager; --scope creates a transient *scope* unit (a cgroup
// wrapping an already-running/about-to-be-forked process tree) instead of
// a *service* unit (which systemd itself would fork); --slice=NAME.slice
// nests that scope under the named parent slice/cgroup so every tenant's
// scopes share one addressable cgroup subtree
// (llmctl-tenant-<id>.slice); -p NAME=VALUE (--property=) sets a unit
// resource-control property - MemoryMax=<bytes> here - on the transient
// unit at creation time, exactly as systemd.resource-control(5)
// documents; and "--" ends systemd-run's own option parsing so everything
// after it is unambiguously the command to run and re-exec, never parsed
// as a further systemd-run flag.
func TestWrapCommand_ArgvShape(t *testing.T) {
	t.Run("plain command no args no memory limit", func(t *testing.T) {
		path, args, err := WrapCommand(WrapConfig{TenantID: "acme"}, "/bin/true")
		if err != nil {
			t.Fatalf("WrapCommand: unexpected error: %v", err)
		}
		if path != "systemd-run" {
			t.Errorf("path = %q, want %q", path, "systemd-run")
		}
		want := []string{
			"--user", "--scope", "--slice=llmctl-tenant-acme.slice",
			"--", "/bin/true",
		}
		if !reflect.DeepEqual(args, want) {
			t.Errorf("args = %#v, want %#v", args, want)
		}
	})

	t.Run("command with args no memory limit", func(t *testing.T) {
		path, args, err := WrapCommand(WrapConfig{TenantID: "tenant-1"}, "llama-server", "--port", "8085", "--model", "/models/small.gguf")
		if err != nil {
			t.Fatalf("WrapCommand: unexpected error: %v", err)
		}
		if path != "systemd-run" {
			t.Errorf("path = %q, want %q", path, "systemd-run")
		}
		want := []string{
			"--user", "--scope", "--slice=llmctl-tenant-tenant-1.slice",
			"--", "llama-server", "--port", "8085", "--model", "/models/small.gguf",
		}
		if !reflect.DeepEqual(args, want) {
			t.Errorf("args = %#v, want %#v", args, want)
		}
	})

	t.Run("command with memory limit set", func(t *testing.T) {
		path, args, err := WrapCommand(WrapConfig{TenantID: "acme", MemoryMaxBytes: 4294967296}, "llama-server", "--port", "8086")
		if err != nil {
			t.Fatalf("WrapCommand: unexpected error: %v", err)
		}
		if path != "systemd-run" {
			t.Errorf("path = %q, want %q", path, "systemd-run")
		}
		want := []string{
			"--user", "--scope", "--slice=llmctl-tenant-acme.slice",
			"-p", "MemoryMax=4294967296",
			"--", "llama-server", "--port", "8086",
		}
		if !reflect.DeepEqual(args, want) {
			t.Errorf("args = %#v, want %#v", args, want)
		}
	})

	t.Run("zero memory limit means no property added", func(t *testing.T) {
		_, args, err := WrapCommand(WrapConfig{TenantID: "acme", MemoryMaxBytes: 0}, "/bin/true")
		if err != nil {
			t.Fatalf("WrapCommand: unexpected error: %v", err)
		}
		for _, a := range args {
			if strings.Contains(a, "MemoryMax") {
				t.Errorf("args = %#v contains a MemoryMax property despite MemoryMaxBytes=0", args)
			}
		}
	})
}

// TestWrapCommand_RejectsMaliciousTenantID proves a malicious/malformed
// tenant ID is rejected (WrapCommand returns a non-nil error) rather than
// silently interpolated into the systemd slice-name argument, where it
// could break out of the --slice=llmctl-tenant-<id>.slice context or (in
// the ";"/space cases) look like an attempt to smuggle an extra shell
// token into a caller that naively string-joins the returned argv before
// invoking a shell (WrapCommand itself always returns a []string argv for
// direct exec.Command use, never a shell string - this test guards the
// tenant-ID-content half of that safety property).
func TestWrapCommand_RejectsMaliciousTenantID(t *testing.T) {
	cases := []struct {
		name     string
		tenantID string
	}{
		{"semicolon", "acme;rm -rf /"},
		{"slash", "acme/evil"},
		{"parent-dir-traversal", ".."},
		{"embedded-parent-dir", "acme/../other"},
		{"space", "acme evil"},
		{"empty", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, _, err := WrapCommand(WrapConfig{TenantID: tc.tenantID}, "/bin/true")
			if err == nil {
				t.Fatalf("WrapCommand(tenantID=%q): expected error, got nil", tc.tenantID)
			}
		})
	}
}

// TestWrapCommand_AcceptsValidTenantID is the negative-control sibling of
// TestWrapCommand_RejectsMaliciousTenantID: a well-formed tenant ID using
// only the alphanumeric/-/_/. characters a systemd unit/slice name
// actually permits MUST be accepted, so the sanitizer is proven to
// reject the malicious shapes specifically - not everything.
func TestWrapCommand_AcceptsValidTenantID(t *testing.T) {
	for _, id := range []string{"acme", "tenant-1", "tenant_2", "Tenant.3", "a"} {
		if _, _, err := WrapCommand(WrapConfig{TenantID: id}, "/bin/true"); err != nil {
			t.Errorf("WrapCommand(tenantID=%q): unexpected error: %v", id, err)
		}
	}
}

// TestTenantStateDir_CreatesRealDirectoryWithReal0700Permissions is a
// REAL filesystem test in a real t.TempDir() sandbox (no special
// privileges needed to create a directory - this runs safely on this
// build host). It proves the ACTUAL resulting permission bits are 0700
// via os.Stat, rather than merely trusting that os.MkdirAll(..., 0700)
// returned no error - Go's os.MkdirAll mode is subject to the process
// umask, so a real umask could silently produce weaker permissions than
// requested, and this project's isolation claim (Clarification 18: "KV
// cache/WAL storage lives in per-tenant directories with filesystem
// permissions enforced") rests on this actually being 0700.
func TestTenantStateDir_CreatesRealDirectoryWithReal0700Permissions(t *testing.T) {
	base := t.TempDir()

	path, err := TenantStateDir(base, "acme")
	if err != nil {
		t.Fatalf("TenantStateDir: unexpected error: %v", err)
	}

	wantPath := filepath.Join(base, "acme")
	if path != wantPath {
		t.Errorf("path = %q, want %q", path, wantPath)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("os.Stat(%q): %v", path, err)
	}
	if !info.IsDir() {
		t.Fatalf("%q is not a directory", path)
	}
	if got := info.Mode().Perm(); got != 0o700 {
		t.Errorf("real on-disk permission bits = %o, want %o (umask may have weakened MkdirAll's requested mode)", got, 0o700)
	}
}

// TestTenantStateDir_IsIdempotent proves calling TenantStateDir twice for
// the same tenant ID returns the same path without erroring - the normal
// "the daemon restarted / this profile was already started once" case.
func TestTenantStateDir_IsIdempotent(t *testing.T) {
	base := t.TempDir()

	first, err := TenantStateDir(base, "acme")
	if err != nil {
		t.Fatalf("TenantStateDir (first call): unexpected error: %v", err)
	}
	second, err := TenantStateDir(base, "acme")
	if err != nil {
		t.Fatalf("TenantStateDir (second call): unexpected error: %v", err)
	}
	if first != second {
		t.Errorf("first call returned %q, second call returned %q - want identical", first, second)
	}
}

// TestTenantStateDir_RejectsPathTraversal proves a tenant ID that could
// escape baseDir via filepath.Join (a ".." component, or an embedded path
// separator) is rejected rather than silently joined - the directory
// half of the same sanitization WrapCommand's tests exercise for the
// slice-name half.
func TestTenantStateDir_RejectsPathTraversal(t *testing.T) {
	base := t.TempDir()
	for _, id := range []string{"..", "../escaped", "acme/../../escaped", "acme/nested", ""} {
		if _, err := TenantStateDir(base, id); err == nil {
			t.Errorf("TenantStateDir(tenantID=%q): expected error, got nil", id)
		}
	}
}

// TestTenantStateDir_DetectsPermissionDrift proves that if a tenant
// directory already exists but its permission bits have drifted away
// from 0700 (e.g. created by something else with looser permissions),
// TenantStateDir reports an error rather than silently trusting a
// directory it did not itself just create with the right mode.
func TestTenantStateDir_DetectsPermissionDrift(t *testing.T) {
	base := t.TempDir()
	drifted := filepath.Join(base, "acme")
	if err := os.Mkdir(drifted, 0o755); err != nil {
		t.Fatalf("setup: os.Mkdir: %v", err)
	}

	if _, err := TenantStateDir(base, "acme"); err == nil {
		t.Fatalf("TenantStateDir: expected error for drifted permissions (0755 present, 0700 required), got nil")
	}
}

// TestWrapCommand_RealSystemdRunInvocation is the one real-subprocess
// test in this file. When systemd-run is genuinely available on this
// build host's PATH (checked via exec.LookPath, never assumed), it
// invokes the exact wrapped argv shape WrapCommand returns against a
// harmless real command and asserts a real exit code 0 - proving the
// argv shape this package constructs is not merely plausible-looking
// strings but a real, acceptable systemd-run invocation. Per
// Constitution §11.4.3 (per-environment-topology test dispatch), when
// systemd-run is not on PATH this SKIPs with the real observed reason
// rather than fabricating a PASS; every other test in this file runs
// unconditionally regardless of systemd-run's availability.
func TestWrapCommand_RealSystemdRunInvocation(t *testing.T) {
	systemdRunPath, err := exec.LookPath("systemd-run")
	if err != nil {
		t.Skipf("systemd-run not found on PATH (exec.LookPath: %v) - this build host has no usable systemd-run, SKIPping per Constitution §11.4.3 rather than fabricating a PASS", err)
	}

	// A distinct, greppable slice name for this test run so a failure's
	// captured evidence is unambiguous about which invocation produced it.
	path, args, err := WrapCommand(WrapConfig{TenantID: "cgrouptest"}, "/bin/true")
	if err != nil {
		t.Fatalf("WrapCommand: unexpected error: %v", err)
	}
	if path != "systemd-run" {
		t.Fatalf("WrapCommand path = %q, want %q", path, "systemd-run")
	}

	cmd := exec.Command(systemdRunPath, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		// A failure here could be this code's argv shape being wrong, or
		// it could be a genuinely environmental condition this code has
		// no control over (no user D-Bus session / no XDG_RUNTIME_DIR /
		// sandboxed systemd absence) - distinguish honestly rather than
		// either silently passing or hard-failing on an environmental
		// condition unrelated to WrapCommand's own correctness.
		combined := string(out)
		if strings.Contains(combined, "Failed to connect to bus") ||
			strings.Contains(combined, "Failed to create bus connection") ||
			strings.Contains(combined, "No such file or directory") && strings.Contains(combined, "bus") {
			t.Skipf("systemd-run present on PATH but this build host's environment cannot run it (real observed output: %q) - SKIPping per Constitution §11.4.3 rather than fabricating a PASS or a spurious FAIL unrelated to WrapCommand's own argv-shape correctness", strings.TrimSpace(combined))
		}
		t.Fatalf("real systemd-run invocation with WrapCommand's argv failed: %v\noutput: %s", err, combined)
	}
}
