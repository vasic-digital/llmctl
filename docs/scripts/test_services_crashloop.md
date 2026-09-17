## Overview

`tests/test_services_crashloop.sh` proves that this project's generated
service units genuinely bound automatic restarts (so a permanently-broken
model does not crash-loop forever), and that `llmctl status`
(`sched_status`) surfaces a crash-looped profile as
`"failed (crash-loop)"` together with its last captured log line
(FR-044, Clarification 14). It covers both the Linux systemd `--user`
backend and the macOS launchd backend's honest, documented partial-parity
restart-throttling, plus the scheduler-level status-reporting logic that
distinguishes a merely-running profile from one that has exhausted its
restart budget.

## Prerequisites

* Sources `tests/helpers.sh` for assertion helpers and
  `test_setup_env`/`test_finish`.
* Sets `LLMCTL_DRY_RUN=1` and
  `LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"` for
  the whole file.
* Sources, in isolated subshells, `lib/common.sh`, `lib/os_detect.sh`,
  `lib/hardware.sh`, and either `lib/service_linux.sh` (unit generation)
  or `lib/service_macos.sh` (plist generation), plus `lib/catalog.sh` and
  `lib/scheduler.sh` for the status-reporting section.
* Relies on `test_setup_env`'s isolated `LLMCTL_UNIT_DIR` (systemd unit
  destination), `LLMCTL_PLIST_DIR` (launchd plist destination),
  `LLMCTL_RUNTIME_DIR` (reservation `.run` files, plus a dry-run
  `.failed` marker file this test writes to simulate a crash-looped
  unit), and `LLMCTL_LOG_DIR` (service log files) — all under a fresh
  temp directory, never real system paths.
* The dry-run `<profile>.failed` marker file is this test's own
  simulation mechanism for the real systemd signal
  (`systemctl --user is-failed`), following, per the script's inline
  comment, the same pattern `svc_is_active` already uses for its own
  dry-run branch.

## Usage examples

```bash
bash tests/test_services_crashloop.sh
```

Also runs as part of the full suite via `tests/run_tests.sh` or
`make test`.

## Edge cases

* **systemd `--user` unit bounds restarts**: after calling `svc_install`
  (in a subshell with the relevant libs sourced), asserts both the llama
  unit (`llmctl-llama@.service`) and the colibri unit
  (`llmctl-colibri@.service`) contain `StartLimitBurst=5` and
  `StartLimitIntervalSec=60` — the bounded-restart configuration that
  stops the unit (rather than looping forever) once 5 restart attempts
  occur within a 60-second window.
* **launchd plist widens its restart throttle (honest partial parity)**:
  after calling `svc_write_env` for a `fast`/`llama` profile via
  `lib/service_macos.sh`, asserts the generated plist
  (`com.llmctl.fast.plist`) contains `<integer>60</integer>` — the
  widened `ThrottleInterval`. The assertion message itself documents the
  honesty boundary: launchd has no native give-up-after-N-restarts
  primitive the way systemd's `StartLimitBurst` does, so this bounds the
  *rate* of restarts, not the total attempt count.
* **`llmctl status` surfaces a crash-looped profile**: in one subshell
  (sourcing `common.sh`, `os_detect.sh`, `hardware.sh`, `catalog.sh`,
  `scheduler.sh`, then `ensure_state_dirs`), writes two synthetic `.run`
  reservation files — one healthy (`fast.run`) and one representing a
  service that exceeded its restart limit and gave up (`broken.run`,
  paired with a `broken.failed` dry-run marker file and a captured log
  containing `"starting..."` then `"error: model file is corrupt"`) —
  then calls `sched_status` and captures its output. Asserts the output
  lists `fast` as `"running"`, lists `broken` as
  `"failed (crash-loop)"`, and that the crash-looped profile's *last*
  captured log line (`"error: model file is corrupt"`) is surfaced in
  the status output — not merely that the profile is flagged broken, but
  that its most recent diagnostic line is actually shown.

## Internal behaviour

1. `set -euo pipefail`; source `tests/helpers.sh`; `test_setup_env`;
   export `LLMCTL_DRY_RUN=1` and the baseline `LLMCTL_FAKE_HW` fixture.
2. Section 1: in a subshell, source `common.sh`, `os_detect.sh`,
   `hardware.sh`, `service_linux.sh`, call `svc_install`; assert both
   generated unit files contain the expected `StartLimitBurst=5` /
   `StartLimitIntervalSec=60` directives.
3. Section 2: in a subshell, source `common.sh`, `service_macos.sh`, call
   `svc_write_env fast llama <exec> --model ... --host 127.0.0.1 --port
   8080`; assert the generated plist contains the widened
   `<integer>60</integer>` throttle value.
4. Section 3: in a subshell that captures its own stdout, source
   `common.sh`, `os_detect.sh`, `hardware.sh`, `catalog.sh`,
   `scheduler.sh`; call `ensure_state_dirs`; write a healthy `fast.run`
   reservation file; write a `broken.run` reservation file plus its
   companion `broken.failed` marker; ensure the log directory exists and
   write a two-line log for `broken`; call `sched_status` (its stdout is
   captured as `status_out` by the outer subshell substitution).
5. Assert `status_out` contains `"fast"`, `"running"`,
   `"failed (crash-loop)"`, and the specific corrupt-model log line.
6. `test_finish` tears down the temp environment and exits non-zero iff
   any assertion failed.

## Related scripts

* Sources `tests/helpers.sh` (sibling, documented separately).
* Exercises `lib/service_linux.sh` (`svc_install`) and
  `lib/service_macos.sh` (`svc_write_env`) for unit/plist generation, and
  `lib/scheduler.sh` (`sched_status`, `ensure_state_dirs`) for the
  status-reporting logic, on top of `lib/common.sh`, `lib/os_detect.sh`,
  `lib/hardware.sh`, `lib/catalog.sh`.
* Reads `tests/fixtures/hw-baseline.json`.
* Sibling test `tests/test_services.sh` covers the broader (non-crash-loop)
  service unit/plist generation surface for both backends.
* Cited directly by `docs/architecture.md`'s "Service backends" section
  (`StartLimitBurst=5`/`StartLimitIntervalSec=60`, launchd's honest
  `ThrottleInterval` gap) and its scheduler state diagram (the
  `Running --> CrashLoop --> Failed` transition).
* Discovered and run automatically by `tests/run_tests.sh`; syntax and
  shebang/strict-mode covered by `tests/test_syntax.sh`.

## Last verified date

2026-09-17
