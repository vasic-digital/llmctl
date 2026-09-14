#!/usr/bin/env bash
# run_tests.sh - deterministic llmctl test harness.
#
# Anti-bluff methodology: every test is executed as a real subprocess; the
# harness prints the exact command, the raw output, and the captured exit
# code for each test file. The summary table is built from the ACTUAL exit
# codes, and the harness exits non-zero when any test fails.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${TESTS_DIR}/.." && pwd)"

pass=0
fail=0
declare -a results=()

shopt -s nullglob
for t in "${TESTS_DIR}"/test_*.sh; do
  name="$(basename "${t}")"
  cmd="bash ${t}"
  printf '\n======================================================================\n'
  printf 'TEST: %s\nCMD:  %s\n' "${name}" "${cmd}"
  printf -- '----------------------------------------------------------------------\n'
  out="$(cd "${ROOT}" && bash "${t}" 2>&1)" && rc=0 || rc=$?
  printf '%s\n' "${out}"
  printf 'EXIT: %d\n' "${rc}"
  if [[ "${rc}" -eq 0 ]]; then
    results+=("PASS  ${name}")
    pass=$((pass+1))
  else
    results+=("FAIL  ${name} (exit ${rc})")
    fail=$((fail+1))
  fi
done

printf '\n======================================================================\n'
printf 'SUMMARY\n'
printf -- '----------------------------------------------------------------------\n'
for r in ${results[@]+"${results[@]}"}; do printf '%s\n' "${r}"; done
printf -- '----------------------------------------------------------------------\n'
printf 'PASS: %d  FAIL: %d\n' "${pass}" "${fail}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
