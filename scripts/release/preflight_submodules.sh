#!/usr/bin/env bash
# preflight_submodules.sh - verifies every pinned submodule ref (this
# repo's own submodules PLUS constitution's nested submodule set,
# recursively) is genuinely fetchable from its configured remote, BEFORE
# any release artifact is built.
#
# Purpose:
#   spec.md FR-014/FR-052, Clarification 21: "What happens when a pinned
#   submodule's ref is unreachable at release-packaging time (upstream
#   private/deleted/rate-limited)? -> Release packaging hard-fails, naming
#   the unreachable submodule and its expected ref; no artifact is produced
#   with a missing or empty submodule directory." This script IS that
#   preflight check.
#
# Usage:
#   source scripts/release/preflight_submodules.sh   # for unit-testing the
#                                                     # preflight_check_ref /
#                                                     # preflight_run functions
#   bash scripts/release/preflight_submodules.sh      # standalone run: walks
#                                                     # every submodule this
#                                                     # repo + constitution
#                                                     # declare, recursively,
#                                                     # and hard-fails on the
#                                                     # first unreachable one
#
# Inputs:
#   None required for the standalone run (it discovers submodules from the
#   real `.gitmodules` files via `git submodule status --recursive`, run
#   from this repo's root AND from inside constitution/ - the task's own
#   "including constitution's nested submodules" requirement). The library
#   functions (preflight_check_ref, preflight_run) take explicit arguments
#   for unit-testability without a real network dependency.
#
# Outputs:
#   Real per-submodule PASS/FAIL evidence on stdout/stderr. Exit 0 if every
#   submodule ref is reachable; exit 1 naming the FIRST unreachable
#   submodule + its exact expected (unreachable) SHA on any failure -
#   hard-fail, never a partial/best-effort continuation past a broken ref
#   (an artifact built past this point would embed a missing/empty
#   submodule directory, which FR-052 forbids).
#
# Side-effects:
#   Performs real `git fetch` calls against each submodule's configured
#   remote (a genuine reachability probe, not an assumption) into a
#   throwaway scratch git repository under a temp directory it creates and
#   cleans up itself - never mutates any of this repo's own submodule
#   checkouts.
#
# Dependencies: bash, git. No llmctl lib/ sourcing - standalone by design so
# it can run in a release-packaging context that doesn't source the rest of
# this project's bash libraries.
#
# Cross-references:
#   scripts/release/create_release.sh   - calls this before building assets
#   tests/test_preflight_submodules.sh  - the RED/GREEN proof of correctness
#   docs/release-process.md             - documents this as the first release step
#   specs/001-llmctl-completion/spec.md - FR-014, FR-052, Clarification 21
set -euo pipefail

# preflight_check_ref <scratch-git-dir> <remote-url> <expected-sha>
# Fetches every branch+tag from <remote-url> into the (already-`git init`'d)
# <scratch-git-dir>, then checks whether <expected-sha> is genuinely
# reachable from what was fetched. This does NOT rely on the remote
# supporting fetch-by-arbitrary-SHA (many git hosts, including GitHub by
# default, restrict that) - it fetches everything the remote advertises and
# checks ancestry locally instead, which works against any git host.
#
# Three-state return (Constitution §11.4.201: a guard MUST assert the REAL
# condition - a network/auth/DNS failure that prevents verification and a
# PROVEN-absent ref are different findings requiring different operator
# responses; conflating them is the false-positive-refusal class §11.4.201
# forbids):
#   0 = reachable (fetch succeeded, expected_sha is an ancestor of a fetched ref)
#   1 = confirmed unreachable (fetch succeeded, expected_sha is genuinely absent)
#   2 = could not verify (the fetch itself failed - network/auth/host problem;
#       this is NOT evidence the ref is unreachable, only that this check
#       could not run to completion)
preflight_check_ref() {
  local scratch_dir="$1" url="$2" expected_sha="$3"
  local fetch_timeout="${PREFLIGHT_FETCH_TIMEOUT:-30}"

  # A connection-refused/DNS-error fetch fails fast; a genuinely HUNG
  # network path (no RST, no response) would otherwise block indefinitely -
  # bounded via `timeout` so one bad submodule can never wedge the whole
  # release preflight. A timeout is itself a "could not verify" outcome
  # (rc 2 below), never silently treated as "confirmed unreachable".
  if ! timeout "${fetch_timeout}" git -C "${scratch_dir}" fetch --quiet --tags "${url}" \
      '+refs/heads/*:refs/remotes/preflight/*' 2>/dev/null; then
    return 2
  fi

  git -C "${scratch_dir}" cat-file -e "${expected_sha}^{commit}" 2>/dev/null || return 1

  local ref
  while IFS= read -r ref; do
    [[ -n "${ref}" ]] || continue
    git -C "${scratch_dir}" merge-base --is-ancestor "${expected_sha}" "${ref}" 2>/dev/null && return 0
  done < <(git -C "${scratch_dir}" for-each-ref --format='%(refname)' refs/remotes/preflight refs/tags)

  return 1
}

# preflight_run <submodule-name> <remote-url> <expected-sha>
# Runs preflight_check_ref in a fresh throwaway scratch repo (cleaned up on
# return) and hard-fails with an evidence-bearing message naming the exact
# submodule + expected SHA on failure. Propagates the same three-state
# return as preflight_check_ref (0 reachable / 1 confirmed-unreachable /
# 2 could-not-verify) with a message honestly distinguishing which one fired.
preflight_run() {
  local name="$1" url="$2" expected_sha="$3"
  local scratch_dir rc
  scratch_dir="$(mktemp -d)"
  # NOTE: deliberately NOT `trap ... RETURN` here. A RETURN trap set inside a
  # function is not reliably scoped to that single invocation in bash: when
  # this function is called repeatedly from a caller's loop (exactly how
  # _preflight_walk below uses it), the trap can fire again when the CALLER
  # itself returns - at which point `scratch_dir` is a different function's
  # now-out-of-scope local, and `set -u` kills the whole script with
  # "scratch_dir: unbound variable". Reproduced live this session: two real
  # PASS/FAIL results were printed correctly, then the walk crashed anyway
  # on the next caller-level return, before every submodule (including
  # constitution's nested ones) had even been checked - a false "the
  # remaining submodules are fine" by omission. Explicit cleanup on every
  # return path avoids the whole class of trap-scoping footgun.
  git init --quiet "${scratch_dir}"

  rc=0
  preflight_check_ref "${scratch_dir}" "${url}" "${expected_sha}" || rc=$?
  rm -rf "${scratch_dir}"
  case "${rc}" in
    0)
      printf 'PASS submodule %s: ref %s is reachable from %s\n' "${name}" "${expected_sha}" "${url}"
      return 0
      ;;
    2)
      printf 'UNKNOWN submodule %s: could not verify ref %s - fetching from %s itself failed (network/auth/host problem, NOT evidence the ref is unreachable)\n' \
        "${name}" "${expected_sha}" "${url}" >&2
      return 2
      ;;
    *)
      printf 'FAIL submodule %s: expected ref %s is NOT reachable from %s\n' "${name}" "${expected_sha}" "${url}" >&2
      printf '  Release packaging hard-fails here (spec.md FR-052/Clarification 21): no artifact\n' >&2
      printf '  is produced with a missing or empty submodule directory.\n' >&2
      return 1
      ;;
  esac
}

# --- standalone run: real submodules, this repo + constitution recursively --
_preflight_main() {
  local root; root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  local fails=0 unknowns=0

  _preflight_walk() {
    local repo_dir="$1"
    local line path sha url rc
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      # `git submodule status` lines: " <sha> <path> (<describe>)" (or a
      # leading +/- marker for out-of-sync/uninitialized).
      sha="$(printf '%s' "${line}" | awk '{print $1}' | sed 's/^[+-]//')"
      path="$(printf '%s' "${line}" | awk '{print $2}')"
      url="$(git -C "${repo_dir}" config -f "${repo_dir}/.gitmodules" --get "submodule.${path}.url" 2>/dev/null || true)"
      [[ -n "${url}" && -n "${sha}" ]] || continue
      rc=0
      preflight_run "${repo_dir}/${path}" "${url}" "${sha}" || rc=$?
      case "${rc}" in
        0) ;;
        2) unknowns=$((unknowns + 1)) ;;
        *) fails=$((fails + 1)) ;;
      esac
    done < <(git -C "${repo_dir}" submodule status 2>/dev/null || true)
  }

  _preflight_walk "${root}"
  [[ -d "${root}/constitution" ]] && _preflight_walk "${root}/constitution"

  if (( fails > 0 || unknowns > 0 )); then
    printf 'PREFLIGHT FAILED: %d submodule ref(s) confirmed unreachable, %d could not be verified (see FAIL/UNKNOWN lines above)\n' \
      "${fails}" "${unknowns}" >&2
    printf 'Neither class is safe to release against - a ref that cannot be verified is treated the same as an unreachable one (no artifact ships on an unproven submodule).\n' >&2
    return 1
  fi
  printf 'PREFLIGHT PASSED: every submodule ref is reachable\n'
  return 0
}

# Only auto-run when executed directly (not when sourced for testing).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _preflight_main
fi
