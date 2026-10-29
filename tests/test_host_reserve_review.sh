#!/usr/bin/env bash
# test_host_reserve_review.sh - UNIT-CLASS (hermetic: fixture CPU count, meminfo, PSI, loadavg, cgroup tree, catalog).
# The findings of the 3.4.0 review round 1 (S1-S7) and the reviewer mutants it left alive (M01-M22), each pinned by a
# test that fails on the old code or on the mutant. Live evidence of the same contract (real units, real cgroups, a real
# decision model) is in docs/qa/2026-10-28-host-reserve/; this suite proves the arithmetic and the wiring only.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
export LLMCTL_DRY_RUN=1
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
# shellcheck disable=SC1090
for l in common os_detect hardware catalog; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
export LLMCTL_HOST_MEM_MB=32768

# q <json> <expr>: the expressions are literals written in THIS file (test-authored), never external input
q() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$@"; }
mkunit() { # <name> <cpu.max> <memory.max bytes|max> [memory.current bytes]
  local d="${LLMCTL_CGROUP_ROOT}/app.slice/$1"; mkdir -p "${d}"
  printf 'populated 1\n' > "${d}/cgroup.events"; printf '%s\n' "$2" > "${d}/cpu.max"; printf '%s\n' "$3" > "${d}/memory.max"
  printf '%s\n' "${4:-0}" > "${d}/memory.current"
}
clean_units() { rm -rf "${LLMCTL_CGROUP_ROOT:?}/app.slice"; }
MIB=1048576

echo "== M01: Rc rounds UP (ceil), not down: 10 CPUs, no SMT -> 3 reserved =="
LLMCTL_HOST_CPUS=10 LLMCTL_CPU_SYSFS="${TEST_TMP}/no-sysfs" reserve_compute
assert_eq "3 7" "${RSV_RC} ${RSV_BC}" "10 CPUs: ceil(2.5) = 3 reserved, 7 for models"

echo "== S6: per-model CPU caps can only get stricter =="
LLMCTL_CHAT_CPU_PCT=100 reserve_compute
assert_eq 6 "${RSV_CHAT_CPUS}" "CHAT_CPU_PCT=100 is clamped back to 50% of Bc (6)"
LLMCTL_DECIDE_CPU_PCT=100 reserve_compute
assert_eq 3 "${RSV_DECIDE_CPUS}" "DECIDE_CPU_PCT=100 is clamped back to 25% of Bc (3)"
LLMCTL_CHAT_CPU_PCT=20 reserve_compute
assert_eq 2 "${RSV_CHAT_CPUS}" "CHAT_CPU_PCT=20 is stricter and honoured (2)"
LLMCTL_RESERVE_CPU_PCT=95 reserve_compute
assert_eq "15 1" "${RSV_RC} ${RSV_BC}" "RESERVE_CPU_PCT=95 is stricter and honoured (no 90% ceiling): 15 reserved, 1 for models"
LLMCTL_RESERVE_MEM_MIN_MB=999999999 reserve_compute
assert_eq "1 0" "${RSV_MEM_SHORT} ${RSV_BM}" "a huge MEM_MIN leaves no model memory: short, Bm 0 (never a 512 MiB floor)"

echo "== M06: a small host whose model budget is under 512 MiB is short and every start is refused =="
LLMCTL_HOST_MEM_MB=4500 reserve_compute
assert_eq "1 404" "${RSV_MEM_SHORT} ${RSV_BM}" "4500 MiB host: Rm 4096, Bm 404, short"
LLMCTL_HOST_MEM_MB=4700 reserve_compute
assert_eq "0 604" "${RSV_MEM_SHORT} ${RSV_BM}" "4700 MiB host: Bm 604, not short (negative control)"
doc="$(LLMCTL_HOST_MEM_MB=4500 capacity_json decide-tiny)"
assert_eq "does_not_fit" "$(q "${doc}" 'd["profiles"]["decide-tiny"]["verdict"]')" "4500 MiB host: decide-tiny does_not_fit"
assert_contains "$(q "${doc}" '"; ".join(d["profiles"]["decide-tiny"]["reasons"])')" "< 512 MiB" "the reason names the short model budget"
assert_rc 75 "4500 MiB host: the combined check refuses even a tiny unit" \
  env LLMCTL_HOST_MEM_MB=4500 bash -c "source '${LLMCTL_ROOT}/lib/common.sh'; source '${LLMCTL_ROOT}/lib/reserve.sh'; reserve_combined_check 100 256 t"
reserve_compute

echo "== S7: dotted and tenant names map to the right class =="
assert_eq "qwen2.5-coder" "$(reserve_base_profile qwen2.5-coder " decide-tiny decide-2b ")" "a dotted profile name is kept whole"
assert_eq "decide-tiny" "$(reserve_base_profile decide-tiny.2 " decide-tiny ")" "an instance suffix of a decision profile is dropped"
assert_eq "decide-tiny" "$(reserve_base_profile acme--decide-tiny.3 " decide-tiny ")" "a tenant prefix and instance suffix are both dropped"
assert_eq "foo.1" "$(reserve_base_profile foo.1 " foo ")" "ordinal 1 is never an instance suffix (the primary has none)"
assert_eq decide "$(reserve_profile_class acme--decide-tiny)" "tenant row of a decision profile is decide"
assert_eq chat "$(reserve_profile_class qwen2.5-coder)" "a dotted chat-looking name stays chat"

echo "== S2 / M10 / M11: capacity_admit fails CLOSED =="
set +e
( capacity_json() { return 1; }; capacity_admit decide-tiny ) > /dev/null 2> "${TEST_TMP}/fail.err"; rc=$?
set -e
assert_eq 75 "${rc}" "capacity measurement fails -> refused 75 (was: admitted)"
assert_file_contains "${TEST_TMP}/fail.err" "llmctl-fallback: none" "fail-closed refusal carries the fallback line"
set +e
( capacity_json() { echo ''; }; capacity_admit decide-tiny ) > /dev/null 2>&1; rc=$?
set -e
assert_eq 75 "${rc}" "capacity measurement prints nothing -> refused 75"
set +e
( capacity_json() { echo '{"profiles": {"decide-tiny": {"verdict": "bogus", "threads": 3}}}'; }; capacity_admit decide-tiny ) > /dev/null 2>&1; rc=$?
set -e
assert_eq 75 "${rc}" "an unreadable verdict -> refused 75"
set +e; capacity_admit no-such-profile > /dev/null 2> "${TEST_TMP}/unk.err"; rc=$?; set -e
assert_eq 75 "${rc}" "a profile the capacity check does not know -> refused 75 (was: admitted)"
assert_file_contains "${TEST_TMP}/unk.err" "llmctl-fallback:" "unknown-profile refusal carries the fallback line"
assert_rc 0 "negative control: an idle host admits decide-tiny" capacity_admit decide-tiny

echo "== M02: the combined RAM boundary is inclusive (used + new == Bm fits) =="
reserve_compute   # 32 GiB -> Bm 26215
mkunit 'llmctl-llama@big.service' '100000 100000' $(( (26215 - 4096) * MIB ))
assert_rc 0 "used 22119 + new 4096 == Bm 26215: fits" reserve_combined_check 100 4096 t
clean_units; mkunit 'llmctl-llama@big.service' '100000 100000' $(( (26215 - 4096 + 1) * MIB ))
assert_rc 75 "used 22120 + new 4096 > Bm: refused" reserve_combined_check 100 4096 t
clean_units

echo "== M03 / M09: a running unit with MemoryMax=max counts as the WHOLE model memory budget =="
mkunit 'llmctl-llama@old.service' '100000 100000' 'max'
assert_rc 75 "bash combined check: CPU fits (1 + 1 <= 12), unlimited memory refuses" reserve_combined_check 100 256 t
doc="$(capacity_json decide-tiny)"
assert_eq "does_not_fit" "$(q "${doc}" 'd["profiles"]["decide-tiny"]["verdict"]')" "capacity: unlimited-memory unit -> does_not_fit"
assert_contains "$(q "${doc}" '"; ".join(d["profiles"]["decide-tiny"]["reasons"])')" "memory" "capacity: the reason names memory"
clean_units

echo "== S4: instance-suffixed units are seen as their profile running =="
mkunit 'llmctl-llama@decide-tiny.2.service' '300000 100000' $(( 1280 * MIB )) $(( 300 * MIB ))
doc="$(capacity_json decide-tiny)"
assert_eq "decide-tiny" "$(q "${doc}" 'd["llmctl"]["units"][0]["base_profile"]')" "decide-tiny.2 maps to base profile decide-tiny"
assert_eq "running" "$(q "${doc}" 'd["profiles"]["decide-tiny"]["verdict"]')" "decide-tiny is running (instance 2)"
printf 'some avg10=95.00 avg60=0 avg300=0 total=0\n' > "${LLMCTL_CPU_PSI_FILE}"
doc="$(capacity_json decide-tiny)"
assert_eq "degraded llmctl stop decide-tiny" "$(q "${doc}" 'd["llmctl"]["units"][0]["status"]+" "+d["llmctl"]["units"][0]["suggest"]')" \
  "a degraded instance-2 unit: the stop suggestion names the base profile"
printf 'some avg10=0.00 avg60=0 avg300=0 total=0\n' > "${LLMCTL_CPU_PSI_FILE}"
mkunit 'llmctl-llama@big.service' '900000 100000' $(( 2048 * MIB ))
doc="$(capacity_json decide-tiny)"
assert_eq "local" "$(q "${doc}" 'd["fallback"]["recommended"]')" "no new decision model fits, but one runs (instance 2) -> local"
clean_units

echo "== S5: fallback is never local when no decision model fits or runs =="
_cat_fx="${TEST_TMP}/catalog-nodecide.json"
python3 - "${LLMCTL_CATALOG}" "${_cat_fx}" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
for k in [k for k, v in d["profiles"].items() if "decide" in (v.get("capability") or []) or v.get("engine") == "onnx"]:
    del d["profiles"][k]
json.dump(d, open(sys.argv[2], "w"))
PYEOF
doc="$(LLMCTL_CATALOG="${_cat_fx}" capacity_json small)"
assert_eq "fits" "$(q "${doc}" 'd["profiles"]["small"]["verdict"]')" "the chat profile fits"
assert_eq "None" "$(q "${doc}" 'd["largest_decision_fit"]')" "no decision profile exists"
assert_eq "none" "$(q "${doc}" 'd["fallback"]["recommended"]')" "a fitting CHAT profile never makes the fallback local"
export LLMCTL_TEST_HOSTED_KEY="sk-test-SECRET-VALUE-0123456789"
doc="$(LLMCTL_CATALOG="${_cat_fx}" capacity_json small)"
assert_eq "cloud" "$(q "${doc}" 'd["fallback"]["recommended"]')" "with a hosted key variable: cloud"
unset LLMCTL_TEST_HOSTED_KEY
mkunit 'llmctl-llama@big.service' '1200000 100000' $(( 2048 * MIB ))
doc="$(capacity_json decide-tiny small)"
assert_eq "none" "$(q "${doc}" 'd["fallback"]["recommended"]')" "a refused named profile never recommends local"
clean_units

# scheduler-level paths (start, decide scale, restart)
source "${LLMCTL_ROOT}/lib/scheduler.sh"

echo "== S1: decide scale goes through the same capacity admission (75 + fallback line, nothing started) =="
mkunit 'llmctl-llama@big.service' '1200000 100000' $(( 2048 * MIB ))
set +e; "${LLMCTL_ROOT}/bin/llmctl" decide scale decide-tiny 1 > "${TEST_TMP}/scale.out" 2>&1; rc=$?; set -e
assert_eq 75 "${rc}" "decide scale over capacity exits 75 (was: started without the capacity check)"
assert_file_contains "${TEST_TMP}/scale.out" "llmctl-fallback:" "decide scale refusal prints the fallback line"
assert_eq "" "$(find "${LLMCTL_RUNTIME_DIR}" -maxdepth 1 -name 'decide-tiny*.run' 2>/dev/null)" "a refused scale started nothing"
printf 'some avg10=95.00 avg60=0 avg300=0 total=0\n' > "${LLMCTL_CPU_PSI_FILE}"
clean_units
set +e; "${LLMCTL_ROOT}/bin/llmctl" decide scale decide-tiny 1 > "${TEST_TMP}/scale2.out" 2>&1; rc=$?; set -e
assert_eq 75 "${rc}" "decide scale under CPU pressure exits 75"
assert_file_contains "${TEST_TMP}/scale2.out" "llmctl-fallback:" "a pressure-gate refusal also prints the fallback line"
printf 'some avg10=0.00 avg60=0 avg300=0 total=0\n' > "${LLMCTL_CPU_PSI_FILE}"
set +e; "${LLMCTL_ROOT}/bin/llmctl" decide scale decide-tiny 1 > "${TEST_TMP}/scale3.out" 2>&1; rc=$?; set -e
assert_eq 0 "${rc}" "negative control: decide scale on an idle host succeeds (dry run)"
"${LLMCTL_ROOT}/bin/llmctl" decide scale decide-tiny 0 > /dev/null 2>&1 || true

echo "== S3: restart goes through the capacity admission, without counting the unit it replaces =="
mkunit 'llmctl-llama@decide-tiny.service' '1200000 100000' $(( 2048 * MIB )) $(( 1500 * MIB ))
assert_rc 0 "the replaced unit alone uses the whole budget: restart admitted (its own limits are not counted)" \
  sched_restart_admit decide-tiny
clean_units
mkunit 'llmctl-llama@decide-tiny.service' '300000 100000' $(( 1280 * MIB ))
mkunit 'llmctl-llama@big.service' '1200000 100000' $(( 2048 * MIB ))
set +e; sched_restart_admit decide-tiny > /dev/null 2> "${TEST_TMP}/restart.err"; rc=$?; set -e
assert_eq 75 "${rc}" "another unit holds the whole CPU budget: restart refused 75"
assert_file_contains "${TEST_TMP}/restart.err" "llmctl-fallback:" "restart refusal prints the fallback line"
clean_units
mkunit 'llmctl-llama@decide-tiny.service' '300000 100000' $(( 1280 * MIB ))
mkunit 'llmctl-llama@big.service' '1000000 100000' $(( 2048 * MIB ))
set +e; sched_restart_admit decide-tiny > /dev/null 2> "${TEST_TMP}/restart2.err"; rc=$?; set -e
assert_eq 75 "${rc}" "only 2 of 3 CPUs left: restart (which keeps its limits) refuses"
assert_file_contains "${TEST_TMP}/restart2.err" "llmctl stop decide-tiny && llmctl start decide-tiny" "it says how to restart with fewer threads"
clean_units
set +e; "${LLMCTL_ROOT}/bin/llmctl" restart decide-tiny > /dev/null 2>&1; rc=$?; set -e
[[ "${rc}" != 75 ]] && assert_eq 1 1 "bin/llmctl restart on an idle host is not refused by the capacity gate (rc ${rc})" \
  || assert_eq "not 75" 75 "bin/llmctl restart on an idle host is not refused by the capacity gate"
mkunit 'llmctl-llama@big.service' '1200000 100000' $(( 2048 * MIB ))
set +e; "${LLMCTL_ROOT}/bin/llmctl" restart decide-tiny > "${TEST_TMP}/restart3.out" 2>&1; rc=$?; set -e
assert_eq 75 "${rc}" "bin/llmctl restart is wired to the admission (75 with the budget full)"
clean_units

# memory: the replaced unit's resident memory comes back when it stops (7168 MiB available + 2048 resident - 2048 footprint
# = 7168 >= the 6553 MiB reserve); not adding it back would refuse a restart that changes nothing
printf 'MemTotal:       33554432 kB\nMemFree:        7340032 kB\nMemAvailable:   7340032 kB\n' > "${LLMCTL_MEMINFO_FILE}"
mkunit 'llmctl-llama@decide-tiny.service' '300000 100000' $(( 2560 * MIB )) $(( 2048 * MIB ))
assert_rc 0 "restart: the replaced unit's resident memory is counted as coming back" sched_restart_admit decide-tiny
clean_units
mkunit 'llmctl-llama@other.service' '300000 100000' $(( 2560 * MIB )) $(( 2048 * MIB ))
assert_rc 75 "negative control: the same memory held by ANOTHER unit refuses a start" capacity_admit decide-tiny
clean_units
printf 'MemTotal:       33554432 kB\nMemFree:        31457280 kB\nMemAvailable:   31457280 kB\n' > "${LLMCTL_MEMINFO_FILE}"
mkunit 'llmctl-llama@decide-tiny.service' '300000 100000' $(( 1280 * MIB ))
mkunit 'llmctl-llama@decide-tiny.2.service' '300000 100000' $(( 1280 * MIB ))
mkunit 'llmctl-llama@big.service' '900000 100000' $(( 2048 * MIB ))
assert_rc 75 "another instance of the same profile running does not make the restart 'running' (admitted unchecked)" \
  sched_restart_admit decide-tiny
clean_units

echo "== M21: reduced threads reach --threads of the started engine =="
mkunit 'llmctl-llama@big.service' '1000000 100000' $(( 2048 * MIB ))
CAP_THREADS=""; capacity_admit decide-tiny 2>/dev/null
assert_eq 2 "${CAP_THREADS}" "capacity_admit: reduced to 2 threads"
SCHED_ARGS=()
_RSV_CAP_OVERRIDE="${CAP_THREADS}" sched_build_launch decide-tiny cpu 18080 2048 0 1 off f16
assert_contains " ${SCHED_ARGS[*]} " " --threads 2 " "the launch carries the reduced --threads 2"
set +e; ( _sched_start_impl decide-tiny ) > "${TEST_TMP}/start-red.out" 2>&1; rc=$?; set -e
assert_eq 0 "${rc}" "start with reduced threads succeeds (dry run)"
grep -rh -- '--threads' "${LLMCTL_SERVICES_DIR}" "${TEST_TMP}/start-red.out" 2>/dev/null > "${TEST_TMP}/threads.txt" || true
assert_file_contains "${TEST_TMP}/threads.txt" "--threads 2 " "start end to end: the recorded launch has --threads 2 (not the 3-CPU cap)"
"${LLMCTL_ROOT}/bin/llmctl" stop decide-tiny > /dev/null 2>&1 || true
clean_units

echo "== M18: the unit's ExecStartPre gate enforces the combined budget (svc_hook.sh gate) =="
HOOK="${LLMCTL_ROOT}/lib/svc_hook.sh"
mkunit 'llmctl-llama@decide-tiny.service' '300000 100000' $(( 1280 * MIB ))
mkunit 'llmctl-llama@big.service' '1200000 100000' $(( 2048 * MIB ))
set +e
LLMCTL_GATE_WAIT=0 LLMCTL_SELF_CGROUP="${LLMCTL_CGROUP_ROOT}/app.slice/llmctl-llama@decide-tiny.service" \
  bash "${HOOK}" gate decide-tiny > /dev/null 2> "${TEST_TMP}/gate.err"; rc=$?
set -e
assert_eq 75 "${rc}" "ExecStartPre (restart, boot, scale): 3 + 12 CPUs > 12 refused 75"
assert_contains "$(cat "${TEST_TMP}/gate.err")" "budget" "the gate message names the budget"
clean_units
mkunit 'llmctl-llama@decide-tiny.service' '300000 100000' $(( 1280 * MIB ))
mkunit 'llmctl-llama@small.service' '600000 100000' $(( 2048 * MIB ))
set +e
LLMCTL_GATE_WAIT=0 LLMCTL_SELF_CGROUP="${LLMCTL_CGROUP_ROOT}/app.slice/llmctl-llama@decide-tiny.service" \
  bash "${HOOK}" gate decide-tiny > /dev/null 2>&1; rc=$?
set -e
assert_eq 0 "${rc}" "negative control: 3 + 6 <= 12 passes, and the gate's own cgroup is not double-counted"
clean_units

echo "== M22: the decision smoke server runs with the DECISION cap, not the chat cap =="
stub="${TEST_TMP}/stub-llama-server"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s/stub-args.txt"\nexit 1\n' "${TEST_TMP}" > "${stub}"; chmod +x "${stub}"
source "${LLMCTL_ROOT}/lib/download.sh"
model="${TEST_TMP}/fake.gguf"; : > "${model}"; _DL_EVIDENCE="${TEST_TMP}/smoke-evidence.log"
set +e
( LLMCTL_LLAMA_SERVER="${stub}" LLMCTL_SMOKE=1 LLMCTL_SMOKE_TIMEOUT=2 _dl_smoke_test_decision decide-2b "${model}" ) > /dev/null 2>&1
set -e
if [[ -s "${TEST_TMP}/stub-args.txt" ]]; then
  assert_contains " $(cat "${TEST_TMP}/stub-args.txt") " " --threads 3 " "decision smoke (decide-2b, letter-logit): --threads = decision cap 3 (chat cap is 6)"
else
  assert_eq "stub launched" "stub not launched" "decision smoke reached the server launch"
fi

test_finish
