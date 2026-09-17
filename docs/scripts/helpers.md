## Overview

`tests/helpers.sh` is the shared assertion + isolation library sourced by
every `tests/test_*.sh` file in llmctl's deterministic test harness. It is
not a test itself — it defines the small set of `assert_*` primitives
(equality, substring, file-content, file-existence/absence, exit-code) that
every test in the suite uses to report pass/fail, plus the
`test_setup_env`/`test_teardown_env`/`test_finish` lifecycle functions that
give each test file its own throwaway, XDG-isolated sandbox. It exists
because the harness's whole anti-bluff guarantee (`tests/run_tests.sh`'s
"every test is executed as a real subprocess" methodology) depends on every
test file reporting failures the same way and never touching real host
state (`~/.local/state`, `~/.config`) or leaking state between test files.

## Prerequisites

* Bash with `set -euo pipefail` (the file sets this itself); every function
  in this file is designed to be called from another script that has also
  sourced it — it is never executed directly as a standalone script.
* Computes `TESTS_DIR` (its own directory) and `LLMCTL_ROOT` (`tests/..`)
  from `${BASH_SOURCE[0]}` and exports `LLMCTL_ROOT` for callers.
* Requires `mktemp` on `PATH` (`test_setup_env` uses it to create the
  per-test sandbox directory).
* No fixture files are read by this file itself — fixtures belong to the
  individual test files that source it.
* Reads/sets no environment variables on entry; `test_setup_env` is the
  function that *exports* the isolation variables (see Internal behaviour).

## Usage examples

This file is never invoked on its own; every `tests/test_*.sh` file begins
with:

```bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
```

and ends with:

```bash
test_finish
```

A minimal test body in between looks like:

```bash
assert_eq "expected" "$(some_command)" "some_command returns expected"
assert_contains "$(cat some.log)" "needle" "log contains needle"
assert_file_exists "${LLMCTL_MODELS_DIR}/toy/model.bin" "model file exists"
```

## Edge cases

* **`test_teardown_env` must never abort under `set -e` when
  `test_setup_env` was never called.** The comment in the source explains
  the exact hazard: `[[ ... ]] && cmd` as a bare statement returns the
  condition's own exit status when false, which under `set -e` would abort
  the *calling* test script the moment a test skips `test_setup_env`
  (leaving `TEST_TMP` unset) and calls `test_finish` directly. The function
  wraps the check in `if` specifically so it always returns 0 regardless of
  whether `TEST_TMP` was ever set.
* **`assert_rc` runs a real command and captures its real exit code** (not a
  string comparison) — it discards the command's stdout/stderr
  (`>/dev/null 2>&1`) and defaults `rc=0` before running, so a command that
  succeeds is correctly recorded as `0` even though `||` only fires on
  failure.
* **`assert_contains`'s failure message truncates the haystack to 500
  characters** (`%.500s`) so a failed assertion against a large JSON blob or
  log file does not flood the test output.
* **`assert_file_contains` fails cleanly (not with a shell error) when the
  file does not exist** — the `[[ -f "$1" ]]` check short-circuits before
  `grep` ever runs on a missing path.
* **`assert_file_absent` treats any existing filesystem entry (`-e`, not
  just `-f`) as a failure** — a stray directory left at the expected path
  would still fail the assertion, not just a stray file.
* **Every isolation variable `test_setup_env` exports is a distinct XDG-style
  path under one `mktemp -d` sandbox** (`LLMCTL_STATE_DIR`,
  `LLMCTL_RUNTIME_DIR`, `LLMCTL_CONFIG_DIR`, `LLMCTL_DATA_DIR`,
  `LLMCTL_MODELS_DIR`, `LLMCTL_LOG_DIR`, `LLMCTL_VERIFY_DIR`,
  `LLMCTL_SERVICES_DIR`, `LLMCTL_UNIT_DIR`, `LLMCTL_PLIST_DIR`), so no test
  run ever reads or writes the real `~/.local/state/llmctl` or
  `~/.config/systemd/user` on the host running the suite. `NO_COLOR=1` is
  also exported so captured output is never polluted by ANSI color codes.

## Internal behaviour

1. Strict mode (`set -euo pipefail`) is enabled at the top of the file.
2. `TESTS_DIR` and `LLMCTL_ROOT` are computed once, at source time, from the
   real filesystem location of this file (works regardless of the caller's
   own cwd).
3. `TEST_FAILS=0` is a global counter, incremented by every `assert_*`
   function on failure; it is never reset mid-file, so a test file's total
   failure count accumulates across every assertion it makes.
4. Each `assert_*` function prints a one-line `ok:` or `FAIL:` line (to
   stdout for `ok`, to stderr for `FAIL`, so `run_tests.sh`'s merged
   `2>&1` capture still shows both in order) and, on failure, increments
   `TEST_FAILS`.
5. `test_setup_env` creates one `mktemp -d` directory and exports every
   `LLMCTL_*` path variable under it, then creates the state/runtime
   directories (`mkdir -p`) so downstream code that assumes they exist does
   not have to create them itself.
6. `test_teardown_env` removes the whole sandbox (`rm -rf "${TEST_TMP}"`)
   if — and only if — `TEST_TMP` was set and is a real directory.
7. `test_finish` calls `test_teardown_env`, then checks `TEST_FAILS`: a
   nonzero count prints `RESULT: FAIL (<N> assertion failure(s))` to stderr
   and `exit 1`s; otherwise it prints `RESULT: PASS` and `exit 0`s. This
   exit code is exactly what `tests/run_tests.sh` uses to classify the test
   file as PASS/FAIL in its summary table.

## Related scripts

* Sourced by every file matching `tests/test_*.sh` in this project (all 12
  files this task documents, plus the sibling test files another agent is
  documenting: `test_normalize_agents.sh`, `test_normalize_common.sh`,
  `test_planner.sh`, `test_port_override.sh`, `test_preflight_submodules.sh`,
  `test_run_tests_format.sh`, `test_scheduler_lock.sh`, `test_scheduler.sh`,
  `test_services_crashloop.sh`, `test_services.sh`, `test_setup_e2e.sh`,
  `test_syntax.sh`, `test_tenant_service_isolation.sh`).
* Discovered/driven by `tests/run_tests.sh`, which globs `test_*.sh` and
  runs each one as `bash <file>` from the project root — it never sources
  `helpers.sh` itself, only the individual test files do.
* Does not source any `lib/*.sh` module itself; individual test files source
  the `lib/*.sh` modules they need after sourcing this file.

## Last verified date

2026-09-17
