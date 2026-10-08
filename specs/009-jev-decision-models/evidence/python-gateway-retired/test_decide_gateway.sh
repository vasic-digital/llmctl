#!/usr/bin/env bash
# test_decide_gateway.sh - HTTP gateway (lib/decide_gateway.py + decide_serve):
# POST /v1/systemone with a TypeSafe-SDK-shaped body, /v1/models aliases,
# /healthz, Bearer auth (401), head+tail state truncation header, and the
# decide serve / --stop pidfile lifecycle. The backend is the deterministic
# tests/fixtures/decide_server.py stub (the real HTTP/JSON parse path
# executes; only the model is stubbed). Both servers run on ephemeral ports.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/os_detect.sh"
source "${LLMCTL_ROOT}/lib/hardware.sh"
source "${LLMCTL_ROOT}/lib/catalog.sh"
source "${LLMCTL_ROOT}/lib/decide.sh"
source "${LLMCTL_ROOT}/lib/scheduler.sh"

GATEWAY="${LLMCTL_ROOT}/lib/decide_gateway.py"

free_port() {
  python3 -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
'
}

BACKEND_PORT="$(free_port)"
GW_PORT="$(free_port)"
GW_AUTH_PORT="$(free_port)"
GW_TRUNC_PORT="$(free_port)"
SERVE_PORT="$(free_port)"

python3 "${LLMCTL_ROOT}/tests/fixtures/decide_server.py" "${BACKEND_PORT}" >/dev/null 2>&1 &
BACKEND_PID=$!
python3 "${GATEWAY}" --port "${GW_PORT}" --backend-port "${BACKEND_PORT}" \
  --profile decide >/dev/null 2>&1 &
GW_PID=$!
python3 "${GATEWAY}" --port "${GW_AUTH_PORT}" --backend-port "${BACKEND_PORT}" \
  --profile decide --api-key "test-secret-key" >/dev/null 2>&1 &
GW_AUTH_PID=$!
python3 "${GATEWAY}" --port "${GW_TRUNC_PORT}" --backend-port "${BACKEND_PORT}" \
  --profile decide --max-state-chars 64 >/dev/null 2>&1 &
GW_TRUNC_PID=$!

cleanup() {
  kill ${BACKEND_PID} ${GW_PID} ${GW_AUTH_PID} ${GW_TRUNC_PID} 2>/dev/null || true
  LLMCTL_DECIDE_BACKEND_PORT="${BACKEND_PORT}" decide_serve --stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

# wait_for /healthz on all gateways (backend /health up -> 200).
for port in "${GW_PORT}" "${GW_AUTH_PORT}" "${GW_TRUNC_PORT}"; do
  ok=1
  for _ in $(seq 1 50); do
    if curl -fsS "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; then ok=0; break; fi
    sleep 0.1
  done
  assert_eq 0 "${ok}" "gateway on port ${port}: /healthz becomes 200"
done

# --- 1. POST /v1/systemone, TypeSafe-SDK-shaped body -------------------------
# Recorded SDK request shape: {model, state, questions: {name: {type,
# instructions, criteria}}}. Question NAMES (team) never reach the model.
BODY='{
  "model": "jev-latest",
  "state": "Routing.",
  "questions": {
    "team": {"type": "choice", "instructions": "Which team handles invoices?",
             "criteria": {"billing": "handles invoices", "legal": "contracts"}}
  }
}'
resp="$(curl -fsS -X POST "http://127.0.0.1:${GW_PORT}/v1/systemone" \
  -H 'Content-Type: application/json' -d "${BODY}")"
assert_eq "billing" "$(printf '%s' "${resp}" | json_stdin 'd["answers"]["team"]["choice"]')" \
  "systemone: answers.team.choice is billing"
assert_eq "True" "$(printf '%s' "${resp}" | json_stdin 'set(d["answers"]["team"]["probabilities"].keys()) == {"billing", "legal"}')" \
  "systemone: probabilities keyed by criteria keys"
assert_contains "${resp}" '"confidence"' "systemone: confidence present"
assert_eq "jev-latest" "$(printf '%s' "${resp}" | json_stdin 'd["model"]')" "systemone: model echoes the requested alias"
assert_eq "True" "$(printf '%s' "${resp}" | json_stdin 'd["usage"]["input_tokens"] > 0 and d["usage"]["output_tokens"] == 1')" \
  "systemone: usage present (estimated input_tokens > 0, 1 output token/question)"

# --- 2. noul + score questions in the same request ---------------------------
BODY2='{
  "model": "jev-latest",
  "state": "Arithmetic facts and outcomes.",
  "questions": {
    "arith": {"type": "noul", "instructions": "Is 2+2=4?"},
    "quality": {"type": "score", "instructions": "Rate the quality of this outcome.",
                "criteria": ["bad outcome", "mixed outcome", "excellent outcome"]}
  }
}'
resp2="$(curl -fsS -X POST "http://127.0.0.1:${GW_PORT}/v1/systemone" \
  -H 'Content-Type: application/json' -d "${BODY2}")"
assert_eq "noul" "$(printf '%s' "${resp2}" | json_stdin 'd["answers"]["arith"]["type"]')" \
  "systemone: noul question typed answer"
assert_eq "True" "$(printf '%s' "${resp2}" | json_stdin 'd["answers"]["arith"]["noul"] > 0.5')" \
  "systemone: noul value > 0.5 on the 2+2=4 fixture distribution"
assert_eq "True" "$(printf '%s' "${resp2}" | json_stdin 'd["answers"]["quality"]["score"] >= 1.0')" \
  "systemone: score weighted expectation >= 1.0 on the top-level-heavy distribution"
assert_eq "excellent outcome" "$(printf '%s' "${resp2}" | json_stdin 'd["answers"]["quality"]["legend"]["2"]')" \
  "systemone: score legend present"
assert_eq "2" "$(printf '%s' "${resp2}" | json_stdin 'd["usage"]["output_tokens"]')" \
  "systemone: usage.output_tokens == number of questions"

# --- 3. GET /v1/models aliases -----------------------------------------------
models="$(curl -fsS "http://127.0.0.1:${GW_PORT}/v1/models")"
assert_contains "${models}" '"jev-latest"' "/v1/models: jev-latest alias present"
assert_contains "${models}" '"jev-preview"' "/v1/models: jev-preview alias present"
assert_contains "${models}" '"llmctl-decide"' "/v1/models: llmctl-<profile> alias present"

# --- 4. Bearer auth: wrong/absent key -> 401, right key -> 200 ----------------
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "http://127.0.0.1:${GW_AUTH_PORT}/v1/systemone" \
  -H 'Content-Type: application/json' -d "${BODY}")"
assert_eq "401" "${code}" "auth gateway: absent Bearer -> 401"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "http://127.0.0.1:${GW_AUTH_PORT}/v1/systemone" \
  -H 'Authorization: Bearer wrong-key' -H 'Content-Type: application/json' -d "${BODY}")"
assert_eq "401" "${code}" "auth gateway: wrong Bearer -> 401"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "http://127.0.0.1:${GW_AUTH_PORT}/v1/systemone" \
  -H 'Authorization: Bearer test-secret-key' -H 'Content-Type: application/json' -d "${BODY}")"
assert_eq "200" "${code}" "auth gateway: correct Bearer -> 200"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${GW_AUTH_PORT}/v1/models")"
assert_eq "401" "${code}" "auth gateway: /v1/models also requires the key"
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${GW_AUTH_PORT}/healthz")"
assert_eq "200" "${code}" "auth gateway: /healthz stays open for probes"

# --- 5. oversized state -> head+tail truncation header -------------------------
big_state="$(python3 -c 'print("head-" + "x" * 500 + "-tail")')"
trunc_body="$(python3 -c '
import json, sys
print(json.dumps({"model": "jev-latest", "state": sys.argv[1],
                  "questions": {"team": {"type": "choice",
                  "instructions": "Which team handles invoices?",
                  "criteria": {"billing": "handles invoices", "legal": "contracts"}}}}))
' "${big_state}")"
hdrs="$(curl -fsS -D - -o /dev/null -X POST \
  "http://127.0.0.1:${GW_TRUNC_PORT}/v1/systemone" \
  -H 'Content-Type: application/json' -d "${trunc_body}")"
assert_contains "${hdrs}" "x-llmctl-decide-truncated: true" "truncating gateway: header set on oversized state"
# Same body against the uncapped gateway -> no truncation header.
hdrs2="$(curl -fsS -D - -o /dev/null -X POST \
  "http://127.0.0.1:${GW_PORT}/v1/systemone" \
  -H 'Content-Type: application/json' -d "${trunc_body}")"
if [[ "${hdrs2}" == *"x-llmctl-decide-truncated"* ]]; then th=1; else th=0; fi
assert_eq 0 "${th}" "uncapped gateway: no truncation header on the same body"

# --- 6. decide serve / --stop lifecycle (backend test seam) -------------------
export LLMCTL_DECIDE_BACKEND_PORT="${BACKEND_PORT}"
serve_out="$(decide_serve --profile decide --port "${SERVE_PORT}" 2>&1)" && rc=0 || rc=$?
[[ "${rc}" -eq 0 ]] || printf '%s\n' "${serve_out}" >&2   # show why serve failed
assert_eq 0 "${rc}" "decide serve (daemonized) -> rc 0"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/decide-gateway.pid" "decide serve: pidfile written"
serve_pid="$(cat "${LLMCTL_RUNTIME_DIR}/decide-gateway.pid")"
kill -0 "${serve_pid}" 2>/dev/null && alive=0 || alive=1
assert_eq 0 "${alive}" "decide serve: gateway process alive"
ok=1
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:${SERVE_PORT}/healthz" >/dev/null 2>&1; then ok=0; break; fi
  sleep 0.1
done
assert_eq 0 "${ok}" "decide serve: gateway answers /healthz"
resp3="$(curl -fsS -X POST "http://127.0.0.1:${SERVE_PORT}/v1/systemone" \
  -H 'Content-Type: application/json' -d "${BODY}")"
assert_eq "billing" "$(printf '%s' "${resp3}" | json_stdin 'd["answers"]["team"]["choice"]')" \
  "decide serve: systemone works through the served gateway"
decide_serve --stop >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 0 "${rc}" "decide serve --stop -> rc 0"
kill -0 "${serve_pid}" 2>/dev/null && alive=0 || alive=1
assert_eq 1 "${alive}" "decide serve --stop: process gone"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/decide-gateway.pid" "decide serve --stop: pidfile removed"
# Second --stop on a missing pidfile -> rc 1 with a clear message (idempotence
# is reported, not silently faked).
out="$(decide_serve --stop 2>&1)" && rc=0 || rc=$?
assert_eq 1 "${rc}" "decide serve --stop when not running -> rc 1"
assert_contains "${out}" "no gateway pidfile" "decide serve --stop when not running -> message"
# Dry-run seam: no process, no pidfile, prints the launch line.
out="$(LLMCTL_DRY_RUN=1 decide_serve --profile decide --port "${SERVE_PORT}" 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "decide serve with LLMCTL_DRY_RUN=1 -> rc 0"
assert_contains "${out}" "DRY-RUN: python3" "decide serve dry-run: launch line printed"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/decide-gateway.pid" "decide serve dry-run: no pidfile"

# --- 7. gateway in --backend-engine onnx mode (single-hop proxy) ---------------
# The onnx backend (tests/fixtures/onnx_decide_server.py stub) already
# speaks /v1/systemone natively; the gateway must proxy the validated,
# truncated body through and return the upstream response verbatim.
ONNX_BE_PORT="$(free_port)"
GW_ONNX_PORT="$(free_port)"
python3 "${LLMCTL_ROOT}/tests/fixtures/onnx_decide_server.py" "${ONNX_BE_PORT}" >/dev/null 2>&1 &
ONNX_BE_PID=$!
python3 "${GATEWAY}" --port "${GW_ONNX_PORT}" --backend-port "${ONNX_BE_PORT}" \
  --profile decide-nli --backend-engine onnx >/dev/null 2>&1 &
GW_ONNX_PID=$!
trap 'kill ${BACKEND_PID} ${GW_PID} ${GW_AUTH_PID} ${GW_TRUNC_PID} ${ONNX_BE_PID} ${GW_ONNX_PID} 2>/dev/null || true; LLMCTL_DECIDE_BACKEND_PORT="${BACKEND_PORT}" decide_serve --stop >/dev/null 2>&1 || true' EXIT

ok=1
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:${GW_ONNX_PORT}/healthz" >/dev/null 2>&1; then ok=0; break; fi
  sleep 0.1
done
assert_eq 0 "${ok}" "onnx-mode gateway: /healthz becomes 200 (backend /health up)"

resp_o="$(curl -fsS -X POST "http://127.0.0.1:${GW_ONNX_PORT}/v1/systemone" \
  -H 'Content-Type: application/json' -d "${BODY}")"
assert_eq "billing" "$(printf '%s' "${resp_o}" | json_stdin 'd["answers"]["team"]["choice"]')" \
  "onnx-mode gateway: answers.team.choice is billing (proxied)"
assert_eq "jev-latest" "$(printf '%s' "${resp_o}" | json_stdin 'd["model"]')" \
  "onnx-mode gateway: model alias passes through to the backend"
assert_eq "42" "$(printf '%s' "${resp_o}" | json_stdin 'd["usage"]["input_tokens"]')" \
  "onnx-mode gateway: upstream usage block returned verbatim"
resp_o2="$(curl -fsS -X POST "http://127.0.0.1:${GW_ONNX_PORT}/v1/systemone" \
  -H 'Content-Type: application/json' -d "${BODY2}")"
assert_eq "True" "$(printf '%s' "${resp_o2}" | json_stdin 'd["answers"]["arith"]["noul"] > 0.5 and d["answers"]["quality"]["score"] >= 1.0')" \
  "onnx-mode gateway: noul + score questions in the same proxied request"
# Bad bodies are still rejected AT THE GATEWAY (validation happens pre-proxy).
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "http://127.0.0.1:${GW_ONNX_PORT}/v1/systemone" \
  -H 'Content-Type: application/json' -d '{"questions":{}}')"
assert_eq "400" "${code}" "onnx-mode gateway: missing state -> 400 at the gateway"

# decide_serve passes the profile's catalog engine to the gateway (dry-run
# seam: assert the launch line carries --backend-engine onnx).
unset LLMCTL_DECIDE_BACKEND_PORT
out="$(LLMCTL_DRY_RUN=1 LLMCTL_DECIDE_BACKEND_PORT="${ONNX_BE_PORT}" \
  decide_serve --profile decide-nli --port "${SERVE_PORT}" 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "decide serve decide-nli (dry-run) -> rc 0"
assert_contains "${out}" "--backend-engine onnx" "decide serve: onnx profiles pass --backend-engine onnx to the gateway"
out="$(LLMCTL_DRY_RUN=1 LLMCTL_DECIDE_BACKEND_PORT="${BACKEND_PORT}" \
  decide_serve --profile decide --port "${SERVE_PORT}" 2>&1)" && rc=0 || rc=$?
assert_contains "${out}" "--backend-engine llama" "decide serve: llama profiles pass --backend-engine llama"
export LLMCTL_DECIDE_BACKEND_PORT="${BACKEND_PORT}"

test_finish
