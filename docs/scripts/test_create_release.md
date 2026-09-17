## Overview

`tests/test_create_release.sh` tests `scripts/release/create_release.sh` —
the script that drives a real llmctl release: SemVer validation of the
requested version string, conventional-commit changelog generation from
real git history, per-forge (GitHub/GitLab) idempotent publish-state
tracking, and `--dry-run`'s zero-network-mutating-call guarantee. It
exists to prove the release tooling's correctness (Phase 8 T045/T046,
spec.md FR-013/FR-050/SC-009, Clarification 5/19) against **real** git
history and against real (but fake, PATH-injected) `gh`/`glab` binaries —
never against the actual GitHub/GitLab APIs, so the test suite never makes
a real network call or a real release.

## Prerequisites

* `tests/helpers.sh` (sourced for `test_setup_env`/`test_finish`/assertion
  helpers).
* `scripts/release/create_release.sh`, sourced directly (`source
  "${LLMCTL_ROOT}/scripts/release/create_release.sh"`) so the test can call
  its internal functions (`release_validate_semver`,
  `release_generate_changelog`, `release_state_get`, `release_state_set`,
  `release_publish_forge`, `release_run_publish_both`) directly, in
  addition to invoking the script itself as a subprocess for the
  `--dry-run` scenario.
* `git` — used to build a real, throwaway repository with real
  conventional-commit-formatted commit messages (`feat:`, `fix:`, `docs:`,
  plus one deliberately-unprefixed commit) and a real tag (`v1.0.0`).
* `LLMCTL_RELEASE_STATE_DIR` — set by the test to a scratch directory under
  `${TEST_TMP}` so `release_state_get`/`release_state_set`'s persisted
  per-forge state never touches the real project's release-state
  location.
* Fake, PATH-injected `gh` and `glab` binaries — the test writes two tiny
  executable shell scripts (`${TEST_TMP}/fake_bin/gh` and `.../glab`) that
  log their invocation arguments to a file (`FAKE_GH_LOG`/`FAKE_GLAB_LOG`)
  and exit with a caller-controlled code (`FAKE_GH_EXIT`/`FAKE_GLAB_EXIT`,
  default 0), then prepends `${FAKE_BIN}` onto `PATH` for the calls under
  test — this is what lets the test exercise `release_publish_forge`'s
  real subprocess-invocation logic without ever calling the real `gh`/`glab`
  CLIs.

## Usage examples

* Standalone: `bash tests/test_create_release.sh`
* Via the harness: `bash tests/run_tests.sh`
* Via `make test` / `make validate`.
* The real dry-run CLI invocation this test exercises as a subprocess (not
  just via the sourced functions):
  ```bash
  PATH="<fake-bin-dir>:${PATH}" LLMCTL_RELEASE_STATE_DIR=<scratch-dir> \
    bash scripts/release/create_release.sh --dry-run v1.0.0
  ```

## Edge cases

* **SemVer validation** (`release_validate_semver`): `v1.0.0` valid;
  `v1.0.0-rc.1` (pre-release suffix) valid; `1.2.3` (no leading `v`) valid;
  `v1.0` (missing PATCH component) rejected; `not-a-version` (garbage
  string) rejected.
* **Changelog generation from real conventional-commit history**
  (`release_generate_changelog`): given a real git repo with commits
  tagged `v1.0.0` and four commits after it (`feat: add widget support`,
  `fix: correct widget off-by-one`, `docs: document widgets`, and an
  unrelated commit with no conventional-commit prefix), asserts the
  generated changelog includes all three prefixed commit messages,
  groups `feat:` commits under a `Features` heading, and groups `fix:`
  commits under a `Fixes` heading. (The unprefixed commit's inclusion or
  exclusion is not itself asserted here.)
* **Per-forge idempotent state tracking**: a forge with no recorded state
  defaults to `pending`; `release_state_set`/`release_state_get`
  round-trips real persisted state; a *different* forge for the same
  version tag has genuinely independent state (setting `github` to `done`
  does not affect `gitlab`'s still-`pending` state for the same version).
* **`release_publish_forge` invokes the real fake `gh`/`glab` binary with
  the expected arguments**: asserts the fake `gh` binary's log contains
  the literal substring `release create`, and that a successful publish is
  recorded as `done` in per-forge state.
* **One forge fails → the whole release is treated as failed, but only the
  failed forge is retried** (Clarification 19): with `FAKE_GH_EXIT=1`,
  `release_run_publish_both` exits 1 even though `glab` (unaffected)
  succeeds; asserts `github`'s state is recorded as `failed` (not `done`)
  while `gitlab`'s state is independently recorded as `done`. This
  scenario deliberately uses a **fresh** tag (`v9.9.10`, not the `v9.9.9`
  used in the prior successful-publish scenario) — reusing `v9.9.9` would
  let `github`'s already-`done` state silently make the induced
  `FAKE_GH_EXIT=1` failure path a no-op, so the test first asserts
  `v9.9.10`/`github` genuinely starts `pending` as a sanity check before
  inducing the failure.
* **Idempotent retry re-runs only the previously-failed forge**: on a
  second run of `release_run_publish_both` for the same `v9.9.10` tag
  (now with `FAKE_GH_EXIT=0`, simulating the underlying issue being
  fixed), asserts `gh`'s fake log shows the `release create` invocation
  exactly **twice** total (1 failed attempt + 1 retry attempt), while
  `glab`'s fake log shows **zero** new invocations (its prior `done`
  state means it is correctly skipped on retry) — proving retry targets
  only the forge that actually failed, and asserts `github`'s state is
  now `done`.
* **`--dry-run` performs every real check but makes zero calls to
  `gh`/`glab`**: invokes the actual `create_release.sh --dry-run v1.0.0`
  script as a subprocess (with the fake binaries still on `PATH`, so a
  real invocation would be immediately detectable), and asserts both fake
  logs are empty and the captured output contains the literal substring
  `dry-run`.

## Internal behaviour

1. Sources `tests/helpers.sh`, calls `test_setup_env`.
2. Sources `scripts/release/create_release.sh` directly, making its
   internal `release_*` functions callable in-process.
3. **SemVer block**: calls `release_validate_semver` against five inputs
   (three valid, two invalid), asserting each real exit code matches
   expectation.
4. **Changelog block**: `git init`s a real repo under `${TEST_TMP}`,
   commits five real commits (one before/at tag `v1.0.0`, four after with
   mixed conventional-commit prefixes), then calls
   `release_generate_changelog "${REPO}" "v1.0.0"` and asserts the real
   output's content and section-grouping.
5. **State-tracking block**: sets `LLMCTL_RELEASE_STATE_DIR` to a fresh
   scratch dir, exercises `release_state_get`/`release_state_set` directly
   for default/round-trip/cross-forge-independence behavior.
6. **Fake-binary setup**: writes executable `gh`/`glab` fakes to
   `${TEST_TMP}/fake_bin`, each appending its invocation to a log file and
   exiting with a controllable code; exports the log-file paths as
   `FAKE_GH_LOG`/`FAKE_GLAB_LOG`; writes a scratch release-notes file.
7. **Single-forge publish block**: runs `release_publish_forge "github"
   "v9.9.9" "v9.9.9" "${NOTES}"` with `PATH` prefixed by the fake bin dir
   and `FAKE_GH_EXIT=0`; asserts the fake log recorded the invocation and
   state was set to `done`.
8. **Mixed-failure block**: clears both fake logs; asserts `v9.9.10`/
   `github` starts `pending`; runs `release_run_publish_both` with
   `FAKE_GH_EXIT=1`, capturing its real (non-zero) exit code; asserts
   overall failure, `github` recorded `failed`, `gitlab` recorded `done`.
9. **Retry block**: clears only the `glab` log; re-runs
   `release_run_publish_both` for the same tag with `FAKE_GH_EXIT=0`;
   counts `release create` occurrences in each fake log via `grep -c`;
   asserts `gh` was called twice total and `glab` zero additional times;
   asserts `github`'s state is now `done`.
10. **Dry-run block**: clears both fake logs; invokes the real
    `create_release.sh --dry-run v1.0.0` script as a subprocess (not
    sourced) with a fresh `LLMCTL_RELEASE_STATE_DIR` and the fake `PATH`
    still active; asserts both fake logs remain empty and the output
    contains `dry-run`.
11. Calls `test_finish`.

## Related scripts

* Exercises `scripts/release/create_release.sh` both by sourcing its
  internal `release_*` functions and by invoking it as a real subprocess
  for the `--dry-run` scenario — see `docs/scripts/create_release.md`
  (already documented) for that script's own contract.
* Sources `tests/helpers.sh` for `test_setup_env`/`test_finish`/assertion
  helpers.
* Discovered and run by `tests/run_tests.sh`.
* Sibling release-tooling test `tests/test_archive_completeness.sh`
  (documented in this same set) covers `scripts/release/build_archive.sh`,
  the archive-building step `create_release.sh`'s real (non-dry-run)
  path invokes via `make archive`.
* Related: `scripts/release/preflight_submodules.sh` (companion release
  script, documented separately by another pass covering
  `test_preflight_submodules.sh`).

## Last verified date

2026-09-17
