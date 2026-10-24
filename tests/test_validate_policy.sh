#!/usr/bin/env bash
# test_validate_policy.sh - review 2026-10-15 findings 6 and 8 (`llmctl validate` on a profile that is or was served):
#   finding 6: a FAIL (wrong answers) of a manual `llmctl validate <p>` left the PUBLISHED profile serving; the verdict
#              policy now applies: it is stopped and its registry row withdrawn. UNDETERMINED leaves it running but NOT
#              validated (status / require-validated / endpoint refuse) - documented. The unit waiter's own call
#              (LLMCTL_VALIDATE_ATTACH_PROFILE) is left to the waiter, which applies its own policy.
#   finding 8: `llmctl validate <p>` on a STOPPED, ENABLED profile starts it in quarantine, which rewrote the env record in
#              quarantine form and never restored it: at the next boot the unit's ExecCondition refused it (exit 77,
#              "expired validation-quarantine record") whatever the record said. The previous env record is restored.
# Harness: tests/gate_wiring_lib.sh (recording service manager, recorder validate_profile, ports remapped).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap 'gw_cleanup_bg; test_teardown_env' EXIT
source "$(dirname "${BASH_SOURCE[0]}")/gate_wiring_lib.sh"
gw_init
if [[ -n "${POL_MUT_FILE:-}" ]]; then    # mutation hook (tests/test_validation_mutants.sh group "policy")
  _mf="${GW_TREE}/lib/${POL_MUT_FILE}"; rm -f -- "${_mf:?}"; cp "${LLMCTL_ROOT}/lib/${POL_MUT_FILE}" "${_mf}"
  python3 -I - "${_mf}" "${POL_MUT_OLD}" "${POL_MUT_NEW}" <<'PY2'
import sys
f, old, new = sys.argv[1:4]
s = open(f).read()
if s.count(old) != 1: sys.exit("mutation anchor found %d times" % s.count(old))
open(f, "w").write(s.replace(old, new))
PY2
  echo "MUTANT applied to ${POL_MUT_FILE}"
fi
L="${GW_LLMCTL}"
b2i() { if "$@"; then echo 1; else echo 0; fi; }
P="$(gw_free_port)"

echo "== finding 6: a manual validate that FAILS stops the published profile"
gw_mark_running small "${P}"; gw_calls_reset
rc="$(GW_VALIDATE_RC=1 gw_run "${L}" validate small)"
assert_eq 1 "${rc}" "validate: FAIL -> exit 1"
assert_eq 1 "$(gw_count '^svc_stop small')" "the published profile is stopped through the normal stop path"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/small.run" "its reservation is removed (no longer served)"
assert_contains "$(gw_out)" "WRONG answers" "the reason is printed"

echo "== finding 6: UNDETERMINED leaves it running, NOT validated (and says so)"
gw_mark_running small "${P}"; gw_calls_reset
rc="$(GW_VALIDATE_RC=2 gw_run "${L}" validate small)"
assert_eq 2 "${rc}" "validate: UNDETERMINED -> exit 2"
assert_eq 0 "$(gw_count '^svc_stop small')" "not stopped"
assert_contains "$(gw_out)" "NOT validated" "the output says it keeps running NOT validated"

echo "== finding 6: the unit waiter's call (attach mode) is decided by the waiter, never by validate itself"
gw_mark_running small "${P}"; gw_calls_reset
rc="$(GW_VALIDATE_RC=1 gw_run env LLMCTL_VALIDATE_ATTACH_PROFILE=small LLMCTL_VALIDATE_ATTACH_PORT="${P}" "${L}" validate small)"
assert_eq 1 "${rc}" "attach mode: FAIL -> exit 1"
assert_eq 0 "$(gw_count '^svc_stop small')" "attach mode: nothing stopped by validate (the waiter stops the unit itself)"
rm -f "${LLMCTL_RUNTIME_DIR}/small.run" "${GW_ACTIVE_DIR}/small"

echo "== finding 6: --host (an external endpoint) never touches a local profile"
gw_mark_running small "${P}"; gw_calls_reset
rc="$(GW_VALIDATE_RC=1 gw_run "${L}" validate small --host "http://127.0.0.1:${P}")"
assert_eq 0 "$(gw_count '^svc_stop small')" "--host FAIL: the local profile is untouched"
rm -f "${LLMCTL_RUNTIME_DIR}/small.run" "${GW_ACTIVE_DIR}/small"

echo "== finding 8: validate on a STOPPED, ENABLED profile restores its env record"
gw_calls_reset
rc="$(GW_VALIDATE_RC=0 gw_run "${L}" enable small)"
assert_eq 0 "${rc}" "setup: enable small (validated)"
gw_run "${L}" stop small >/dev/null
assert_file_exists "${LLMCTL_SERVICES_DIR}/small.enabled" "setup: still enabled after the stop"
cp "${LLMCTL_SERVICES_DIR}/small.env" "${TEST_TMP}/small.env.before"
export GW_REAL_VALIDATE=1
rc="$(gw_run "${L}" validate small)"
assert_eq 2 "${rc}" "a real validation of the stopped profile (quarantine start; nothing answers) -> UNDETERMINED"
assert_eq 1 "$(gw_count '^svc_start small')" "...it was started (in quarantine) for the validation"
assert_eq 1 "$(b2i cmp -s "${TEST_TMP}/small.env.before" "${LLMCTL_SERVICES_DIR}/small.env")" "the env record is the enabled (public) one again, byte for byte"
assert_eq "" "$(sed -n 's/^LLMCTL_QUARANTINE_UNTIL=//p' "${LLMCTL_SERVICES_DIR}/small.env")" "no quarantine marker left in the env record"
LLMCTL_ROOT="${GW_TREE}" bash "${GW_TREE}/lib/svc_hook.sh" validated small > "${TEST_TMP}/hk.out" 2>&1 || true
assert_eq 0 "$(b2i grep -q 'expired validation-quarantine' "${TEST_TMP}/hk.out")" "the unit's ExecCondition no longer sees a stale quarantine record"
unset GW_REAL_VALIDATE

test_finish
