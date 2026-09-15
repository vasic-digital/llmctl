package executor

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// llmctlBinPath returns the absolute path to the real bin/llmctl script at
// the repository root, computed from this test file's own location (via
// runtime.Caller) rather than an assumed working directory, so it resolves
// correctly regardless of where `go test` is invoked from.
//
// Real, empirically-confirmed layout (verified 2026-09-15):
//
//	<repo>/bin/llmctl                          <- the real data-plane script
//	<repo>/tests/fixtures/hw-baseline.json     <- the fixture the bash test
//	                                               suite (tests/test_cli.sh,
//	                                               tests/test_scheduler.sh)
//	                                               already uses for
//	                                               deterministic LLMCTL_DRY_RUN
//	                                               runs
//	<repo>/llmctld/internal/executor/local_test.go  <- this file
func llmctlBinPath(t *testing.T) string {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller(0) failed - cannot locate this test file")
	}
	repoRoot := filepath.Join(filepath.Dir(thisFile), "..", "..", "..")
	bin := filepath.Join(repoRoot, "bin", "llmctl")
	if _, err := os.Stat(bin); err != nil {
		t.Fatalf("real bin/llmctl not found at %s (repo layout changed?): %v", bin, err)
	}
	return bin
}

func llmctlFakeHWFixture(t *testing.T) string {
	t.Helper()
	repoRoot := filepath.Join(filepath.Dir(llmctlBinPath(t)), "..")
	fixture := filepath.Join(repoRoot, "tests", "fixtures", "hw-baseline.json")
	if _, err := os.Stat(fixture); err != nil {
		t.Fatalf("hw-baseline.json fixture not found at %s: %v", fixture, err)
	}
	return fixture
}

// newDryRunExecutor builds a LocalExecutor pointed at the REAL bin/llmctl
// script, with a fully isolated per-test state tree (mirroring
// tests/helpers.sh's test_setup_env exactly - same env var set, same
// directory layout) and LLMCTL_DRY_RUN=1 so the real subprocess never
// downloads a model, never touches the real user's systemd --user session,
// and never binds a real port - it only ever prints
// "[dry-run] systemctl --user ..." (bin/llmctl -> lib/service_linux.sh
// _svc_sys) and writes state files under the isolated temp tree.
//
// This is real-subprocess testing, not a Go-side mock: every assertion in
// this file is against bytes that the real bin/llmctl bash script actually
// printed to stdout/stderr in this test run.
func newDryRunExecutor(t *testing.T) *LocalExecutor {
	t.Helper()
	tmp := t.TempDir()

	stateDir := filepath.Join(tmp, "state")
	runtimeDir := filepath.Join(stateDir, "run")
	env := map[string]string{
		"LLMCTL_STATE_DIR":    stateDir,
		"LLMCTL_RUNTIME_DIR":  runtimeDir,
		"LLMCTL_CONFIG_DIR":   filepath.Join(tmp, "config"),
		"LLMCTL_DATA_DIR":     filepath.Join(tmp, "data"),
		"LLMCTL_MODELS_DIR":   filepath.Join(tmp, "models"),
		"LLMCTL_LOG_DIR":      filepath.Join(stateDir, "logs"),
		"LLMCTL_VERIFY_DIR":   filepath.Join(stateDir, "verify"),
		"LLMCTL_SERVICES_DIR": filepath.Join(stateDir, "services"),
		"LLMCTL_UNIT_DIR":     filepath.Join(tmp, "systemd-user"),
		"LLMCTL_PLIST_DIR":    filepath.Join(tmp, "LaunchAgents"),
		"NO_COLOR":            "1",
		"LLMCTL_DRY_RUN":      "1",
		"LLMCTL_FAKE_HW":      llmctlFakeHWFixture(t),
	}
	for k, v := range env {
		t.Setenv(k, v)
	}
	if err := os.MkdirAll(runtimeDir, 0o755); err != nil {
		t.Fatalf("mkdir runtime dir: %v", err)
	}

	return New(Config{LLMCtlPath: llmctlBinPath(t)})
}

// TestLocalExecutor_StartStatusStop_RealDryRunSubprocess drives Start,
// Status, and Stop against the REAL bin/llmctl script (LLMCTL_DRY_RUN=1),
// asserting on the real captured stdout the real subprocess produced -
// empirically confirmed by hand before writing this test:
//
//	$ LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW=tests/fixtures/hw-baseline.json \
//	    ./bin/llmctl start small
//	[llmctl] wrote .../state/services/small.env
//	[dry-run] systemctl --user start llmctl-llama@small.service
//	started small (mode=gpu, port=8085, reserved 2048 MiB RAM + 3973 MiB VRAM)
//
//	$ ./bin/llmctl status
//	profile          port   mode     RAM MiB    VRAM MiB   enabled  state
//	small            8085   gpu      2048       3973       no       running
//
//	$ ./bin/llmctl stop small
//	[dry-run] systemctl --user stop llmctl-llama@small.service
//	stopped small
//
//	$ ./bin/llmctl status
//	no llmctl services running
func TestLocalExecutor_StartStatusStop_RealDryRunSubprocess(t *testing.T) {
	exec := newDryRunExecutor(t)

	if err := exec.Start("small"); err != nil {
		t.Fatalf("Start(small) returned an error against the real dry-run subprocess: %v", err)
	}

	status, err := exec.Status("small")
	if err != nil {
		t.Fatalf("Status(small) returned an error: %v", err)
	}
	if !strings.Contains(status, "small") {
		t.Errorf("Status(small) output does not mention the profile; got:\n%s", status)
	}
	if !strings.Contains(status, "running") {
		t.Errorf("Status(small) output does not report 'running'; got:\n%s", status)
	}

	if err := exec.Stop("small"); err != nil {
		t.Fatalf("Stop(small) returned an error against the real dry-run subprocess: %v", err)
	}

	statusAfterStop, err := exec.Status("small")
	if err != nil {
		t.Fatalf("Status(small) after Stop returned an error: %v", err)
	}
	// Real bin/llmctl (lib/scheduler.sh sched_status) prints the literal
	// "no llmctl services running" message once nothing is running - note
	// that message itself contains the substring "running", so the correct
	// assertion is that the profile's OWN row is gone, not a naive
	// substring check on the word "running".
	if strings.Contains(statusAfterStop, "small") {
		t.Errorf("Status(small) after Stop still lists 'small'; got:\n%s", statusAfterStop)
	}
	if !strings.Contains(statusAfterStop, "no llmctl services running") {
		t.Errorf("Status(small) after Stop does not report the real bin/llmctl no-services message; got:\n%s", statusAfterStop)
	}
}

// TestLocalExecutor_Start_UnknownProfile_RealError asserts Start surfaces
// the REAL error bin/llmctl produces for an unrecognised profile (real
// exit code 1 + real "unknown profile: ..." message from
// lib/scheduler.sh's _sched_start_impl), the same behaviour
// tests/test_cli.sh's "unknown profile -> clear error, exit 1" case
// already covers on the bash side.
func TestLocalExecutor_Start_UnknownProfile_RealError(t *testing.T) {
	exec := newDryRunExecutor(t)

	err := exec.Start("nosuchprofile")
	if err == nil {
		t.Fatal("Start(nosuchprofile) unexpectedly succeeded against the real subprocess")
	}
	if !strings.Contains(err.Error(), "unknown profile: nosuchprofile") {
		t.Errorf("Start(nosuchprofile) error does not contain the real bin/llmctl message; got: %v", err)
	}
}

// newDryRunExecutorForTenant is identical to newDryRunExecutor except the
// returned LocalExecutor is configured with Config.TenantID set - and,
// critically, LLMCTL_TENANT_ID is deliberately NEVER set via t.Setenv here,
// so the only way it can reach the real bin/llmctl subprocess is if
// LocalExecutor's own run() explicitly injects it. That is the exact
// behavior under test: a real dry-run bin/llmctl subprocess, with the real
// lib/service_linux.sh tenant-aware instance-keying (_svc_instance_key /
// _svc_ensure_tenant_slice_dropin) that already exists on the bash side,
// engaging ONLY because LocalExecutor passed the tenant ID through.
func newDryRunExecutorForTenant(t *testing.T, tenantID string) (exec *LocalExecutor, servicesDir string) {
	t.Helper()
	tmp := t.TempDir()

	stateDir := filepath.Join(tmp, "state")
	runtimeDir := filepath.Join(stateDir, "run")
	servicesDir = filepath.Join(stateDir, "services")
	env := map[string]string{
		"LLMCTL_STATE_DIR":    stateDir,
		"LLMCTL_RUNTIME_DIR":  runtimeDir,
		"LLMCTL_CONFIG_DIR":   filepath.Join(tmp, "config"),
		"LLMCTL_DATA_DIR":     filepath.Join(tmp, "data"),
		"LLMCTL_MODELS_DIR":   filepath.Join(tmp, "models"),
		"LLMCTL_LOG_DIR":      filepath.Join(stateDir, "logs"),
		"LLMCTL_VERIFY_DIR":   filepath.Join(stateDir, "verify"),
		"LLMCTL_SERVICES_DIR": servicesDir,
		"LLMCTL_UNIT_DIR":     filepath.Join(tmp, "systemd-user"),
		"LLMCTL_PLIST_DIR":    filepath.Join(tmp, "LaunchAgents"),
		"NO_COLOR":            "1",
		"LLMCTL_DRY_RUN":      "1",
		"LLMCTL_FAKE_HW":      llmctlFakeHWFixture(t),
	}
	for k, v := range env {
		t.Setenv(k, v)
	}
	if err := os.MkdirAll(runtimeDir, 0o755); err != nil {
		t.Fatalf("mkdir runtime dir: %v", err)
	}

	return New(Config{LLMCtlPath: llmctlBinPath(t), TenantID: tenantID}), servicesDir
}

// TestLocalExecutor_Start_WithTenantID_WritesTenantScopedEnvFile is the
// real-subprocess proof that LocalExecutor's Config.TenantID actually
// reaches bin/llmctl's real subprocess environment as LLMCTL_TENANT_ID -
// closing T072's disclosed gap (WrapCommand alone would only isolate this
// short-lived CLI invocation, never the long-running systemd-unit-managed
// server process; see internal/isolation/cgroup.go). The oracle is the
// REAL lib/service_linux.sh tenant-aware instance-keying mechanism
// (_svc_instance_key) that already exists on the bash side (see
// tests/test_tenant_service_isolation.sh): when LLMCTL_TENANT_ID reaches
// the subprocess, svc_write_env writes to a tenant-qualified env file
// instead of the bare profile name. This is real-subprocess testing, not a
// mock: the assertion is on a real file the real bash script actually
// wrote (or didn't).
func TestLocalExecutor_Start_WithTenantID_WritesTenantScopedEnvFile(t *testing.T) {
	e, servicesDir := newDryRunExecutorForTenant(t, "tenant-a")

	if err := e.Start("small"); err != nil {
		t.Fatalf("Start(small) with Config.TenantID=tenant-a returned an error against the real dry-run subprocess: %v", err)
	}

	tenantEnvFile := filepath.Join(servicesDir, "tenant-a--small.env")
	if _, err := os.Stat(tenantEnvFile); err != nil {
		t.Fatalf("expected tenant-scoped env file %s to exist (proves LLMCTL_TENANT_ID reached the real bin/llmctl subprocess and lib/service_linux.sh's _svc_instance_key engaged); stat error: %v", tenantEnvFile, err)
	}

	untenantedEnvFile := filepath.Join(servicesDir, "small.env")
	if _, err := os.Stat(untenantedEnvFile); err == nil {
		t.Fatalf("bare (untenanted) env file %s unexpectedly exists - tenant scoping did not take effect, the profile fell back to the untenanted path", untenantedEnvFile)
	}
}

// TestNew_DefaultsLLMCtlPath confirms Config's LLMCtlPath is optional and
// falls back to the bare "llmctl" name (PATH-resolved by os/exec at call
// time), matching how a human operator would invoke it from a shell where
// llmctl is already on PATH.
func TestNew_DefaultsLLMCtlPath(t *testing.T) {
	exec := New(Config{})
	if exec.llmctlPath != "llmctl" {
		t.Errorf("New(Config{}) llmctlPath = %q, want %q", exec.llmctlPath, "llmctl")
	}
}
