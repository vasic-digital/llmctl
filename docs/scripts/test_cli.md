## Overview

`tests/test_cli.sh` tests `bin/llmctl` — the project's single CLI
entrypoint — as a real subprocess, end to end: command dispatch, exit
codes, usage-error messages, `help`/`version` output, `models list`
rendering, `hw --json`/`hw` human output against a fake-hardware fixture,
`plan` end-to-end output, and refusal behavior for an unknown profile. It
exists to prove the CLI's outward-facing contract (what a real operator or
CLI-agent integration actually sees) without needing real hardware, real
downloaded models, or real running services — everything is driven through
`LLMCTL_FAKE_HW` and `LLMCTL_DRY_RUN` so the whole test is deterministic and
side-effect-free.

## Prerequisites

* `tests/helpers.sh` (sourced for `test_setup_env`/`test_finish`/assertion
  helpers), which isolates `LLMCTL_STATE_DIR`, `LLMCTL_RUNTIME_DIR`,
  `LLMCTL_CONFIG_DIR`, `LLMCTL_DATA_DIR`, `LLMCTL_MODELS_DIR`,
  `LLMCTL_LOG_DIR`, `LLMCTL_VERIFY_DIR`, `LLMCTL_SERVICES_DIR`,
  `LLMCTL_UNIT_DIR`, `LLMCTL_PLIST_DIR` under a fresh `mktemp -d`.
* `LLMCTL_FAKE_HW` set to `tests/fixtures/hw-baseline.json` — the fixture
  whose hardware profile (AMD Ryzen 7 2700X, RTX 3060 12 GB, etc.) the
  `hw`/`plan` assertions are written against.
* `LLMCTL_DRY_RUN=1` set for the one command (`start`) whose failure path
  is exercised, so no real process/service-management call is attempted.
* Real invocations of `bin/llmctl` (`${LLMCTL_ROOT}/bin/llmctl`) as a
  subprocess (not sourced) — this test exercises the actual CLI dispatch
  logic in `bin/llmctl`, not an internal library function directly.
* `python3` (used once, to parse `hw --json`'s output and pull out
  `cpu.model` for a structural assertion).

## Usage examples

* Standalone: `bash tests/test_cli.sh`
* Via the harness: `bash tests/run_tests.sh`
* Via `make test` / `make validate`.
* The real CLI invocation shape this test exercises directly:
  ```bash
  export LLMCTL_FAKE_HW="$(pwd)/tests/fixtures/hw-baseline.json"
  ./bin/llmctl help
  ./bin/llmctl models list
  ./bin/llmctl hw --json
  ./bin/llmctl plan
  LLMCTL_DRY_RUN=1 ./bin/llmctl start nosuchprofile
  ```

## Edge cases

* **`help`**: exits 0 and its output contains `USAGE`.
* **`version`**: exits 0 and its output contains the literal `llmctl 0.`
  prefix (i.e. asserts the version string is present and starts with a `0.`
  minor-version series, without pinning an exact patch number).
* **Unknown top-level command** (`frobnicate`): exits **2** (distinct from
  the exit-1 usage-error class below) and reports `unknown command:
  frobnicate`.
* **`switch` with no profile argument**: exits **1** and reports the exact
  usage hint `usage: llmctl switch <profile>`.
* **`models download` with no profile argument**: exits **1** and reports
  the exact usage hint `usage: llmctl models download <profile>`.
* **`models` with an unknown subcommand** (`models frob`): exits **1** and
  reports `unknown models subcommand: frob`.
* **`models list`**: asserts every one of the 10 catalog profiles (`fast`,
  `coder`, `vision`, `vision-pro`, `moe-fast`, `small`, `ws-dense-32b`,
  `ws-moe-30b`, `colibri-glm`, `colibri-qwen36`) appears somewhere in its
  rendered output.
* **`hw --json` against the fake-hardware fixture**: asserts (via a
  `python3 -c 'import json,...'` one-liner piped the captured output) that
  `cpu.model` is exactly `"AMD Ryzen 7 2700X Eight-Core Processor"` — i.e.
  the fixture's contents pass through the CLI verbatim rather than the CLI
  falling back to a real host probe.
* **`hw` (human, non-JSON) against the same fixture**: asserts the GPU name
  `"NVIDIA GeForce RTX 3060"` appears in the human-readable rendering.
* **`plan` end-to-end**: asserts the tier line `Host tier:   baseline`
  (matching the fixture's classified tier) and the co-residency grouping
  line `group 1: fast, coder, vision` both appear — i.e. the full
  probe→plan pipeline produces the expected planner output for this
  fixture.
* **Starting an unknown profile under `LLMCTL_DRY_RUN=1`**: `start
  nosuchprofile` exits **1** and reports `unknown profile: nosuchprofile` —
  proving the scheduler validates the profile name against the catalog
  before attempting any dry-run service action.

## Internal behaviour

1. Sources `tests/helpers.sh`, calls `test_setup_env`.
2. Exports `LLMCTL_FAKE_HW` pointing at `tests/fixtures/hw-baseline.json`
   and sets `LLMCTL="${LLMCTL_ROOT}/bin/llmctl"`.
3. Runs `"${LLMCTL}" help`, captures output+rc, asserts rc 0 and `USAGE`
   substring present.
4. Runs `"${LLMCTL}" version`, asserts rc 0 and the `llmctl 0.` substring.
5. Runs `"${LLMCTL}" frobnicate 2>&1`, asserts rc 2 and the `unknown
   command: frobnicate` message.
6. Runs `"${LLMCTL}" switch 2>&1` (no argument), asserts rc 1 and the exact
   switch-usage string.
7. Runs `"${LLMCTL}" models download 2>&1` (no argument), asserts rc 1 and
   the exact models-download-usage string.
8. Runs `"${LLMCTL}" models frob 2>&1`, asserts rc 1 and the unknown-
   subcommand message.
9. Runs `"${LLMCTL}" models list`, loops over the 10 expected profile
   names and asserts each is `assert_contains`-present in the output.
10. Runs `"${LLMCTL}" hw --json`, pipes the captured JSON into a Python
    one-liner to extract `cpu.model`, asserts it equals the fixture's CPU
    model string.
11. Runs `"${LLMCTL}" hw` (human mode) and asserts the GPU name substring.
12. Runs `"${LLMCTL}" plan` and asserts both the tier line and the
    group-1 co-residency line.
13. Runs `LLMCTL_DRY_RUN=1 "${LLMCTL}" start nosuchprofile 2>&1`, asserts
    rc 1 and the unknown-profile message.
14. Calls `test_finish`, which exits non-zero if any assertion failed.

## Related scripts

* Exercises `bin/llmctl` (the CLI dispatcher) as a real subprocess — see
  `docs/scripts/llmctl.md` (already documented) for the entrypoint's own
  contract.
* Exercises, indirectly through the CLI, `lib/hardware.sh` (`hw`
  subcommand → `hw_probe_json`/`hw_probe_human`), `lib/catalog.sh`
  (`models list`, `plan`), `lib/scheduler.sh` (`start`, `switch`).
* Reads `tests/fixtures/hw-baseline.json` via `LLMCTL_FAKE_HW`.
* Sources `tests/helpers.sh` for `test_setup_env`/`test_finish`/assertion
  helpers.
* Discovered and run by `tests/run_tests.sh`.
* Sibling determinism test `tests/test_determinism.sh` (documented in this
  same set) re-invokes the identical `hw --json`/`plan --json` commands
  against the same fixture to prove byte-identical repeatability, a
  property this test does not itself check.
* Sibling hardware-probe test `tests/test_hardware_probe.sh` (documented in
  this same set) tests `lib/hardware.sh`'s `hw_probe_json`/`hw_probe_human`
  functions directly (sourced), rather than through the CLI dispatcher.

## Last verified date

2026-09-17
