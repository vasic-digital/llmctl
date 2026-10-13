#!/usr/bin/env bash
# test_onnx_eaddrinuse.sh - lib/onnx_server.py must exit 98 (EADDRINUSE, the code
# the generated units list in RestartPreventExitStatus) when its port is already
# bound, with a clear stderr message, and exit 1 for any other bind failure.
# Hermetic: free high loopback port + stub model backends (never 8096).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT

RUNNER="${LLMCTL_ROOT}/lib/onnx_server.py"
STUBS="${LLMCTL_ROOT}/tests/fixtures/onnx_stubs"
if ! python3 -c 'import numpy' 2>/dev/null; then
  assert_skip "numpy not installed; the runtime imports it" "onnx EADDRINUSE contract"
  test_finish; exit 0
fi
mkdir -p "${TEST_TMP}/m"
printf '{"order":["entailment","neutral","contradiction"]}' > "${TEST_TMP}/m/model.onnx"
echo spm > "${TEST_TMP}/m/spm.model"
printf 'k-secret-123\n' > "${TEST_TMP}/key"; chmod 600 "${TEST_TMP}/key"
run() { PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="${STUBS}" timeout 30 python3 -B "${RUNNER}" \
  --model-dir "${TEST_TMP}/m" --profile x --api-key-file "${TEST_TMP}/key" "$@" 2>&1; }

# hold a real listener on a free port
HOLDER_OUT="${TEST_TMP}/holder"
python3 -c '
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(1)
print(s.getsockname()[1], flush=True); time.sleep(60)' > "${HOLDER_OUT}" &
HPID=$!
trap 'kill "${HPID}" 2>/dev/null || true; test_teardown_env' EXIT
for _ in $(seq 1 50); do [[ -s "${HOLDER_OUT}" ]] && break; sleep 0.1; done
PORT="$(head -1 "${HOLDER_OUT}")"

out="$(run --port "${PORT}")" && rc=0 || rc=$?
assert_eq 98 "${rc}" "port already bound -> rc 98 (EADDRINUSE)"
assert_contains "${out}" "already in use" "EADDRINUSE -> clear message"
assert_contains "${out}" "${PORT}" "EADDRINUSE -> message names the port"
case "${out}" in *Traceback*) tb=1 ;; *) tb=0 ;; esac
assert_eq 0 "${tb}" "EADDRINUSE: no traceback"

if [[ "$(id -u)" != 0 ]]; then
  out="$(run --port 80)" && rc=0 || rc=$?
  assert_eq 1 "${rc}" "other bind failure (EACCES on :80) -> rc 1, not 98"
  assert_contains "${out}" "cannot bind" "other bind failure -> clear message"
fi
test_finish
