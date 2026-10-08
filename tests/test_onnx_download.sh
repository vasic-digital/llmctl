#!/usr/bin/env bash
# test_onnx_download.sh - a toy onnx-engine decide profile through the
# verified download pipeline against a LOCAL http fixture, mirroring
# tests/test_decide_download.sh. Asserts:
#   1. structural validation (_dl_validate_onnx: model.onnx + tokenizer
#      present) runs and passes;
#   2. with stub onnxruntime/sentencepiece modules on PYTHONPATH
#      (tests/fixtures/onnx_stubs - the only stand-ins, no env seam in
#      production code) the REAL lib/onnx_server.py launches on the smoke
#      port, becomes /readyz-ready and the entail/contradict/batch probes
#      pass against POST /v1/score;
#   3. without the inference deps the smoke SKIPs with reason, the evidence
#      line is logged and download_profile does NOT claim "downloaded and
#      verified" (D-12);
#   4. a SIGTERM to the smoke shell leaves no orphaned runtime (D-14).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/catalog.sh"
source "${LLMCTL_ROOT}/lib/download.sh"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
LLMCTL_SMOKE_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
export LLMCTL_SMOKE_PORT
STUBS="${LLMCTL_ROOT}/tests/fixtures/onnx_stubs"
if ! python3 -c 'import numpy' 2>/dev/null; then
  assert_skip "numpy is not installed; the stub backends and the runtime need it" "onnx download smoke tests"
  test_finish; exit 0
fi
WWW="${TEST_TMP}/www"
REV="0123456789abcdef0123456789abcdef01234567"
mkdir -p "${WWW}/toy/onnx/resolve/${REV}/onnx"
MODEL_FIX="${WWW}/toy/onnx/resolve/${REV}/onnx/model.onnx"
TOK_FIX="${WWW}/toy/onnx/resolve/${REV}/onnx/spm.model"
# The stub onnxruntime reads model.onnx as a JSON behaviour spec (NOT a real ONNX protobuf).
printf '{"order":["entailment","neutral","contradiction"]}' > "${MODEL_FIX}"
printf 'llmctl toy sentencepiece payload - NOT a real spm\n' > "${TOK_FIX}"
CFG_FIX="${WWW}/toy/onnx/resolve/${REV}/onnx/config.json"
printf '{"id2label":{"0":"entailment","1":"neutral","2":"contradiction"}}' > "${CFG_FIX}"
CFG_SIZE="$(stat -c%s "${CFG_FIX}" 2>/dev/null || stat -f%z "${CFG_FIX}")"
CFG_SHA="$(llmctl_sha256 "${CFG_FIX}")"
MODEL_SIZE="$(stat -c%s "${MODEL_FIX}" 2>/dev/null || stat -f%z "${MODEL_FIX}")"
TOK_SIZE="$(stat -c%s "${TOK_FIX}" 2>/dev/null || stat -f%z "${TOK_FIX}")"
MODEL_SHA="$(llmctl_sha256 "${MODEL_FIX}")"
TOK_SHA="$(llmctl_sha256 "${TOK_FIX}")"

cat > "${TEST_TMP}/catalog-onnx.json" <<EOF
{
  "version": 1,
  "notes": "test catalog",
  "ports": {"toy-onnx": 9996},
  "profiles": {
    "toy-onnx": {
      "engine": "onnx",
      "capability": ["decide"],
      "min_tier": "below-minimum",
      "port": 9996,
      "hf_repo": "toy/onnx",
      "hf_revision": "${REV}",
      "desc": "tiny test onnx decision profile",
      "defaults": {"ctx": 512, "ngl": 0, "parallel": 1, "flash_attn": "off"},
      "files": [
        {"name": "onnx/model.onnx", "size": ${MODEL_SIZE}, "sha256": "${MODEL_SHA}", "role": "model"},
        {"name": "onnx/spm.model", "size": ${TOK_SIZE}, "sha256": "${TOK_SHA}", "role": "tokenizer"},
        {"name": "onnx/config.json", "size": ${CFG_SIZE}, "sha256": "${CFG_SHA}", "role": "config"}
      ]
    }
  }
}
EOF

python3 -m http.server "${PORT}" --bind 127.0.0.1 --directory "${WWW}" >/dev/null 2>&1 &
HTTP_PID=$!
trap 'kill ${HTTP_PID} 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 && break
  sleep 0.1
done

export LLMCTL_HF_BASE="http://127.0.0.1:${PORT}"
export LLMCTL_CATALOG="${TEST_TMP}/catalog-onnx.json"

# --- 1. stub backends on PYTHONPATH: REAL runtime launch + probes ---------------
export LLMCTL_SMOKE=1
export PYTHONPATH="${STUBS}${PYTHONPATH:+:${PYTHONPATH}}" PYTHONDONTWRITEBYTECODE=1
out="$(download_profile toy-onnx 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "download_profile toy-onnx (stub backends, smoke enabled): exit code"
printf '%s\n' "${out}" | sed 's/^/  /'
assert_file_exists "${LLMCTL_MODELS_DIR}/toy-onnx/onnx/model.onnx" "onnx/model.onnx exists after download (subdirectory preserved)"
assert_eq "${MODEL_SHA}" "$(llmctl_sha256 "${LLMCTL_MODELS_DIR}/toy-onnx/onnx/model.onnx")" "downloaded model sha256 matches"
EVID="${LLMCTL_VERIFY_DIR}/toy-onnx.log"
assert_file_contains "${EVID}" "structural check passed: model " "structural validation ran (model.onnx found)"
assert_file_contains "${EVID}" "tokenizer " "structural validation ran (tokenizer found)"
assert_file_contains "${EVID}" "smoke: " "onnx smoke launched the REAL lib/onnx_server.py"
assert_file_contains "${EVID}" "--api-key-file <throwaway 0600 file>" "evidence log shows the key goes via a 0600 file, never argv"
assert_file_contains "${EVID}" "smoke: /readyz OK" "smoke: runtime became ready (real load-time inference)"
assert_file_contains "${EVID}" "RUN: _dl_onnx_probe_entail" "probe evidence: entail"
assert_file_contains "${EVID}" "RUN: _dl_onnx_probe_contradict" "probe evidence: contradict"
assert_file_contains "${EVID}" "RUN: _dl_onnx_probe_batch" "probe evidence: batch"
assert_file_contains "${EVID}" '"top": "entailment"' "entail probe: argmax label is entailment"
assert_file_contains "${EVID}" '"top": "contradiction"' "contradict probe: argmax label is contradiction"
assert_file_contains "${EVID}" "onnx smoke PASSED" "smoke passed against the stub backends"
assert_file_contains "${EVID}" "download toy-onnx: SUCCESS" "evidence log records overall success"
assert_contains "${out}" "downloaded and verified" "smoke ran -> the verified claim IS made"

# --- 2. second run: marker-based SKIP -------------------------------------------
out="$(download_profile toy-onnx 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "second download: exit code"
assert_contains "${out}" "already present and verified: onnx/model.onnx (skipped)" \
  "second download: existing verified files are skipped (no re-download)"

# --- 3. missing deps: SKIP-with-reason, and NO "downloaded and verified" (D-12) --
rm -rf "${LLMCTL_MODELS_DIR}/toy-onnx" "${LLMCTL_VERIFY_DIR}/toy-onnx.log"
# an interpreter that cannot import the backends: -I-style isolation via an empty PYTHONPATH
# and a python that has no onnxruntime (real onnxruntime may exist on a dev host: shadow it
# with a module that raises ImportError).
mkdir -p "${TEST_TMP}/noort"
printf 'raise ImportError("onnxruntime deliberately hidden by the test")\n' > "${TEST_TMP}/noort/onnxruntime.py"
export PYTHONPATH="${TEST_TMP}/noort:${STUBS}"
out="$(download_profile toy-onnx 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "download without deps: still rc 0 (skip-warn precedent)"
assert_file_contains "${EVID}" "onnx smoke test SKIPPED: python package(s) not installed:" \
  "evidence log records the SKIP-with-reason line"
assert_contains "${out}" "smoke test SKIPPED" "operator-facing skip warning"
case "${out}" in *"downloaded and verified"*) claimed=1 ;; *) claimed=0 ;; esac
assert_eq 0 "${claimed}" "skipped smoke: the output does NOT claim 'downloaded and verified' (D-12)"
assert_file_contains "${EVID}" "FILES-VERIFIED, smoke not run" "evidence log distinguishes files-verified from fully-verified"
case "$(cat "${EVID}")" in *"download toy-onnx: SUCCESS"*) succ=1 ;; *) succ=0 ;; esac
assert_eq 0 "${succ}" "skipped smoke is NOT recorded as 'download toy-onnx: SUCCESS' (N-26)"
assert_file_contains "${EVID}" "structural check passed" "structural validation still ran before the skip"
export PYTHONPATH="${STUBS}"

# --- 4. SIGTERM to the smoke shell leaves no orphan runtime (D-14) --------------
rm -rf "${LLMCTL_MODELS_DIR}/toy-onnx"
download_profile toy-onnx >/dev/null 2>&1   # fetch + verify files again (smoke passes)
cat > "${TEST_TMP}/slowshell.sh" <<SLOW
set -u
source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/catalog.sh"; source "${LLMCTL_ROOT}/lib/download.sh"
_DL_EVIDENCE="${TEST_TMP}/slow-evidence.log"; : > "\${_DL_EVIDENCE}"
# slow the probes so the shell is still inside the smoke when TERM arrives
_dl_onnx_probe_entail() { sleep 20; }
_dl_smoke_test_onnx toy-onnx "${LLMCTL_MODELS_DIR}/toy-onnx"
SLOW
bash "${TEST_TMP}/slowshell.sh" >/dev/null 2>&1 &
SHELL_PID=$!
up=0
for _ in $(seq 1 100); do
  curl -fsS "http://127.0.0.1:${LLMCTL_SMOKE_PORT}/healthz" >/dev/null 2>&1 && { up=1; break; }
  sleep 0.1
done
assert_eq 1 "${up}" "D-14: smoke runtime is up while the shell is mid-smoke"
kill -TERM "${SHELL_PID}" 2>/dev/null || true
wait "${SHELL_PID}" 2>/dev/null || true
sleep 0.5
if curl -fsS "http://127.0.0.1:${LLMCTL_SMOKE_PORT}/healthz" >/dev/null 2>&1; then orphan=1; else orphan=0; fi
assert_eq 0 "${orphan}" "D-14: no orphaned onnx_server after SIGTERM to the smoke shell"

test_finish
