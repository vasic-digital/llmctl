#!/usr/bin/env bash
# test_gate_wiring_pressure.sh - RED-FIRST specification of GAP 2 (docs/validation.md "Known gaps" #2): validation
# starts a model (sched_start) and hammers it with probes WITHOUT looking at host pressure. The hardening branch
# (fix/bounded-restart-and-pressure-gates) provides hw_pressure_gate <footprint-MiB> [label] in lib/hardware.sh
# (rc 75 = refused: PSI full avg10 > 2, or some avg10 > 10, or MemAvailable < footprint + 4096 MiB). Desired:
#   * validate_profile calls the gate BEFORE sched_start (profile not running) AND again before the probe loop
#     (profile running or just started);
#   * rc 75 -> a DISTINCT 'refused under pressure' result: exit 2 (UNDETERMINED), a message containing both
#     'refus' and 'pressure', NEVER recorded as a FAIL (no 'fail' state record), and NO model is started and NO
#     probe request is sent;
#   * the same holds for every validation entry point: validate, validate-all, vision validate, models verify --live
#     (models_verify_gate --live), and the post-start hook validate_after_start.
# Interface assumptions (UNKNOWN until implemented): the validation layer emits its OWN message (the test shim of the
# gate is silent); the label argument is the profile name; the footprint argument is a non-negative integer (MiB).
# SECTION A defines the interface with a recording hw_pressure_gate SHIM (tests/gate_wiring_lib.sh overlay) - it
# runs on any branch. SECTION B drives the REAL gate through its PSI/meminfo fixtures and is an honest assert_skip
# unless lib/hardware.sh defines hw_pressure_gate (i.e. after the hardening branch is merged).
# The probe target is a counting HTTP fixture; every catalog port is rewritten (LLMCTL_CATALOG) to an unused one,
# so a probe can never reach a real model server. No model, service or container is started.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source "$(dirname "${BASH_SOURCE[0]}")/gate_wiring_lib.sh"
test_setup_env
trap 'gw_cleanup_bg; test_teardown_env' EXIT

REQ="${TEST_TMP}/requests.log"
gw_http_server "${REQ}"
PORT="${GW_HTTP_PORT}"
assert_eq 1 "$([[ "${PORT}" =~ ^[0-9]+$ ]] && echo 1 || echo 0)" "fixture: counting endpoint on 127.0.0.1:${PORT}"
gw_init "small=${PORT}" "vision=${PORT}"
export GW_REAL_VALIDATE=1               # the REAL validate_profile / judge; only the service manager and the gate are test doubles
L="${GW_LLMCTL}"
export LLMCTL_VALIDATE_ON_START=1

b2i() { if "$@"; then echo 1; else echo 0; fi; }
out_has() { grep -qiE -- "$1" "${TEST_TMP}/last.out"; }
nreq() { local n; n="$(wc -l < "${REQ}" | tr -d ' ')"; echo "${n:-0}"; }
reset_world() {
  rm -f "${LLMCTL_RUNTIME_DIR:?}"/*.run "${GW_ACTIVE_DIR:?}"/* 2>/dev/null || true
  rm -rf "${LLMCTL_STATE_DIR:?}/validation"
  gw_calls_reset; : > "${REQ}"
  unset GW_GATE_RC GW_GATE_MODE
  export GW_REAL_VALIDATE=1
}
state_status() { # state_status <profile> -> pass|fail|undetermined|none
  local f="${LLMCTL_STATE_DIR}/validation/$1.json"
  [[ -f "${f}" ]] || { echo none; return; }
  python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status","?"))' "${f}"
}
not_fail() { [[ "$(state_status "$1")" != fail ]]; }

echo "== CONTROL 1 (positive): with the gate OPEN the probes DO reach the endpoint (the harness can see requests)"
reset_world; gw_mark_running small "${PORT}"
rc="$(GW_GATE_RC=0 gw_run "${L}" validate small)"
assert_eq 1 "$(( $(nreq) > 0 ? 1 : 0 ))" "control: gate open -> $(nreq) probe request(s) seen by the counting fixture (validate rc=${rc})"

echo "== CONTROL 2 (positive): the gate shim records calls made to it (harness can see a wired gate)"
reset_world
bash -c 'export LLMCTL_ROOT="$1"; source "$1/lib/common.sh"; source "$1/lib/hardware.sh"; hw_pressure_gate 123 probe-label' _ "${GW_TREE}" >/dev/null 2>&1 || true
assert_eq 1 "$(gw_count '^hw_pressure_gate 123 probe-label$')" "control: a direct gate call is recorded with its arguments"

echo "== CONTROL 3 (negative): a path that never validates makes ZERO gate calls and ZERO requests"
reset_world; gw_mark_running small "${PORT}"
assert_eq 0 "$(gw_run "${L}" status)" "control: 'llmctl status' -> 0"
assert_eq 0 "$(gw_count '^hw_pressure_gate')" "control: no gate call from a non-validating command"
assert_eq 0 "$(nreq)" "control: no request from a non-validating command"

echo "== A1. validate <running profile>, gate REFUSES (75): refused, UNDETERMINED, no probe, never FAIL"
reset_world; gw_mark_running small "${PORT}"
rc="$(GW_GATE_RC=75 gw_run "${L}" validate small)"
assert_eq 1 "$(( $(gw_count '^hw_pressure_gate ') >= 1 ? 1 : 0 ))" "A1: the gate was consulted before the probe loop (RED: validate_profile never calls it today)"
assert_eq 0 "$(nreq)" "A1: NO probe request reached the model endpoint while the host is under pressure (got $(nreq))"
assert_eq 2 "${rc}" "A1: exit 2 = UNDETERMINED (a refusal is not a verdict)"
assert_eq 1 "$(b2i out_has 'refus')" "A1: the output says the validation was refused"
assert_eq 1 "$(b2i out_has 'pressure')" "A1: the output names memory pressure"
assert_eq 1 "$(b2i not_fail small)" "A1: a refusal is NEVER recorded as FAIL (state: $(state_status small))"
assert_eq 1 "$(b2i gw_is_running small)" "A1: a running profile is left running (refusal does not stop it)"

echo "== A2. validate <running profile>, gate OPEN (0): the gate is consulted exactly before the probes, which then run"
reset_world; gw_mark_running small "${PORT}"
rc="$(GW_GATE_RC=0 gw_run "${L}" validate small)"
assert_eq 1 "$(( $(gw_count '^hw_pressure_gate ') >= 1 ? 1 : 0 ))" "A2: gate consulted even when the profile is already running (RED)"
assert_eq 1 "$(( $(nreq) > 0 ? 1 : 0 ))" "A2: gate open -> the probes run ($(nreq) requests)"

echo "== A3. validate <profile NOT running>, gate REFUSES: no model is started, nothing is probed"
reset_world
rc="$(GW_GATE_RC=75 gw_run "${L}" validate small)"
assert_eq 1 "$(( $(gw_count '^hw_pressure_gate ') >= 1 ? 1 : 0 ))" "A3: the gate is consulted before starting the model (RED)"
assert_eq 0 "$(gw_count '^svc_start ')" "A3: NO svc_start while the gate refuses - the model is never started under pressure (RED)"
assert_eq 0 "$(b2i gw_is_running small)" "A3: no reservation was created"
assert_eq 0 "$(nreq)" "A3: no probe request"
assert_eq 2 "${rc}" "A3: exit 2 = UNDETERMINED"
assert_eq 11 "$(b2i out_has 'refus')$(b2i out_has 'pressure')" "A3: output says refused + pressure (both)"
assert_eq 1 "$(b2i not_fail small)" "A3: never recorded as FAIL (state: $(state_status small))"

echo "== A4. validate <profile NOT running>, gate OPEN: gate BEFORE sched_start and AGAIN before the probe loop"
reset_world
rc="$(GW_GATE_RC=0 gw_run "${L}" validate small)"
g1="$(gw_line '^hw_pressure_gate ')"; s1="$(gw_line '^svc_start small$')"
g2="$(gw_line_after '^hw_pressure_gate ' "${s1}")"
assert_eq 1 "$(( g1 > 0 && s1 > 0 && g1 < s1 ? 1 : 0 ))" "A4: a gate call (line ${g1}) precedes svc_start (line ${s1}) (RED)"
assert_eq 1 "$(( g2 > s1 && s1 > 0 ? 1 : 0 ))" "A4: a SECOND gate call (line ${g2}) follows the start, before the probe loop (RED)"

echo "== A5. validate-all (running profile), gate REFUSES"
reset_world; gw_mark_running small "${PORT}"
rc="$(GW_GATE_RC=75 gw_run "${L}" validate-all)"
assert_eq 1 "$(( $(gw_count '^hw_pressure_gate ') >= 1 ? 1 : 0 ))" "A5: validate-all consults the gate (RED)"
assert_eq 0 "$(nreq)" "A5: validate-all sent no probe under pressure (got $(nreq))"
assert_eq 2 "${rc}" "A5: validate-all exits 2 (UNDETERMINED), not 1"
assert_eq 1 "$(b2i not_fail small)" "A5: not recorded as FAIL"

echo "== A6. vision validate (running vision profile), gate REFUSES"
reset_world; gw_mark_running vision "${PORT}"
rc="$(GW_GATE_RC=75 gw_run "${L}" vision validate --profile vision)"
assert_eq 1 "$(( $(gw_count '^hw_pressure_gate ') >= 1 ? 1 : 0 ))" "A6: vision validate consults the gate (RED)"
assert_eq 0 "$(nreq)" "A6: no probe under pressure (got $(nreq))"
assert_eq 2 "${rc}" "A6: exit 2 (UNDETERMINED)"
assert_eq 1 "$(b2i not_fail vision)" "A6: not recorded as FAIL"

echo "== A7. models verify --live (models_verify_gate --live), gate REFUSES"
reset_world; gw_mark_running small "${PORT}"
rc=0
GW_GATE_RC=75 bash -c 'export LLMCTL_ROOT="$1"; shift; for f in common os_detect hardware catalog scheduler validate; do source "${LLMCTL_ROOT}/lib/${f}.sh"; done; models_verify_gate "$@"' _ "${GW_TREE}" small --live >"${TEST_TMP}/last.out" 2>&1 || rc=$?
assert_eq 1 "$(( $(gw_count '^hw_pressure_gate ') >= 1 ? 1 : 0 ))" "A7: models verify --live consults the gate (RED)"
assert_eq 0 "$(nreq)" "A7: no probe under pressure (got $(nreq))"
assert_eq 2 "${rc}" "A7: exit 2 (UNDETERMINED)"

echo "== A8. post-start hook validate_after_start, gate REFUSES: nothing probed, stopped as UNDETERMINED (strict), not FAIL"
reset_world; gw_mark_running small "${PORT}"
rc="$(GW_GATE_RC=75 gw_run "${L}" validate-after-start small)"
assert_eq 1 "$(( $(gw_count '^hw_pressure_gate ') >= 1 ? 1 : 0 ))" "A8: the start hook consults the gate (RED)"
assert_eq 0 "$(nreq)" "A8: no probe under pressure (got $(nreq))"
assert_eq 1 "$(gw_count '^svc_stop small$')" "A8: a refusal is UNDETERMINED: the profile is stopped (strict default since review 2026-10-14; it also relieves the pressure)"
assert_eq 1 "$(b2i not_fail small)" "A8: not recorded as FAIL"
assert_eq 1 "$(b2i out_has 'refus|pressure')" "A8: reported loudly"

echo "== B. REAL hw_pressure_gate through its PSI / meminfo fixtures"
if ! grep -qE '^hw_pressure_gate\(\)' "${LLMCTL_ROOT}/lib/hardware.sh"; then
  assert_skip "lib/hardware.sh in this branch has no hw_pressure_gate (it lives on fix/bounded-restart-and-pressure-gates); section B becomes meaningful after the merge" "real-gate wiring of validate_profile"
else
  export GW_GATE_MODE=real
  export LLMCTL_PSI_FILE="${TEST_TMP}/psi.fixture" LLMCTL_MEMINFO_FILE="${TEST_TMP}/meminfo.fixture"
  printf 'MemTotal:       33554432 kB\nMemFree:        31457280 kB\nMemAvailable:   31457280 kB\n' > "${LLMCTL_MEMINFO_FILE}"

  reset_world; export GW_GATE_MODE=real; gw_mark_running small "${PORT}"
  printf 'some avg10=50.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "${LLMCTL_PSI_FILE}"
  rc="$(gw_run "${L}" validate small)"
  assert_eq 2 "${rc}" "B1: PSI some avg10=50 -> validate exits 2 (UNDETERMINED)"
  assert_eq 0 "$(nreq)" "B1: no probe under real PSI pressure"
  assert_eq 1 "$(b2i not_fail small)" "B1: not recorded as FAIL"

  reset_world; export GW_GATE_MODE=real; gw_mark_running small "${PORT}"
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=9.00 avg60=0.00 avg300=0.00 total=0\n' > "${LLMCTL_PSI_FILE}"
  rc="$(gw_run "${L}" validate small)"
  assert_eq 2 "${rc}" "B2: PSI full avg10=9 -> exit 2"
  assert_eq 0 "$(nreq)" "B2: no probe"

  reset_world; export GW_GATE_MODE=real
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' > "${LLMCTL_PSI_FILE}"
  printf 'MemTotal:       33554432 kB\nMemFree:        1048576 kB\nMemAvailable:   1048576 kB\n' > "${LLMCTL_MEMINFO_FILE}"
  rc="$(gw_run "${L}" validate small)"
  assert_eq 2 "${rc}" "B3: MemAvailable 1 GiB < footprint + 4 GiB -> a validation-triggered start is refused (exit 2)"
  assert_eq 0 "$(gw_count '^svc_start ')" "B3: no svc_start under low memory"

  reset_world; export GW_GATE_MODE=real; gw_mark_running small "${PORT}"
  printf 'MemTotal:       33554432 kB\nMemFree:        31457280 kB\nMemAvailable:   31457280 kB\n' > "${LLMCTL_MEMINFO_FILE}"
  rc="$(gw_run "${L}" validate small)"
  assert_eq 1 "$(( $(nreq) > 0 ? 1 : 0 ))" "B4 (control): no pressure -> the probes run ($(nreq) requests)"
fi

test_finish
