#!/usr/bin/env bash
# test_validation_exit_mapping.sh - RED-first (wiring review #1, HIGH). The gate STOPS a model on exit 1, so exit 1 must mean
# exactly one thing: an explicit "VERDICT: FAIL" of the judge. Every other exit or exception (PermissionError on the
# evidence write, a malformed suite -> TypeError/AttributeError, die()/set -e inside the validator) is UNDETERMINED (2):
# it must never stop a healthy model. Control: a genuine wrong answer still gives 1.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
PIDS=()
trap 'for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "${p}" 2>/dev/null || true; done; chmod -R u+rwx "${TEST_TMP}" 2>/dev/null || true; test_teardown_env' EXIT
J="${LLMCTL_ROOT}/lib/validate_judge.py"
SUITE="${LLMCTL_ROOT}/validation/suites/chat-v1"
SRV="${LLMCTL_ROOT}/tests/fixtures/validation/code_server.py"
start_srv() { # start_srv <code> [content] -> sets URL
  local pf="${TEST_TMP}/port.$RANDOM"
  python3 -I "${SRV}" 0 test-model "$@" > "${pf}" &
  PIDS+=("$!")
  local i; for (( i=0; i<50; i++ )); do [[ -s "${pf}" ]] && break; sleep 0.1; done
  URL="http://127.0.0.1:$(cat "${pf}")"
}
jrun() { local rc=0; python3 -I "${J}" run "$@" >"${TEST_TMP}/j.out" 2>&1 || rc=$?; echo "${rc}"; }

echo "== control: a genuine wrong answer (HTTP 200, wrong content) is an explicit FAIL -> exit 1"
start_srv 200 "definitely wrong"
assert_eq 1 "$(jrun --suite "${SUITE}" --endpoint "${URL}")" "control: wrong answer -> exit 1"
assert_contains "$(cat "${TEST_TMP}/j.out")" "VERDICT: FAIL" "control: the explicit verdict line is printed"

echo "== PermissionError on the evidence write -> 2, not a traceback exit 1"
mkdir -p "${TEST_TMP}/ro"; chmod 500 "${TEST_TMP}/ro"
if [[ -w "${TEST_TMP}/ro" ]]; then assert_skip "running as a user that ignores directory permissions" "evidence PermissionError"
else
  assert_eq 2 "$(jrun --suite "${SUITE}" --endpoint "${URL}" --evidence "${TEST_TMP}/ro/evidence.log")" "unwritable evidence file -> exit 2 (UNDETERMINED), never 1"
fi

echo "== malformed suite (valid JSON of the wrong shape) -> 2"
mkdir -p "${TEST_TMP}/badsuite"; printf '[]' > "${TEST_TMP}/badsuite/suite.json"
assert_eq 2 "$(jrun --suite "${TEST_TMP}/badsuite" --endpoint "${URL}")" "suite.json is a list (AttributeError/TypeError) -> exit 2"
printf '{"kind": 7, "suite": null, "probes": 3}' > "${TEST_TMP}/badsuite/suite.json"
assert_eq 2 "$(jrun --suite "${TEST_TMP}/badsuite" --endpoint "${URL}")" "suite.json with wrong field types -> exit 2"

echo "== die()/set -e inside the validator -> 2 through the CLI entry (_validate_cli), no FAIL"
rc=0
bash -c '
  export LLMCTL_ROOT="$1"
  for l in common os_detect hardware catalog scheduler validate; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
  validate_profile() { die "injected failure inside the validator"; }
  _validate_cli small
' _ "${LLMCTL_ROOT}" >"${TEST_TMP}/d.out" 2>&1 || rc=$?
assert_eq 2 "${rc}" "die() inside validate_profile -> exit 2"
rc=0
bash -c '
  set -e
  export LLMCTL_ROOT="$1"
  for l in common os_detect hardware catalog scheduler validate; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
  validate_profile() { false; return 1; }
  _validate_cli small
' _ "${LLMCTL_ROOT}" >"${TEST_TMP}/d.out" 2>&1 || rc=$?
assert_eq 1 "${rc}" "control: an explicit return 1 from validate_profile (its FAIL verdict) stays 1"

echo "== validate.sh: a judge crash (rc 1 WITHOUT a VERDICT: FAIL) is undetermined, not a FAIL"
cat > "${TEST_TMP}/crashjudge.py" <<'PY'
import sys
sys.exit(1)
PY
start_srv 200 "definitely wrong"
# end-to-end through validate_profile, with a lib copy whose judge crashes (exit 1, no verdict)
TREE="${TEST_TMP}/tree"; mkdir -p "${TREE}"; cp -r "${LLMCTL_ROOT}/lib" "${TREE}/lib"; ln -s "${LLMCTL_ROOT}/validation" "${TREE}/validation"; ln -s "${LLMCTL_ROOT}/models" "${TREE}/models"
cp "${TEST_TMP}/crashjudge.py" "${TREE}/lib/crash.py"
python3 - "${TREE}/lib/validate.sh" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('python3 -I "${LLMCTL_ROOT}/lib/validate_judge.py" "${jargs[@]}" & jpid=$!', 'python3 -I "${LLMCTL_ROOT}/lib/crash.py" "${jargs[@]}" & jpid=$!')
open(p, "w").write(s)
PY
mkdir -p "${LLMCTL_RUNTIME_DIR}" "${LLMCTL_MODELS_DIR}/small"
printf 'profile=small\nmode=gpu\nport=%s\nram_mb=1\nvram_mb=1\nstarted_epoch=%s\n' "${URL##*:}" "$(date +%s)" > "${LLMCTL_RUNTIME_DIR}/small.run"
rc=0
LLMCTL_ROOT="${TREE}" LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json" LLMCTL_VALIDATE_HERMETIC=1 bash -c '
  for l in common os_detect hardware catalog scheduler validate; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
  validate_profile small
' >"${TEST_TMP}/v.out" 2>&1 || rc=$?
assert_eq 2 "${rc}" "a crashing judge (exit 1, no VERDICT line) -> validate_profile exits 2, not 1"
test_finish
