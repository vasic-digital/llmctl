#!/usr/bin/env bash
# test_gate_switch_enable.sh - RED-first (review HIGH-2).
#  (a) `switch A->B` gated on the FULL memory check BEFORE stopping A, so MemAvailable still counted A's memory and a
#      switch between two big models was refused. Contract: before the stop only PSI is checked (footprint 0, reserve 0);
#      the memory check runs after the stop (in _sched_start_impl) and in the unit's ExecStartPre.
#  (b) PSI pressure before the stop still refuses the switch with 75 and stops NOTHING.
#  (c) `enable` of an already-running profile must not return 75 (nothing is being started).
#  (d) the rollback path (_sched_restore_set) must not be refused by the gate: a failed switch must not leave nothing
#      running (the unit's own ExecStartPre gate still waits/applies).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
export LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
LLMCTL="${LLMCTL_ROOT}/bin/llmctl"
OKPSI="${LLMCTL_PSI_FILE}"; OKMEM="${LLMCTL_MEMINFO_FILE}"
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\nfull avg10=9.00 avg60=0.00 avg300=0.00 total=1\n' > "${TEST_TMP}/psi.high"
printf 'MemTotal:       33554432 kB\nMemFree:  3000000 kB\nMemAvailable:   3000000 kB\n' > "${TEST_TMP}/mem.low"   # ~2.9 GiB: below footprint+4 GiB

"${LLMCTL}" start fast >/dev/null 2>&1 || { printf '  FAIL: setup: start fast\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); }

echo "== (a) switch with low MemAvailable (the running model's memory is about to be freed) =="
out="$(LLMCTL_MEMINFO_FILE="${TEST_TMP}/mem.low" "${LLMCTL}" switch coder 2>&1)" && rc=0 || rc=$?
case "${out}" in *"systemctl --user stop llmctl-llama@fast.service"*) echo "  ok: (a) the running model was stopped, i.e. the pre-stop gate did not refuse on MemAvailable";;
  *) printf '  FAIL: (a) switch was refused BEFORE the stop on low MemAvailable (rc=%s): %.200s\n' "${rc}" "${out}" >&2; TEST_FAILS=$((TEST_FAILS+1));; esac

# reset: fast running again
"${LLMCTL}" stop all >/dev/null 2>&1 || true; "${LLMCTL}" start fast >/dev/null 2>&1

echo "== (b) switch under PSI pressure: refused, nothing stopped =="
out="$(LLMCTL_PSI_FILE="${TEST_TMP}/psi.high" "${LLMCTL}" switch coder 2>&1)" && rc=0 || rc=$?
assert_eq "75" "${rc}" "(b) PSI high: switch exits 75"
case "${out}" in *"systemctl --user stop"*) printf '  FAIL: (b) something was stopped before the refusal\n' >&2; TEST_FAILS=$((TEST_FAILS+1));; *) echo "  ok: (b) nothing stopped";; esac

echo "== (c) enable of an already-running profile under pressure =="
out="$(LLMCTL_PSI_FILE="${TEST_TMP}/psi.high" "${LLMCTL}" enable fast 2>&1)" && rc=0 || rc=$?
if [[ "${rc}" == 75 ]]; then printf '  FAIL: (c) enable of a RUNNING profile returned 75 under pressure\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else echo "  ok: (c) enable of a running profile is not gated (rc=${rc})"; fi
echo "  -- control: enable of a NOT running profile under pressure is refused"
out="$(LLMCTL_PSI_FILE="${TEST_TMP}/psi.high" "${LLMCTL}" enable small 2>&1)" && rc=0 || rc=$?
assert_eq "75" "${rc}" "(c) control: enable small (not running) under PSI pressure exits 75"

echo "== (d) rollback restore is not refused by the gate =="
"${LLMCTL}" stop all >/dev/null 2>&1 || true
rc=0; out="$( export LLMCTL_PSI_FILE="${TEST_TMP}/psi.high"
  # shellcheck disable=SC1090
  for l in common os_detect hardware catalog portreg service_linux scheduler; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
  sched_load_backend; _sched_restore_set fast 2>&1 )" || rc=$?
assert_eq "0" "${rc}" "(d) _sched_restore_set fast under PSI pressure succeeds"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/fast.run" "(d) fast is running again after the restore"
test_finish
