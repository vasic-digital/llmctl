#!/usr/bin/env bash
# test_version_consistency.sh - T123 / FR-053: one release version, stated identically everywhere it is stated.
# Single source of truth: the VERSION file. Checked against: bin/llmctl, the CHANGELOG top release heading and its
# required sections, the README release banner, every "llmctl X.Y.Z" statement in docs/*.md, the OpenAPI contract
# info.version (`<VERSION>` or `<VERSION>-draft` until the tag is cut) and the catalog schema version (an integer
# schema number, NOT the release version). The extractor is proven first with a control needle (a planted file with a
# different version MUST be read as different), so an extractor that cannot see says nothing about the tree. A tree
# that disagrees is REPORTED assertion by assertion (every extractor ends in `|| true`, see below): nothing in here may
# abort the run silently, because a silent abort hides which files disagree and skips every later check.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

R="${LLMCTL_ROOT}"
VER="$(tr -d '[:space:]' < "${R}/VERSION")"

# first_semver <file> <ere-prefix>: first "<prefix>X.Y.Z" in the file, X.Y.Z only
first_semver() { grep -oE -m1 "$2[0-9]+\.[0-9]+\.[0-9]+" "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+$' | head -1; }

# The extractors below feed ASSIGNMENTS under `set -e -o pipefail`. A pipeline whose grep finds nothing exits 1 and,
# unguarded, silently killed the whole run at the assignment (found 2026-10-27: a CHANGELOG whose first heading is
# `## Unreleased` has no X.Y.Z, so the run died after 4 assertions with exit 1, no message, and the README, docs and
# OpenAPI checks never ran). Each extractor therefore ends in `|| true`: "nothing found" is an empty string that the
# assertion reports, never an abort.
# changelog_top <file>: the first '## ' heading line of a CHANGELOG ('' when there is none).
changelog_top() { grep -m1 -E '^## ' "$1" | head -1 || true; }
# semver_of <text>: the first X.Y.Z in the text ('' when there is none).
semver_of() { printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true; }

# --- control needle -----------------------------------------------------------------------------------------------
printf 'LLMCTL_VERSION="9.9.9"\n' > "${TEST_TMP}/needle.sh"
needle="$(first_semver "${TEST_TMP}/needle.sh" 'LLMCTL_VERSION="')"
assert_eq "9.9.9" "${needle}" "control needle: extractor sees a planted version"
if [[ "${needle}" != "${VER}" ]]; then rc=0; else rc=1; fi
assert_eq 0 "${rc}" "control needle: planted version differs from VERSION (a mismatch is detectable)"
# Control needles for the failure path itself, exercised as ASSIGNMENTS exactly like the real checks below (a command
# substitution used as an argument would not trip errexit and would prove nothing): a CHANGELOG that starts with
# '## Unreleased' (no version in its first heading) must be READ as '## Unreleased' / '', and a file with no '## '
# heading at all as ''. Both are then reported by the CHANGELOG assertion, never an abort. Un-guarding either
# extractor kills the run on the matching line here.
printf '# Changelog\n\n## Unreleased\n\n* x\n\n## 9.9.9 (2026-01-01)\n' > "${TEST_TMP}/needle_changelog.md"
needle_top="$(changelog_top "${TEST_TMP}/needle_changelog.md")"
assert_eq "## Unreleased" "${needle_top}" "control needle: the CHANGELOG top heading is the first '## ' line, even '## Unreleased'"
needle_top_ver="$(semver_of "${needle_top}")"
assert_eq "" "${needle_top_ver}" "control needle: a versionless top heading reads as an empty version (reported, not an abort)"
printf '# Changelog\n\nno release headings here\n' > "${TEST_TMP}/needle_changelog_none.md"
needle_none="$(changelog_top "${TEST_TMP}/needle_changelog_none.md")"
assert_eq "" "${needle_none}" "control needle: a CHANGELOG without any '## ' heading reads as '' (reported, not an abort)"

# --- VERSION itself -----------------------------------------------------------------------------------------------
if [[ "${VER}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then rc=0; else rc=1; fi
assert_eq 0 "${rc}" "VERSION is plain X.Y.Z (got '${VER}')"

# --- bin/llmctl ---------------------------------------------------------------------------------------------------
assert_eq "${VER}" "$(first_semver "${R}/bin/llmctl" 'LLMCTL_VERSION="')" "bin/llmctl LLMCTL_VERSION equals VERSION"

# --- CHANGELOG ----------------------------------------------------------------------------------------------------
top="$(changelog_top "${R}/CHANGELOG.md")"
top_ver="$(semver_of "${top}")"
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
oa="$(grep -m1 -E '^  version:' "${R}/specs/009-jev-decision-models/contracts/openapi.yaml" | sed -E 's/^  version:[[:space:]]*//' || true)"
case "${oa}" in
  "${VER}"|"${VER}-draft") rc=0 ;;
  *) rc=1 ;;
esac
assert_eq 0 "${rc}" "openapi info.version is ${VER} or ${VER}-draft (got '${oa}')"

# --- catalog: schema version is an integer, not the release version ------------------------------------------------
sv="$(python3 -I -c 'import json,sys; v=json.load(open(sys.argv[1]))["version"]; print(type(v).__name__, v)' "${R}/models/catalog.json")"
assert_eq "int 1" "${sv}" "catalog.json 'version' is the integer schema number (1), not the release version"

test_finish
