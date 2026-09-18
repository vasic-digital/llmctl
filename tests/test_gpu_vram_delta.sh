#!/usr/bin/env bash
# test_gpu_vram_delta.sh - 005-cuda-gpu-inference T007/T008 (spec.md
# Acceptance Scenario 2, SC-002): proves a real, GPU-eligible cataloged
# profile's model load produces a MEASURED >= 500 MiB VRAM delta on this
# host, observed independently of llama-server's own self-reported
# success line, via a real `nvidia-smi --query-gpu=memory.used`
# before/after/during-inference comparison (research.md R4).
#
# This test launches llama-server DIRECTLY (mirroring
# lib/download.sh's _dl_smoke_test_gguf() real-completion pattern,
# per the task brief) rather than through the systemd-backed
# lib/scheduler.sh path, so it can force a specific --n-gpu-layers value
# per invocation without needing `llmctl install` units or disturbing
# any already-running persistent llmctl services on this host.
#
# Real requirements, no mocking (Constitution Principle IV / §11.4.27):
# - a real, already-downloaded GGUF model file
# - a real llama-server subprocess, real HTTP requests
# - real `nvidia-smi` output, sampled from the live GPU
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/os_detect.sh"
source "${LLMCTL_ROOT}/lib/hardware.sh"
source "${LLMCTL_ROOT}/lib/catalog.sh"

# --- prerequisites: this test needs a real GPU + a real built binary +
# a real, already-downloaded model. Any absence is an honest SKIP
# (Constitution §11.4.3), never a fabricated PASS or a silent no-op. ------
PROFILE="${LLMCTL_TEST_GPU_PROFILE:-small}"
QA_DIR="${LLMCTL_ROOT}/docs/qa/005-cuda-gpu-inference"
mkdir -p "${QA_DIR}"
EVIDENCE="${QA_DIR}/vram_delta.txt"

if ! have_cmd nvidia-smi; then
  assert_skip "nvidia-smi not present on this host" "GPU VRAM-delta measurement"
  { echo "SKIPPED: nvidia-smi not present on this host"; } > "${EVIDENCE}"
  test_finish
fi

# LLMCTL_TEST_SERVER_BIN: override the llama-server binary under test.
# Used by this feature's own T007 RED-first verification to point at a
# deliberately CPU-only build (built into a separate directory, never
# touching the real submodules/llama.cpp/build the rest of this project
# depends on) to prove this test genuinely fails (no meaningful VRAM
# delta) when there is no real GPU backend - never asserted, always
# actually run.
SERVER_BIN="${LLMCTL_TEST_SERVER_BIN:-${LLMCTL_ROOT}/submodules/llama.cpp/build/bin/llama-server}"
if [[ ! -x "${SERVER_BIN}" ]]; then
  assert_skip "llama-server not built (${SERVER_BIN} missing)" "GPU VRAM-delta measurement"
  { echo "SKIPPED: llama-server not built at ${SERVER_BIN}"; } > "${EVIDENCE}"
  test_finish
fi

# Real, external catalog + real, external model store on THIS host (NOT
# TEST_TMP's isolated env - this test deliberately measures the real,
# already-downloaded models this feature's spec targets). test_setup_env
# (helpers.sh) EXPORTS LLMCTL_MODELS_DIR (and siblings) pointing at
# TEST_TMP, so every subshell resolving the REAL host paths below MUST
# explicitly unset them first, or lib/common.sh's own
# "${LLMCTL_MODELS_DIR:-...}" default-if-unset idiom silently inherits
# the isolated TEST_TMP path instead of the real one (reproduced: without
# the `env -u` below, this test SKIPPED claiming the model was "not
# downloaded" at a /tmp/tmp.XXXX/models/... path that was never real).
_ISOLATION_VARS=(LLMCTL_STATE_DIR LLMCTL_RUNTIME_DIR LLMCTL_CONFIG_DIR
  LLMCTL_DATA_DIR LLMCTL_MODELS_DIR LLMCTL_LOG_DIR LLMCTL_VERIFY_DIR
  LLMCTL_SERVICES_DIR LLMCTL_UNIT_DIR LLMCTL_PLIST_DIR)
real_env() { env "${_ISOLATION_VARS[@]/#/-u}" "$@"; }

REAL_CATALOG="${LLMCTL_ROOT}/models/catalog.json"
REAL_MODELS_DIR="$(cd "${LLMCTL_ROOT}" && real_env bash -c 'source lib/common.sh; echo "${LLMCTL_MODELS_DIR}"')"

MODEL_NAME=""
while IFS='|' read -r name _ _ role; do
  [[ "${role}" == "mmproj" ]] && continue
  MODEL_NAME="${name}"
  break
done < <(LLMCTL_CATALOG="${REAL_CATALOG}" real_env bash -c 'source "'"${LLMCTL_ROOT}"'/lib/common.sh"; source "'"${LLMCTL_ROOT}"'/lib/catalog.sh"; catalog_files "'"${PROFILE}"'"')

MODEL_PATH="${REAL_MODELS_DIR}/${PROFILE}/${MODEL_NAME}"
if [[ -z "${MODEL_NAME}" || ! -f "${MODEL_PATH}" ]]; then
  assert_skip "profile '${PROFILE}' model not downloaded (${MODEL_PATH})" "GPU VRAM-delta measurement"
  { echo "SKIPPED: model not downloaded for profile ${PROFILE}: ${MODEL_PATH}"; } > "${EVIDENCE}"
  test_finish
fi

# Resolve the REAL catalog-planned ngl for this host+profile (never a
# hardcoded guess - research.md R4: the planner already computes full
# offload (ngl=99 by catalog default) vs ngl=0 based on real detected
# VRAM; this reuses that existing planning pipeline unmodified).
PLANNED_NGL="$(cd "${LLMCTL_ROOT}" && real_env bash -c '
  source lib/common.sh; source lib/os_detect.sh; source lib/hardware.sh; source lib/catalog.sh
  hw_probe_json | catalog_plan_json
' | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['profiles']['${PROFILE}']['ngl'])")"

TEST_PORT="${LLMCTL_TEST_GPU_PORT:-18095}"
SERVER_LOG="${TEST_TMP}/vram-delta-server.log"
SERVER_DIR="$(cd "$(dirname "${SERVER_BIN}")" && pwd)"

SERVER_PID=""
cleanup() {
  if [[ -n "${SERVER_PID}" ]]; then
    kill "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# --- BEFORE: idle GPU memory, captured before the server process exists ----
BEFORE_MIB="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)"

LD_LIBRARY_PATH="${SERVER_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
  "${SERVER_BIN}" --model "${MODEL_PATH}" --ctx-size 2048 \
    --n-gpu-layers "${PLANNED_NGL}" --host 127.0.0.1 --port "${TEST_PORT}" \
    > "${SERVER_LOG}" 2>&1 &
SERVER_PID=$!

ready=0
for (( i=0; i<180; i++ )); do
  if curl -fsS "http://127.0.0.1:${TEST_PORT}/health" >/dev/null 2>&1; then
    ready=1; break
  fi
  kill -0 "${SERVER_PID}" 2>/dev/null || break
  sleep 1
done

if [[ "${ready}" != "1" ]]; then
  echo "server did not become healthy; log:" >&2
  cat "${SERVER_LOG}" >&2
  printf 'FAIL: llama-server (profile=%s, ngl=%s) did not become healthy within 180s\n' "${PROFILE}" "${PLANNED_NGL}"
  TEST_FAILS=$((TEST_FAILS+1))
  test_finish
fi

# --- DURING: fire a real completion request that takes a few seconds to
# generate, and sample nvidia-smi WHILE it is in flight (spec.md
# Acceptance Scenario 2: "while an inference request is in flight"). -------
PAYLOAD='{"messages":[{"role":"user","content":"Write a short paragraph (at least 80 words) describing how photosynthesis works."}],"max_tokens":200,"temperature":0}'
RESPONSE_FILE="${TEST_TMP}/vram-delta-response.json"
curl -fsS -X POST "http://127.0.0.1:${TEST_PORT}/v1/chat/completions" \
  -H 'Content-Type: application/json' -d "${PAYLOAD}" > "${RESPONSE_FILE}" 2>"${TEST_TMP}/curl.err" &
CURL_PID=$!

# Sample memory.used a few times while the completion request is running.
DURING_MIB=0
for (( i=0; i<20; i++ )); do
  kill -0 "${CURL_PID}" 2>/dev/null || break
  sample="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)"
  (( sample > DURING_MIB )) && DURING_MIB="${sample}"
  sleep 0.3
done
wait "${CURL_PID}" 2>/dev/null || true

# One more sample right after (model stays resident regardless of request
# completion; catches the case where generation finished before our
# polling loop above sampled anything meaningful).
AFTER_IDLE_MIB="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)"
AFTER_MIB="${DURING_MIB}"
(( AFTER_IDLE_MIB > AFTER_MIB )) && AFTER_MIB="${AFTER_IDLE_MIB}"

kill "${SERVER_PID}" 2>/dev/null || true
wait "${SERVER_PID}" 2>/dev/null || true
SERVER_PID=""

DELTA=$(( AFTER_MIB - BEFORE_MIB ))

content="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d["choices"][0]["message"].get("content") or "")
except Exception:
    print("")
' "${RESPONSE_FILE}" 2>/dev/null || true)"

{
  echo "profile: ${PROFILE}"
  echo "model: ${MODEL_PATH}"
  echo "planned ngl (from hw_probe_json | catalog_plan_json): ${PLANNED_NGL}"
  echo "nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits"
  echo "before (idle, no server running):  ${BEFORE_MIB} MiB"
  echo "after (during/just-after a real inference request): ${AFTER_MIB} MiB"
  echo "delta: ${DELTA} MiB"
  echo "SC-002 threshold: >= 500 MiB"
  echo "completion content (truncated): ${content:0:200}"
} | tee "${EVIDENCE}"

assert_eq "1" "$(( DELTA >= 500 ? 1 : 0 ))" \
  "VRAM delta (${DELTA} MiB) is >= 500 MiB (SC-002) for profile ${PROFILE} at ngl=${PLANNED_NGL}"

if [[ -n "${content}" ]]; then
  printf '  ok: %s\n' "real completion response has non-empty content while VRAM was sampled"
else
  printf '  FAIL: %s\n' "real completion response had empty content"
  TEST_FAILS=$((TEST_FAILS+1))
fi

test_finish
