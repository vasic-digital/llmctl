#!/usr/bin/env bash
# test_no_retired_vars.sh - retired decision-layer variables are gone from every PRODUCTION path (task T025, gap G-051).
#   LLMCTL_DECIDE_BACKEND_HOST/PORT   redirected user state to another host (D-11)
#   LLMCTL_ONNX_FAKE                  fake-model test seam that could mark a download "verified" (D-12)
#   LLMCTL_DECIDE_API_KEY             replaced by the single LLMCTL_API_KEY (FR-057)
#   LLMCTL_DECIDE_INTERNAL_KEY        engine key in the environment (visible in /proc/<pid>/environ, G-040) -> key FILES
# Production code (bin, lib, scripts, templates, models, Makefile, non-test Go and Python) must not mention them at all.
# Docs and tests may mention them only on a line that says they are retired/removed/ignored/historical (negative
# assertions and migration notes), or in an allow-listed file up to a PINNED number of mentions. A control needle proves
# the scanner sees a planted production hit.
# .claude/ is agent tool state (worktree copies of specs/ live there), never product code.
# C3-13: the production scan skips only the TOP-LEVEL docs/, tests/, specs/, build/, submodules/, constitution/ (and .git /
# node_modules anywhere). A directory merely NAMED tests/, docs/ or build/ deeper in the tree (lib/tests/, scripts/build/)
# is production and is scanned. An allow-list entry is "path:N": the file may mention a retired name at most N times, so a
# NEW mention in an allow-listed file is still caught.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
cd "${LLMCTL_ROOT}"

RETIRED='LLMCTL_DECIDE_BACKEND_(HOST|PORT)|LLMCTL_ONNX_FAKE|LLMCTL_DECIDE_API_KEY|LLMCTL_DECIDE_INTERNAL_KEY([^A-Za-z0-9_]|$)'
EXPLAIN='retired|removed|no longer|ignored|historical|migration|must not|never|forbidden|negative|absent|gone|legacy|scrub|has no effect|deleted|refuse'
TOP_EXCLUDED=" .git .claude submodules constitution specs docs tests build node_modules evidence "

scan_production() { # $1 = root dir to scan -> prints offending file:line (paths prefixed with $1/)
  local e base
  for e in "$1"/* "$1"/.[!.]*; do
    [[ -e "${e}" ]] || continue
    base="${e##*/}"
    case "${TOP_EXCLUDED}" in *" ${base} "*) continue ;; esac
    grep -rInE "${RETIRED}" "${e}" --exclude-dir=.git --exclude-dir=node_modules \
      --exclude='*_test.go' --exclude='CHANGELOG.md' 2>/dev/null || true
  done
}

# check_named <root> <allow-entry...>: hits in docs/tests/changelog/internal/cmd/README that are neither on an explaining
# line nor inside an allow-listed file's pinned budget. Prints the offenders.
check_named() {
  local root="$1"; shift
  local -a allow=("$@")
  local hit file line a n cnt bad="" f
  local counts=$'\n'
  while IFS= read -r hit; do
    [[ -z "${hit}" ]] && continue
    file="${hit%%:*}"
    [[ "${file}" == "tests/test_no_retired_vars.sh" ]] && continue
    line="${hit#*:*:}"
    f=""; for a in ${allow[@]+"${allow[@]}"}; do [[ "${a%:*}" == "${file}" ]] && f="${a}"; done
    if [[ -n "${f}" ]]; then
      counts+="${file}"$'\n'
      continue
    fi
    grep -qiE "${EXPLAIN}" <<<"${line}" || bad+="${hit}"$'\n'
  done < <(cd "${root}" && grep -rInE "${RETIRED}" docs tests CHANGELOG.md internal cmd README.md 2>/dev/null || true)
  for a in ${allow[@]+"${allow[@]}"}; do
    file="${a%:*}"; n="${a##*:}"
    cnt="$(grep -c -x -F -- "${file}" <<<"${counts}" || true)"
    [[ "${cnt}" -le "${n}" ]] || bad+="${file}: ${cnt} mention(s) of a retired variable, the allow-list pins ${n}"$'\n'
  done
  printf '%s' "${bad}"
}

# --- control needles: planted production hits must be reported by the same scanner ---
ctl="$(mktemp -d)"; trap 'rm -rf "${ctl}"' EXIT
mkdir -p "${ctl}/lib" "${ctl}/lib/tests" "${ctl}/scripts/build" "${ctl}/docs" "${ctl}/tests"
printf 'export LLMCTL_ONNX_FAKE=1\n' > "${ctl}/lib/planted.sh"
printf 'export LLMCTL_ONNX_FAKE=1\n' > "${ctl}/lib/tests/planted_deep.sh"
printf 'export LLMCTL_DECIDE_API_KEY=x\n' > "${ctl}/scripts/build/planted_deep.sh"
printf 'LLMCTL_ONNX_FAKE=1\n' > "${ctl}/docs/top_level_doc.md"
printf 'LLMCTL_ONNX_FAKE=1\n' > "${ctl}/tests/top_level_test.sh"
hits="$(scan_production "${ctl}")"
assert_contains "${hits}" "lib/planted.sh" "control: scanner sees a planted production hit"
assert_contains "${hits}" "lib/tests/planted_deep.sh" "C3-13: a production file under a directory merely NAMED tests/ (lib/tests/) is scanned"
assert_contains "${hits}" "scripts/build/planted_deep.sh" "C3-13: a production file under a directory merely NAMED build/ (scripts/build/) is scanned"
case "${hits}" in *top_level_doc.md*|*top_level_test.sh*) assert_eq "absent" "present" "control: the TOP-LEVEL docs/ and tests/ are not part of the production scan" ;; *) assert_eq 0 0 "control: the TOP-LEVEL docs/ and tests/ are not part of the production scan" ;; esac

# the allow-list budget: exactly the pinned mentions pass, one more fails
mkdir -p "${ctl}/r/tests" "${ctl}/r/docs" "${ctl}/r/internal" "${ctl}/r/cmd"
printf 'a LLMCTL_ONNX_FAKE b\nc LLMCTL_ONNX_FAKE d\n' > "${ctl}/r/tests/test_x.sh"
assert_eq "" "$(check_named "${ctl}/r" "tests/test_x.sh:2")" "C3-13 control: a file within its pinned mention budget passes"
assert_contains "$(check_named "${ctl}/r" "tests/test_x.sh:1")" "tests/test_x.sh: 2 mention(s)" "C3-13: a NEW mention beyond the pinned budget in an allow-listed file FAILS"
assert_contains "$(check_named "${ctl}/r")" "tests/test_x.sh:1" "C3-13: a file that is not allow-listed and does not explain the retirement FAILS"
printf 'LLMCTL_ONNX_FAKE is retired and has no effect\n' > "${ctl}/r/docs/note.md"
assert_eq "" "$(check_named "${ctl}/r" "tests/test_x.sh:2")" "C3-13 control: a doc line that says it is retired still passes"

# --- production paths: zero mentions ---
prod_hits="$(scan_production "${LLMCTL_ROOT}")"
assert_eq "" "${prod_hits}" "no production file names a retired variable"

# --- docs/tests/changelog: only files that are ABOUT the retirement may name the variables, up to a pinned count ---
# Allow-list "path:N" with the reason each file legitimately names them (negative assertions set the retired variable to
# prove it has NO effect; the changelog carries the migration table; docs/scripts pages describe those tests).
allowed=(
  CHANGELOG.md:5                                  # migration table: old name -> new name
  docs/CONTINUATION.md:4                          # historical session log (marked HISTORICAL)
  docs/qa/decision-models-validation/README.md:2  # historical QA archive (marked HISTORICAL)
  docs/qa/decision-models-validation/iter2-test-output.txt:4  # captured historical test output
  docs/scripts/test_onnx_server.md:2              # describes the negative assertions of tests/test_onnx_server.sh
  docs/scripts/test_no_retired_vars.md:4          # generated page quoting this guard's own header (one line per retired variable)
  docs/scripts/test_regression_defects.md:1       # describes the regression groups
  tests/test_regression_defects.sh:1              # regression groups for D-11/D-12/D-29
  tests/test_onnx_server.sh:2 tests/test_onnx_runtime.sh:3 tests/fixtures/onnx_rt_contract.py:1  # runtime ignores the old variables
  tests/test_decide.sh:1 tests/test_decide_cli.sh:1  # lib/decide.sh must never touch the key / retired names
  tests/test_registry_cli.sh:1 tests/test_scheduler.sh:1  # secrets-not-leaked checks that export the retired name on purpose
  internal/registry/cli_test.go:1                 # same: planted retired variable must not reach output
  internal/gateway/keyfile_test.go:4              # the repo-wide "no code reads the key from the environment" test
)
bad="$(check_named "${LLMCTL_ROOT}" "${allowed[@]}")"
assert_eq "" "${bad}" "no other file names a retired variable without saying it is retired (allow-listed files within their pinned counts)"
test_finish
