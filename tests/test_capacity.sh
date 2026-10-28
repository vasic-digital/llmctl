#!/usr/bin/env bash
# test_capacity.sh - UNIT-CLASS (hermetic: fixture meminfo / PSI / loadavg / cgroup tree / plan). The live counterpart
# (real /proc, real cgroups, a real running decision model, a simulated-pressure window) is
# scripts/qa/host_reserve_live.sh -> docs/qa/2026-10-28-host-reserve/.
#
# Contract (3.4.0, lib/capacity.sh, schema llmctl.capacity/1 - docs/capacity.md):
#   * every catalog profile gets fits | fits_with_reduced_threads | does_not_fit | running, with reasons and headroom;
#   * largest_decision_fit names the biggest decision profile that fits now;
#   * fallback.recommended = local when a model fits, cloud when nothing fits and a hosted-key VARIABLE is set (the value
#     is never printed), none otherwise;
#   * a running unit is degraded under host pressure or near its memory limit, with a "llmctl stop" suggestion;
#   * capacity_admit refuses (75, "llmctl-fallback: ..." on stderr) on does_not_fit, sets CAP_THREADS on reduced threads;
#   * `llmctl capacity` exits 0 / 75 (named profile does not fit) / 3 (degraded).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
# shellcheck disable=SC1090
for l in common os_detect hardware catalog; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
export LLMCTL_HOST_MEM_MB=32768

# q <json> <expr>: the expressions are literals written in THIS file (test-authored), never external input
q() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$@"; }
mkunit() { # <name> <cpu.max> <memory.max bytes> [memory.current bytes]
  local d="${LLMCTL_CGROUP_ROOT}/app.slice/$1"; mkdir -p "${d}"
  printf 'populated 1\n' > "${d}/cgroup.events"; printf '%s\n' "$2" > "${d}/cpu.max"; printf '%s\n' "$3" > "${d}/memory.max"
  printf '%s\n' "${4:-0}" > "${d}/memory.current"
}

echo "== idle host: decision profiles fit, local fallback =="
doc="$(capacity_json)"
assert_eq "llmctl.capacity/1" "$(q "${doc}" 'd["schema"]')" "schema id"
assert_eq "fits 3" "$(q "${doc}" 'd["profiles"]["decide-tiny"]["verdict"]+" "+str(d["profiles"]["decide-tiny"]["threads"])')" "decide-tiny fits with the decision cap"
assert_eq "local" "$(q "${doc}" 'd["fallback"]["recommended"]')" "a local model fits -> fallback local"
assert_eq "True" "$(q "${doc}" 'd["largest_decision_fit"] is not None')" "a largest decision fit is named"
assert_eq "decide" "$(q "${doc}" 'd["profiles"]["decide-tiny"]["class"]')" "decision class detected"
assert_eq "False" "$(q "${doc}" 'd["degraded"]')" "nothing degraded"

echo "== reduced threads: only 2 CPUs left of the 12-CPU model budget =="
mkunit 'llmctl-llama@small.service' '1000000 100000' $(( 2048 * 1048576 ))
doc="$(capacity_json decide-tiny small)"
assert_eq "fits_with_reduced_threads 2" "$(q "${doc}" 'd["profiles"]["decide-tiny"]["verdict"]+" "+str(d["profiles"]["decide-tiny"]["threads"])')" \
  "3-CPU decision profile gets 2 threads when 200% CPU is left"
assert_eq "running" "$(q "${doc}" 'd["profiles"]["small"]["verdict"]')" "a running profile is reported running"
assert_eq 200 "$(q "${doc}" 'd["llmctl"]["cpu_pct_free"]')" "headroom: 200% CPU free"
CAP_THREADS=""; set +e; capacity_admit decide-tiny 2>/dev/null; rc=$?; set -e
assert_eq "0 2" "${rc} ${CAP_THREADS}" "capacity_admit: admitted with CAP_THREADS=2"

echo "== no CPU left -> does_not_fit, fallback cloud only with a key variable =="
rm -rf "${LLMCTL_CGROUP_ROOT:?}/app.slice"
mkunit 'llmctl-llama@big.service' '1200000 100000' $(( 2048 * 1048576 ))
doc="$(capacity_json decide-tiny)"
assert_eq "does_not_fit" "$(q "${doc}" 'd["profiles"]["decide-tiny"]["verdict"]')" "full CPU budget -> does_not_fit"
assert_contains "$(q "${doc}" '"; ".join(d["profiles"]["decide-tiny"]["reasons"])')" "no CPU left" "reason names the CPU budget"
assert_eq "none" "$(q "${doc}" 'd["fallback"]["recommended"]')" "no key variable set -> fallback none"
export LLMCTL_TEST_HOSTED_KEY="sk-test-SECRET-VALUE-0123456789"
doc="$(capacity_json decide-tiny)"
assert_eq "cloud LLMCTL_TEST_HOSTED_KEY" "$(q "${doc}" 'd["fallback"]["recommended"]+" "+d["fallback"]["key_variable"]')" \
  "key variable set -> fallback cloud, named by variable"
[[ "${doc}" != *SECRET-VALUE* ]] && assert_eq 1 1 "the key VALUE never appears in the JSON" || assert_eq hidden leaked "the key VALUE never appears in the JSON"
set +e; capacity_admit decide-tiny >/dev/null 2>"${TEST_TMP}/admit.err"; rc=$?; set -e
assert_eq 75 "${rc}" "capacity_admit refuses with 75"
assert_file_contains "${TEST_TMP}/admit.err" "llmctl-fallback: cloud" "machine-readable fallback line on stderr"
if grep -q SECRET-VALUE "${TEST_TMP}/admit.err"; then assert_eq hidden leaked "admit stderr never prints the key"; else assert_eq 1 1 "admit stderr never prints the key"; fi
set +e; "${LLMCTL_ROOT}/bin/llmctl" capacity --json decide-tiny > "${TEST_TMP}/cap.json" 2>/dev/null; rc=$?; set -e
assert_eq 75 "${rc}" "llmctl capacity <profile> exits 75 when it does not fit"
unset LLMCTL_TEST_HOSTED_KEY
rm -rf "${LLMCTL_CGROUP_ROOT:?}/app.slice"

echo "== host pressure -> does_not_fit; a running model becomes degraded =="
mkunit 'llmctl-llama@decide-tiny.service' '300000 100000' $(( 1280 * 1048576 )) $(( 600 * 1048576 ))
printf 'some avg10=95.00 avg60=0 avg300=0 total=0\n' > "${LLMCTL_CPU_PSI_FILE}"
doc="$(capacity_json)"
assert_eq "does_not_fit" "$(q "${doc}" 'd["profiles"]["decide-2b"]["verdict"]')" "CPU PSI 95 -> new profiles do not fit"
assert_eq "degraded llmctl stop decide-tiny" "$(q "${doc}" 'd["llmctl"]["units"][0]["status"]+" "+d["llmctl"]["units"][0]["suggest"]')" \
  "the running model is degraded, stop suggested"
set +e; "${LLMCTL_ROOT}/bin/llmctl" capacity > /dev/null 2>&1; rc=$?; set -e
assert_eq 3 "${rc}" "llmctl capacity exits 3 while a running model is degraded"
printf 'some avg10=0.00 avg60=0 avg300=0 total=0\n' > "${LLMCTL_CPU_PSI_FILE}"
mkunit 'llmctl-llama@decide-tiny.service' '300000 100000' $(( 1280 * 1048576 )) $(( 1200 * 1048576 ))
doc="$(capacity_json)"
assert_contains "$(q "${doc}" '"; ".join(d["llmctl"]["units"][0]["reasons"])')" ">= 90%" "near its memory limit -> degraded"
rm -rf "${LLMCTL_CGROUP_ROOT:?}/app.slice"

echo "== memory: MemAvailable minus the footprint must keep the host reserve =="
printf 'MemTotal:       33554432 kB\nMemFree:        7340032 kB\nMemAvailable:   7340032 kB\n' > "${LLMCTL_MEMINFO_FILE}"
doc="$(capacity_json decide-tiny)"
assert_eq "does_not_fit" "$(q "${doc}" 'd["profiles"]["decide-tiny"]["verdict"]')" "7 GiB available < 6.4 GiB reserve + footprint"
assert_contains "$(q "${doc}" '"; ".join(d["pressure"]["reasons"])+"|"+"; ".join(d["profiles"]["decide-tiny"]["reasons"])')" "host reserve" "reason names the reserve"
printf 'MemTotal:       33554432 kB\nMemFree:        31457280 kB\nMemAvailable:   31457280 kB\n' > "${LLMCTL_MEMINFO_FILE}"

echo "== reserve off: capacity_admit is a no-op (diagnostics) =="
printf 'some avg10=95.00 avg60=0 avg300=0 total=0\n' > "${LLMCTL_CPU_PSI_FILE}"
set +e; LLMCTL_HOST_RESERVE=0 capacity_admit decide-tiny 2>/dev/null; rc=$?; set -e
assert_eq 0 "${rc}" "LLMCTL_HOST_RESERVE=0: no capacity refusal (negative control)"
printf 'some avg10=0.00 avg60=0 avg300=0 total=0\n' > "${LLMCTL_CPU_PSI_FILE}"

echo "== start refuses before writing anything =="
export LLMCTL_DRY_RUN=1
source "${LLMCTL_ROOT}/lib/scheduler.sh"
mkunit 'llmctl-llama@big.service' '1200000 100000' $(( 2048 * 1048576 ))
set +e; ( _sched_start_impl decide-tiny ) > "${TEST_TMP}/start.out" 2>&1; rc=$?; set -e
assert_eq 75 "${rc}" "start of a does_not_fit profile exits 75"
assert_file_contains "${TEST_TMP}/start.out" "llmctl-fallback:" "start prints the fallback line"
assert_file_absent "${LLMCTL_SERVICES_DIR}/decide-tiny.env" "no env record written for a refused start"
rm -rf "${LLMCTL_CGROUP_ROOT:?}/app.slice"

test_finish
