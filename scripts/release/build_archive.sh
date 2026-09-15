#!/usr/bin/env bash
# build_archive.sh - produces <output>.tar.gz and <output>.zip containing
# the FULL working tree of a source directory, including .git and every
# submodule's real content recursively (arbitrary nesting depth), excluding
# build-output directories.
#
# Purpose:
#   spec.md FR-014/Clarification 4: a release archive must be a fully
#   self-contained, buildable tree - `git archive` cannot satisfy this,
#   because it is fundamentally submodule-blind: it emits an EMPTY
#   directory for every submodule (verified empirically this session -
#   `git archive HEAD | tar -tf - | grep submodules/` shows each submodule
#   as a single directory entry with zero of its actual file content). A
#   plain filesystem-level tar/zip of the already-checked-out tree has no
#   such gap: it archives whatever is genuinely present on disk, which
#   naturally includes every submodule's real content at any nesting depth,
#   because "nested submodule" is a git-level concept with no special
#   filesystem representation - it is just more files in more directories.
#
# Usage:
#   source scripts/release/build_archive.sh   # for unit-testing build_archive
#   build_archive <source-root> <output-basename>
#     writes <output-basename>.tar.gz and <output-basename>.zip
#
# Inputs:
#   <source-root> - path to the working tree to archive (must be a real,
#   already-checked-out directory - this script does not run
#   `git submodule update`; run that first if submodules aren't populated).
#   <output-basename> - path (without extension) for the two archives.
#
# Outputs:
#   Two real archive files. Exits non-zero if either tool fails.
#
# Side-effects: reads <source-root> recursively; writes exactly the two
# named archive files. Never modifies <source-root>.
#
# Dependencies: bash, tar, zip.
#
# Cross-references:
#   Makefile                              - `make archive` calls this script
#   tests/test_archive_completeness.sh    - RED/GREEN proof against a small
#                                            real-submodule fixture
#   docs/release-process.md               - documents this as part of the
#                                            release procedure
#   specs/001-llmctl-completion/spec.md   - FR-014, Clarification 4
set -euo pipefail

# build_archive <source-root> <output-basename>
build_archive() {
  local src="$1" out="$2"
  src="$(cd "${src}" && pwd)"
  local parent base
  parent="$(dirname "${src}")"
  base="$(basename "${src}")"

  # <output-basename> is resolved to an ABSOLUTE path relative to the
  # CALLER's original working directory, BEFORE any `cd` below - the real
  # Makefile invocation passes a relative path ("../llmctl"), and a `cd
  # "${parent}"` (needed so tar/zip store repo-relative paths, not
  # caller-relative ones) would otherwise silently re-resolve that relative
  # path against the WRONG base directory (a real bug found this session:
  # `make archive` reported success while writing llmctl.zip one directory
  # level too high, and the .tar.gz's own path-resolution was only correct
  # by coincidence because tar's -C flag doesn't re-interpret ${out}).
  case "${out}" in
    /*) : ;;
    *) out="$(pwd)/${out}" ;;
  esac

  tar --exclude='*/build/*' -czf "${out}.tar.gz" -C "${parent}" "${base}"

  # zip: -x excludes patterns; unlike the old git-archive-based target this
  # NO LONGER excludes .git - the whole point of this fix is including it.
  ( cd "${parent}" && zip -qr "${out}.zip" "${base}" -x "*/build/*" )
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ "$#" -ne 2 ]]; then
    echo "usage: build_archive.sh <source-root> <output-basename>" >&2
    exit 1
  fi
  build_archive "$1" "$2"
fi
