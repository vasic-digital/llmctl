#!/usr/bin/env bash
# test_host_reserve_review2.sh - UNIT-CLASS (hermetic: fixture CPU count, meminfo, PSI, loadavg, cgroup tree, catalog;
# the only real process is a fake GPU probe that sleeps). The findings of the 3.4.0 review round 2 (F1-F6) and the
# reviewer mutants round 1 left alive (M03-M07, M10, M16, M20-M22), each pinned by a test that fails on be0707d or on the
# mutant. Live evidence of the same contract is in docs/qa/2026-10-28-host-reserve/review-r2/.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
export LLMCTL_DRY_RUN=1
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
# shellcheck disable=SC1090
for l in common os_detect hardware catalog reserve capacity; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
export LLMCTL_HOST_MEM_MB=32768

# q <json> <expr>: the expressions are literals written in THIS file (test-authored), never external input
q() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$@"; }
mkunit() { # <name> <cpu.max> <memory.max bytes|max> [memory.current bytes]
  local d="${LLMCTL_CGROUP_ROOT}/app.slice/$1"; mkdir -p "${d}"
  printf 'populated 1\n' > "${d}/cgroup.events"; printf '%s\n' "$2" > "${d}/cpu.max"; printf '%s\n' "$3" > "${d}/memory.max"
  printf '%s\n' "${4:-0}" > "${d}/memory.current"
}
clean_units() { rm -rf -- "${LLMCTL_CGROUP_ROOT:?}/app.slice"; }
admit_rc() { local rc=0; capacity_admit "$@" > /dev/null 2> "${TEST_TMP}/admit.err" || rc=$?; echo "${rc}"; }
MIB=1048576

echo "== F1: 'running' is the exact unit instance being started, never another instance of the profile =="
mkunit 'llmctl-llama@decide-tiny.2.service' '1200000 100000' $(( 2048 * MIB ))
doc="$(capacity_json decide-tiny)"
assert_eq "does_not_fit" "$(q "${doc}" 'd["profiles"]["decide-tiny"]["verdict"]')" \
  "decide-tiny.2 holds the whole CPU budget: decide-tiny (primary, not running) does_not_fit (was: running)"
assert_eq 75 "$(admit_rc decide-tiny)" "start decide-tiny is refused 75 (was: admitted unchecked)"
assert_file_contains "${TEST_TMP}/admit.err" "llmctl-fallback:" "the refusal carries the fallback line"
clean_units
mkunit 'llmctl-llama@decide-tiny.service' '1200000 100000' $(( 2048 * MIB ))
doc="$(capacity_json decide-tiny)"
assert_eq "running" "$(q "${doc}" 'd["profiles"]["decide-tiny"]["verdict"]')" "negative control: the primary itself running is 'running'"
assert_eq 0 "$(admit_rc decide-tiny)" "negative control: starting the running primary is a no-op admission"
clean_units

echo "== F1: another tenant's instance of the profile is consumption, never 'running' =="
mkunit 'llmctl-llama@t1--decide-tiny.service' '1200000 100000' $(( 2048 * MIB ))
assert_eq 75 "$(LLMCTL_TENANT_ID=t2 admit_rc decide-tiny)" "tenant t2 start while t1 holds the budget: refused 75 (was: admitted)"
assert_eq 75 "$(admit_rc decide-tiny)" "the single-host start while tenant t1 holds the budget: refused 75"
doc="$(LLMCTL_TENANT_ID=t1 capacity_json decide-tiny)"
assert_eq "running" "$(q "${doc}" 'd["profiles"]["decide-tiny"]["verdict"]')" "negative control: tenant t1's own row is 'running' for t1"
assert_eq 0 "$(LLMCTL_TENANT_ID=t1 admit_rc decide-tiny)" "negative control: t1 starting its own running row is admitted"
echo "== M21: the capacity base_profile drops the tenant prefix =="
doc="$(capacity_json)"
assert_eq "decide-tiny" "$(q "${doc}" 'd["llmctl"]["units"][0]["base_profile"]')" "t1--decide-tiny maps to base profile decide-tiny"
clean_units
mkunit 'llmctl-llama@t1--decide-tiny.service' 'max' $(( 2048 * MIB ))
doc="$(capacity_json)"
assert_eq "llmctl stop decide-tiny" "$(q "${doc}" 'd["llmctl"]["units"][0]["suggest"]')" "the stop suggestion names the base profile"
clean_units

echo "== F4: verdict_class and route carry the anchor vocabulary next to llmctl's names =="
doc="$(capacity_json decide-tiny)"
assert_eq "fits fits local" "$(q "${doc}" '" ".join([d["profiles"]["decide-tiny"]["verdict"], d["profiles"]["decide-tiny"]["verdict_class"], d["fallback"]["route"]])')" \
  "idle host: fits -> fits, route local"
mkunit 'llmctl-llama@big.service' '1000000 100000' $(( 2048 * MIB ))
doc="$(capacity_json decide-tiny)"
assert_eq "fits_with_reduced_threads fits_reduced" "$(q "${doc}" 'd["profiles"]["decide-tiny"]["verdict"]+" "+d["profiles"]["decide-tiny"]["verdict_class"]')" \
  "fits_with_reduced_threads -> fits_reduced"
clean_units
mkunit 'llmctl-llama@big.service' '1200000 100000' $(( 2048 * MIB ))
doc="$(capacity_json decide-tiny)"
assert_eq "does_not_fit does_not_fit none none" "$(q "${doc}" '" ".join([d["profiles"]["decide-tiny"]["verdict"], d["profiles"]["decide-tiny"]["verdict_class"], d["fallback"]["recommended"], d["fallback"]["route"]])')" \
  "does_not_fit -> does_not_fit, no key: route none"
export LLMCTL_TEST_HOSTED_KEY="sk-test-SECRET-VALUE-0123456789"
doc="$(capacity_json decide-tiny)"
assert_eq "cloud hosted" "$(q "${doc}" 'd["fallback"]["recommended"]+" "+d["fallback"]["route"]')" "key variable set: cloud -> route hosted"
case "${doc}" in *SECRET-VALUE*) assert_eq "no key value" "key value in doc" "the key VALUE never appears in the document" ;;
  *) assert_eq 1 1 "the key VALUE never appears in the document" ;; esac
unset LLMCTL_TEST_HOSTED_KEY
clean_units
mkunit 'llmctl-llama@decide-tiny.service' '300000 100000' $(( 1280 * MIB ))
doc="$(capacity_json decide-tiny)"
assert_eq "running None" "$(q "${doc}" 'd["profiles"]["decide-tiny"]["verdict"]+" "+str(d["profiles"]["decide-tiny"]["verdict_class"])')" \
  "running is unit state, not a candidate verdict: verdict_class null"
assert_eq "True" "$(q "${doc}" 'd["profiles"]["decide-tiny"]["running"]')" "the running state is its own boolean field"
assert_eq "llmctl.capacity/1 True" "$(q "${doc}" 'd["schema"]+" "+str(d["measurement"]["ok"])')" "schema unchanged; measurement.ok true"
clean_units

echo "== F2: a hung probe cannot hang the CLI or the admission: bounded, undetermined, 75, fallback =="
fake="${TEST_TMP}/fakebin"; mkdir -p "${fake}"
printf '#!/bin/sh\nprintf "%%s\\n" "$$" >> "%s/fake-probe.pids"\nexec sleep 600\n' "${TEST_TMP}" > "${fake}/nvidia-smi"
chmod +x "${fake}/nvidia-smi"
reap_fake() { local p; [[ -f "${TEST_TMP}/fake-probe.pids" ]] || return 0
  while read -r p; do test_bg_register "${p}"; done < "${TEST_TMP}/fake-probe.pids"; }
alive_fake() { local p n=0; [[ -f "${TEST_TMP}/fake-probe.pids" ]] || { echo 0; return; }
  while read -r p; do kill -0 "${p}" 2>/dev/null && n=$(( n + 1 )); done < "${TEST_TMP}/fake-probe.pids"; echo "${n}"; }
s=$(date +%s); set +e
env -u LLMCTL_FAKE_HW PATH="${fake}:${PATH}" LLMCTL_CAPACITY_TIMEOUT=3 LLMCTL_CAPACITY_PROBE_TIMEOUT=1 \
  timeout -k 2 40 "${LLMCTL_ROOT}/bin/llmctl" capacity --json decide-tiny > "${TEST_TMP}/hang.json" 2> "${TEST_TMP}/hang.err"; rc=$?
set -e; el=$(( $(date +%s) - s ))
reap_fake
assert_eq 75 "${rc}" "llmctl capacity --json with a hung GPU probe exits 75 (was: hangs; 124 = the test's own 40 s guard)"
(( el <= 8 )) && assert_eq 1 1 "it returns within the bound (${el} s <= 8 s with a 3 s budget)" \
  || assert_eq "<= 8 s" "${el} s" "it returns within the bound"
doc="$(cat "${TEST_TMP}/hang.json")"
if [[ -n "${doc}" ]] && q "${doc}" '1' > /dev/null 2>&1; then
  assert_eq "undetermined undetermined none False" "$(q "${doc}" '" ".join([d["profiles"]["decide-tiny"]["verdict"], d["profiles"]["decide-tiny"]["verdict_class"], d["fallback"]["route"], str(d["measurement"]["ok"])])')" \
    "the document says undetermined, route none, measurement.ok false"
  assert_eq "llmctl.capacity/1" "$(q "${doc}" 'd["schema"]')" "the undetermined document keeps the schema"
  assert_contains "$(q "${doc}" 'd["measurement"]["reason"]')" "LLMCTL_CAPACITY_PROBE_TIMEOUT" \
    "the PROBE bound (1 s) fired first and is named in measurement.reason"
else
  assert_eq "a JSON document" "no document" "the CLI prints an undetermined document"
fi
assert_file_contains "${TEST_TMP}/hang.err" "llmctl-fallback: none" "the CLI prints the fallback line (never local)"
sleep 1; assert_eq 0 "$(alive_fake)" "no hung probe process is left behind"
: > "${TEST_TMP}/fake-probe.pids"
# no profile named: an undetermined measurement still exits 75 with the fallback line (never 0 "nothing degraded")
set +e
env -u LLMCTL_FAKE_HW PATH="${fake}:${PATH}" LLMCTL_CAPACITY_TIMEOUT=3 LLMCTL_CAPACITY_PROBE_TIMEOUT=1 \
  timeout -k 2 40 "${LLMCTL_ROOT}/bin/llmctl" capacity > "${TEST_TMP}/hang2.out" 2> "${TEST_TMP}/hang2.err"; rc=$?
set -e
reap_fake
assert_eq 75 "${rc}" "llmctl capacity (no profile named, human output) with a hung probe exits 75"
assert_file_contains "${TEST_TMP}/hang2.out" "UNDETERMINED" "the human output says UNDETERMINED"
assert_file_contains "${TEST_TMP}/hang2.err" "llmctl-fallback: none" "and prints the fallback line"
sleep 1; assert_eq 0 "$(alive_fake)" "no hung probe process is left behind (no profile named)"
: > "${TEST_TMP}/fake-probe.pids"
s=$(date +%s); set +e
env -u LLMCTL_FAKE_HW PATH="${fake}:${PATH}" LLMCTL_CAPACITY_TIMEOUT=3 LLMCTL_TEST_HOSTED_KEY=x timeout -k 2 40 bash -c '
  set -uo pipefail; for l in common os_detect hardware catalog reserve capacity; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
  capacity_admit decide-tiny' > /dev/null 2> "${TEST_TMP}/hang-admit.err"; rc=$?
set -e; el=$(( $(date +%s) - s ))
reap_fake
assert_eq 75 "${rc}" "capacity_admit (start/switch/restart/scale) with a hung GPU probe refuses 75"
(( el <= 8 )) && assert_eq 1 1 "the admission returns within the bound (${el} s)" || assert_eq "<= 8 s" "${el} s" "the admission returns within the bound"
assert_file_contains "${TEST_TMP}/hang-admit.err" "llmctl-fallback: cloud" "with a key variable set the fallback is cloud"
assert_file_contains "${TEST_TMP}/hang-admit.err" "could not be determined" "the message says the capacity could not be determined"
sleep 1; assert_eq 0 "$(alive_fake)" "no hung probe process is left behind by the admission"
: > "${TEST_TMP}/fake-probe.pids"
echo "== F2: the WHOLE-measurement bound holds when a step outside the probe hangs (a /proc read that never returns) =="
mkfifo "${TEST_TMP}/meminfo.fifo"
s=$(date +%s); set +e
LLMCTL_MEMINFO_FILE="${TEST_TMP}/meminfo.fifo" LLMCTL_CAPACITY_TIMEOUT=2 timeout -k 2 40 bash -c '
  set -uo pipefail; for l in common os_detect hardware catalog reserve capacity; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
  capacity_json decide-tiny' > "${TEST_TMP}/fifo.json" 2>/dev/null; rc=$?
set -e; el=$(( $(date +%s) - s ))
assert_eq 0 "${rc}" "capacity_json returns (rc 0, a document) instead of hanging on the read"
(( el <= 6 )) && assert_eq 1 1 "within the 2 s whole budget (${el} s)" || assert_eq "<= 6 s" "${el} s" "within the whole budget"
doc="$(cat "${TEST_TMP}/fifo.json")"
if [[ -n "${doc}" ]] && q "${doc}" '1' > /dev/null 2>&1; then
  assert_eq "undetermined False" "$(q "${doc}" 'd["profiles"]["decide-tiny"]["verdict"]+" "+str(d["measurement"]["ok"])')" "undetermined"
  assert_contains "$(q "${doc}" 'd["measurement"]["reason"]')" "LLMCTL_CAPACITY_TIMEOUT" "the WHOLE bound is named"
else
  assert_eq "a JSON document" "no document" "an undetermined document"
fi
rm -f -- "${TEST_TMP:?}/meminfo.fifo"
echo "== F2: the time budget knobs are clamped to sane bounds =="
doc="$(LLMCTL_CAPACITY_TIMEOUT=0 LLMCTL_CAPACITY_PROBE_TIMEOUT=0 capacity_json)"
assert_eq "2 1" "$(q "${doc}" '"%s %s" % (d["measurement"]["timeout_s"], d["measurement"]["probe_timeout_s"])')" "0 is raised to the floors (2 s / 1 s)"
doc="$(LLMCTL_CAPACITY_TIMEOUT=9999 LLMCTL_CAPACITY_PROBE_TIMEOUT=9999 capacity_json)"
assert_eq "30 30" "$(q "${doc}" '"%s %s" % (d["measurement"]["timeout_s"], d["measurement"]["probe_timeout_s"])')" "9999 is lowered to the ceilings; the probe budget never exceeds the whole"
doc="$(LLMCTL_CAPACITY_TIMEOUT=abc capacity_json)"
assert_eq "5 3" "$(q "${doc}" '"%s %s" % (d["measurement"]["timeout_s"], d["measurement"]["probe_timeout_s"])')" "a non-integer is the default (5 s / 3 s)"

echo "== F6: a plan/probe failure is 'undetermined', not 'not a catalog profile' =="
set +e
( catalog_plan_json() { return 1; }; capacity_admit decide-tiny ) > /dev/null 2> "${TEST_TMP}/plan.err"; rc=$?
set -e
assert_eq 75 "${rc}" "a failing planner refuses 75"
assert_file_contains "${TEST_TMP}/plan.err" "could not be determined" "the message says the capacity could not be determined"
if grep -qF "not a catalog profile" "${TEST_TMP}/plan.err"; then
  assert_eq "no catalog claim" "not a catalog profile" "it no longer claims the profile is unknown"
else assert_eq 1 1 "it no longer claims the profile is unknown"; fi
doc="$( ( catalog_plan_json() { echo 'not json'; }; capacity_json decide-tiny ) )"
assert_eq "undetermined" "$(q "${doc}" 'd["profiles"]["decide-tiny"]["verdict"]')" "unreadable planner output -> undetermined"
assert_eq 75 "$(admit_rc no-such-profile)" "negative control: a real unknown profile still refuses"
assert_file_contains "${TEST_TMP}/admit.err" "not a catalog profile" "negative control: and still says it is not a catalog profile"

echo "== M10: an empty measurement is refused as 'could not be measured' =="
set +e
( capacity_json() { echo ''; }; capacity_admit decide-tiny ) > /dev/null 2> "${TEST_TMP}/empty.err"; rc=$?
set -e
assert_eq 75 "${rc}" "empty measurement refused 75"
assert_file_contains "${TEST_TMP}/empty.err" "could not be measured" "the refusal names the failed measurement"

echo "== M03: restart adds the replaced unit's resident memory back to the user manager's cgroup room =="
fp="$(q "$(capacity_json decide-tiny)" 'd["profiles"]["decide-tiny"]["headroom"]["footprint_mb"]')"
rm_mb="$(q "$(capacity_json)" 'd["reserve"]["mem_reserved_mb"]')"
# cgroup room without the add-back is 1000 MiB short of footprint + reserve; the replaced unit holds 2048 MiB
max_mb=20480; cur_mb=$(( max_mb - (fp + rm_mb - 1000) ))
printf '%s\n' $(( max_mb * MIB )) > "${LLMCTL_CGROUP_ROOT}/memory.max"; printf '%s\n' $(( cur_mb * MIB )) > "${LLMCTL_CGROUP_ROOT}/memory.current"
mkunit 'llmctl-llama@decide-tiny.service' '300000 100000' $(( 2560 * MIB )) $(( 2048 * MIB ))
assert_eq 0 "$(admit_rc decide-tiny "" decide-tiny)" "restart: the replaced unit's 2048 MiB come back into the cgroup room (admitted)"
clean_units
mkunit 'llmctl-llama@other.service' '300000 100000' $(( 2560 * MIB )) $(( 2048 * MIB ))
assert_eq 75 "$(admit_rc decide-tiny)" "negative control: the same memory held by another unit refuses a start"
clean_units
rm -f -- "${LLMCTL_CGROUP_ROOT:?}/memory.max" "${LLMCTL_CGROUP_ROOT:?}/memory.current"

echo "== M04 / M05: decide scale judges NEW instances at the full cap, k of them together =="
mkunit 'llmctl-llama@big.service' '700000 100000' $(( 2048 * MIB ))
assert_eq 75 "$(admit_rc decide-tiny 2)" "2 new instances need 600% CPU, 500% left: refused (k is the instance count)"
assert_eq 0 "$(admit_rc decide-tiny 1)" "negative control: 1 new instance (300%) fits"
clean_units
mkunit 'llmctl-llama@big.service' '1000000 100000' $(( 2048 * MIB ))
assert_eq 75 "$(admit_rc decide-tiny 1)" "1 new instance, only 200% left: refused (a scale never runs with reduced threads)"
CAP_THREADS=""; capacity_admit decide-tiny 2>/dev/null
assert_eq 2 "${CAP_THREADS}" "negative control: a plain start with 200% left runs with 2 threads"
clean_units

echo "== M06 / M07: the fallback is never local for a refused named start or a degraded decision unit =="
mkunit 'llmctl-llama@decide-tiny.service' '300000 100000' $(( 1280 * MIB ))
mkunit 'llmctl-llama@big.service' '900000 100000' $(( 2048 * MIB ))
doc="$(capacity_json decide-2b)"
assert_eq "does_not_fit ok" "$(q "${doc}" 'd["profiles"]["decide-2b"]["verdict"]+" "+[u for u in d["llmctl"]["units"] if u["profile"]=="decide-tiny"][0]["status"]')" \
  "decide-2b does not fit; a healthy decide-tiny runs"
assert_eq "none none" "$(q "${doc}" 'd["fallback"]["recommended"]+" "+d["fallback"]["route"]')" "a refused named start: fallback none (never local)"
clean_units
mkunit 'llmctl-llama@decide-tiny.service' 'max' $(( 1280 * MIB ))
doc="$(capacity_json)"
assert_eq "degraded None" "$(q "${doc}" 'd["llmctl"]["units"][0]["status"]+" "+str(d["largest_decision_fit"])')" "the only decision unit is degraded and nothing else fits"
assert_eq "none" "$(q "${doc}" 'd["fallback"]["recommended"]')" "a degraded decision unit is not local"
clean_units

# scheduler-level paths
source "${LLMCTL_ROOT}/lib/scheduler.sh"

echo "== M16: bin/llmctl decide scale passes the instance count to the admission =="
mkunit 'llmctl-llama@big.service' '700000 100000' $(( 2048 * MIB ))
set +e; "${LLMCTL_ROOT}/bin/llmctl" decide scale decide-tiny 2 > "${TEST_TMP}/scale2.out" 2>&1; rc=$?; set -e
assert_eq 75 "${rc}" "decide scale to 2 instances with 500% left exits 75"
assert_file_contains "${TEST_TMP}/scale2.out" "llmctl-fallback:" "and prints the fallback line"
"${LLMCTL_ROOT}/bin/llmctl" decide scale decide-tiny 0 > /dev/null 2>&1 || true
clean_units

echo "== M22: decide scale keeps the memory pressure gate even with the host reserve off =="
printf 'some avg10=50.00 avg60=0 avg300=0 total=0\nfull avg10=50.00 avg60=0 avg300=0 total=0\n' > "${LLMCTL_PSI_FILE}"
set +e; LLMCTL_HOST_RESERVE=0 "${LLMCTL_ROOT}/bin/llmctl" decide scale decide-tiny 1 > "${TEST_TMP}/scale3.out" 2>&1; rc=$?; set -e
assert_eq 75 "${rc}" "memory PSI full 50 with the reserve off: decide scale refused 75"
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "${LLMCTL_PSI_FILE}"
set +e; LLMCTL_HOST_RESERVE=0 "${LLMCTL_ROOT}/bin/llmctl" decide scale decide-tiny 1 > /dev/null 2>&1; rc=$?; set -e
assert_eq 0 "${rc}" "negative control: no pressure, reserve off: decide scale succeeds (dry run)"
"${LLMCTL_ROOT}/bin/llmctl" decide scale decide-tiny 0 > /dev/null 2>&1 || true

echo "== F5: _sched_base_profile uses the same mapping as reserve_base_profile =="
_cat_fx="${TEST_TMP}/catalog-dotted.json"
python3 - "${LLMCTL_CATALOG}" "${_cat_fx}" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["profiles"]["decide-tiny.2"] = dict(d["profiles"]["decide-tiny"])   # a profile whose name looks like an instance key
json.dump(d, open(sys.argv[2], "w"))
PYEOF
names="$(LLMCTL_CATALOG="${_cat_fx}" python3 -c 'import json,os; print(" ".join(json.load(open(os.environ["LLMCTL_CATALOG"]))["profiles"]))')"
for n in decide-tiny decide-tiny.2 decide-tiny.3 t1--decide-tiny t1--decide-tiny.3 decide.1 decide.10 qwen2.5-coder no-such; do
  assert_eq "$(reserve_base_profile "${n}" "${names}")" "$(LLMCTL_CATALOG="${_cat_fx}" _sched_base_profile "${n}")" \
    "_sched_base_profile ${n} == reserve_base_profile ${n}"
done

echo "== M20: a short host's template unit keeps the 256 MiB MemoryMax floor =="
lim="$(bash -c "set -uo pipefail; for l in common reserve service_linux; do source '${LLMCTL_ROOT}/lib/'\$l.sh; done; _svc_rsv_mem_limit 4300")"
assert_eq 256 "${lim}" "4300 MiB host (model budget 204 MiB): the template MemoryMax is the 256 MiB floor"
lim="$(bash -c "set -uo pipefail; for l in common reserve service_linux; do source '${LLMCTL_ROOT}/lib/'\$l.sh; done; _svc_rsv_mem_limit 8192")"
assert_eq 4096 "${lim}" "negative control: 8192 MiB host: the model budget 4096 MiB"

test_finish
