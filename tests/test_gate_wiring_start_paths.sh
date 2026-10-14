#!/usr/bin/env bash
# test_gate_wiring_start_paths.sh - RED-FIRST specification of GAP 1 for the START paths (docs/validation.md "Known
# gaps" #1): `llmctl start`, `switch` and `auto` already CALL the validation hook after the profile is ready, but the
# gate is ADVISORY - a WRONG answer (validate_profile exit 1) leaves the model running. Desired behaviour:
#   * validation runs EXACTLY ONCE per started profile, OUTSIDE the scheduler lock (validate_profile itself may call
#     sched_start, whose flock is not re-entrant);
#   * FAIL (1)          -> the profile is STOPPED through the normal stop path (sched_stop -> svc_stop), the command
#                          exits non-zero with a clear message;
#   * UNDETERMINED (2)  -> STOPPED as well (strict is the default since review 2026-10-14 finding 1), loud, no PASS;
#   * PASS (0)          -> the QUARANTINE instance (loopback, private port, unpublished) is replaced by the published
#                          one, which keeps running (tests/test_validation_enforcement.sh covers the quarantine itself);
#   * a catalog profile that cannot be validated -> stopped + non-zero by default, the reason named;
#   * LLMCTL_VALIDATE_ON_START=0 still disables the hook (hermetic tests), loudly;
#   * `llmctl require-validated` exit codes (0 fresh PASS / 1 refused / 2 usage).
# Harness: tests/gate_wiring_lib.sh (recording service backend, validate_profile recorder, throw-away tree). No
# model, service, container or systemd is touched; nothing real exists to start.
# CONTROL sections prove the harness can SEE a wired call and can see the ABSENCE of one.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source "$(dirname "${BASH_SOURCE[0]}")/gate_wiring_lib.sh"
test_setup_env
trap 'gw_cleanup_bg; test_teardown_env' EXIT
gw_init
L="${GW_LLMCTL}"

# b2i <cmd...> -> 1 when the command succeeds, else 0 (for assert_eq on booleans)
b2i() { if "$@"; then echo 1; else echo 0; fi; }
out_has() { grep -qiE -- "$1" "${TEST_TMP}/last.out"; }

reset_world() { # nothing running, no calls, no records, default verdict env
  rm -f "${LLMCTL_RUNTIME_DIR:?}"/*.run "${GW_ACTIVE_DIR:?}"/* 2>/dev/null || true
  rm -rf "${LLMCTL_STATE_DIR:?}/validation"
  gw_calls_reset
  unset GW_VALIDATE_RC GW_VALIDATE_RC_small GW_VALIDATE_RC_vision GW_REAL_VALIDATE LLMCTL_VALIDATE_STRICT
  export LLMCTL_VALIDATE_ON_START=1
}

echo "== CONTROL 1: the harness records a validate_profile call (positive control) and its injected verdict"
reset_world
assert_eq 0 "$(gw_run "${L}" validate small)" "control: 'llmctl validate small' (stub verdict PASS) -> 0"
assert_eq 1 "$(gw_count '^validate_profile ')" "control: exactly one validate_profile call is visible to the harness"
assert_eq 1 "$(GW_VALIDATE_RC=1 gw_run "${L}" validate small)" "control: an injected FAIL verdict comes back as exit 1"

echo "== CONTROL 2: the harness sees NO validate_profile call on a path that does not validate (negative control)"
reset_world
LLMCTL_VALIDATE_ON_START=0 "${L}" start small >/dev/null 2>&1
gw_calls_reset
assert_eq 0 "$(gw_run "${L}" stop small)" "control: 'llmctl stop small' -> 0"
assert_eq 0 "$(gw_count '^validate_profile ')" "control: stop makes ZERO validate_profile calls (the harness does not invent calls)"
assert_eq 1 "$(gw_count '^svc_stop small$')" "control: the harness sees the normal stop path (svc_stop small)"
assert_eq 0 "$(b2i gw_is_running small)" "control: stop removes the reservation"

for verb in start switch; do
  echo "== ${verb} PASS: validation runs exactly once, outside the scheduler lock; profile keeps running"
  reset_world
  rc="$(GW_VALIDATE_RC=0 gw_run "${L}" "${verb}" small)"
  assert_eq 0 "${rc}" "${verb}: PASS -> exit 0"
  assert_eq 1 "$(gw_count '^validate_profile small ')" "${verb}: validate_profile called exactly once"
  assert_eq 1 "$(gw_count '^validate_profile small lock_held=no$')" "${verb}: validation ran OUTSIDE the scheduler lock (not recursive)"
  assert_eq 1 "$(gw_count '^svc_stop small$')" "${verb}: PASS: the quarantine instance is stopped once (then the profile is published)"
  assert_eq 2 "$(gw_count '^svc_start small$')" "${verb}: PASS: started twice - quarantine, then published"
  assert_eq 1 "$(b2i gw_is_running small)" "${verb}: PASS leaves the profile running"
  s_start="$(gw_line '^svc_start small$')"; s_val="$(gw_line '^validate_profile small ')"
  assert_eq 1 "$(( s_start > 0 && s_val > s_start ? 1 : 0 ))" "${verb}: validation is AFTER the profile became ready (svc_start line ${s_start} < validate line ${s_val})"

  echo "== ${verb} FAIL (rc 1): the profile is STOPPED through the normal stop path and the command exits non-zero"
  reset_world
  rc="$(GW_VALIDATE_RC=1 gw_run "${L}" "${verb}" small)"
  assert_eq 1 "$(gw_count '^validate_profile small ')" "${verb}: FAIL: validation still ran exactly once"
  assert_eq 1 "$(gw_count '^svc_stop small$')" "${verb}: FAIL: the profile is stopped through sched_stop -> svc_stop (RED: the gate is advisory today)"
  assert_eq 0 "$(b2i gw_is_running small)" "${verb}: FAIL: no reservation is left behind"
  s_val="$(gw_line '^validate_profile small ')"; s_stop="$(gw_line '^svc_stop small$')"
  assert_eq 1 "$(( s_stop > s_val && s_val > 0 ? 1 : 0 ))" "${verb}: FAIL: the stop comes AFTER the verdict (validate line ${s_val}, stop line ${s_stop})"
  assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "${verb}: FAIL: exit code is non-zero (rc=${rc})"
  assert_eq 1 "$(b2i out_has 'small')" "${verb}: FAIL: the message names the profile"
  assert_eq 1 "$(b2i out_has 'stopp(ed|ing)')" "${verb}: FAIL: the message says the profile was STOPPED"
  assert_eq 1 "$(b2i out_has 'validat')" "${verb}: FAIL: the message says it was the validation that failed"

  echo "== ${verb} UNDETERMINED (rc 2): STOPPED (strict default), loud, never a PASS"
  reset_world
  rc="$(GW_VALIDATE_RC=2 gw_run "${L}" "${verb}" small)"
  assert_eq 1 "$(gw_count '^validate_profile small ')" "${verb}: UNDETERMINED: validation ran exactly once"
  assert_eq 1 "$(gw_count '^svc_stop small$')" "${verb}: UNDETERMINED: the profile is stopped (an unvalidated model is never served)"
  assert_eq 0 "$(b2i gw_is_running small)" "${verb}: UNDETERMINED: nothing left running"
  assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "${verb}: UNDETERMINED: exit code is non-zero (rc=${rc})"
  assert_eq 1 "$(b2i out_has 'UNDETERMINED|could not be validated')" "${verb}: UNDETERMINED is reported loudly"
  assert_eq 0 "$(b2i grep -q PASSED "${TEST_TMP}/last.out")" "${verb}: UNDETERMINED is never reported as PASSED"
  assert_file_absent "${LLMCTL_STATE_DIR}/validation/small.json" "${verb}: UNDETERMINED records no PASS (no state file)"
  assert_eq 1 "$(gw_run "${L}" require-validated small)" "${verb}: require-validated still refuses after an UNDETERMINED start"
done

echo "== auto FAIL / UNDETERMINED / PASS (auto picks the best-ranked downloaded profile)"
gw_touch_model coder
reset_world
rc="$(GW_VALIDATE_RC=0 gw_run "${L}" auto chat)"
if [[ "$(gw_count '^svc_start ')" -eq 0 ]]; then
  assert_skip "'llmctl auto chat' started nothing on the hermetic fixture host (rc=${rc}): $(gw_out | head -c 300 | tr '\n' ' ')" "auto path wiring cannot be exercised on this fixture"
else
  started="$(grep -E '^svc_start ' "${GW_CALLS}" | head -1 | cut -d' ' -f2)"
  assert_eq 1 "$(gw_count "^validate_profile ${started} ")" "auto PASS: validation ran exactly once for '${started}'"
  assert_eq 1 "$(gw_count "^validate_profile ${started} lock_held=no\$")" "auto PASS: outside the scheduler lock"
  reset_world
  rc="$(GW_VALIDATE_RC=1 gw_run "${L}" auto chat)"
  assert_eq 1 "$(gw_count "^svc_stop ${started}\$")" "auto FAIL: '${started}' is stopped through the normal stop path (RED: advisory today)"
  assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "auto FAIL: exit code is non-zero (rc=${rc})"
  reset_world
  rc="$(GW_VALIDATE_RC=2 gw_run "${L}" auto chat)"
  assert_eq 1 "$(gw_count "^svc_stop ${started}\$")" "auto UNDETERMINED: '${started}' is stopped (strict default)"
fi

echo "== (b) a catalog profile that CANNOT be validated (decide-tiny: jev-verdict has no driver): stopped by default, reason named"
gw_touch_model decide-tiny
reset_world
export GW_REAL_VALIDATE=1   # the REAL validate_profile: decide-tiny's suite is UNDETERMINED (no driver for jev-verdict)
rc="$(gw_run "${L}" start decide-tiny)"
assert_eq 1 "$(gw_count '^svc_start decide-tiny$')" "decide-tiny was started (in quarantine) for its validation"
assert_eq 1 "$(gw_count '^svc_stop decide-tiny$')" "default (strict): the profile is stopped"
assert_eq 0 "$(b2i gw_is_running decide-tiny)" "...nothing left running"
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "...exit non-zero (rc=${rc})"
assert_eq 1 "$(b2i out_has 'no (llmctl )?validation suite|implemented by no decide driver')" "...the message names why it cannot be validated (jev-verdict has no driver)"
assert_eq 0 "$(python3 -I -c 'import json,sys
try: print(1 if json.load(open(sys.argv[1])).get("status") == "pass" else 0)
except OSError: print(0)' "${LLMCTL_STATE_DIR}/validation/decide-tiny.json")" "...nothing records a PASS"
assert_eq 1 "$(gw_run "${L}" require-validated decide-tiny)" "...require-validated refuses"
reset_world
export GW_REAL_VALIDATE=1
rc="$(gw_run env LLMCTL_VALIDATE_STRICT=0 "${L}" start decide-tiny)"
assert_eq 1 "$(gw_count '^svc_stop decide-tiny$')" "LLMCTL_VALIDATE_STRICT=0 on a consumer-facing profile: refused, stopped"
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "...exit non-zero (rc=${rc})"
unset GW_REAL_VALIDATE

echo "== (c) LLMCTL_VALIDATE_ON_START=0 still disables the hook inside the test harness (LLMCTL_VALIDATE_HERMETIC=1; refused outside it: tests/test_validation_enforcement.sh)"
reset_world
rc="$(GW_VALIDATE_RC=1 gw_run env LLMCTL_VALIDATE_ON_START=0 "${L}" start small)"
assert_eq 0 "${rc}" "ON_START=0: start exits 0 even though a validator would FAIL"
assert_eq 0 "$(gw_count '^validate_profile ')" "ON_START=0: validate_profile is never called"
assert_eq 0 "$(gw_count '^svc_stop ')" "ON_START=0: nothing is stopped"
assert_eq 1 "$(b2i out_has 'NOT validated|validation on start disabled')" "ON_START=0: says loudly that nothing was validated"

echo "== (d) require-validated exit codes"
reset_world
assert_eq 2 "$(gw_run "${L}" require-validated)" "require-validated without a profile -> 2 (usage)"
assert_eq 1 "$(gw_run "${L}" require-validated small)" "require-validated on a never-validated profile -> 1"
assert_contains "$(gw_out)" "no validation record" "...with the reason"
assert_eq 1 "$(( $(gw_run "${L}" require-validated no-such-profile) != 0 ? 1 : 0 ))" "require-validated on an unknown profile is refused (non-zero), never a pass"

test_finish
