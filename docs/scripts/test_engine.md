## Overview

`tests/test_engine.sh` tests the cheap, deterministic parts of
`lib/engine.sh` — the module responsible for building the llama.cpp and
colibri inference engines from their pinned git submodules. Specifically it
verifies (a) which directories `lib/engine.sh` resolves as the real engine
*source* trees, (b) that its submodule-presence detection
(`engine_ensure_submodules`) checks those same correct paths rather than a
stale/wrong location, and (c) that `LLMCTL_DRY_RUN=1` makes the build
functions print what they *would* run instead of actually invoking
`cmake`/`make`. Full engine compiles (a real `cmake`/`make` build against
the ~3500-file llama.cpp tree and the colibri tree) are explicitly *not*
covered here — those are release-gating concerns under Clarification 1's
hybrid testing approach, not part of this project's fast/deterministic
suite.

## Prerequisites

* `tests/helpers.sh` (sourced for `test_setup_env`/`test_finish`/assertion
  helpers).
* `lib/common.sh`, `lib/os_detect.sh`, `lib/engine.sh` — all three sourced
  directly so the test can inspect `LLMCTL_LLAMA_SRC`/`LLMCTL_COLIBRI_SRC`
  and call `engine_ensure_submodules`/`engine_build_llama`/
  `engine_build_colibri` as in-process functions.
* `LLMCTL_ROOT` (exported by `tests/helpers.sh`'s `test_setup_env`/module
  load) — used both directly and, for the fake-root scenarios, overridden
  inside an isolated subshell.
* `LLMCTL_DRY_RUN=1` — set for the build-function assertions so no real
  `cmake`/`make` invocation is attempted.
* No fixture files under `tests/fixtures/` are read; the fake-submodule
  scenarios instead synthesize a throwaway directory tree
  (`${TEST_TMP}/fake-root/submodules/{llama.cpp,colibri}`) with empty
  placeholder `.git` files standing in for a real initialized git
  submodule.

## Usage examples

* Standalone: `bash tests/test_engine.sh`
* Via the harness: `bash tests/run_tests.sh`
* Via `make test` / `make validate`.
* The real function-level invocation shape this test exercises (after
  sourcing the three `lib/*.sh` files):
  ```bash
  echo "${LLMCTL_LLAMA_SRC}"     # -> <root>/submodules/llama.cpp
  echo "${LLMCTL_COLIBRI_SRC}"   # -> <root>/submodules/colibri
  engine_ensure_submodules
  LLMCTL_DRY_RUN=1 engine_build_llama
  LLMCTL_DRY_RUN=1 engine_build_colibri
  ```

## Edge cases

* **Engine source paths must resolve to the real, pinned git submodules,
  not a stale `vendor/` copy**: the project's actual git submodules (per
  `.gitmodules`, pinned tags, clean `git submodule status`) live under
  `submodules/llama.cpp` and `submodules/colibri` — **not**
  `vendor/llama.cpp`/`vendor/colibri`, which the in-file comment documents
  as "a separate, un-pinned, directly-committed copy left over from an
  earlier design" (per the Phase 3 investigation referenced in
  `tasks.md`/`progress.yml`). Asserts `LLMCTL_LLAMA_SRC` and
  `LLMCTL_COLIBRI_SRC` equal `${LLMCTL_ROOT}/submodules/llama.cpp` and
  `${LLMCTL_ROOT}/submodules/colibri` respectively.
* **`engine_ensure_submodules` checks the SAME correct paths (not
  `vendor/`) against a fake root**: constructs a fake `LLMCTL_ROOT` under
  `${TEST_TMP}/fake-root` with `submodules/llama.cpp/.git` and
  `submodules/colibri/.git` both present (as empty placeholder files, not
  real git repos — `engine_ensure_submodules` only checks for a `.git`
  entry's presence, not its content), and runs the check inside a
  dedicated subshell (`run_ensure_submodules`) that re-exports
  `LLMCTL_ROOT` and re-sources the three `lib/*.sh` files so the override
  never leaks into the rest of the test file. Asserts the function exits
  0 and produces no "not initialized" warning when both are present.
* **A missing submodule at the correct path is detected and reported (at
  the new, correct path name)**: removes
  `${FAKE_ROOT}/submodules/colibri/.git` and re-runs the check, asserting
  the output contains `"submodule submodules/colibri not initialized"` —
  i.e. the missing-submodule warning names the real, current path
  (`submodules/colibri`), not the old `vendor/colibri` path this test's
  in-file comments explain was replaced.
* **`LLMCTL_DRY_RUN=1` makes `engine_build_llama` print, not execute**:
  asserts the captured output contains the literal `[dry-run]` marker and
  additionally names the `cmake` command it would have run — proving the
  dry-run path is not merely silent but genuinely informative about what
  action was skipped. The in-file comment notes this test closes a real
  prior gap: every other heavy/side-effecting module in this codebase
  (`scheduler.sh`, `service_linux.sh`, `service_macos.sh`, `download.sh`)
  already supported `LLMCTL_DRY_RUN`; `engine.sh` was the one exception,
  which made verifying `llmctl setup`'s full orchestration in a fast test
  impossible without a real multi-minute compile.
* **`LLMCTL_DRY_RUN=1` makes `engine_build_colibri` print, not execute**:
  asserts the captured output contains `[dry-run]` (mirroring the llama.cpp
  case, for the `make`-based colibri build).

## Internal behaviour

1. Sources `tests/helpers.sh`, calls `test_setup_env`; sources
   `lib/common.sh`, `lib/os_detect.sh`, `lib/engine.sh` at the top level
   (against the *real* `LLMCTL_ROOT`).
2. Asserts `LLMCTL_LLAMA_SRC`/`LLMCTL_COLIBRI_SRC` equal the real
   `submodules/llama.cpp`/`submodules/colibri` paths.
3. Defines a local `run_ensure_submodules <fake-root>` helper: inside a
   subshell, it re-exports `LLMCTL_ROOT="$1"`, re-sources
   `lib/common.sh`/`lib/os_detect.sh`/`lib/engine.sh` (so all internal
   state is recomputed against the fake root), calls
   `engine_ensure_submodules`, and returns its combined stdout+stderr
   (`2>&1`) — deliberately isolated in a subshell so the fake
   `LLMCTL_ROOT` override cannot leak into the rest of this test file's
   environment.
4. Creates `${TEST_TMP}/fake-root/submodules/{llama.cpp,colibri}` with
   placeholder `.git` files, calls `run_ensure_submodules` against it,
   asserts real exit code 0 and empty output.
5. Removes the placeholder `.git` file for `colibri` only, re-runs the
   helper (tolerating a non-zero exit via `|| true` since a warning may
   accompany a non-zero status), and asserts the output names the missing
   submodule at its correct current path.
6. Exports `LLMCTL_DRY_RUN=1` (now for the rest of the top-level script,
   against the real, non-fake `LLMCTL_ROOT`), calls `engine_build_llama`
   and asserts its output contains `[dry-run]` and `cmake`.
7. Calls `engine_build_colibri` and asserts its output contains
   `[dry-run]`.
8. Calls `test_finish`.

## Related scripts

* Exercises `lib/engine.sh`'s `LLMCTL_LLAMA_SRC`/`LLMCTL_COLIBRI_SRC`
  path-resolution variables and its `engine_ensure_submodules`,
  `engine_build_llama`, `engine_build_colibri` functions directly
  (sourced).
* Sources `lib/common.sh` and `lib/os_detect.sh` as `lib/engine.sh`'s own
  dependencies (each already documented separately: `common.md`,
  `os_detect.md`).
* Sources `tests/helpers.sh` for `test_setup_env`/`test_finish`/assertion
  helpers.
* Discovered and run by `tests/run_tests.sh`.
* Relates to the project's real, pinned git submodules
  `submodules/llama.cpp` (v0.4.0) and `submodules/colibri` (v1.11.0), and
  to `llmctl setup`'s full orchestration (`bin/llmctl`), whose dry-run
  path this test's dry-run assertions specifically make fast-testable.

## Last verified date

2026-09-17
