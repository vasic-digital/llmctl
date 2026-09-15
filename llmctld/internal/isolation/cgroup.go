// Package isolation implements T072's per-tenant process + filesystem
// isolation on a shared llmctld cluster node (spec.md FR-049,
// Clarification 18: "Tenant isolation on a shared cluster node is
// process + namespace isolation - each tenant's model server is a
// separate OS process under its own systemd scope/cgroup with per-tenant
// memory limits, and KV cache/WAL storage lives in per-tenant
// directories with filesystem permissions enforced; this is the
// isolation mechanism SC-022's 'zero cross-tenant data leakage' claim
// rests on").
//
// Like internal/executor (see that package's doc comment for the
// project's control-plane/data-plane split), this package NEVER
// reimplements process-spawning logic - it wraps whatever real command a
// caller (internal/executor.LocalExecutor today, or a future caller)
// would otherwise invoke directly, so the exact same command runs inside
// a per-tenant systemd --user scope instead of the caller's own cgroup.
// WrapCommand returns a real, ready-to-exec argv (path + args) for the
// real `systemd-run` binary; it never shells out itself and never
// mutates a caller's exec.Command - the caller decides when and how to
// actually run the wrapped command.
//
// Real systemd-run flag semantics this package relies on (confirmed via
// `man systemd-run` + a real invocation on this build host, systemd 259
// - never assumed, per Constitution §11.4.99):
//
//		systemd-run --user --scope --slice=<name>.slice [-p PROP=VAL ...] -- <cmd> [args...]
//
//	  - --user: talk to the caller's own user-session systemd manager
//	    (systemd --user) rather than the system manager, so no root
//	    privilege is required and the scope lives entirely inside the
//	    calling user's login session.
//	  - --scope: create a transient *scope* unit rather than a *service*
//	    unit. A scope wraps an already-existing (or about-to-be
//	    exec'd-into, via systemd-run's own fork+exec of the trailing
//	    command) process tree in a cgroup, as opposed to a service, which
//	    systemd itself would be responsible for forking. This matches
//	    what llmctld needs: the caller (LocalExecutor or a future
//	    replacement) already owns the decision of exactly how the
//	    underlying model-server process is started; systemd-run's job here
//	    is only to place that process into its own tenant-scoped cgroup.
//	  - --slice=<name>.slice: nest the new transient scope under the named
//	    parent slice (itself a cgroup), so every scope for one tenant
//	    shares one addressable cgroup subtree
//	    (llmctl-tenant-<id>.slice/...). This is the mechanism the FR-049
//	    "separate OS process under its own systemd scope/cgroup with
//	    per-tenant memory limits" requirement is built on - a memory
//	    limit applied as a slice-level property (or, as here, directly on
//	    the scope via -p) is enforced by the kernel cgroup controller,
//	    independent of anything the wrapped process itself does.
//	  - -p NAME=VALUE (long form --property=): set a unit resource-control
//	    property on the transient unit at creation time. MemoryMax=<bytes>
//	    is a real property documented in systemd.resource-control(5); a
//	    plain decimal integer is interpreted as a byte count (no K/M/G
//	    suffix required). This mirrors lib/service_linux.sh's own
//	    MemoryHigh=/MemoryMax= convention for the project's systemd
//	    *service* units (see that file's OS-level memory-protection
//	    comment) - the Go and bash sides express the same "OS-level
//	    memory protection" requirement via the same systemd mechanism,
//	    just for a *scope* instead of a *service* unit.
//	  - --: end systemd-run's own option parsing, so everything after it
//	    is unambiguously the command (and its arguments) to exec, never
//	    mis-parsed as a further systemd-run flag even if, say, a tenant's
//	    model path happened to start with a "-".
package isolation

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// tenantIDPattern is the closed set of characters this package accepts
// in a tenant ID: it must start with an alphanumeric character (never
// "-", "_", or "." - a leading "-" in particular could be mistaken for
// an option flag by some downstream tool, even though it is embedded
// inside a single --slice=... argument here) and may otherwise contain
// only alphanumerics, "-", "_", and "." - the real character set a
// systemd unit/slice name permits, and also a safe, unambiguous
// component for a filesystem path segment.
var tenantIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$`)

// validateTenantID rejects any tenant ID that could break out of the
// `--slice=llmctl-tenant-<id>.slice` argument context WrapCommand builds,
// or (independently, for TenantStateDir) escape a filepath.Join(baseDir,
// tenantID) via a path-traversal component - never silently sanitizing
// or escaping an unsafe value, only accepting an already-safe one or
// refusing outright (Constitution §11.4.6: no guessing about what a
// caller "probably meant").
func validateTenantID(tenantID string) error {
	if !tenantIDPattern.MatchString(tenantID) {
		return fmt.Errorf("isolation: invalid tenant ID %q: must match %s", tenantID, tenantIDPattern.String())
	}
	// Defense in depth beyond the charset check above: ".." alone matches
	// tenantIDPattern (dots are a permitted character for ordinary
	// tenant IDs like "tenant.3"), but as a tenant ID it is exactly the
	// path-traversal component filepath.Join would otherwise resolve
	// upward through in TenantStateDir. Reject it unconditionally rather
	// than trying to special-case "when is a dot safe".
	if strings.Contains(tenantID, "..") {
		return fmt.Errorf("isolation: invalid tenant ID %q: must not contain \"..\"", tenantID)
	}
	return nil
}

// WrapConfig configures WrapCommand's per-tenant systemd-run wrapping.
type WrapConfig struct {
	// TenantID identifies the tenant whose scope/slice the wrapped
	// command runs under. Validated by validateTenantID before being
	// interpolated into the --slice=... argument; an invalid value makes
	// WrapCommand return a non-nil error rather than a malformed or
	// unsafe argv.
	TenantID string

	// MemoryMaxBytes is an optional per-tenant memory ceiling, applied
	// as the transient scope's MemoryMax= resource-control property (a
	// plain byte count, no unit suffix). Zero (the default) adds NO
	// memory-limit property at all - mirroring
	// internal/replication/checkpoint.go's CheckpointConfig.MaxWALSizeBytes
	// convention: an optional numeric limit is opt-in, never a silently
	// invented default (Constitution §11.4.6). A caller wanting the
	// per-tenant memory ceiling FR-049 describes sets a real value for
	// its own deployment.
	MemoryMaxBytes uint64
}

// WrapCommand returns the real systemd-run invocation (path + argv) that
// runs cmdPath (with args) inside a transient, per-tenant systemd --user
// scope nested under llmctl-tenant-<cfg.TenantID>.slice. It PREPENDS the
// systemd-run wrapper arguments rather than replacing cmdPath/args, so
// the returned (path, wrappedArgs) is directly usable as
// exec.Command(path, wrappedArgs...) by internal/executor.LocalExecutor
// (or any future caller) in place of exec.Command(cmdPath, args...) -
// WrapCommand itself never invokes exec.Command; it only constructs the
// argv a caller will use to do so.
//
// cfg.TenantID is validated before being interpolated into the
// --slice=... argument (see validateTenantID's doc comment for the
// exact character-set and path-traversal rules); an invalid tenant ID
// makes WrapCommand return a non-nil error and no usable argv, rather
// than a slice-name argument a malicious or malformed tenant ID could
// break out of, or inject extra systemd-run flags into.
func WrapCommand(cfg WrapConfig, cmdPath string, args ...string) (path string, wrappedArgs []string, err error) {
	if err := validateTenantID(cfg.TenantID); err != nil {
		return "", nil, err
	}

	wrapped := []string{
		"--user",
		"--scope",
		fmt.Sprintf("--slice=llmctl-tenant-%s.slice", cfg.TenantID),
	}
	if cfg.MemoryMaxBytes > 0 {
		wrapped = append(wrapped, "-p", "MemoryMax="+strconv.FormatUint(cfg.MemoryMaxBytes, 10))
	}
	wrapped = append(wrapped, "--", cmdPath)
	wrapped = append(wrapped, args...)

	return "systemd-run", wrapped, nil
}

// tenantDirPerm is the exact permission bits Clarification 18/FR-049
// require for a tenant's KV-cache/WAL state directory: readable,
// writable, and executable (traversable) only by the directory's own
// owner (the user llmctld itself runs as) - no group or other access at
// all. This is the numeric literal every real permission check in this
// file compares against; it is never derived indirectly, so a reader can
// see the exact required value at every use site.
const tenantDirPerm = 0o700

// TenantStateDir computes, and (idempotently) ensures on disk, the
// per-tenant state directory filepath.Join(baseDir, tenantID) that
// Clarification 18 requires KV-cache/WAL storage to live under, with
// real, verified 0700 filesystem permissions.
//
// tenantID is validated by the same validateTenantID rules WrapCommand
// uses (see its doc comment) before being joined onto baseDir - in
// particular this rejects a ".." component or an embedded path
// separator, which would otherwise let filepath.Join produce a path
// escaping baseDir entirely.
//
// If the directory does not yet exist, TenantStateDir creates it with
// requested mode 0700 via os.MkdirAll, then immediately re-reads its
// REAL on-disk permission bits via os.Stat and fails if they are not
// exactly 0700 - os.MkdirAll's requested mode is subject to the calling
// process's umask, so "MkdirAll returned no error" alone does not prove
// the directory actually ended up at 0700; this project's whole
// isolation claim rests on that real bit pattern, so it is PROVEN here
// rather than assumed.
//
// If the directory already exists, TenantStateDir does not attempt to
// create it again (avoiding a spurious error on the ordinary
// "llmctld restarted, this tenant was already provisioned" path), but
// still re-verifies its real permission bits and returns an error if
// they have drifted away from 0700 - defending against a directory that
// was created by something else with looser permissions before llmctld
// ever saw it.
func TenantStateDir(baseDir, tenantID string) (string, error) {
	if err := validateTenantID(tenantID); err != nil {
		return "", err
	}

	path := filepath.Join(baseDir, tenantID)

	info, statErr := os.Stat(path)
	switch {
	case statErr == nil:
		if !info.IsDir() {
			return "", fmt.Errorf("isolation: tenant state path %q exists and is not a directory", path)
		}
	case os.IsNotExist(statErr):
		if err := os.MkdirAll(path, tenantDirPerm); err != nil {
			return "", fmt.Errorf("isolation: creating tenant state dir %q: %w", path, err)
		}
		var err error
		info, err = os.Stat(path)
		if err != nil {
			return "", fmt.Errorf("isolation: stat after creating tenant state dir %q: %w", path, err)
		}
	default:
		return "", fmt.Errorf("isolation: stat tenant state dir %q: %w", path, statErr)
	}

	if got := info.Mode().Perm(); got != tenantDirPerm {
		return "", fmt.Errorf("isolation: tenant state dir %q has permission bits %o, want %o (a process umask, or a directory created by something else, may have weakened it - refusing to trust it for per-tenant isolation)", path, got, tenantDirPerm)
	}

	return path, nil
}
