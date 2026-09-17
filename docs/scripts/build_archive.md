# `build_archive.sh`

## Overview

`scripts/release/build_archive.sh` produces `<output-basename>.tar.gz` and
`<output-basename>.zip` archives containing the **full working tree** of a
source directory — including the real `.git` directory and every
submodule's real file content, recursively, at any nesting depth.

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
- **`.git` is intentionally included**: the header calls out that, unlike
  an older git-archive-based target this replaced, the `zip` command's `-x`
  exclusion list does **not** exclude `.git` — the entire point of this
  script is that the archive is a fully self-contained, buildable git
  repository when extracted.
- **`set -euo pipefail`**: any failing `tar` or `zip` invocation aborts the
  script non-zero rather than silently producing a partial archive.
- **Source root normalization**: `src="$(cd "${src}" && pwd)"` resolves the
  source root to a canonical absolute path first, so `dirname`/`basename`
  used to split it into `${parent}`/`${base}` behave correctly regardless of
  how `<source-root>` was originally spelled (relative, trailing slash,
  etc.) — if the `cd` fails (path doesn't exist), the script aborts via
  `set -e`.

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
   - Runs `tar --exclude='*/build/*' -czf "${out}.tar.gz" -C "${parent}"
     "${base}"` — a single tar invocation using `-C` so no `cd` is needed
     for the tar step.
   - Runs the zip step inside a subshell (`( cd "${parent}" && zip -qr
     "${out}.zip" "${base}" -x "*/build/*" )`), because `zip` (unlike
     `tar -C`) has no built-in "change base directory" flag; the subshell
     ensures the `cd` doesn't affect the rest of the script/caller.

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

2026-09-17
