#!/usr/bin/env bash
# test_gate_waiter_stop.sh - RED-first (wiring review #3 and the waiter half of #1).
#  #3: `systemctl --user stop <unit>` SIGTERMs the whole control group - INCLUDING the detached waiter that issued it - so anything
#      the waiter does after the stop never runs. The reservation (<runtime>/<profile>.run) must therefore be removed BEFORE the stop.
#      The fake systemctl's `stop` kills its parent (the waiter) exactly like KillMode=control-group.
#  #1: a bare exit 1 of the llmctl process (crash, die(), set -e) is NOT a wrong answer: it is UNDETERMINED (logged so),
#      which strict mode - the default since review 2026-10-14 - does not serve either.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source "$(dirname "${BASH_SOURCE[0]}")/gate_wiring_lib.sh"
test_setup_env
cleanup() { local p; for p in $(pgrep -f "${TEST_TMP}/tree/lib/svc_hook.sh" 2>/dev/null || true); do kill "${p}" 2>/dev/null || true; done; gw_cleanup_bg; test_teardown_env; }
trap cleanup EXIT
gw_init
unset LLMCTL_SERVICE_BACKEND_FILE
export LLMCTL_ROOT="${GW_TREE}"
export LLMCTL_REGISTER_WAIT=15 LLMCTL_REGISTER_POLL=1 LLMCTL_REGISTER_IDENTITY_WAIT=1
HK="${GW_TREE}/lib/svc_hook.sh"
FAKEBIN="${TEST_TMP}/fakebin"; mkdir -p "${FAKEBIN}"
cat > "${FAKEBIN}/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "${GW_CALLS:?}"
case " $* " in
  *" stop "*) kill -TERM "${PPID}" 2>/dev/null || true; sleep 0.2; exit 0 ;;   # KillMode=control-group: the waiter dies with the unit
  *" is-active "*) exit 0 ;;
  *" is-failed "*) exit 1 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "${FAKEBIN}/systemctl"; export PATH="${FAKEBIN}:${PATH}"
b2i() { if "$@"; then echo 1; else echo 0; fi; }
GW_HTTP_FIXED_PORT=0 gw_http_server "${TEST_TMP}/ready.req"; PORT="${GW_HTTP_PORT}"
mkdir -p "${LLMCTL_SERVICES_DIR}"
{ printf 'LLMCTL_ENGINE=llama\nLLMCTL_PORT=%s\nLLMCTL_REG_TOKEN=tok\nLLMCTL_REG_PROTOCOL=http\n' "${PORT}"
  printf 'LLMCTL_REG_HEALTH=/health\nLLMCTL_REG_KIND=llm\nLLMCTL_REG_PROFILE=small\nLLMCTL_REG_LOOPBACK=1\n'; } > "${LLMCTL_SERVICES_DIR}/small.env"
reset_world() {
  gw_calls_reset; rm -f "${LLMCTL_RUNTIME_DIR:?}"/*.run; rm -rf "${LLMCTL_STATE_DIR:?}/validation"
  mkdir -p "${LLMCTL_LOG_DIR}"; : > "${LLMCTL_LOG_DIR}/svc_hook.log"
  unset GW_VALIDATE_RC GW_REAL_VALIDATE
  export LLMCTL_VALIDATE_ON_START=1
  sleep 300 >/dev/null 2>&1 & ENGINE_PID=$!; GW_BG_PIDS+=("${ENGINE_PID}")
  gw_mark_running small "${PORT}"
}
run_waiter() { local rc=0; env "$@" timeout 60 bash "${HK}" _wait_register small "${ENGINE_PID}" >"${TEST_TMP}/last.out" 2>&1 || rc=$?; echo "${rc}"; }

echo "== #3 FAIL verdict: the reservation is gone even though the stop kills the waiter before it can clean up"
reset_world
assert_eq 1 "$(b2i gw_is_running small)" "setup: the reservation exists before the validation"
rc="$(run_waiter GW_VALIDATE_RC=1)"
assert_eq 1 "$(gw_count '^systemctl --user stop llmctl-llama@small.service$')" "FAIL: the unit was stopped through systemctl --user stop"
assert_eq 0 "$(b2i gw_is_running small)" "FAIL: the reservation was removed BEFORE the stop (the waiter never got to clean up after it)"

echo "== #1 a bare exit 1 of the llmctl process is NOT a verdict: it is UNDETERMINED - never reported as a wrong answer"
# (since review 2026-10-14 finding 1 strict is the default: an UNDETERMINED unit is stopped too, but it is logged as
# UNDETERMINED, never as FAILED; only the opt-out marker of a non-consumer-facing profile keeps it serving)
reset_world
cp "${GW_TREE}/bin/llmctl" "${TEST_TMP}/llmctl.real"; rm -f "${GW_TREE}/bin/llmctl"
printf '#!/usr/bin/env bash\nexit 1\n' > "${GW_TREE}/bin/llmctl"; chmod +x "${GW_TREE}/bin/llmctl"
rc="$(run_waiter GW_VALIDATE_RC=1)"
assert_eq 1 "$(b2i grep -qiE 'UNDETERMINED|could not be validated' "${LLMCTL_LOG_DIR}/svc_hook.log")" "llmctl crashed: reported loudly as UNDETERMINED"
assert_eq 0 "$(b2i grep -q 'FAILED (wrong answers)' "${LLMCTL_LOG_DIR}/svc_hook.log")" "llmctl crashed: NOT reported as a wrong answer"
assert_eq 1 "$(gw_count '^systemctl --user stop llmctl-llama@small.service$')" "llmctl crashed: UNDETERMINED -> the unit is stopped (strict default)"
reset_world
printf 'LLMCTL_UNVALIDATED=%s\n' "opt-out (test)" >> "${LLMCTL_SERVICES_DIR}/small.env"
rc="$(run_waiter GW_VALIDATE_RC=1)"
assert_eq 0 "$(gw_count '^systemctl --user stop')" "opt-out marker in the env record: the unit is NOT stopped"
assert_eq 1 "$(b2i gw_is_running small)" "opt-out marker: the reservation is untouched"
rm -f "${GW_TREE}/bin/llmctl"; cp "${TEST_TMP}/llmctl.real" "${GW_TREE}/bin/llmctl"; chmod +x "${GW_TREE}/bin/llmctl"
test_finish
