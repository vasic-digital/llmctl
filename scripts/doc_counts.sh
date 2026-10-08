#!/usr/bin/env bash
# doc_counts.sh - generate assertion counts from a REAL run of a test suite
# and (optionally) compare them with the count a docs/scripts/test_<suite>.md
# page claims. N-27 (spec 009): hand-typed counts in documentation went stale
# (55/36 documented vs 71/45 actual); the doc audit must use measured numbers.
#
# Usage:
#   scripts/doc_counts.sh <suite> [<suite>...]       print "<suite> <ok> <fail> <skip>"
#   scripts/doc_counts.sh --check <suite> [...]      also compare with the doc page:
#                                                    exit 1 when a page states a different
#                                                    "<N> passing" count (host-dependent
#                                                    suites that print SKIP are reported
#                                                    as "env-dependent", not as stale)
#   scripts/doc_counts.sh --all [--check]            every tests/test_*.sh
#
# <suite> is the file name without "test_" and ".sh" (e.g. planner for
# tests/test_planner.sh; its page is docs/scripts/test_planner.md).
# A count is the number of lines a suite prints starting with exactly
# "  ok:" (tests/helpers.sh assert_* format); FAIL lines start "  FAIL:",
# honest skips "  SKIP:". Nothing is guessed: a suite that cannot run is
# reported as "error" and makes the script exit 2.
# A suite that prints "SKIP-SUITE: <reason>" (tests/run_tests.sh skip contract) ran nothing; with
# --check it is reported status=skipped-suite instead of being compared with its page.
# Host-dependent branches (G-084): a suite brackets assertions whose count varies with the host
# (`hostdep_begin <reason>` ... `hostdep_end` in tests/helpers.sh print `HOSTDEP-BEGIN: <reason>` /
# `HOSTDEP-END`). `  ok:` lines between the markers are excluded from ok= (reported as hostdep=<N>); the
# documented count is compared with the host-independent ok= STRICTLY (a SKIP does not excuse a
# mismatch), so a page cannot go stale unseen behind "env-dependent". Unmarked suites keep the old rule.
# Output is machine-readable, one record per line:
#   <suite> ok=<N> fail=<N> skip=<N> rc=<rc> [doc=<N>] [status=match|stale|env-dependent|no-doc-count|skipped-suite]
# status=inconsistent (C2-10): the suite exited 0 but printed `  FAIL:` lines (a lost assertion counter), or printed
# SKIP-SUITE after an assertion line; reported for every run (with or without --check) and the exit is 2.
# Exit: 0 all fine, 1 a documented count is stale, 2 a suite errored or is inconsistent.
set -uo pipefail
ROOT="${DOC_COUNTS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"   # DOC_COUNTS_ROOT: test hook (a scratch tree with tests/ + docs/scripts/)
check=0; all=0; suites=()
for a in "$@"; do
  case "${a}" in
    --check) check=1 ;;
    --all) all=1 ;;
    -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) echo "doc_counts.sh: unknown option ${a}" >&2; exit 2 ;;
    *) suites+=("${a}") ;;
  esac
done
if (( all )); then
  for f in "${ROOT}"/tests/test_*.sh; do b="$(basename "${f}" .sh)"; suites+=("${b#test_}"); done
fi
(( ${#suites[@]} )) || { echo "doc_counts.sh: no suite given (see --help)" >&2; exit 2; }
exit_code=0
for s in "${suites[@]}"; do
  f="${ROOT}/tests/test_${s}.sh"
  [[ -f "${f}" ]] || { echo "${s} error=no-such-suite"; exit_code=2; continue; }
  out="$(bash "${f}" 2>&1)"; rc=$?
  # host-independent ok count: lines between HOSTDEP-BEGIN/HOSTDEP-END are tallied separately
  read -r ok hostdep marked < <(printf '%s\n' "${out}" | awk '
    /^HOSTDEP-BEGIN: /{ins=1; m=1; next}
    /^HOSTDEP-END/{ins=0; next}
    /^  ok:/{ if (ins) h++; else o++ }
    END{printf "%d %d %d\n", o, h, m}')
  fail="$(printf '%s\n' "${out}" | grep -c '^  FAIL:' || true)"
  skip="$(printf '%s\n' "${out}" | grep -cE '^[[:space:]]+SKIP:' || true)"
  suite_skip=0
  printf '%s\n' "${out}" | grep -q '^SKIP-SUITE: ' && suite_skip=1       # whole suite skipped (tests/run_tests.sh contract)
  # C2-10: a suite that exits 0 while printing `  FAIL:` lines lost an assertion failure (subshell counter), and a
  # SKIP-SUITE printed AFTER an assertion means the suite had already asserted something; neither is a count.
  inconsistent=0
  (( rc == 0 && fail > 0 )) && inconsistent=1
  if (( suite_skip )) && printf '%s\n' "${out}" | awk '/^  (ok|FAIL):/{a=1} /^SKIP-SUITE: /{ if (a) bad=1; exit } END{exit bad?0:1}'; then inconsistent=1; fi
  line="${s} ok=${ok} fail=${fail} skip=${skip} rc=${rc}"
  (( marked )) && line+=" hostdep=${hostdep}"
  if (( inconsistent )); then
    line+=" status=inconsistent"
    exit_code=2
  elif (( suite_skip )); then
    # nothing ran: there is no measured count to compare, and a doc is not "stale" because of it
    (( check )) && line+=" status=skipped-suite"
  elif (( check )); then
    doc="${ROOT}/docs/scripts/test_${s}.md"
    claim=""
    [[ -f "${doc}" ]] && claim="$(tr '\n' ' ' < "${doc}" | grep -oE '\*\*[0-9]+ +passing' | head -1 | grep -oE '[0-9]+' || true)"
    if [[ -z "${claim}" ]]; then
      line+=" status=no-doc-count"
    else
      line+=" doc=${claim}"
      if [[ "${claim}" == "${ok}" ]]; then line+=" status=match"
      elif (( skip > 0 && ! marked )); then line+=" status=env-dependent"
      else line+=" status=stale"; (( exit_code == 0 )) && exit_code=1
      fi
    fi
  fi
  echo "${line}"
  (( rc != 0 && exit_code == 0 )) && exit_code=2
done
exit "${exit_code}"
