#!/usr/bin/env bash
# test_host_reserve_review11.sh - UNIT-CLASS (hermetic cgroup-tree fixture). Review round 5 finding F-A on ea68fc4:
#   F-A  the census dedupes admission records by canonical cgroup path and the FIRST record won, so a record of another
#        uid ("0 0 <victim cgroup>" in a lower-sorting per-uid dir) replaced the victim's real pending reservation and the
#        budget was breached (fail-open regression against 62b6a1f). Among records for one cgroup the gate now keeps the
#        MAXIMUM cpu and the MAXIMUM memory ("max" is the largest), so a forged record can only add counted budget.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
export LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
# shellcheck disable=SC1090
for l in common os_detect hardware catalog reserve svc_hook; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
export LLMCTL_HOST_MEM_MB=32768 LLMCTL_HOST_CPUS=16 LLMCTL_GATE_WAIT=0 LLMCTL_GATE_POLL=1
export LLMCTL_ADMIT_DIR="${TEST_TMP}/admit"
U="$(id -u)"
printf 'MemTotal:       33554432 kB\nMemFree:        31457280 kB\nMemAvailable:   31457280 kB\n' > "${LLMCTL_MEMINFO_FILE}"
printf 'some avg10=0.00 avg60=0 avg300=0 total=0\n' > "${LLMCTL_CPU_PSI_FILE}"
reserve_compute
FULLCPU=$(( RSV_BC * 100 ))
A='llmctl-llama@a.service'; B='llmctl-llama@b.service'
cgA="${LLMCTL_CGROUP_ROOT}/app.slice/${A}"; mkdir -p "${cgA}"; printf 'populated 0\nfrozen 0\n' > "${cgA}/cgroup.events"
mkdir -p "${LLMCTL_CGROUP_ROOT}/app.slice/${B}"
newbase() { rm -rf "${LLMCTL_ADMIT_DIR:?}"; mkdir -m 1777 "${LLMCTL_ADMIT_DIR}"; mkdir -m 755 "${LLMCTL_ADMIT_DIR}/llmctl-admit-${U}" "${LLMCTL_ADMIT_DIR}/llmctl-admit-$1"; }
# gate as B (100% CPU, 1024 MiB) with a stat shim that makes the per-uid dir $1 and its records genuinely owned by uid $1
gate_forged() { local FUID="$1"; ( stat() { case "$*" in *"%a %u"*llmctl-admit-${FUID}) echo "755 ${FUID}";; *"%u"*llmctl-admit-${FUID}/*) echo "${FUID}";; *) command stat "$@";; esac; }
  export LLMCTL_SELF_CGROUP="${LLMCTL_CGROUP_ROOT}/app.slice/${B}"; reserve_combined_check 100 1024 t >/dev/null 2>"${TEST_TMP}/gate.err" ); }
victim() { printf '%s 1024 %s\n' "${FULLCPU}" "${cgA}" > "${LLMCTL_ADMIT_DIR}/llmctl-admit-${U}/${A}"; }
forged() { printf '%s\n' "$2" > "${LLMCTL_ADMIT_DIR}/llmctl-admit-$1/${A}"; }

echo "=== F-A: a record of another uid cannot hide the victim's pending reservation"
for f in 0 99999; do   # 0 sorts before the victim's dir, 99999 after it: the result must not depend on the order
  newbase "${f}"; victim
  rc=0; gate_forged "${f}" || rc=$?
  assert_eq 75 "${rc}" "F-A control: victim record alone, forged dir ${f} empty -> budget breach (75)"
  forged "${f}" "0 0 ${cgA}"
  rc=0; gate_forged "${f}" || rc=$?
  assert_eq 75 "${rc}" "F-A: forged '0 0 <victim cgroup>' in dir ${f} does not hide the victim (75)"
  assert_contains "$(cat "${TEST_TMP}/gate.err")" "would be breached" "F-A: and it is the budget refusal"
  forged "${f}" "10 10 ${cgA}"
  rc=0; gate_forged "${f}" || rc=$?
  assert_eq 75 "${rc}" "F-A: forged smaller numbers in dir ${f} do not hide the victim (75)"
  forged "${f}" "max max ${cgA}"
  rc=0; gate_forged "${f}" || rc=$?
  assert_eq 75 "${rc}" "F-A: forged 'max max' only adds counted budget (75)"
done
echo "--- F-A control: with only a small victim record and a small forged record the start still fits (so the 75s above can fail)"
newbase 0; printf '100 512 %s\n' "${cgA}" > "${LLMCTL_ADMIT_DIR}/llmctl-admit-${U}/${A}"; forged 0 "0 0 ${cgA}"
rc=0; gate_forged 0 || rc=$?
assert_eq 0 "${rc}" "F-A control: small victim + small forged record -> fits (0)"
echo "--- F-A: the victim record may be the SMALLER one - the larger forged record is counted, never the first"
newbase 0; printf '100 512 %s\n' "${cgA}" > "${LLMCTL_ADMIT_DIR}/llmctl-admit-${U}/${A}"; forged 0 "${FULLCPU} 1024 ${cgA}"
rc=0; gate_forged 0 || rc=$?
assert_eq 75 "${rc}" "F-A: the larger of the duplicate records is counted (75)"
echo "--- F-A: 'max' is the largest number, in either record order (a small victim record plus a forged 'max max' counts the whole budget)"
for f in 0 99999; do
  newbase "${f}"; printf '100 512 %s\n' "${cgA}" > "${LLMCTL_ADMIT_DIR}/llmctl-admit-${U}/${A}"; forged "${f}" "max max ${cgA}"
  rc=0; gate_forged "${f}" || rc=$?
  assert_eq 75 "${rc}" "F-A: small victim record + forged 'max max' in dir ${f} -> the larger (max) is counted (75)"
done
test_finish
