#!/usr/bin/env bash
# test_gate_wiring_systemd_waiter.sh - RED-FIRST specification of GAP 1 for the SYSTEMD path (docs/validation.md
# "Known gaps" #1): a unit started by systemd (boot, Restart=on-failure/always, `llmctl enable`, `llmctl restart`)
# never passes through any validation hook. The place to run it is the registration waiter of lib/svc_hook.sh
# (`_wait_register` / hk__wait_register, spawned detached by hk_register = ExecStartPost): AFTER the service
# answers its health endpoint. Desired behaviour:
#   * the waiter validates exactly once, after readiness (+ registration), through the public validation entry
#     (llmctl validate / validate-after-start: the test accepts either - it observes validate_profile);
#   * FAIL (1)         -> `systemctl --user stop <unit>` (the NORMAL stop path). The waiter must NOT kill the main
#                         pid itself and the engine must NOT exit non-zero (Restart=on-failure would count/loop it);
#   * UNDETERMINED (2) -> NO stop, loud, no PASS;  PASS (0) -> NO stop;
#   * LLMCTL_VALIDATE_ON_START=0 disables it;
#   * hk_register (ExecStartPost) stays DETACHED: it returns promptly even while validation is slow - it must
#     never block `systemctl start`.
# Harness: tests/gate_wiring_lib.sh; a FAKE systemctl on PATH records every call ("systemctl <args>") into the same
# call log as the validate_profile recorder, so ORDER is observable. A real counting HTTP fixture stands in for the
# engine's health endpoint; the "engine pid" is a harmless `sleep`. No systemd, model or container is touched.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source "$(dirname "${BASH_SOURCE[0]}")/gate_wiring_lib.sh"
test_setup_env
cleanup() {
  local p
  # waiters/validators of THIS run only: their command line contains this run's unique temp tree
  for p in $(pgrep -f "${TEST_TMP}/tree/lib/svc_hook.sh" 2>/dev/null || true); do kill "${p}" 2>/dev/null || true; done
  gw_cleanup_bg
  test_teardown_env
}
trap cleanup EXIT
gw_init
unset LLMCTL_SERVICE_BACKEND_FILE      # the waiter path must use the systemd backend -> the fake systemctl below
export LLMCTL_ROOT="${GW_TREE}"        # lib/common.sh honours it; the waiter then runs the TREE's llmctl + overlays
export LLMCTL_REGISTER_WAIT=15 LLMCTL_REGISTER_POLL=1 LLMCTL_REGISTER_IDENTITY_WAIT=1
HK="${GW_TREE}/lib/svc_hook.sh"
UNIT="llmctl-llama@small.service"

# --- fake systemctl: records, never acts --------------------------------------------------------------------------
FAKEBIN="${TEST_TMP}/fakebin"; mkdir -p "${FAKEBIN}"
cat > "${FAKEBIN}/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "${GW_CALLS:?}"
case " $* " in
  *" is-active "*) exit 0 ;;
  *" is-failed "*) exit 1 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "${FAKEBIN}/systemctl"
export PATH="${FAKEBIN}:${PATH}"

b2i() { if "$@"; then echo 1; else echo 0; fi; }
ENGINE_PID=""
new_engine_pid() { sleep 300 >/dev/null 2>&1 & ENGINE_PID=$!; GW_BG_PIDS+=("${ENGINE_PID}"); }
write_env() { # write_env <port>
  mkdir -p "${LLMCTL_SERVICES_DIR}"
  { printf 'LLMCTL_ENGINE=llama\nLLMCTL_PORT=%s\nLLMCTL_REG_TOKEN=tok\nLLMCTL_REG_PROTOCOL=http\n' "$1"
    printf 'LLMCTL_REG_HEALTH=/health\nLLMCTL_REG_KIND=llm\nLLMCTL_REG_PROFILE=small\nLLMCTL_REG_LOOPBACK=1\n'; } > "${LLMCTL_SERVICES_DIR}/small.env"
}
reset_world() {
  gw_calls_reset
  rm -f "${LLMCTL_RUNTIME_DIR:?}"/*.run "${GW_ACTIVE_DIR:?}"/* 2>/dev/null || true
  rm -rf "${LLMCTL_STATE_DIR:?}/validation"
  mkdir -p "${LLMCTL_LOG_DIR}"; : > "${LLMCTL_LOG_DIR}/svc_hook.log"
  unset GW_VALIDATE_RC GW_VALIDATE_SLEEP GW_REAL_VALIDATE
  export LLMCTL_VALIDATE_ON_START=1
  new_engine_pid
}
# run_waiter [env...] -> rc of the synchronous waiter (bounded)
run_waiter() { local rc=0; env "$@" timeout 60 bash "${HK}" _wait_register small "${ENGINE_PID}" >"${TEST_TMP}/last.out" 2>&1 || rc=$?; echo "${rc}"; }

READY_REQ="${TEST_TMP}/ready.req"
GW_HTTP_FIXED_PORT=0 gw_http_server "${READY_REQ}"
READY_PORT="${GW_HTTP_PORT}"
assert_eq 1 "$([[ "${READY_PORT}" =~ ^[0-9]+$ ]] && echo 1 || echo 0)" "fixture: the health endpoint is up on port ${READY_PORT}"
write_env "${READY_PORT}"

echo "== CONTROL 1 (positive): the fake systemctl recorder sees a stop issued the way the waiter must issue it"
reset_world
systemctl --user stop "${UNIT}"
assert_eq 1 "$(gw_count "^systemctl --user stop ${UNIT}\$")" "control: 'systemctl --user stop' is visible in the call log"

echo "== CONTROL 2 (negative): a waiter whose endpoint never answers validates NOTHING and stops NOTHING"
reset_world
write_env "$(gw_free_port)"
rc="$(run_waiter LLMCTL_REGISTER_WAIT=2 GW_VALIDATE_RC=1)"
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "control: not-ready waiter exits non-zero (rc=${rc})"
assert_eq 0 "$(gw_count '^validate_profile ')" "control: no validation before readiness"
assert_eq 0 "$(gw_count '^systemctl --user stop')" "control: no stop for a service that never became ready"
write_env "${READY_PORT}"

echo "== CONTROL 3 (negative): a waiter whose main pid died validates NOTHING"
reset_world
kill "${ENGINE_PID}" 2>/dev/null || true; sleep 0.5
rc="$(run_waiter GW_VALIDATE_RC=1)"
assert_eq 0 "$(gw_count '^validate_profile ')" "control: dead pid -> no validation"
assert_eq 0 "$(gw_count '^systemctl --user stop')" "control: dead pid -> no stop"

echo "== waiter PASS: validated exactly once after readiness, not recursive, NO stop"
reset_world
rc="$(run_waiter GW_VALIDATE_RC=0)"
assert_eq 0 "${rc}" "waiter PASS: exits 0"
assert_file_contains "${LLMCTL_LOG_DIR}/svc_hook.log" "registered port ${READY_PORT}" "waiter PASS: the registration step still ran (readiness reached)"
assert_eq 1 "$(gw_count '^validate_profile small ')" "waiter PASS: validate_profile called exactly once (RED: the systemd path has no validation today)"
assert_eq 1 "$(gw_count '^validate_profile small lock_held=no$')" "waiter PASS: not inside the scheduler lock"
assert_eq 0 "$(gw_count '^systemctl --user stop')" "waiter PASS: no stop"
assert_eq 1 "$(b2i kill -0 "${ENGINE_PID}")" "waiter PASS: the engine process is untouched"

echo "== waiter FAIL (rc 1): 'systemctl --user stop <unit>' - not a non-zero exit of the main process"
reset_world
rc="$(run_waiter GW_VALIDATE_RC=1)"
assert_eq 1 "$(gw_count '^validate_profile small ')" "waiter FAIL: validated exactly once"
assert_eq 1 "$(gw_count "^systemctl --user stop ${UNIT}\$")" "waiter FAIL: the unit is stopped through 'systemctl --user stop ${UNIT}' (RED)"
s_val="$(gw_line '^validate_profile_end small ')"; s_stop="$(gw_line "^systemctl --user stop ${UNIT}\$")"
assert_eq 1 "$(( s_val > 0 && s_stop > s_val ? 1 : 0 ))" "waiter FAIL: the stop comes AFTER the verdict (verdict line ${s_val}, stop line ${s_stop})"
assert_eq 1 "$(b2i kill -0 "${ENGINE_PID}")" "waiter FAIL: the waiter did NOT kill/signal the main pid itself (systemd stops it)"
assert_eq 0 "$(gw_count '^systemctl --user (restart|kill|reset-failed)')" "waiter FAIL: no restart/kill games - only the normal stop"
assert_eq 1 "$(b2i grep -qiE 'validat' "${TEST_TMP}/last.out" "${LLMCTL_LOG_DIR}/svc_hook.log")" "waiter FAIL: the failure is reported (waiter output or svc_hook.log)"

echo "== waiter UNDETERMINED (rc 2): NO stop, loud, never a PASS"
reset_world
rc="$(run_waiter GW_VALIDATE_RC=2)"
assert_eq 1 "$(gw_count '^validate_profile small ')" "waiter UNDETERMINED: validated exactly once"
assert_eq 0 "$(gw_count '^systemctl --user stop')" "waiter UNDETERMINED: the unit is NOT stopped"
assert_eq 1 "$(b2i grep -qiE 'UNDETERMINED|could not be validated' "${TEST_TMP}/last.out" "${LLMCTL_LOG_DIR}/svc_hook.log")" "waiter UNDETERMINED: reported loudly"
assert_eq 0 "$(b2i grep -q PASSED "${TEST_TMP}/last.out" "${LLMCTL_LOG_DIR}/svc_hook.log")" "waiter UNDETERMINED: never reported as PASSED"
assert_file_absent "${LLMCTL_STATE_DIR}/validation/small.json" "waiter UNDETERMINED: no PASS recorded"

echo "== waiter with LLMCTL_VALIDATE_ON_START=0: no validation, no stop"
reset_world
rc="$(run_waiter GW_VALIDATE_RC=1 LLMCTL_VALIDATE_ON_START=0)"
assert_eq 0 "$(gw_count '^validate_profile ')" "waiter ON_START=0: no validation"
assert_eq 0 "$(gw_count '^systemctl --user stop')" "waiter ON_START=0: no stop"

echo "== ordering: validation starts only AFTER the endpoint answered (delayed health endpoint)"
reset_world
LATE_PORT="$(gw_free_port)"
GW_HTTP_FIXED_PORT="${LATE_PORT}" GW_HTTP_DELAY=3 GW_HTTP_NOWAIT=1 gw_http_server "${TEST_TMP}/late.req"
LATE_UP="${GW_HTTP_UP_FILE}"
write_env "${LATE_PORT}"
rc="$(run_waiter GW_VALIDATE_RC=0)"
up_ts="$(cat "${LATE_UP}" 2>/dev/null || echo 0)"
begin_ts="$(awk '$1=="validate_profile_begin"{print $3; exit}' "${GW_CALLS}")"
assert_eq 1 "$(gw_count '^validate_profile small ')" "ordering: validation ran"
assert_eq 1 "$(python3 -I -c 'import sys; u,b=float(sys.argv[1]),float(sys.argv[2] or 0); print(1 if b>0 and u>0 and b>=u else 0)' "${up_ts}" "${begin_ts:-0}")" "ordering: validation began (${begin_ts:-none}) after the endpoint came up (${up_ts})"
write_env "${READY_PORT}"

echo "== hk_register (ExecStartPost) stays DETACHED: returns promptly while validation is slow"
reset_world
OUT="${TEST_TMP}/reg.out"
t0="$(date +%s.%N)"
GW_VALIDATE_SLEEP=4 GW_VALIDATE_RC=1 MAINPID="${ENGINE_PID}" bash -c '
  source "$1/lib/svc_hook.sh"
  portreg_active() { return 0; }       # exercise the spawn path without a registry binary (portreg_register is a no-op when inactive)
  hk_register small
' _ "${GW_TREE}" > "${OUT}" 2>&1 || true
t1="$(date +%s.%N)"
elapsed="$(python3 -I -c 'import sys; print("%.2f" % (float(sys.argv[2]) - float(sys.argv[1])))' "${t0}" "${t1}")"
assert_eq 1 "$(python3 -I -c 'import sys; print(1 if float(sys.argv[1]) < 2.0 else 0)' "${elapsed}")" "hk_register returned in ${elapsed}s (< 2s although the validation takes 4s): it never blocks 'systemctl start'"
# the detached waiter keeps going: wait for the (slow) validation verdict, then for the stop
for _ in $(seq 1 30); do [[ "$(gw_count '^validate_profile_end small ')" -ge 1 ]] && break; sleep 0.5; done
assert_eq 1 "$(gw_count '^validate_profile small ')" "detached waiter: the validation still ran, exactly once (RED: nothing validates today)"
end_ts="$(awk '$1=="validate_profile_end"{print $4; exit}' "${GW_CALLS}")"
assert_eq 1 "$(python3 -I -c 'import sys; e=float(sys.argv[1] or 0); r=float(sys.argv[2]); print(1 if e>r else 0)' "${end_ts:-0}" "${t1}")" "detached waiter: the verdict arrived AFTER hk_register had returned"
for _ in $(seq 1 10); do [[ "$(gw_count '^systemctl --user stop')" -ge 1 ]] && break; sleep 0.5; done
assert_eq 1 "$(gw_count "^systemctl --user stop ${UNIT}\$")" "detached waiter FAIL: the unit is stopped via 'systemctl --user stop' (RED)"

test_finish
