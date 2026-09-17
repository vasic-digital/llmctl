## Overview

`lib/service_linux.sh` is llmctl's Linux service backend: it implements the
`svc_*` interface `lib/scheduler.sh` calls through after
`sched_load_backend` detects Linux, using **systemd `--user`** as the
process-supervision mechanism. It installs two parameterized (`@`) template
units — `llmctl-llama@.service` and `llmctl-colibri@.service` — writes a
per-profile `EnvironmentFile` that carries the real executable and argument
list, and drives the unit lifecycle (`enable`/`disable`/`start`/`stop`/
`restart`/`status`/`logs`) via `systemctl --user`. It also implements
optional per-tenant cgroup isolation (via a per-instance `Slice=` drop-in)
for the opt-in multi-tenant cluster mode. It exists so llmctl gets
`Restart=always` with a bounded restart budget, a `MemoryHigh`/`MemoryMax`
cgroup ceiling, and autostart-at-login (via `loginctl enable-linger`) for
free from the host OS, rather than llmctl having to supervise processes
itself (see `docs/architecture.md`'s "Service backends" section).

## Prerequisites

* Sourced by `lib/scheduler.sh` (via `sched_load_backend`) or a test
  harness; it itself sources `common.sh` and `hardware.sh` from its own
  directory (`_svl_dir`).
* Needs `systemctl` on `PATH` for any real (non-dry-run) invocation of
  `_svc_sys`; `_svc_sys` prints `[dry-run] systemctl --user ...` instead of
  executing when `LLMCTL_DRY_RUN=1`.
* `svc_install` calls `hw_probe_json | json_stdin ...` to read the total
  probed RAM for `MemoryMax`/`MemoryHigh`, so it depends on `hardware.sh`'s
  probe succeeding (or `LLMCTL_FAKE_HW` pointing at a fixture) and dies
  (`die "cannot probe memory for service limits"`) if that fails.
* `svc_install` also calls `loginctl enable-linger` if `loginctl` is on
  `PATH` (warns with a `sudo` retry hint if it fails, or warns outright if
  `loginctl` is missing) so user services survive logout.
* Reads `${LLMCTL_SERVICES_DIR}`, `${LLMCTL_LOG_DIR}`, `${LLMCTL_UNIT_DIR}`
  (falls back to `${XDG_CONFIG_HOME}/systemd/user`), and
  `${LLMCTL_RUNTIME_DIR}` (all from `common.sh`).
* Optional environment: `LLMCTL_TENANT_ID` (opt-in per-tenant isolation —
  unset is the single-host default path, byte-identical to every prior
  release), `LLMCTL_DRY_RUN`.

## Usage examples

Not meant to be invoked standalone; reached through `bin/llmctl` (which
loads the correct backend via `sched_load_backend`) or sourced directly in
tests:

```bash
# via bin/llmctl (loads this file automatically on Linux)
llmctl install                 # writes the two template units + env dirs
llmctl enable coder            # writes env, enables + starts the unit
llmctl start fast               # scheduler writes env + calls svc_start
llmctl restart fast
llmctl logs fast 200            # tail -n 200 of the profile's log
llmctl disable coder
```

Sourcing it directly (as `tests/test_services.sh` does):

```bash
source lib/common.sh
source lib/os_detect.sh
source lib/hardware.sh
source lib/service_linux.sh

svc_install
svc_write_env fast llama /opt/llmctl/submodules/llama.cpp/build/bin/llama-server \
  --model /models/fast/m.gguf --host 127.0.0.1 --port 8080 --ctx-size 8192 \
  --n-gpu-layers 99 --flash-attn auto --parallel 1 --jinja
svc_enable fast
svc_status fast
svc_is_active fast
svc_is_failed fast
```

Per-tenant isolation (opt-in, cluster mode):

```bash
LLMCTL_TENANT_ID=tenant-a llmctl enable fast   # writes services/tenant-a--fast.env,
                                                # unit llmctl-llama@tenant-a--fast.service,
                                                # drop-in Slice=llmctl-tenant-tenant-a.slice
```

Dry run (no real `systemctl`/`loginctl` calls, files still written for
real):

```bash
LLMCTL_DRY_RUN=1 llmctl install
LLMCTL_DRY_RUN=1 llmctl enable fast
```

## Edge cases

* **`ExecStart=` cannot expand `${VAR}` in the executable-path position** —
  systemd's own `$VAR`/`${VAR}` expansion in `ExecStart=` only applies to
  the *argument list*, never to the executable path itself (word 0), which
  must be resolvable at unit-parse time. The unit therefore execs through a
  fixed literal shell, `ExecStart=/bin/bash -c 'set -f; exec
  "$LLMCTL_EXEC" $LLMCTL_ARGS'`, letting that shell resolve the dynamic
  executable from its inherited `EnvironmentFile` at run time instead. This
  was root-caused via direct reproduction on this host's systemd (a bare
  `${LLMCTL_EXEC}` in `ExecStart=` always failed `status=203/EXEC`
  regardless of profile).
* **`set -f` disables glob expansion systemd itself never performed** —
  systemd's native `$VAR` expansion in `ExecStart=` word-splits but never
  globs; switching to bash's own `$LLMCTL_ARGS` expansion (needed for the
  fix above) reintroduces globbing by default, so a literal argument
  containing `*`, `?`, or `[...]` (a model path, profile name, or save-path)
  could be silently expanded against the unit's cwd. `set -f` inside the
  wrapper shell restores systemd's original no-globbing behavior exactly;
  this was proven live with a real unit + arg-printing target before being
  adopted.
* **Non-fatal `LD_LIBRARY_PATH` directory resolution in `svc_write_env`** —
  the `llama` engine's `LD_LIBRARY_PATH` line is only written if
  `cd "$(dirname "${exec_bin}")" 2>/dev/null && pwd` succeeds; if the
  executable's directory doesn't exist yet (e.g. `llmctl build llama` has
  not run), the `if` guard makes that a no-op rather than aborting the whole
  `svc_write_env` function under `set -e` mid-write, which previously left a
  truncated `.env` file (missing `LLMCTL_ARGS`) that would have launched a
  real service with no arguments at all.
* **`LD_LIBRARY_PATH` never inherits the calling shell's own value** — it is
  derived only from `exec_bin`'s own directory, deliberately never appending
  `${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}` from the invoking shell, because
  doing so previously baked a non-reproducible, shell-dependent value into a
  *persistent* systemd unit — and, measured live on this host, that
  ambient value was exactly the stale system library directory
  (`/usr/lib/x86_64-linux-gnu`) this whole mechanism exists to rank behind
  the fresh build's sibling libraries.
* **Colliding system `libggml.so.0` SONAME** — the reason
  `LD_LIBRARY_PATH` exists at all: a freshly-built `llama-server` links
  against sibling `.so` files with no covering `RPATH`, so if an unrelated
  system package installs a same-SONAME library missing newer symbols, the
  dynamic linker silently prefers the stale system copy and the server dies
  immediately on symbol lookup; prepending the exec's own directory fixes it
  (confirmed via `ldd` and a live `/health` check).
* **`svc_is_failed` (crash-loop signal)** — becomes true only once
  `StartLimitBurst` (5) restarts within `StartLimitIntervalSec` (60s) are
  exceeded and systemd gives up (`Restart=always` stops firing until
  `systemctl --user reset-failed`); under `LLMCTL_DRY_RUN=1` it instead
  checks for a marker file (`${LLMCTL_RUNTIME_DIR}/${profile}.failed`) so
  the OS-agnostic status logic in `scheduler.sh` is testable without a real
  systemd session.
* **`MemoryMax`/`MemoryHigh` set to the full probed RAM, no headroom
  subtraction** — an explicit operator decision (recorded 2026-09-15):
  served profiles get no artificial ceiling below hardware capacity; the
  cgroup directive is still present so a runaway profile gets a clean
  cgroup-level OOM-kill rather than an uncontrolled whole-host OOM event,
  but the *value* is the raw total, not total-minus-headroom.
* **`loginctl enable-linger` failure paths** — dry-run prints the command
  instead of running it; missing `loginctl` warns that services will stop
  at logout; a real failure (e.g. no polkit rule) warns with a `sudo
  loginctl enable-linger <user>` retry hint rather than aborting `svc_install`.
* **Tenant ID validation, two independent checks** — `_svc_validate_tenant_id`
  enforces the regex `^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$` (deliberately
  mirroring the Go-side `internal/isolation/cgroup.go` pattern exactly,
  after an independent review found the prior bash regex —
  `^[A-Za-z0-9_-]+$` — genuinely diverged: no dots, no first-char-alnum
  requirement, no length cap), *plus* a separate `[[ "${id}" != *..* ]]`
  rejection for path-traversal-shaped IDs (since `..` alone is charset-legal
  — dots are permitted in ordinary IDs like `tenant.3`).
* **Tenant slice drop-in is idempotent** — `_svc_ensure_tenant_slice_dropin`
  compares the desired drop-in content against the existing file and only
  writes + `daemon-reload`s when it actually differs; it is a no-op entirely
  when `LLMCTL_TENANT_ID` is unset. The drop-in file itself is written for
  real even under `LLMCTL_DRY_RUN=1` (plain filesystem I/O, matching
  `svc_install`'s own unit-file-write behavior) — only the subsequent
  `daemon-reload` is dry-run-gated.
* **Why per-instance `Slice=` drop-in, not a `systemd-run` wrapper** —
  documented investigation: wrapping the short-lived `bin/llmctl` CLI
  invocation in a `systemd-run --user --scope` would only isolate that
  CLI call (which exits in milliseconds), never the long-running
  `llama-server`/`colibri` process systemd spawns independently from the
  unit's own `Slice=` property — so the isolation mechanism has to be set on
  the unit itself, not on the invoking process.
* **`svc_disable`** tolerates `systemctl stop`/`disable` failures with
  `|| true` (a unit that was never started/enabled still gets cleaned up),
  and only removes the env file when not in dry-run.
* **`svc_known_profiles`** globs `*.env` under `LLMCTL_SERVICES_DIR` and
  skips (`[[ -e "${f}" ]] || continue`) the literal unexpanded glob when the
  directory is empty.

## Internal behaviour

1. **Setup**: resolves its own directory, sources `common.sh` and
   `hardware.sh`, defines `svc_backend_name` (`"systemd-user"`) and
   `svc_unit_dir` (`${LLMCTL_UNIT_DIR:-${XDG_CONFIG_HOME}/systemd/user}`).
2. **`_svc_sys`** — the single choke point for every `systemctl --user`
   invocation; dry-run prints instead of executing.
3. **Per-tenant isolation helpers** — `_svc_validate_tenant_id`,
   `_svc_instance_key` (returns the bare profile name when
   `LLMCTL_TENANT_ID` is unset, else `<tenant>--<profile>`), and
   `_svc_ensure_tenant_slice_dropin` (writes/reloads the `Slice=` drop-in
   idempotently, no-op when untenanted).
4. **`svc_install`** — ensures the unit dir + state dirs exist, probes total
   RAM via `hw_probe_json | json_stdin`, writes both template unit files
   (`llmctl-llama@.service`, `llmctl-colibri@.service`) with the
   `bash -c 'set -f; exec ...'` `ExecStart=` form, `Restart=always` +
   bounded restart limits, and the computed `MemoryHigh`/`MemoryMax`; then
   `daemon-reload`s and attempts `loginctl enable-linger`.
5. **`svc_write_env <profile> <engine> <exec> <args...>`** — resolves the
   tenant-qualified instance key, writes
   `LLMCTL_PROFILE`/`LLMCTL_ENGINE`/`LLMCTL_EXEC` (all `%q`-escaped),
   conditionally `LD_LIBRARY_PATH` for the `llama` engine (per the edge
   cases above), and `LLMCTL_ARGS` as a `%q`-escaped, space-joined argument
   list, into `${LLMCTL_SERVICES_DIR}/<instance>.env`.
6. **`_svc_unit_for <profile>`** — resolves the instance key, reads the
   engine back out of that profile's `.env` file (defaulting to `llama` if
   unreadable), and returns `llmctl-<engine>@<instance>.service`.
7. **Lifecycle wrappers** — `svc_enable` (ensures the tenant drop-in, then
   `enable` + `start`), `svc_disable` (`stop` + `disable`, tolerant of
   failure, removes the env file outside dry-run), `svc_start`/`svc_stop`/
   `svc_restart` (thin wrappers around `_svc_sys`), `svc_status` (prints or
   runs `systemctl --user --no-pager status`), `svc_logs` (dry-run prints a
   `tail` command; real mode dies if the log file doesn't exist yet,
   otherwise tails it), `svc_is_active` (dry-run checks the `.run`
   reservation file; real mode `systemctl --user is-active --quiet`),
   `svc_is_failed` (see Edge cases), `svc_known_profiles` (lists profiles
   with a `.env` file).

## Related scripts

* Sourced by `lib/scheduler.sh`'s `sched_load_backend` on Linux, and by
  `bin/llmctl` for direct `install`/`enable`/`disable`/`restart`/`logs`
  dispatch.
* Sources `lib/common.sh` (logging, `die`, `ensure_dir`, `ensure_state_dirs`,
  `have_cmd`, `json_stdin`) and `lib/hardware.sh` (`hw_probe_json`).
* Sibling backend: `lib/service_macos.sh` implements the identical `svc_*`
  interface for launchd; the two are mutually exclusive per-OS choices made
  by `sched_load_backend`.
* Exercised by `tests/test_services.sh` (unit/env generation), by
  `tests/test_services_crashloop.sh` (restart-bound assertions +
  `svc_is_failed` surfaced via `sched_status`), and by
  `tests/test_tenant_service_isolation.sh` (per-tenant env/unit-name
  isolation).

## Last verified date

2026-09-17
