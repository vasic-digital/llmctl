#!/usr/bin/env bash
# test_constitution_inheritance_worktree.sh - Invariant 8 of test_constitution_inheritance.sh must inspect the
# CONSTITUTION submodule's own repository, never silently fall through to the enclosing project repo.
#
# Root cause (found 2026-10-13): in a linked `git worktree` (or any checkout where `git submodule update` has not
# run) constitution/ is an EMPTY directory. `cd constitution && git remote` then resolves to the ENCLOSING repo,
# so the remote count measured llmctl itself (vacuous pass or fail depending on the project's own remotes),
# while every file-presence invariant failed. The check must (a) require constitution/ to be its own repo and
# (b) in a linked worktree, resolve the submodule checkout from the main worktree.
# Fixtures only: temp git repos, no network, nothing outside TEST_TMP is touched.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

SCRIPT="${LLMCTL_ROOT}/tests/test_constitution_inheritance.sh"
G() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }

# mk_const <dir> <n-remotes> <n-pushurls>: a standalone repo standing in for the constitution submodule
mk_const() {
  local d="$1" nr="$2" np="$3" i
  mkdir -p "${d}"; G -C "${d}" init -q
  for ((i=1; i<=nr; i++)); do G -C "${d}" remote add "r${i}" "git@example.invalid:o/r${i}.git"; done
  G -C "${d}" remote add origin "git@example.invalid:o/origin.git"
  for ((i=1; i<=np; i++)); do G -C "${d}" remote set-url --add --push origin "git@example.invalid:o/p${i}.git"; done
}
# mk_proj <dir> <n-parent-remotes>: a project repo carrying a copy of the script under test
mk_proj() {
  local d="$1" nr="$2" i
  mkdir -p "${d}/tests"; cp "${SCRIPT}" "${d}/tests/"; G -C "${d}" init -q
  for ((i=1; i<=nr; i++)); do G -C "${d}" remote add "p${i}" "git@example.invalid:o/p${i}.git"; done
  G -C "${d}" remote add origin "git@example.invalid:o/o.git"
  for ((i=1; i<=5; i++)); do G -C "${d}" remote set-url --add --push origin "git@example.invalid:o/pp${i}.git"; done
  G -C "${d}" add -A; G -C "${d}" commit -q -m init
}
inv8() { bash "$1/tests/test_constitution_inheritance.sh" 2>&1 | sed -n '/^Invariant 8/,/^Invariant 9/p' || true; }

# A. NEGATIVE: constitution/ is an empty dir, the ENCLOSING repo has 6 remotes + 5 push URLs (would satisfy
#    the old count). Invariant 8 must FAIL: the submodule is not a repository of its own.
mk_proj "${TEST_TMP}/A" 6; mkdir -p "${TEST_TMP}/A/constitution"
out="$(inv8 "${TEST_TMP}/A")"
assert_contains "${out}" "✗" "empty constitution/ inside a remote-rich project repo: Invariant 8 FAILS (no vacuous pass)"
[[ "${out}" != *"✓ At least 4"* ]] && echo "  ok: the enclosing repo's remotes were not counted as the constitution's" || { echo "  FAIL: enclosing repo remotes counted" >&2; TEST_FAILS=$((TEST_FAILS+1)); }

# B. POSITIVE: main checkout has the real submodule repo (5 remotes + 4 push URLs); a LINKED WORKTREE of the
#    project has constitution/ empty. Invariant 8 in the worktree must resolve the main checkout's submodule.
mk_proj "${TEST_TMP}/B" 0; mk_const "${TEST_TMP}/B/constitution" 5 4
G -C "${TEST_TMP}/B" worktree add -q "${TEST_TMP}/Bwt" -b wt
out="$(inv8 "${TEST_TMP}/B")"
assert_contains "${out}" "✓ At least 4 upstream remotes configured" "main checkout with a real submodule repo: Invariant 8 passes"
out="$(inv8 "${TEST_TMP}/Bwt")"
assert_contains "${out}" "✓ At least 4 upstream remotes configured" "linked worktree (constitution/ empty): Invariant 8 resolves the main checkout's submodule"

# C. NEGATIVE in the worktree: the main checkout's submodule really has too few remotes -> must still FAIL.
mk_proj "${TEST_TMP}/C" 0; mk_const "${TEST_TMP}/C/constitution" 2 1
G -C "${TEST_TMP}/C" worktree add -q "${TEST_TMP}/Cwt" -b wt
out="$(inv8 "${TEST_TMP}/Cwt")"
assert_contains "${out}" "✗ Insufficient upstream remotes" "linked worktree whose main submodule has 2 remotes / 1 push URL: Invariant 8 still FAILS"

# D. NEGATIVE: a stray .git FILE (not a gitlink to a real repo) or a symlink to the enclosing repo must NOT count
#    as the submodule's own repository.
mk_proj "${TEST_TMP}/D" 6; mkdir -p "${TEST_TMP}/D/constitution"; echo "stray" >"${TEST_TMP}/D/constitution/.git"
out="$(inv8 "${TEST_TMP}/D")"
assert_contains "${out}" "✗" "stray .git file in constitution/: Invariant 8 FAILS"
[[ "${out}" != *"✓ At least 4"* ]] && echo "  ok: stray .git file not treated as an own repo" || { echo "  FAIL: stray .git counted" >&2; TEST_FAILS=$((TEST_FAILS+1)); }
mk_proj "${TEST_TMP}/E" 6; ln -s . "${TEST_TMP}/E/constitution"
out="$(inv8 "${TEST_TMP}/E")"
assert_contains "${out}" "✗" "constitution -> symlink to the enclosing repo: Invariant 8 FAILS"
[[ "${out}" != *"✓ At least 4"* ]] && echo "  ok: symlink to the enclosing repo not treated as an own repo" || { echo "  FAIL: symlink counted" >&2; TEST_FAILS=$((TEST_FAILS+1)); }
# F. POSITIVE: a symlinked constitution/ pointing at a genuine standalone repo still works.
mk_proj "${TEST_TMP}/F" 0; mk_const "${TEST_TMP}/Freal" 5 4; ln -s "${TEST_TMP}/Freal" "${TEST_TMP}/F/constitution"
out="$(inv8 "${TEST_TMP}/F")"
assert_contains "${out}" "✓ At least 4 upstream remotes configured" "constitution -> symlink to a genuine standalone repo: Invariant 8 passes"

test_finish
