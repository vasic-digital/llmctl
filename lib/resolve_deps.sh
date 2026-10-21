#!/usr/bin/env bash
# resolve_deps.sh - the ONE place that locates llmctl's non-vendored dependencies:
#   constitution  (the Helix Constitution hub),
#   containers    (vasic-digital/Containers, Go module digital.vasic.containers),
#   superspec     (WangX0111/superspec Spec Kit extension).
#
# Why this exists (owner mandate 2026-10-21, "one source of truth, always the latest"): llmctl used to carry
# its own pinned `constitution`, `submodules/containers` and `submodules/superspec` submodules. llmctl lives
# INSIDE the constitution hub (constitution/submodules/llmctl), so its nested `constitution` created a
# mutual-reference cycle (hub -> llmctl -> hub), and `containers`/`superspec` duplicated the hub's own flat
# copies. They are now resolved at run time from the single copy that exists on the host. llmctl's own real
# dependencies (submodules/llama.cpp, submodules/colibri) are still ordinary submodules.
#
# Usage:
#   bash lib/resolve_deps.sh <constitution|containers|superspec>   # prints the absolute path, exit 0
#   bash lib/resolve_deps.sh --all                                 # prints name=path lines; exit 1 if any unresolved
#   source lib/resolve_deps.sh; llmctl_resolve_dep containers      # function form (no shell options are changed)
#
# Resolution order (first candidate that passes its marker check wins):
#   1. env override  LLMCTL_CONSTITUTION_DIR / LLMCTL_CONTAINERS_DIR / LLMCTL_SUPERSPEC_DIR. An override that
#      does not pass the marker check is an ERROR (exit 1), never a silent fall-through to another location.
#   2. the parent hub, when llmctl is nested at <hub>/submodules/llmctl (hub = ../.. and holds Constitution.md):
#      constitution = <hub>; containers/superspec = <hub>/submodules/<name> (= ../<name>).
#   3. <root>/constitution and <root>/submodules/<name>  (root = this llmctl checkout; usually the symlinks
#      made by scripts/link_deps.sh).
#   4. sibling directories  <root>/../constitution, <root>/../containers, <root>/../superspec.
#   5. ancestor walk: for every ancestor A of <root>: A/constitution, A/submodules/constitution (constitution
#      - the semantics of the hub's find_constitution.sh), A/submodules/<name>, A/constitution/submodules/<name>.
#   6. host fallback (constitution ONLY): ${LLMCTL_HOST_FALLBACK_DIR:-/home/milosvasic/Projects/helix_code/constitution}.
#
# Marker checks (so an empty directory or a different project is never accepted):
#   constitution: Constitution.md exists;  containers: go.mod declares `module digital.vasic.containers`;
#   superspec: extension.yml exists.
#
# Exit codes: 0 resolved (path on stdout); 1 not resolved / bad override (actionable message on stderr, stdout
# empty); 2 usage error.
#
# Side effects: none (read-only). Dependencies: bash >= 3.2 (macOS-compatible), grep, dirname.
# Cross-references: scripts/link_deps.sh (creates the ignored symlinks used by go.mod and the carriers'
# `@constitution/CLAUDE.md` import), tests/test_resolve_deps.sh (the proof), docs/dependency-layout.md.

# _llmctl_rd_root: absolute path of the llmctl checkout this library belongs to.
_llmctl_rd_root() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  (cd "${here}/.." && pwd)
}

# _llmctl_rd_valid <name> <dir> : marker check
_llmctl_rd_valid() {
  local name="$1" dir="$2"
  [[ -d "${dir}" ]] || return 1
  case "${name}" in
    constitution) [[ -f "${dir}/Constitution.md" ]] ;;
    containers)   [[ -f "${dir}/go.mod" ]] && grep -qE '^module[[:space:]]+digital\.vasic\.containers[[:space:]]*$' "${dir}/go.mod" ;;
    superspec)    [[ -f "${dir}/extension.yml" ]] ;;
    *) return 1 ;;
  esac
}

# _llmctl_rd_norm <dir> : absolute, '..'-free form of an existing directory (symlinks are NOT resolved)
_llmctl_rd_norm() { (cd "$1" 2>/dev/null && pwd); }

# _llmctl_rd_candidates <name> <root> : candidate directories in resolution order (steps 2-6), one per line
_llmctl_rd_candidates() {
  local name="$1" root="$2" parent hub a
  parent="$(dirname "${root}")"
  hub="$(dirname "${parent}")"
  # 2. the parent hub
  if [[ "$(basename "${parent}")" == "submodules" && -f "${hub}/Constitution.md" ]]; then
    if [[ "${name}" == "constitution" ]]; then printf '%s\n' "${hub}"; else printf '%s\n' "${parent}/${name}"; fi
  fi
  # 3. <root>/constitution, <root>/submodules/<name>
  if [[ "${name}" == "constitution" ]]; then printf '%s\n' "${root}/constitution"; else printf '%s\n' "${root}/submodules/${name}"; fi
  # 4. siblings
  printf '%s\n' "${parent}/${name}"
  # 5. ancestor walk
  a="${parent}"
  while [[ -n "${a}" ]]; do
    if [[ "${name}" == "constitution" ]]; then
      printf '%s\n' "${a}/constitution" "${a}/submodules/constitution"
    else
      printf '%s\n' "${a}/submodules/${name}" "${a}/constitution/submodules/${name}"
    fi
    [[ "${a}" == "/" ]] && break
    a="$(dirname "${a}")"
  done
  # 6. host fallback (constitution only)
  if [[ "${name}" == "constitution" ]]; then
    printf '%s\n' "${LLMCTL_HOST_FALLBACK_DIR:-/home/milosvasic/Projects/helix_code/constitution}"
  fi
}

# llmctl_resolve_dep <name> : print the absolute path of the dependency; return 1 (message on stderr) otherwise.
llmctl_resolve_dep() {
  local name="${1:-}" root var override cand norm
  case "${name}" in
    constitution|containers|superspec) ;;
    *) printf 'llmctl_resolve_dep: unknown dependency "%s" (want constitution|containers|superspec)\n' "${name}" >&2; return 2 ;;
  esac
  var="LLMCTL_$(printf '%s' "${name}" | tr '[:lower:]' '[:upper:]')_DIR"
  override="${!var:-}"
  if [[ -n "${override}" ]]; then
    if _llmctl_rd_valid "${name}" "${override}"; then
      printf '%s\n' "${override}"
      return 0
    fi
    printf 'llmctl: %s=%s is set but is not a valid %s directory (marker check failed); fix or unset it - not falling back silently\n' \
      "${var}" "${override}" "${name}" >&2
    return 1
  fi
  root="$(_llmctl_rd_root)"
  while IFS= read -r cand; do
    [[ -n "${cand}" ]] || continue
    if _llmctl_rd_valid "${name}" "${cand}"; then
      norm="$(_llmctl_rd_norm "${cand}")"
      printf '%s\n' "${norm:-${cand}}"
      return 0
    fi
  done < <(_llmctl_rd_candidates "${name}" "${root}")
  printf 'llmctl: cannot resolve %s. Looked (in order): %s, the parent hub, %s, sibling dirs, ancestor dirs%s.\n' \
    "${name}" "${var}" "${root}/$([[ ${name} == constitution ]] && echo constitution || echo "submodules/${name}")" \
    "$([[ ${name} == constitution ]] && echo ", host fallback")" >&2
  printf '  Fix: set %s=/absolute/path, or place llmctl at <hub>/submodules/llmctl inside the constitution hub, or put %s next to llmctl.\n' "${var}" "${name}" >&2
  return 1
}

# Executable form
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  case "${1:-}" in
    constitution|containers|superspec) llmctl_resolve_dep "$1" ;;
    --all)
      rc=0
      for _d in constitution containers superspec; do
        if _p="$(llmctl_resolve_dep "${_d}")"; then printf '%s=%s\n' "${_d}" "${_p}"; else rc=1; fi
      done
      exit "${rc}" ;;
    *) printf 'usage: resolve_deps.sh <constitution|containers|superspec>|--all\n' >&2; exit 2 ;;
  esac
fi
