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
if [[ "${1:-}" == "--check" ]]; then check_only=1; shift; fi
names=("$@")
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
    printf 'BLOCKED %s exists as a real file/directory; not replacing it (remove it, or set LLMCTL_%s_DIR to it)\n' \
      "${rel}" "$(printf '%s' "${dep}" | tr '[:lower:]' '[:upper:]')" >&2
    rc=1; return 0
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
