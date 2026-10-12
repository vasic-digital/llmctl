#!/usr/bin/env bash
# bump_version.sh - move every pinned release-version string from the current VERSION to a new X.Y.Z.
#
# Usage: bump_version.sh [--root DIR] [--apply] <new-version X.Y.Z>
#   default is a DRY RUN: prints each file and line that would change; writes nothing.
#   --apply writes the changes (working tree only: never commits, tags or pushes).
#
# Edits (exactly the pins tests/test_version_consistency.sh checks, nothing else):
#   VERSION                          whole file
#   bin/llmctl                       LLMCTL_VERSION="..."
#   README.md                        banner "**Release X.Y.Z**"
#   docs/*.md                        every "llmctl X.Y.Z" statement (the test fails on any other value)
#   specs/009-jev-decision-models/contracts/openapi.yaml   info.version (also strips a -draft suffix)
#   docs/calibration-tool-fields.md  "contract version `X.Y.Z`" / "is versioned `X.Y.Z`"
# NOT edited (manual, listed at the end): CHANGELOG.md (new section with its required sub-headings), README prose
#   ("Status in X.Y.Z" table, llama.cpp pin sentence), historical docs, llmctld/cmd/llmctld/main.go (own version, 0.1.0).
# Dependencies: bash, sed, grep. Exit 0 ok, 2 usage, 1 refused (same/older version, or a pin was not found).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; APPLY=0; NEW=""
while (($#)); do
  case "$1" in
    --root) ROOT="$(cd "$2" && pwd)"; shift 2;;
    --apply) APPLY=1; shift;;
    -*) echo "bump_version.sh: unknown flag $1" >&2; exit 2;;
    *) NEW="$1"; shift;;
  esac
done
[[ "${NEW}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: bump_version.sh [--root DIR] [--apply] X.Y.Z" >&2; exit 2; }
OLD="$(tr -d '[:space:]' < "${ROOT}/VERSION")"
[[ "${OLD}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bump_version.sh: VERSION is not X.Y.Z ('${OLD}')" >&2; exit 1; }
[[ "${OLD}" != "${NEW}" ]] || { echo "bump_version.sh: VERSION is already ${NEW}" >&2; exit 1; }
[[ "$(printf '%s\n%s\n' "${OLD}" "${NEW}" | sort -V | head -1)" == "${OLD}" ]] || { echo "bump_version.sh: ${NEW} is older than ${OLD}" >&2; exit 1; }
OLDRE="${OLD//./\\.}"
OA="specs/009-jev-decision-models/contracts/openapi.yaml"
echo "bump ${OLD} -> ${NEW} (root ${ROOT}) $([[ ${APPLY} == 1 ]] && echo APPLY || echo DRY-RUN)"
miss=0
# edit <file> <grep-ere that must match before> <sed-expr>
edit() {
  local f="${ROOT}/$1" pat="$2" expr="$3"
  if [[ ! -f "${f}" ]] || ! grep -qE "${pat}" "${f}"; then echo "MISSING pin in $1 (pattern: ${pat})" >&2; miss=1; return; fi
  grep -nE "${pat}" "${f}" | sed "s|^|  $1:|" | cut -c1-150
  if ((APPLY)); then sed -i -E "${expr}" "${f}"; fi
}
edit bin/llmctl '^LLMCTL_VERSION="'"${OLDRE}"'"' 's/^(LLMCTL_VERSION=")'"${OLDRE}"'(")/\1'"${NEW}"'\2/'
edit README.md '\*\*Release '"${OLDRE}"'\*\*' 's/\*\*Release '"${OLDRE}"'\*\*/**Release '"${NEW}"'**/'
edit "${OA}" '^  version: '"${OLDRE}"'(-draft)?[[:space:]]*$' 's/^(  version: )'"${OLDRE}"'(-draft)?[[:space:]]*$/\1'"${NEW}"'/'
for f in "${ROOT}"/docs/*.md; do
  b="docs/$(basename "${f}")"
  if grep -qE 'llmctl '"${OLDRE}"'([^0-9.]|$)' "${f}"; then edit "${b}" 'llmctl '"${OLDRE}"'([^0-9.]|$)' 's/llmctl '"${OLDRE}"'([^0-9.]|$)/llmctl '"${NEW}"'\1/g'; fi
done
if grep -qE 'contract version `'"${OLDRE}"'(-draft)?`|versioned `'"${OLDRE}"'(-draft)?`' "${ROOT}/docs/calibration-tool-fields.md"; then
  edit docs/calibration-tool-fields.md 'version `'"${OLDRE}"'(-draft)?`|versioned `'"${OLDRE}"'(-draft)?`' 's/(contract version `|versioned `)'"${OLDRE}"'(-draft)?`/\1'"${NEW}"'`/g'
fi
if ((APPLY)); then printf '%s\n' "${NEW}" > "${ROOT}/VERSION"; fi
echo "  VERSION: ${OLD} -> ${NEW}"
((miss==0)) || { echo "bump_version.sh: at least one pin was not found; nothing is guaranteed consistent" >&2; exit 1; }
echo "MANUAL: CHANGELOG.md needs a new '## ${NEW} (YYYY-MM-DD)' section ABOVE '## ${OLD}' with ### Added/Changed/Fixed/Security/Removed/Migration notes/Known limitations"
echo "MANUAL: README prose still naming ${OLD} (status table, llama.cpp pin sentence); llmctld/cmd/llmctld/main.go keeps its own 0.1.0"
echo "THEN: bash tests/test_version_consistency.sh"
