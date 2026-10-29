#!/usr/bin/env bash
# test_host_reserve_review4.sh - UNIT-CLASS (hermetic: fixture meminfo, PSI, loadavg, cgroup tree, /proc thread census
# and plan; the only real processes are `sleep` children and a `flock` holder this suite starts, registers and kills).
# The findings of the 3.4.0 review round 4 and the reviewer mutants of that round that survived (Y03, Y04, Y05, Y09,
# Y11, Y13), each pinned by a test that fails on ea50536 or on the mutant. Live evidence of the same contract is in
# docs/qa/2026-10-28-host-reserve/review-r4/.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
export LLMCTL_DRY_RUN=1
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
# shellcheck disable=SC1090
for l in common os_detect hardware catalog reserve capacity; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
export LLMCTL_HOST_MEM_MB=32768
export LLMCTL_PROC_DIR="${TEST_TMP}/proc-fixture"; mkdir -p "${LLMCTL_PROC_DIR}"; t_proc_self "${LLMCTL_PROC_DIR}"

# q <json> <expr>: the expressions are literals written in THIS file (test-authored), never external input
q() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$@"; }
mkunit() { # <name> <cpu.max> <memory.max bytes> [memory.current bytes]
  local d="${LLMCTL_CGROUP_ROOT}/app.slice/$1"; mkdir -p "${d}"
  printf 'populated 1\n' > "${d}/cgroup.events"; printf '%s\n' "$2" > "${d}/cpu.max"; printf '%s\n' "$3" > "${d}/memory.max"
  printf '%s\n' "${4:-0}" > "${d}/memory.current"
}
clean_units() { rm -rf -- "${LLMCTL_CGROUP_ROOT:?}/app.slice"; }
MIB=1048576
REAL_KEY="sk-test-REALISH-0123456789abcdef"
G="${TEST_TMP}/garbage"; printf 'this is not a kernel file\nsome avg10=abc\nfull avg10=-\nMemAvailable: lots kB\n' > "${G}"
MISSING="${TEST_TMP}/no-such-input"
grc() { local rc=0; hw_pressure_gate 0 decide-tiny 2>/dev/null || rc=$?; echo "${rc}"; }

echo "== positive control: every input readable -> measured, fits, gate admits =="
doc="$(capacity_json decide-tiny)"
assert_eq "True fits" "$(q "${doc}" 'str(d["measurement"]["ok"])+" "+d["profiles"]["decide-tiny"]["verdict"]')" "all inputs readable: measured, decide-tiny fits"
assert_eq "[]" "$(q "${doc}" 'd["measurement"]["critical_inputs_unreadable"]')" "no critical input is unreadable"
assert_eq 0 "$(grc)" "all inputs readable: the start gate admits"

echo "== F1: an unreadable or unparseable verdict-critical input -> undetermined, exit 75, never local; the gate refuses =="
# check_case <label> <gate expected rc|-> <env assignment...>
check_case() {
  local label="$1" grc_want="$2"; shift 2
  local d rc=0
  d="$( export "$@"; capacity_json decide-tiny 2>/dev/null )" || true
  assert_eq "False undetermined" "$(q "${d}" 'str(d["measurement"]["ok"])+" "+d["profiles"]["decide-tiny"]["verdict"]' 2>/dev/null || echo unparseable)" "${label}: measurement not ok, verdict undetermined (was: fits)"
  assert_eq "none" "$(q "${d}" 'd["fallback"]["recommended"]' 2>/dev/null || echo unparseable)" "${label}: fallback none without a key (never local)"
  capacity_exit_code "${d}" decide-tiny >/dev/null 2>&1 || rc=$?
  assert_eq 75 "${rc}" "${label}: capacity exit code 75"
  if [[ "${grc_want}" != - ]]; then
    rc=0; ( export "$@"; hw_pressure_gate 0 decide-tiny ) >/dev/null 2>&1 || rc=$?
    assert_eq "${grc_want}" "${rc}" "${label}: the start gate refuses with 75 (was: admitted)"
  fi
}
check_case "meminfo unreadable"      75 LLMCTL_MEMINFO_FILE="${MISSING}"
check_case "meminfo garbage"         75 LLMCTL_MEMINFO_FILE="${G}"
check_case "memory PSI unreadable"   75 LLMCTL_PSI_FILE="${MISSING}"
check_case "memory PSI garbage"      75 LLMCTL_PSI_FILE="${G}"
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "${TEST_TMP}/psi-some-only"
check_case "memory PSI without full" 75 LLMCTL_PSI_FILE="${TEST_TMP}/psi-some-only"
check_case "CPU PSI unreadable"      75 LLMCTL_CPU_PSI_FILE="${MISSING}"
check_case "CPU PSI garbage"         75 LLMCTL_CPU_PSI_FILE="${G}"
check_case "loadavg unreadable"      75 LLMCTL_LOADAVG_FILE="${MISSING}"
check_case "loadavg garbage"         75 LLMCTL_LOADAVG_FILE="${G}"
check_case "cgroup root missing"     75 LLMCTL_CGROUP_ROOT="${MISSING}"
# the start gate reads no /proc thread census (capacity_admit does): "-" means the gate is not the instrument here
check_case "proc dir missing"        -  LLMCTL_PROC_DIR="${MISSING}"
check_case "all at once"             75 LLMCTL_MEMINFO_FILE="${MISSING}" LLMCTL_PSI_FILE="${MISSING}" LLMCTL_CPU_PSI_FILE="${MISSING}" \
  LLMCTL_LOADAVG_FILE="${MISSING}" LLMCTL_CGROUP_ROOT="${MISSING}" LLMCTL_PROC_DIR="${MISSING}"
# sharper garbage (mutant sweep, round 4): "abc" sorts ABOVE 80 in awk's string comparison, so a gate that accepted any
# value refused it for the wrong reason ("pressure too high"); "0x" sorts below, so only the parse check can refuse it.
printf 'some avg10=0x avg60=0.00 avg300=0.00 total=0\nfull avg10=0x avg60=0.00 avg300=0.00 total=0\n' > "${TEST_TMP}/psi-low-garbage"
check_case "CPU PSI low-sorting garbage"    75 LLMCTL_CPU_PSI_FILE="${TEST_TMP}/psi-low-garbage"
check_case "memory PSI low-sorting garbage" 75 LLMCTL_PSI_FILE="${TEST_TMP}/psi-low-garbage"
rc=0; LLMCTL_CPU_PSI_FILE="${TEST_TMP}/psi-low-garbage" reserve_cpu_gate decide-tiny 2>/dev/null || rc=$?
assert_eq 75 "${rc}" "CPU gate: a low-sorting garbage PSI value is refused by the parse check (was: admitted)"
# garbage only in the 5-minute field: the 1-minute value parses, so nothing crashes; the document must still not be built
# on a half-parsed load (the start gate reads only the 1-minute value, so it is not checked here)
printf '0.10 x 0.10 1/100 1\n' > "${TEST_TMP}/load-mid-garbage"
check_case "loadavg 5-minute field garbage" -  LLMCTL_LOADAVG_FILE="${TEST_TMP}/load-mid-garbage"
d="$(LLMCTL_MEMINFO_FILE="${MISSING}" LLMCTL_TEST_HOSTED_KEY="${REAL_KEY}" capacity_json decide-tiny)"
assert_eq "cloud hosted" "$(q "${d}" 'd["fallback"]["recommended"]+" "+d["fallback"]["route"]')" "with a hosted key set: cloud, route hosted"
assert_contains "$(q "${d}" 'd["measurement"]["reason"]')" "meminfo" "the reason names the unreadable input"
[[ "${d}" != *"${REAL_KEY}"* ]] && assert_eq 1 1 "the key VALUE never appears in the document" || assert_eq absent present "the key VALUE never appears in the document"
rc=0; LLMCTL_LOADAVG_FILE="${MISSING}" capacity_admit decide-tiny >/dev/null 2>&1 || rc=$?
assert_eq 75 "${rc}" "capacity_admit refuses (75) when loadavg is unreadable (was: admitted)"
# scope: the CPU inputs, the cgroup root and the census are critical only with the host reserve on (the CPU checks need them)
d="$(LLMCTL_HOST_RESERVE=0 LLMCTL_LOADAVG_FILE="${MISSING}" LLMCTL_CPU_PSI_FILE="${MISSING}" capacity_json decide-tiny)"
assert_eq "True" "$(q "${d}" 'd["measurement"]["ok"]')" "reserve off: CPU PSI/loadavg are informational (negative control of the scope)"
d="$(LLMCTL_GATE_CPU_CHECKS=0 LLMCTL_LOADAVG_FILE="${MISSING}" capacity_json decide-tiny)"
assert_eq "True" "$(q "${d}" 'd["measurement"]["ok"]')" "CPU checks off: loadavg is informational"
d="$(LLMCTL_IO_PSI_FILE="${MISSING}" capacity_json decide-tiny)"
assert_eq "True fits" "$(q "${d}" 'str(d["measurement"]["ok"])+" "+d["profiles"]["decide-tiny"]["verdict"]')" "io PSI unreadable: informational only, still measured"
rc=0; LLMCTL_GATE_CPU_CHECKS=0 LLMCTL_LOADAVG_FILE="${MISSING}" hw_pressure_gate 0 decide-tiny 2>/dev/null || rc=$?
assert_eq 0 "${rc}" "the PSI-only pre-switch gate (CPU checks off) does not read loadavg"

echo "== Y11: memory PSI full threshold boundary (2) =="
printf 'some avg10=0.00 avg60=0 avg300=0 total=0\nfull avg10=2.50 avg60=0 avg300=0 total=0\n' > "${TEST_TMP}/psi-full25"
printf 'some avg10=0.00 avg60=0 avg300=0 total=0\nfull avg10=1.50 avg60=0 avg300=0 total=0\n' > "${TEST_TMP}/psi-full15"
assert_eq "does_not_fit" "$(q "$(LLMCTL_PSI_FILE="${TEST_TMP}/psi-full25" capacity_json decide-tiny)" 'd["profiles"]["decide-tiny"]["verdict"]')" "PSI full 2.5 > 2: does_not_fit"
assert_eq "fits" "$(q "$(LLMCTL_PSI_FILE="${TEST_TMP}/psi-full15" capacity_json decide-tiny)" 'd["profiles"]["decide-tiny"]["verdict"]')" "PSI full 1.5 <= 2: fits"
rc=0; LLMCTL_PSI_FILE="${TEST_TMP}/psi-full25" hw_pressure_gate 0 decide-tiny 2>/dev/null || rc=$?; assert_eq 75 "${rc}" "gate: PSI full 2.5 refused"
rc=0; LLMCTL_PSI_FILE="${TEST_TMP}/psi-full15" hw_pressure_gate 0 decide-tiny 2>/dev/null || rc=$?; assert_eq 0 "${rc}" "gate: PSI full 1.5 admitted"

echo "== Y05: load threshold boundary (3 x CPUs) =="
reserve_compute; LIM=$(( RSV_GATE_LOAD_PER_CPU * RSV_N ))
printf '%s.50 0 0 1/1 1\n' "${LIM}" > "${TEST_TMP}/load-over"
printf '%s.50 0 0 1/1 1\n' "$(( LIM - 1 ))" > "${TEST_TMP}/load-under"
d="$(LLMCTL_LOADAVG_FILE="${TEST_TMP}/load-over" capacity_json decide-tiny)"
assert_eq "does_not_fit" "$(q "${d}" 'd["profiles"]["decide-tiny"]["verdict"]')" "load ${LIM}.5 > ${LIM}: does_not_fit"
assert_contains "$(q "${d}" '"; ".join(d["pressure"]["reasons"])')" "1-minute load" "the pressure reason names the load"
assert_eq "fits" "$(q "$(LLMCTL_LOADAVG_FILE="${TEST_TMP}/load-under" capacity_json decide-tiny)" 'd["profiles"]["decide-tiny"]["verdict"]')" "load $(( LIM - 1 )).5: fits"
rc=0; LLMCTL_LOADAVG_FILE="${TEST_TMP}/load-over" reserve_cpu_gate decide-tiny 2>/dev/null || rc=$?; assert_eq 75 "${rc}" "gate: load over the limit refused"
rc=0; LLMCTL_LOADAVG_FILE="${TEST_TMP}/load-under" reserve_cpu_gate decide-tiny 2>/dev/null || rc=$?; assert_eq 0 "${rc}" "gate: load under the limit admitted"

echo "== Y03: a tenant's own units are matched as '<tenant>--', never by a bare prefix =="
doc0="$(capacity_json)"; BC="$(q "${doc0}" 'd["reserve"]["cpus_model_budget"]')"
mkunit 'llmctl-llama@t10--decide-tiny.service' '300000 100000' $(( 1280 * MIB ))
mkunit 'llmctl-llama@big.service' "$(( (BC - 3) * 100000 )) 100000" $(( 2048 * MIB ))
assert_eq "none" "$(q "$(LLMCTL_TENANT_ID=t1 capacity_json)" 'd["fallback"]["recommended"]')" "tenant t1 does not count t10--decide-tiny as its own decision unit"
assert_eq "local" "$(q "$(LLMCTL_TENANT_ID=t10 capacity_json)" 'd["fallback"]["recommended"]')" "positive control: tenant t10 does"
clean_units

echo "== Y13: AllowedCPUs and CPUAffinity are exactly the model CPU set (the reserved CPUs are never allowed) =="
reserve_compute
body="$(reserve_dropin_body decide-tiny)"
allowed="$(sed -n 's/^AllowedCPUs=//p' <<<"${body}")"; aff="$(sed -n 's/^CPUAffinity=//p' <<<"${body}")"
assert_eq "${RSV_CPUSET}" "${allowed}" "AllowedCPUs == the model CPU set"
assert_eq "${RSV_CPUSET//,/ }" "${aff}" "CPUAffinity == the model CPU set"
model_exp="$(comm -23 <(seq 0 $(( RSV_N - 1 )) | sort) <(_rsv_expand "${RSV_RESERVED_SET}" | sort) | sort -n | tr '\n' ' ')"
assert_eq "${model_exp% }" "$(_rsv_expand "${allowed}" | sort -n | tr '\n' ' ' | sed 's/ $//')" "AllowedCPUs = all online CPUs minus the reserved set (independent computation)"
[[ -z "$(comm -12 <(_rsv_expand "${allowed}" | sort) <(_rsv_expand "${RSV_RESERVED_SET}" | sort))" ]] && assert_eq 1 1 "no reserved CPU is allowed" || assert_eq none overlap "no reserved CPU is allowed"

echo "== Y04: the capacity memory limit and the unit drop-in agree for an unmeasured GPU profile (floor 6144 MiB) =="
source "${LLMCTL_ROOT}/lib/service_linux.sh"
_cap_plan_probe() { printf '{"profiles": {"decide-tiny": {"ram_mb": 1000, "mode": "gpu", "vram_provenance": "estimate", "fits": true}}}\n'; }
d="$(capacity_json decide-tiny)"
want="$(_svc_profile_caps 1000 32768 gpu estimate)"
assert_eq "${want##* }" "$(q "${d}" 'd["profiles"]["decide-tiny"]["headroom"]["mem_limit_need_mb"]')" "capacity mem_limit_need_mb == _svc_profile_caps MemoryMax (gpu, estimate)"
assert_eq 6144 "${want##* }" "the unmeasured GPU floor is 6144 MiB"
_cap_plan_probe() { set -o pipefail; hw_probe_json | catalog_plan_json; }

echo "== Y09: the tree collector re-snapshots until a pass adds nothing (a child missed by the first snapshot is caught) =="
( sleep 300 & wait ) &
ROOTP=$!; test_bg_register "${ROOTP}"
CHILD=""; for _ in $(seq 1 50); do CHILD="$(ps -o pid= --ppid "${ROOTP}" 2>/dev/null | awk 'NR==1{print $1}')"; [[ -n "${CHILD}" ]] && break; sleep 0.1; done
test_bg_register "${CHILD}"
CNT="${TEST_TMP}/ppid.calls"; echo 0 > "${CNT}"
_cap_ppid_table() { local n; n="$(cat "${CNT}")"; echo $(( n + 1 )) > "${CNT}"
  if (( n == 0 )); then ps -e -o pid=,ppid= | awk -v c="${CHILD}" '$1 != c'; else ps -e -o pid=,ppid=; fi; }
_cap_tree_collect "${ROOTP}"
[[ " ${_CAP_KT_ALL[*]} " == *" ${CHILD} "* ]] && assert_eq 1 1 "the child the first snapshot missed is collected by a later pass" \
  || assert_eq "collected" "missed" "the child the first snapshot missed is collected by a later pass"
_cap_tree_kill
kill -CONT "${ROOTP}" "${CHILD}" 2>/dev/null || true
kill -KILL "${CHILD}" 2>/dev/null || true; wait "${ROOTP}" 2>/dev/null || true
unset -f _cap_ppid_table
source "${LLMCTL_ROOT}/lib/capacity.sh"

echo "== F3: the JSON names what the consumption count covers =="
d="$(capacity_json)"
assert_eq "${LLMCTL_CGROUP_ROOT}" "$(q "${d}" 'd["llmctl"]["consumption_scope"]["cgroup_root"]')" "consumption_scope.cgroup_root is the counted root"
assert_contains "$(q "${d}" 'd["llmctl"]["consumption_scope"]["not_counted"]')" "other users" "consumption_scope says other users' units are not counted"

echo "== F2: llmctl capacity accepts --json in any position and rejects unknown options =="
rc=0; "${LLMCTL_ROOT}/bin/llmctl" capacity decide-tiny --json > "${TEST_TMP}/f2.json" 2>/dev/null || rc=$?
assert_eq 0 "${rc}" "capacity decide-tiny --json exits 0 (was: 75, --json read as a profile)"
assert_eq "fits" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["profiles"]["decide-tiny"]["verdict"])' "${TEST_TMP}/f2.json" 2>/dev/null || echo not-json)" "the output is the JSON document"
rc=0; "${LLMCTL_ROOT}/bin/llmctl" capacity --bogus > /dev/null 2> "${TEST_TMP}/f2.err" || rc=$?
assert_eq 2 "${rc}" "an unknown option is a usage error (exit 2)"
assert_contains "$(cat "${TEST_TMP}/f2.err")" "usage" "the usage error says usage"

echo "== F4: restart admission and restart run under the scheduler lock =="
source "${LLMCTL_ROOT}/lib/scheduler.sh"
assert_eq 1 "$(grep -c 'sched_restart "\$1"' "${LLMCTL_ROOT}/bin/llmctl")" "bin/llmctl restart calls sched_restart"
INLOCK="${TEST_TMP}/inlock"
sched_restart_admit() { [[ "${_SCHED_LOCK_OWNER}" == "${BASHPID}" ]] && echo admit-locked >> "${INLOCK}" || echo admit-unlocked >> "${INLOCK}"; }
svc_restart() { [[ "${_SCHED_LOCK_OWNER}" == "${BASHPID}" ]] && echo restart-locked >> "${INLOCK}" || echo restart-unlocked >> "${INLOCK}"; }
rc=0; sched_restart decide-tiny || rc=$?
assert_eq "0 admit-locked restart-locked" "${rc} $(tr '\n' ' ' < "${INLOCK}" | sed 's/ $//')" "admission and restart both ran while this process held the lock"
mkdir -p "${LLMCTL_RUNTIME_DIR}"
# the holder IS the sleeping process (exec), so killing the registered pid leaves no orphan behind
( exec 9>"${LLMCTL_RUNTIME_DIR}/.scheduler.lock"; flock -x 9; exec sleep 30 ) &
HOLD=$!; test_bg_register "${HOLD}"; sleep 0.3
: > "${INLOCK}"; rc=0; LLMCTL_SCHED_LOCK_WAIT=1 sched_restart decide-tiny 2>/dev/null || rc=$?
assert_eq "2 " "${rc} $(cat "${INLOCK}")" "a held lock makes the restart wait and give up (2) without admitting or restarting"
kill "${HOLD}" 2>/dev/null || true; wait "${HOLD}" 2>/dev/null || true

test_finish
