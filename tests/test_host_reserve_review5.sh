#!/usr/bin/env bash
# test_host_reserve_review5.sh - UNIT-CLASS (hermetic: fixture cgroup trees, /proc thread census, PSI and plan; no real
# process is started). The findings of the 3.4.0 review round 5, each pinned by a test that fails on 5376ee6:
#   R5-1  capacity: an unreadable cgroup root (mode 000, or an unreadable directory under it) counted zero llmctl units
#         and answered "fits / local"; it must be undetermined, exit 75, never local.
#   R5-2  the start gate (hw_pressure_gate), the combined budget check and the unit ExecStartPre gate (hk_gate) admitted
#         with a missing or unreadable cgroup root; they must refuse with 75. On a host without the cgroup v2 unified
#         hierarchy the units cannot be counted at all, so the gate refuses with a message that says so.
#   R5-5  reviewer mutant Y02: a "running" verdict carries threads 0 and must leave CAP_THREADS empty.
#   R5-6  an empty or foreign /proc counted zero threads and was accepted; the census must see its own process (a
#         control needle) or the measurement is not ok.
# Every refusal case has a positive control on the same instrument (a readable tree whose unit IS counted).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap 'chmod -R u+rwx "${TEST_TMP:?}" 2>/dev/null || true; test_teardown_env' EXIT
export LLMCTL_DRY_RUN=1
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
# shellcheck disable=SC1090
for l in common os_detect hardware catalog reserve capacity svc_hook; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
export LLMCTL_HOST_MEM_MB=32768 LLMCTL_GATE_WAIT=0 LLMCTL_GATE_POLL=1

# q <json> <expr>: the expressions are literals written in THIS file (test-authored), never external input
q() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$@"; }
reserve_compute
MIB=1048576
# mkunit <root> <name>: a populated engine unit that holds the WHOLE model budget (so counting it must refuse a new one)
mkunit() {
  local d="$1/app.slice/$2"; mkdir -p "${d}"
  printf 'populated 1\n' > "${d}/cgroup.events"; printf '%s 100000\n' $(( RSV_BC * 100000 )) > "${d}/cpu.max"
  printf '%s\n' $(( RSV_BM * MIB )) > "${d}/memory.max"; printf '0\n' > "${d}/memory.current"
}
verdict() { q "$1" 'str(d["measurement"]["ok"])+" "+d["profiles"]["decide-tiny"]["verdict"]+" "+d["fallback"]["recommended"]' 2>/dev/null || echo unparseable; }
gate_rc() { local rc=0; ( export "$@"; hw_pressure_gate 0 decide-tiny ) >/dev/null 2>&1 || rc=$?; echo "${rc}"; }
comb_rc() { local rc=0; ( export "$@"; reserve_combined_check 100 512 decide-tiny ) >/dev/null 2>&1 || rc=$?; echo "${rc}"; }
hk_rc()   { local rc=0; ( export "$@"; hk_gate "" ) >/dev/null 2>&1 || rc=$?; echo "${rc}"; }
admit_rc() { local rc=0; ( export "$@"; capacity_admit decide-tiny ) >/dev/null 2>&1 || rc=$?; echo "${rc}"; }

echo "== positive controls: a readable root is counted (the instrument can see) =="
EMPTY="${TEST_TMP}/cg-empty"; mkdir -p "${EMPTY}"
FULL="${TEST_TMP}/cg-full"; mkunit "${FULL}" 'llmctl-llama@big.service'
assert_eq "True fits local" "$(verdict "$(LLMCTL_CGROUP_ROOT="${EMPTY}" capacity_json decide-tiny)")" "control: an empty readable root -> measured, fits, local"
assert_eq 0 "$(comb_rc LLMCTL_CGROUP_ROOT="${EMPTY}")" "control: combined check admits on an empty readable root"
assert_eq 0 "$(gate_rc LLMCTL_CGROUP_ROOT="${EMPTY}")" "control: the start gate admits on an empty readable root"
assert_eq 0 "$(hk_rc LLMCTL_CGROUP_ROOT="${EMPTY}")" "control: hk_gate admits on an empty readable root"
assert_eq 0 "$(admit_rc LLMCTL_CGROUP_ROOT="${EMPTY}")" "control: capacity_admit admits on an empty readable root"
assert_eq 75 "$(comb_rc LLMCTL_CGROUP_ROOT="${FULL}")" "needle: the unit holding the whole budget IS counted (combined 75)"
assert_eq 75 "$(hk_rc LLMCTL_CGROUP_ROOT="${FULL}")" "needle: hk_gate counts it too (75)"
assert_eq 1 "$(q "$(LLMCTL_CGROUP_ROOT="${FULL}" capacity_json decide-tiny)" 'len(d["llmctl"]["units"])')" "needle: capacity lists the unit"

echo "== R5-1 / R5-2: a missing or unreadable cgroup root (or a directory under it) -> refuse, never admit =="
MISSING="${TEST_TMP}/no-such-root"
LOCKED="${TEST_TMP}/cg-locked"; mkunit "${LOCKED}" 'llmctl-llama@big.service'; chmod 000 "${LOCKED}"
SUBLOCK="${TEST_TMP}/cg-sublocked"; mkunit "${SUBLOCK}" 'llmctl-llama@big.service'; chmod 000 "${SUBLOCK}/app.slice"
for c in "missing:${MISSING}" "mode-000 root:${LOCKED}" "mode-000 directory under the root:${SUBLOCK}"; do
  label="${c%%:*}" root="${c#*:}"
  doc="$(LLMCTL_CGROUP_ROOT="${root}" capacity_json decide-tiny 2>/dev/null)" || true
  assert_eq "False undetermined none" "$(verdict "${doc}")" "${label}: capacity undetermined, fallback none (was: fits local)"
  assert_contains "$(q "${doc}" 'd["measurement"].get("reason","")' 2>/dev/null || true)" "${root}" "${label}: the reason names the cgroup root"
  rc=0; capacity_exit_code "${doc}" decide-tiny >/dev/null 2>&1 || rc=$?
  assert_eq 75 "${rc}" "${label}: capacity exit code 75"
  assert_eq 75 "$(admit_rc LLMCTL_CGROUP_ROOT="${root}")" "${label}: capacity_admit refuses 75 (was: 0)"
  assert_eq 75 "$(comb_rc LLMCTL_CGROUP_ROOT="${root}")" "${label}: combined budget check refuses 75 (was: 0)"
  assert_eq 75 "$(gate_rc LLMCTL_CGROUP_ROOT="${root}")" "${label}: the start gate refuses 75 (was: 0)"
  assert_eq 75 "$(hk_rc LLMCTL_CGROUP_ROOT="${root}")" "${label}: hk_gate (ExecStartPre, every restart and boot) refuses 75 (was: 0)"
  msg="$( ( export LLMCTL_CGROUP_ROOT="${root}"; reserve_combined_check 100 512 decide-tiny ) 2>&1 >/dev/null || true)"
  assert_contains "${msg}" "cannot count the running llmctl units" "${label}: the refusal says why"
  # the census itself fails (second layer: a caller that skips the up-front check still never reads "0 units")
  rc=0; out="$(LLMCTL_CGROUP_ROOT="${root}" reserve_running_units)" || rc=$?
  assert_eq "1:" "${rc}:${out}" "${label}: reserve_running_units returns 1 with no lines"
done
assert_eq "0:llmctl-llama@big.service" "$(rc=0; o="$(LLMCTL_CGROUP_ROOT="${FULL}" reserve_running_units)" || rc=$?; echo "${rc}:${o%% *}")" "needle: the census lists the unit on a readable tree"
chmod 700 "${LOCKED}" "${SUBLOCK}/app.slice"
assert_eq 75 "$(comb_rc LLMCTL_CGROUP_ROOT="${LOCKED}")" "after chmod back: the same tree is counted again (75: full budget)"
d="$(LLMCTL_CGROUP_ROOT="${MISSING}" LLMCTL_HOST_RESERVE=0 capacity_json decide-tiny)"
assert_eq "True" "$(q "${d}" 'str(d["measurement"]["ok"])')" "reserve disabled: the cgroup root is not a critical input"

echo "== R5-2: the default root needs the cgroup v2 unified hierarchy; v1/hybrid -> refuse with a clear message =="
FS="${TEST_TMP}/cgfs"; U="$(id -u)"; mkdir -p "${FS}/user.slice/user-${U}.slice/user@${U}.service"
assert_eq 75 "$(comb_rc LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${FS}")" "no cgroup.controllers at the cgroup mount: refuse 75"
msg="$( ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${FS}"; reserve_combined_check 100 512 decide-tiny ) 2>&1 >/dev/null || true)"
assert_contains "${msg}" "cgroup v2" "the refusal names the missing cgroup v2 unified hierarchy"
assert_eq "False" "$(q "$(LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${FS}" capacity_json decide-tiny)" 'str(d["measurement"]["ok"])')" "capacity: not ok without cgroup v2"
: > "${FS}/cgroup.controllers"
assert_eq 0 "$(comb_rc LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${FS}")" "control: with cgroup.controllers present the default root is used and admits"
mkunit "${FS}/user.slice/user-${U}.slice/user@${U}.service" 'llmctl-llama@big.service'
assert_eq 75 "$(comb_rc LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${FS}")" "needle: a unit under the default root is counted (75)"

echo "== R5-6: the /proc thread census must see its own process (control needle) =="
EP="${TEST_TMP}/proc-empty-r5"; mkdir -p "${EP}"
d="$(LLMCTL_PROC_DIR="${EP}" capacity_json decide-tiny)"
assert_eq "False" "$(q "${d}" 'str(d["measurement"]["ok"])')" "an empty proc dir: measurement not ok (was: ok, 0 threads)"
assert_contains "$(q "${d}" 'd["measurement"].get("reason","")')" "thread census" "the reason names the thread census"
FP="${TEST_TMP}/proc-foreign"; mkdir -p "${FP}/77"
printf 'Name:\tx\nUid:\t%s\t0\t0\t0\nThreads:\t5\n' $(( U + 1 )) > "${FP}/77/status"
assert_eq "False" "$(q "$(LLMCTL_PROC_DIR="${FP}" capacity_json decide-tiny)" 'str(d["measurement"]["ok"])')" "a proc dir with only another uid's processes: not ok"
d="$(LLMCTL_PROC_DIR=/proc LLMCTL_PROC_SELF_PID= capacity_json decide-tiny)"
assert_eq "True" "$(q "${d}" 'str(d["host"]["nproc"]["user_threads"] is not None and d["host"]["nproc"]["user_threads"] >= 1)')" "control: the real /proc sees this process (>= 1 thread of this uid)"
assert_eq "[]" "$(q "${d}" '[c for c in d["measurement"]["critical_inputs_unreadable"] if "thread" in c]')" "control: the real /proc census is not flagged"

echo "== R5-5 (Y02): a running profile leaves CAP_THREADS empty (its verdict carries threads 0) =="
RUN="${TEST_TMP}/cg-running"; d0="${RUN}/app.slice/llmctl-llama@decide-tiny.service"; mkdir -p "${d0}"
printf 'populated 1\n' > "${d0}/cgroup.events"; printf '100000 100000\n' > "${d0}/cpu.max"; printf '%s\n' $(( 512 * MIB )) > "${d0}/memory.max"; printf '0\n' > "${d0}/memory.current"
doc="$(LLMCTL_CGROUP_ROOT="${RUN}" capacity_json decide-tiny)"
assert_eq "running 0" "$(q "${doc}" 'd["profiles"]["decide-tiny"]["verdict"]+" "+str(d["profiles"]["decide-tiny"]["threads"])')" "precondition: decide-tiny is running, threads 0"
export LLMCTL_CGROUP_ROOT="${RUN}"; CAP_THREADS=x; rc=0; capacity_admit decide-tiny >/dev/null 2>&1 || rc=$?
assert_eq "0 []" "${rc} [${CAP_THREADS}]" "running: admitted, CAP_THREADS empty (Y02 gave 0)"
export LLMCTL_CGROUP_ROOT="${EMPTY}"; CAP_THREADS=x; capacity_admit decide-tiny >/dev/null 2>&1 || true
assert_eq "True" "$( [[ "${CAP_THREADS}" =~ ^[1-9][0-9]*$ ]] && echo True || echo "False(${CAP_THREADS})")" "control: a fitting profile sets a positive thread count"

echo "== R5-1: llmctl reserve reports an unreadable unit tree instead of 'no unit is running' =="
r="$(LLMCTL_CGROUP_ROOT="${MISSING}" reserve_report --json)"
assert_eq "False" "$(q "${r}" 'str(d["units_readable"])')" "reserve --json: units_readable false on a missing root"
assert_contains "$(q "${r}" 'd["units_error"]')" "${MISSING}" "reserve --json: units_error names the root"
assert_contains "$(LLMCTL_CGROUP_ROOT="${MISSING}" reserve_report)" "UNKNOWN" "reserve (text): units UNKNOWN, not 'no unit is running'"
assert_eq "True" "$(q "$(LLMCTL_CGROUP_ROOT="${EMPTY}" reserve_report --json)" 'str(d["units_readable"])')" "control: a readable empty root is readable"

test_finish
