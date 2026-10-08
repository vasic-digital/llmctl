#!/usr/bin/env bash
# test_version_consistency.sh - T123 / FR-053: one release version, stated identically everywhere it is stated.
# Single source of truth: the VERSION file. Checked against: bin/llmctl, the CHANGELOG top release heading and its
# required sections, the README release banner, every "llmctl X.Y.Z" statement in docs/*.md, the OpenAPI contract
# info.version (`<VERSION>` or `<VERSION>-draft` until the tag is cut) and the catalog schema version (an integer
# schema number, NOT the release version). The extractor is proven first with a control needle (a planted file with a
# different version MUST be read as different), so an extractor that cannot see says nothing about the tree.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

R="${LLMCTL_ROOT}"
VER="$(tr -d '[:space:]' < "${R}/VERSION")"

# first_semver <file> <ere-prefix>: first "<prefix>X.Y.Z" in the file, X.Y.Z only
first_semver() { grep -oE -m1 "$2[0-9]+\.[0-9]+\.[0-9]+" "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+$' | head -1; }

# --- control needle -----------------------------------------------------------------------------------------------
printf 'LLMCTL_VERSION="9.9.9"\n' > "${TEST_TMP}/needle.sh"
needle="$(first_semver "${TEST_TMP}/needle.sh" 'LLMCTL_VERSION="')"
assert_eq "9.9.9" "${needle}" "control needle: extractor sees a planted version"
if [[ "${needle}" != "${VER}" ]]; then rc=0; else rc=1; fi
assert_eq 0 "${rc}" "control needle: planted version differs from VERSION (a mismatch is detectable)"

# --- VERSION itself -----------------------------------------------------------------------------------------------
if [[ "${VER}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then rc=0; else rc=1; fi
assert_eq 0 "${rc}" "VERSION is plain X.Y.Z (got '${VER}')"

# --- bin/llmctl ---------------------------------------------------------------------------------------------------
assert_eq "${VER}" "$(first_semver "${R}/bin/llmctl" 'LLMCTL_VERSION="')" "bin/llmctl LLMCTL_VERSION equals VERSION"

# --- CHANGELOG ----------------------------------------------------------------------------------------------------
top="$(grep -m1 -E '^## ' "${R}/CHANGELOG.md" | head -1)"
top_ver="$(printf '%s' "${top}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
assert_eq "${VER}" "${top_ver}" "CHANGELOG: newest release heading is ${VER} (got: ${top})"
section="$(awk -v v="## ${VER}" 'index($0,v)==1{f=1;next} f&&/^## /{exit} f' "${R}/CHANGELOG.md")"
for h in "### Added" "### Changed" "### Fixed" "### Security" "### Removed" "### Migration notes" "### Known limitations"; do
  assert_contains "${section}" "${h}" "CHANGELOG ${VER} has '${h}'"
done
for kw in "llmctl-decide" "decide scale" "decide calibrate" "probe-order" "completions" "maturity" "llmctl doctor" \
          "status --json" "overhead_mb" "LLMCTL_CTX_" "eviction"; do
  assert_contains "${section}" "${kw}" "CHANGELOG ${VER} documents '${kw}'"
done

# --- README banner ------------------------------------------------------------------------------------------------
assert_file_contains "${R}/README.md" "**Release ${VER}**" "README release banner names ${VER}"

# --- docs: every 'llmctl X.Y.Z' statement -------------------------------------------------------------------------
bad=""
for f in "${R}"/docs/*.md; do
  while IFS= read -r v; do
    if [[ -n "${v}" && "${v}" != "${VER}" ]]; then bad+="$(basename "${f}"):${v} "; fi
  done < <(grep -oE 'llmctl [0-9]+\.[0-9]+\.[0-9]+' "${f}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+$' | sort -u)
done
assert_eq "" "${bad}" "docs/*.md: no 'llmctl X.Y.Z' statement other than ${VER}"

# --- OpenAPI contract ---------------------------------------------------------------------------------------------
oa="$(grep -m1 -E '^  version:' "${R}/specs/009-jev-decision-models/contracts/openapi.yaml" | sed -E 's/^  version:[[:space:]]*//')"
case "${oa}" in
  "${VER}"|"${VER}-draft") rc=0 ;;
  *) rc=1 ;;
esac
assert_eq 0 "${rc}" "openapi info.version is ${VER} or ${VER}-draft (got '${oa}')"

# --- catalog: schema version is an integer, not the release version ------------------------------------------------
sv="$(python3 -I -c 'import json,sys; v=json.load(open(sys.argv[1]))["version"]; print(type(v).__name__, v)' "${R}/models/catalog.json")"
assert_eq "int 1" "${sv}" "catalog.json 'version' is the integer schema number (1), not the release version"

test_finish
