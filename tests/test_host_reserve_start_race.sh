#!/usr/bin/env bash
# test_host_reserve_start_race.sh - UNIT-CLASS (hermetic cgroup-tree fixture). Round-8 finding 10 ("start-time race"):
# hk_gate (ExecStartPre) admits a unit, then the unit's cgroup is EMPTY for a moment (the gate process has exited, the
# engine is not forked yet). A second gate that runs in that window censuses the first unit as "not populated" and
# admits too, so two units together exceed the model budget. Fix: an admitted unit leaves a short-lived admission
# record that the census counts while the unit's cgroup is not populated yet (lib/reserve.sh reserve_admit_record).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
export LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
# shellcheck disable=SC1090
for l in common os_detect hardware catalog reserve svc_hook; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
export LLMCTL_HOST_MEM_MB=32768 LLMCTL_HOST_CPUS=16 LLMCTL_GATE_WAIT=0 LLMCTL_GATE_POLL=1
export LLMCTL_ADMIT_DIR="${TEST_TMP}/admit"
printf 'MemTotal:       33554432 kB\nMemFree:        31457280 kB\nMemAvailable:   31457280 kB\n' > "${LLMCTL_MEMINFO_FILE}"
printf 'some avg10=0.00 avg60=0 avg300=0 total=0\n' > "${LLMCTL_CPU_PSI_FILE}"
reserve_compute   # 16 CPUs: model budget 12 CPUs = 1200 %

mkunit() { # <name> <cpu.max> <memory.max MiB> <populated 0|1>
  local d="${LLMCTL_CGROUP_ROOT}/app.slice/$1"; mkdir -p "${d}"
  printf 'populated %s\nfrozen 0\n' "$4" > "${d}/cgroup.events"; printf '%s\n' "$2" > "${d}/cpu.max"
  printf '%s\n' $(( $3 * 1048576 )) > "${d}/memory.max"
}
setpop() { printf 'populated %s\nfrozen 0\n' "$2" > "${LLMCTL_CGROUP_ROOT}/app.slice/$1/cgroup.events"; }
gate_as() { # <unit> -> rc of hk_gate run "inside" that unit's cgroup
  ( export LLMCTL_SELF_CGROUP="${LLMCTL_CGROUP_ROOT}/app.slice/$1"; hk_gate "${1#llmctl-llama@}" ) >/dev/null 2>&1
}
A='llmctl-llama@a.service'; B='llmctl-llama@b.service'

echo "--- gate A admitted, then the empty-cgroup window, then gate B (A 600% + B 700% > 1200%)"
mkunit "${A}" '600000 100000' 4096 1
mkunit "${B}" '700000 100000' 4096 0     # B has not started yet
rc=0; gate_as "${A}" || rc=$?
assert_eq 0 "${rc}" "A is admitted on an empty host"
setpop "${A}" 0            # ExecStartPre process exited, ExecStart not forked yet: the cgroup is empty
rc=0; gate_as "${B}" || rc=$?
assert_eq 75 "${rc}" "B is REFUSED while A's cgroup is empty (admitted-but-not-yet-running units count)"

echo "--- once A is populated by its engine it is counted from the cgroup, not twice"
setpop "${A}" 1
mkunit "${B}" '600000 100000' 4096 1
rc=0; gate_as "${B}" || rc=$?
assert_eq 0 "${rc}" "A (populated, also recorded) + B = 1200% <= 1200%: admitted, A not double counted"

echo "--- an expired admission record stops counting (a start that never happened)"
setpop "${A}" 0
mkunit "${B}" '700000 100000' 4096 1
find "${LLMCTL_ADMIT_DIR}" -type f -exec touch -d '10 minutes ago' {} + 2>/dev/null || true
rc=0; gate_as "${B}" || rc=$?
assert_eq 0 "${rc}" "a record older than the TTL is ignored"
echo "--- a record whose unit cgroup no longer exists stops counting"
rm -rf "${LLMCTL_ADMIT_DIR:?}"
mkunit "${A}" '600000 100000' 4096 1; gate_as "${A}" || true
rm -rf "${LLMCTL_CGROUP_ROOT:?}/app.slice/${A}"
rc=0; gate_as "${B}" || rc=$?
assert_eq 0 "${rc}" "no cgroup, no reservation"

echo "--- a refused gate leaves no record"
rm -rf "${LLMCTL_ADMIT_DIR:?}"
mkunit "${A}" '600000 100000' 4096 1
mkunit "${B}" '700000 100000' 4096 1
rc=0; gate_as "${B}" || rc=$?
assert_eq 75 "${rc}" "B refused against populated A"
n="$(find "${LLMCTL_ADMIT_DIR}" -type f 2>/dev/null | wc -l || true)"
assert_eq 0 "${n}" "a refused gate writes no admission record"
test_finish
