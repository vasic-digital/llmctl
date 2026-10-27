#!/usr/bin/env bash
# test_bg_register.sh - test_bg_register <pid...> must make test_teardown_env kill exactly the background processes the test
# started, and nothing else:
#   A. a pid registered inside a subshell ($(...) or ( ... )) is killed too (an in-memory array assignment made in a
#      subshell is lost, so the process outlived the test: review 2026-10-27 finding F2);
#   B. a recorded pid whose /proc start time no longer matches (the pid was reused by another process) is NOT killed
#      (review finding F3: kill only what we still own);
#   D. the shell's own pids ($$, $BASHPID, $PPID) are never recorded (review finding F-3, section 11.4.263 hardening);
#   C. control needles: a registration made in the test's own shell is killed (the mechanism works at all), and a process
#      the test never registered survives teardown (teardown is not a pattern kill).
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
OWN=()   # processes this test started outside the mechanism under test; killed here, by pid, on exit
_own_cleanup() { local p; for p in "${OWN[@]:-}"; do [[ -n "${p}" ]] && kill "${p}" 2>/dev/null || true; done; test_teardown_env; }
trap _own_cleanup EXIT

alive() { kill -0 "$1" 2>/dev/null && echo 1 || echo 0; }
gone_within() { # gone_within <pid>: 1 if the pid is gone within 3 s
  local _; for _ in $(seq 1 30); do kill -0 "$1" 2>/dev/null || { echo 1; return; }; sleep 0.1; done; echo 0; }

echo "== A: a registration made in a subshell is honoured by teardown"
test_setup_env
SUB_PID="$(sleep 300 >/dev/null 2>&1 & test_bg_register "$!"; echo "$!")"
OWN+=("${SUB_PID}")
assert_eq 1 "$(alive "${SUB_PID}")" "setup: the subshell-started process is running"
test_teardown_env
assert_eq 1 "$(gone_within "${SUB_PID}")" "A: teardown killed the process registered inside \$(...)"

echo "== B: a recorded pid whose start time no longer matches is left alone"
test_setup_env
sleep 300 >/dev/null 2>&1 & STRANGER=$!; OWN+=("${STRANGER}")
test_bg_register "${STRANGER}"
# simulate pid reuse: the record now carries a start time that is not the running process's start time
REC="${TEST_TMP}/.bg_pids"
assert_eq 1 "$([[ -s "${REC}" ]] && echo 1 || echo 0)" "setup: the registration is recorded in ${REC##*/}"
# the recorded start time must be field 22 of /proc/<pid>/stat (read here with awk, independently of the helper): a helper that
# read field 21 (always 0) or any other field is caught here, not only by the reuse simulation below (review F-2)
REAL_START="$(awk '{print $22}' "/proc/${STRANGER}/stat")"
assert_eq "${STRANGER} ${REAL_START}" "$(cat "${REC}")" "B: the recorded start time equals field 22 of /proc/<pid>/stat"
# simulate pid reuse with a start time that really differs from the running process's own (REAL_START + 1), not a made-up constant
sed -i "s/^${STRANGER} .*/${STRANGER} $(( REAL_START + 1 ))/" "${REC}"
test_teardown_env
sleep 0.3
assert_eq 1 "$(alive "${STRANGER}")" "B: a recorded pid with a different start time (a reused pid) is not killed"

echo "== D: the shell's own pids are refused (a recorded \$\$ / \$BASHPID / \$PPID would make teardown kill the test runner)"
test_setup_env
REC="${TEST_TMP}/.bg_pids"
test_bg_register "$$" "${BASHPID}" "${PPID}"
( test_bg_register "$$" "${BASHPID}" "${PPID}" )
assert_eq 0 "$([[ -s "${REC}" ]] && echo 1 || echo 0)" "D: nothing was recorded for \$\$, \$BASHPID or \$PPID"
: > "${REC}"   # never let a failing D reach teardown with our own pids recorded
test_teardown_env

echo "== C: control needles"
test_setup_env
sleep 300 >/dev/null 2>&1 & MINE=$!; OWN+=("${MINE}")
sleep 300 >/dev/null 2>&1 & NOTMINE=$!; OWN+=("${NOTMINE}")
test_bg_register "${MINE}"
test_teardown_env
assert_eq 1 "$(gone_within "${MINE}")" "C: a registration made in the test's own shell is killed"
assert_eq 1 "$(alive "${NOTMINE}")" "C: a process the test never registered survives teardown"

test_setup_env
test_finish
