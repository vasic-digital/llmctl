#!/usr/bin/env bash
# test_host_reserve_review6.sh - UNIT-CLASS (hermetic: fixture cgroup trees and a find(1) stub on PATH; no real process
# is started). The findings of the 3.4.0 review round 6, each pinned by a test that fails on 0440759:
#   F1  a cgroup that vanishes between readdir and descent makes GNU find exit 1 with "No such file or directory". That
#       is a unit stopping, not an unreadable tree: it must count as absent, not as "unmeasurable" (measured 4/277 false
#       unmeasurable on the reference host). A permission error, or an unexplained non-zero exit, still fails closed.
#   F2  cgroups deeper than the scan depth were silently not counted (fail-open); the scan must say so and refuse.
#   F3  an llmctl unit inside a container scope under this user's manager was classified owner=self.
#   F4  LLMCTL_CGROUP_FS with a trailing slash mis-classified this user's own units as another user's.
#   F5  reserve --json must stay valid JSON for a cgroup path with a double quote or a control character.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap 'chmod -R u+rwx "${TEST_TMP:?}" 2>/dev/null || true; test_teardown_env' EXIT
export LLMCTL_DRY_RUN=1
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
# shellcheck disable=SC1090
for l in common os_detect hardware catalog reserve capacity svc_hook; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
export LLMCTL_HOST_MEM_MB=32768 LLMCTL_GATE_WAIT=0 LLMCTL_GATE_POLL=1
assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then printf '  ok: %s\n' "$3"
  else printf '  FAIL: %s\n    unexpected: %s\n    haystack: %.500s\n' "$3" "$2" "$1" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
}
q() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$@"; }
reserve_compute
MIB=1048576; U="$(id -u)"; O=4242
mkunit() { # <dir> <cpu-pct> <mem-mb>
  mkdir -p "$1"; printf 'populated 1\n' > "$1/cgroup.events"; printf '%s 100000\n' $(( $2 * 1000 )) > "$1/cpu.max"
  printf '%s\n' $(( $3 * MIB )) > "$1/memory.max"; printf '0\n' > "$1/memory.current"
}
newfs() { mkdir -p "$1/user.slice/user-${U}.slice/user@${U}.service/app.slice" "$1/user.slice/user-${O}.slice/user@${O}.service/app.slice" "$1/system.slice"; : > "$1/cgroup.controllers"; }
FULLCPU=$(( RSV_BC * 100 )); FULLMEM="${RSV_BM}"
comb_rc() { local fs="$1" rc=0; shift; ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${fs}" "$@"; reserve_combined_check 100 512 decide-tiny ) >/dev/null 2>&1 || rc=$?; echo "${rc}"; }
comb_msg() { local fs="$1"; shift; ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${fs}" "$@"; reserve_combined_check 100 512 decide-tiny ) 2>&1 >/dev/null || true; }
hk_rc() { local fs="$1" rc=0; shift; ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${fs}" "$@"; hk_gate "" ) >/dev/null 2>&1 || rc=$?; echo "${rc}"; }
cap() { local fs="$1"; shift; ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${fs}" "$@"; capacity_json decide-tiny 2>/dev/null ); }
cap_any() { local fs="$1"; shift; ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${fs}" "$@"; capacity_json 2>/dev/null ); }

# --- a find(1) stub: runs the real find, prints its stdout, then adds stderr and an exit status (MODE) ----------------
REALFIND="$(command -v find)"
STUB="${TEST_TMP}/stub"; mkdir -p "${STUB}"
cat > "${STUB}/find" <<STUBEOF
#!/usr/bin/env bash
out="\$(${REALFIND} "\$@" 2>/dev/null)" || true
[ -n "\${out}" ] && printf '%s\n' "\${out}"
case "\${STUB_FIND_MODE:-}" in
  vanish) printf "find: '%s/user.slice/gone.service': No such file or directory\n" "\${1:-x}" >&2; exit 1 ;;
  perm)   printf "find: '%s/user.slice/locked': Permission denied\n" "\${1:-x}" >&2; exit 1 ;;
  silent) exit 1 ;;
  rootgone) printf "find: '%s': No such file or directory\n" "\${1:-x}" >&2; exit 1 ;;
  vanish2)  printf "find: '%s/user.slice/gone.service': No such file or directory\n" "\${1:-x}" >&2; exit 2 ;;
  mixed)  printf "find: '%s/a': No such file or directory\nfind: '%s/b': Permission denied\n" "\${1:-x}" "\${1:-x}" >&2; exit 1 ;;
esac
exit 0
STUBEOF
chmod +x "${STUB}/find"

EMPTY="${TEST_TMP}/fs-empty"; newfs "${EMPTY}"
FULL="${TEST_TMP}/fs-full"; newfs "${FULL}"
mkunit "${FULL}/user.slice/user-${U}.slice/user@${U}.service/app.slice/app-llmctl\\x2dllama.slice/llmctl-llama@big.service" "${FULLCPU}" "${FULLMEM}"

echo "== controls: the stub with no mode changes nothing; the unit holding the whole budget is counted =="
assert_eq 0  "$(comb_rc "${EMPTY}" PATH="${STUB}:${PATH}")" "control: empty tree admits through the stub"
assert_eq 75 "$(comb_rc "${FULL}"  PATH="${STUB}:${PATH}")" "control: the full unit is counted through the stub (75)"

echo "== F1: a cgroup that vanished mid-scan (find exit 1, ENOENT only) is absent, not unreadable =="
assert_eq 0  "$(comb_rc "${EMPTY}" PATH="${STUB}:${PATH}" STUB_FIND_MODE=vanish)" "F1: combined check admits an empty tree when a dir vanished"
assert_eq 0  "$(hk_rc   "${EMPTY}" PATH="${STUB}:${PATH}" STUB_FIND_MODE=vanish)" "F1: hk_gate admits likewise"
assert_eq "True fits" "$(q "$(cap "${EMPTY}" PATH="${STUB}:${PATH}" STUB_FIND_MODE=vanish)" 'str(d["measurement"]["ok"])+" "+d["profiles"]["decide-tiny"]["verdict"]')" "F1: capacity measured, fits"
assert_eq 75 "$(comb_rc "${FULL}" PATH="${STUB}:${PATH}" STUB_FIND_MODE=vanish)" "F1: a unit still present next to the vanished dir is still counted (75)"
assert_contains "$(comb_msg "${FULL}" PATH="${STUB}:${PATH}" STUB_FIND_MODE=vanish)" "would be breached" "F1: and the refusal is the budget refusal, not 'cannot count'"
assert_not_contains "$(comb_msg "${FULL}" PATH="${STUB}:${PATH}" STUB_FIND_MODE=vanish)" "cannot count" "F1: not the unmeasurable message"
rep="$(LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${EMPTY}" PATH="${STUB}:${PATH}" STUB_FIND_MODE=vanish reserve_report --json)"
assert_eq True "$(q "${rep}" 'd["units_readable"]')" "F1: reserve --json units_readable true"

echo "== F1 negative: permission errors, mixed errors and an unexplained exit 1 still fail closed =="
for m in perm mixed silent rootgone vanish2; do
  assert_eq 75 "$(comb_rc "${EMPTY}" PATH="${STUB}:${PATH}" STUB_FIND_MODE=${m})" "F1[${m}]: combined check refuses (75)"
  assert_eq 75 "$(hk_rc   "${EMPTY}" PATH="${STUB}:${PATH}" STUB_FIND_MODE=${m})" "F1[${m}]: hk_gate refuses (75)"
  assert_eq "False undetermined" "$(q "$(cap "${EMPTY}" PATH="${STUB}:${PATH}" STUB_FIND_MODE=${m})" 'str(d["measurement"]["ok"])+" "+d["profiles"]["decide-tiny"]["verdict"]')" "F1[${m}]: capacity undetermined"
done
msg="$(comb_msg "${EMPTY}" PATH="${STUB}:${PATH}" STUB_FIND_MODE=perm)"
assert_contains "${msg}" "cannot count the running llmctl units" "F1: refusal text"
assert_contains "${msg}" "${EMPTY}" "F1: the message names the scan root (the cgroup mount)"
assert_contains "${msg}" "Permission denied" "F1: and carries find's own reason"
assert_not_contains "${msg}" "user@${U}.service" "F1: and not the manager root"

echo "== F2: a cgroup deeper than the scan depth is reported and refused, never silently skipped =="
DEEP="${TEST_TMP}/fs-deep"; newfs "${DEEP}"
# depth 9 below the mount: user.slice/user-O.slice/user@O.service/user.slice/libpod-abc.scope/container/system.slice/system-llmctl\x2dllama.slice/<unit>
mkunit "${DEEP}/user.slice/user-${O}.slice/user@${O}.service/user.slice/libpod-abc.scope/container/system.slice/system-llmctl\\x2dllama.slice/llmctl-llama@big.service" "${FULLCPU}" "${FULLMEM}"
assert_eq 75 "$(comb_rc "${DEEP}")" "F2: combined check refuses (was 0: the depth-9 unit was not counted)"
assert_contains "$(comb_msg "${DEEP}")" "deeper than" "F2: the message says the tree is deeper than the scan"
assert_eq "False undetermined" "$(q "$(cap "${DEEP}")" 'str(d["measurement"]["ok"])+" "+d["profiles"]["decide-tiny"]["verdict"]')" "F2: capacity undetermined"
EDGE="${TEST_TMP}/fs-edge"; newfs "${EDGE}"
# depth 8 (the boundary): one level fewer; it must be counted, not refused as too deep
mkunit "${EDGE}/user.slice/user-${O}.slice/user@${O}.service/user.slice/libpod-abc.scope/container/system-llmctl\\x2dllama.slice/llmctl-llama@big.service" "${FULLCPU}" "${FULLMEM}"
assert_contains "$(comb_msg "${EDGE}")" "would be breached" "F2: a depth-8 unit is counted (budget refusal)"
assert_not_contains "$(comb_msg "${EDGE}")" "deeper than" "F2: and not reported as too deep"
assert_eq 1 "$(q "$(cap "${EDGE}")" 'len(d["llmctl"]["units"])')" "F2: capacity lists the depth-8 unit"

echo "== F3: a unit inside a container scope under this user's manager is not 'self' =="
CT="${TEST_TMP}/fs-ct"; newfs "${CT}"
mkunit "${CT}/user.slice/user-${U}.slice/user@${U}.service/user.slice/libpod-abc.scope/container/llmctl-llama@decide-tiny.service" 100 512
assert_eq container "$(q "$(cap "${CT}")" 'd["llmctl"]["units"][0]["owner"]')" "F3: owner is 'container', not 'self'"
assert_eq "self" "$(q "$(cap "${FULL}")" 'd["llmctl"]["units"][0]["owner"]')" "F3 control: a regular unit under app.slice is still 'self'"

echo "== F4: LLMCTL_CGROUP_FS with a trailing slash classifies like the one without =="
assert_eq self "$(q "$(cap "${FULL}/")" 'd["llmctl"]["units"][0]["owner"]')" "F4: trailing slash -> self (was user-${U})"
assert_eq self "$(q "$(cap "${FULL}//")" 'd["llmctl"]["units"][0]["owner"]')" "F4: double trailing slash -> self"
sysfs="${TEST_TMP}/fs-sys"; newfs "${sysfs}"; mkunit "${sysfs}/system.slice/llmctl-llama@x.service" 100 512
assert_eq system "$(q "$(cap "${sysfs}/")" 'd["llmctl"]["units"][0]["owner"]')" "F4: system.slice unit with a trailing slash -> system"

echo "== owner classification pins (reviewer mutants RV6-01, RV6-02) =="
# RV6-01: the uid in user-<uid>.slice must equal the uid in user@<uid>.service; a mismatched path is 'other', not a user
MM="${TEST_TMP}/fs-mismatch"; newfs "${MM}"
mkunit "${MM}/user.slice/user-${O}.slice/user@${U}.service/app.slice/llmctl-llama@big.service" "${FULLCPU}" "${FULLMEM}"
assert_eq other "$(q "$(cap "${MM}")" 'd["llmctl"]["units"][0]["owner"]')" "RV6-01: user-<A>.slice/user@<B>.service is 'other' (not user-<A>)"
assert_eq 75 "$(comb_rc "${MM}")" "RV6-01: and it is still counted as consumption (75)"
MM2="${TEST_TMP}/fs-match"; newfs "${MM2}"
mkunit "${MM2}/user.slice/user-${O}.slice/user@${O}.service/app.slice/llmctl-llama@big.service" "${FULLCPU}" "${FULLMEM}"
assert_eq "user-${O}" "$(q "$(cap "${MM2}")" 'd["llmctl"]["units"][0]["owner"]')" "RV6-01 control: matching uids -> user-<uid>"
# RV6-02: another owner's decision unit is not a local decision endpoint for this user; this user's own is
DX="${TEST_TMP}/fs-dec-foreign"; newfs "${DX}"
mkunit "${DX}/user.slice/user-${O}.slice/user@${O}.service/app.slice/llmctl-llama@decide-tiny.service" "${FULLCPU}" "${FULLMEM}"
assert_eq "False" "$(q "$(cap_any "${DX}")" 'str(d["fallback"]["recommended"]=="local")')" "RV6-02: another owner's running decide-tiny is not a local decision endpoint"
DO="${TEST_TMP}/fs-dec-own"; newfs "${DO}"
mkunit "${DO}/user.slice/user-${U}.slice/user@${U}.service/app.slice/llmctl-llama@decide-tiny.service" "${FULLCPU}" "${FULLMEM}"
assert_eq "True" "$(q "$(cap_any "${DO}")" 'str(d["fallback"]["recommended"]=="local")')" "RV6-02 control: this user's own running decide-tiny is local"

echo "== restart, manager scope, root mode, units input (reviewer mutants RV6-04, 06, 07, 10) =="
# RV6-04: a restart only gets back the memory of THIS user's instance; another owner's same-named unit with a big resident
# set must not make a host that is below the reserve look fine. Budgets pass (small limits); only MemAvailable binds.
MI="${TEST_TMP}/meminfo"; printf 'MemTotal: 33554432 kB\nMemFree: 1000000 kB\nMemAvailable: %s kB\n' $(( (RSV_RM - 500) * 1024 )) > "${MI}"
mkcur() { printf '%s\n' $(( $2 * MIB )) > "$1/memory.current"; }
RF="${TEST_TMP}/fs-rep-foreign"; newfs "${RF}"
FU="${RF}/user.slice/user-${O}.slice/user@${O}.service/app.slice/llmctl-llama@decide-tiny.service"; mkunit "${FU}" 100 64; mkcur "${FU}" 6000
rc=0; ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${RF}" LLMCTL_MEMINFO_FILE="${MI}"; capacity_admit decide-tiny "" decide-tiny ) >/dev/null 2>&1 || rc=$?
assert_eq 75 "${rc}" "RV6-04: restart does not get back another owner's resident memory (host below the reserve -> 75)"
RO="${TEST_TMP}/fs-rep-own"; newfs "${RO}"
OU="${RO}/user.slice/user-${U}.slice/user@${U}.service/app.slice/llmctl-llama@decide-tiny.service"; mkunit "${OU}" 100 64; mkcur "${OU}" 6000
rc=0; ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${RO}" LLMCTL_MEMINFO_FILE="${MI}"; capacity_admit decide-tiny "" decide-tiny ) >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "RV6-04 control: restart of this user's own instance gets its resident memory back (0)"
# RV6-06: a cgroup root without the search (x) bit is refused by name, not left to the later find failure
RX="${TEST_TMP}/rootx"; mkdir -p "${RX}"; chmod 0644 "${RX}"
assert_contains "$( ( export LLMCTL_CGROUP_ROOT="${RX}"; reserve_combined_check 100 512 decide-tiny ) 2>&1 >/dev/null || true )" "is not readable" "RV6-06: root at mode 0644 -> refused as not readable"
# RV6-07: under the manager scope every unit is this user's own, a container scope included: it is 'running'
MS="${TEST_TMP}/mscope"; mkdir -p "${MS}/app.slice" "${MS}/libpod-abc.scope"
mkunit "${MS}/libpod-abc.scope/llmctl-llama@decide-tiny.service" 100 64
mv=$( ( export LLMCTL_CGROUP_ROOT="${MS}"; capacity_json decide-tiny 2>/dev/null ) )
assert_eq "running self" "$(q "${mv}" 'd["profiles"]["decide-tiny"]["verdict"]+" "+d["llmctl"]["units"][0]["owner"]')" "RV6-07: manager scope -> unit (even in a .scope) is own, verdict running"
# RV6-10: an unreadable unit tree is recorded as an unreadable input, never as 'readable, zero units'
UL="${TEST_TMP}/ulocked"; mkdir -p "${UL}/app.slice"; chmod 000 "${UL}"
ud=$( ( export LLMCTL_CGROUP_ROOT="${UL}"; capacity_json decide-tiny 2>/dev/null ) )
chmod 755 "${UL}" "${RX}"
assert_eq "False" "$(q "${ud}" 'str(d["inputs"]["units"]["readable"])')" "RV6-10: inputs.units.readable is false when the tree cannot be read"

echo "== F5: reserve --json is valid JSON for a hostile cgroup path =="
J="${TEST_TMP}/fs-json"; newfs "${J}"
mkunit "${J}/system.slice/odd\"dir/llmctl-llama@x.service" 100 512
r="$(LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${J}" reserve_report --json)"
assert_eq 1 "$(q "${r}" 'len(d["units"])')" "F5: quote in the path -> valid JSON with the unit"
assert_contains "$(q "${r}" 'd["units"][0]["cgroup"]')" 'odd"dir' "F5: and the path round-trips"
J3="${TEST_TMP}/fs-json3"; newfs "${J3}"
mkunit "${J3}/system.slice/ctl"$'\001'"dir/llmctl-llama@x.service" 100 512
r="$(LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${J3}" reserve_report --json)"
assert_eq 1 "$(q "${r}" 'len(d["units"])')" "F5: a 0x01 control character in the path -> valid JSON"
J2="${TEST_TMP}/fs-json2"; newfs "${J2}"
mkunit "${J2}/system.slice/ctl"$'\t'"dir/llmctl-llama@x.service" 100 512
r="$(LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${J2}" reserve_report --json)"
assert_eq 1 "$(q "${r}" 'len(d["units"])')" "F5: a tab in the path -> valid JSON"
assert_eq 'True' "$(q "$(LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${EMPTY}" reserve_report --json)" 'd["units"]==[]')" "F5 control: empty tree"
UE=$( ( export LLMCTL_CGROUP_ROOT="${TEST_TMP}/no\"such"; reserve_report --json 2>/dev/null ) )
assert_contains "$(q "${UE}" 'd["units_error"]')" 'no"such' "F5: units_error carrying a double quote is valid JSON and round-trips"

test_finish
