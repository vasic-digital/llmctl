#!/usr/bin/env bash
# test_validation_r2_small.sh - review 2026-10-15 finding 11, the small items:
#   * LLMCTL_VALIDATION_MAX_AGE accepted 12-digit values (records fresh for millennia): capped at 400 days (34560000 s);
#   * an existing validation directory with looser permissions is tightened to 0700;
#   * `llmctl status` said "validated" for a signed PASS record whose model bytes no longer matched (require-validated refused):
#     the label now follows the same check as require-validated;
#   * decide-tiny's coverage text said "never executed" - it cannot be validated at all (no driver).
# Fixture server only (tests/validation_local_lib.sh); no model, no unit.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
source "$(dirname "${BASH_SOURCE[0]}")/validation_local_lib.sh"
trap 'vl_cleanup; test_teardown_env' EXIT
vl_setup
L="${VL_LLMCTL}"
export LLMCTL_SERVICE_BACKEND_FILE="${LLMCTL_ROOT}/tests/fixtures/svc_backend_recording.sh" GW_CALLS="${TEST_TMP}/calls" GW_ACTIVE_DIR="${TEST_TMP}/active"
: > "${GW_CALLS}"; mkdir -p "${GW_ACTIVE_DIR}"

echo "== max age: whole seconds 0..34560000 only"
assert_eq 2 "$(vl_rc env LLMCTL_VALIDATION_MAX_AGE=999999999999 "${L}" require-validated vision)" "a 12-digit max age -> refused (exit 2)"
assert_contains "$(cat "${TEST_TMP}/last.out")" "34560000" "the limit is named"
assert_eq 2 "$(vl_rc env LLMCTL_VALIDATION_MAX_AGE=34560001 "${L}" require-validated vision)" "400 days + 1 s -> refused"
assert_eq 1 "$(vl_rc env LLMCTL_VALIDATION_MAX_AGE=34560000 "${L}" require-validated vision)" "control: 400 days is a valid limit (no record -> not validated, exit 1)"

echo "== an existing validation directory is tightened to 0700"
mkdir -p "${LLMCTL_STATE_DIR}/validation"; chmod 755 "${LLMCTL_STATE_DIR}/validation"
vl_rc "${L}" require-validated vision >/dev/null
assert_eq 700 "$(stat -c '%a' "${LLMCTL_STATE_DIR}/validation")" "validation/ is 0700 after use"

echo "== status says 'validated' only when require-validated would accept the running profile"
U="$(vl_fake_start "${VL_FIX}/answers_good.json" --model "${VL_MODEL}")"; vl_mark_running "${U##*:}"; : > "${GW_ACTIVE_DIR}/vision"
assert_eq 0 "$(vl_rc "${L}" validate vision)" "setup: a real signed PASS record"
assert_contains "$(vl_rc "${L}" status >/dev/null; cat "${TEST_TMP}/last.out")" "validation: validated" "control: status says validated"
printf 'other bytes\n' >> "${VL_MODEL}"
assert_eq 1 "$(vl_rc "${L}" require-validated vision)" "the model bytes changed: require-validated refuses"
vl_rc "${L}" status >/dev/null
assert_contains "$(cat "${TEST_TMP}/last.out")" "validation: NOT VALIDATED" "status no longer says validated"

echo "== decide-tiny: 'cannot be validated (no driver)'"
assert_contains "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["profiles"]["decide-tiny"]["validation"]["unexecuted_reason"])' "${LLMCTL_ROOT}/models/catalog.json")" "CANNOT be validated (no driver)" "the catalog says it cannot be validated at all"
test_finish
