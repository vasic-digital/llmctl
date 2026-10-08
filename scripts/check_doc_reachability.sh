#!/usr/bin/env bash
# check_doc_reachability.sh - Constitution 11.4.212: README.md is the entry point of ALL documentation; every markdown
# document under docs/ must be reachable from it, directly or transitively, through markdown links.
#
# Usage:  scripts/check_doc_reachability.sh [--root DIR] [--check-links] [--list]
#   --root DIR      repository root (default: the directory above this script); must hold README.md
#   --check-links   also fail on a link inside a reachable document whose target does not exist
#   --list          print every reachable in-scope document before the summary
# Scope:  docs/**/*.md (the documentation tree). README.md itself is the start node and is not an orphan.
# What counts as a link: an inline markdown link  [text](target)  or  [text](target "title")  in a *.md file.
#   target forms followed: relative paths, ../ paths, #anchors (stripped), a directory (its README.md).
#   not followed: http(s)/mailto/other-scheme targets, non-.md targets (scripts, json, ...), reference-style links,
#   bare backticked paths. A link written inside a code fence is counted like any other (documented limit).
# Output: "ORPHAN: <path>" per unreachable document, then "reachable=<N> orphans=<N> broken=<N>"; with --check-links a
#   "BROKEN: <file> -> <target>" line per dead link.
# Exit: 0 no orphan (and, with --check-links, no broken link); 1 an orphan or broken link; 2 usage / no README.md.
# Portability: bash 3.2 compatible (no associative arrays, no mapfile); needs only grep, sed, sort, find.
set -euo pipefail

root=""; check_links=0; list=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || { echo "check_doc_reachability: --root needs a directory" >&2; exit 2; }; root="$2"; shift 2 ;;
    --check-links) check_links=1; shift ;;
    --list) list=1; shift ;;
    -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "check_doc_reachability: unknown option '$1' (see --help)" >&2; exit 2 ;;
  esac
done
[ -n "${root}" ] || root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -d "${root}" ] || { echo "check_doc_reachability: root '${root}' is not a directory" >&2; exit 2; }
root="$(cd "${root}" && pwd -P)"
[ -f "${root}/README.md" ] || { echo "check_doc_reachability: ${root}/README.md not found (no entry point to check from)" >&2; exit 2; }

tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT
visited="${tmp}/visited"; queue="${tmp}/queue"; broken="${tmp}/broken"
: >"${visited}"; : >"${broken}"
printf '%s\n' "${root}/README.md" >"${queue}"

# abspath <dir> <target-relative-to-dir> -> canonical absolute path (directories and files; missing leaf allowed)
abspath() {
  local d="$1" t="$2" td tb
  case "${t}" in /*) d="/"; t="${t#/}" ;; esac
  td="$(dirname "${t}")"; tb="$(basename "${t}")"
  if (cd "${d}/${td}" 2>/dev/null); then
    printf '%s/%s\n' "$(cd "${d}/${td}" && pwd -P)" "${tb}" | sed 's#//*#/#g; s#/\.$##'
  else
    return 1
  fi
}

# links_of <file> -> one raw link target per line
links_of() {
  grep -o '\]([^)]*)' "$1" 2>/dev/null | sed -e 's/^](//' -e 's/)$//' -e 's/[[:space:]]\{1,\}"[^"]*"$//' -e "s/[[:space:]]\\{1,\\}'[^']*'\$//" \
    -e 's/^<//' -e 's/>$//' || true
}

while [ -s "${queue}" ]; do
  cur="$(head -n 1 "${queue}")"; tail -n +2 "${queue}" >"${queue}.n"; mv "${queue}.n" "${queue}"
  grep -qxF -- "${cur}" "${visited}" && continue
  printf '%s\n' "${cur}" >>"${visited}"
  dir="$(dirname "${cur}")"
  while IFS= read -r raw; do
    [ -n "${raw}" ] || continue
    case "${raw}" in http://*|https://*|mailto:*|ftp://*|"#"*|*://*) continue ;; esac
    t="${raw%%#*}"; t="${t%%\?*}"
    [ -n "${t}" ] || continue
    if ! full="$(abspath "${dir}" "${t}")"; then
      case "${t}" in *.md|*/) printf '%s -> %s\n' "${cur#"${root}"/}" "${raw}" >>"${broken}" ;; esac
      continue
    fi
    if [ -d "${full}" ]; then
      full="${full}/README.md"
      [ -f "${full}" ] || { printf '%s -> %s\n' "${cur#"${root}"/}" "${raw}" >>"${broken}"; continue; }
    fi
    case "${full}" in *.md) ;; *) continue ;; esac
    case "${full}" in "${root}"/*) ;; *) continue ;; esac     # never follow outside the repository
    if [ ! -f "${full}" ]; then printf '%s -> %s\n' "${cur#"${root}"/}" "${raw}" >>"${broken}"; continue; fi
    grep -qxF -- "${full}" "${visited}" || printf '%s\n' "${full}" >>"${queue}"
  done < <(links_of "${cur}")
done

scope="${tmp}/scope"
if [ -d "${root}/docs" ]; then find "${root}/docs" -type f -name '*.md' | sort >"${scope}"; else : >"${scope}"; fi
nreach=0; norph=0
while IFS= read -r f; do
  if grep -qxF -- "${f}" "${visited}"; then
    nreach=$((nreach + 1)); [ "${list}" -eq 1 ] && printf 'REACHABLE: %s\n' "${f#"${root}"/}"
  else
    norph=$((norph + 1)); printf 'ORPHAN: %s\n' "${f#"${root}"/}"
  fi
done <"${scope}"
nbroken=0
if [ "${check_links}" -eq 1 ]; then
  while IFS= read -r b; do [ -n "${b}" ] || continue; nbroken=$((nbroken + 1)); printf 'BROKEN: %s\n' "${b}"; done < <(sort -u "${broken}")
fi
printf 'reachable=%d orphans=%d broken=%d\n' "${nreach}" "${norph}" "${nbroken}"
[ "${norph}" -eq 0 ] && [ "${nbroken}" -eq 0 ] || exit 1
