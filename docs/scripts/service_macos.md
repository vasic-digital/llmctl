## Overview

`lib/service_macos.sh` is llmctl's macOS service backend: it implements the
same `svc_*` interface `lib/scheduler.sh` calls after `sched_load_backend`
detects macOS, using **launchd LaunchAgents** as the process-supervision
mechanism. Unlike the Linux backend's shared parameterized template units,
macOS has no equivalent global unit-install step — each profile gets its
own fully-rendered `~/Library/LaunchAgents/com.llmctl.<profile>.plist` with
`KeepAlive`, a widened `ThrottleInterval`, and `RunAtLoad`. It exists so
llmctl gets automatic restart-on-crash and login-time autostart on macOS
without llmctl having to supervise processes itself, while honestly
documenting where launchd's supervision model falls short of systemd's
(see `docs/architecture.md`'s "Service backends" section and the file's own
header comment).

## Prerequisites

* Sourced by `lib/scheduler.sh` (via `sched_load_backend`) or a test
  harness; it sources `common.sh` from its own directory (`_svm_dir`).
* Needs `launchctl` on `PATH` for any real (non-dry-run) invocation of
  `_svc_launchctl`; that function prints `[dry-run] launchctl ...` instead
  of executing when `LLMCTL_DRY_RUN=1`.
* Reads `${LLMCTL_SERVICES_DIR}`, `${LLMCTL_LOG_DIR}`, `${LLMCTL_ROOT}`, and
  `${LLMCTL_RUNTIME_DIR}` (all exported by `common.sh`); `svc_plist_dir`
  falls back to `${HOME}/Library/LaunchAgents` when `LLMCTL_PLIST_DIR` is
  unset.
* `svc_enable`/`svc_disable`/`svc_start`/`svc_stop`/`svc_status`/
  `svc_is_active` all address the per-user launchd GUI domain
  (`gui/$(id -u)`), which requires an active GUI login session (or an
  equivalent `bootstrap`-capable session) for real (non-dry-run) calls.

## Usage examples

Reached through `bin/llmctl` on macOS (which loads this file automatically
via `sched_load_backend`), or sourced directly in tests:

```bash
# via bin/llmctl (loads this file automatically on macOS)
llmctl install                 # ensures the LaunchAgents dir + state dirs
llmctl enable coder            # writes env + plist, bootstraps it into launchd
llmctl start fast               # scheduler writes env + calls svc_start
llmctl restart fast             # svc_restart -> svc_start (kickstart -k)
llmctl logs fast 200
llmctl disable coder            # bootout + remove plist/env
```

Sourcing it directly (mirroring `tests/test_services_crashloop.sh`):

```bash
source lib/common.sh
source lib/service_macos.sh

svc_install
svc_write_env fast llama /opt/llmctl/submodules/llama.cpp/build/bin/llama-server \
  --model /models/fast/m.gguf --host 127.0.0.1 --port 8080
svc_enable fast
svc_status fast
svc_is_active fast
svc_is_failed fast    # always returns 1 (false) outside dry-run - see Edge cases
```

Dry run (plist/env files still written for real, `launchctl` calls
printed instead of executed):

```bash
LLMCTL_DRY_RUN=1 llmctl install
LLMCTL_DRY_RUN=1 llmctl enable fast
```

## Edge cases

* **No native crash-loop give-up, by design and honestly documented** —
  launchd's `KeepAlive=true` has no equivalent of systemd's
  `StartLimitBurst` (give up permanently after N restarts within an
  interval); the file's own header comment states this is "an honest
  platform gap (documented, not silently claimed equivalent to Linux)". The
  chosen mitigation is `ThrottleInterval=60`, which bounds the *rate* of
  restarts (at most once per 60s) but never the *total* attempt count — a
  permanently-broken model restarts forever here, just slowly.
* **`svc_is_failed` always returns false (1) outside dry-run** — because
  launchd genuinely provides no signal equivalent to systemd's
  `is-failed`/permanently-given-up state for a `KeepAlive=true` job, the
  real branch honestly reports failure (`return 1`) rather than fabricating
  a crash-loop signal the platform does not have. The `LLMCTL_DRY_RUN=1`
  branch still checks a marker file (`${LLMCTL_RUNTIME_DIR}/${profile}.failed`)
  purely so the OS-agnostic status-reporting logic in `lib/scheduler.sh`
  (`sched_status`) is testable the same way on both backends, even though
  the real macOS path can never produce that state.
* **`_svc_plist_str` XML-escapes arguments** — every string placed into a
  `<string>` element (the executable path and each argument) has `&`, `<`,
  and `>` escaped (in that order, `&` first so it doesn't double-escape the
  entities it just introduced) before being written into the plist, since
  launch arguments (model paths, profile names) are not guaranteed to be
  XML-safe.
* **`svc_restart` is implemented as `svc_start`** — because
  `launchctl kickstart -k` already tears down and restarts a running job in
  one call, there is no separate "stop then start" restart primitive needed
  on this backend, unlike systemd's dedicated `restart` subcommand.
* **`svc_disable` tolerates a bootout failure** — `_svc_launchctl bootout ...
  || true` so disabling a profile that was never actually bootstrapped
  (e.g. after a crash or a manual `launchctl` intervention) doesn't abort
  the cleanup; the plist and env files are still removed afterward (outside
  dry-run).
* **`svc_write_env` writes both the env file *and* the plist in one call** —
  unlike the Linux backend (env file only, consumed by an
  `EnvironmentFile=` directive on a shared template unit), macOS has no
  per-profile template mechanism, so the exact same launch parameters are
  rendered directly into `ProgramArguments` in the plist as well as kept in
  the parallel `.env` file (which remains the source of truth the scheduler
  reads back, e.g. for `LLMCTL_ENGINE`).
* **`svc_is_active` dry-run branch defers to the reservation record** —
  identical convention to the Linux backend: under `LLMCTL_DRY_RUN=1` it
  checks `${LLMCTL_RUNTIME_DIR}/${profile}.run` rather than calling
  `launchctl print`, since there is no real launchd session state to query
  in a dry run.
* **`svc_known_profiles`** globs `*.env` under `LLMCTL_SERVICES_DIR` and
  skips (`[[ -e "${f}" ]] || continue`) the case where the directory is
  empty (literal unexpanded glob).
* **No memory-ceiling analog** — `svc_write_env`/`svc_install` set no
  cgroup-style resource directive on macOS at all (no launchd primitive
  equivalent to systemd's `MemoryHigh`/`MemoryMax`); this is documented as
  an intentional platform gap in `docs/architecture.md`, not implemented in
  this file as a partial/simulated substitute.

## Internal behaviour

1. **Setup**: resolves its own directory, sources `common.sh`, defines
   `svc_backend_name` (`"launchd"`), `svc_plist_dir`, `_svc_label`
   (`com.llmctl.<profile>`), `_svc_plist_path`.
2. **`_svc_launchctl`** — the single choke point for every `launchctl`
   invocation; dry-run prints instead of executing.
3. **`svc_install`** — ensures the LaunchAgents directory and llmctl's state
   dirs exist; unlike the Linux backend there is no template-unit content
   to write here (each profile's plist is fully rendered later by
   `svc_write_env`), so this is effectively a directory-preparation step
   plus an informational log line.
4. **`_svc_plist_str`** — escapes and wraps one value in a `<string>`
   element, used for both the executable path and every argument.
5. **`svc_write_env <profile> <engine> <exec> <args...>`** — writes the
   `.env` file (same four-line format as the Linux backend, no
   tenant-qualification support here) and, in the same call, renders the
   full LaunchAgent plist: `Label`, `ProgramArguments` (exec + args via
   `_svc_plist_str`), `KeepAlive=true`, `ThrottleInterval=60`,
   `RunAtLoad=true`, `StandardOutPath`/`StandardErrorPath` pointing at the
   profile's log file, and `WorkingDirectory` set to `${LLMCTL_ROOT}`.
6. **`_svc_domain`** — returns the launchd GUI domain string
   `gui/$(id -u)` used by every `bootstrap`/`bootout`/`kickstart`/`print`
   call.
7. **Lifecycle wrappers** — `svc_enable` (`launchctl bootstrap
   <domain> <plist>`), `svc_disable` (`bootout`, tolerant of failure, then
   removes the plist + env file outside dry-run), `svc_start`
   (`kickstart -k <domain>/<label>`), `svc_stop` (`kill SIGTERM
   <domain>/<label>`), `svc_restart` (delegates to `svc_start`),
   `svc_status` (dry-run prints; real mode `launchctl print`, tolerant of
   failure), `svc_logs` (dry-run prints a `tail` command; real mode dies if
   the log file doesn't exist yet, otherwise tails it), `svc_is_active`
   (dry-run checks the `.run` file; real mode `launchctl print` with output
   discarded, using its exit status), `svc_is_failed` (see Edge cases),
   `svc_known_profiles` (lists profiles with a `.env` file).

## Related scripts

* Sourced by `lib/scheduler.sh`'s `sched_load_backend` on macOS, and by
  `bin/llmctl` for direct `install`/`enable`/`disable`/`restart`/`logs`
  dispatch.
* Sources `lib/common.sh` (logging, `die`, `ensure_dir`, `ensure_state_dirs`).
* Sibling backend: `lib/service_linux.sh` implements the identical `svc_*`
  interface for systemd `--user`; the two are mutually exclusive per-OS
  choices made by `sched_load_backend`. This file has no
  `LLMCTL_TENANT_ID`/per-tenant isolation equivalent to
  `lib/service_linux.sh`'s cgroup `Slice=` drop-in mechanism.
* Exercised by `tests/test_services_crashloop.sh` (asserts the
  `ThrottleInterval=60` widening); the Linux-specific env/unit-generation
  assertions in `tests/test_services.sh` and the tenant-isolation
  assertions in `tests/test_tenant_service_isolation.sh` do not apply to
  this backend.

## Last verified date

2026-09-17
