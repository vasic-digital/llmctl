#!/usr/bin/env bash
# test_validation_identity.sh - RED-first (wiring review #6).
#  (a) LLMCTL_VALIDATE_ATTACH_PORT must be honoured only together with LLMCTL_VALIDATE_ATTACH_PROFILE == the profile being
#      validated (the waiter sets both): a stray exported port must never redirect another profile's probes.
#  (b) --expect-model is an EXACT identity: the served id equals it, or its basename does (llama-server serves the model PATH);
#      a substring ("test-model" inside "other-test-model-2") is not the expected model.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
PIDS=()
cleanup() { local q; for q in ${PIDS[@]+"${PIDS[@]}"}; do kill "${q}" 2>/dev/null || true; done; test_teardown_env; }
trap cleanup EXIT
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
vp() { env "$@" bash -c 'for l in common os_detect hardware catalog scheduler validate; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done; _val_port small' 2>/dev/null || echo NONE; }
assert_eq NONE "$(vp LLMCTL_ROOT="${LLMCTL_ROOT}" LLMCTL_VALIDATE_ATTACH_PORT=4321)" "(a) port without a matching profile marker is ignored"
assert_eq NONE "$(vp LLMCTL_ROOT="${LLMCTL_ROOT}" LLMCTL_VALIDATE_ATTACH_PORT=4321 LLMCTL_VALIDATE_ATTACH_PROFILE=vision)" "(a) a marker for ANOTHER profile is ignored"
assert_eq 4321 "$(vp LLMCTL_ROOT="${LLMCTL_ROOT}" LLMCTL_VALIDATE_ATTACH_PORT=4321 LLMCTL_VALIDATE_ATTACH_PROFILE=small)" "(a) control: port + matching profile marker is honoured"

J="${LLMCTL_ROOT}/lib/validate_judge.py"; SUITE="${LLMCTL_ROOT}/validation/suites/chat-v1"; SRV="${LLMCTL_ROOT}/tests/fixtures/validation/code_server.py"
serve() { # serve <model-id> -> sets URL (runs in THIS shell so the server pid is registered for cleanup)
  local pf="${TEST_TMP}/port.$RANDOM" i
  python3 -I "${SRV}" 0 "$1" 200 "definitely wrong" > "${pf}" 2>/dev/null </dev/null &
  PIDS+=("$!")
  for (( i=0; i<50; i++ )); do [[ -s "${pf}" ]] && break; sleep 0.1; done
  URL="http://127.0.0.1:$(cat "${pf}")"
}
jr() { local rc=0; python3 -I "${J}" run --suite "${SUITE}" --endpoint "${URL}" --expect-model test-model >"${TEST_TMP}/o" 2>&1 || rc=$?; echo "${rc}"; }
serve test-model;                assert_eq 1 "$(jr)" "(b) control: the exact id is the expected model (wrong answers -> FAIL 1)"
serve /models/small/test-model;  assert_eq 1 "$(jr)" "(b) the id may be a PATH whose basename is the expected model"
serve other-test-model-2;        assert_eq 2 "$(jr)" "(b) a substring match is NOT the expected model -> UNDETERMINED"
assert_contains "$(cat "${TEST_TMP}/o")" "not the expected model" "(b) the reason is stated"
test_finish
