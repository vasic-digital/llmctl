#!/usr/bin/env bash
# test_host_reserve_review9.sh - UNIT-CLASS (hermetic fixtures). Round-9 review (Opus, NO-GO on d16e205) findings:
#   R1 a start with LLMCTL_HOST_RESERVE=0 must NOT persist the override into the unit's env record (OWN4)
#   R2 the memo key includes the cgroup chain inputs: a limit tightened in the SAME shell is seen
#   R3 the CPU warning is true when the operator-set reserve is the maximum (Rc>0, cpu_short=1); STRICT still refuses
#   R4 a huge chain value (2^64-1) is "unlimited", not a wrapped negative number; memory.max=0 floors to 1 MiB (OWN2)
#   R5 malformed STRICTER knobs (" 8192", "8G", 2^63) refuse (rc 75) instead of silently loosening
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
export LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
# shellcheck disable=SC1090
for l in common os_detect hardware catalog reserve capacity svc_hook download; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
export LLMCTL_HOST_MEM_MB=32768 LLMCTL_GATE_WAIT=0 LLMCTL_GATE_POLL=1
q() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$@"; }
MIB=1048576; U="$(id -u)"
newfs() { mkdir -p "$1/user.slice/user-${U}.slice/user@${U}.service/app.slice"; : > "$1/cgroup.controllers"; }
UM() { echo "$1/user.slice/user-${U}.slice/user@${U}.service"; }
bm() { ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="$1" LLMCTL_HOST_CPUS=16 "${@:2}"; capacity_json decide-tiny 2>/dev/null ) | python3 -c 'import json,sys; print(json.load(sys.stdin)["reserve"]["mem_model_budget_mb"])'; }

echo "--- R1: the reserve-off diagnostic override is not persisted into the unit env record"
source "${LLMCTL_ROOT}/lib/service_linux.sh" 2>/dev/null || true
if declare -F _svc_write_reserve_dropin >/dev/null; then
  export LLMCTL_SERVICES_DIR="${TEST_TMP}/services"; mkdir -p "${LLMCTL_SERVICES_DIR}"
  svc_unit_dir() { echo "${TEST_TMP}/units"; }
  ENVF="${LLMCTL_SERVICES_DIR}/i1.env"; printf 'LLMCTL_PORT=1\n' > "${ENVF}"
  ( export LLMCTL_HOST_RESERVE=0; _svc_write_reserve_dropin decide-tiny llama i1 ) >/dev/null 2>&1 || true
  if grep -q '^LLMCTL_HOST_RESERVE' "${ENVF}"; then echo "  FAIL: R1: the env record carries LLMCTL_HOST_RESERVE after a reserve-off start" >&2; TEST_FAILS=$((TEST_FAILS+1))
  else echo "  ok: R1: a reserve-off start leaves no LLMCTL_HOST_RESERVE line in the env record"; fi
  printf 'LLMCTL_HOST_RESERVE=0\n' >> "${ENVF}"      # a record written by an older build
  ( export LLMCTL_HOST_RESERVE=1; _svc_write_reserve_dropin decide-tiny llama i1 ) >/dev/null 2>&1 || true
  if grep -q '^LLMCTL_HOST_RESERVE' "${ENVF}"; then echo "  FAIL: R1: a later normal start did not clear the stale LLMCTL_HOST_RESERVE line" >&2; TEST_FAILS=$((TEST_FAILS+1))
  else echo "  ok: R1: a later normal start clears a stale LLMCTL_HOST_RESERVE line"; fi
  assert_contains "$(ls "$(svc_unit_dir)"/*/06-reserve.conf 2>/dev/null || echo none)" "06-reserve.conf" "R1: the normal start writes the reserve drop-in again"
else echo "  FAIL: R1: _svc_write_reserve_dropin not loadable" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi

echo "--- R2: the memo key includes the cgroup chain"
FS2="${TEST_TMP}/cg2"; newfs "${FS2}"
export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${FS2}" LLMCTL_HOST_CPUS=16
reserve_compute; B0="${RSV_BM}"
printf '%s\n' $(( 12000 * MIB )) > "${FS2}/user.slice/memory.max"
reserve_compute; B1="${RSV_BM}"
if (( B1 < B0 && B1 <= 12000 )); then echo "  ok: R2: a limit tightened after the first compute is seen (${B0} -> ${B1})"
else echo "  FAIL: R2: stale memo (before ${B0}, after ${B1})" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
unset LLMCTL_CGROUP_ROOT LLMCTL_CGROUP_FS LLMCTL_HOST_CPUS

echo "--- R3: the CPU warning is true when the operator reserves almost every CPU"
FS3="${TEST_TMP}/cg3"; newfs "${FS3}"
warn="$( ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${FS3}" LLMCTL_HOST_CPUS=16 LLMCTL_RESERVE_CPU_PCT=100; capacity_admit decide-tiny ) 2>&1 >/dev/null || true )"
if [[ "${warn}" == *"reserved 0"* ]]; then echo "  FAIL: R3: the warning says 'reserved 0' while 15 of 16 CPUs are reserved: ${warn}" >&2; TEST_FAILS=$((TEST_FAILS+1))
else echo "  ok: R3: no false 'reserved 0' claim at RESERVE_CPU_PCT=100"; fi
assert_contains "${warn}" "reserved 15" "R3: the warning states the real reserve (15 CPUs)"
rc=0; ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${FS3}" LLMCTL_HOST_CPUS=16 LLMCTL_RESERVE_CPU_PCT=100 LLMCTL_HOST_RESERVE_STRICT=1; capacity_admit decide-tiny ) >/dev/null 2>&1 || rc=$?
assert_eq 75 "${rc}" "R3: STRICT still refuses a host that cannot keep the full reserve"

echo "--- R4: chain value overflow and the 1 MiB floor"
FS4="${TEST_TMP}/cg4"; newfs "${FS4}"; UNB="$(bm "${FS4}")"
printf '18446744073709551615\n' > "$(UM "${FS4}")/memory.max"
assert_eq "${UNB}" "$(bm "${FS4}")" "R4: memory.max=2^64-1 is unlimited (no wrapped value, no false refusal)"
printf '9223372036854775808\n' > "$(UM "${FS4}")/memory.max"
assert_eq "${UNB}" "$(bm "${FS4}")" "R4: memory.max=2^63 is unlimited too"
printf '0\n' > "$(UM "${FS4}")/memory.max"
assert_eq 0 "$(bm "${FS4}")" "R4: memory.max=0 floors to 1 MiB: no model budget (the floor is not dropped)"
printf '%s\n' 524288 > "$(UM "${FS4}")/memory.max"
assert_eq 0 "$(bm "${FS4}")" "R4: memory.max=512 KiB floors to 1 MiB: no model budget"

echo "--- R5: malformed stricter knobs refuse"
PSI="${TEST_TMP}/psi9"; MEMI="${TEST_TMP}/mem9"
printf 'some avg10=0.00 avg60=0 avg300=0 total=0\nfull avg10=0.00 avg60=0 avg300=0 total=0\n' > "${PSI}"
printf 'MemTotal: 33554432 kB\nMemAvailable: %s kB\n' $(( 30000 * 1024 )) > "${MEMI}"
g() { local rc=0; ( export LLMCTL_PSI_FILE="${PSI}" LLMCTL_MEMINFO_FILE="${MEMI}" "$@"; hw_pressure_gate 0 decide-tiny ) 2>"${TEST_TMP}/gerr" >/dev/null || rc=$?; echo "${rc}"; }
assert_eq 0 "$(g)" "R5: 30000 MiB available: admitted (control)"
assert_eq 0 "$(g LLMCTL_RESERVE_MEM_MIN_MB=8192)" "R5: a well-formed stricter minimum that still fits admits (control)"
for bad in " 8192" "8G" "9223372036854775808" "0x10"; do
  assert_eq 75 "$(g LLMCTL_RESERVE_MEM_MIN_MB="${bad}")" "R5: LLMCTL_RESERVE_MEM_MIN_MB='${bad}' refuses"
done
assert_contains "$(cat "${TEST_TMP}/gerr")" "llmctl-fallback:" "R5: ... with the fallback line"
assert_eq 75 "$(g LLMCTL_RESERVE_MEM_PCT=2O)" "R5: LLMCTL_RESERVE_MEM_PCT=2O refuses"
assert_eq 75 "$(g LLMCTL_RESERVE_CPU_PCT=40%)" "R5: LLMCTL_RESERVE_CPU_PCT=40% refuses"
assert_eq 0 "$(g LLMCTL_RESERVE_CPU_PCT=40)" "R5: LLMCTL_RESERVE_CPU_PCT=40 is fine (control)"
assert_eq 0 "$(g LLMCTL_HOST_RESERVE=0 LLMCTL_RESERVE_MEM_MIN_MB=8G)" "R5: with the reserve off the knobs are not read (negative control)"
test_finish
