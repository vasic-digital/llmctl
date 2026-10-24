#!/usr/bin/env bash
# resolve_deps.sh - the ONE place that locates llmctl's non-vendored dependencies:
#   constitution  (the Helix Constitution hub),
#   containers    (vasic-digital/Containers, Go module digital.vasic.containers),
#   superspec     (WangX0111/superspec Spec Kit extension).
#
# Why this exists (owner mandate 2026-10-21, "one source of truth, always the latest"): llmctl used to carry
# its own pinned `constitution`, `submodules/containers` and `submodules/superspec` submodules. llmctl lives
# INSIDE the constitution hub (constitution/submodules/llmctl), so its nested `constitution` created a
# mutual-reference cycle (hub -> llmctl -> hub). The hub now vendors `containers` and `superspec` under
# <hub>/submodules/<name> (owner decision 2026-10-21), so llmctl no longer pins private copies: it resolves
# them. llmctl's own real dependencies (submodules/llama.cpp, submodules/colibri) are still ordinary submodules.
#
# Usage:
#   bash lib/resolve_deps.sh <constitution|containers|superspec>   # prints the absolute path, exit 0
#   bash lib/resolve_deps.sh --all                                 # prints name=path lines; exit 1 if any unresolved
#   source lib/resolve_deps.sh; llmctl_resolve_dep containers      # function form (no shell options are changed)
#
# Resolution order (first candidate that passes its marker check wins):
#   1. env override  LLMCTL_CONSTITUTION_DIR / LLMCTL_CONTAINERS_DIR / LLMCTL_SUPERSPEC_DIR. A relative value is
#      made absolute. An override that is empty or does not pass the marker check is an ERROR (exit 1), never a
#      silent fall-through to another location.
#   2. the parent hub, when llmctl is nested at <hub>/submodules/llmctl (hub = ../.. and holds Constitution.md):
#      constitution = <hub>; containers/superspec = <hub>/submodules/<name> (= ../<name>, vendored by the hub).
#      This step comes BEFORE step 3 (pinned by a fixture in tests/test_resolve_deps.sh).
#   3. <root>/constitution and <root>/submodules/<name>  (root = this llmctl checkout: a consumer's own copy,
#      Constitution section 11.4.76, or the symlinks made by scripts/link_deps.sh).
#   4. sibling clones  <root>/../constitution, <root>/../containers, <root>/../superspec  (standalone use).
#   5. ancestor walk: for every ancestor A of <root>: A/constitution, A/submodules/constitution (constitution
#      - the semantics of the hub's find_constitution.sh), A/submodules/<name>, A/constitution/submodules/<name>.
#      BOUNDED: the walk stops BEFORE any directory named .cache (a cache is never a source), AFTER
#      LLMCTL_RESOLVE_STOP_AT when set, and AFTER $HOME. (A stray ~/.cache/submodules/<name> used to satisfy it.)
#   6. host fallback (constitution ONLY) - OPT-IN: only when LLMCTL_HOST_FALLBACK_DIR is set. There is no
#      built-in host path (a host-specific literal does not belong in a shared library).
#
# A real <root>/constitution or <root>/submodules/<name> directory (the checkout git leaves behind when a submodule
# gitlink is removed) is warned about on stderr whenever it exists, used or not.
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
  here="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  (CDPATH='' cd "${here}/.." && pwd)
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
_llmctl_rd_norm() { (CDPATH='' cd "$1" 2>/dev/null && pwd); }

# _llmctl_rd_candidates <name> <root> : candidate directories in resolution order (steps 2-6), one per line
_llmctl_rd_candidates() {
  local name="$1" root="$2" parent hub a
  parent="$(dirname "${root}")"
  hub="$(dirname "${parent}")"
  # 2. the parent hub (step-2-begin)
  if [[ "$(basename "${parent}")" == "submodules" && -f "${hub}/Constitution.md" ]]; then
    if [[ "${name}" == "constitution" ]]; then printf '%s\n' "${hub}"; else printf '%s\n' "${parent}/${name}"; fi
  fi
  # (step-2-end)
  # 3. <root>/constitution, <root>/submodules/<name>
  if [[ "${name}" == "constitution" ]]; then printf '%s\n' "${root}/constitution"; else printf '%s\n' "${root}/submodules/${name}"; fi
  # 4. siblings
  printf '%s\n' "${parent}/${name}"
  # 5. ancestor walk
  # The walk is BOUNDED (3.3.0 review): it never examines a directory named .cache (a cache is not a source of truth; a
  # stray ~/.cache/submodules/<name> must not satisfy resolution) or anything above it, stops after
  # LLMCTL_RESOLVE_STOP_AT (inclusive) when that is set, and stops after $HOME (inclusive).
  a="${parent}"
  while [[ -n "${a}" ]]; do
    [[ "$(basename "${a}")" == ".cache" ]] && break
    if [[ "${name}" == "constitution" ]]; then
      printf '%s\n' "${a}/constitution" "${a}/submodules/constitution"
    else
      printf '%s\n' "${a}/submodules/${name}" "${a}/constitution/submodules/${name}"
    fi
    [[ "${a}" == "/" ]] && break
    [[ -n "${LLMCTL_RESOLVE_STOP_AT:-}" && "${a}" == "${LLMCTL_RESOLVE_STOP_AT%/}" ]] && break
    [[ -n "${HOME:-}" && "${a}" == "${HOME%/}" ]] && break
    a="$(dirname "${a}")"
  done
  # 6. host fallback (constitution only)
  if [[ "${name}" == "constitution" && -n "${LLMCTL_HOST_FALLBACK_DIR:-}" ]]; then
    printf '%s\n' "${LLMCTL_HOST_FALLBACK_DIR}"
  fi
}

# _llmctl_rd_warn_leftover <name> <root> <resolved> : a REAL (non-symlink) <root>/constitution or
# <root>/submodules/<name> is almost always the checkout left behind when the gitlink was removed (git does not
# delete a populated submodule worktree). Warn on stderr - whether it is the answer or is shadowed by a better one.
_llmctl_rd_warn_leftover() {
  local name="$1" root="$2" resolved="$3" legacy
  if [[ "${name}" == "constitution" ]]; then legacy="${root}/constitution"; else legacy="${root}/submodules/${name}"; fi
  [[ -d "${legacy}" && ! -L "${legacy}" ]] || return 0
  if [[ "${resolved}" == "${legacy}" ]]; then
    printf 'llmctl: WARNING: %s is a real directory (a leftover of the removed %s submodule?); using it. Prefer LLMCTL_%s_DIR=<a clean clone OUTSIDE this repository> (see docs/dependency-layout.md).\n' "${legacy}" "${name}" "$(printf '%s' "${name}" | tr '[:lower:]' '[:upper:]')" >&2
  else
    printf 'llmctl: WARNING: %s is a real directory (a leftover of the removed %s submodule?) but %s wins; the leftover is ignored. Once nothing in it is needed (docs/dependency-layout.md says how to check), delete it.\n' "${legacy}" "${name}" "${resolved}" >&2
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
  if [[ -n "${!var+x}" ]]; then
    override="${!var}"
    if [[ -z "${override}" ]]; then
      printf 'llmctl: %s is set but empty; unset it or give a directory - not falling back silently\n' "${var}" >&2
      return 1
    fi
    case "${override}" in
      /*) ;;
      *) override="$(CDPATH='' cd "${override}" 2>/dev/null && pwd || printf '%s/%s' "$(pwd)" "${override}")" ;;
    esac
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
      _llmctl_rd_warn_leftover "${name}" "${root}" "${norm:-${cand}}"
      printf '%s\n' "${norm:-${cand}}"
      return 0
    fi
  done < <(_llmctl_rd_candidates "${name}" "${root}")
  printf 'llmctl: cannot resolve %s. Looked (in order): %s, the parent hub, %s, sibling dirs, ancestor dirs%s.\n' \
    "${name}" "${var}" "${root}/$([[ ${name} == constitution ]] && echo constitution || echo "submodules/${name}")" \
    "$([[ ${name} == constitution ]] && echo ", LLMCTL_HOST_FALLBACK_DIR if set")" >&2
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
