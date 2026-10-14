#!/usr/bin/env bash
# test_gate_wiring_restart_enable.sh - RED-FIRST specification of GAP 1 for the paths that SKIP validation today:
#   `llmctl restart <profile>`  (bin/llmctl: `sched_load_backend; svc_restart "$1"` - no hook at all)
#   `llmctl enable  <profile>`  (sched_enable -> _enable_impl - no hook at all)
# Desired behaviour, identical to the start paths (see test_gate_wiring_start_paths.sh):
#   * after the profile is up, validation runs EXACTLY ONCE, outside the scheduler lock (validate_profile may call
#     sched_start, whose flock is not re-entrant);
#   * FAIL (1)         -> stopped through the normal stop path (sched_stop -> svc_stop), non-zero exit, clear message;
#   * UNDETERMINED (2) -> stopped as well (strict default since review 2026-10-14 finding 1), loud, no PASS;
#   * PASS (0)         -> keeps running (restart: published after a quarantine start; enable: enabled after the PASS);
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

# ---- since review 2026-10-14 finding 1 the gate is ENFORCED (strict default; tests/test_validation_enforcement.sh):
#   restart of a profile without a fresh record: never a plain svc_restart on the public port - stop, quarantine start,
#   validate, then publish (PASS) or stop (FAIL / UNDETERMINED);
#   enable: the profile is validated (in quarantine) BEFORE any unit is enabled; FAIL / UNDETERMINED -> no unit enabled.
# The recorder writes no record; tests/gate_wiring_lib.sh's freshness overlay counts a recorded verdict 0 as a PASS record.
echo "== restart PASS: stop, quarantine start, validation once (outside the lock), published; never a plain svc_restart"
reset_world; prime_running small
rc="$(GW_VALIDATE_RC=0 gw_run "${L}" restart small)"
assert_eq 0 "${rc}" "restart: PASS -> exit 0"
assert_eq 1 "$(gw_count '^validate_profile small ')" "restart: validate_profile called exactly once"
assert_eq 1 "$(gw_count '^validate_profile small lock_held=no$')" "restart: validation ran OUTSIDE the scheduler lock"
assert_eq 0 "$(gw_count '^svc_restart small$')" "restart: an unvalidated profile is never restarted in place on its public port"
assert_eq 1 "$(b2i gw_is_running small)" "restart: PASS leaves the (published) profile running"
s_q="$(gw_line '^svc_start small$')"; s_val="$(gw_line '^validate_profile small ')"
assert_eq 1 "$(( s_q > 0 && s_val > s_q ? 1 : 0 ))" "restart: validation is AFTER the quarantine start (svc_start line ${s_q} < validate line ${s_val})"

for v in 1 2; do
  echo "== restart verdict ${v}: STOPPED (FAIL and UNDETERMINED alike - strict default), non-zero exit"
  reset_world; prime_running small
  rc="$(GW_VALIDATE_RC=${v} gw_run "${L}" restart small)"
  assert_eq 1 "$(gw_count '^validate_profile small ')" "restart rc ${v}: validation ran exactly once"
  assert_eq 0 "$(b2i gw_is_running small)" "restart rc ${v}: nothing left running"
  s_val="$(gw_line '^validate_profile small ')"; s_stop="$(gw_line_after '^svc_stop small$' "${s_val}")"
  assert_eq 1 "$(( s_stop > s_val && s_val > 0 ? 1 : 0 ))" "restart rc ${v}: stopped AFTER the verdict (validate ${s_val}, stop ${s_stop})"
  assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "restart rc ${v}: exit non-zero (rc=${rc})"
  assert_eq 1 "$(b2i out_has 'stopp(ed|ing)')" "restart rc ${v}: the message says it is stopped"
  assert_eq 0 "$(b2i grep -q PASSED "${TEST_TMP}/last.out")" "restart rc ${v}: never reported as PASSED"
done

echo "== enable PASS: validated (in quarantine) BEFORE the unit is enabled; runs; validated exactly once"
reset_world
rc="$(GW_VALIDATE_RC=0 gw_run "${L}" enable small)"
assert_eq 0 "${rc}" "enable: PASS -> exit 0"
assert_eq 1 "$(gw_count '^validate_profile small ')" "enable: validate_profile called exactly once"
assert_eq 1 "$(gw_count '^validate_profile small lock_held=no$')" "enable: validation ran OUTSIDE the scheduler lock"
assert_eq 1 "$(gw_count '^svc_enable small$')" "enable: the unit is enabled"
assert_eq 1 "$(b2i gw_is_running small)" "enable: PASS leaves the profile running"
s_val="$(gw_line '^validate_profile small ')"; s_en="$(gw_line '^svc_enable small$')"
assert_eq 1 "$(( s_val > 0 && s_en > s_val ? 1 : 0 ))" "enable: validation (${s_val}) BEFORE enablement (${s_en})"

for v in 1 2; do
  echo "== enable verdict ${v}: NO unit enabled, nothing running, non-zero exit"
  reset_world
  rc="$(GW_VALIDATE_RC=${v} gw_run "${L}" enable small)"
  assert_eq 1 "$(gw_count '^validate_profile small ')" "enable rc ${v}: validation ran exactly once"
  assert_eq 0 "$(gw_count '^svc_enable small$')" "enable rc ${v}: no unit enabled"
  assert_eq 0 "$(b2i gw_is_running small)" "enable rc ${v}: nothing running"
  assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "enable rc ${v}: exit non-zero (rc=${rc})"
  assert_eq 1 "$(b2i out_has 'NOT enabled')" "enable rc ${v}: the message says it is NOT enabled"
  assert_file_absent "${LLMCTL_SERVICES_DIR}/small.enabled" "enable rc ${v}: no .enabled marker"
done

for verb in restart enable; do
  echo "== ${verb} with LLMCTL_VALIDATE_ON_START=0 inside the test harness (LLMCTL_VALIDATE_HERMETIC=1): no validation, served UNVALIDATED"
  reset_world
  [[ "${verb}" == restart ]] && prime_running small
  rc="$(GW_VALIDATE_RC=1 gw_run env LLMCTL_VALIDATE_ON_START=0 "${L}" "${verb}" small)"
  assert_eq 0 "${rc}" "${verb}: ON_START=0 -> exit 0"
  assert_eq 0 "$(gw_count '^validate_profile ')" "${verb}: ON_START=0 -> validate_profile never called"
  assert_eq 0 "$(gw_count '^svc_stop ')" "${verb}: ON_START=0 -> nothing stopped"
  assert_eq 1 "$(b2i gw_is_running small)" "${verb}: ON_START=0 -> still running"
done

echo "== restart of a profile that is NOT running (no reservation): nothing is stopped before it was started"
reset_world
rc="$(GW_VALIDATE_RC=1 gw_run "${L}" restart small)"
s_first_stop="$(gw_line '^svc_stop ')"; s_first_start="$(gw_line '^svc_start small$')"
assert_eq 1 "$(( s_first_stop == 0 || s_first_stop > s_first_start ? 1 : 0 ))" "restart of a never-started profile: no stop is invented before a start (stop ${s_first_stop}, start ${s_first_start})"

test_finish
