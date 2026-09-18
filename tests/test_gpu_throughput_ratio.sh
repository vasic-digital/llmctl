#!/usr/bin/env bash
# test_gpu_throughput_ratio.sh - 005-cuda-gpu-inference T009/T010
# (spec.md Acceptance Scenario 3, SC-003): runs the SAME cataloged
# profile + prompt once forced to `--n-gpu-layers 0` (CPU-only) and once
# at the real catalog-planned `ngl` (GPU offload), measures REAL
# wall-clock time to a real chat-completion response and derives REAL
# tokens/sec from the response's own `usage.completion_tokens` field
# (reusing lib/download.sh's `_dl_smoke_test_gguf()` real-completion
# parsing pattern - message.content + finish_reason, per the task
# brief), and asserts the GPU run's tok/s is at least 2x the CPU run's
# tok/s (SC-003).
#
# Real requirements, no mocking (Constitution Principle IV / §11.4.27):
# real llama-server subprocesses, real HTTP completion requests, real
# wall-clock timing, real token counts from the engine's own usage field.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/os_detect.sh"
source "${LLMCTL_ROOT}/lib/hardware.sh"
source "${LLMCTL_ROOT}/lib/catalog.sh"

PROFILE="${LLMCTL_TEST_GPU_PROFILE:-small}"
QA_DIR="${LLMCTL_ROOT}/docs/qa/005-cuda-gpu-inference"
mkdir -p "${QA_DIR}"
EVIDENCE="${QA_DIR}/throughput_ratio.txt"

if ! have_cmd nvidia-smi; then
  assert_skip "nvidia-smi not present on this host" "GPU throughput-ratio measurement"
  { echo "SKIPPED: nvidia-smi not present on this host"; } > "${EVIDENCE}"
  test_finish
fi

# LLMCTL_TEST_SERVER_BIN: override the llama-server binary under test.
# Used by this feature's own T009 RED-first verification to point at a
# deliberately CPU-only build (built into a separate directory, never
# touching the real submodules/llama.cpp/build the rest of this project
# depends on) to prove this test genuinely fails (ratio ~1x) when there
# is no real GPU backend - never asserted, always actually run.
SERVER_BIN="${LLMCTL_TEST_SERVER_BIN:-${LLMCTL_ROOT}/submodules/llama.cpp/build/bin/llama-server}"
if [[ ! -x "${SERVER_BIN}" ]]; then
  assert_skip "llama-server not built (${SERVER_BIN} missing)" "GPU throughput-ratio measurement"
  { echo "SKIPPED: llama-server not built at ${SERVER_BIN}"; } > "${EVIDENCE}"
  test_finish
fi

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
  assert_skip "profile '${PROFILE}' model not downloaded (${MODEL_PATH})" "GPU throughput-ratio measurement"
  { echo "SKIPPED: model not downloaded for profile ${PROFILE}: ${MODEL_PATH}"; } > "${EVIDENCE}"
  test_finish
fi

PLANNED_NGL="$(cd "${LLMCTL_ROOT}" && real_env bash -c '
  source lib/common.sh; source lib/os_detect.sh; source lib/hardware.sh; source lib/catalog.sh
  hw_probe_json | catalog_plan_json
' | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['profiles']['${PROFILE}']['ngl'])")"

SERVER_DIR="$(cd "$(dirname "${SERVER_BIN}")" && pwd)"
PROMPT_PAYLOAD='{"messages":[{"role":"user","content":"Write a short paragraph (at least 100 words) explaining how photosynthesis works."}],"max_tokens":220,"temperature":0}'

SERVER_PID=""
cleanup() {
  if [[ -n "${SERVER_PID}" ]]; then
    kill "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# run_completion <ngl> <port> <label> - starts llama-server with the given
# --n-gpu-layers value, waits for /health, fires the SAME real completion
# request, measures real wall-clock elapsed time, parses the real
# response, and returns (via globals) tok/s + content + finish_reason.
RUN_TOKS=0
RUN_ELAPSED="0"
RUN_TOKPS="0"
RUN_CONTENT=""
RUN_FINISH=""
run_completion() {
  local ngl="$1" port="$2" label="$3"
  local server_log="${TEST_TMP}/throughput-${label}-server.log"
  local response_file="${TEST_TMP}/throughput-${label}-response.json"

  LD_LIBRARY_PATH="${SERVER_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    "${SERVER_BIN}" --model "${MODEL_PATH}" --ctx-size 2048 \
      --n-gpu-layers "${ngl}" --host 127.0.0.1 --port "${port}" \
      > "${server_log}" 2>&1 &
  SERVER_PID=$!

  local ready=0 i
  for (( i=0; i<180; i++ )); do
    if curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      ready=1; break
    fi
    kill -0 "${SERVER_PID}" 2>/dev/null || break
    sleep 1
  done
  if [[ "${ready}" != "1" ]]; then
    echo "server (${label}, ngl=${ngl}) did not become healthy; log:" >&2
    cat "${server_log}" >&2
    return 1
  fi

  local start end
  start="$(date +%s.%N)"
  if ! curl -fsS -X POST "http://127.0.0.1:${port}/v1/chat/completions" \
      -H 'Content-Type: application/json' -d "${PROMPT_PAYLOAD}" > "${response_file}" 2>"${TEST_TMP}/curl-${label}.err"; then
    echo "completion request (${label}) failed:" >&2
    cat "${TEST_TMP}/curl-${label}.err" >&2
    kill "${SERVER_PID}" 2>/dev/null || true; wait "${SERVER_PID}" 2>/dev/null || true
    SERVER_PID=""
    return 1
  fi
  end="$(date +%s.%N)"

  kill "${SERVER_PID}" 2>/dev/null || true
  wait "${SERVER_PID}" 2>/dev/null || true
  SERVER_PID=""

  RUN_ELAPSED="$(python3 -c "print(f'{${end} - ${start}:.4f}')")"
  RUN_TOKS="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get("usage", {}).get("completion_tokens") or 0)
except Exception:
    print(0)
' "${response_file}")"
  RUN_CONTENT="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d["choices"][0]["message"].get("content") or "")
except Exception:
    print("")
' "${response_file}")"
  RUN_FINISH="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d["choices"][0].get("finish_reason") or "")
except Exception:
    print("")
' "${response_file}")"
  RUN_TOKPS="$(python3 -c "print(f'{${RUN_TOKS} / ${RUN_ELAPSED}:.4f}')" 2>/dev/null || echo 0)"
}

# --- run 1: forced CPU-only (--n-gpu-layers 0), same model, same prompt ----
if ! run_completion 0 18096 cpu; then
  printf 'FAIL: %s\n' "CPU-forced (ngl=0) completion run failed to complete"
  TEST_FAILS=$((TEST_FAILS+1))
  test_finish
fi
CPU_TOKS="${RUN_TOKS}"; CPU_ELAPSED="${RUN_ELAPSED}"; CPU_TOKPS="${RUN_TOKPS}"
CPU_CONTENT="${RUN_CONTENT}"; CPU_FINISH="${RUN_FINISH}"

# --- run 2: real catalog-planned ngl (GPU offload), same model, same prompt -
if ! run_completion "${PLANNED_NGL}" 18097 gpu; then
  printf 'FAIL: %s\n' "GPU-planned (ngl=${PLANNED_NGL}) completion run failed to complete"
  TEST_FAILS=$((TEST_FAILS+1))
  test_finish
fi
GPU_TOKS="${RUN_TOKS}"; GPU_ELAPSED="${RUN_ELAPSED}"; GPU_TOKPS="${RUN_TOKPS}"
GPU_CONTENT="${RUN_CONTENT}"; GPU_FINISH="${RUN_FINISH}"

RATIO="$(python3 -c "print(f'{${GPU_TOKPS} / ${CPU_TOKPS}:.4f}')" 2>/dev/null || echo 0)"

{
  echo "profile: ${PROFILE}"
  echo "model: ${MODEL_PATH}"
  echo "prompt: ${PROMPT_PAYLOAD}"
  echo ""
  echo "CPU-forced run (--n-gpu-layers 0):"
  echo "  completion_tokens: ${CPU_TOKS}"
  echo "  wall-clock elapsed: ${CPU_ELAPSED}s"
  echo "  tok/s: ${CPU_TOKPS}"
  echo "  finish_reason: ${CPU_FINISH}"
  echo "  content (truncated): ${CPU_CONTENT:0:150}"
  echo ""
  echo "GPU-planned run (--n-gpu-layers ${PLANNED_NGL}, from hw_probe_json | catalog_plan_json):"
  echo "  completion_tokens: ${GPU_TOKS}"
  echo "  wall-clock elapsed: ${GPU_ELAPSED}s"
  echo "  tok/s: ${GPU_TOKPS}"
  echo "  finish_reason: ${GPU_FINISH}"
  echo "  content (truncated): ${GPU_CONTENT:0:150}"
  echo ""
  echo "ratio (GPU tok/s / CPU tok/s): ${RATIO}"
  echo "SC-003 threshold: >= 2.0x"
} | tee "${EVIDENCE}"

if [[ -z "${CPU_CONTENT}" ]]; then
  printf '  FAIL: %s\n' "CPU-forced run produced empty content"
  TEST_FAILS=$((TEST_FAILS+1))
else
  printf '  ok: %s\n' "CPU-forced run produced real, non-empty completion content"
fi
if [[ -z "${GPU_CONTENT}" ]]; then
  printf '  FAIL: %s\n' "GPU-planned run produced empty content"
  TEST_FAILS=$((TEST_FAILS+1))
else
  printf '  ok: %s\n' "GPU-planned run produced real, non-empty completion content"
fi

RATIO_OK="$(python3 -c "print(1 if ${RATIO} >= 2.0 else 0)" 2>/dev/null || echo 0)"
assert_eq "1" "${RATIO_OK}" \
  "GPU/CPU throughput ratio (${RATIO}x) is >= 2.0x (SC-003) for profile ${PROFILE}"

test_finish
