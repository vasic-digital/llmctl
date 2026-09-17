## Overview

`tests/test_determinism.sh` proves llmctl's zero-flake requirement
(spec.md SC-001): running the same `bin/llmctl` command against the same
fixed hardware fixture multiple times in a row must produce
**byte-identical** output every single time. This test exists because
Constitution §11.4.50 (deterministic-consistency mandate) and this
project's own anti-bluff test methodology require that a command's output
never depend on incidental factors (map/hash-iteration order, timestamps,
process IDs, wall-clock-dependent formatting, etc.) — a test suite that
only asserts a command "looks right" once would miss a latent
nondeterminism bug that silently makes downstream tooling (CLI-agent
integrations, CI pipelines comparing `plan --json` output) unreliable.

## Prerequisites

* `tests/helpers.sh` (sourced for `test_setup_env`/`test_finish`/assertion
  helpers).
* `LLMCTL_DRY_RUN=1` — set so no real process-management/service action is
  ever attempted (not strictly required by the two read-only commands this
  test exercises, but set defensively/consistently with the harness
  convention).
* `LLMCTL_FAKE_HW` set to `tests/fixtures/hw-baseline.json` — the same
  fixture `tests/test_cli.sh` uses, so the hardware input to both `hw` and
  `plan` is fixed and repeatable.
* Real invocations of `bin/llmctl` (`${LLMCTL_ROOT}/bin/llmctl`) as a
  subprocess, run three times per command under test.

## Usage examples

* Standalone: `bash tests/test_determinism.sh`
* Via the harness: `bash tests/run_tests.sh`
* Via `make test` / `make validate`.
* The real invocation shape exercised (run 3× per command):
  ```bash
  export LLMCTL_DRY_RUN=1
  export LLMCTL_FAKE_HW="$(pwd)/tests/fixtures/hw-baseline.json"
  ./bin/llmctl hw --json
  ./bin/llmctl plan --json
  ```

## Edge cases

* **`hw --json` output must be byte-identical across 3 independent real
  invocations**: captures the output of three separate subprocess calls
  and asserts run 1 == run 2, then run 2 == run 3 (transitively covering
  all three); also sanity-checks the output is not empty/degenerate by
  asserting the literal substring `"cores"` is present (i.e. this is real
  hardware-shaped JSON, not an empty or truncated payload that would
  trivially and meaninglessly "match itself").
* **`plan --json` output must likewise be byte-identical across 3
  independent real invocations**: same two-comparison pattern (run 1 ==
  run 2, run 2 == run 3) applied to the planner's JSON output, which
  depends on more computation (catalog matching, co-residency
  bin-packing) than the raw hardware probe and is therefore a stronger
  determinism signal.

## Internal behaviour

1. Sources `tests/helpers.sh`, calls `test_setup_env`.
2. Exports `LLMCTL_DRY_RUN=1` and `LLMCTL_FAKE_HW` (pointing at the
   baseline fixture); sets `LLMCTL="${LLMCTL_ROOT}/bin/llmctl"`.
3. Runs `"${LLMCTL}" hw --json` three times in sequence, capturing each
   output into `out1`/`out2`/`out3`.
4. Asserts `out1 == out2` and `out2 == out3` (byte-for-byte string
   equality via `assert_eq`).
5. Asserts `out1` contains the `"cores"` substring (non-degenerate output
   sanity check).
6. Runs `"${LLMCTL}" plan --json` three times, capturing into
   `plan1`/`plan2`/`plan3`.
7. Asserts `plan1 == plan2` and `plan2 == plan3`.
8. Calls `test_finish`.

## Related scripts

* Exercises `bin/llmctl`'s `hw --json` and `plan --json` subcommands as
  real subprocesses — see `docs/scripts/llmctl.md` (already documented)
  for the entrypoint's own contract.
* Exercises, indirectly through the CLI, `lib/hardware.sh` (the JSON probe
  the `hw` subcommand renders) and `lib/catalog.sh` (the planner logic
  behind `plan`).
* Reads `tests/fixtures/hw-baseline.json` via `LLMCTL_FAKE_HW`.
* Sources `tests/helpers.sh` for `test_setup_env`/`test_finish`/assertion
  helpers.
* Discovered and run by `tests/run_tests.sh`.
* Sibling test `tests/test_cli.sh` (documented in this same set) exercises
  the *content* correctness of `hw --json`/`hw`/`plan` against the same
  fixture (specific field values), whereas this test exercises only
  *repeatability* (byte-identical output across repeated runs) — the two
  are complementary, not overlapping, checks.
* Sibling test `tests/test_hardware_probe.sh` (documented in this same
  set) tests `lib/hardware.sh`'s `hw_probe_json` function directly
  (sourced) rather than through the CLI, including its real (non-fixture)
  probe path this test never exercises.

## Last verified date

2026-09-17
