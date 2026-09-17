## Overview

`scripts/release/preflight_submodules.sh` verifies that every pinned
submodule ref — both this repository's own submodules and
`constitution`'s nested submodule set, recursively — is genuinely
fetchable from its configured remote, *before* any release artifact is
built. It exists to implement spec.md FR-014/FR-052, Clarification 21:
"What happens when a pinned submodule's ref is unreachable at
release-packaging time (upstream private/deleted/rate-limited)? →
Release packaging hard-fails, naming the unreachable submodule and its
expected ref; no artifact is produced with a missing or empty submodule
directory." This script is that preflight check, and it is invoked as
Step 1 of `scripts/release/create_release.sh`'s release pipeline.

Rather than assuming any git host supports fetch-by-arbitrary-SHA (many,
including GitHub by default, restrict that), the script fetches everything
a submodule's remote advertises into a fresh throwaway scratch git
repository and checks the expected commit's ancestry locally — a mechanism
that works against any git host.

## Prerequisites

* `bash`, `git`, `timeout` — `preflight_check_ref` wraps its fetch in
  `timeout "${fetch_timeout}" git ... fetch ...` so one bad submodule can
  never wedge the whole release preflight.
* Network access to every submodule's configured remote (real `git fetch`
  calls are made against each one).
* `PREFLIGHT_FETCH_TIMEOUT` (optional env var, seconds) — overrides the
  default 30-second per-submodule fetch timeout used in
  `preflight_check_ref`.
* When run standalone, must be executed from a location where
  `$(dirname "${BASH_SOURCE[0]}")/../..` resolves to this repository's root
  (i.e. run from its real location inside `scripts/release/`) — `.gitmodules`
  is read via `git -C "${repo_dir}" config -f "${repo_dir}/.gitmodules"
  --get submodule.<path>.url`, and submodule status via `git -C
  "${repo_dir}" submodule status`.
* No llmctl `lib/` sourcing — standalone by design, so it runs in a
  release-packaging context that does not source this project's other bash
  libraries.

## Usage examples

Standalone run — walks every submodule this repo and `constitution/`
declare, recursively, hard-failing on the first unreachable one:

```bash
bash scripts/release/preflight_submodules.sh
```

Sourcing it for unit-testing `preflight_check_ref`/`preflight_run` directly,
against a fully-local fixture repo (no real network dependency needed for
the unit-tested functions themselves):

```bash
source scripts/release/preflight_submodules.sh

scratch="$(mktemp -d)"
git init --quiet "${scratch}"
rc=0
preflight_check_ref "${scratch}" "file:///path/to/upstream.git" "<expected-sha>" || rc=$?
# rc: 0 reachable, 1 confirmed unreachable, 2 could not verify
```

Calling the higher-level `preflight_run` wrapper (handles its own scratch
directory creation and cleanup via `trap ... RETURN`):

```bash
source scripts/release/preflight_submodules.sh
preflight_run "my-submodule" "https://example.com/upstream.git" "<expected-sha>"
```

Overriding the per-submodule fetch timeout:

```bash
PREFLIGHT_FETCH_TIMEOUT=10 bash scripts/release/preflight_submodules.sh
```

Invoked automatically as Step 1 of a release (the normal path — see
`create_release.md`):

```bash
bash scripts/release/create_release.sh v1.0.0
```

## Edge cases

* **Three-state return, not a binary pass/fail** (Constitution §11.4.201: a
  guard must assert the *real* condition — a network/auth/DNS failure that
  prevents verification and a proven-absent ref are different findings
  requiring different operator responses; conflating them is the
  false-positive-refusal class §11.4.201 forbids):
  * `0` = **reachable** — the fetch succeeded and `expected_sha` is a real
    ancestor of a fetched ref.
  * `1` = **confirmed unreachable** — the fetch succeeded but
    `expected_sha` is genuinely absent from everything fetched.
  * `2` = **could not verify** — the fetch itself failed (network/auth/host
    problem); this is *not* evidence the ref is unreachable, only that this
    check could not run to completion.
* **Fetch hangs with no response** (no connection-refused/DNS-error, just
  silence): bounded by `timeout "${fetch_timeout}"` in `preflight_check_ref`,
  which returns `2` (could-not-verify) rather than blocking indefinitely or
  being mistaken for a confirmed-unreachable ref.
* **Expected SHA not directly fetchable but reachable via a branch/tag**:
  `preflight_check_ref` doesn't just `cat-file -e` the SHA — after confirming
  the commit object exists locally, it iterates every fetched ref
  (`refs/remotes/preflight/*` plus `refs/tags`) via
  `git merge-base --is-ancestor "${expected_sha}" "${ref}"` and returns `0`
  on the *first* ref that proves ancestry, so a pinned commit that is an
  ancestor of a later commit on a branch (not the tip itself) still verifies
  as reachable.
* **Commit object doesn't exist at all after a successful fetch**:
  `git cat-file -e "${expected_sha}^{commit}" 2>/dev/null || return 1` —
  short-circuits straight to the confirmed-unreachable (`1`) return without
  even attempting the ancestry-scan loop.
* **`preflight_run`'s scratch directory is always cleaned up**: `trap 'rm -rf
  "${scratch_dir}"' RETURN` runs regardless of which of the three states
  `preflight_check_ref` returns, including the could-not-verify (`2`) case.
* **Uninitialized/out-of-sync submodule entries**: `_preflight_walk` strips a
  leading `+`/`-` marker from the SHA field
  (`sed 's/^[+-]//'`) that `git submodule status` prepends for
  out-of-sync/uninitialized submodules, so the check still runs against the
  pinned SHA rather than skipping or misparsing those rows.
* **A submodule path with no resolvable `.gitmodules` URL or empty SHA**:
  `_preflight_walk` skips that line entirely
  (`[[ -n "${url}" && -n "${sha}" ]] || continue`) rather than calling
  `preflight_run` with an empty argument.
* **`constitution/` directory absent**: `_preflight_main` only walks it if
  `[[ -d "${root}/constitution" ]]` — a project without that submodule
  checked out simply skips the second walk, no error.
* **Any confirmed-FAIL or could-not-verify (UNKNOWN) submodule**:
  `_preflight_main` treats both classes as blocking — `(( fails > 0 ||
  unknowns > 0 ))` triggers a `PREFLIGHT FAILED: <n> submodule ref(s)
  confirmed unreachable, <n> could not be verified` message and a non-zero
  return; the header comment explains why: "a ref that cannot be verified is
  treated the same as an unreachable one (no artifact ships on an unproven
  submodule)".
* **Sourced vs. executed**: `_preflight_main` only auto-runs when
  `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` — sourcing the file for testing
  `preflight_check_ref`/`preflight_run` does not trigger the real-submodule
  walk.
* **`set -euo pipefail`**: an unhandled command failure anywhere outside the
  explicitly-guarded `|| true`/`|| rc=$?` spots aborts the script rather than
  silently continuing.

## Internal behaviour

1. **`preflight_check_ref <scratch-git-dir> <remote-url> <expected-sha>`**:
   fetches every branch and tag from `<remote-url>` into the caller-provided
   (already `git init`'d) `<scratch-git-dir>` via
   `git fetch --quiet --tags "${url}" '+refs/heads/*:refs/remotes/preflight/*'`,
   bounded by `timeout "${fetch_timeout}"` (default 30s, overridable via
   `PREFLIGHT_FETCH_TIMEOUT`). A fetch failure returns `2` immediately. On a
   successful fetch, it checks the commit object exists
   (`git cat-file -e`), returning `1` if not; otherwise it walks every
   fetched remote-tracking ref and tag looking for one that has
   `expected_sha` as an ancestor (`git merge-base --is-ancestor`), returning
   `0` on the first match or `1` if none match.
2. **`preflight_run <submodule-name> <remote-url> <expected-sha>`**: creates
   a fresh `mktemp -d` scratch directory, `trap`s its cleanup on RETURN,
   `git init --quiet`s it, calls `preflight_check_ref` against it, and maps
   the three-state return code to an evidence-bearing printed message
   (`PASS submodule ...`/`UNKNOWN submodule ...`/`FAIL submodule ...`),
   propagating the same 0/1/2 return code to its own caller.
3. **`_preflight_main`** (the standalone entrypoint):
   * Resolves `root` as this repository's root.
   * Defines an inner helper `_preflight_walk <repo_dir>` that parses each
     line of `git -C "${repo_dir}" submodule status` (format
     `[+-]<sha> <path> (<describe>)`), extracts `sha`/`path`, looks up the
     submodule's remote `url` from `.gitmodules`, and calls `preflight_run`
     for each valid entry, tallying `fails`/`unknowns` by return code.
   * Runs `_preflight_walk "${root}"`, then conditionally
     `_preflight_walk "${root}/constitution"` if that directory exists.
   * If either tally is non-zero, prints a `PREFLIGHT FAILED: ...` summary
     to stderr and returns 1; otherwise prints `PREFLIGHT PASSED: every
     submodule ref is reachable` and returns 0.
4. **Entrypoint guard**: `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
   _preflight_main; fi` — the standalone real-submodule walk only runs when
   the file is executed directly.

## Related scripts

* `scripts/release/create_release.sh` — calls this script as Step 1, before
  building any release asset; a preflight failure aborts the release before
  the archive is built.
* `tests/test_preflight_submodules.sh` — the RED/GREEN proof of correctness,
  sourcing this script and exercising `preflight_check_ref`/`preflight_run`
  against real local fixture git repositories (a genuinely-reachable pinned
  commit and a genuinely-unreachable one) — no real network dependency in
  the test itself.
* `docs/release-process.md` — documents this script as the first step of
  the full release procedure.
* `specs/001-llmctl-completion/spec.md` — FR-014, FR-052, Clarification 21 —
  the requirement this script satisfies.

## Last verified date

2026-09-17
