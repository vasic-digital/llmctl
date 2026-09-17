## Overview

`tests/test_archive_completeness.sh` proves that `scripts/release/build_archive.sh`
produces a `.tar.gz`/`.zip` pair whose **extracted** tree is a fully
self-contained, genuinely buildable git repository — including real
submodule content, not the empty placeholder directories `git archive`
leaves behind for submodules. This closes the exact gap Phase 8 task T047
(spec.md FR-014, Clarification 4) targets: a release archive that a
developer downloads and unpacks must contain working submodules, not
directories that look populated in a listing but are actually empty because
`git archive` never recurses into submodules on its own.

Rather than exercising this project's own ~2 GB, multi-submodule
repository, the test builds a small, real, throwaway git fixture (one
superproject + one real submodule added via a local `file://` URL) — the
property under test (does a submodule's relative `.git` gitdir pointer
survive being relocated to a brand-new absolute path) is provable with one
small real submodule exactly as well as with the project's 3 real ones.
This mirrors the project's established fast/deterministic fixture pattern
(the sibling precedent is `tests/test_setup_e2e.sh`'s symlinked
fresh-clone fixture, documented separately).

## Prerequisites

* `tests/helpers.sh` (sourced for `test_setup_env`/`test_finish`/assertion
  helpers) and the isolated `TEST_TMP` directory it provides.
* `scripts/release/build_archive.sh`, sourced directly (`source
  "${LLMCTL_ROOT}/scripts/release/build_archive.sh"`) so the test can call
  the real `build_archive` function in-process rather than only shelling
  out to it.
* Real commands: `git` (with `-c protocol.file.allow=always` to permit a
  local `file://` submodule URL), `tar`, `zip`, standard coreutils.
* No fixture files are read from `tests/fixtures/` — this test builds its
  own throwaway git repositories entirely under `${TEST_TMP}` (via
  `test_setup_env`).
* No project-specific environment variables (`LLMCTL_FAKE_HW`,
  `LLMCTL_DRY_RUN`, etc.) are used; this test operates entirely on git and
  the filesystem, independent of llmctl's own state directories.

## Usage examples

* Standalone: `bash tests/test_archive_completeness.sh`
* Via the harness (the normal path): `bash tests/run_tests.sh` (discovered
  automatically by its `test_*.sh` glob).
* Via `make test` / `make validate`.

## Edge cases

* **Empty-looking submodule directories from `git archive` (the historical
  bug this test guards against)**: asserts the extracted tree contains the
  submodule's *real* file content (`sub/sub_file.txt`) and arbitrarily
  nested submodule content (`sub/nested/deep/deep_file.txt`) — not merely
  an empty `sub/` directory.
* **Build-output directories must be excluded from the archive**: creates
  `sub/build/binary.bin` inside the submodule tree and asserts it is
  **absent** from the extracted archive, matching the project's existing
  `*/build/*` exclusion convention (both `tar --exclude` and `zip -x` are
  exercised transitively through `build_archive`).
* **Relocated submodule must be a genuinely functional git repository, not
  just copied files**: after extracting to a brand-new location that never
  existed before the test ran, it runs `git status --short sub` inside the
  extracted superproject (asserting exit 0 and empty/clean output) and
  `git log --oneline -1` inside the extracted submodule itself (asserting
  exit 0 and that the real commit message `"submodule commit"` is present)
  — proving the submodule's relative `.git` gitdir pointer
  (`../../.git/modules/sub`) survived being moved to a path with no prior
  history.
* **Relative output-basename path resolves against the caller's cwd, not
  `build_archive`'s internal `cd`** (a real bug found and fixed during this
  session): calls `build_archive "${SUPER}" "../rel_output"` from inside a
  freshly created `workdir` subshell and asserts both `../rel_output.tar.gz`
  and `../rel_output.zip` land one directory *above* `workdir` — i.e. where
  the caller's relative path actually points — rather than silently
  re-resolving against `build_archive`'s own internal `cd "${parent}"`
  (the exact shape the real Makefile uses: `bash
  scripts/release/build_archive.sh "$(ROOT)" ../llmctl`).

## Internal behaviour

1. Sources `tests/helpers.sh`, calls `test_setup_env` for an isolated
   `${TEST_TMP}`.
2. Sources `scripts/release/build_archive.sh` directly so `build_archive`
   is callable as an in-process bash function.
3. Builds a real git fixture under `${TEST_TMP}/archive_fixture`:
   * `sub_upstream/` — a standalone git repo with a nested file tree
     (`sub_file.txt`, `nested/deep/deep_file.txt`), committed as "submodule
     commit".
   * `super/` — a second git repo that adds `sub_upstream` as a real git
     submodule via `git -c protocol.file.allow=always submodule add
     file://${SUBUPSTREAM} sub`, adds its own `super_file.txt`, and
     deliberately creates `sub/build/binary.bin` (simulating a
     build-output artifact that must never be archived), then commits.
4. Calls the real `build_archive "${SUPER}" "${OUT_BASENAME}"` function and
   asserts both `.tar.gz` and `.zip` outputs exist.
5. Extracts the `.tar.gz` to a brand-new `${TEST_TMP}/extracted` directory
   and asserts: the superproject's own `.git` directory is present; the
   submodule's real (including nested) file content is present; the
   excluded `sub/build/binary.bin` is absent.
6. Runs real `git status`/`git log` commands **inside the extracted tree**
   (at its new, never-before-existing path) to prove the relocated
   submodule is a genuinely working git repository, not merely copied
   files.
7. Repeats the archive-build step in a second scenario using a **relative**
   output-basename path invoked from a fresh subshell/cwd, asserting the
   relative path resolves against the *caller's* cwd rather than
   `build_archive`'s internal directory change.
8. Calls `test_finish`, which exits non-zero if any assertion failed.

## Related scripts

* Exercises `scripts/release/build_archive.sh`'s `build_archive` function
  directly (sourced, not just shelled out to) — see
  `docs/scripts/build_archive.md` (already documented) for that script's
  own contract.
* Sources `tests/helpers.sh` for `test_setup_env`/`test_teardown_env`/
  `test_finish` and all `assert_*` helpers.
* Discovered and run by `tests/run_tests.sh` via its `test_*.sh` glob.
* Sibling release-tooling test: `tests/test_create_release.sh` (covers
  `scripts/release/create_release.sh`, the script that actually invokes
  `make archive` — and therefore `build_archive.sh` — as part of a real
  release).

## Last verified date

2026-09-17
