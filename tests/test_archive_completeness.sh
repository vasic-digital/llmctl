#!/usr/bin/env bash
# test_archive_completeness.sh - proves scripts/release/build_archive.sh
# produces a tar.gz/zip whose EXTRACTED tree is a fully self-contained,
# buildable git repo with real submodule content (not the empty
# placeholder directories `git archive` produces for submodules) - Phase 8
# T047, spec.md FR-014, Clarification 4.
#
# Uses a SMALL, real git fixture (one real submodule, added via a local
# file:// URL) rather than this actual ~2GB multi-submodule repo, matching
# this project's established fast/deterministic test-suite pattern
# (test_setup_e2e.sh's symlinked fresh-clone fixture is the sibling
# precedent). The property under test - does a real submodule's relative
# `.git` gitdir pointer survive being moved to a brand-new absolute path -
# is provable with one small real submodule exactly as well as with 23.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

source "${LLMCTL_ROOT}/scripts/release/build_archive.sh"

WORK="${TEST_TMP}/archive_fixture"
mkdir -p "${WORK}"

# --- Build a small real superproject + one real submodule -------------------
SUBUPSTREAM="${WORK}/sub_upstream"
git init -q "${SUBUPSTREAM}"
(
  cd "${SUBUPSTREAM}"
  git config user.email test@example.com; git config user.name test
  mkdir -p nested/deep
  echo "real submodule content" > sub_file.txt
  echo "deeply nested content" > nested/deep/deep_file.txt
  git add -A; git commit -qm "submodule commit"
)

SUPER="${WORK}/super"
git init -q "${SUPER}"
(
  cd "${SUPER}"
  git config user.email test@example.com; git config user.name test
  git -c protocol.file.allow=always submodule add -q "file://${SUBUPSTREAM}" sub >/dev/null
  echo "superproject content" > super_file.txt
  # A build-output directory that MUST be excluded from the archive (matches
  # the project's existing exclusion convention for */build/* directories).
  mkdir -p sub/build
  echo "compiled binary placeholder - must NOT be archived" > sub/build/binary.bin
  git add super_file.txt
  git commit -qm "superproject commit"
)

# --- Real archive build via the actual production function ------------------
OUT_BASENAME="${TEST_TMP}/output/llmctl_test"
mkdir -p "$(dirname "${OUT_BASENAME}")"
build_archive "${SUPER}" "${OUT_BASENAME}"

assert_file_exists "${OUT_BASENAME}.tar.gz" "build_archive produces a real .tar.gz"
assert_file_exists "${OUT_BASENAME}.zip" "build_archive produces a real .zip"

# --- Extract to a BRAND-NEW location and verify it is genuinely buildable ---
EXTRACT="${TEST_TMP}/extracted"
mkdir -p "${EXTRACT}"
tar -xzf "${OUT_BASENAME}.tar.gz" -C "${EXTRACT}"
EXTRACTED_ROOT="${EXTRACT}/$(basename "${SUPER}")"

rc=0
[[ -d "${EXTRACTED_ROOT}/.git" ]] || rc=1
assert_eq 0 "${rc}" "extracted tree includes the superproject's own .git directory"
assert_file_exists "${EXTRACTED_ROOT}/sub/sub_file.txt" "extracted tree includes the submodule's REAL file content (not an empty placeholder dir - the exact git-archive gap this task fixes)"
assert_file_exists "${EXTRACTED_ROOT}/sub/nested/deep/deep_file.txt" "extracted tree includes ARBITRARILY-NESTED submodule content"
assert_file_absent "${EXTRACTED_ROOT}/sub/build/binary.bin" "build-output directories are excluded from the archive (matches the project's existing */build/* exclusion convention)"

# The real, decisive proof: a genuine `git status` inside the submodule at
# its NEW, never-before-existing path must work cleanly - proving the
# relative `.git` gitdir pointer (`../../.git/modules/sub`) survived being
# moved to a location that never existed before this test ran.
out="$(cd "${EXTRACTED_ROOT}" && git status --short sub 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "git status on the relocated submodule succeeds (relative .git gitdir pointer survived relocation)"
assert_eq "" "${out}" "relocated submodule reports a clean status (no unexpected diff introduced by archiving)"

out2="$(cd "${EXTRACTED_ROOT}/sub" && git log --oneline -1 2>&1)" && rc2=0 || rc2=$?
assert_eq 0 "${rc2}" "git log inside the relocated submodule succeeds (it is a genuinely functional git repo, not just copied files)"
assert_contains "${out2}" "submodule commit" "relocated submodule's real commit history is intact"

# --- RELATIVE output-basename path (the exact shape the real Makefile uses:
# `bash scripts/release/build_archive.sh "$(ROOT)" ../llmctl`) must resolve
# against the CALLER's cwd, not silently re-resolve against build_archive's
# own internal `cd "${parent}"` (a real bug found this session: `make
# archive` reported success while writing llmctl.zip one directory level
# too high because the relative output path was consumed AFTER the cd). --
RELDIR="${TEST_TMP}/relpath_test"
mkdir -p "${RELDIR}/workdir"
( cd "${RELDIR}/workdir" && build_archive "${SUPER}" "../rel_output" )
assert_file_exists "${RELDIR}/rel_output.tar.gz" "a RELATIVE output-basename resolves against the caller's cwd, not build_archive's internal cd target"
assert_file_exists "${RELDIR}/rel_output.zip" "the .zip counterpart also resolves correctly for a relative output-basename"

test_finish
