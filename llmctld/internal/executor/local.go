// Package executor is the control-plane/data-plane boundary of llmctld.
//
// llmctld NEVER reimplements model download, engine build, or scheduler
// logic - that logic already lives, verified and tested, in the real
// bin/llmctl bash script + lib/*.sh at the repository root. Per
// docs/architecture.md / docs/cluster-architecture.md (control-plane vs
// data-plane), the ONLY thing llmctld does for a model profile on the
// local host it is running on is shell out to the real bin/llmctl exactly
// as a human operator would from the command line.
//
// Real CLI surface this file shells out to (confirmed by reading
// bin/llmctl's dispatch `case` statement and lib/scheduler.sh directly,
// 2026-09-15 - never assumed):
//
//	start <profile> [more...]   -> bin/llmctl case "start)    sched_start "$@" ;;"
//	                               -> lib/scheduler.sh sched_start -> _sched_start_impl
//	stop  <profile|all>         -> bin/llmctl case "stop)     sched_stop "$@" ;;"
//	                               -> lib/scheduler.sh sched_stop -> _sched_stop_impl
//	status                      -> bin/llmctl case "status)   sched_status ;;"
//	                               -> lib/scheduler.sh sched_status
//
// There is NO single unified "status by profile name" subcommand -
// sched_status (lib/scheduler.sh) always lists every currently-running
// profile (it loops every "${LLMCTL_RUNTIME_DIR}"/*.run file) and takes no
// argument at all; `bin/llmctl status <profile>` is not a real invocation
// shape. Status(profile) below therefore shells out to the real, unfiltered
// `bin/llmctl status` and filters the real captured output down to the
// header row plus the row(s) whose leftmost (profile) column matches, on
// the Go side - it never invents a bash-side per-profile status feature
// that does not exist.
//
// LLMCTL_DRY_RUN: a real, pre-existing feature of bin/llmctl - NOT
// something added or assumed for this task. Confirmed by reading
// lib/common.sh:46 (`LLMCTL_DRY_RUN="${LLMCTL_DRY_RUN:-0}"`, a real
// environment-var-backed global) and every one of its call sites in
// lib/scheduler.sh, lib/service_linux.sh, lib/service_macos.sh,
// lib/engine.sh, and lib/download.sh, and by running the real script by
// hand under it before writing this file:
//
//	$ LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW=tests/fixtures/hw-baseline.json \
//	    ./bin/llmctl start small
//	[dry-run] systemctl --user start llmctl-llama@small.service
//	started small (mode=gpu, port=8085, reserved 2048 MiB RAM + 2949 MiB VRAM)
//
// Under LLMCTL_DRY_RUN=1, lib/scheduler.sh's sched_build_launch skips its
// "model not downloaded" existence check (lib/scheduler.sh lines ~130 and
// ~148) and lib/service_linux.sh's _svc_sys prints
// "[dry-run] systemctl --user <verb> <unit>" instead of actually invoking
// systemctl - so a Start/Stop call under LLMCTL_DRY_RUN=1 never downloads a
// model, never spawns a real inference server, and never touches the
// operator's real systemd --user session; it is the exact mechanism the
// project's own bash test suite (tests/test_scheduler.sh, tests/test_cli.sh)
// already relies on for hermetic, side-effect-free testing of this same
// bash code. local_test.go reuses it rather than mocking exec.Command,
// per this project's "no fakes beyond unit tests" anti-bluff discipline -
// every LocalExecutor test runs the real bin/llmctl as a real subprocess.
//
// LocalExecutor itself NEVER sets LLMCTL_DRY_RUN - that decision belongs to
// whoever launches llmctld (or its tests), and is inherited from the
// calling process's environment exactly as any other bin/llmctl invocation
// would inherit it, via exec.Command's default of copying os.Environ() when
// Cmd.Env is left nil.
package executor

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
)

// Config configures a LocalExecutor.
type Config struct {
	// LLMCtlPath is the path to the real bin/llmctl script/binary this
	// executor shells out to. May be absolute, or a bare name resolved via
	// $PATH by os/exec at call time (matching how a human operator would
	// invoke it from an interactive shell). Left empty, it defaults to the
	// bare name "llmctl" - callers running llmctld against a specific
	// checkout (or a test fixture) MUST set this to that checkout's real
	// bin/llmctl path; LocalExecutor never guesses or hardcodes a
	// filesystem location that would only work from one specific working
	// directory.
	LLMCtlPath string

	// TenantID identifies the tenant this executor's real bin/llmctl
	// subprocess invocations act on behalf of. When non-empty, every
	// invocation's subprocess environment carries an additional
	// LLMCTL_TENANT_ID=<TenantID> entry, which is the real,
	// already-implemented lib/service_linux.sh tenant-aware instance-keying
	// mechanism (_svc_instance_key / _svc_ensure_tenant_slice_dropin) - the
	// real per-tenant cgroup isolation mechanism for this project's
	// systemd-unit-based service model. A systemd-run wrapper around this
	// short-lived CLI invocation (as internal/isolation.WrapCommand alone
	// would produce) cannot isolate the actual long-running model-server
	// process, since `systemctl --user start` hands the unit off to
	// systemd's own user manager, which resolves cgroup placement from the
	// UNIT's own Slice= property - never inherited from the process that
	// invoked `systemctl --user start` (see
	// internal/isolation/cgroup.go's WrapCommand doc comment for the full
	// investigation). LLMCTL_TENANT_ID is therefore the correct and
	// sufficient signal to pass through: it is the SAME environment
	// variable lib/service_linux.sh's tenant-aware unit-instance-keying
	// already reads, real and tested (tests/test_tenant_service_isolation.sh).
	// Left empty, no LLMCTL_TENANT_ID is set and behavior is byte-identical
	// to a Config with no tenant awareness at all.
	TenantID string
}

// LocalExecutor shells out to the real bin/llmctl on the local node to
// start, stop, and query the status of a model profile. It is the sole
// control-plane -> data-plane boundary for llmctld's local-host actions:
// it contains no download/engine/scheduler logic of its own, only real
// subprocess invocations of the real script.
type LocalExecutor struct {
	llmctlPath string
	tenantID   string
}

// New returns a LocalExecutor that shells out to cfg.LLMCtlPath (or the
// bare "llmctl" name, PATH-resolved, if cfg.LLMCtlPath is empty).
func New(cfg Config) *LocalExecutor {
	path := cfg.LLMCtlPath
	if path == "" {
		path = "llmctl"
	}
	return &LocalExecutor{llmctlPath: path, tenantID: cfg.TenantID}
}

// filterOutTenantIDEnv returns a copy of env (in os.Environ()'s
// "KEY=VALUE" string form) with every entry named LLMCTL_TENANT_ID
// removed - the mechanism that guarantees run()'s explicitly-untenanted
// path never lets a stray inherited value pass through to the real
// bin/llmctl subprocess (see run()'s doc comment for why this matters).
// Preserves every other entry's exact order and value; never mutates
// env itself.
func filterOutTenantIDEnv(env []string) []string {
	filtered := make([]string, 0, len(env))
	for _, kv := range env {
		if strings.HasPrefix(kv, "LLMCTL_TENANT_ID=") {
			continue
		}
		filtered = append(filtered, kv)
	}
	return filtered
}

// WithTenant returns a COPY of e scoped to tenantID - the base
// executor's llmctlPath is preserved, only the tenant scoping changes.
// e itself is never mutated: LocalExecutor is a small, immutable-by-
// convention value, so a single shared "base" executor (constructed
// once, e.g. at cmd/llmctld daemon startup) can safely serve many
// different tenants' concurrent requests, each via its own
// base.WithTenant(id) call, without one tenant's dispatch ever sharing
// mutable state with another's.
func (e *LocalExecutor) WithTenant(tenantID string) *LocalExecutor {
	return &LocalExecutor{llmctlPath: e.llmctlPath, tenantID: tenantID}
}

// run invokes the real bin/llmctl with args, inheriting the calling
// process's environment (os/exec's default when Cmd.Env is nil) so a
// caller's LLMCTL_DRY_RUN, LLMCTL_FAKE_HW, LLMCTL_STATE_DIR, etc. reach the
// real subprocess exactly as they would from an interactive shell. It
// returns the real combined stdout+stderr the subprocess produced (bin/
// llmctl's own logging helpers, lib/common.sh's log/info/warn/err, write to
// both streams depending on level, so combining them is required to
// capture every real message a caller might need to match against - e.g.
// the "unknown profile: ..." error bin/llmctl prints to stderr via `err`).
func (e *LocalExecutor) run(args ...string) (string, error) {
	cmd := exec.Command(e.llmctlPath, args...)
	if e.tenantID != "" {
		// Deliberately append to os.Environ() rather than leaving Cmd.Env
		// nil: nil would still inherit the parent environment (os/exec's
		// default), but there would be nowhere to add LLMCTL_TENANT_ID
		// without first materializing that inherited set explicitly.
		cmd.Env = append(os.Environ(), "LLMCTL_TENANT_ID="+e.tenantID)
	} else {
		// Explicitly untenanted MUST mean genuinely untenanted, never
		// "whatever this process happened to inherit" - an independent
		// code review flagged that leaving Cmd.Env nil here would let a
		// stray LLMCTL_TENANT_ID already present in llmctld's OWN
		// process environment (e.g. leaked from its parent shell/
		// launcher) silently pass through to the subprocess, breaking
		// the "untenanted is byte-identical to before" guarantee this
		// executor's own tests rely on. filterOutTenantIDEnv strips any
		// such inherited entry before it ever reaches cmd.Env.
		cmd.Env = filterOutTenantIDEnv(os.Environ())
	}
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	err := cmd.Run()
	combined := out.String()
	if err != nil {
		return combined, fmt.Errorf("bin/llmctl %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(combined))
	}
	return combined, nil
}

// Start shells out to the real `bin/llmctl start <profile>`
// (lib/scheduler.sh sched_start -> _sched_start_impl), which starts the
// profile if its combined memory/VRAM footprint fits the host's budget, or
// fails with a real, captured error (e.g. "unknown profile: ...", or a
// "cannot start '<profile>': needs N MiB RAM ..." budget refusal) exactly
// as it would for a human operator running the same command.
func (e *LocalExecutor) Start(profile string) error {
	_, err := e.run("start", profile)
	return err
}

// Stop shells out to the real `bin/llmctl stop <profile>`
// (lib/scheduler.sh sched_stop -> _sched_stop_impl), which stops the named
// profile's service (or every running profile when profile is "all",
// matching bin/llmctl's own accepted argument shape).
func (e *LocalExecutor) Stop(profile string) error {
	_, err := e.run("stop", profile)
	return err
}

// planDoc is the subset of `bin/llmctl plan --json`'s real
// lib/catalog.sh:catalog_plan_json schema this method needs -
// confirmed by hand before writing this method:
//
//	$ LLMCTL_FAKE_HW=tests/fixtures/hw-baseline.json ./bin/llmctl plan --json
//	{"profiles": {"small": {"mode": "gpu", "ram_mb": 2048,
//	 "vram_mb": 2949, ...}, ...}, ...}
type planDoc struct {
	Profiles map[string]struct {
		RAMMB  int64 `json:"ram_mb"`
		VRAMMB int64 `json:"vram_mb"`
	} `json:"profiles"`
}

// Footprint shells out to the real `bin/llmctl plan --json`
// (lib/catalog.sh's catalog_plan_json) and returns profile's own real,
// reported ram_mb/vram_mb - the resource DEMAND
// 002-cluster-model-scheduler's cluster.Place() needs to bin-pack this
// profile onto a candidate node, since this codebase has no separate
// Go-side reimplementation of bin/llmctl's own per-profile sizing
// (Constitution's control-plane/data-plane split this package's own
// doc comment already documents - llmctld never reimplements catalog/
// scheduler logic that already lives, tested, in bin/llmctl + lib/*.sh).
//
// Unlike Start/Stop/Status, Footprint is deliberately NOT tenant-scoped
// (e.tenantID is never set on its subprocess environment): a profile's
// resource footprint is a property of the profile + the querying node's
// own hardware/catalog, never of which tenant is asking - the SAME
// profile costs the SAME RAM/VRAM regardless of tenant.
func (e *LocalExecutor) Footprint(profile string) (ramMB, vramMB int64, err error) {
	cmd := exec.Command(e.llmctlPath, "plan", "--json")
	cmd.Env = filterOutTenantIDEnv(os.Environ())
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	if runErr := cmd.Run(); runErr != nil {
		return 0, 0, fmt.Errorf("bin/llmctl plan --json: %w: %s", runErr, strings.TrimSpace(out.String()))
	}

	var doc planDoc
	if jsonErr := json.Unmarshal(out.Bytes(), &doc); jsonErr != nil {
		return 0, 0, fmt.Errorf("bin/llmctl plan --json: parse output: %w", jsonErr)
	}

	fp, known := doc.Profiles[profile]
	if !known {
		return 0, 0, fmt.Errorf("bin/llmctl plan --json: unknown profile %q", profile)
	}
	return fp.RAMMB, fp.VRAMMB, nil
}

// Status shells out to the real `bin/llmctl status`
// (lib/scheduler.sh sched_status), which - per the real script, confirmed
// above - always lists every currently-running profile and accepts no
// per-profile argument. Status filters the real captured output down to
// the header row plus any row whose leftmost (profile) column equals
// profile, so a caller gets exactly that profile's real reported
// port/mode/RAM/VRAM/enabled/state - or, when bin/llmctl reports nothing is
// running at all ("no llmctl services running"), that real message
// verbatim.
func (e *LocalExecutor) Status(profile string) (string, error) {
	out, err := e.run("status")
	if err != nil {
		return "", err
	}

	lines := strings.Split(out, "\n")
	filtered := make([]string, 0, len(lines))
	for i, line := range lines {
		if i == 0 {
			// Header row ("profile   port   mode   ...") or the
			// no-services-running message - always kept so the caller can
			// tell the difference between "profile not running" and
			// "nothing is running at all".
			filtered = append(filtered, line)
			continue
		}
		fields := strings.Fields(line)
		if len(fields) > 0 && fields[0] == profile {
			filtered = append(filtered, line)
		}
	}
	return strings.Join(filtered, "\n"), nil
}

// --- 003-kv-cache-replication User Story 2: real engine slot save/restore --
//
// EngineSlotAction is the closed set of the real llama-server
// /slots/:id_slot HTTP endpoint's supported action query values
// (save/restore) - confirmed present in the pinned vendored
// submodules/llama.cpp source by this project's own T060 investigation
// (tools/server/server.cpp:285-286 / server-context.cpp:5288-5320+,
// gated behind --slot-save-path) and matching llama.cpp's own long-
// standing, publicly documented server wire contract for this
// capability (examples/server/README.md's "Save & Restore Slot"
// section): POST http://<engine-host>:<port>/slots/{id_slot}?action=save
// (or ?action=restore) with a JSON body {"filename": "<name>"} - the
// filename names a file UNDER the engine's own --slot-save-path
// directory, never an absolute/parent-escaping path.
//
// SaveSlot/RestoreSlot additionally refuse a filename containing a path
// separator BEFORE ever sending it, as a second, our-own-side line of
// defense (Constitution §11.4.133 host-safety: never hand the engine an
// ambiguous path when this caller can trivially validate it is a bare
// filename first) - independent of whatever validation the real engine
// itself does.
//
// Honest boundary (Constitution §11.4.6): this wiring is built against
// the well-established, publicly documented, and independently
// T060-investigated wire contract. A genuine end-to-end round trip
// against the real pinned llama-server binary is exercised by
// test/integration's real-engine tests (T012/T014) - this environment
// could not fetch the pinned submodule commit to build+boot that real
// binary (see this feature's own final report for the confirmed,
// investigated reason), so those tests honestly SKIP here rather than
// run; SaveSlot/RestoreSlot's own request-construction/response-handling
// logic is instead proven against a real HTTP server implementing this
// SAME documented contract in local_test.go, matching this codebase's
// established "decouple the transport/logic from the specific remote
// implementation" testing convention (internal/replication/forwarder_test.go).
const (
	engineSlotActionSave    = "save"
	engineSlotActionRestore = "restore"
)

// engineSlotRequestTimeout bounds a single real HTTP call to the local
// engine's own /slots/:id_slot endpoint - a save/restore call that never
// returns must not hang its caller indefinitely (the same FR-004-style
// bounded-not-indefinite discipline internal/replication/forwarder.go
// already applies to cross-node calls, applied here to this LOCAL
// engine call).
const engineSlotRequestTimeout = 30 * time.Second

// engineSlotRequest is POST /slots/:id_slot?action=save|restore's real
// JSON request body shape.
type engineSlotRequest struct {
	Filename string `json:"filename"`
}

// ErrEngineSlotFilenameInvalid is returned by SaveSlot/RestoreSlot when
// filename is empty or contains a path separator - refused BEFORE any
// HTTP call is made (see this section's doc comment for why).
var ErrEngineSlotFilenameInvalid = errors.New("executor: engine slot filename must be a non-empty bare filename (no path separators)")

func validEngineSlotFilename(filename string) bool {
	return filename != "" && !strings.ContainsAny(filename, `/\`)
}

// SaveSlot calls the REAL local inference engine's own
// POST /slots/{slotID}?action=save endpoint (llama-server, when started
// with --slot-save-path - lib/scheduler.sh's opt-in wiring), asking it
// to save its own real, in-process attention-weight KV cache for slotID
// to filename under its --slot-save-path directory. engineBaseURL is
// the running engine's own real base HTTP URL (e.g.
// "http://127.0.0.1:8085") - LocalExecutor does not resolve this
// itself; the port a profile is running on is the caller's already-
// established concern (e.g. a real bin/llmctl status / a RunningProfile
// record), never re-derived here, matching Start/Stop's own "the
// caller names the target" convention. Returns
// ErrEngineSlotFilenameInvalid without making any HTTP call if filename
// is empty or path-like; returns the real HTTP/engine error otherwise
// (a non-2xx response, connection failure, or a real timeout) -
// 003-kv-cache-replication's internal/replication.EngineSaver is the
// caller-facing adapter that turns this into the closed
// intact/unavailable outcome (enginecache.go's own doc comment).
func (e *LocalExecutor) SaveSlot(engineBaseURL string, slotID int, filename string) error {
	return e.doEngineSlotAction(engineBaseURL, engineSlotActionSave, slotID, filename)
}

// RestoreSlot is SaveSlot's restore-side sibling: calls the real local
// engine's POST /slots/{slotID}?action=restore endpoint, asking it to
// load its real attention-weight KV cache for slotID FROM filename
// under its --slot-save-path directory (a warm-restore, User Story 2).
// The caller (internal/replication.EngineRestorer's real implementation)
// is responsible for having already confirmed filename's real on-disk
// presence/non-emptiness (enginecache.go's statFileNonEmpty) before
// calling this - RestoreSlot itself only ever asks the ENGINE to
// restore; a restore failure the engine itself reports (a corrupt file
// its own parser rejects) surfaces here as a genuine error, which
// internal/replication.RestoreOrFallback then correctly falls back from
// (FR-008), never surfaced as a correctness failure by this method
// itself.
func (e *LocalExecutor) RestoreSlot(engineBaseURL string, slotID int, filename string) error {
	return e.doEngineSlotAction(engineBaseURL, engineSlotActionRestore, slotID, filename)
}

func (e *LocalExecutor) doEngineSlotAction(engineBaseURL, action string, slotID int, filename string) error {
	if !validEngineSlotFilename(filename) {
		return ErrEngineSlotFilenameInvalid
	}
	body, err := json.Marshal(engineSlotRequest{Filename: filename})
	if err != nil {
		return fmt.Errorf("executor: marshal engine slot %s request: %w", action, err)
	}
	url := fmt.Sprintf("%s/slots/%d?action=%s", strings.TrimRight(engineBaseURL, "/"), slotID, action)
	ctx, cancel := context.WithTimeout(context.Background(), engineSlotRequestTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("executor: build engine slot %s request: %w", action, err)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("executor: engine slot %s request to %s: %w", action, url, err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		var errBody bytes.Buffer
		_, _ = errBody.ReadFrom(resp.Body)
		return fmt.Errorf("executor: engine slot %s request to %s: status %d: %s", action, url, resp.StatusCode, strings.TrimSpace(errBody.String()))
	}
	return nil
}
