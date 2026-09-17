## Overview

`tests/test_scheduler.sh` is the end-to-end, dry-run functional test for
the scheduler's CLI-facing behaviors: co-residency start, budget-aware
refusal with a suggested alternative, LRU eviction inside `auto`,
enabled-service eviction protection, `switch`'s always-works semantics,
and two opt-in launch-flag features (`LLMCTL_SEED` and
`LLMCTL_SLOT_SAVE_PATH`). It exists to prove the scheduler's decision
logic — described in `docs/architecture.md`'s "Scheduler state" section
and state diagram — behaves correctly against real `bin/llmctl`
subcommand invocations, with all actual service/process management
short-circuited to `LLMCTL_DRY_RUN=1` printed actions and reservation
state living entirely in an isolated temp directory.

## Prerequisites

* Sources `tests/helpers.sh` for assertion helpers and
  `test_setup_env`/`test_finish`.
* Sets `LLMCTL_DRY_RUN=1` for the whole file so no real `systemctl`/
  process-management calls occur — every `svc_*` action is printed
  (`[dry-run] ...`) instead of executed.
* Sets `LLMCTL_FAKE_HW` to different fixture files at different points in
  the file (`hw-baseline.json`, then `hw-constrained.json`, then
  `hw-workstation.json`) to exercise different budget scenarios, calling
  `test_teardown_env; test_setup_env` between fixture switches to start
  each scenario from fresh reservation state.
* Invokes the real `bin/llmctl` CLI entrypoint as a subprocess
  (`LLMCTL="${LLMCTL_ROOT}/bin/llmctl"`) for most assertions; sources
  `lib/scheduler.sh` directly (in-process) for the final two sections
  (`sched_build_launch` flag assertions).
* Reads/writes reservation files under `${LLMCTL_RUNTIME_DIR}/*.run` and
  the "enabled" marker file `${LLMCTL_SERVICES_DIR}/<profile>.enabled` —
  both isolated per-test via `test_setup_env`.
* Uses the opt-in environment variables `LLMCTL_SEED` and
  `LLMCTL_SLOT_SAVE_PATH` (both unset by default; set and later `unset`
  within their respective sections) to exercise `sched_build_launch`'s
  conditional flag injection.
* Uses `mktemp -d` directly (not `test_setup_env`'s `TEST_TMP`) to create
  a scratch directory for the `LLMCTL_SLOT_SAVE_PATH` section, removed
  with `rm -rf` at the end of that section.

## Usage examples

```bash
bash tests/test_scheduler.sh
```

Also runs as part of the full suite via `tests/run_tests.sh` or
`make test`.

## Edge cases

* **Co-resident start fits**: `llmctl start fast small` on the baseline
  fixture exits `0`, reports both profiles started, and writes both
  `fast.run`/`small.run` reservation files; `llmctl status` subsequently
  lists both.
* **Refusal with suggested alternative**: after `fast`+`small` reserve
  9689/10444 MiB VRAM, `llmctl start vision` (needing 4210 MiB more) is
  refused with exit `1`, the message `"cannot start 'vision'"`, a
  `"suggested alternative"`, and a `"llmctl switch vision"` fallback
  suggestion; asserts nothing changed — `fast`/`small` reservations
  remain, `vision.run` was never created.
* **`auto` evicts the LRU non-enabled service**: `llmctl auto vision`
  (after a `sleep 1` to guarantee distinct LRU epochs) succeeds, reports
  `"evicting 'fast'"`, removes `fast.run`, keeps `small.run`, and creates
  `vision.run`.
* **Enabled services are never evicted**: switching to the
  `hw-constrained.json` fixture with fresh state, starts `fast`, marks it
  enabled by touching `${LLMCTL_SERVICES_DIR}/fast.enabled`, then asserts
  `llmctl auto vision` fails (exit `1`) with an `"enabled (protected)"`
  message, and that `fast.run` is untouched while `vision.run` was never
  created — even though evicting `fast` is the *only* way `vision` could
  fit in this fixture's 6963 MiB VRAM budget.
* **`switch` always works**: `llmctl switch moe-fast` succeeds and
  results in *exactly* one `.run` reservation file present
  (`moe-fast`), regardless of what was running before.
* **Dry-run never calls real `systemctl`**: `llmctl stop all` output
  contains the literal dry-run marker
  `"[dry-run] systemctl --user stop"`.
* **`auto <capability> <capability>` co-residency (US1 Acceptance
  Scenario 3)**: on the `hw-workstation.json` fixture (which, per the
  script's own comment, actually classifies as `datacenter` tier under
  the real threshold rules — cores≥32 AND ram≥96GiB AND free≥400GiB all
  hold — not `workstation`, a pre-existing filename mismatch left
  as-is), `llmctl auto coder vision` exits `0`, reports capability→profile
  resolution for both `coder` and `vision`, reports at least one service
  started, asserts **zero** evictions occurred (both profiles fit the
  abundant datacenter-tier budget directly — 235904 MiB RAM / 27852 MiB
  VRAM available), and asserts exactly two `.run` files exist afterward.
* **`LLMCTL_SEED` opt-in determinism (FR-012/SC-008)**: with
  `LLMCTL_SEED` unset, `sched_build_launch`'s resulting `SCHED_ARGS` array
  contains no `--seed` flag (default interactive behavior is unchanged);
  with `LLMCTL_SEED=42` exported, the same call's args contain both
  `--seed 42` and `--temp 0` (the fixed-seed + temperature-0 pair FR-012
  requires for deterministic live challenges). The script's own comment
  explains this is deliberately opt-in rather than baked into every
  default launch, since an always-on fixed seed would make every
  interactive coding-assistant session identically non-creative — FR-012
  scopes determinism to the manual release-gating "live challenges"
  procedure (US4), not everyday interactive use.
* **`LLMCTL_SLOT_SAVE_PATH` opt-in wiring (003-kv-cache-replication
  T015, FR-006/User Story 2)**: with the variable unset,
  `sched_build_launch`'s args contain no `--slot-save-path` flag; with it
  set to a fresh `mktemp -d`, the resulting args contain
  `--slot-save-path <base>/fast` (a per-profile subdirectory), and the
  directory is asserted to have actually been created *before* the engine
  launch. The script cites `scheduler.sh`'s own Constitution §11.4.133
  host-safety rationale for why this must be opt-in: unbounded
  engine-cache disk growth must be an explicit deployment choice, never a
  forced-on default.

## Internal behaviour

1. `set -euo pipefail`; source `tests/helpers.sh`; `test_setup_env`;
   export `LLMCTL_DRY_RUN=1` and `LLMCTL_FAKE_HW=hw-baseline.json`.
2. Section 1: `llmctl start fast small`; assert exit code, both-started
   message, both reservation files, and `llmctl status` output.
3. Section 2: `sleep 1`; `llmctl start vision`; assert refusal exit code,
   message, alternative suggestion, and that nothing changed.
4. Section 3: `llmctl auto vision`; assert eviction message and resulting
   reservation-file state.
5. Section 4: switch `LLMCTL_FAKE_HW` to the constrained fixture; reset
   env via `test_teardown_env; test_setup_env`; `llmctl start fast`;
   `touch` its `.enabled` marker; `llmctl auto vision`; assert refusal,
   protection message, and unchanged reservation state.
6. Section 5: `llmctl switch moe-fast`; enumerate `*.run` files in
   `LLMCTL_RUNTIME_DIR` and assert exactly one, named `moe-fast`, remains.
7. Section 6: `llmctl stop all`; assert the dry-run `systemctl ... stop`
   marker appears.
8. Section 7: switch `LLMCTL_FAKE_HW` to the workstation fixture; reset
   env; `llmctl auto coder vision`; assert exit code, capability
   resolution messages, at least one start, zero eviction messages (via
   `grep -c "evicting"`), and exactly two resulting `.run` files.
9. Section 8: source `lib/scheduler.sh` directly; re-export
   `LLMCTL_DRY_RUN=1` (so `sched_build_launch`'s model-file-existence
   check does not require a real downloaded model on disk); call
   `sched_build_launch fast cpu 8080 8192 99 1 auto` with `LLMCTL_SEED`
   unset and assert no `--seed` entry in `SCHED_ARGS`; export
   `LLMCTL_SEED=42`, call it again, assert `--seed 42` and `--temp 0` are
   both present; `unset LLMCTL_SEED`.
10. Section 9: call `sched_build_launch` again with `LLMCTL_SLOT_SAVE_PATH`
    unset and assert no `--slot-save-path` entry; create a fresh
    `mktemp -d`, export it as `LLMCTL_SLOT_SAVE_PATH`, call
    `sched_build_launch` again, assert the per-profile
    `--slot-save-path <base>/fast` argument is present and that the
    directory was actually created; `unset` the variable and `rm -rf`
    the scratch directory.
11. `test_finish` tears down the temp environment and exits non-zero iff
    any assertion failed.

## Related scripts

* Sources `tests/helpers.sh` (sibling, documented separately).
* Invokes `bin/llmctl` as a real subprocess (`start`, `status`, `auto`,
  `switch`, `stop` subcommands) and separately sources `lib/scheduler.sh`
  directly for `sched_build_launch`.
* Transitively exercises `lib/catalog.sh` (planner) and `lib/hardware.sh`
  (`hw_probe_json`, faked via `LLMCTL_FAKE_HW`) that the scheduler
  commands depend on.
* Reads `tests/fixtures/hw-baseline.json`, `hw-constrained.json`,
  `hw-workstation.json`.
* Sibling test `tests/test_scheduler_lock.sh` proves the underlying
  `scheduler::with_lock` mutual-exclusion primitive this script's `sched_*`
  commands are all built on.
* Sibling tests `tests/test_services.sh` and
  `tests/test_services_crashloop.sh` cover the service-backend layer
  (`lib/service_linux.sh`/`lib/service_macos.sh`) that a non-dry-run
  scheduler action would ultimately invoke.
* Discovered and run automatically by `tests/run_tests.sh`; syntax and
  shebang/strict-mode covered by `tests/test_syntax.sh`.

## Last verified date

2026-09-17
