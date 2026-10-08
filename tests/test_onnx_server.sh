#!/usr/bin/env bash
# test_onnx_server.sh - startup / argument / secret-handling contract of the
# INTERNAL encoder scoring runtime (lib/onnx_server.py). The wire contract
# (POST /v1/score, /healthz, /readyz, truncation, labels, limits) is covered
# with real sockets in tests/test_onnx_runtime.sh; the typed-question logic
# that used to live here (noul|choice|score over /v1/systemone, the
# LLMCTL_ONNX_FAKE seam) moved to the Go gateway and is gone from this file.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT

RUNNER="${LLMCTL_ROOT}/lib/onnx_server.py"
STUBS="${LLMCTL_ROOT}/tests/fixtures/onnx_stubs"
run() { PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="${STUBS}" python3 -B "${RUNNER}" "$@" 2>&1; }

mkdir -p "${TEST_TMP}/m"
printf '{}' > "${TEST_TMP}/m/model.onnx"; echo spm > "${TEST_TMP}/m/spm.model"
printf 'k-secret-123\n' > "${TEST_TMP}/key"; chmod 600 "${TEST_TMP}/key"
printf 'k-secret-123\n' > "${TEST_TMP}/key-open"; chmod 644 "${TEST_TMP}/key-open"
: > "${TEST_TMP}/key-empty"; chmod 600 "${TEST_TMP}/key-empty"

out="$(run --port 1 --profile x --api-key-file "${TEST_TMP}/key")" && rc=0 || rc=$?
assert_eq 2 "${rc}" "missing --model-dir -> rc 2"
assert_contains "${out}" "--model-dir is required" "missing --model-dir -> message"
out="$(run --model-dir "${TEST_TMP}/nope" --port 1 --profile x --api-key-file "${TEST_TMP}/key")" && rc=0 || rc=$?
assert_eq 1 "${rc}" "nonexistent --model-dir -> rc 1"
assert_contains "${out}" "not a directory" "nonexistent --model-dir -> message"
out="$(run --model-dir "${TEST_TMP}/m" --port 1 --profile x)" && rc=0 || rc=$?
assert_eq 2 "${rc}" "no --api-key-file -> refuses to start (rc 2)"
assert_contains "${out}" "--api-key-file is required" "no --api-key-file -> message says key never comes from argv/env"
out="$(LLMCTL_DECIDE_API_KEY=from-env LLMCTL_API_KEY=from-env2 run --model-dir "${TEST_TMP}/m" --port 1 --profile x)" && rc=0 || rc=$?
assert_eq 2 "${rc}" "a key in the environment is NOT a substitute for --api-key-file"
out="$(run --model-dir "${TEST_TMP}/m" --port 1 --profile x --api-key k-secret)" && rc=0 || rc=$?
assert_eq 2 "${rc}" "--api-key on argv is not an accepted option (rc 2)"
assert_contains "${out}" "unrecognized arguments" "--api-key on argv -> argparse rejects it"
out="$(run --model-dir "${TEST_TMP}/m" --port 1 --profile x --api-key-file "${TEST_TMP}/key-open")" && rc=0 || rc=$?
assert_eq 1 "${rc}" "world-readable key file -> rc 1"
assert_contains "${out}" "must not be accessible by group/other" "world-readable key file -> message"
out="$(run --model-dir "${TEST_TMP}/m" --port 1 --profile x --api-key-file "${TEST_TMP}/key-empty")" && rc=0 || rc=$?
assert_eq 1 "${rc}" "empty key file -> rc 1"
out="$(run --model-dir "${TEST_TMP}/m" --port 1 --profile x --api-key-file "${TEST_TMP}/absent")" && rc=0 || rc=$?
assert_eq 1 "${rc}" "missing key file -> rc 1"
for h in 0.0.0.0 ::1 localhost 192.168.1.5; do
  out="$(run --model-dir "${TEST_TMP}/m" --port 1 --profile x --api-key-file "${TEST_TMP}/key" --host "${h}")" && rc=0 || rc=$?
  assert_eq 2 "${rc}" "--host ${h} refused (loopback 127.0.0.1 only)"
done
out="$(LLMCTL_BIND_HOST=0.0.0.0 run --model-dir "${TEST_TMP}/m" --port 1 --profile x --api-key-file "${TEST_TMP}/key")" && rc=0 || rc=$?
case "${out}" in *"must be 127.0.0.1"*) refused=1 ;; *) refused=0 ;; esac
assert_eq 0 "${refused}" "LLMCTL_BIND_HOST is ignored (the runtime has no env bind override)"
out="$(run --model-dir "${TEST_TMP}/m" --port 1 --profile x --api-key-file "${TEST_TMP}/key" --tokenizer ../etc/passwd)" && rc=0 || rc=$?
assert_eq 2 "${rc}" "--tokenizer must be a bare file name"
out="$(LLMCTL_ONNX_MAX_PAIRS=abc run --model-dir "${TEST_TMP}/m" --port 1 --profile x --api-key-file "${TEST_TMP}/key")" && rc=0 || rc=$?
assert_eq 2 "${rc}" "non-numeric LLMCTL_ONNX_MAX_PAIRS -> clean rc 2, no traceback"
case "${out}" in *Traceback*) tb=1 ;; *) tb=0 ;; esac
assert_eq 0 "${tb}" "bad env value: no Python traceback"

# deps missing -> actionable message naming `llmctl build onnx`, never a traceback (D-16)
mkdir -p "${TEST_TMP}/noort"
printf 'raise ImportError("hidden")\n' > "${TEST_TMP}/noort/onnxruntime.py"
out="$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="${TEST_TMP}/noort" python3 -B "${RUNNER}" --model-dir "${TEST_TMP}/m" --port 1 --profile x --api-key-file "${TEST_TMP}/key" 2>&1)" && rc=0 || rc=$?
assert_eq 1 "${rc}" "onnxruntime missing -> rc 1"
assert_contains "${out}" "llmctl build onnx" "onnxruntime missing -> message points at the hash-locked build"
case "${out}" in *Traceback*) tb=1 ;; *) tb=0 ;; esac
assert_eq 0 "${tb}" "onnxruntime missing: no traceback"

# malformed label config refuses to guess an order (N-21c)
mkdir -p "${TEST_TMP}/bad"
printf '{}' > "${TEST_TMP}/bad/model.onnx"; echo spm > "${TEST_TMP}/bad/spm.model"
printf '{"id2label":{"a":"entailment","b":"neutral","c":"contradiction"}}' > "${TEST_TMP}/bad/config.json"
out="$(run --model-dir "${TEST_TMP}/bad" --port 1 --profile x --api-key-file "${TEST_TMP}/key")" && rc=0 || rc=$?
assert_eq 1 "${rc}" "non-integer id2label key -> rc 1 (refuses to guess)"
assert_contains "${out}" "not an integer" "non-integer id2label key -> clear message"
case "${out}" in *Traceback*) tb=1 ;; *) tb=0 ;; esac
assert_eq 0 "${tb}" "non-integer id2label: no traceback"

test_finish
