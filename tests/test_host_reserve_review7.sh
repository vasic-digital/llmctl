#!/usr/bin/env bash
# test_host_reserve_review7.sh - UNIT-CLASS (hermetic, no process started). Round-7 review findings:
#   F1  a host with too few CPUs to keep a CPU reserve (1 CPU: reserved 0) is admitted with a loud warning and
#       `capacity --json` says reserve.cpu_short=true; LLMCTL_HOST_RESERVE_STRICT=1 refuses (rc 75). A normal host: no flag.
#   F2  only the literal LLMCTL_HOST_RESERVE=0 disables the reserve; 1, yes, off, empty and unset keep it ON.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap 'test_teardown_env' EXIT
export LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
# shellcheck disable=SC1090
for l in common os_detect hardware catalog reserve capacity svc_hook; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
export LLMCTL_HOST_MEM_MB=32768 LLMCTL_GATE_WAIT=0 LLMCTL_GATE_POLL=1
assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then printf '  ok: %s\n' "$3"
  else printf '  FAIL: %s\n    unexpected: %s\n' "$3" "$2" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
}
q() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$@"; }
FS="${TEST_TMP}/cg"; mkdir -p "${FS}"; : > "${FS}/cgroup.controllers"
adm() { local cpus="$1"; shift; ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${FS}" LLMCTL_HOST_CPUS="${cpus}" "$@"; capacity_admit decide-tiny ) 2>&1; echo "rc=$?"; }
doc() { ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${FS}" LLMCTL_HOST_CPUS="$1"; capacity_json decide-tiny 2>/dev/null ); }

echo "--- F1: cpu_short"
assert_eq 'True' "$(q "$(doc 1)" 'd["reserve"]["cpu_short"] and d["reserve"]["cpus_reserved"]==0')" "F1: 1-CPU host reports cpu_short=true, 0 reserved"
assert_eq 'False' "$(q "$(doc 16)" 'd["reserve"]["cpu_short"]')" "F1: 16-CPU host reports cpu_short=false"
R1="$(adm 1)"
assert_contains "${R1}" "too few CPUs" "F1: 1-CPU admission warns loudly"
assert_contains "${R1}" "rc=0" "F1: ... and still admits without STRICT"
RS="$(adm 1 LLMCTL_HOST_RESERVE_STRICT=1)"
assert_contains "${RS}" "rc=75" "F1: STRICT refuses a 1-CPU host"
assert_contains "${RS}" "llmctl-fallback:" "F1: STRICT refusal carries the fallback line"
R16="$(adm 16 LLMCTL_HOST_RESERVE_STRICT=1)"
assert_not_contains "${R16}" "too few CPUs" "F1: no warning on a 16-CPU host (even STRICT)"
assert_contains "${R16}" "rc=0" "F1: STRICT does not refuse a normal host"

echo "--- F2: only literal 0 disables"
for v in 1 yes off empty ""; do
  [[ "${v}" == empty ]] && v="empty"
  if ( export LLMCTL_HOST_RESERVE="${v}"; reserve_enabled ); then printf '  ok: LLMCTL_HOST_RESERVE=%q keeps the reserve ON\n' "${v}"
  else printf '  FAIL: LLMCTL_HOST_RESERVE=%q disabled the reserve\n' "${v}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
done
if ( unset LLMCTL_HOST_RESERVE; reserve_enabled ); then echo "  ok: unset keeps it ON"; else echo "  FAIL: unset disabled" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
if ( export LLMCTL_HOST_RESERVE=0; reserve_enabled ); then echo "  FAIL: literal 0 did not disable" >&2; TEST_FAILS=$((TEST_FAILS+1)); else echo "  ok: literal 0 disables"; fi
test_finish
