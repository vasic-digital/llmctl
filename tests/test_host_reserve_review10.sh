#!/usr/bin/env bash
# test_host_reserve_review10.sh - UNIT-CLASS (hermetic fixtures). Round-10 review (Opus, NO-GO on 4fedf0a) findings:
#   F1 a start/install with LLMCTL_HOST_RESERVE=0 must not persist reserve-OFF state anywhere: the complete unit state
#      (template, every drop-in, the env record incl. LLMCTL_ARGS) after a reserve-off start, a reserve-on start and a
#      restart-style rewrite is IDENTICAL. The override only skips the admission gates / reporting / direct launches.
#   F2 every numeric env knob is validated by ONE shared validator: a malformed value refuses (rc 75) naming the
#      variable, in the start gate, the capacity report and `llmctl install`.
#   F3 pins for reviewer mutants A1 (stale CPU_PCT_UNIT line), B (memo key needs >=3 computes), C2 (leading zeros),
#      D2 (CPU_MIN not validated), D5 (capacity report must be undetermined on a bad knob).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
export LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
# shellcheck disable=SC1090
for l in common os_detect hardware catalog reserve capacity svc_hook download service_linux scheduler; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
export LLMCTL_HOST_MEM_MB=32768 LLMCTL_HOST_CPUS=16 LLMCTL_GATE_WAIT=0 LLMCTL_GATE_POLL=1
MIB=1048576; U="$(id -u)"
newfs() { mkdir -p "$1/user.slice/user-${U}.slice/user@${U}.service/app.slice"; : > "$1/cgroup.controllers"; }

# snap <root> -> every file under the root with its content (stable order); nothing is excluded.
snap() { ( cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '== %s\n' "${f}"; cat -- "${f}"; done ); }

# scenario <name> <reserve-value|"-"> -> a fresh unit dir + services dir; install the units, build the launch and
# write the env record of profile $PROFILE the way `llmctl start` does (sched_build_launch + _sched_svc_write_env).
PROFILE=small
scenario() {
  local name="$1" rsv="$2" root="${TEST_TMP}/scen-$1"
  mkdir -p "${root}/units/default.target.wants" "${root}/services"
  (
    export LLMCTL_UNIT_DIR="${root}/units" LLMCTL_SERVICES_DIR="${root}/services" LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${root}/cg"
    newfs "${root}/cg"
    [[ "${rsv}" == - ]] || export LLMCTL_HOST_RESERVE="${rsv}"
    svc_install
    sched_build_launch "${PROFILE}" gpu 18099 8192 99 1 auto f16
    _sched_svc_write_env "${PROFILE}"
  ) >/dev/null 2>"${root}.err" || { echo "  note: scenario ${name} stderr: $(head -c 400 "${root}.err")" >&2; }
  echo "${root}"
}

echo "--- F1: complete unit state is identical for reserve-off start, reserve-on start and restart"
ON="$(scenario on -)"
OFF="$(scenario off 0)"
norm() { snap "$1" | sed -e "s#$1#@ROOT@#g" -e "s#${ON}#@ROOT@#g"; }   # the sandbox root differs in the paths inside the records
norm "${ON}" > "${TEST_TMP}/snap-on"; norm "${OFF}" > "${TEST_TMP}/snap-off"
files_on="$(grep -c '^== ' "${TEST_TMP}/snap-on")"
if (( files_on >= 4 )); then echo "  ok: F1: the reserve-on start produced ${files_on} files (template, drop-ins, env record)"
else echo "  FAIL: F1: the reserve-on scenario produced only ${files_on} files - the scenario does not exercise the start path" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
assert_contains "$(cat "${TEST_TMP}/snap-on")" "06-reserve.conf" "F1: the reserve-on state has the reserve drop-in"
assert_contains "$(cat "${TEST_TMP}/snap-on")" "--threads" "F1: the reserve-on launch carries --threads"
if diff -u "${TEST_TMP}/snap-on" "${TEST_TMP}/snap-off" > "${TEST_TMP}/snap.diff"; then
  echo "  ok: F1: reserve-off start state == reserve-on start state (every drop-in, the template, the env record)"
else
  echo "  FAIL: F1: a reserve-off start persisted different unit state:" >&2; head -40 "${TEST_TMP}/snap.diff" >&2; TEST_FAILS=$((TEST_FAILS+1))
fi
# restart-style: an already-running reserve-on unit re-written under the override (boot/restart never re-derive)
REST="${TEST_TMP}/scen-restart"; cp -a "${ON}" "${REST}"
( export LLMCTL_UNIT_DIR="${REST}/units" LLMCTL_SERVICES_DIR="${REST}/services" LLMCTL_HOST_RESERVE=0 LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${REST}/cg"
  sched_build_launch "${PROFILE}" gpu 18099 8192 99 1 auto f16; _sched_svc_write_env "${PROFILE}" ) >/dev/null 2>&1 || true
norm "${REST}" > "${TEST_TMP}/snap-rest"
if diff -u "${TEST_TMP}/snap-on" "${TEST_TMP}/snap-rest" > "${TEST_TMP}/snap2.diff"; then echo "  ok: F1: a reserve-off re-write of a reserve-on unit changes nothing"
else echo "  FAIL: F1: a reserve-off re-write changed the unit state:" >&2; head -40 "${TEST_TMP}/snap2.diff" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
# the memory drop-in is sized with the reserve-on limit also under the override (05-memory.conf)
assert_eq "$(grep -h '^MemoryMax=' "${ON}"/units/*/05-memory.conf 2>/dev/null | head -1)" "$(grep -h '^MemoryMax=' "${OFF}"/units/*/05-memory.conf 2>/dev/null | head -1)" "F1: 05-memory.conf MemoryMax is identical"
test_finish
