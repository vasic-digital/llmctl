#!/usr/bin/env bash
# test_preflight_submodules.sh - proves preflight_check_ref genuinely detects
# an unreachable pinned submodule commit vs. a reachable one, using REAL
# local git repositories (not mocked network calls) - Phase 8 T044, spec.md
# FR-014/FR-052/Clarification 21: "Release packaging hard-fails, naming the
# unreachable submodule and its expected ref; no artifact is produced with a
# missing or empty submodule directory."
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

source "${LLMCTL_ROOT}/scripts/release/preflight_submodules.sh"

WORK="${TEST_TMP}/preflight_fixtures"
mkdir -p "${WORK}"

# --- Fixture 1: a genuinely reachable pinned commit --------------------------
UPSTREAM_GOOD="${WORK}/upstream_good"
git init -q "${UPSTREAM_GOOD}"
(
  cd "${UPSTREAM_GOOD}"
  git config user.email test@example.com; git config user.name test
  echo "one" > f.txt; git add f.txt; git commit -qm "commit A"
)
GOOD_SHA="$(git -C "${UPSTREAM_GOOD}" rev-parse HEAD)"

SCRATCH_GOOD="${WORK}/scratch_good"
git init -q "${SCRATCH_GOOD}"

rc=0
preflight_check_ref "${SCRATCH_GOOD}" "file://${UPSTREAM_GOOD}" "${GOOD_SHA}" || rc=$?
assert_eq 0 "${rc}" "a genuinely reachable pinned commit is detected as reachable"

# --- Fixture 2: a genuinely UNREACHABLE pinned commit (object pruned away) --
UPSTREAM_BAD="${WORK}/upstream_bad"
git init -q "${UPSTREAM_BAD}"
(
  cd "${UPSTREAM_BAD}"
  git config user.email test@example.com; git config user.name test
  echo "one" > f.txt; git add f.txt; git commit -qm "commit A (will be orphaned)"
)
BAD_SHA="$(git -C "${UPSTREAM_BAD}" rev-parse HEAD)"
(
  cd "${UPSTREAM_BAD}"
  # Orphan commit A: create an unrelated history and force the branch to
  # point at it instead, then actually prune A's object away so it is
  # genuinely gone from the repo - not merely unreferenced-but-recoverable.
  git checkout -q --orphan replacement
  git rm -qf f.txt 2>/dev/null || true
  echo "two" > g.txt; git add g.txt; git commit -qm "commit B (unrelated)"
  git branch -qD master 2>/dev/null || git branch -qD main 2>/dev/null || true
  git branch -qm replacement main
  git reflog expire --expire=now --all
  git gc --prune=now -q
)
# Sanity: confirm the fixture itself genuinely lost the object (proves this
# test's own negative case is real, not merely "we didn't try hard enough" -
# Constitution §11.4.115(F): a RED test must reproduce the REAL condition).
rc=0
git -C "${UPSTREAM_BAD}" cat-file -e "${BAD_SHA}^{commit}" 2>/dev/null || rc=1
assert_eq 1 "${rc}" "fixture sanity: the orphaned commit is genuinely gone from upstream_bad after gc --prune"

SCRATCH_BAD="${WORK}/scratch_bad"
git init -q "${SCRATCH_BAD}"

rc=0
preflight_check_ref "${SCRATCH_BAD}" "file://${UPSTREAM_BAD}" "${BAD_SHA}" || rc=$?
assert_eq 1 "${rc}" "a genuinely unreachable pinned commit is detected as unreachable"

# --- Top-level preflight_run: hard-fails naming the specific submodule + ref
out="$(preflight_run "bad-submodule" "file://${UPSTREAM_BAD}" "${BAD_SHA}" 2>&1)" && rc=0 || rc=$?
assert_eq 1 "${rc}" "preflight_run exits 1 when a submodule ref is unreachable"
assert_contains "${out}" "bad-submodule" "failure message names the specific unreachable submodule"
assert_contains "${out}" "${BAD_SHA}" "failure message names the specific expected (unreachable) ref"

out="$(preflight_run "good-submodule" "file://${UPSTREAM_GOOD}" "${GOOD_SHA}" 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "preflight_run exits 0 when the submodule ref is genuinely reachable"

# --- A fetch that fails outright (unreachable HOST, e.g. network/auth/DNS
# problem) must be reported as a DISTINCT "could not verify" outcome, never
# conflated with "confirmed the ref is genuinely gone" (Constitution
# §11.4.201: a guard's refusal must assert the REAL condition - a network
# failure and a proven-absent ref are different findings requiring
# different operator responses; lumping them together is the exact
# false-positive-refusal class §11.4.201 forbids). Use a URL pointing at a
# path that does not exist on disk, so the local `file://` fetch itself
# fails immediately (no network dependency in this test). -------------------
mkdir -p "${WORK}/scratch_noconn"
git init -q "${WORK}/scratch_noconn"
rc=0
preflight_check_ref "${WORK}/scratch_noconn" "file:///nonexistent/path/that/does/not/exist" "${GOOD_SHA}" || rc=$?
assert_eq 2 "${rc}" "preflight_check_ref returns 2 (could-not-verify) when the fetch itself fails, distinct from 1 (confirmed unreachable)"

out="$(preflight_run "unfetchable-submodule" "file:///nonexistent/path/that/does/not/exist" "${GOOD_SHA}" 2>&1)" && rc=0 || rc=$?
assert_eq 2 "${rc}" "preflight_run exits 2 (could-not-verify) when the fetch itself fails, never silently treated as reachable (rc 0) nor mis-reported as confirmed-unreachable (rc 1)"
assert_contains "${out}" "UNKNOWN" "could-not-verify case is reported with an honest UNKNOWN message, not a false FAIL/PASS claim"

# --- Regression: preflight_run must not leak a stale RETURN trap into its
# CALLER's scope when invoked repeatedly from a caller-owned loop (the exact
# shape _preflight_walk uses in the standalone run) - a real, live-reproduced
# defect this session where a bash RETURN trap set inside preflight_run fired
# again when the WRAPPING function returned, referencing that invocation's
# now-out-of-scope `scratch_dir` local and crashing under `set -euo pipefail`
# with "scratch_dir: unbound variable" - AFTER two correct PASS results had
# already printed, silently aborting the walk before every remaining
# submodule was checked (a false "the rest are fine" by omission). -----------
_preflight_run_leak_wrapper() {
  local names=("wrap-a" "wrap-b") n rc
  for n in "${names[@]}"; do
    rc=0
    preflight_run "${n}" "file://${UPSTREAM_GOOD}" "${GOOD_SHA}" || rc=$?
    [[ "${rc}" -eq 0 ]] || return 1
  done
  return 0
}

wrapper_out=""
wrapper_rc=0
wrapper_out="$(_preflight_run_leak_wrapper 2>&1)" || wrapper_rc=$?
assert_eq 0 "${wrapper_rc}" "a caller that invokes preflight_run twice in its own loop returns cleanly (no leaked RETURN-trap crash on the CALLER's own return)"
case "${wrapper_out}" in
  *"unbound variable"*)
    assert_eq 0 1 "no 'unbound variable' text ever appears - a leaked trap referencing an out-of-scope local must not fire (got: ${wrapper_out:0:200})"
    ;;
  *)
    assert_eq 0 0 "no 'unbound variable' text appears in the wrapper's output"
    ;;
esac

test_finish
