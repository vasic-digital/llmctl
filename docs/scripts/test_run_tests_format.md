## Overview

`tests/test_run_tests_format.sh` verifies that `tests/run_tests.sh` (the
project's own deterministic test-runner harness) emits grep-parseable
`CMD:` / `OUTPUT:` / `EXIT:` markers for every test file it runs, and
that those three markers appear in that order for one test block. This
is the harness's own anti-bluff contract (Phase 4 T021, `spec.md` FR-002:
"producing deterministic evidence (exit codes, raw output) for every
test") — it exists to prove the harness that every other test in this
suite is run through is itself trustworthy machine-readable evidence,
not just a pass/fail summary line.

## Prerequisites

* Sources `tests/helpers.sh` for assertion helpers (does **not** call
  `test_setup_env`/rely on `LLMCTL_*` isolation state — it manages its
  own isolated scratch directory directly via `mktemp -d` and an `EXIT`
  trap, and calls `test_finish` at the end which safely no-ops the
  teardown of an unset `TEST_TMP`).
* Requires `bash`, `cp`, `cat`, `chmod`, `mktemp`, `grep`, `cut`.
* Copies the real, unmodified `tests/run_tests.sh` into an isolated
  temporary directory, and writes one synthetic
  `test_fake_pass.sh` fixture into that same isolated directory — it
  never runs the harness against the real `tests/` directory.

## Usage examples

```bash
bash tests/test_run_tests_format.sh
```

Also runs as part of the full suite via `tests/run_tests.sh` or
`make test` — see the "Internal behaviour" section below for why this
specific test is careful about *how* it invokes a copy of the harness
rather than the harness itself.

## Edge cases

* Asserts the isolated harness run exits `0` on an all-passing fake
  suite (its one fixture, `test_fake_pass.sh`, echoes a fixed string and
  exits `0`).
* Asserts the output contains a `CMD:` line naming the *real* invoked
  command (`CMD:  bash <tmpdir>/test_fake_pass.sh`) — proving the harness
  reports the actual command line it ran, not a placeholder.
* Asserts an `OUTPUT:` label is present — the grep-parseable evidence
  marker FR-002 requires — and that it is followed by the real captured
  subprocess output (`"fake test body output"`).
* Asserts an `EXIT: 0` line is present with the real captured exit code.
* **Ordering check** (the part a naive `assert_contains`-per-label
  wouldn't catch): the script explicitly extracts the line numbers of the
  *first* occurrence of `^CMD:`, `^OUTPUT:`, and `^EXIT:` via
  `grep -n ... | head -1 | cut -d: -f1` and asserts
  `cmd_line < output_line < exit_line` — because, per the script's own
  comment, a bare `assert_contains` on each label alone would still pass
  even if, say, `OUTPUT:` appeared only in the unrelated `SUMMARY`
  section rather than attached to this specific test block. On failure
  this branch prints a `FAIL:` line and increments `TEST_FAILS` itself
  (it does not call `assert_eq`/`assert_contains` for this particular
  check — it is a hand-rolled conditional using the same `TEST_FAILS`
  counter convention as `helpers.sh`).

## Internal behaviour

1. `set -euo pipefail`; source `tests/helpers.sh` (for `assert_*` and
   `test_finish`, but not `test_setup_env`).
2. Create an isolated `harness_tmp="$(mktemp -d)"` and register
   `trap 'rm -rf "${harness_tmp}"' EXIT` so it is always cleaned up.
3. Copy the real `tests/run_tests.sh` into `harness_tmp/run_tests.sh`.
4. Write a minimal fake test file `harness_tmp/test_fake_pass.sh` (echoes
   `"fake test body output"`, exits `0`) and `chmod +x` both the copied
   harness and the fake test.
5. Invoke the *copied* harness as a real subprocess:
   `bash "${harness_tmp}/run_tests.sh"`, capturing combined
   stdout+stderr and the exit code.
6. Assert the harness's own exit code is `0`.
7. Assert the captured output contains the expected `CMD:`, `OUTPUT:`,
   and the raw fake-test body output, and `EXIT: 0`.
8. Extract and compare the line numbers of the first `CMD:`, `OUTPUT:`,
   and `EXIT:` lines to confirm ordering, reporting a hand-rolled
   `FAIL:`/`ok:`-style message either way.
9. Call `test_finish`, which (since `test_setup_env` was never called
   here) safely no-ops its `TEST_TMP`-based teardown and exits non-zero
   iff `TEST_FAILS` is non-zero.

The file's header explains *why* it copies the harness into an isolated
directory rather than invoking `tests/run_tests.sh` directly: this test
file itself matches the `test_*.sh` glob the real harness enumerates, so
running the real harness from inside a test the real harness would
itself re-enumerate causes unbounded recursive self-invocation. Copying
the harness (unmodified) into an isolated directory alongside a single
controlled fixture avoids the recursion while still exercising the real,
unmodified harness logic as a genuine subprocess (no mocking of the code
under test).

## Related scripts

* Sources `tests/helpers.sh` (sibling, documented separately) for
  `assert_*`/`test_finish` only.
* Its subject under test is `tests/run_tests.sh` itself (a *copy* of it,
  run as a real subprocess) — documented separately as a sibling script
  by another agent.
* Discovered and run automatically by the real (uncopied)
  `tests/run_tests.sh` as one of the `test_*.sh` files it enumerates;
  also covered by `tests/test_syntax.sh`'s `bash -n` + shebang +
  strict-mode sweep.

## Last verified date

2026-09-17
