#!/usr/bin/env bash
# test_gate_wiring_restart_enable.sh - RED-FIRST specification of GAP 1 for the paths that SKIP validation today:
#   `llmctl restart <profile>`  (bin/llmctl: `sched_load_backend; svc_restart "$1"` - no hook at all)
#   `llmctl enable  <profile>`  (sched_enable -> _enable_impl - no hook at all)
# Desired behaviour, identical to the start paths (see test_gate_wiring_start_paths.sh):
#   * after the profile is up, validation runs EXACTLY ONCE, outside the scheduler lock (validate_profile may call
#     sched_start, whose flock is not re-entrant);
#   * FAIL (1)         -> stopped through the normal stop path (sched_stop -> svc_stop), non-zero exit, clear message;
#   * UNDETERMINED (2) -> NOT stopped, loud, nothing records a PASS;
#   * PASS (0)         -> keeps running;
#   * LLMCTL_VALIDATE_ON_START=0 still disables the hook.
# CONTROLs: the wired `start` path (positive control: the harness DOES see a validation call there) and the
# harness's view of restart/enable verbs themselves (svc_restart / svc_enable are recorded, so a missing validation
# line is a genuine absence and not a blind recorder).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source "$(dirname "${BASH_SOURCE[0]}")/gate_wiring_lib.sh"
test_setup_env
trap 'gw_cleanup_bg; test_teardown_env' EXIT
gw_init
L="${GW_LLMCTL}"

b2i() { if "$@"; then echo 1; else echo 0; fi; }
out_has() { grep -qiE -- "$1" "${TEST_TMP}/last.out"; }

reset_world() {
  rm -f "${LLMCTL_RUNTIME_DIR:?}"/*.run "${GW_ACTIVE_DIR:?}"/* "${LLMCTL_SERVICES_DIR:?}"/*.enabled 2>/dev/null || true
  rm -rf "${LLMCTL_STATE_DIR:?}/validation"
  gw_calls_reset
  unset GW_VALIDATE_RC GW_VALIDATE_RC_small GW_REAL_VALIDATE LLMCTL_VALIDATE_STRICT
  export LLMCTL_VALIDATE_ON_START=1
}
# prime_running <profile> -> the profile is up (started with validation OFF), call log emptied
prime_running() {
  LLMCTL_VALIDATE_ON_START=0 "${L}" start "$1" >/dev/null 2>&1
  gw_calls_reset
}

echo "== CONTROL A (positive): the WIRED path 'start' shows a validation call to the harness"
reset_world
assert_eq 0 "$(gw_run "${L}" start small)" "control: start small -> 0"
assert_eq 1 "$(gw_count '^validate_profile small ')" "control: the harness SEES the start path's validation (so a zero below is a real zero)"

echo "== CONTROL B (negative): the harness sees the restart / enable verbs themselves"
reset_world
prime_running small
assert_eq 0 "$(LLMCTL_VALIDATE_ON_START=0 gw_run "${L}" restart small)" "control: restart small (validation disabled) -> 0"
assert_eq 1 "$(gw_count '^svc_restart small$')" "control: svc_restart is recorded"
assert_eq 0 "$(gw_count '^validate_profile ')" "control: ON_START=0 -> no validation call (the recorder has no phantom calls)"
reset_world
assert_eq 0 "$(LLMCTL_VALIDATE_ON_START=0 gw_run "${L}" enable small)" "control: enable small (validation disabled) -> 0"
assert_eq 1 "$(gw_count '^svc_enable small$')" "control: svc_enable is recorded"
assert_eq 0 "$(gw_count '^validate_profile ')" "control: ON_START=0 -> no validation call"

for verb in restart enable; do
  echo "== ${verb} PASS: validation runs exactly once, outside the scheduler lock; profile keeps running"
  reset_world
  [[ "${verb}" == restart ]] && prime_running small
  rc="$(GW_VALIDATE_RC=0 gw_run "${L}" "${verb}" small)"
  assert_eq 0 "${rc}" "${verb}: PASS -> exit 0"
  assert_eq 1 "$(gw_count '^validate_profile small ')" "${verb}: validate_profile called exactly once (RED: ${verb} skips validation today)"
  assert_eq 1 "$(gw_count '^validate_profile small lock_held=no$')" "${verb}: validation ran OUTSIDE the scheduler lock (not recursive)"
  assert_eq 0 "$(gw_count '^svc_stop ')" "${verb}: PASS never stops the profile"
  assert_eq 1 "$(b2i gw_is_running small)" "${verb}: PASS leaves the profile running"
  s_up="$(gw_line "^svc_${verb} small\$")"; s_val="$(gw_line '^validate_profile small ')"
  assert_eq 1 "$(( s_up > 0 && s_val > s_up ? 1 : 0 ))" "${verb}: validation is AFTER the unit was (re)started (svc_${verb} line ${s_up} < validate line ${s_val})"

  echo "== ${verb} FAIL (rc 1): STOPPED through the normal stop path, non-zero exit, clear message"
  reset_world
  [[ "${verb}" == restart ]] && prime_running small
  rc="$(GW_VALIDATE_RC=1 gw_run "${L}" "${verb}" small)"
  assert_eq 1 "$(gw_count '^validate_profile small ')" "${verb}: FAIL: validation ran exactly once"
  assert_eq 1 "$(gw_count '^svc_stop small$')" "${verb}: FAIL: the profile is stopped through sched_stop -> svc_stop"
  assert_eq 0 "$(b2i gw_is_running small)" "${verb}: FAIL: no reservation is left behind"
  s_val="$(gw_line '^validate_profile small ')"; s_stop="$(gw_line '^svc_stop small$')"
  assert_eq 1 "$(( s_stop > s_val && s_val > 0 ? 1 : 0 ))" "${verb}: FAIL: the stop comes AFTER the verdict (validate line ${s_val}, stop line ${s_stop})"
  assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "${verb}: FAIL: exit code is non-zero (rc=${rc}); NOT a unit/main-process failure that Restart=on-failure would count"
  assert_eq 1 "$(b2i out_has 'small')" "${verb}: FAIL: the message names the profile"
  assert_eq 1 "$(b2i out_has 'stopp(ed|ing)')" "${verb}: FAIL: the message says the profile was STOPPED"
  assert_eq 1 "$(b2i out_has 'validat')" "${verb}: FAIL: the message says it was the validation that failed"

  echo "== ${verb} UNDETERMINED (rc 2): NOT stopped, loud, never a PASS"
  reset_world
  [[ "${verb}" == restart ]] && prime_running small
  rc="$(GW_VALIDATE_RC=2 gw_run "${L}" "${verb}" small)"
  assert_eq 1 "$(gw_count '^validate_profile small ')" "${verb}: UNDETERMINED: validation ran exactly once"
  assert_eq 0 "$(gw_count '^svc_stop ')" "${verb}: UNDETERMINED never stops a running profile"
  assert_eq 1 "$(b2i gw_is_running small)" "${verb}: UNDETERMINED leaves the profile running"
  assert_eq 1 "$(b2i out_has 'UNDETERMINED|could not be validated')" "${verb}: UNDETERMINED is reported loudly"
  assert_eq 0 "$(b2i grep -q PASSED "${TEST_TMP}/last.out")" "${verb}: UNDETERMINED is never reported as PASSED"
  assert_file_absent "${LLMCTL_STATE_DIR}/validation/small.json" "${verb}: UNDETERMINED records no PASS"

  echo "== ${verb} with LLMCTL_VALIDATE_ON_START=0: the hook stays disabled even for a would-be FAIL"
  reset_world
  [[ "${verb}" == restart ]] && prime_running small
  rc="$(GW_VALIDATE_RC=1 gw_run env LLMCTL_VALIDATE_ON_START=0 "${L}" "${verb}" small)"
  assert_eq 0 "${rc}" "${verb}: ON_START=0 -> exit 0"
  assert_eq 0 "$(gw_count '^validate_profile ')" "${verb}: ON_START=0 -> validate_profile never called"
  assert_eq 0 "$(gw_count '^svc_stop ')" "${verb}: ON_START=0 -> nothing stopped"
  assert_eq 1 "$(b2i gw_is_running small)" "${verb}: ON_START=0 -> still running"
done

echo "== restart of a profile that is NOT running (no reservation): validation must not run against a ghost"
reset_world
rc="$(GW_VALIDATE_RC=1 gw_run "${L}" restart small)"
assert_eq 0 "$(gw_count '^svc_stop ')" "restart of a never-started profile: no stop is invented"

test_finish
