## Overview

`tests/run_tests.sh` is the deterministic test-harness runner for llmctl — it
is the single entry point `make test` invokes (see `Makefile` target `test:
bash tests/run_tests.sh`). It does not contain assertions itself; instead it
discovers every `tests/test_*.sh` file, executes each one as a real
subprocess from the project root, captures its raw stdout/stderr and exit
code, prints a full transcript for each test, and finally prints a
pass/fail summary table. It exists so that a single command runs the whole
suite with zero flakiness and with anti-bluff-grade visibility: nothing is
summarized without the underlying command, its literal output, and its
literal exit code being shown first.

## Prerequisites

* `bash` (uses `set -euo pipefail`, `shopt -s nullglob`, arrays).
* The suite of `tests/test_*.sh` files themselves — each is a fully
  independent script; `run_tests.sh` does not source any of them, it only
  invokes `bash <file>` as a subprocess.
* No environment variables are required by `run_tests.sh` itself; whatever
  environment variables individual test files need (e.g. `LLMCTL_FAKE_HW`,
  `LLMCTL_DRY_RUN`) are set inside those test files, not here.
* Computes `TESTS_DIR` (its own directory) and `ROOT` (the parent, i.e. the
  project root) via `$(dirname "${BASH_SOURCE[0]}")`, and always runs each
  test with `ROOT` as the working directory (`cd "${ROOT}" && bash "${t}"`).

## Usage examples

* Canonical invocation (matches `make test`):
  ```bash
  bash tests/run_tests.sh
  ```
* Direct equivalent of the Makefile target:
  ```bash
  make test
  ```
* It takes no arguments and reads no CLI flags; it simply globs
  `tests/test_*.sh` in its own directory.

## Edge cases

* **Empty test directory**: `shopt -s nullglob` is set before the `for`
  loop, so if no `test_*.sh` files exist the loop body never executes (the
  glob expands to nothing instead of the literal unmatched pattern) — the
  script still reaches the summary section and reports `PASS: 0  FAIL: 0`
  rather than erroring.
* **A test file crashes with a non-zero exit code**: `out="$(... bash "${t}"
  2>&1)" && rc=0 || rc=$?` captures the real exit code (`rc`) without
  letting a non-zero exit trip the harness's own `set -e` (the `||` clause
  neutralizes it for that one command only). The test is recorded as
  `FAIL  <name> (exit <rc>)` and the harness continues to the next test
  file rather than aborting the whole suite.
* **A test file passes (exit 0)**: recorded as `PASS  <name>` regardless of
  what it printed to stdout/stderr (still shown in full under `OUTPUT:`).
* **`results` array with zero elements at summary time**: the `for r in
  ${results[@]+"${results[@]}"}` idiom guards against an "unbound variable"
  error under `set -u` when the array is empty (i.e. the "no test files
  found" case above) — without the `${results[@]+...}` guard, expanding an
  empty array under `set -u` would itself be a fatal error.
* **Any single test failing anywhere in the suite**: the harness's own
  final exit code is 1 (`if [[ "${fail}" -gt 0 ]]; then exit 1; fi`), which
  is what makes `make test` fail the build.

## Internal behaviour

1. Resolves `TESTS_DIR` (own directory) and `ROOT` (`..` from there,
   i.e. the llmctl project root) as absolute paths.
2. Initializes `pass=0`, `fail=0`, and an empty `results` array.
3. Enables `nullglob` so an empty match set doesn't leave a literal
   `test_*.sh` glob pattern in the loop.
4. For every file matching `"${TESTS_DIR}"/test_*.sh` (sorted by shell glob
   order, i.e. alphabetical):
   * Derives `name` (basename) and the `cmd` string it prints for display
     purposes (`bash <path>`).
   * Prints a banner block: a separator line, `TEST: <name>` / `CMD: <cmd>`,
     and another separator.
   * Runs the test for real: `out="$(cd "${ROOT}" && bash "${t}" 2>&1)"`,
     capturing combined stdout+stderr, then captures the real `rc` via the
     `&& rc=0 || rc=$?` idiom (never letting `set -e` short-circuit the
     loop).
   * Prints the full captured `OUTPUT:` block and the numeric `EXIT: <rc>`.
   * Appends either `PASS  <name>` or `FAIL  <name> (exit <rc>)` to
     `results`, and increments `pass` or `fail` accordingly.
5. After the loop, prints a `SUMMARY` banner, then every line collected in
   `results` (in the order tests ran), then `PASS: <n>  FAIL: <n>`.
6. Exits `1` if `fail > 0`, otherwise falls through and exits `0`
   (`set -e` default success).

## Related scripts

* Discovers and executes every sibling `tests/test_*.sh` file in this
  directory — this includes all 11 scripts this document set covers
  (`test_archive_completeness.sh`, `test_catalog_json.sh`, `test_cli.sh`,
  `test_constitution_inheritance.sh`, `test_create_release.sh`,
  `test_determinism.sh`, `test_download.sh`, `test_download_resume.sh`,
  `test_engine.sh`, `test_hardware_probe.sh`) plus every other
  `test_*.sh` file documented by the sibling companion pass
  (`test_normalize_agents.sh`, `test_normalize_common.sh`,
  `test_planner.sh`, `test_port_override.sh`,
  `test_preflight_submodules.sh`, `test_run_tests_format.sh`,
  `test_scheduler_lock.sh`, `test_scheduler.sh`,
  `test_services_crashloop.sh`, `test_services.sh`, `test_setup_e2e.sh`,
  `test_syntax.sh`, `test_tenant_service_isolation.sh`).
* Does **not** source `tests/helpers.sh` itself — each individual
  `test_*.sh` file sources `helpers.sh` on its own, and `run_tests.sh`
  treats every test file as an opaque subprocess.
* Invoked by `Makefile`'s `test:` target (`bash tests/run_tests.sh`), which
  is itself part of the `validate:` target (`json-check + lint + test`).
* `tests/test_run_tests_format.sh` (documented by the sibling companion
  pass) is the meta-test that verifies this script's own output format is
  correctly structured (i.e. it tests `run_tests.sh` itself).

## Last verified date

2026-09-17
