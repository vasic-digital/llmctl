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
build_archive --allow-dirty "${SUPER}" "${OUT_BASENAME}"   # the fixture plants an untracked sub/build/

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
( cd "${RELDIR}/workdir" && build_archive --allow-dirty "${SUPER}" "../rel_output" )
assert_file_exists "${RELDIR}/rel_output.tar.gz" "a RELATIVE output-basename resolves against the caller's cwd, not build_archive's internal cd target"
assert_file_exists "${RELDIR}/rel_output.zip" "the .zip counterpart also resolves correctly for a relative output-basename"

# --- C2-01: the shipped .git must ACTIVATE its submodules ----------------------------------------------------------
# A release built FROM a release must not silently lose submodule content: `git submodule status` of the extracted tree
# has no '-' (uninitialised) prefix, `git ls-files --recurse-submodules` matches the source's, and re-archiving the
# extracted tree ships the submodule's real files.
st="$(git -C "${EXTRACTED_ROOT}" submodule status 2>&1)" || true
assert_eq 0 "$(grep -c '^-' <<<"${st}" || true)" "C2-01: extracted tree's submodule is initialised (no '-' prefix in: ${st})"
src_ls="$(git -C "${SUPER}" ls-files --recurse-submodules | LC_ALL=C sort)"
ext_ls="$(git -C "${EXTRACTED_ROOT}" ls-files --recurse-submodules | LC_ALL=C sort)"
assert_eq "${src_ls}" "${ext_ls}" "C2-01: git ls-files --recurse-submodules of the extracted tree == the source's"
OUT_RE="${TEST_TMP}/output/rearchived"
rc=0; ( build_archive "${EXTRACTED_ROOT}" "${OUT_RE}" ) >/dev/null 2>"${TEST_TMP}/re.err" || rc=$?
assert_eq 0 "${rc}" "C2-01: re-archiving an extracted release succeeds"
re_list="$(tar -tzf "${OUT_RE}.tar.gz" 2>/dev/null || true)"
assert_eq 1 "$(grep -c -E '(^|/)sub/sub_file\.txt$' <<<"${re_list}" || true)" "C2-01: re-archive of a release holds sub/sub_file.txt (no silent submodule loss)"

# a gitlink that yields ZERO files must FAIL the build, never exit 0 with an empty submodule
ZERO="${TEST_TMP}/zero_fixture"
cp -a "${SUPER}" "${ZERO}"
rm -rf "${ZERO}/sub"; mkdir "${ZERO}/sub"          # gitlink present, working tree empty (uninitialised submodule)
rc=0; ( build_archive "${ZERO}" "${TEST_TMP}/output/zero" ) >/dev/null 2>"${TEST_TMP}/zero.err" || rc=$?
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "C2-01: a gitlink yielding zero files makes build_archive FAIL"
assert_file_contains "${TEST_TMP}/zero.err" "sub" "C2-01: ...and names the gitlink"
assert_file_absent "${TEST_TMP}/output/zero.tar.gz" "C2-01: ...leaving no archive behind"

# --- C2-15: a dirty tree is refused unless --allow-dirty; the manifest records it -----------------------------------
DIRTY="${TEST_TMP}/dirty_fixture"
cp -a "${SUPER}" "${DIRTY}"
echo "local edit" >> "${DIRTY}/super_file.txt"
echo "untracked" > "${DIRTY}/not_committed.txt"
rc=0; ( build_archive "${DIRTY}" "${TEST_TMP}/output/dirty" ) >/dev/null 2>"${TEST_TMP}/dirty.err" || rc=$?
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "C2-15: a dirty tree is refused by default"
assert_file_contains "${TEST_TMP}/dirty.err" "allow-dirty" "C2-15: ...naming the override"
assert_file_absent "${TEST_TMP}/output/dirty.tar.gz" "C2-15: ...leaving no archive behind"
rc=0; ( build_archive --allow-dirty "${DIRTY}" "${TEST_TMP}/output/dirty" ) >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "C2-15: --allow-dirty builds a dirty tree"
mf="$(tar -xzOf "${TEST_TMP}/output/dirty.tar.gz" dirty_fixture/.git/llmctl-release-manifest.json 2>/dev/null || true)"
assert_contains "${mf}" '"dirty": true' "C2-15: the shipped manifest records dirty=true"
mf_clean="$(tar -xzOf "${OUT_RE}.tar.gz" super/.git/llmctl-release-manifest.json 2>/dev/null || true)"
assert_contains "${mf_clean}" '"dirty": false' "C2-15: a clean build (the re-archive) records dirty=false"
rc=0; ( BA_ALLOW_DIRTY=1 build_archive "${DIRTY}" "${TEST_TMP}/output/dirty_env" ) >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "C2-15: BA_ALLOW_DIRTY=1 is the env spelling of --allow-dirty"

# --- C3-06: the zero-file gitlink check is ANCHORED (a decoy path that merely CONTAINS "<base>/<sub>/" is no proof) -----
# Source dir named `proj` with an uninitialised gitlink `sub` and a TRACKED decoy file docs/proj/sub/readme: the list entry
# "proj/docs/proj/sub/readme" contains the substring "proj/sub/" but is NOT under the submodule.
UNI="${TEST_TMP}/uni/proj"; mkdir -p "${TEST_TMP}/uni"
cp -a "${SUPER}" "${UNI}"
( cd "${UNI}"; git config user.email t@e.x; git config user.name t
  git submodule deinit -q -f sub >/dev/null 2>&1; mkdir -p docs/proj/sub; echo decoy > docs/proj/sub/readme
  git add docs/proj/sub/readme; git commit -qm decoy )
rc=0; ( build_archive "${UNI}" "${TEST_TMP}/output/uni" ) >/dev/null 2>"${TEST_TMP}/uni.err" || rc=$?
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "C3-06: an UNINITIALISED submodule fails the build even when a decoy path contains '<base>/<sub>/'"
assert_file_contains "${TEST_TMP}/uni.err" "gitlink 'sub'" "C3-06: ...naming the gitlink"
assert_file_absent "${TEST_TMP}/output/uni.tar.gz" "C3-06: ...leaving no archive behind"

# --- C3-15 (S1): an initialised submodule whose only listed entry is its .git pointer still counts as ZERO files -----
EMP="${TEST_TMP}/emp_up"; git init -q "${EMP}"; ( cd "${EMP}"; git config user.email t@e.x; git config user.name t; git commit -q --allow-empty -m empty )
ESUP="${TEST_TMP}/esup"; git init -q "${ESUP}"
( cd "${ESUP}"; git config user.email t@e.x; git config user.name t; echo x > x.txt; git add x.txt; git commit -qm x
  git -c protocol.file.allow=always submodule add -q "file://${EMP}" esub >/dev/null 2>&1; git commit -qm addsub )
rc=0; ( build_archive "${ESUP}" "${TEST_TMP}/output/esup" ) >/dev/null 2>"${TEST_TMP}/esup.err" || rc=$?
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "C3-15/S1: a submodule contributing only its .git pointer is a zero-file gitlink (pointer not counted)"

# --- C3-15 (S5): a DIRTY SUBMODULE (edit inside it) is refused like a dirty main tree ------------------------------
SDIRTY="${TEST_TMP}/sub_dirty"
cp -a "${SUPER}" "${SDIRTY}"
echo "local edit in the submodule" >> "${SDIRTY}/sub/sub_file.txt"
rc=0; ( build_archive "${SDIRTY}" "${TEST_TMP}/output/sub_dirty" ) >/dev/null 2>"${TEST_TMP}/sdirty.err" || rc=$?
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "C3-15/S5: an edit INSIDE a submodule makes the tree dirty and build_archive refuses"
assert_file_contains "${TEST_TMP}/sdirty.err" "allow-dirty" "C3-15/S5: ...naming the override"

# --- C2-17: no bare "${arr[@]}" expansion of a possibly-empty array under set -u (bash < 4.4) -------------------------
# control needle: the guard must see a planted bare expansion, else a clean result proves nothing.
bare_expansions() { grep -nE '"\$\{[A-Za-z_]+\[@\]\}"' "$1" | grep -v -E '\$\{[A-Za-z_]+\[@\]\+' || true; }
printf 'x=(); echo "${x[@]}"\n' > "${TEST_TMP}/needle.sh"
assert_contains "$(bare_expansions "${TEST_TMP}/needle.sh")" 'x[@]' "C2-17: guard control needle is seen (instrument not blind)"
assert_eq "" "$(bare_expansions "${LLMCTL_ROOT}/scripts/release/build_archive.sh")" "C2-17: build_archive.sh has no bare \"\${arr[@]}\" expansion (bash 3.2 / <4.4 under set -u)"

test_finish
