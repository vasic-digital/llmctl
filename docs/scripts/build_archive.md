# `build_archive.sh`

## Overview

`scripts/release/build_archive.sh` produces `<output-basename>.tar.gz` and
`<output-basename>.zip` archives containing the **tracked working tree** of a
source directory — tracked files of the main repo and of every submodule
(recursively, any nesting depth), plus a **sanitised** `.git` (see "Shipped `.git`" below) and each
submodule's `.git` pointer. **Untracked and ignored files are never
archived** (spec 009 FR-087 / D-30), so a planted `.env`, `cert/**`, `*.key`
or `*.pem` cannot enter a release.

It exists because `git archive` is fundamentally submodule-blind: the
script's own header notes it was verified empirically that `git archive
HEAD | tar -tf - | grep submodules/` emits each submodule as a single,
empty directory entry with none of its actual file content. A
filesystem-level `tar`/`zip` of an already-checked-out tree has no such
gap — it archives whatever is genuinely present on disk, which naturally
includes every submodule's content because "nested submodule" is a
git-level concept with no special filesystem representation. This is the
mechanism behind `make archive` and the release pipeline's asset-build
step (spec.md FR-014 / Clarification 4).

## Prerequisites

- `bash`, `tar`, `zip` on `PATH`.
- `<source-root>` must be a real, already-checked-out directory — this
  script does **not** run `git submodule update`; submodules must already
  be populated (run `git submodule update --init --recursive` first if not).
- No environment variables are read.

## Usage examples

Standalone invocation (the script requires exactly 2 positional arguments
when executed directly):

```bash
bash scripts/release/build_archive.sh /path/to/llmctl ../llmctl
# writes ../llmctl.tar.gz and ../llmctl.zip
```

Via the project `Makefile` (the real, documented invocation):

```bash
make archive
# runs: bash scripts/release/build_archive.sh "$(ROOT)" ../llmctl
```

Sourcing for unit testing, calling the `build_archive` function directly:

```bash
source scripts/release/build_archive.sh
build_archive "$(pwd)" "/tmp/mytest/llmctl-out"
```

## Edge cases

- **Wrong-argument-count guard**: when run standalone (not sourced) with
  anything other than exactly 2 arguments, it prints a usage message to
  stderr and exits 1 (`[[ "$#" -ne 2 ]]`).
- **Relative output path resolved against the caller's original cwd**: the
  script header documents a real bug found in this project — a relative
  `<output-basename>` (e.g. `../llmctl`, as `make archive` passes) must be
  resolved to an absolute path *before* the function `cd`s into
  `${parent}` (the source root's parent directory, needed so `tar`/`zip`
  store repository-relative paths rather than caller-relative ones).
  Without this, `../llmctl.zip` would silently land one directory level
  too high. The code guards this explicitly: `case "${out}" in /*) ;; *)
  out="$(pwd)/${out}" ;; esac` runs before any `cd`.
- **Build-output exclusion**: both the `tar` and `zip` invocations exclude
  `*/build/*` so generated build artifacts never end up archived.
- **`.git` is included, but never copied**: the archive is a fully self-contained git
  repository when extracted, yet the shipped `.git` is rebuilt from the release commit (below) —
  copying the source `.git` would ship stashes, unpushed branches, reflogs, hooks and remote URLs.
- **`set -euo pipefail`**: any failing `tar` or `zip` invocation aborts the
  script non-zero rather than silently producing a partial archive.
- **Source root normalization**: `src="$(cd "${src}" && pwd)"` resolves the
  source root to a canonical absolute path first, so `dirname`/`basename`
  used to split it into `${parent}`/`${base}` behave correctly regardless of
  how `<source-root>` was originally spelled (relative, trailing slash,
  etc.) — if the `cd` fails (path doesn't exist), the script aborts via
  `set -e`.

## Shipped `.git` (C-02)

For the main repo and every initialised submodule the archive's git directory is generated, not
copied: `git bundle create HEAD` (only the objects reachable from the release commit), unpacked into
a fresh bare-then-non-bare git dir with **one** branch ref (or a detached HEAD), no remotes, no
hooks, no reflogs, no stash, no credential helper or URL rewrite, a minimal config (only
`core.worktree` is kept for submodule git dirs) and a rebuilt index (`git read-tree HEAD`), so the
extracted tree reports a clean `git status` and a working `git log`. Consequently none of these can
leak into a release: a `git stash -u` that stored an untracked `.env` as a blob, a local-only
branch or unpushed WIP commit, a reflog, a hook, an `https://user:token@` remote. The tar is built
with `--recursion -C <stage> <base>/.git` appended after the file list; the zip gets the same tree
with a second `zip -r` into the same archive. A source `.git` that is not a directory (a linked
worktree / submodule checkout) is refused.

## Secrets protection (spec 009 FR-087 / D-30, C-03, C-21)

- File list = `git ls-files -z --recurse-submodules` + `<submodule>/.git` pointers
  (`git submodule foreach --recursive`). A non-git source falls back to a filesystem walk with the
  deny-list applied at collection time.
- **Deny-list** (`_ba_is_secret_path`, anchored `[[ =~ ]]` regexes on the lower-cased path, never a
  case-glob whose `*` would match across `/`): `.env`, `.env.*` (not `.env.example`), `*.key`, `*.pem`,
  `*.p12`, `*.pfx`, `*.jks`, `*.keystore`, `id_rsa*`, `id_dsa*`, `id_ecdsa*`, `id_ed25519*`, `.netrc`,
  `.pgpass`, `credentials*.json`, any `cert/` directory — case-insensitive. Paths inside `.git/` are not
  judged here (the shipped `.git` is generated; the scanner judges its content).
- **Exemptions are exact paths only**, read from two manifests: `scripts/release/public_allowlist.txt`
  (named vendored files: the llama.cpp Keynote deck, the Containers submodule's `tests/configs/.env.*`
  templates) and `tests/fixtures/PUBLIC_FIXTURES.txt` (public test fixtures; currently none). A manifest
  entry with a glob character, `..` or a leading `/` is refused, so an exemption can never widen into a
  subtree (the old `tests/fixtures/*` and `submodules/*/docs/*` case-globs exempted
  `submodules/a/b/docs/x.pem` and `tests/fixtures/real/.env`). `BA_PUBLIC_ALLOWLIST` (colon-separated)
  replaces the manifests in tests.
- **Independent post-scan** (`scripts/release/scan_archive.py`, a different implementation in a different
  language that shares no code with the bash filter): reads both archives with `tarfile`/`zipfile`, applies
  its own path rules, scans working-tree file content (≤ 2 MiB) for a real PEM **private-key block**
  (BEGIN line plus base64 body lines — a source line merely quoting the header is not a block), and
  checks the shipped `.git` for a stash ref, reflogs, hooks, a `[remote]`/`[credential]`/`[url]`
  config section or a URL with embedded credentials (also `.gitmodules`). Any finding removes both
  archives and returns non-zero with the offending path on stderr.
- Tests: `tests/test_release_no_secrets.sh` (RED-scenario reuse, git-mode fixture, tracked-secret
  failure, pre-fix mutation, a table of every deny class plus the old exemption escapes, the scanner on
  one archive per class, and the stash/branch/remote fixture proving none of it ships),
  `tests/test_archive_completeness.sh` (self-contained tree guarantee). Dropping `*.pem` from either
  implementation fails its own assertions.
- Extra dependencies: `git`, GNU `tar`, `zip`, `python3`.

## Internal behaviour

1. **Entry point selection**: the script checks `[[ "${BASH_SOURCE[0]}" ==
   "${0}" ]]` — when executed directly it validates argument count and
   calls `build_archive "$1" "$2"`; when sourced (as the test suite does),
   nothing runs automatically and the caller invokes `build_archive`
   itself.
2. **`build_archive <source-root> <output-basename>`**:
   - Canonicalizes `src` to an absolute path via `cd "${src}" && pwd`.
   - Splits it into `parent` (`dirname`) and `base` (`basename`) — these are
     what `tar -C`/`zip` (via a subshell `cd`) use so the archived paths are
     repo-relative (`llmctl/...`), not absolute or caller-relative.
   - Normalizes `out` to an absolute path if it was given as relative,
     *before* any directory change, per the edge case above.
   - Lists the files (`_ba_list_files`), generates the sanitised git dirs into a temp stage
     (`_ba_stage_git`), then runs one `tar` invocation (`--no-recursion --null -T list` for the
     working-tree files, `--recursion -C <stage> <base>/.git` for the git dirs) and the zip step in
     a subshell (`zip` has no "change base directory" flag), followed by a second `zip -r` of the
     staged `.git` into the same zip.
   - Runs `scan_archive.py` on both outputs and removes them on any finding.

## Related scripts

- **`Makefile`** — the `archive` target is the real, documented entry point:
  `bash scripts/release/build_archive.sh "$(ROOT)" ../llmctl`.
- **`scripts/release/create_release.sh`** — Step 3 of its release pipeline
  runs `make -C "${root}" archive` (or prints the dry-run equivalent), which
  transitively invokes this script.
- **`tests/test_archive_completeness.sh`** — the RED/GREEN proof of
  correctness against a small real-submodule fixture; it sources this
  script (`source scripts/release/build_archive.sh`) to call `build_archive`
  directly.
- **`docs/release-process.md`** — documents this script as part of the full
  release procedure.

## Last verified date

2026-10-07

## Round-3 hardening (C2-01, C2-05, C2-15, C2-17)

- **Submodules ship active (C2-01).** The shipped `.git/config` carries `submodule.<name>.active=true` and
  `submodule.<name>.url` (from the tracked `.gitmodules`; a URL with userinfo is rejected by the scanner), so
  `git submodule status` of an extracted release has no `-` prefix and `git ls-files --recurse-submodules` equals
  the source's. Building a release FROM a release therefore no longer drops submodule content. In addition the
  build FAILS (`gitlink '<path>' yields zero files`) when any gitlink contributes no file to the archive, never
  exiting 0 with an empty submodule. The match is ANCHORED (C3-06): a list entry counts only when it starts with
  `<base>/<gitlink>/`, so a tracked decoy such as `docs/<base>/<gitlink>/readme` no longer hides an
  uninitialised submodule, and the `.git` pointer file is not counted as content.
- **History is judged too (C2-05, C3-03, C3-04).** The shipped `.git` is a bundle of HEAD, so every path ever
  touched on HEAD's history (`git log -m --no-renames --name-only -z HEAD`, main repo and every submodule, merge
  commits included, both sides of a rename) is run through the same deny-list: every historical PATH is judged,
  not every blob once (`rev-list --objects` lists a blob once under the first path it meets, so a secret-named
  path holding content identical to another path's was never judged, and it cuts a path at its first newline).
  A historical path containing a newline is refused. An allow entry that names neither a tracked file nor a
  historical path is reported (`unused allow entry: ...`, report only). A committed-then-deleted `*.key` fails
  the build, naming the historical path. The exact allow
  manifests apply (`scripts/release/public_allowlist.txt`). **Bound:** this is a PATH check - a secret committed
  under a benign name and deleted again is not detected.
- **Dirty trees are refused (C2-15).** `build_archive [--allow-dirty] <src> <out>` (env `BA_ALLOW_DIRTY=1`) exits 1
  when `git status --porcelain --ignore-submodules=none` is non-empty (tracked edits and untracked files alike): the
  archive holds HEAD only. With the override it proceeds and the shipped `.git/llmctl-release-manifest.json`
  records `"dirty": true`, the entry count and `"allow_dirty": true` (kept inside `.git` so the extracted tree stays
  `git status`-clean); a clean build records `"dirty": false`.
- **bash 3.2 (C2-17).** Possibly-empty arrays are expanded as `${arr[@]+"${arr[@]}"}` (a bare `"${arr[@]}"` is an
  "unbound variable" under `set -u` on bash < 4.4); `tests/test_archive_completeness.sh` greps for a bare expansion
  and proves its instrument with a planted needle.
