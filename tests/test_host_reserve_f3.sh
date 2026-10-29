#!/usr/bin/env bash
# test_host_reserve_f3.sh - UNIT-CLASS (hermetic: a fixture cgroup v2 mount with several owners; no real process is
# started). Review round 5, F3: the host model budget is ONE budget for the host, so the llmctl engine units of every
# owner count against it - this user's manager, other users' managers and system.slice - not only this user's units.
#   - another user's unit, or a system.slice unit, that holds the whole budget refuses a new start (75) in the combined
#     check, hk_gate (ExecStartPre), the start gate path and capacity (does_not_fit); before F3 it was not counted.
#   - those units are consumption only: never this user's "running" instance, never replaced by this user's restart.
#   - an unreadable part of the host tree (another user's manager at mode 000) fails closed (75, undetermined).
#   - LLMCTL_CGROUP_ROOT narrows the scan to one manager root and the scope says so ("manager").
# Every refusal has a positive control on the same fixture (empty owners admit; the own manager is still seen).
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
U="$(id -u)"; O=4242
[[ "${U}" != "${O}" ]] || O=4243
# mkunit <unit-dir> <cpu-pct> <mem-mb>: a populated engine unit cgroup
mkunit() {
  mkdir -p "$1"; printf 'populated 1\n' > "$1/cgroup.events"
  printf '%s 100000\n' $(( $2 * 1000 )) > "$1/cpu.max"; printf '%s\n' $(( $3 * MIB )) > "$1/memory.max"; printf '0\n' > "$1/memory.current"
}
# newfs <dir>: a cgroup v2 mount with this user's manager (empty) and another user's manager (empty)
newfs() {
  mkdir -p "$1/user.slice/user-${U}.slice/user@${U}.service/app.slice" "$1/user.slice/user-${O}.slice/user@${O}.service/app.slice" "$1/system.slice"
  : > "$1/cgroup.controllers"
}
own()   { echo "$1/user.slice/user-${U}.slice/user@${U}.service/app.slice/app-llmctl\\x2dllama.slice/$2"; }
other() { echo "$1/user.slice/user-${O}.slice/user@${O}.service/app.slice/app-llmctl\\x2dllama.slice/$2"; }
FULLCPU=$(( RSV_BC * 100 )); FULLMEM="${RSV_BM}"
comb_rc()  { local rc=0; ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="$1"; reserve_combined_check 100 512 decide-tiny ) >/dev/null 2>&1 || rc=$?; echo "${rc}"; }
hk_rc()    { local rc=0; ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="$1"; hk_gate "" ) >/dev/null 2>&1 || rc=$?; echo "${rc}"; }
gate_rc()  { local rc=0; ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="$1"; hw_pressure_gate 0 decide-tiny ) >/dev/null 2>&1 || rc=$?; echo "${rc}"; }
admit_rc() { local rc=0; ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="$1"; capacity_admit decide-tiny ) >/dev/null 2>&1 || rc=$?; echo "${rc}"; }
cap()      { LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="$1" capacity_json decide-tiny 2>/dev/null || true; }

echo "== controls: a host tree with no llmctl unit admits; the own manager's unit is seen =="
E="${TEST_TMP}/fs-empty"; newfs "${E}"
assert_eq 0 "$(comb_rc "${E}")" "control: no unit anywhere -> combined admits"
assert_eq 0 "$(hk_rc "${E}")" "control: no unit anywhere -> hk_gate admits"
assert_eq 0 "$(admit_rc "${E}")" "control: no unit anywhere -> capacity_admit admits"
d="$(cap "${E}")"
assert_eq "host [] 8" "$(q "${d}" 'd["llmctl"]["consumption_scope"]["scope"]+" "+str(d["llmctl"]["consumption_scope"]["owners"])+" "+str(d["llmctl"]["consumption_scope"]["max_depth"])')" "scope: the whole host, depth 8"
assert_eq "${E}" "$(q "${d}" 'd["llmctl"]["consumption_scope"]["cgroup_root"]')" "scope: the scan root is the cgroup mount"
S="${TEST_TMP}/fs-self"; newfs "${S}"; mkunit "$(own "${S}" 'llmctl-llama@big.service')" "${FULLCPU}" "${FULLMEM}"
assert_eq 75 "$(comb_rc "${S}")" "needle: this user's unit (template slice, depth 6) holding the budget is counted (75)"
assert_eq "self" "$(q "$(cap "${S}")" '",".join(u["owner"] for u in d["llmctl"]["units"])')" "needle: its owner is self"

echo "== F3: another user's unit holding the whole budget -> refuse (was: not counted, admitted) =="
X="${TEST_TMP}/fs-other"; newfs "${X}"; mkunit "$(other "${X}" 'llmctl-llama@big.service')" "${FULLCPU}" "${FULLMEM}"
assert_eq 75 "$(comb_rc "${X}")" "other user's unit: combined budget check refuses 75"
assert_eq 75 "$(hk_rc "${X}")" "other user's unit: hk_gate (every start, restart, boot) refuses 75"
assert_eq 75 "$(admit_rc "${X}")" "other user's unit: capacity_admit refuses 75"
d="$(cap "${X}")"
assert_eq "does_not_fit" "$(q "${d}" 'd["profiles"]["decide-tiny"]["verdict"]')" "other user's unit: capacity does_not_fit"
assert_eq "user-${O}" "$(q "${d}" '",".join(u["owner"] for u in d["llmctl"]["units"])')" "the unit is listed with its owner"
assert_contains "$(q "${d}" 'd["llmctl"]["units"][0]["cgroup"]')" "user@${O}.service" "the unit's cgroup path is reported"
assert_eq "host ['user-${O}']" "$(q "${d}" 'd["llmctl"]["consumption_scope"]["scope"]+" "+str(d["llmctl"]["consumption_scope"]["owners"])')" "consumption_scope lists the owners whose units were counted"
msg="$( ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${X}"; reserve_combined_check 100 512 decide-tiny ) 2>&1 >/dev/null || true)"
assert_contains "${msg}" "(user-${O})" "the refusal names the owner of the unit"

echo "== F3: a system.slice unit holding the whole budget -> refuse =="
Y="${TEST_TMP}/fs-system"; newfs "${Y}"; mkunit "${Y}/system.slice/system-llmctl\\x2dllama.slice/llmctl-llama@big.service" "${FULLCPU}" "${FULLMEM}"
assert_eq 75 "$(comb_rc "${Y}")" "system.slice unit: combined refuses 75"
assert_eq 75 "$(hk_rc "${Y}")" "system.slice unit: hk_gate refuses 75"
assert_eq "system" "$(q "$(cap "${Y}")" '",".join(u["owner"] for u in d["llmctl"]["units"])')" "system.slice unit: owner system"

echo "== F3: another user's unit is consumption only - never this user's instance =="
H="${TEST_TMP}/fs-half"; newfs "${H}"; mkunit "$(other "${H}" 'llmctl-llama@decide-tiny.service')" 100 512
d="$(cap "${H}")"
assert_eq "fits" "$(q "${d}" 'd["profiles"]["decide-tiny"]["verdict"]')" "another user's decide-tiny is not 'running' for this user (a new own start is judged: fits)"
M="${TEST_TMP}/fs-mine"; newfs "${M}"; mkunit "$(own "${M}" 'llmctl-llama@decide-tiny.service')" 100 512
assert_eq "running" "$(q "$(cap "${M}")" 'd["profiles"]["decide-tiny"]["verdict"]')" "control: this user's own decide-tiny IS running"
# restart: only this user's instance is replaced; another user's same-named unit stays counted
R="${TEST_TMP}/fs-restart"; newfs "${R}"
mkunit "$(other "${R}" 'llmctl-llama@decide-tiny.service')" "${FULLCPU}" "${FULLMEM}"
rc=0; ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${R}"; capacity_admit decide-tiny "" decide-tiny ) >/dev/null 2>&1 || rc=$?
assert_eq 75 "${rc}" "restart of decide-tiny: another user's same-named unit is not 'replaced' (still counted -> 75)"
R2="${TEST_TMP}/fs-restart-own"; newfs "${R2}"; mkunit "$(own "${R2}" 'llmctl-llama@decide-tiny.service')" "${FULLCPU}" "${FULLMEM}"
rc=0; ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${R2}"; capacity_admit decide-tiny "" decide-tiny ) >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "control: restart of this user's own decide-tiny replaces it (0)"

echo "== F3 + R5-1: an unreadable part of the host tree fails closed =="
L="${TEST_TMP}/fs-locked"; newfs "${L}"; mkunit "$(other "${L}" 'llmctl-llama@big.service')" "${FULLCPU}" "${FULLMEM}"
chmod 000 "${L}/user.slice/user-${O}.slice/user@${O}.service"
assert_eq 75 "$(comb_rc "${L}")" "another user's manager unreadable: combined refuses 75"
assert_eq 75 "$(hk_rc "${L}")" "another user's manager unreadable: hk_gate refuses 75"
assert_eq 75 "$(gate_rc "${L}")" "another user's manager unreadable: the start gate refuses 75"
d="$(cap "${L}")"
assert_eq "False undetermined" "$(q "${d}" 'str(d["measurement"]["ok"])+" "+d["profiles"]["decide-tiny"]["verdict"]')" "another user's manager unreadable: capacity undetermined"
chmod 700 "${L}/user.slice/user-${O}.slice/user@${O}.service"
assert_eq 75 "$(comb_rc "${L}")" "after chmod back: the unit is counted again (75: full budget)"
E2="${TEST_TMP}/fs-locked-empty"; newfs "${E2}"; chmod 000 "${E2}/system.slice"
assert_eq 75 "$(comb_rc "${E2}")" "an unreadable system.slice with no visible unit still refuses (not 'no units')"
chmod 700 "${E2}/system.slice"
assert_eq 0 "$(comb_rc "${E2}")" "control: the same tree readable admits"

echo "== scope: LLMCTL_CGROUP_ROOT narrows the scan to one manager and says so =="
d="$(LLMCTL_CGROUP_ROOT="${X}/user.slice/user-${U}.slice/user@${U}.service" capacity_json decide-tiny)"
assert_eq "manager 3" "$(q "${d}" 'd["llmctl"]["consumption_scope"]["scope"]+" "+str(d["llmctl"]["consumption_scope"]["max_depth"])')" "manager scope reported, depth 3"
assert_contains "$(q "${d}" 'd["llmctl"]["consumption_scope"]["not_counted"]')" "outside LLMCTL_CGROUP_ROOT" "manager scope: says what is not counted"
r="$(LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${X}" reserve_report --json)"
assert_eq "host user-${O}" "$(q "${r}" 'd["units_scope"]+" "+",".join(u["owner"] for u in d["units"])')" "llmctl reserve --json: host scope, the other user's unit listed with its owner"

test_finish
