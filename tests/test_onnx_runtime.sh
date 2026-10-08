#!/usr/bin/env bash
# test_onnx_runtime.sh - the INTERNAL encoder scoring runtime (lib/onnx_server.py)
# through its REAL loopback HTTP surface: POST /v1/score, /healthz, /readyz.
# Contract: specs/009-jev-decision-models/contracts/encoder-runtime.md.
# Only the model BACKENDS (onnxruntime / sentencepiece / tokenizers) are stub
# modules injected via PYTHONPATH (tests/fixtures/onnx_stubs); the runtime code,
# its sockets, auth, truncation and label handling are the real ones. There is
# no environment test seam in production code.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

RUNNER="${LLMCTL_ROOT}/lib/onnx_server.py"
STUBS="${LLMCTL_ROOT}/tests/fixtures/onnx_stubs"
rm -f "${LLMCTL_ROOT}"/lib/__pycache__/onnx_server*.pyc 2>/dev/null || true
KEY="rt-key-$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [[ -n "${p}" ]] && kill "${p}" 2>/dev/null || true; done; test_teardown_env; }
trap cleanup EXIT

if ! python3 -c 'import numpy' 2>/dev/null; then
  assert_skip "numpy is not installed here; the runtime imports it for onnxruntime input arrays and the stub backends need it" \
    "onnx runtime contract tests (run \`llmctl build onnx\` or install numpy)"
  test_finish
  exit 0
fi

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

printf '%s\n' "${KEY}" > "${TEST_TMP}/key"; chmod 600 "${TEST_TMP}/key"

# mkmodel <dir> <json-spec> [tokenizer-file] - writes the stub model spec + tokenizer
mkmodel() {
  mkdir -p "$(dirname "$1")"
  printf '%s' "$2" > "$1"
}
mkcfg() { # <path> <id0> <id1> <id2>
  python3 - "$@" <<'PY'
import json, sys
p, *labels = sys.argv[1:]
json.dump({"id2label": {str(i): l for i, l in enumerate(labels)}}, open(p, "w"))
PY
}

declare -A PORT REC
# start <name> <model_dir> [env KEY=VAL ...] -- [runner args ...]
start() {
  local name="$1" dir="$2"; shift 2
  local -a envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift
  PORT[${name}]="$(free_port)"
  env "${envs[@]}" PYTHONPATH="${STUBS}" PYTHONDONTWRITEBYTECODE=1 \
    python3 -B "${RUNNER}" --model-dir "${dir}" --port "${PORT[${name}]}" \
    --profile toy-onnx --api-key-file "${TEST_TMP}/key" "$@" \
    >"${TEST_TMP}/server-${name}.log" 2>&1 &
  PIDS+=("$!")
  local ok=1
  for _ in $(seq 1 80); do
    curl -fsS "http://127.0.0.1:${PORT[${name}]}/healthz" >/dev/null 2>&1 && { ok=0; break; }
    kill -0 "$!" 2>/dev/null || break
    sleep 0.1
  done
  assert_eq 0 "${ok}" "server ${name}: /healthz becomes 200"
}

NLI3='"order":["entailment","neutral","contradiction"]'
M="${TEST_TMP}/m"

# A: canonical order, 2-input graph, feeds recorded
REC[A]="${TEST_TMP}/rec-A.jsonl"
mkmodel "${M}/A/model.onnx" "{\"inputs\":[\"input_ids\",\"attention_mask\"],${NLI3},\"record\":\"${REC[A]}\"}"
mkcfg "${M}/A/config.json" entailment neutral contradiction
echo spm > "${M}/A/spm.model"
start A "${M}/A"
# B: permuted label order
mkmodel "${M}/B/model.onnx" '{"order":["contradiction","neutral","entailment"]}'
mkcfg "${M}/B/config.json" contradiction neutral entailment
echo spm > "${M}/B/spm.model"
start B "${M}/B"
# C: model in onnx/, both configs present, DIFFERENT orders -> the one beside the model wins
mkmodel "${M}/C/onnx/model.onnx" "{${NLI3}}"
mkcfg "${M}/C/onnx/config.json" entailment neutral contradiction
mkcfg "${M}/C/config.json" contradiction neutral entailment
echo spm > "${M}/C/onnx/spm.model"
start C "${M}/C"
# D: generic LABEL_n names
mkmodel "${M}/D/model.onnx" "{${NLI3}}"
mkcfg "${M}/D/config.json" LABEL_0 LABEL_1 LABEL_2
echo spm > "${M}/D/spm.model"
start D "${M}/D"
# E: no config.json at all
mkmodel "${M}/E/model.onnx" "{${NLI3}}"
echo spm > "${M}/E/spm.model"
start E "${M}/E"
# F: spm, max-tokens 16, graph WANTS token_type_ids
REC[F]="${TEST_TMP}/rec-F.jsonl"
mkmodel "${M}/F/model.onnx" "{\"inputs\":[\"input_ids\",\"attention_mask\",\"token_type_ids\"],${NLI3},\"record\":\"${REC[F]}\"}"
mkcfg "${M}/F/config.json" entailment neutral contradiction
echo spm > "${M}/F/spm.model"
start F "${M}/F" -- --max-tokens 16
# G: tokenizer.json path
mkmodel "${M}/G/model.onnx" "{${NLI3}}"
mkcfg "${M}/G/config.json" entailment neutral contradiction
echo '{}' > "${M}/G/tokenizer.json"
start G "${M}/G" -- --tokenizer tokenizer.json --max-tokens 16
# H: NaN logits after the load-time smoke
mkmodel "${M}/H/model.onnx" "{\"mode\":\"nan_after_first\",${NLI3}}"
mkcfg "${M}/H/config.json" entailment neutral contradiction
echo spm > "${M}/H/spm.model"
start H "${M}/H"
# I: backend raises at load -> not_ready ; J: wrong logits count at load -> not_ready
mkmodel "${M}/I/model.onnx" '{"mode":"raise"}'
echo spm > "${M}/I/spm.model"
start I "${M}/I"
mkmodel "${M}/J/model.onnx" '{"mode":"two"}'
mkcfg "${M}/J/config.json" entailment neutral contradiction
echo spm > "${M}/J/spm.model"
start J "${M}/J"
# K: limits via env; K2: logits-count mismatch after ready; R: backend raises after ready
mkmodel "${M}/K/model.onnx" "{${NLI3}}"
echo spm > "${M}/K/spm.model"
start K "${M}/K" LLMCTL_ONNX_MAX_PAIRS=3 LLMCTL_ONNX_MAX_BODY_BYTES=2048 LLMCTL_ONNX_SOCKET_TIMEOUT=1
mkmodel "${M}/K2/model.onnx" "{\"mode\":\"two_after_first\",${NLI3}}"
mkcfg "${M}/K2/config.json" entailment neutral contradiction
echo spm > "${M}/K2/spm.model"
start K2 "${M}/K2"
mkmodel "${M}/R/model.onnx" "{\"mode\":\"raise_after_first\",${NLI3}}"
mkcfg "${M}/R/config.json" entailment neutral contradiction
echo spm > "${M}/R/spm.model"
start R "${M}/R"
# L: ctx from LLMCTL_CTX_<PROFILE>
mkmodel "${M}/L/model.onnx" "{${NLI3}}"
echo spm > "${M}/L/spm.model"
start L "${M}/L" LLMCTL_CTX_TOY_ONNX=24

# Ports/paths for the python contract driver (A's env carries a bogus key to prove it is ignored)
python3 - "${TEST_TMP}/ports.json" "${KEY}" "${REC[A]}" "${REC[F]}" \
  A "${PORT[A]}" B "${PORT[B]}" C "${PORT[C]}" D "${PORT[D]}" E "${PORT[E]}" F "${PORT[F]}" \
  G "${PORT[G]}" H "${PORT[H]}" I "${PORT[I]}" J "${PORT[J]}" K "${PORT[K]}" K2 "${PORT[K2]}" \
  R "${PORT[R]}" L "${PORT[L]}" <<'PY'
import json, sys
out, key, ra, rf, *kv = sys.argv[1:]
ports = {kv[i]: int(kv[i + 1]) for i in range(0, len(kv), 2)}
json.dump({"ports": ports, "key": key, "rec": {"A": ra, "F": rf}}, open(out, "w"))
PY
out="$(PYTHONDONTWRITEBYTECODE=1 LLMCTL_DECIDE_API_KEY=envkey-from-environment python3 -B \
  "${LLMCTL_ROOT}/tests/fixtures/onnx_rt_contract.py" "${TEST_TMP}/ports.json" 2>&1)" && rc=0 || rc=$?
printf '%s\n' "${out}"
fails="$(printf '%s\n' "${out}" | grep -c '^  FAIL:' || true)"
assert_eq 0 "${rc}" "contract driver exit status"
assert_eq 0 "${fails}" "contract driver reported no FAIL lines"
if [[ "${rc}" == "0" && "${fails}" == "0" ]]; then
  assert_eq 1 "$(printf '%s\n' "${out}" | grep -c '^  ok:' | awk '$1>=60{print 1; exit} {print 0}')" \
    "contract driver actually executed >= 60 checks (guards against a silently empty driver)"
fi

# --- process-level properties ---------------------------------------------------
pid_a="${PIDS[0]}"
if [[ -r "/proc/${pid_a}/cmdline" ]]; then
  assert_eq 0 "$(tr '\0' ' ' < "/proc/${pid_a}/cmdline" | grep -c -- "${KEY}" || true)" \
    "key is NOT in /proc/<pid>/cmdline (only --api-key-file path is) (D-03)"
  assert_eq 0 "$(tr '\0' '\n' < "/proc/${pid_a}/environ" 2>/dev/null | grep -c -- "${KEY}" || true)" \
    "key is NOT in the runtime's environment either"
  hexport="$(printf '%04X' "${PORT[A]}")"
  assert_eq 1 "$(awk -v h="0100007F:${hexport}" '$2==h && $4=="0A"{n++} END{print n+0}' /proc/net/tcp)" \
    "listening socket is bound to 127.0.0.1 only (/proc/net/tcp)"
  assert_eq 0 "$(awk -v p=":${hexport}" '$2 ~ p"$" && $4=="0A" && $2 !~ /^0100007F/{n++} END{print n+0}' /proc/net/tcp /proc/net/tcp6 2>/dev/null)" \
    "no listener on 0.0.0.0/:: for the runtime port"
else
  assert_skip "/proc is not available (non-Linux host)" "process-level key/bind checks"
fi

# request text never reaches the logs
req_text="UNIQUE-PREMISE-TOKEN-$$"
curl -fsS -X POST "http://127.0.0.1:${PORT[A]}/v1/score" -H "Authorization: Bearer ${KEY}" \
  -H 'Content-Type: application/json' -d "{\"pairs\":[{\"premise\":\"${req_text}\",\"hypothesis\":\"h\"}]}" >/dev/null
sleep 0.2
assert_eq 0 "$(grep -c -- "${req_text}" "${TEST_TMP}/server-A.log" || true)" "request text (premise) is never logged"
assert_file_contains "${TEST_TMP}/server-A.log" '"event": "smoke"' "startup: load-time smoke inference logged"
assert_file_contains "${TEST_TMP}/server-A.log" '"event": "listening"' "startup: listening event logged to stdout"
assert_file_contains "${TEST_TMP}/server-I.log" '"ok": false' "not-ready runtime logs the failed smoke"

# no bytecode litter, no test seams in production code
assert_eq 0 "$(find "${LLMCTL_ROOT}/lib" -name 'onnx_server*.pyc' | grep -c . || true)" \
  "no onnx_server .pyc created under lib/ by running the runtime (D-25)"
assert_eq 0 "$(grep -c 'LLMCTL_ONNX_FAKE\|BACKEND_HOST\|BACKEND_PORT' "${RUNNER}" || true)" \
  "production runtime carries no LLMCTL_ONNX_FAKE / BACKEND_* test seam"
assert_eq 0 "$(grep -c 'systemone\|"noul"\|criteria' "${RUNNER}" || true)" \
  "runtime holds no typed-question logic (that lives in the Go gateway)"

# --- constant-time key comparison (in-process spy on the REAL handler) ---------
spy="$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="${STUBS}" python3 -B - "${RUNNER}" <<'PY'
import hmac, http.client, importlib.util, sys, threading, types
spec = importlib.util.spec_from_file_location("onnx_rt", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
calls = []
orig = hmac.compare_digest
hmac.compare_digest = lambda a, b: (calls.append(1), orig(a, b))[1]
st = types.SimpleNamespace(key=b"k", max_body=1024, max_pairs=4, ready=True, model="m",
                           sem=threading.BoundedSemaphore(1), scorer=None)
srv = mod.LoopbackServer(("127.0.0.1", 0), mod.make_handler(st))
threading.Thread(target=srv.serve_forever, daemon=True).start()
c = http.client.HTTPConnection("127.0.0.1", srv.server_address[1], timeout=5)
c.request("POST", "/v1/score", b"{}", {"Authorization": "Bearer wrong", "Content-Length": "2"})
status = c.getresponse().status
srv.shutdown()
print(status, len(calls))
PY
)"
assert_eq "401" "${spy%% *}" "constant-time check: wrong key rejected (401)"
assert_eq "True" "$([[ "${spy##* }" -ge 1 ]] && echo True || echo False)" "constant-time check: hmac.compare_digest was used for the key (D-23)"

test_finish
