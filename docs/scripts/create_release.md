## Overview

`scripts/release/create_release.sh` creates a GitHub + GitLab release
atomically: it validates the given version as SemVer, generates a
conventional-commits changelog from real `git log` history, runs the
submodule preflight check (`scripts/release/preflight_submodules.sh`),
builds the release archive (`make archive`), and then publishes via
`gh release create` and `glab release create` with per-forge idempotent
retry. It exists to satisfy spec.md FR-013 ("Release MUST be created via
`gh release create` and `glab release create` with generated changelog"),
FR-050/Clarification 19 ("a GitHub/GitLab release is atomic across both
forges — if either fails, the release is NOT considered published;
re-running MUST be idempotent, retrying only the failed forge"), and
SC-009/Clarification 5 (SemVer with pre-release tag support, e.g.
`v1.0.0-rc.1`).

The script supports a `--dry-run` mode that performs every real check
(SemVer validation, submodule preflight, changelog generation, asset build)
but makes zero calls to `gh`/`glab` — this is the only mode this project's
own test suite ever exercises against the real `gh`/`glab` binaries (via a
PATH-injected fake). Creating a public release is a hard-to-reverse,
externally-visible action this script never takes unattended: a real
release requires the operator to run it without `--dry-run` explicitly,
themselves, after reviewing the dry-run output.

## Prerequisites

* `bash`, `git` — always required.
* `gh` (GitHub CLI) and `glab` (GitLab CLI) — only actually invoked in
  non-dry-run mode, inside `release_publish_forge`.
* `make` — non-dry-run Step 3 runs `make -C "${root}" archive`.
* `scripts/release/preflight_submodules.sh` — non-dry-run Step 1 sources and
  runs it (`bash "${root}/scripts/release/preflight_submodules.sh"`).
* `LLMCTL_RELEASE_STATE_DIR` (optional env var) — where per-version,
  per-forge idempotency state is recorded; defaults to
  `~/.local/state/llmctl/release/` (created via `mkdir -p` in
  `_release_state_dir`).
* Must be run from inside the git repository (or with the script's own
  directory inside one) — `_release_root` does
  `cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd` to resolve the repo
  root, and `release_generate_changelog`/`_release_main` both call
  `git -C "${root}" ...` against it.

## Usage examples

Real release (requires deliberate operator action, publishes for real):

```bash
bash scripts/release/create_release.sh v1.0.0
```

Dry-run — every check runs for real, but zero `gh`/`glab` calls are made:

```bash
bash scripts/release/create_release.sh --dry-run v1.0.0
```

The version accepts an optional leading `v`, and an optional pre-release
suffix (Clarification 5), so all of these are valid:

```bash
bash scripts/release/create_release.sh --dry-run 1.2.3
bash scripts/release/create_release.sh --dry-run v1.0.0-rc.1
```

Source it for unit-testing the individual functions without running
`_release_main` (the file only auto-runs `_release_main "$@"` when executed
directly, guarded by `[[ "${BASH_SOURCE[0]}" == "${0}" ]]`):

```bash
source scripts/release/create_release.sh
release_validate_semver "v1.0.0-rc.1" && echo "valid semver"
release_generate_changelog "$(pwd)" "v0.9.0"
```

Overriding the idempotency state directory (useful for isolated test runs):

```bash
LLMCTL_RELEASE_STATE_DIR=/tmp/my-release-state bash scripts/release/create_release.sh --dry-run v1.0.0
```

## Edge cases

* **Missing version argument**: `_release_main` prints
  `usage: create_release.sh [--dry-run] <version>` to stderr and returns 1
  if, after consuming `--dry-run`, no positional `version` was collected.
* **Invalid SemVer**: `release_validate_semver` is a pure regex match
  (`^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$`); on a non-match,
  `_release_main` prints a `FAIL:` line naming the exact rejected string and
  returns 1 before touching git, the preflight check, or any forge.
* **No prior tag exists**: `since_tag` is resolved via
  `git -C "${root}" describe --tags --abbrev=0 2>/dev/null`, and if that
  fails (no tags yet), it falls back to
  `git -C "${root}" rev-list --max-parents=0 HEAD` (the repo's very first
  commit), so the changelog always has a valid starting point even on a
  repository with zero release tags.
* **No commits of a given conventional-commit type since the last tag**:
  `release_generate_changelog` only emits a `### Features`/`### Fixes`/
  `### Documentation`/`### Other` section header when that category's
  captured variable is non-empty (`[[ -n "${feats}" ]]`, etc.) — an empty
  category is silently omitted from the changelog rather than printed as an
  empty heading.
* **Submodule preflight fails** (non-dry-run only): Step 1 runs
  `bash "${root}/scripts/release/preflight_submodules.sh"`; on non-zero exit
  the script prints `FAIL: submodule preflight failed - release aborted
  (no artifact produced with a missing/unreachable submodule)` and returns
  1 — the archive is never built and neither forge is contacted.
* **Idempotent retry of a partially-published release**:
  `release_run_publish_both` checks `release_state_get "${tag}" "${forge}"`
  for each of `github` and `gitlab` before publishing; a forge already
  recorded `"done"` from a prior run is skipped with a `SKIP <forge>:
  already published` line and no new `gh`/`glab` call is made, while any
  forge not yet `"done"` is (re)attempted. The overall function returns
  non-zero if either forge is not `"done"` by the end — the release is
  atomic (FR-050): not-published-on-both means not-published.
* **A `gh`/`glab` release-create call fails**: `release_publish_forge`
  records `release_state_set "${tag}" "${forge}" "failed"` (distinct from
  the never-run default of `"pending"`, which `release_state_get` returns
  when no state file exists yet) and returns 1; `release_run_publish_both`
  then prints a `FAIL <forge>: release ${tag} publish failed` line to
  stderr and sets its own `overall=1` return code, but still attempts the
  *other* forge in the same loop iteration set (per-forge failures don't
  short-circuit the loop).
* **Unknown forge name** passed to `release_publish_forge` (defensive,
  since the only real callers pass `github`/`gitlab`): the `case` statement's
  `*)` branch prints `unknown forge: ${forge}` to stderr and returns 1
  without touching any state file.
* **`--dry-run` skips every mutating step**: Step 1 prints
  `[dry-run] would run: bash .../preflight_submodules.sh` instead of running
  it; Step 3 prints `[dry-run] would run: make -C ... archive` instead of
  running it; Step 4 prints the two `gh`/`glab` commands it *would* run,
  deletes the temp notes file, and returns 0 immediately — `gh`/`glab` are
  never invoked and `release_run_publish_both` is never called in dry-run
  mode.
* **Temp changelog file cleanup**: `notes_file="$(mktemp)"` is written by
  `release_generate_changelog | tee "${notes_file}"` and is explicitly
  removed (`rm -f "${notes_file}"`) on both the dry-run early-return path and
  after `release_run_publish_both` returns in the real-publish path, so no
  stray temp file is left behind on either code path.
* **`set -euo pipefail`**: any unexpected command failure not explicitly
  handled by an `|| true`/`|| rc=$?` guard aborts the whole script
  immediately rather than continuing past a step that silently didn't work.

## Internal behaviour

1. **`_release_root`**: resolves the repository root as an absolute path
   (`cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd`) — used by
   `_release_main` to locate `preflight_submodules.sh`, the `Makefile`, and
   the git history to changelog against.
2. **`release_validate_semver <version>`**: a pure regex check; returns 0/1
   via bash's `[[ =~ ]]` exit status, no output.
3. **`release_generate_changelog <repo-dir> <since-tag>`**: runs four
   separate `git log "${since_tag}..HEAD" --format='%s'` passes (feats,
   fixes, docs, other-uncategorized-via-`grep -vE`), then prints a
   `## Changelog since <tag>` header followed by one `###` subsection per
   non-empty category, stripping each commit's conventional-commit prefix
   (`${line#feat*: }` etc.) before printing it as a bullet.
4. **`_release_state_dir` / `_release_state_file` / `release_state_get` /
   `release_state_set`**: a minimal one-file-per-`<version>.<forge>` state
   store under `LLMCTL_RELEASE_STATE_DIR` (default
   `~/.local/state/llmctl/release/`), storing the literal string `done` or
   `failed`; `release_state_get` returns `pending` when no file exists yet.
5. **`release_publish_forge <forge> <tag> <title> <notes_file>`**: maps
   `forge` to its real binary (`github`→`gh`, `gitlab`→`glab`), runs
   `"${bin}" release create "${tag}" --title "${title}" --notes-file
   "${notes_file}"`, and records the outcome via `release_state_set`.
6. **`release_run_publish_both <tag> <title> <notes_file>`**: loops over
   `github` then `gitlab`, skipping any already-`"done"` forge, calling
   `release_publish_forge` for the rest, and accumulating a non-zero
   `overall` if any forge fails — this is the atomicity/idempotency
   enforcement point (FR-050/Clarification 19).
7. **`_release_main "$@"`** (the standalone entrypoint, only invoked when the
   script is executed directly, not sourced):
   * Parses `--dry-run` and the positional `version` from `"$@"`.
   * Validates the version is present and passes `release_validate_semver`.
   * Resolves `root` via `_release_root` and `since_tag` via `git describe`
     (with the first-commit fallback).
   * **Step 1**: runs (or dry-run-prints) `preflight_submodules.sh`.
   * **Step 2**: generates the changelog into a `mktemp` file, printing it
     via `tee`.
   * **Step 3**: runs (or dry-run-prints) `make -C "${root}" archive`.
   * **Step 4**: in dry-run mode, prints the two commands that would run and
     returns 0; otherwise calls `release_run_publish_both` and propagates
     its return code, cleaning up the notes file on either path.
8. **Entrypoint guard**: `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
   _release_main "$@"; fi` — `_release_main` only auto-runs when the script
   is executed, not when it is `source`d for unit testing individual
   functions.

## Related scripts

* `scripts/release/preflight_submodules.sh` — invoked as Step 1, before any
  archive asset is built; see its own doc for the reachability check it
  performs.
* `scripts/release/build_archive.sh` — invoked transitively via `make
  archive` in Step 3.
* `tests/test_create_release.sh` — the RED/GREEN proof of this script's
  behaviour, sourcing it and calling `release_validate_semver`/
  `release_generate_changelog`/etc. directly, using a PATH-injected fake
  `gh`/`glab` so the real forges are never touched during testing.
* `docs/release-process.md` — documents the full release procedure this
  script implements.
* `specs/001-llmctl-completion/spec.md` — FR-013, FR-050, SC-009,
  Clarification 5, Clarification 19 — the requirements this script
  satisfies.

## Last verified date

2026-09-17
