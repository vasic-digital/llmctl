#!/usr/bin/env bash
# test_validate_interrupt.sh - review 2026-10-15 finding 2 (interruption safety of the validation gate):
#   (a) _val_on_signal read ${#rfiles[@]} before rfiles was declared: under `set -u` the handler aborted, so a profile
#       started for validation (svc_start) was never stopped;
#   (b) scheduler::with_lock took `flock -x` without a timeout and was not re-entrant: a stop from the signal handler,
#       while the interrupted quarantine START still held the lock in the same process, would block forever;
#   (c) a SIGTERM during the post-start validation of a QUARANTINED profile (validate_after_start; validate_profile did
#       not start it itself, started=0) left it running with quarantine=1 - QUARANTINE forever in `llmctl status`.
# Harness: tests/gate_wiring_lib.sh (recording service manager, throw-away tree, every catalog port remapped); the real
# validate_profile (GW_REAL_VALIDATE=1). Nothing real is started or signalled except this test's own processes.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source "$(dirname "${BASH_SOURCE[0]}")/gate_wiring_lib.sh"
test_setup_env
trap 'gw_cleanup_bg; test_teardown_env' EXIT
gw_init
L="${GW_LLMCTL}"
export GW_REAL_VALIDATE=1
unset LLMCTL_VALIDATE_HERMETIC
# mutation hook (tests/test_validation_mutants.sh group "interrupt"): INT_MUT_FILE/OLD/NEW change ONE lib file of this
# run's throw-away tree (never the repository)
if [[ -n "${INT_MUT_FILE:-}" ]]; then
  _mf="${GW_TREE}/lib/${INT_MUT_FILE}"; rm -f -- "${_mf:?}"; cp "${LLMCTL_ROOT}/lib/${INT_MUT_FILE}" "${_mf}"
  python3 -I - "${_mf}" "${INT_MUT_OLD}" "${INT_MUT_NEW}" <<'PY2'
import sys
f, old, new = sys.argv[1:4]
s = open(f).read()
if s.count(old) != 1: sys.exit("mutation anchor found %d times" % s.count(old))
open(f, "w").write(s.replace(old, new))
PY2
  echo "MUTANT applied to ${INT_MUT_FILE}"
fi
b2i() { if "$@"; then echo 1; else echo 0; fi; }
# wait_gone <pid> <seconds> -> 1 when the process ended in time
wait_gone() { local i; for (( i=0; i<$2*5; i++ )); do kill -0 "$1" 2>/dev/null || { echo 1; return 0; }; sleep 0.2; done; echo 0; }

echo "== (b) scheduler::with_lock is re-entrant in the process that holds it (a nested call does not block)"
rc=0
timeout 10 bash -c 'source "$1/lib/common.sh"; source "$1/lib/scheduler.sh"; scheduler::with_lock scheduler::with_lock true' _ "${GW_TREE}" || rc=$?
assert_eq 0 "${rc}" "nested with_lock returns at once (124 = deadlock)"
rc=0
timeout 10 bash -c 'source "$1/lib/common.sh"; source "$1/lib/scheduler.sh"; scheduler::with_lock bash -c "exec 9>\"\$1/.scheduler.lock\"; flock -n 9" _ "${LLMCTL_RUNTIME_DIR}"' _ "${GW_TREE}" || rc=$?
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "control: ANOTHER process still cannot take the lock while it is held (rc ${rc})"

echo "== (a)+(b) SIGTERM while 'llmctl validate' is inside its quarantine START (scheduler lock held, readiness poll)"
gw_calls_reset
LLMCTL_READY_TIMEOUT=30 "${L}" validate small > "${TEST_TMP}/a.out" 2>&1 & VP=$!
for _ in $(seq 1 100); do [[ "$(gw_count '^svc_start small')" -ge 1 ]] && break; sleep 0.1; done
assert_eq 1 "$(gw_count '^svc_start small')" "the quarantine start reached svc_start"
sleep 1
kill -TERM "${VP}"
gone="$(wait_gone "${VP}" 20)"
assert_eq 1 "${gone}" "the interrupted validate exits within 20 s (no handler abort, no lock deadlock)"
if [[ "${gone}" == 1 ]]; then rc=0; wait "${VP}" || rc=$?; else kill -9 "${VP}" 2>/dev/null || true; rc=hung; fi
assert_eq 143 "${rc}" "exit status 143 (SIGTERM)"
assert_eq 1 "$(gw_count '^svc_stop small')" "the profile started for validation is STOPPED by the handler"
assert_eq 0 "$(b2i grep -q 'unbound variable' "${TEST_TMP}/a.out")" "no 'unbound variable' abort in the handler"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/small.run" "no reservation left behind"

echo "== (c) SIGTERM during the post-start validation of a QUARANTINED profile stops it"
python3 -I -c 'import socket,time,sys; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(50); open(sys.argv[1],"w").write(str(s.getsockname()[1])); time.sleep(120)' "${TEST_TMP}/hang.port" &
GW_BG_PIDS+=("$!"); for _ in $(seq 50); do [[ -s "${TEST_TMP}/hang.port" ]] && break; sleep 0.1; done
HP="$(cat "${TEST_TMP}/hang.port")"
gw_mark_running small "${HP}"; printf 'quarantine=1\n' >> "${LLMCTL_RUNTIME_DIR}/small.run"
gw_calls_reset
LLMCTL_VALIDATE_TIMEOUT=60 "${L}" validate-after-start small > "${TEST_TMP}/c.out" 2>&1 & VP=$!
sleep 4
kill -TERM "${VP}"
gone="$(wait_gone "${VP}" 20)"
assert_eq 1 "${gone}" "the interrupted validate-after-start exits within 20 s"
[[ "${gone}" == 1 ]] || kill -9 "${VP}" 2>/dev/null || true
wait "${VP}" 2>/dev/null || true
assert_eq 1 "$(gw_count '^svc_stop small')" "the quarantined profile is STOPPED on interrupt"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/small.run" "its quarantine reservation is removed (no QUARANTINE forever)"

echo "== (c) ...also when the signal arrives OUTSIDE validate_profile (waiting for the per-profile validation lock)"
gw_mark_running small "${HP}"; printf 'quarantine=1\n' >> "${LLMCTL_RUNTIME_DIR}/small.run"
( exec 8>"${LLMCTL_RUNTIME_DIR}/.validate-small.lock"; flock 8; sleep 30 ) & HOLD=$!; GW_BG_PIDS+=("${HOLD}")
sleep 0.5
gw_calls_reset
LLMCTL_VALIDATE_LOCK_WAIT=4 "${L}" validate-after-start small > "${TEST_TMP}/c2.out" 2>&1 & VP=$!
sleep 1
kill -TERM "${VP}"
gone="$(wait_gone "${VP}" 20)"
[[ "${gone}" == 1 ]] || kill -9 "${VP}" 2>/dev/null || true
wait "${VP}" 2>/dev/null || true
kill "${HOLD}" 2>/dev/null || true
assert_eq 1 "$(gw_count '^svc_stop small')" "lock wait interrupted: the quarantined profile is STOPPED"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/small.run" "lock wait interrupted: its quarantine reservation is removed"

echo "== control: SIGTERM during the validation of a PUBLISHED profile (not quarantined, not started by the validator) stops nothing"
gw_mark_running small "${HP}"
gw_calls_reset
LLMCTL_VALIDATE_TIMEOUT=60 "${L}" validate-after-start small > "${TEST_TMP}/d.out" 2>&1 & VP=$!
sleep 4
kill -TERM "${VP}"
gone="$(wait_gone "${VP}" 20)"; [[ "${gone}" == 1 ]] || kill -9 "${VP}" 2>/dev/null || true
wait "${VP}" 2>/dev/null || true
assert_eq 0 "$(gw_count '^svc_stop small')" "control: a published profile is not stopped by an interrupted validation"
rm -f "${LLMCTL_RUNTIME_DIR}/small.run"

test_finish
