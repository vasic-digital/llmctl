#!/usr/bin/env bash
# test_validation_http_codes.sh - RED-first (wiring review #2). An HTTP 4xx used to count as a FAIL of the model, and a FAIL
# stops the model. Only 400 and 422 (the endpoint understood the request and refused its SHAPE) are a FAIL; 401/403
# (credentials), 404, 408, 413, 429 (operational) and 5xx are "no answer" -> UNDETERMINED (exit 2).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
PIDS=()
trap 'for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "${p}" 2>/dev/null || true; done; test_teardown_env' EXIT
J="${LLMCTL_ROOT}/lib/validate_judge.py"
SUITE="${LLMCTL_ROOT}/validation/suites/chat-v1"
SRV="${LLMCTL_ROOT}/tests/fixtures/validation/code_server.py"
for code in 400 422 401 403 404 408 413 429 500 503; do
  pf="${TEST_TMP}/port.${code}"
  python3 -I "${SRV}" 0 test-model "${code}" > "${pf}" & PIDS+=("$!")
  for (( i=0; i<50; i++ )); do [[ -s "${pf}" ]] && break; sleep 0.1; done
  rc=0; python3 -I "${J}" run --suite "${SUITE}" --endpoint "http://127.0.0.1:$(cat "${pf}")" >"${TEST_TMP}/o.${code}" 2>&1 || rc=$?
  case "${code}" in
    400|422) assert_eq 1 "${rc}" "HTTP ${code} (request shape refused) -> FAIL (exit 1)"
             assert_contains "$(cat "${TEST_TMP}/o.${code}")" "VERDICT: FAIL" "HTTP ${code}: explicit FAIL verdict" ;;
    *)       assert_eq 2 "${rc}" "HTTP ${code} -> UNDETERMINED (exit 2), never a FAIL"
             assert_contains "$(cat "${TEST_TMP}/o.${code}")" "VERDICT: UNDETERMINED" "HTTP ${code}: UNDETERMINED verdict" ;;
  esac
done
test_finish
