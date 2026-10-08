#!/usr/bin/env bash
# run_tests.sh - deterministic llmctl test harness.
#
# Anti-bluff methodology: every test is executed as a real subprocess; the
# harness prints the exact command, the raw output, and the captured exit
# code for each test file. The summary table is built from the ACTUAL exit
# codes, and the harness exits non-zero when any test fails.
#
# SKIP contract (C-20): a skipped test is NOT a pass. A test file that cannot run on this host
# (no go / podman / network ...) prints a line starting exactly `SKIP-SUITE: <reason>` and exits 0;
# the harness then reports it as SKIP (own counter, own list with the reason in the summary), not
# PASS. A test that ran but skipped individual assertions prints `  SKIP: <message>` lines
# (helpers.sh assert_skip); it still PASSes but is listed as "PASS (n skipped assertions)" and the
# total is summarised.
# Lost-counter guard (C2-06): a suite that exits 0 but printed a `  FAIL:` line (an assertion run in a
# subshell, whose TEST_FAILS increment is lost) is reported FAIL. `SKIP-SUITE:` is honoured only when it
# is emitted BEFORE any assertion line (`  ok:` / `  FAIL:`): a suite that already asserted something must
# not skip, so SKIP-SUITE after an assertion is reported FAIL, never SKIP. A test that asserted nothing but skipped (no `  ok:` line at all, at least one
# `  SKIP:`) is reported SKIP too. A SKIP never fails the run; it is never hidden either.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${TESTS_DIR}/.." && pwd)"

esc="$(printf '\033')"
pass=0
fail=0
skip=0
partial=0
declare -a results=()
declare -a skips=()

shopt -s nullglob
for t in "${TESTS_DIR}"/test_*.sh; do
  name="$(basename "${t}")"
  cmd="bash ${t}"
  printf '\n======================================================================\n'
  printf 'TEST: %s\nCMD:  %s\n' "${name}" "${cmd}"
  printf -- '----------------------------------------------------------------------\n'
  out="$(cd "${ROOT}" && bash "${t}" 2>&1)" && rc=0 || rc=$?
  printf 'OUTPUT:\n%s\n' "${out}"
  printf 'EXIT: %d\n' "${rc}"
  # C3-11: judge a copy without ANSI colour codes; a FAIL line is any indented `FAIL:` (spaces or tab, with or without
  # a space after the colon), so a coloured / tab-indented / unspaced failure is not invisible.
  plain="$(sed "s/${esc}\[[0-9;]*m//g" <<<"${out}")"
  # line numbers of the first SKIP-SUITE marker and of the first / last assertion line (0 = none)
  skip_ln="$(grep -n '^SKIP-SUITE: ' <<<"${plain}" | head -1 | cut -d: -f1 || true)"
  assert_ln="$(grep -nE '^[[:space:]]+(ok|FAIL):' <<<"${plain}" | head -1 | cut -d: -f1 || true)"
  last_assert_ln="$(grep -nE '^[[:space:]]+(ok|FAIL):' <<<"${plain}" | tail -1 | cut -d: -f1 || true)"
  nfail_lines="$(grep -cE '^[[:space:]]+FAIL:' <<<"${plain}" || true)"
  nok_lines="$(grep -cE '^[[:space:]]+ok:' <<<"${plain}" || true)"
  nskipasrt_lines="$(grep -cE '^[[:space:]]+SKIP:' <<<"${plain}" || true)"
  if [[ "${rc}" -eq 0 && "${nfail_lines}" -gt 0 ]]; then
    results+=("FAIL  ${name} (exit 0 but ${nfail_lines} '  FAIL:' line(s): an assertion failure was lost)")
    fail=$((fail+1))
  elif [[ "${rc}" -eq 0 ]] && grep -qE '^RESULT: FAIL' <<<"${plain}"; then
    results+=("FAIL  ${name} (exit 0 but the suite printed 'RESULT: FAIL')")
    fail=$((fail+1))
  elif [[ "${rc}" -eq 0 && -n "${skip_ln}" && -n "${assert_ln}" && "${assert_ln}" -lt "${skip_ln}" ]]; then
    results+=("FAIL  ${name} (SKIP-SUITE after assertions already ran: a suite that asserted must not skip)")
    fail=$((fail+1))
  elif [[ "${rc}" -eq 0 && -n "${skip_ln}" && -n "${last_assert_ln}" && "${last_assert_ln}" -gt "${skip_ln}" ]]; then
    results+=("FAIL  ${name} (assertions ran AFTER SKIP-SUITE: a skipped suite must stop)")
    fail=$((fail+1))
  elif [[ "${rc}" -eq 0 && -n "${skip_ln}" ]]; then
    reason="$(printf '%s\n' "${out}" | sed -n 's/^SKIP-SUITE: //p' | head -1)"
    results+=("SKIP  ${name} (${reason})")
    skips+=("${name}: ${reason}")
    skip=$((skip+1))
  elif [[ "${rc}" -eq 0 ]] && ! grep -q '^  ok: ' <<<"${out}" && grep -q '^  SKIP: ' <<<"${out}"; then
    # ran, asserted nothing, skipped something: that is a skipped suite whatever its RESULT line says
    reason="$(sed -n 's/^    reason: //p' <<<"${out}" | head -1)"
    results+=("SKIP  ${name} (every assertion skipped: ${reason})")
    skips+=("${name}: every assertion skipped: ${reason}")
    skip=$((skip+1))
  elif [[ "${rc}" -eq 0 && "${nok_lines}" -eq 0 && "${nskipasrt_lines}" -eq 0 ]]; then
    # C3-11: exit 0 with no `  ok:` line, no SKIP and no SKIP-SUITE proves nothing (a silent suite, a wrong path, an
    # early `exit 0`): it asserted nothing, so it is a FAIL, never a PASS.
    results+=("FAIL  ${name} (exit 0 but the suite asserted nothing: no '  ok:' line, no SKIP)")
    fail=$((fail+1))
  elif [[ "${rc}" -eq 0 ]]; then
    nskip="$(printf '%s\n' "${out}" | grep -c '^  SKIP: ' || true)"
    if [[ "${nskip}" -gt 0 ]]; then
      results+=("PASS  ${name} (${nskip} skipped assertion(s))")
      partial=$((partial+nskip))
    else
      results+=("PASS  ${name}")
    fi
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
if [[ "${skip}" -gt 0 ]]; then
  printf 'NOT RUN (skipped suites, not passes):\n'
  for r in "${skips[@]}"; do printf '  %s\n' "${r}"; done
fi
[[ "${partial}" -gt 0 ]] && printf 'skipped assertions inside passing suites: %d\n' "${partial}"
printf 'PASS: %d  FAIL: %d  SKIP: %d\n' "${pass}" "${fail}" "${skip}"
if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
