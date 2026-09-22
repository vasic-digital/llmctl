## Overview

`lib/scheduler.sh` is llmctl's multi-model co-residency and lifecycle
scheduler. It is the layer that turns "start these profiles" into a
budget-checked, OS-service-backed set of running inference servers: it reads
the live hardware plan (from `lib/hardware.sh` + `lib/catalog.sh`), compares
requested profiles' RAM/VRAM footprints against the remaining budget after
subtracting whatever is already reserved, builds the real launch arguments
for either engine (`llama.cpp` or `colibri`), delegates process lifecycle to
whichever OS service backend applies (`lib/service_linux.sh` or
`lib/service_macos.sh`), and persists a reservation record per running
profile so later `start`/`auto`/`status` calls know what is already
consuming memory. It exists because llmctl's whole value proposition is
running several models side-by-side without overcommitting host memory
(README "Co-residency and switching"; `docs/architecture.md` "Scheduler
state"), and this file is the only place that policy is enforced.

## Prerequisites

* Must be sourced from `bin/llmctl` (or a test harness) — it sources
  `common.sh`, `os_detect.sh`, `hardware.sh`, and `catalog.sh` from its own
  directory (`_sch_dir`) and calls functions those files define
  (`json_query`, `ensure_dir`, `die`, `log`, `info`, `warn`, `err`,
  `hw_probe_json`, `catalog_plan_json`, `catalog_exists`, `catalog_engine`,
  `catalog_files`, `catalog_capability`).
* `sched_load_backend` sources exactly one of `service_linux.sh` /
  `service_macos.sh` based on `llmctl_os` (from `os_detect.sh`); an
  unsupported OS calls `die "unsupported OS: $(uname -s)"`.
* Needs `flock` (via `scheduler::with_lock`) and `mktemp` on `PATH`.
* Reads/writes under `${LLMCTL_STATE_DIR}` / `${LLMCTL_RUNTIME_DIR}` /
  `${LLMCTL_SERVICES_DIR}` (all exported by `common.sh`); `ensure_state_dirs`
  is called before writing reservations so those directories exist.
* For the `llama` engine path, `sched_build_launch` expects the model file to
  already be present at `${LLMCTL_MODELS_DIR}/<profile>/<file>` — real files,
  not fixtures — unless `LLMCTL_DRY_RUN=1` is set, in which case the
  file-existence check is skipped entirely.
* Environment variables it reads directly: `LLMCTL_LLAMA_SERVER` (override
  for the llama.cpp binary path), `LLMCTL_COLI_BIN` (override for the
  colibri launcher), `LLMCTL_SEED` (opt-in deterministic decoding),
  `LLMCTL_SLOT_SAVE_PATH` (opt-in KV-cache slot-save directory),
  `LLMCTL_DRY_RUN` (checked directly and also relied on transitively via the
  sourced service backends). Reads `LLMCTL_BIND_HOST`/
  `LLMCTL_BIND_HOST_<PROFILE>` indirectly via `lib/catalog.sh`'s
  `catalog_bind_host()` (see catalog.md) — `sched_build_launch` calls that
  function, never the raw env vars, for both engine paths' `--host` flag.

## Usage examples

`lib/scheduler.sh` is not meant to be run standalone; it is sourced by
`bin/llmctl`, which exposes its public entry points as subcommands:

```bash
# Start one or more profiles only if the combined footprint fits.
llmctl start fast
llmctl start fast small coder      # co-resident; refuses as one atomic check

# Pick the best-ranked fitting profile per capability, evicting
# non-enabled (not `enable`d) services LRU-first if room is needed.
llmctl auto chat coder vision

# Stop specific profiles, or everything.
llmctl stop fast
llmctl stop all

# Always-works escape hatch: stop everything, start exactly one profile.
llmctl switch coder

# Enable persistent autostart for a profile (budget-checked the same way
# as `start`), and show current reservations/state.
llmctl enable small
llmctl status
```

Directly sourcing the file (as the test suite does) to call its internal
functions:

```bash
source lib/common.sh
source lib/scheduler.sh
sched_load_backend            # picks service_linux.sh or service_macos.sh
sched_start fast small        # public, locking entry point
sched_rank_for_capability coder
# -> "colibri-glm coder ws-moe-30b ws-dense-32b colibri-qwen36"
```

Environment variables that change scheduler behavior:

```bash
LLMCTL_DRY_RUN=1 llmctl start fast     # prints service actions, no real exec
LLMCTL_SEED=42 llmctl start fast       # deterministic decoding (--seed --temp 0)
LLMCTL_SLOT_SAVE_PATH=/var/llmctl/slots llmctl start coder
LLMCTL_FAKE_HW=tests/fixtures/hw-baseline.json llmctl plan --json

LLMCTL_BIND_HOST=127.0.0.1 llmctl start fast          # lock every profile to localhost-only
LLMCTL_BIND_HOST_FAST=127.0.0.1 llmctl start fast     # lock just "fast"; the default (0.0.0.0,
                                                       # LAN-accessible) still applies elsewhere
```

## Edge cases

* **Combined footprint refusal with a suggested alternative** —
  `_sched_start_impl` checks every requested profile's `fits` flag from the
  plan AND the running (`used_ram`/`used_vram`) + requested totals against
  `ram_budget`/`vram_budget`; on refusal it scans `d["recommended"]` for the
  first alternative that would fit right now and prints it, plus a
  CONTEXT-AWARE fallback line (fixed 2026-09-22, real live incident): if
  another llmctl profile is genuinely running (`sched_running` non-empty),
  it suggests `llmctl switch <profile>` (stopping that other profile would
  free room); if NOTHING is running, suggesting `switch` would be circular
  (there is nothing left to stop - this exact message fired from INSIDE
  `llmctl switch` itself on a live host, telling the operator to re-run
  the command that had just failed), so it instead names the real
  constraint honestly: the host's own available RAM/VRAM is too low right
  now. Either way, returns 1 without starting anything (see the exact
  refusal-message assertions in `tests/test_scheduler.sh` and
  `tests/test_scheduler_switch_safety.sh`).
* **Already-running profile is a no-op, not an error** — inside the
  selection loop, `sched_is_running "${p}"` short-circuits with
  `log "${p} is already running"` and `continue`, so re-requesting a running
  profile in a `start` batch never double-reserves it.
* **Unknown profile** — `catalog_exists "${p}"` failing removes the temp
  plan file and calls `die "unknown profile: ${p} (see: llmctl models list)"`.
* **Service backend refuses to actually start** — because this whole
  function runs as the `"$@"` operand inside `scheduler::with_lock`'s
  `"$@" || rc=$?`, bash disables `set -e` propagation through that call, so a
  failing `svc_start` used to be silently swallowed (the reservation was
  still written and "started" printed even though nothing was running). The
  code now explicitly checks `if ! svc_start "${p}"; then ...; fi` and
  returns 1 with an actionable message (check `llmctl logs`, verify
  `llmctl install` ran) instead of ever writing a reservation for a service
  that isn't actually up.
* **`enable` is budget-checked exactly like `start`, closing a real TOCTOU**
  — `_enable_impl` previously computed and wrote a reservation for a new
  profile with no reference to what was already reserved; it is now
  dispatched through `sched_enable` under the same `scheduler::with_lock`
  `start` uses, and — only when the profile is not already running — checks
  `used_ram + ram > ram_budget` / `used_vram + vram > vram_budget` and
  refuses (with exact numbers) before writing any env file, touching the
  systemd unit, or reserving anything.
* **`llama` engine, missing model file** — `sched_build_launch` calls
  `die "profile ${profile} has no model file in catalog"` if `catalog_files`
  yields no non-mmproj entry, and (outside dry-run) `die "model not
  downloaded: ${model}. Run: llmctl models download ${profile}"` if the file
  is absent on disk.
* **`colibri` engine, missing model directory** — same dry-run-aware check,
  but on the profile's model directory rather than a single file; the
  `SCHED_EXEC` for `colibri` resolves to the in-submodule `coli` launcher
  path by default (`${LLMCTL_ROOT}/submodules/colibri/c/coli`) rather than
  requiring a separate pip-installed `coli` on `PATH`, since the launcher is
  already executable in-tree.
* **`--slot-save-path` directory creation is unconditional even under
  dry-run** — unlike the model-existence check (which is skipped under
  `LLMCTL_DRY_RUN=1` to avoid touching real multi-gigabyte files), the
  per-profile subdirectory under `LLMCTL_SLOT_SAVE_PATH` is created for real
  even in dry-run mode, so a dry run genuinely validates the real target path
  rather than only pretending to.
* **`auto`'s eviction loop is bounded and protects enabled services** — the
  loop in `_sched_auto_impl` runs at most 16 attempts; each iteration
  recomputes whether the wanted set fits against current reservations, and
  if not, evicts the running, non-enabled (`sched_is_enabled` false),
  not-in-the-wanted-set service with the oldest `started_epoch` (true LRU).
  If no evictable candidate exists (everything left is enabled/protected or
  already wanted), it fails with `"remaining services are enabled
  (protected)"` and suggests `llmctl switch <first-wanted-profile>` instead
  of looping forever.
* **Concurrency: `scheduler::with_lock`** — every public mutating entry
  point (`sched_start`, `sched_stop`, `sched_auto`, `sched_enable`) acquires
  an exclusive `flock` on `${LLMCTL_RUNTIME_DIR}/.scheduler.lock` before
  running its `_impl`, and releases it after, even on failure (`rc=$?`
  captured, lock released, then `return "${rc}"`). `sched_auto`'s `_impl`
  calls `_sched_start_impl` directly (never the public, re-locking
  `sched_start`) specifically so the evict-then-start sequence is one atomic
  locked unit and nested `flock` acquisition (which would deadlock against
  itself) never happens. `tests/test_scheduler_lock.sh` proves 200 concurrent
  increments through the lock lose zero updates, and that a second acquirer
  genuinely waits rather than racing.
* **Crash-loop surfaced in `status`, not hidden** — `sched_status` calls
  `svc_is_failed "${p}"` per running reservation and prints
  `"failed (crash-loop)"` plus the service's last log line
  (`tail -n 1 ${LLMCTL_LOG_DIR}/${p}.log`, or `"(no log)"` if absent) instead
  of just listing it as an ordinary running row.
* **Engine bind host defaults to LAN-accessible, not localhost-only** —
  both `sched_build_launch` engine branches resolve their `--host` flag via
  `catalog_bind_host "${profile}"`, which defaults to `0.0.0.0`
  (`LLMCTL_BIND_HOST` in `common.sh`) per explicit operator mandate,
  rather than the historically-hardcoded `127.0.0.1`. This is a real
  security trade-off (no built-in API auth) disclosed in README.md's
  "Safety guarantees" — an operator who needs localhost-only sets
  `LLMCTL_BIND_HOST=127.0.0.1` (every profile) or
  `LLMCTL_BIND_HOST_<PROFILE>=127.0.0.1` (just one) before `start`/
  `enable`/`switch`. `lib/download.sh`'s one-shot smoke-test launch is
  unaffected either way and stays hardcoded to `127.0.0.1` (it is
  ephemeral and never needs to be LAN-reachable).
* **The colibri engine has its OWN, independent fail-closed bind guard,
  which `sched_build_launch` deliberately does NOT try to work around** —
  confirmed live (2026-09-22): `submodules/colibri/c/openai_server.py`'s
  `serve()` refuses any non-loopback `--host` with no API key unless
  `COLI_ALLOW_INSECURE_BIND=1` is set in its environment, printing
  "refusing to bind ... without COLI_API_KEY set" and exiting 1 (a
  crash-loop under `enable`/`install`). `sched_build_launch` still resolves
  `--host` via `catalog_bind_host` for colibri exactly as it does for
  llama — it just never sets `COLI_ALLOW_INSECURE_BIND` itself, since doing
  so would silently override a component's own explicit security control
  rather than this project's own default; see README.md "Safety
  guarantees" for the operator-facing remediation (set the env var on that
  unit, or lock that one profile to loopback via
  `LLMCTL_BIND_HOST_<PROFILE>`).
* **`sched_reserved_field`/reservation files tolerate missing values** —
  `${v:-0}` defaults a missing/blank field to `0` when summing `ram_mb` or
  `vram_mb` across `*.run` files, and the glob loop itself checks
  `[[ -e "${f}" ]] || continue` so an empty `LLMCTL_RUNTIME_DIR` (literal
  unexpanded glob) never breaks the sum.

## Internal behaviour

1. **Setup** (top of file): resolves its own directory, sources
   `common.sh`/`os_detect.sh`/`hardware.sh`/`catalog.sh`, and defines
   `sched_load_backend` (OS-dispatch to the right service backend) and
   `sched_rank_for_capability` (fixed, documented quality rankings per
   capability: `chat`, `coder`, `vision`).
2. **Concurrency primitive** — `scheduler::with_lock <command> [args...]`
   opens the lock file on a dynamic fd (`exec {lock_fd}>...`), takes an
   exclusive `flock`, runs the command capturing its exit code without
   letting `set -e` abort the wrapper, releases the lock, and propagates the
   real exit code.
3. **Reservation-record helpers** — `_sched_run_file`, `sched_running`
   (lists profile names with a `.run` file), `sched_is_running`,
   `sched_is_enabled`, `sched_reserved_field` (sums a field across all
   `.run` files), and `_sched_write_reservation` (writes
   `profile/mode/port/ram_mb/vram_mb/started_epoch` as a flat key=value
   file).
4. **`sched_build_launch`** — given a profile/mode/port/ctx/ngl/parallel/fa,
   looks up the engine via `catalog_engine`, and populates the global
   `SCHED_EXEC` + `SCHED_ARGS` array with the real command line for either
   `llama` (resolves model + optional mmproj file via `catalog_files`,
   resolves `--host` via `catalog_bind_host "${profile}"`, adds
   `--seed`/`--temp` when `LLMCTL_SEED` is set, adds `--slot-save-path` when
   `LLMCTL_SLOT_SAVE_PATH` is set) or `colibri` (resolves the model
   directory, resolves `--host` the identical way, builds a `coli serve`
   command line). Dies on an unknown engine.
5. **Public locking wrappers** — `sched_start`, `sched_stop`, `sched_auto`,
   `sched_enable` each call `scheduler::with_lock` around their respective
   `_impl` function.
6. **`_sched_start_impl`** — loads the backend, computes a fresh hardware
   plan into a temp JSON file, sums current reservations, validates every
   requested profile against the remaining budget (collecting a `selected`
   array), then in a second pass actually builds launch args, writes the
   env file (`svc_write_env`), starts the service (`svc_start`, with the
   explicit exit-code check described above), and writes the reservation
   record on success — printing an `info` line per started profile.
7. **`_enable_impl`** — resolves plan values for the profile, budget-checks
   only if not already running, then (unconditionally after that check)
   builds launch args, writes the env file, touches the
   `<profile>.enabled` marker, calls `svc_enable`, and writes the
   reservation record (enable implies start).
8. **`_sched_stop_impl`** — resolves either the literal targets given or
   (for `all`/no args) everything currently running via `sched_running`,
   calls `svc_stop` per target (tolerating failure with `|| true`), removes
   the `.run` file, and logs.
9. **`sched_switch`** (`_sched_switch_impl`, fixed 2026-09-22) — a SINGLE
   locked, atomic operation (not two separate `sched_stop`/`sched_start`
   calls as before): snapshots the currently-running set, no-ops if the
   target is already the sole running profile, otherwise stops everything
   and starts the target - and if that start fails for ANY reason
   (budget gate, systemd refusing the unit), automatically restores the
   snapshotted set (best-effort) before propagating the original failure.
   A failed switch is therefore never worse than a no-op: the host is
   left with what was running before, never with nothing running. See
   `tests/test_scheduler_switch_safety.sh` for the full RED/GREEN
   coverage and the real, live-reproduced incident that motivated this
   (a `switch` to an oversized profile stranded a healthy, serving host
   with zero running services until a manual `llmctl start` restored it).
10. **`_sched_auto_impl`** — resolves the best-ranked, catalog-recommended
    profile per requested capability into a `want` array, then runs the
    bounded (16-iteration) fit-or-evict loop described in Edge cases, and
    finally delegates to `_sched_start_impl` for the actual start (still
    under the same lock as the eviction loop).
11. **`sched_status`** — lists every `.run` file's fields in a formatted
    table, marking enabled services and crash-looped ones with their last
    log line.

## Related scripts

* `bin/llmctl` sources this file directly and dispatches most of its
  subcommands (`start`, `stop`, `switch`, `auto`, `status`, `enable`,
  `install`, `restart`, `logs`) straight into its public functions.
* Sources `lib/common.sh` (logging, `die`, XDG paths, `json_query`),
  `lib/os_detect.sh` (`llmctl_os`), `lib/hardware.sh` (`hw_probe_json`), and
  `lib/catalog.sh` (`catalog_plan_json`, `catalog_exists`, `catalog_engine`,
  `catalog_files`, `catalog_capability`).
* Sources exactly one of `lib/service_linux.sh` or `lib/service_macos.sh` at
  runtime via `sched_load_backend`, and calls their `svc_*` functions
  (`svc_write_env`, `svc_start`, `svc_stop`, `svc_enable`, `svc_is_failed`,
  `svc_install`, `svc_restart`, `svc_logs`, `svc_disable`).
* Exercised by `tests/test_scheduler.sh` (co-residency, refusal + suggested
  alternative, LRU eviction, enabled-service protection, `switch`),
  `tests/test_scheduler_lock.sh` (concurrency/locking correctness),
  `tests/test_scheduler_bind_host.sh` (`LLMCTL_BIND_HOST`/
  `LLMCTL_BIND_HOST_<PROFILE>`, both engine paths),
  `tests/test_scheduler_reboot_reconciliation.sh` (post-reboot `*.run`
  self-heal), `tests/test_services.sh`, `tests/test_services_crashloop.sh`,
  and `tests/test_tenant_service_isolation.sh` (which exercise the service
  backends this file loads and depends on).

## Last verified date

2026-09-22
