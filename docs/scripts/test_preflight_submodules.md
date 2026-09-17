## Overview

`tests/test_preflight_submodules.sh` proves that
`preflight_check_ref`/`preflight_run` (defined in
`scripts/release/preflight_submodules.sh`) genuinely distinguish three
distinct outcomes when verifying that a pinned submodule commit is
reachable from its declared upstream: (1) a genuinely reachable pinned
commit, (2) a genuinely unreachable pinned commit (the object has
actually been pruned away, not merely unreferenced-but-recoverable), and
(3) a fetch that fails outright (network/host/auth-shaped failure) —
which must be reported as a distinct "could not verify" outcome, never
conflated with either of the other two. This is release-packaging safety
machinery (Phase 8 T044, `spec.md` FR-014/FR-052/Clarification 21): "no
artifact is produced with a missing or empty submodule directory," and
the pre-flight check must hard-fail naming the specific unreachable
submodule and its expected ref rather than silently proceeding. All
fixtures in this test are **real local git repositories** created,
committed to, and (for the negative case) actually pruned by the test
itself — never mocked network calls — so the reachable/unreachable
distinction is proven against real git plumbing (`git fetch`,
`git cat-file -e`).

## Prerequisites

* Sources `tests/helpers.sh` for assertion helpers and
  `test_setup_env`/`test_finish`.
* Sources `${LLMCTL_ROOT}/scripts/release/preflight_submodules.sh`
  directly to bring `preflight_check_ref` and `preflight_run` into the
  test's own shell.
* Requires a real, working `git` (`git init`, `git config`, `git add`,
  `git commit`, `git checkout --orphan`, `git rm`, `git branch -D`/`-m`,
  `git reflog expire --expire=now --all`, `git gc --prune=now`,
  `git cat-file -e`, `git -C ... rev-parse HEAD`) — this test performs
  real git operations, not stubs.
* Uses `${TEST_TMP}/preflight_fixtures` (built from `test_setup_env`'s
  isolated `TEST_TMP`) as scratch space for four throwaway local git
  repositories it creates: `upstream_good`, `scratch_good`,
  `upstream_bad`, `scratch_bad`, plus a `scratch_noconn` directory used
  for the fetch-failure case.
* Uses `file://` URLs to reference the local upstream fixture
  repositories (no network access, no external services required) and
  one deliberately nonexistent path
  (`file:///nonexistent/path/that/does/not/exist`) to force a real fetch
  failure without any network dependency.

## Usage examples

```bash
bash tests/test_preflight_submodules.sh
```

Also runs as part of the full suite via `tests/run_tests.sh` or
`make test`.

Reproducing the function calls directly (for exploration, not how the
test itself is invoked):

```bash
source scripts/release/preflight_submodules.sh
preflight_check_ref <scratch-dir> <upstream-url> <expected-sha>
preflight_run <submodule-name> <upstream-url> <expected-sha>
```

## Edge cases

* **Reachable pinned commit**: creates `upstream_good` with one real
  commit, captures its SHA, and asserts `preflight_check_ref` against an
  empty `scratch_good` clone target returns exit `0`.
* **Unreachable pinned commit (genuinely pruned, not just orphaned)**:
  creates `upstream_bad` with a commit, captures its SHA, then
  deliberately orphans and hard-prunes that commit
  (`git checkout --orphan`, `git rm`, force-move the branch,
  `git reflog expire --expire=now --all`, `git gc --prune=now`) so the
  object is genuinely gone — not merely unreferenced-but-recoverable.
  **Fixture self-check**: before testing the function under test at all,
  the script independently verifies with `git cat-file -e
  "${BAD_SHA}^{commit}"` that the fixture itself really lost the object
  (Constitution §11.4.115(F): a RED test must reproduce the *real*
  condition, not merely assume it). Only then does it assert
  `preflight_check_ref` against this fixture returns exit `1`.
* **`preflight_run` top-level wrapper**: asserts it exits `1` and its
  combined stdout+stderr names both the specific unreachable submodule
  (`"bad-submodule"`) and the specific unreachable ref (the `BAD_SHA`
  value) when given the bad fixture; asserts it exits `0` cleanly when
  given the good fixture.
* **Fetch failure is a THIRD, distinct outcome (rc=2), never conflated
  with rc=1 (confirmed-unreachable) or rc=0 (reachable)**: pointing
  `preflight_check_ref` at a `file://` URL for a path that does not exist
  on disk (so the fetch itself fails immediately, with no network
  dependency) asserts a return code of exactly `2` — distinct from both
  the reachable (`0`) and confirmed-unreachable (`1`) cases. The script's
  own comment explicitly frames this as the Constitution §11.4.201
  false-positive-refusal class: a network/host failure and a
  proven-absent-ref are different findings requiring different operator
  responses, and lumping them together would itself be a guard-honesty
  violation. `preflight_run` on the same unfetchable case also returns
  `2` and its output is asserted to contain the honest string
  `"UNKNOWN"` — never a false PASS nor a false "confirmed unreachable"
  claim.

## Internal behaviour

1. `set -euo pipefail`; source `tests/helpers.sh`; `test_setup_env`.
2. Source `scripts/release/preflight_submodules.sh` to get
   `preflight_check_ref` / `preflight_run` into scope.
3. Create `WORK="${TEST_TMP}/preflight_fixtures"`.
4. **Fixture 1 (good)**: `git init` `upstream_good`, commit one file,
   capture `GOOD_SHA`; `git init` an empty `scratch_good`; call
   `preflight_check_ref` against it and assert rc `0`.
5. **Fixture 2 (bad)**: `git init` `upstream_bad`, commit one file,
   capture `BAD_SHA`; orphan-and-prune that commit's object out of
   existence; sanity-assert (via `git cat-file -e`) that the object is
   genuinely gone; `git init` an empty `scratch_bad`; call
   `preflight_check_ref` against it and assert rc `1`.
6. Call `preflight_run` for `"bad-submodule"` against the bad upstream
   and assert rc `1` plus both the submodule name and the bad SHA appear
   in its captured output; call `preflight_run` for `"good-submodule"`
   against the good upstream and assert rc `0`.
7. **Fixture 3 (unfetchable)**: `git init` an empty `scratch_noconn`;
   call `preflight_check_ref` against a nonexistent `file://` path and
   assert rc `2`; call `preflight_run` for `"unfetchable-submodule"`
   against the same nonexistent path and assert rc `2` and that its
   output contains `"UNKNOWN"`.
8. `test_finish` tears down the temp environment (removing all four
   throwaway git repos along with the rest of `TEST_TMP`) and exits
   non-zero iff any assertion failed.

## Related scripts

* Sources `tests/helpers.sh` (sibling, documented separately).
* Exercises `scripts/release/preflight_submodules.sh`'s
  `preflight_check_ref` and `preflight_run` functions directly (that
  script itself has its own companion doc,
  `docs/scripts/preflight_submodules.md`, covering the library script —
  not to be confused with this file, which documents the *test* for it).
* Related release-process scripts in the same directory:
  `scripts/release/build_archive.sh`, `scripts/release/create_release.sh`
  (see `docs/release-process.md` for how the preflight fits into the
  overall release pipeline).
* Discovered and run automatically by `tests/run_tests.sh`; syntax and
  shebang/strict-mode covered by `tests/test_syntax.sh` (which also
  syntax-checks every file under `scripts/release/*.sh`).

## Last verified date

2026-09-17
