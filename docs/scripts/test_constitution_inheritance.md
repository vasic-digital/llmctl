## Overview

`tests/test_constitution_inheritance.sh` audits that this project correctly
inherits the Helix Constitution governance submodule (vendored at
`constitution/`) per the setup procedure's Step 7 & 9 invariants. It checks
that the submodule's canonical governance files exist and carry their
expected anchor text, that this project's own root `CLAUDE.md`/`AGENTS.md`
point back at the submodule (the inheritance-pointer pattern), that nested
submodules (`submodules/superspec`, `submodules/llama.cpp`,
`submodules/colibri`) carry their own inheritance pointers where
applicable, that the constitution submodule has its required upstream git
remotes configured, and finally that the submodule's own verification
harness and meta-test mutation both execute successfully. It exists because
governance inheritance is a structural, mechanically-checkable property
this project's constitution mandates be verified rather than assumed.

## Prerequisites

* No sourced helpers — this file does **not** source `tests/helpers.sh` and
  does not use its `assert_*`/`test_setup_env`/`test_finish` conventions;
  it is a self-contained script with its own `FAILURES` array and its own
  local `check_file_exists`/`check_anchor`/`check_inheritance_pointer`
  helper functions.
* `constitution/` — the vendored Helix Constitution git submodule, expected
  to contain `Constitution.md`, `CLAUDE.md`, `AGENTS.md`,
  `install_upstreams.sh`, `find_constitution.sh`, and
  `scripts/validation/run_verification.sh` +
  `scripts/validation/meta_test_verification.sh`.
* This project's own root `CLAUDE.md` and `AGENTS.md` (checked for an
  inheritance-pointer substring referencing `constitution/CLAUDE.md` /
  `constitution/AGENTS.md`).
* Nested submodule directories, checked only if present:
  `submodules/superspec`, `submodules/llama.cpp`, `submodules/colibri`
  (each checked for a `CLAUDE.md` or `AGENTS.md` containing the substring
  `Helix Constitution`).
* `git` — used inside the `constitution/` directory to count configured
  upstream remotes (`git remote`) and origin push URLs (`git remote
  get-url --push --all origin`).
* Writes two scratch files under the shared system temp directory,
  `/tmp/verification_output.txt` and `/tmp/meta_test_output.txt`, to
  capture the two harness scripts' output for display on failure (not
  under this project's own `tests/fixtures/` or an isolated per-test temp
  directory — this script predates, and does not follow, the
  `test_setup_env`/isolated-`TEST_TMP` convention the rest of the suite
  uses).

## Usage examples

* Standalone: `bash tests/test_constitution_inheritance.sh`
* Via the harness: `bash tests/run_tests.sh`
* Via `make test` / `make validate`.

## Edge cases

* **`constitution/` directory itself is missing**: Invariant 1 reports it
  missing and records a failure; later invariants that depend on it
  (`Constitution.md`/`CLAUDE.md`/`AGENTS.md` existence and anchor checks,
  the upstream-remote check, the harness executions) each independently
  guard with their own `[[ -f ... ]]`/`[[ -d ... ]]` check and report their
  own distinct failure rather than crashing.
* **A canonical governance file exists but is missing its expected anchor
  text**: `check_anchor` uses `grep -qF` (fixed-string match) against the
  exact anchor string per file — `"§11.4 End-user quality guarantee —
  forensic anchor"` in `Constitution.md`, `"MANDATORY ANTI-BLUFF COVENANT"`
  in `CLAUDE.md`, `"Anti-bluff covenant"` in `AGENTS.md` — and reports a
  distinct `"... anchor MISSING in ..."` failure if the file exists but the
  substring does not.
* **This project's own root `CLAUDE.md`/`AGENTS.md` is missing entirely**:
  reported as `"Parent CLAUDE.md missing"` / an analogous AGENTS.md
  failure, distinct from "file exists but lacks the inheritance pointer
  substring".
* **A nested submodule directory doesn't exist on disk**: reported as an
  informational `"- <submodule>: Not found"` line (not appended to
  `FAILURES` — a genuinely absent nested submodule is not itself a
  failure condition here, only a missing inheritance pointer *within* an
  existing submodule is).
* **A nested submodule exists but has neither `CLAUDE.md` nor `AGENTS.md`**:
  reported as an informational `"- <submodule>: No CLAUDE.md or AGENTS.md
  (will need inheritance pointer added)"` line, likewise not counted as a
  hard failure.
* **Fewer than 4 upstream remotes configured on the constitution
  submodule**: Invariant 8 counts `git remote` entries excluding `origin`
  itself, and separately counts `git remote get-url --push --all origin`
  lines; both must be `>= 4` or the whole check fails as one combined
  `"Insufficient upstream remotes ..."` failure.
* **The constitution's own verification harness
  (`scripts/validation/run_verification.sh`) fails**: its real exit code is
  captured; on failure the accumulated output (written to
  `/tmp/verification_output.txt`) is `cat`'d to the terminal so the
  operator sees exactly what failed, and a `"Verification harness
  execution failed"` entry is recorded.
* **The constitution's own meta-test mutation
  (`scripts/validation/meta_test_verification.sh`) fails**: same pattern —
  captured to `/tmp/meta_test_output.txt`, `cat`'d on failure, recorded as
  `"Meta-test mutation failed"`. This meta-test's entire purpose is to
  prove the verification harness is not a bluff (i.e. that it genuinely
  fails when a known violation is planted) — a failure here means the
  governance-verification mechanism itself cannot be trusted.
* **Every invariant passes**: prints `"ALL INVARIANTS PASSED ✓"` and exits
  0; the `FAILURES` array staying empty is the sole pass/fail signal (see
  Internal behaviour below for why this is deliberate under `set -e`).

## Internal behaviour

1. `set -euo pipefail` is active. Resolves `PROJECT_ROOT` (`..` from this
   script's own directory) and `CONSTITUTION_DIR="${PROJECT_ROOT}/constitution"`.
2. Declares an empty `FAILURES` array.
3. Defines three local helper functions — `check_file_exists`,
   `check_anchor`, `check_inheritance_pointer` — each of which prints a
   `✓`/`✗` line and, on failure, appends a message to `FAILURES`, but each
   **always explicitly `return 0`** regardless of whether the check
   passed. This is deliberate and documented in-file: under `set -e`, a
   bare statement (not wrapped in an `if`) that returns non-zero would
   abort the entire script at the *first* failing invariant, which would
   defeat this script's whole purpose — collecting and reporting *every*
   violation in one run rather than stopping at the first one.
4. **Invariant 1**: checks `constitution/` directory exists.
5. **Invariant 2**: checks `constitution/Constitution.md` exists and
   contains its anchor string.
6. **Invariant 3**: checks `constitution/CLAUDE.md` exists and contains
   its anchor string.
7. **Invariant 4**: checks `constitution/AGENTS.md` exists and contains
   its anchor string.
8. **Invariant 5 / 5b**: checks the project's own root `CLAUDE.md` /
   `AGENTS.md` exist and each contains an inheritance-pointer substring
   referencing the corresponding `constitution/*.md` file.
9. **Invariant 5c**: an informational-only check for
   `docs/validation_and_verification.md` (does not append to `FAILURES`
   either way — purely diagnostic output).
10. **Invariant 6**: iterates the three hardcoded nested-submodule paths
    (`submodules/superspec`, `submodules/llama.cpp`, `submodules/colibri`)
    and, for each present one, checks its `CLAUDE.md` (preferred) or
    `AGENTS.md` for the substring `"Helix Constitution"`.
11. **Invariant 7**: checks all five required constitution-submodule files
    exist (`Constitution.md`, `CLAUDE.md`, `AGENTS.md`,
    `install_upstreams.sh`, `find_constitution.sh`).
12. **Invariant 8**: inside a subshell `cd`'d into `constitution/`, counts
    upstream remotes (excluding `origin`) and origin push URLs, asserting
    both are `>= 4`.
13. **Invariant 9**: if `constitution/scripts/validation/run_verification.sh`
    exists, runs it, capturing output to `/tmp/verification_output.txt`;
    on non-zero exit, `cat`s that file and records a failure.
14. **Invariant 10**: same pattern for
    `constitution/scripts/validation/meta_test_verification.sh`.
15. Prints the final summary: `"ALL INVARIANTS PASSED ✓"` and exits 0 if
    `FAILURES` is empty; otherwise lists every collected failure message
    and exits 1.

## Related scripts

* Audits the vendored `constitution/` git submodule (Constitution.md,
  CLAUDE.md, AGENTS.md, `install_upstreams.sh`, `find_constitution.sh`,
  `scripts/validation/run_verification.sh`,
  `scripts/validation/meta_test_verification.sh`), none of which live
  under this project's own `lib/` or `bin/` and are explicitly out of
  scope for modification per this documentation task.
* Checks this project's own root `CLAUDE.md`/`AGENTS.md` inheritance
  pointers, and the nested `submodules/superspec`,
  `submodules/llama.cpp`, `submodules/colibri` submodules' own
  `CLAUDE.md`/`AGENTS.md`.
* Does **not** source `tests/helpers.sh` — it is the one file in this
  suite (besides `tests/helpers.sh` itself) with its own independent
  assertion/reporting convention (`FAILURES` array + `check_*` helpers)
  rather than `assert_*` + `test_finish`.
* Discovered and run by `tests/run_tests.sh` via its `test_*.sh` glob (it
  is invoked identically to every `helpers.sh`-based test — `run_tests.sh`
  does not care which internal convention a test file uses, only its real
  exit code).

## Last verified date

2026-09-17
