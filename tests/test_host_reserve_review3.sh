#!/usr/bin/env bash
# test_host_reserve_review3.sh - UNIT-CLASS (hermetic: fixture CPU count, meminfo, PSI, loadavg, cgroup tree, catalog,
# /proc thread census; the only real processes are `sleep` children this suite starts, registers and kills itself).
# The findings of the 3.4.0 review round 3 and the reviewer mutants of that round that survived (X03, X04, X05, X07,
# X08, X09, X11), each pinned by a test that fails on bbfd380 or on the mutant. Live evidence of the same contract is in
# docs/qa/2026-10-28-host-reserve/review-r3/.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
export LLMCTL_DRY_RUN=1
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
# shellcheck disable=SC1090
for l in common os_detect hardware catalog reserve capacity; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
export LLMCTL_HOST_MEM_MB=32768
export LLMCTL_PROC_DIR="${TEST_TMP}/proc-fixture"; mkdir -p "${LLMCTL_PROC_DIR}"; t_proc_self "${LLMCTL_PROC_DIR}"   # the thread census reads no real /proc

# q <json> <expr>: the expressions are literals written in THIS file (test-authored), never external input
q() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$@"; }
mkunit() { # <name> <cpu.max> <memory.max bytes|max> [memory.current bytes]
  local d="${LLMCTL_CGROUP_ROOT}/app.slice/$1"; mkdir -p "${d}"
  printf 'populated 1\n' > "${d}/cgroup.events"; printf '%s\n' "$2" > "${d}/cpu.max"; printf '%s\n' "$3" > "${d}/memory.max"
  printf '%s\n' "${4:-0}" > "${d}/memory.current"
}
clean_units() { rm -rf -- "${LLMCTL_CGROUP_ROOT:?}/app.slice"; }
ms_now() { date +%s%N | cut -c1-13; }
pstate() { awk '{print $3}' "/proc/$1/stat" 2>/dev/null || echo gone; }
# the real start-time reader (a verbatim copy of lib/capacity.sh _cap_pid_start), so a test can override and restore it
_cap_pid_start_real() {
  local s f; s="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  s="${s##*) }"; read -r -a f <<<"${s}"; [[ -n "${f[19]:-}" ]] || return 1; printf '%s' "${f[19]}"
}
restore_pid_start() { _cap_pid_start() { _cap_pid_start_real "$1"; }; }
MIB=1048576
REAL_KEY="sk-test-REALISH-0123456789abcdef"   # 32 characters, not a known dummy value
doc0="$(capacity_json)"
BC="$(q "${doc0}" 'd["reserve"]["cpus_model_budget"]')"; DCAP="$(q "${doc0}" 'd["reserve"]["decide_cpu_cap"]')"
RM="$(q "${doc0}" 'd["reserve"]["mem_reserved_mb"]')"
FULL="$(( BC * 100000 )) 100000"

echo "== R3-1: decision_local counts only THIS tenant's own decision instances, never another tenant's =="
mkunit 'llmctl-llama@t1--decide-tiny.service' '300000 100000' $(( 1280 * MIB ))
mkunit 'llmctl-llama@big.service' "$(( (BC - 3) * 100000 )) 100000" $(( 2048 * MIB ))
doc="$(LLMCTL_TENANT_ID=t2 capacity_json)"
assert_eq "[]" "$(q "${doc}" 'sorted(p for p,v in d["profiles"].items() if v["class"]=="decide" and v["verdict"]!="does_not_fit")')" \
  "precondition: tenant t2 has no decision profile that fits (the CPU budget is held)"
assert_eq "none none" "$(q "${doc}" 'd["fallback"]["recommended"]+" "+d["fallback"]["route"]')" \
  "tenant t2 with only t1's decide unit healthy: fallback none (was: local, route local)"
assert_eq "cloud hosted" "$(LLMCTL_TEST_HOSTED_KEY="${REAL_KEY}" LLMCTL_TENANT_ID=t2 capacity_json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["fallback"]["recommended"], d["fallback"]["route"])')" \
  "tenant t2 with a hosted key set: cloud, route hosted (never local)"
doc="$(capacity_json)"
assert_eq "none" "$(q "${doc}" 'd["fallback"]["recommended"]')" "the single-host (no tenant) view does not count tenant t1's unit either"
doc="$(LLMCTL_TENANT_ID=t1 capacity_json)"
assert_eq "local local" "$(q "${doc}" 'd["fallback"]["recommended"]+" "+d["fallback"]["route"]')" \
  "positive control: tenant t1's own healthy decide unit is local for t1"
clean_units
mkunit 'llmctl-llama@decide-tiny.2.service' '300000 100000' $(( 1280 * MIB ))
mkunit 'llmctl-llama@big.service' "$(( (BC - 3) * 100000 )) 100000" $(( 2048 * MIB ))
assert_eq "local" "$(q "$(capacity_json)" 'd["fallback"]["recommended"]')" "positive control: this host's own instance .2 is local"
assert_eq "none" "$(q "$(LLMCTL_TENANT_ID=t2 capacity_json)" 'd["fallback"]["recommended"]')" "but not for tenant t2"
clean_units
mkunit 'llmctl-llama@t2--decide-tiny.2.service' '300000 100000' $(( 1280 * MIB ))
mkunit 'llmctl-llama@big.service' "$(( (BC - 3) * 100000 )) 100000" $(( 2048 * MIB ))
assert_eq "local" "$(q "$(LLMCTL_TENANT_ID=t2 capacity_json)" 'd["fallback"]["recommended"]')" "positive control: tenant t2's own instance .2 is local for t2"
clean_units

echo "== X05: the undetermined document never recommends local =="
doc="$(_cap_undetermined_doc "test reason" decide-tiny)"
assert_eq "none none None" "$(q "${doc}" 'd["fallback"]["recommended"]+" "+d["fallback"]["route"]+" "+str(d["fallback"]["key_variable"])')" \
  "no key: recommended none, route none"
doc="$(LLMCTL_TEST_HOSTED_KEY="${REAL_KEY}" _cap_undetermined_doc "test reason" decide-tiny)"
assert_eq "cloud hosted LLMCTL_TEST_HOSTED_KEY" "$(q "${doc}" 'd["fallback"]["recommended"]+" "+d["fallback"]["route"]+" "+d["fallback"]["key_variable"]')" \
  "a real key set: recommended cloud, route hosted, the variable NAME"

echo "== X11: MemAvailable below the host RAM reserve is pressure =="
cp -- "${LLMCTL_MEMINFO_FILE}" "${TEST_TMP}/meminfo.saved"
printf 'MemTotal:       33554432 kB\nMemFree:        1024 kB\nMemAvailable:   %s kB\n' $(( (RM - 512) * 1024 )) > "${LLMCTL_MEMINFO_FILE}"
doc="$(capacity_json)"
assert_eq "False" "$(q "${doc}" 'd["pressure"]["ok"]')" "MemAvailable ${RM}-512 MiB < the ${RM} MiB reserve: pressure.ok false"
assert_contains "$(q "${doc}" '"; ".join(d["pressure"]["reasons"])')" "host reserve" "the reason names the host reserve"
printf 'MemTotal:       33554432 kB\nMemFree:        1024 kB\nMemAvailable:   %s kB\n' $(( (RM + 512) * 1024 )) > "${LLMCTL_MEMINFO_FILE}"
assert_eq "True" "$(q "$(capacity_json)" 'd["pressure"]["ok"]')" "negative control: ${RM}+512 MiB available is no pressure"
cp -- "${TEST_TMP}/meminfo.saved" "${LLMCTL_MEMINFO_FILE}"

echo "== X07 / X08: the CPU boundaries (exactly 1 CPU left; exactly the decision cap left) =="
mkunit 'llmctl-llama@big.service' "$(( (BC - 1) * 100000 )) 100000" $(( 2048 * MIB ))
doc="$(capacity_json decide-tiny)"
assert_eq "fits_with_reduced_threads 1" "$(q "${doc}" 'd["profiles"]["decide-tiny"]["verdict"]+" "+str(d["profiles"]["decide-tiny"]["threads"])')" \
  "exactly 100% CPU left: fits with 1 thread (not does_not_fit)"
clean_units
mkunit 'llmctl-llama@big.service' "$(( (BC - DCAP) * 100000 )) 100000" $(( 2048 * MIB ))
doc="$(capacity_json decide-tiny)"
assert_eq "fits ${DCAP}" "$(q "${doc}" 'd["profiles"]["decide-tiny"]["verdict"]+" "+str(d["profiles"]["decide-tiny"]["threads"])')" \
  "exactly the ${DCAP}-CPU decision cap left: fits with the full cap (not reduced)"
clean_units

echo "== X09 / R3-6: the time bound is wall-clock elapsed time, not a count of loop iterations =="
hang() { command sleep 30; }
s="$(ms_now)"; rc=0; _cap_bounded 1 "${TEST_TMP}/b1.out" hang || rc=$?; el=$(( $(ms_now) - s ))
assert_eq 124 "${rc}" "a 1 s bound on a 30 s command returns 124"
(( el >= 900 && el <= 1600 )) && assert_eq 1 1 "it returns after the bound (${el} ms, 900..1600)" || assert_eq "900..1600 ms" "${el} ms" "it returns after the bound"
# slow the polling loop down (each poll sleep now takes 0.3 s): an iteration-count bound would run three times too long
s="$(ms_now)"; rc=0; ( sleep() { command sleep 0.3; }; _cap_bounded 1 "${TEST_TMP}/b2.out" hang ) || rc=$?; el=$(( $(ms_now) - s ))
assert_eq 124 "${rc}" "slow polling: still 124"
(( el <= 1700 )) && assert_eq 1 1 "slow polling: still bounded by wall-clock time (${el} ms <= 1700)" || assert_eq "<= 1700 ms" "${el} ms" "slow polling: bounded by wall-clock time (was ~3.3 s)"
rc=0; _cap_bounded 2 "${TEST_TMP}/b3.out" echo ok || rc=$?
assert_eq "0 ok" "${rc} $(cat "${TEST_TMP}/b3.out")" "negative control: a fast command returns its own rc and output"

echo "== X03 / X04 / R3-7: the measurement tree kill (collect stops each pid, re-checks it, kills only matching pids) =="
if ! declare -F _cap_tree_collect >/dev/null || ! declare -F _cap_tree_kill >/dev/null; then
  assert_eq "_cap_tree_collect + _cap_tree_kill" "missing" "the tree kill is split into collect and kill (testable phases)"
else
( command sleep 600; : ) & root=$!; test_bg_register "${root}"
child=""; for _ in 1 2 3 4 5 6 7 8 9 10; do child="$(pgrep -P "${root}" || true)"; [[ -n "${child}" ]] && break; command sleep 0.1; done
test_bg_register "${child}"
_cap_tree_collect "${root}"
assert_eq "T T" "$(pstate "${root}") $(pstate "${child}")" "collect STOPs every pid of the tree (no new children while it is collected)"
assert_eq "${root} ${child}" "${_CAP_KT_ALL[*]}" "collect records the root and its child, parent first"
_cap_pid_start() { if [[ "$1" == "${child}" ]]; then echo "reused-pid"; else _cap_pid_start_real "$1"; fi; }
_cap_tree_kill
command sleep 0.3
assert_eq "gone" "$(pstate "${root}")" "the root whose start time still matches is killed"
if [[ "$(pstate "${child}")" != gone ]]; then assert_eq 1 1 "a pid whose start time changed (pid reused) is NOT killed"
else assert_eq "alive" "killed" "a pid whose start time changed (pid reused) is NOT killed"; fi
restore_pid_start
kill -KILL "${child}" 2>/dev/null || true
# R3-7: the start time is re-read AFTER the STOP; a mismatch (pid reused between the read and the STOP) is CONTinued and
# skipped, never left stopped and never collected
( command sleep 600; : ) & root=$!; test_bg_register "${root}"
child=""; for _ in 1 2 3 4 5 6 7 8 9 10; do child="$(pgrep -P "${root}" || true)"; [[ -n "${child}" ]] && break; command sleep 0.1; done
test_bg_register "${child}"
: > "${TEST_TMP}/pstart.count"
_cap_pid_start() {
  if [[ "$1" == "${child}" ]]; then
    local n; n=$(( $(wc -l < "${TEST_TMP}/pstart.count") + 1 )); echo x >> "${TEST_TMP}/pstart.count"
    if (( n == 1 )); then _cap_pid_start_real "$1"; else echo "changed-${n}"; fi
  else _cap_pid_start_real "$1"; fi
}
_cap_tree_collect "${root}"
assert_eq "${root}" "${_CAP_KT_ALL[*]}" "a pid whose start time changed after the STOP is not collected"
if [[ "$(pstate "${child}")" != T ]]; then assert_eq 1 1 "and it is CONTinued, not left stopped ($(pstate "${child}"))"
else assert_eq "not T" "T" "a mismatched pid is CONTinued, not left stopped"; fi
restore_pid_start
_cap_tree_kill; command sleep 0.3
assert_eq "gone" "$(pstate "${root}")" "the collected root is killed"
kill -KILL "${child}" 2>/dev/null || true
for p in "${root}" "${child}"; do wait "${p}" 2>/dev/null || true; done
fi

echo "== R3-5: a placeholder hosted key never routes to the hosted endpoint (by variable NAME, never the value) =="
mkunit 'llmctl-llama@big.service' "${FULL}" $(( 2048 * MIB ))
for v in x changeme CHANGEME your-key-here placeholder '<your-api-key>' '<put-your-hosted-api-key-here>' short-value-12 aaaaaaaaaaaaaaaaaaaaaaaa; do
  doc="$(LLMCTL_TEST_HOSTED_KEY="${v}" capacity_json decide-tiny)"
  assert_eq "none none" "$(q "${doc}" 'd["fallback"]["recommended"]+" "+d["fallback"]["route"]')" "placeholder key value (${#v} chars): fallback none"
  assert_eq "none" "$(LLMCTL_TEST_HOSTED_KEY="${v}" _cap_fallback_name)" "placeholder key value: the refusal line says none"
  assert_eq "none" "$(q "$(LLMCTL_TEST_HOSTED_KEY="${v}" _cap_undetermined_doc t decide-tiny)" 'd["fallback"]["recommended"]')" "placeholder key: undetermined fallback none"
done
doc="$(LLMCTL_TEST_HOSTED_KEY="${REAL_KEY}" capacity_json decide-tiny)"
assert_eq "cloud hosted LLMCTL_TEST_HOSTED_KEY" "$(q "${doc}" 'd["fallback"]["recommended"]+" "+d["fallback"]["route"]+" "+d["fallback"]["key_variable"]')" \
  "negative control: a real-looking key routes hosted, by variable name"
case "${doc}" in *REALISH*) assert_eq "no key value" "key value in doc" "the key VALUE never appears in the document" ;;
  *) assert_eq 1 1 "the key VALUE never appears in the document" ;; esac
clean_units

echo "== R3-4: the anchor input contract: per-input source and read time, footprint provenance, RLIMIT_NPROC, throttling =="
printf 'usage_usec 5\nnr_periods 100\nnr_throttled 7\nthrottled_usec 900\n' > "${LLMCTL_CGROUP_ROOT}/cpu.stat"
mkunit 'llmctl-llama@decide-tiny.service' '300000 100000' $(( 1280 * MIB )) $(( 512 * MIB ))
printf 'usage_usec 5\nnr_periods 40\nnr_throttled 3\nthrottled_usec 1200\n' > "${LLMCTL_CGROUP_ROOT}/app.slice/llmctl-llama@decide-tiny.service/cpu.stat"
doc="$(capacity_json decide-2b)"
assert_eq "llmctl.capacity/1" "$(q "${doc}" 'd["schema"]')" "the schema name is unchanged (additive fields only)"
for k in meminfo loadavg psi_memory psi_cpu psi_io cgroup_memory_max cgroup_memory_current cgroup_cpu_max cgroup_cpu_stat units plan rlimit_nproc; do
  assert_eq "True" "$(q "${doc}" 'all(x in d["inputs"]["'"${k}"'"] for x in ("source","read_at","readable")) and isinstance(d["inputs"]["'"${k}"'"]["read_at"], (int, float))')" \
    "inputs.${k} carries source, read_at and readable"
done
assert_eq "${LLMCTL_MEMINFO_FILE} True" "$(q "${doc}" 'd["inputs"]["meminfo"]["source"]+" "+str(d["inputs"]["meminfo"]["readable"])')" "inputs.meminfo names the file it read"
assert_eq "declared" "$(q "${doc}" 'd["profiles"]["decide-2b"]["headroom"]["footprint_provenance"]')" "the candidate footprint is labelled declared (planner ram_mb)"
assert_contains "$(q "${doc}" 'd["profiles"]["decide-2b"]["headroom"]["footprint_source"]')" "ram_mb" "and names its source"
assert_eq "measured 512" "$(q "${doc}" 'd["llmctl"]["units"][0]["memory_current_provenance"]+" "+str(d["llmctl"]["units"][0]["memory_current_mb"])')" "a running unit's memory is labelled measured"
assert_eq "100 7 900" "$(q "${doc}" '"%(nr_periods)s %(nr_throttled)s %(throttled_usec)s" % d["host"]["cgroup"]["cpu_stat"]')" "the scope throttle counters (cpu.stat, §11.4.225)"
assert_eq "40 3 1200" "$(q "${doc}" '"%(nr_periods)s %(nr_throttled)s %(throttled_usec)s" % d["llmctl"]["units"][0]["cpu_stat"]')" "and each unit's throttle counters"
assert_eq "True" "$(q "${doc}" 'all(k in d["host"]["nproc"] for k in ("rlimit_soft","user_threads","headroom","source"))')" "host.nproc reports RLIMIT_NPROC, the user's threads and the headroom"
mkdir -p "${LLMCTL_PROC_DIR}/4242" "${LLMCTL_PROC_DIR}/4243" "${LLMCTL_PROC_DIR}/4244"
printf 'Name:\tx\nUid:\t%s\t%s\t%s\t%s\nThreads:\t6\n' "$(id -u)" "$(id -u)" "$(id -u)" "$(id -u)" > "${LLMCTL_PROC_DIR}/4242/status"
printf 'Name:\tx\nUid:\t%s\t%s\t%s\t%s\nThreads:\t4\n' "$(id -u)" "$(id -u)" "$(id -u)" "$(id -u)" > "${LLMCTL_PROC_DIR}/4243/status"
printf 'Name:\tx\nUid:\t%s\t0\t0\t0\nThreads:\t99\n' $(( $(id -u) + 1 )) > "${LLMCTL_PROC_DIR}/4244/status"
clean_units
doc="$(LLMCTL_NPROC_LIMIT=12 capacity_json decide-tiny)"
assert_eq "12 10 2" "$(q "${doc}" '"%(rlimit_soft)s %(user_threads)s %(headroom)s" % d["host"]["nproc"]')" "10 threads of this uid (another uid not counted), limit 12: headroom 2"
assert_eq "does_not_fit" "$(q "${doc}" 'd["profiles"]["decide-tiny"]["verdict"]')" "headroom 2 < the ${DCAP}-thread cap: does_not_fit"
assert_contains "$(q "${doc}" '"; ".join(d["profiles"]["decide-tiny"]["reasons"])')" "RLIMIT_NPROC" "the reason names RLIMIT_NPROC"
assert_eq "fits" "$(q "$(LLMCTL_NPROC_LIMIT=100 capacity_json decide-tiny)" 'd["profiles"]["decide-tiny"]["verdict"]')" "negative control: headroom 90 fits"
real_soft="$(python3 -c 'import resource; s=resource.getrlimit(resource.RLIMIT_NPROC)[0]; print(s if s != resource.RLIM_INFINITY else "None")')"
assert_eq "${real_soft}" "$(q "$(LLMCTL_NPROC_LIMIT=999999999 capacity_json)" 'd["host"]["nproc"]["rlimit_soft"]')" \
  "LLMCTL_NPROC_LIMIT can only lower the limit, never raise it above the real RLIMIT_NPROC"
cp -- "${LLMCTL_MEMINFO_FILE}" "${TEST_TMP}/meminfo.saved"; chmod 000 "${LLMCTL_MEMINFO_FILE}"
if [[ -r "${LLMCTL_MEMINFO_FILE}" ]]; then assert_eq 1 1 "(running as root: the unreadable-input case is skipped)"
else assert_eq "False" "$(q "$(capacity_json)" 'd["inputs"]["meminfo"]["readable"]')" "an unreadable input is recorded unreadable, never defaulted"; fi
chmod 644 "${LLMCTL_MEMINFO_FILE}"; cp -- "${TEST_TMP}/meminfo.saved" "${LLMCTL_MEMINFO_FILE}"
rm -f -- "${LLMCTL_CGROUP_ROOT:?}/cpu.stat"

test_finish
