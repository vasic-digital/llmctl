#!/usr/bin/env bash
# link_deps.sh - materialise the (untracked, .gitignored) convenience links to llmctl's resolved dependencies.
#
# llmctl no longer vendors `constitution`, `submodules/containers` or `submodules/superspec` as submodules
# (single source of truth: the copy in the constitution hub / on the host - see lib/resolve_deps.sh). Two
# things still address them by fixed repo-relative path: go.mod (`replace digital.vasic.containers =>
# ./submodules/containers`) and the carriers' `@constitution/CLAUDE.md` import. This script makes those paths
# valid by symlinking them to whatever lib/resolve_deps.sh resolves. Nothing is copied; nothing is pinned.
#
# Usage:
#   bash scripts/link_deps.sh                       # create/refresh all three links (idempotent)
#   bash scripts/link_deps.sh containers            # only the named ones (constitution|containers|superspec)
#   bash scripts/link_deps.sh --check [names...]    # verify only; exit 1 if any link is missing or points elsewhere
#   bash scripts/link_deps.sh --adopt-leftover [names...]   # see UPGRADE LEFTOVERS below
#
# UPGRADE LEFTOVERS: git does not delete a populated submodule worktree when its gitlink is removed, so an
# existing checkout keeps REAL directories constitution/, submodules/containers/, submodules/superspec/ (they are
# .gitignored now, i.e. hidden). Such a path blocks the link (exit 1, "LEFTOVER <path>") and the script prints the
# remediation: verify `git -C <path> status --porcelain` is empty, then `rm -rf <path>` and re-run. With the explicit
# opt-in --adopt-leftover it converts ONLY a leftover that is (a) a gitfile-style submodule worktree (.git is a
# FILE), (b) clean, and (c) at HEAD == the old recorded pin (constitution 8a60462..., containers 4a8f04e...,
# superspec c20ac6c...; test hook: LLMCTL_ADOPT_PIN_<NAME>) by MOVING it to <path>.leftover-<YYYYMMDD>[-N]
# (nothing is deleted, section 9.2) and linking. Anything else is refused with the reason.
# Inside the hub (llmctl at <hub>/submodules/llmctl) the links are RELATIVE (constitution -> ../..,
# submodules/<name> -> ../../<name>) so they survive moving the hub; elsewhere they are absolute.
#
# Links managed (relative to the llmctl root):
#   constitution -> <resolved constitution>      submodules/containers -> <resolved containers>
#   submodules/superspec -> <resolved superspec>
#
# Safety: a path that exists as a REAL directory or file is never replaced (reported and skipped, exit 1);
# only missing paths and symlinks are touched. An unresolvable dependency is reported (exit 1) after the
# others have still been linked - never a silent skip.
# Exit codes: 0 all links correct; 1 at least one dependency unresolved / blocked by a real dir / (--check) wrong.
# Side effects: creates/replaces symlinks inside the llmctl checkout. Dependencies: bash, ln, readlink.
# Cross-references: lib/resolve_deps.sh, tests/test_link_deps.sh, docs/dependency-layout.md.
set -euo pipefail

ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/resolve_deps.sh
source "${ROOT}/lib/resolve_deps.sh"

check_only=0
adopt=0
names=()
for _a in "$@"; do
  case "${_a}" in
    --check) check_only=1 ;;
    --adopt-leftover) adopt=1 ;;
    *) names+=("${_a}") ;;
  esac
done
if [[ ${#names[@]} -eq 0 ]]; then names=(constitution containers superspec); fi

# same_dir <a> <b>: both resolve to the same physical directory
same_dir() { [[ "$(CDPATH='' cd "$1" 2>/dev/null && pwd -P)" == "$(CDPATH='' cd "$2" 2>/dev/null && pwd -P)" ]]; }
# desired_link <dep> <target> : the link text - relative when the target is the hub layout, else the absolute target
desired_link() {
  local dep="$1" target="$2" parent hub
  parent="$(dirname "${ROOT}")"; hub="$(dirname "${parent}")"
  if [[ "$(basename "${parent}")" == "submodules" && -f "${hub}/Constitution.md" ]]; then
    if [[ "${dep}" == constitution && "${target}" == "${hub}" ]]; then printf '../..'; return; fi
    if [[ "${dep}" != constitution && "${target}" == "${parent}/${dep}" ]]; then printf '../../%s' "${dep}"; return; fi
  fi
  printf '%s' "${target}"
}

rc=0
old_pin() { # <dep> : the gitlink llmctl recorded before 2026-10-21 (override: LLMCTL_ADOPT_PIN_<NAME>)
  local v
  v="LLMCTL_ADOPT_PIN_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  if [[ -n "${!v:-}" ]]; then printf '%s' "${!v}"; return; fi
  case "$1" in
    constitution) printf '8a604628ebf4af9ac19a70014e640edd9024d43b' ;;
    containers)   printf '4a8f04e05f3535d77c48f69b89687f9fcc896fbf' ;;
    superspec)    printf 'c20ac6c1ba069cc9a72dacb8044b7b193d3dde81' ;;
  esac
}
# leftover <dep> <rel> <target> : handle a REAL file/dir at the link path. Returns 0 only when it was adopted
# (the caller then links), 1 otherwise (rc already set).
leftover() {
  local dep="$1" rel="$2" target="$3" path="${ROOT}/$2" head pin dest n=0
  printf 'LEFTOVER %s is a real directory (a checkout left behind by the removed submodule). Not replacing it.\n' "${rel}" >&2
  printf '  Fix: verify `git -C %s status --porcelain` prints nothing (no local work), then `rm -rf %s` and re-run scripts/link_deps.sh;\n' "${path}" "${path}" >&2
  printf '       or opt in with `scripts/link_deps.sh --adopt-leftover %s` (moves a clean pinned submodule worktree aside, deletes nothing).\n' "${dep}" >&2
  if [[ "${adopt}" != 1 || "${check_only}" == 1 ]]; then rc=1; return 1; fi
  if [[ ! -f "${path}/.git" ]]; then printf '  adopt refused: %s has no .git FILE (not a submodule-style worktree)\n' "${rel}" >&2; rc=1; return 1; fi
  if [[ -n "$(git -C "${path}" status --porcelain 2>/dev/null)" ]]; then printf '  adopt refused: %s is not clean (git status --porcelain is non-empty)\n' "${rel}" >&2; rc=1; return 1; fi
  head="$(git -C "${path}" rev-parse HEAD 2>/dev/null || true)"; pin="$(old_pin "${dep}")"
  if [[ -z "${head}" || "${head}" != "${pin}" ]]; then printf '  adopt refused: HEAD %s != the old recorded pin %s\n' "${head:-unreadable}" "${pin}" >&2; rc=1; return 1; fi
  dest="${path}.leftover-$(date +%Y%m%d)"
  while [[ -e "${dest}" ]]; do n=$((n+1)); dest="${path}.leftover-$(date +%Y%m%d)-${n}"; done
  mv "${path}" "${dest}"
  printf 'moved %s -> %s (kept; delete it yourself when you no longer need it)\n' "${rel}" "${dest}"
  return 0
}
link_one() { # <dep-name> <link-path-relative-to-root>
  local dep="$1" rel="$2" target link="${ROOT}/$2" cur want
  if ! target="$(llmctl_resolve_dep "${dep}")"; then rc=1; return 0; fi
  # The resolver's own <root>/... candidate IS this link when it already exists and is valid: it then returns
  # the link's own path. Re-pointing the link at itself would make a self-loop - the link is already correct.
  if [[ -L "${link}" && "${target}" == "${link}" ]]; then
    printf 'ok    %s -> %s (kept)\n' "${rel}" "$(readlink "${link}")"; return 0
  fi
  want="$(desired_link "${dep}" "${target}")"
  if [[ -L "${link}" ]]; then
    cur="$(readlink "${link}")"
    if [[ "${cur}" == "${want}" ]] || same_dir "${link}" "${target}"; then printf 'ok    %s -> %s\n' "${rel}" "${cur}"; return 0; fi
    if [[ "${check_only}" == 1 ]]; then printf 'WRONG %s -> %s (resolver says %s)\n' "${rel}" "${cur}" "${target}" >&2; rc=1; return 0; fi
  elif [[ -e "${link}" ]]; then
    leftover "${dep}" "${rel}" "${target}" || return 0
  elif [[ "${check_only}" == 1 ]]; then
    printf 'MISSING %s (would link to %s)\n' "${rel}" "${target}" >&2; rc=1; return 0
  fi
  mkdir -p "$(dirname "${link}")"
  ln -sfn "${want}" "${link}"
  printf 'link  %s -> %s\n' "${rel}" "${want}"
}

for dep in "${names[@]}"; do
  case "${dep}" in
    constitution) link_one constitution constitution ;;
    containers)   link_one containers submodules/containers ;;
    superspec)    link_one superspec submodules/superspec ;;
    *) printf 'link_deps: unknown dependency "%s"\n' "${dep}" >&2; rc=2 ;;
  esac
done
exit "${rc}"
