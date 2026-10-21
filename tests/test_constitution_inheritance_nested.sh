#!/usr/bin/env bash
# test_constitution_inheritance_nested.sh - behaviour of tests/test_constitution_inheritance.sh when the
# constitution submodule's OWN nested submodules (constitution/submodules/*) are not initialised.
#
# Root cause this guards (systematic-debugging, 2026-10-13): constitution/scripts/validation/run_verification.sh
# REQUIRES ~16 nested submodules to be checked out (`[ -f <name>/README.md ]` ...). A checkout that populated
# constitution/ but not its nested submodules (no `--recursive`, no network, a linked worktree) therefore failed
# invariants 9/10 with "Verification harness execution failed" / "Meta-test mutation failed" although nothing in
# the pin was wrong. The inheritance test must (a) say LOUDLY that 9/10 did not run and why, (b) never hide a
# genuinely broken constitution behind that skip, (c) be able to refuse the skip (strict mode, for releases).
#
# Everything runs against a throw-away FIXTURE project built under a mktemp dir: the real inheritance test is
# copied into it unchanged, its `constitution/` is a tiny real git repo (own .git, 6 remotes, gitlinks for every
# required nested submodule, the REAL validation scripts copied from the pinned constitution). Nothing in the
# working tree or in the real constitution/ is touched.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

REAL_TEST="${LLMCTL_ROOT}/tests/test_constitution_inheritance.sh"

# --- locate the REAL validation scripts (constitution/ here, or the main worktree's in a linked worktree) ----------
src=""
for cand in "$(bash "${LLMCTL_ROOT}/lib/resolve_deps.sh" constitution 2>/dev/null || true)" \
            "${LLMCTL_ROOT}/constitution" \
            "$(git -C "${LLMCTL_ROOT}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's#/\.git$##')/constitution"; do
  if [[ -f "${cand}/scripts/validation/run_verification.sh" && -f "${cand}/scripts/validation/meta_test_verification.sh" ]]; then
    src="${cand}"; break
  fi
done
if [[ -z "${src}" ]]; then
  skip_suite "no constitution/scripts/validation/*.sh available (constitution not resolvable: set LLMCTL_CONSTITUTION_DIR, nest llmctl in the hub, or see docs/dependency-layout.md)"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/llmctl-inherit-nested.XXXXXX")"
trap 'rm -rf -- "${WORK}"' EXIT

mapfile -t REQUIRED < <(sed -n '/^REQUIRED_SUBMODULES=(/,/^)/p' "${src}/scripts/validation/run_verification.sh" | grep -o '"[^"]*"' | tr -d '"')
assert_eq "yes" "$([[ ${#REQUIRED[@]} -ge 10 ]] && echo yes || echo no)" "parsed the harness's REQUIRED_SUBMODULES list (${#REQUIRED[@]} entries)"

# build_fixture <dir> : a project + a minimal constitution git repo whose nested submodules are gitlinks with EMPTY dirs
build_fixture() {
  local d="$1" n
  mkdir -p "${d}/tests" "${d}/constitution/scripts/validation"
  cp "${REAL_TEST}" "${d}/tests/"
  printf 'See constitution/CLAUDE.md\n' > "${d}/CLAUDE.md"
  printf 'See constitution/AGENTS.md\n' > "${d}/AGENTS.md"
  (
    cd "${d}/constitution"
    printf '§11.4 End-user quality guarantee — forensic anchor\n' > Constitution.md
    printf 'MANDATORY ANTI-BLUFF COVENANT\n' > CLAUDE.md
    printf 'Anti-bluff covenant\n' > AGENTS.md
    : > install_upstreams.sh; : > find_constitution.sh
    cp "${src}/scripts/validation/run_verification.sh" "${src}/scripts/validation/meta_test_verification.sh" scripts/validation/
    git init -q .
    git remote add origin git@example.invalid:o/c.git
    git remote set-url --add --push origin git@example.invalid:o/c.git
    for n in 1 2 3 4 5; do
      git remote add "up${n}" "git@example.invalid:u${n}/c.git"
      git remote set-url --add --push origin "git@example.invalid:u${n}/c.git"
    done
    git add -A
    for n in "${REQUIRED[@]}"; do
      git update-index --add --cacheinfo "160000,$(printf '%040d' 1),submodules/${n}"
      mkdir -p "submodules/${n}"
    done
    git -c user.name=t -c user.email=t@example.invalid commit -q -m fixture
  )
}
# populate_nested <constitution-dir> : every file the harness checks for, in every required nested dir
populate_nested() {
  local c="$1" n
  for n in "${REQUIRED[@]}"; do : > "${c}/submodules/${n}/README.md"; : > "${c}/submodules/${n}/Cargo.toml"; : > "${c}/submodules/${n}/package.json"; done
}
# run_case <dir> [VAR=val...] : run the copy of the real inheritance test inside the fixture; sets OUT / RC
run_case() {
  local d="$1"; shift
  RC=0
  OUT="$(env "$@" bash "${d}/tests/test_constitution_inheritance.sh" 2>&1)" || RC=$?
}

# --- case 1: populated constitution, nested submodules NOT initialised -> loud skip of 9/10, exit 0 ----------------
echo "== 1. nested submodules uninitialised: invariants 9/10 skipped LOUDLY, 1-8 still enforced =="
build_fixture "${WORK}/c1"
run_case "${WORK}/c1" LLMCTL_REQUIRE_NESTED_SUBMODULES=
assert_eq "0" "${RC}" "uninitialised nested submodules: the inheritance test exits 0 (it measures the pin, not the checkout depth)"
assert_contains "${OUT}" "SKIP: Invariant 9" "invariant 9 skip is printed as a SKIP line (runner counts it)"
assert_contains "${OUT}" "SKIP: Invariant 10" "invariant 10 skip is printed as a SKIP line (runner counts it)"
assert_contains "${OUT}" "git submodule update --init --recursive" "the skip names the remedy"
assert_contains "${OUT}" "  ok: " "invariants 1-8 report at least one ok line (suite is a PASS with skips, not an all-skipped SKIP)"
assert_eq "no" "$([[ "${OUT}" == *"ALL INVARIANTS PASSED"* ]] && echo yes || echo no)" "the summary does NOT claim ALL INVARIANTS PASSED when 9/10 were skipped"

# --- case 2: strict mode refuses the skip ---------------------------------------------------------------------------
echo "== 2. LLMCTL_REQUIRE_NESTED_SUBMODULES=1 refuses the skip =="
run_case "${WORK}/c1" LLMCTL_REQUIRE_NESTED_SUBMODULES=1
assert_eq "1" "${RC}" "strict mode: uninitialised nested submodules FAIL the test"

# --- case 3: negative control - broken constitution content is NOT hidden by the skip -----------------------------
echo "== 3. negative control: a genuinely broken constitution still FAILS with nested submodules uninitialised =="
build_fixture "${WORK}/c3"
printf 'no anchor here\n' > "${WORK}/c3/constitution/CLAUDE.md"
run_case "${WORK}/c3" LLMCTL_REQUIRE_NESTED_SUBMODULES=
assert_eq "1" "${RC}" "missing MANDATORY ANTI-BLUFF COVENANT anchor still fails (skip must not mask invariants 1-8)"
assert_contains "${OUT}" "MANDATORY ANTI-BLUFF COVENANT anchor missing" "the failure names the missing anchor"

# --- case 4: negative control - a required nested submodule absent from the PINNED TREE is a real defect ------------
echo "== 4. negative control: a required submodule that is not even a gitlink in the pinned tree FAILS =="
build_fixture "${WORK}/c4"
(cd "${WORK}/c4/constitution" && git rm -q --cached -- "submodules/${REQUIRED[0]}" && rmdir "submodules/${REQUIRED[0]}" \
  && git -c user.name=t -c user.email=t@example.invalid commit -q -m 'drop one required gitlink')
run_case "${WORK}/c4" LLMCTL_REQUIRE_NESTED_SUBMODULES=
assert_eq "1" "${RC}" "harness requires a submodule the pinned tree does not carry: FAIL, not skip"

# --- case 5: nested submodules populated -> the REAL harness + meta-test run (no skip) ---------------------------------
echo "== 5. nested submodules initialised: the real harness and meta-test run and pass =="
build_fixture "${WORK}/c5"
populate_nested "${WORK}/c5/constitution"
run_case "${WORK}/c5" LLMCTL_REQUIRE_NESTED_SUBMODULES=
assert_eq "0" "${RC}" "populated nested submodules: the inheritance test passes"
assert_contains "${OUT}" "Verification harness executes successfully" "invariant 9 really ran"
assert_contains "${OUT}" "Meta-test mutation passes" "invariant 10 really ran"
assert_eq "no" "$([[ "${OUT}" == *"SKIP:"* ]] && echo yes || echo no)" "nothing was skipped when the nested submodules are present"

# --- case 6: negative control - populated but a required submodule is broken -> the harness failure surfaces ----------
echo "== 6. negative control: populated nested submodules with one broken -> invariant 9 FAILS (never skipped) =="
build_fixture "${WORK}/c6"
populate_nested "${WORK}/c6/constitution"
rm -f "${WORK}/c6/constitution/submodules/verfix/README.md"
run_case "${WORK}/c6" LLMCTL_REQUIRE_NESTED_SUBMODULES=
assert_eq "1" "${RC}" "an initialised required submodule missing its README is a REAL harness failure"
assert_contains "${OUT}" "Verification harness execution failed" "the real harness failure is reported"

test_finish
