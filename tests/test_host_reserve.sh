#!/usr/bin/env bash
# test_host_reserve.sh - UNIT-CLASS (hermetic; fixtures for CPU count, topology, PSI, load and the cgroup tree).
# Live evidence of the same contract against real units, real cgroups and a real model is in
# docs/qa/2026-10-28-host-reserve/ (scripts/qa/host_reserve_live.sh); this suite only proves the arithmetic and the wiring.
#
# Contract (3.4.0, lib/reserve.sh): a local model can never take the whole host.
#   CPU: Rc = max(2, ceil(25% N)) rounded up to whole physical cores, at most N-1; models may use Bc = N - Rc;
#        a chat profile gets max(1, Bc/2) CPUs, a decision profile max(1, Bc/4); llama.cpp gets --threads = that cap.
#   RAM: Rm = max(4096 MiB, 20% T); models together may be limited to Bm = T - Rm; no unit's MemoryMax exceeds Bm.
#   Units: CPUQuota + CPUAffinity, Nice 15, CPUWeight 20, IOWeight 20, OOMScoreAdjust 800, MemorySwapMax 0.
#   Gate: refuse (75) at CPU PSI some avg10 > 80, 1-minute load > 3 x N, or when the running units + the new one would
#         exceed Bc CPUs / Bm MiB. Looser settings than the floors are clamped back; LLMCTL_HOST_RESERVE=0 turns it off.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
export LLMCTL_DRY_RUN=1
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
# shellcheck disable=SC1090
for l in common os_detect hardware catalog; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done

echo "== CPU reserve arithmetic (16 CPUs, no SMT topology) =="
reserve_compute
assert_eq 4 "${RSV_RC}" "16 CPUs: 4 reserved (max(2, 25%))"
assert_eq 12 "${RSV_BC}" "16 CPUs: 12 for models"
assert_eq "0-3" "${RSV_RESERVED_SET}" "reserved CPUs are the lowest ones"
assert_eq "4-15" "${RSV_CPUSET}" "model CPU set"
assert_eq 6 "${RSV_CHAT_CPUS}" "chat cap = Bc/2"
assert_eq 3 "${RSV_DECIDE_CPUS}" "decision cap = Bc/4"

echo "== SMT topology: whole physical cores are reserved (siblings i and i+8) =="
for (( c = 0; c < 16; c++ )); do
  mkdir -p "${LLMCTL_CPU_SYSFS}/cpu${c}/topology"
  printf '%s,%s\n' "$(( c % 8 ))" "$(( c % 8 + 8 ))" > "${LLMCTL_CPU_SYSFS}/cpu${c}/topology/core_cpus_list"
done
reserve_compute
assert_eq "0-1,8-9" "${RSV_RESERVED_SET}" "SMT: cores 0 and 1 with both siblings"
assert_eq "2-7,10-15" "${RSV_CPUSET}" "SMT: model set excludes the siblings"
assert_eq 12 "${RSV_BC}" "SMT: 12 CPUs for models"

echo "== floors: looser is clamped, stricter is honoured =="
LLMCTL_RESERVE_CPU_PCT=5 LLMCTL_RESERVE_CPU_MIN=0 reserve_compute
assert_eq 4 "${RSV_RC}" "CPU_PCT=5 / CPU_MIN=0 clamped back to the floor (4 of 16)"
LLMCTL_RESERVE_CPU_PCT=50 reserve_compute
assert_eq 8 "${RSV_RC}" "CPU_PCT=50 is stricter: 8 reserved"
LLMCTL_HOST_CPUS=2 LLMCTL_CPU_SYSFS="${TEST_TMP}/none" reserve_compute
assert_eq 1 "${RSV_RC}" "2 CPUs: the reserve never takes the last CPU (Rc = N-1)"
assert_eq 1 "${RSV_BC}" "2 CPUs: 1 CPU for models"
assert_eq 1 "${RSV_CPU_SHORT}" "2 CPUs: the shortfall is flagged"

echo "== RAM reserve arithmetic =="
LLMCTL_HOST_MEM_MB=32768 reserve_compute
assert_eq 6553 "${RSV_RM}" "32 GiB: 20% reserved"
assert_eq 26215 "${RSV_BM}" "32 GiB: model RAM budget"
LLMCTL_HOST_MEM_MB=8192 reserve_compute
assert_eq 4096 "${RSV_RM}" "8 GiB: the 4 GiB floor wins"
LLMCTL_HOST_MEM_MB=32768 LLMCTL_RESERVE_MEM_PCT=1 LLMCTL_RESERVE_MEM_MIN_MB=1 reserve_compute
assert_eq 6553 "${RSV_RM}" "MEM_PCT=1 / MEM_MIN=1 clamped back to the floor"
# on a small host the 4 GiB minimum is what binds, so a looser MEM_MIN must be raised back to it (mutant M9)
LLMCTL_HOST_MEM_MB=8192 LLMCTL_RESERVE_MEM_MIN_MB=1 reserve_compute
assert_eq 4096 "${RSV_RM}" "8 GiB, MEM_MIN=1: the looser minimum is raised back to 4096"

echo "== per-profile drop-in, threads and unit directives =="
body="$(reserve_dropin_body decide-tiny)"
assert_contains "${body}" "CPUQuota=300%" "decision profile drop-in: 3 CPUs"
assert_contains "${body}" "CPUAffinity=2-7 10-15" "decision drop-in pins the model CPU set"
assert_contains "${body}" "OMP_NUM_THREADS=3" "decision drop-in caps OpenMP threads"
body="$(reserve_dropin_body small)"
assert_contains "${body}" "CPUQuota=600%" "chat profile drop-in: 6 CPUs"
assert_eq 3 "$(_RSV_CAP_OVERRIDE=9 reserve_cpu_cap decide-tiny)" "an override can never RAISE the cap"
assert_eq 2 "$(_RSV_CAP_OVERRIDE=2 reserve_cpu_cap small)" "an override lowers the cap (reduced threads)"

source "${LLMCTL_ROOT}/lib/service_linux.sh"
dirs="$(_svc_resource_directives)"
for kv in OOMScoreAdjust=800 Nice=15 CPUWeight=20 IOWeight=20 MemorySwapMax=0 CPUQuota=600%; do
  assert_contains "${dirs}" "${kv}" "unit template directive ${kv}"
done
dirs_off="$(LLMCTL_HOST_RESERVE=0 _svc_resource_directives)"
assert_contains "${dirs_off}" "OOMScoreAdjust=500" "LLMCTL_HOST_RESERVE=0 restores the 3.3 directives"
[[ "${dirs_off}" != *CPUQuota* ]] && assert_eq 1 1 "reserve off: no CPUQuota" || assert_eq none CPUQuota "reserve off: no CPUQuota"
caps="$(_svc_profile_caps 40000 32768 cpu measured)"
assert_eq 26215 "${caps##* }" "a huge footprint is capped at the model RAM budget, not 90% of RAM"

source "${LLMCTL_ROOT}/lib/scheduler.sh"
SCHED_ARGS=()
sched_build_launch decide-tiny cpu 18080 2048 0 1 off f16
args=" ${SCHED_ARGS[*]} "
assert_contains "${args}" " --threads 3 " "llama launch carries --threads = decision cap"
assert_contains "${args}" " --threads-batch 3 " "llama launch carries --threads-batch"
# round 10: the launch is persisted into the unit's env record, so it is ALWAYS derived with the reserve on; the override
# only skips admission (see tests/test_host_reserve_review10.sh for the full unit-state comparison)
LLMCTL_HOST_RESERVE=0 sched_build_launch decide-tiny cpu 18080 2048 0 1 off f16
assert_contains " ${SCHED_ARGS[*]} " " --threads 3 " "reserve override: the persisted launch still carries --threads (override does not persist)"

echo "== CPU gate =="
assert_rc 0 "no pressure: CPU gate passes" reserve_cpu_gate t
printf 'some avg10=91.00 avg60=50.00 avg300=10.00 total=1\n' > "${LLMCTL_CPU_PSI_FILE}"
assert_rc 75 "CPU PSI some 91 > 80: refused" reserve_cpu_gate t
assert_rc 0 "CPU PSI refusal skipped with the reserve off" env LLMCTL_HOST_RESERVE=0 bash -c "source '${LLMCTL_ROOT}/lib/common.sh'; source '${LLMCTL_ROOT}/lib/reserve.sh'; reserve_cpu_gate t"
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "${LLMCTL_CPU_PSI_FILE}"
printf '49.00 10.00 5.00 1/100 1\n' > "${LLMCTL_LOADAVG_FILE}"
assert_rc 75 "load 49 > 3 x 16: refused" reserve_cpu_gate t
printf '47.00 10.00 5.00 1/100 1\n' > "${LLMCTL_LOADAVG_FILE}"
assert_rc 0 "load 47 <= 48: passes" reserve_cpu_gate t
printf '0.00 0.00 0.00 1/100 1\n' > "${LLMCTL_LOADAVG_FILE}"
printf 'some avg10=85.00 avg60=0 avg300=0 total=1\n' > "${LLMCTL_CPU_PSI_FILE}"
assert_rc 75 "a looser LLMCTL_GATE_CPU_SOME_MAX=99 is clamped back to 80: PSI 85 still refused" env LLMCTL_GATE_CPU_SOME_MAX=99 bash -c "source '${LLMCTL_ROOT}/lib/common.sh'; source '${LLMCTL_ROOT}/lib/reserve.sh'; reserve_cpu_gate t"
assert_rc 75 "a stricter LLMCTL_GATE_CPU_SOME_MAX=50 is honoured" env LLMCTL_GATE_CPU_SOME_MAX=50 bash -c "printf 'some avg10=60.00 avg60=0 avg300=0 total=1\\n' > '${LLMCTL_CPU_PSI_FILE}'; source '${LLMCTL_ROOT}/lib/common.sh'; source '${LLMCTL_ROOT}/lib/reserve.sh'; reserve_cpu_gate t"
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "${LLMCTL_CPU_PSI_FILE}"
assert_rc 75 "hw_pressure_gate includes the CPU gate" env LLMCTL_CPU_PSI_FILE=<(printf 'some avg10=99.00 avg60=0 avg300=0 total=0\n') \
  bash -c "source '${LLMCTL_ROOT}/lib/common.sh'; source '${LLMCTL_ROOT}/lib/hardware.sh'; hw_pressure_gate 100 t"

echo "== memory gate uses the reserve, not a fixed 4 GiB =="
printf 'MemTotal:       33554432 kB\nMemFree:        8192000 kB\nMemAvailable:   8192000 kB\n' > "${LLMCTL_MEMINFO_FILE}"
assert_rc 75 "8000 MiB available - 2000 footprint < 6553 reserve: refused" hw_pressure_gate 2000 t
assert_rc 0 "same with the reserve off (4096): passes (negative control)" env LLMCTL_HOST_RESERVE=0 \
  bash -c "source '${LLMCTL_ROOT}/lib/common.sh'; source '${LLMCTL_ROOT}/lib/hardware.sh'; hw_pressure_gate 2000 t"
printf 'MemTotal:       33554432 kB\nMemFree:        31457280 kB\nMemAvailable:   31457280 kB\n' > "${LLMCTL_MEMINFO_FILE}"

echo "== combined budget across running units (cgroup tree fixture) =="
mkunit() { # <name> <cpu.max> <memory.max>
  local d="${LLMCTL_CGROUP_ROOT}/app.slice/$1"; mkdir -p "${d}"
  printf 'populated 1\nfrozen 0\n' > "${d}/cgroup.events"; printf '%s\n' "$2" > "${d}/cpu.max"; printf '%s\n' "$3" > "${d}/memory.max"
}
LLMCTL_HOST_MEM_MB=32768 reserve_compute
assert_rc 0 "no unit running: a 6-CPU unit fits" reserve_combined_check 600 4096 t
mkunit 'llmctl-llama@small.service' '600000 100000' $(( 4096 * 1048576 ))
assert_rc 0 "one 6-CPU unit + a 3-CPU one = 9 <= 12: fits" reserve_combined_check 300 4096 t
mkunit 'llmctl-llama@fast.service' '600000 100000' $(( 4096 * 1048576 ))
assert_rc 75 "two 6-CPU units + 3 = 15 > 12: refused" reserve_combined_check 300 4096 t
rm -rf "${LLMCTL_CGROUP_ROOT:?}/app.slice"
mkunit 'llmctl-llama@old.service' 'max 100000' 'max'
assert_rc 75 "a unit without limits counts as the whole budget" reserve_combined_check 100 1024 t
rm -rf "${LLMCTL_CGROUP_ROOT:?}/app.slice"
mkunit 'llmctl-llama@big.service' '100000 100000' $(( 24000 * 1048576 ))
assert_rc 75 "RAM: 24000 + 4096 > model budget: refused" env LLMCTL_HOST_MEM_MB=32768 \
  bash -c "source '${LLMCTL_ROOT}/lib/common.sh'; source '${LLMCTL_ROOT}/lib/reserve.sh'; reserve_combined_check 100 4096 t"
assert_rc 0 "the caller's own cgroup is never counted" env LLMCTL_HOST_MEM_MB=32768 \
  LLMCTL_SELF_CGROUP="${LLMCTL_CGROUP_ROOT}/app.slice/llmctl-llama@big.service" \
  bash -c "source '${LLMCTL_ROOT}/lib/common.sh'; source '${LLMCTL_ROOT}/lib/reserve.sh'; reserve_combined_check 100 4096 t"
rm -rf "${LLMCTL_CGROUP_ROOT:?}/app.slice"

echo "== reserve report JSON =="
mkunit 'llmctl-llama@decide-tiny.service' '300000 100000' $(( 1280 * 1048576 ))
js="$(reserve_report --json)"
assert_eq "True 12 6 3 1" "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); u=d["units"]; print(d["enabled"], d["cpus"]["model_budget"], d["cpus"]["chat_cap"], d["cpus"]["decide_cap"], len(u))' "${js}")" \
  "reserve --json: enabled, budget, caps, one running unit"
assert_eq "300 1280" "$(python3 -c 'import json,sys; u=json.loads(sys.argv[1])["units"][0]; print(u["cpu_quota_pct"], u["memory_max_mb"])' "${js}")" \
  "reserve --json reads the unit's limits back from its cgroup"
rm -rf "${LLMCTL_CGROUP_ROOT:?}/app.slice"

echo "== decision class: one catalog read, same rule as before (capability decide, or engine onnx) =="
assert_eq decide "$(reserve_profile_class decide-tiny)" "decide-tiny (capability decide) is a decision profile"
assert_eq decide "$(reserve_profile_class decide-nli)" "decide-nli (onnx) is a decision profile"
assert_eq chat "$(reserve_profile_class small)" "small is a chat profile"
assert_eq decide "$(reserve_profile_class decide-tiny.2)" "an instance suffix is stripped"
assert_eq chat "$(reserve_profile_class no-such-profile)" "an unknown profile is chat"
# the same rule on a fixture catalog: an onnx engine WITHOUT the decide capability is still a decision engine
_cat_fx="${TEST_TMP}/catalog-class.json"
python3 - "${LLMCTL_CATALOG}" "${_cat_fx}" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
v = dict(d["profiles"]["small"]); v["engine"] = "onnx"; v["capability"] = ["chat"]
d["profiles"]["onnx-chat"] = v
json.dump(d, open(sys.argv[2], "w"))
PYEOF
_cat_saved="${LLMCTL_CATALOG}"
LLMCTL_CATALOG="${_cat_fx}"
reserve_prime
assert_eq decide "$(reserve_profile_class onnx-chat)" "onnx engine without the decide capability is a decision engine"
echo "== the memos are keyed on their inputs (a cache can never return a stale answer) =="
# the catalog changes at the SAME path after the memo was primed: the class must follow the new content
python3 - "${_cat_fx}" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1])); d["profiles"]["onnx-chat"]["engine"] = "llama"
json.dump(d, open(sys.argv[1], "w"))
PYEOF
assert_eq chat "$(reserve_profile_class onnx-chat)" "catalog rewritten in place after priming: the class follows the new content"
LLMCTL_CATALOG="${_cat_saved}"
# the reserve memo follows a knob change made after priming
reserve_prime
_rc_before="${RSV_RC}"
LLMCTL_RESERVE_CPU_PCT=50 reserve_compute
assert_eq 8 "${RSV_RC}" "a knob changed after priming recomputes the reserve (was ${_rc_before})"

test_finish
