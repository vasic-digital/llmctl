#!/usr/bin/env bash
# run_live_nli.sh - the live matrix for the ENCODER profile decide-nli (ONNX DeBERTa-v3-large NLI), through the real stack:
#   internal runtime lib/onnx_server.py (hash-locked venv, loopback, key FILE)  <-  HTTPS gateway (llmctl decide serve)  <-  clients.
# Run on the host that has the model (REALCHECK ran it on nezha.local under ~/llmctl-work-realcheck/). It never prints a key.
# Needs: REPO (tree copy), W (work dir), the env exported below. Output dir OUT is sealed with MANIFEST.json + SHA256SUMS by the caller.
set -uo pipefail
# acquire_access_key <dest>: writes the gateway access key (only the key, one line) to <dest>, mode 0600,
# never to the terminal. Run from the repo root with the LLMCTL_* env of this script.
# (`key export` is the startup-file installer and prints no key: it left this file EMPTY - D-06 run 2026-10-08.)
acquire_access_key() {
  local rc
  rm -f "$1"
  ( umask 077; bin/llmctl decide key show --yes-print > "$1" 2>/dev/null ); rc=$?
  chmod 600 "$1" 2>/dev/null
  [[ "${rc}" -eq 0 && -s "$1" ]]
}
RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# wire_gateway_env <eng_port> <gw_port>: the Go gateway resolves a profile's engine address with precedence
# LLMCTL_DECIDE_ENDPOINT_<PROFILE> > LLMCTL_PORT_<PROFILE> > catalog port (internal/gateway/resolver.go). The explicit
# ENDPOINT is exported too (it wins, and is the unambiguous form); the CLI client finds a non-default gateway only via
# LLMCTL_DECIDE_PORT (live 2026-10-08: unset => every request 503 not_ready).
wire_gateway_env() {
  export LLMCTL_PORT_DECIDE_NLI="$1" LLMCTL_DECIDE_ENDPOINT_DECIDE_NLI="http://127.0.0.1:$1" LLMCTL_DECIDE_PORT="$2"
}
# preflight_gateway <profile> <models-file> <result-file>: the gateway must report the profile ready before the
# 173-request matrix; a miswired gateway then fails in seconds. rc 0 = ready, 1 = not (RESULT written).
preflight_gateway() {
  if awk -v p="$1" '$1==p && $2=="ready"{f=1} END{exit !f}' "$2" 2>/dev/null; then return 0; fi
  echo "FAILED-PREFLIGHT: gateway does not report $1 ready" > "$3"; return 1
}
# RUN_LIVE_NLI_LIB_ONLY=1: define the functions and stop (tests/test_run_live_nli.sh sources it).
if [[ "${RUN_LIVE_NLI_LIB_ONLY:-0}" == "1" ]]; then return 0 2>/dev/null || exit 0; fi
P=decide-nli
: "${REPO:?}" "${W:?}" "${OUT:?}" "${GW_PORT:?}" "${ENG_PORT:?}"
cd "${REPO}" || exit 1
export LLMCTL_DATA_DIR="${W}/data" LLMCTL_STATE_DIR="${W}/state" LLMCTL_HOME="${W}/home" LLMCTL_ENV_FILE="${W}/home/env"
export LLMCTL_DECIDE_BIN="${REPO}/build/llmctl-decide" LLMCTL_DECIDE_NATIVE=1
wire_gateway_env "${ENG_PORT}" "${GW_PORT}"
GW="https://127.0.0.1:${GW_PORT}"; CA="${LLMCTL_HOME}/cert/ca/ca.crt"
IKEY="${LLMCTL_STATE_DIR}/keys/onnx-${P}.key"
VPY="${LLMCTL_DATA_DIR}/venv-onnx/bin/python"
MDIR="${LLMCTL_DATA_DIR}/models/${P}"
mkdir -p "${OUT}"
say() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
PID=""
mem() { # <label>
  { echo "## $1 $(date -u +%T)"; grep -E 'VmRSS|VmHWM|VmSwap' "/proc/${PID}/status"; } >> "${OUT}/memory.txt"
}
cleanup() {
  bin/llmctl decide serve --stop > /dev/null 2>&1 || true
  [[ -f "${OUT}/engine.log" ]] && sed -i -E 's#(Bearer )[A-Za-z0-9._~+/=-]+#\1<redacted>#g' "${OUT}/engine.log"
  if [[ -n "${PID}" ]] && kill -0 "${PID}" 2>/dev/null && grep -q onnx_server.py "/proc/${PID}/cmdline" 2>/dev/null; then kill "${PID}"; fi
}
trap cleanup EXIT

{
  echo "profile=${P} date=$(date -u +%FT%TZ) host=$(hostname) kernel=$(uname -r)"
  echo "venv python: $(${VPY} --version 2>&1)  onnxruntime=$(${VPY} -c 'import onnxruntime as o;print(o.__version__)') numpy=$(${VPY} -c 'import numpy as n;print(n.__version__)') sentencepiece=$(${VPY} -c 'import sentencepiece as s;print(s.__version__)') tokenizers=$(${VPY} -c 'import tokenizers as t;print(t.__version__)')"
  echo "runtime sha256: $(sha256sum lib/onnx_server.py | cut -d' ' -f1)  lock sha256: $(sha256sum lib/lock/requirements-onnx.lock | cut -d' ' -f1)"
  echo "decide binary sha256: $(sha256sum build/llmctl-decide | cut -d' ' -f1)"
  echo "catalog entry: $(python3 -c 'import json,sys;p=json.load(open("models/catalog.json"))["profiles"][sys.argv[1]];print(p["hf_repo"],p["hf_revision"],[(f["name"],f["size"],f["sha256"]) for f in p["files"]],p["decision"])' "${P}")"
  echo "--- memory before"; free -m | sed -n 1,3p; nproc; df -h "${W}" | tail -1
  echo "--- plan row"; bin/llmctl plan --json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(json.dumps({"budgets":d["budgets"],"profile":d["profiles"][sys.argv[1]]},indent=1))' "${P}"
} > "${OUT}/context.txt" 2>&1

say "verify"
bin/llmctl models verify "${P}" > "${OUT}/verify.txt" 2>&1; echo "rc=$?" >> "${OUT}/verify.txt"

# ---- internal runtime: the exact argv lib/scheduler.sh builds for the onnx arm (key file created by the scheduler's own rule) ----
say "start runtime"
mkdir -p "$(dirname "${IKEY}")"; chmod 700 "$(dirname "${IKEY}")"
[[ -s "${IKEY}" ]] || { umask 077; "${VPY}" -c 'import secrets;print(secrets.token_hex(32))' > "${IKEY}"; }
chmod 600 "${IKEY}"
nice -n 10 env -u LD_LIBRARY_PATH PYTHONDONTWRITEBYTECODE=1 "${VPY}" "${REPO}/lib/onnx_server.py" --model-dir "${MDIR}" \
  --host 127.0.0.1 --port "${ENG_PORT}" --profile "${P}" --max-tokens 512 --api-key-file "${IKEY}" --tokenizer spm.model \
  > "${OUT}/engine.log" 2>&1 &
PID=$!
echo "argv: ${VPY} lib/onnx_server.py --model-dir <data>/models/${P} --host 127.0.0.1 --port ${ENG_PORT} --profile ${P} --max-tokens 512 --api-key-file <path> --tokenizer spm.model (pid ${PID})" > "${OUT}/engine-cmdline.txt"
t0=$(date +%s)
for _ in $(seq 1 240); do
  curl -fsS -m 2 "http://127.0.0.1:${ENG_PORT}/readyz" >/dev/null 2>&1 && break
  kill -0 "${PID}" 2>/dev/null || { echo "RUNTIME-EXITED" > "${OUT}/RESULT.txt"; exit 3; }
  sleep 1
done
echo "ready_after_s=$(( $(date +%s) - t0 )) healthz=$(curl -sS -m 3 http://127.0.0.1:${ENG_PORT}/healthz) readyz=$(curl -sS -m 3 http://127.0.0.1:${ENG_PORT}/readyz)" > "${OUT}/readiness.txt"
: > "${OUT}/memory.txt"; mem "after-start-idle"

# ---- gateway (own CA/leaf + access key under the scratch LLMCTL_HOME, first-start rule of the project) ----
say "gateway"
bin/llmctl decide serve --port "${GW_PORT}" > "${OUT}/gateway-start.txt" 2>&1; echo "rc=$?" >> "${OUT}/gateway-start.txt"
for _ in $(seq 1 30); do bin/llmctl decide models 2>/dev/null | awk -v p="${P}" '$1==p && $2=="ready"{f=1} END{exit !f}' && break; sleep 1; done
bin/llmctl decide models > "${OUT}/gateway-models.txt" 2>&1
preflight_gateway "${P}" "${OUT}/gateway-models.txt" "${OUT}/RESULT.txt" || exit 5
LIVE_KEYFILE="${W}/work/access.key"; mkdir -p "${W}/work"
acquire_access_key "${LIVE_KEYFILE}" || { echo "no access key could be exported" > "${OUT}/RESULT.txt"; exit 4; }

say "smoke + ask"
{ bin/llmctl decide smoke --url "http://127.0.0.1:${ENG_PORT}" --protocol nli-onnx --key-file "${IKEY}" --options 2 --json; echo "rc=$?"
  bin/llmctl decide smoke --url "http://127.0.0.1:${ENG_PORT}" --protocol nli-onnx --key-file "${IKEY}" --options 4 --json; echo "rc=$?"; } > "${OUT}/smoke.txt" 2>&1
mem "after-smoke"

say "golden"
nice -n 10 python3 scripts/golden/run_golden.py --base-url "${GW}" --cacert "${CA}" --key-file "${LIVE_KEYFILE}" --profile "${P}" \
  --permute-groups --run-id "${P}-golden" --out-dir "${OUT}/golden" > "${OUT}/golden.log" 2>&1; echo "rc=$?" >> "${OUT}/golden.log"
mem "after-golden-questions"
say "probes"
nice -n 10 python3 scripts/golden/run_golden.py --base-url "${GW}" --cacert "${CA}" --key-file "${LIVE_KEYFILE}" --profile "${P}" \
  --set probes --run-id "${P}-probes" --out-dir "${OUT}/probes" > "${OUT}/probes.log" 2>&1; echo "rc=$?" >> "${OUT}/probes.log"
[[ -f "${OUT}/golden/results.json" ]] && python3 scripts/golden/stats.py "${OUT}/golden/results.json" > "${OUT}/golden-stats.txt" 2>&1
[[ -f "${OUT}/probes/results.json" ]] && python3 scripts/golden/stats.py "${OUT}/probes/results.json" > "${OUT}/probes-stats.txt" 2>&1
mem "after-probes"

say "determinism + batch composition + D-01 over HTTP + edges"
python3 "${RUNNER_DIR}/live_checks.py" "${GW}" "${CA}" "${LIVE_KEYFILE}" "${P}" "http://127.0.0.1:${ENG_PORT}" "${IKEY}" "${OUT}" "${MDIR}/onnx/spm.model" > "${OUT}/live_checks.log" 2>&1; echo "rc=$?" >> "${OUT}/live_checks.log"
mem "after-checks"

python3 - "${OUT}" <<'PYEOF'
import json, os, sys
out = sys.argv[1]; lat = {}
for run in ("golden", "probes"):
    p = os.path.join(out, run, "results.json")
    if not os.path.exists(p): continue
    xs = sorted(r["latency_ms"] for r in json.load(open(p))["records"] if r.get("status") == 200 and r.get("latency_ms") is not None)
    if not xs: continue
    q = lambda f: xs[min(len(xs) - 1, int(round(f * (len(xs) - 1))))]
    lat[run] = {"n": len(xs), "p50_ms": q(0.5), "p95_ms": q(0.95), "max_ms": xs[-1], "min_ms": xs[0]}
json.dump(lat, open(os.path.join(out, "latency.json"), "w"), indent=1); print("latency:", lat)
PYEOF

say "stop"
bin/llmctl decide serve --stop > "${OUT}/gateway-stop.txt" 2>&1; echo "rc=$?" >> "${OUT}/gateway-stop.txt"
sed -E 's#(Bearer )[A-Za-z0-9._~+/=-]+#\1<redacted>#g' "${OUT}/engine.log" > "${OUT}/engine.log.redacted" && mv "${OUT}/engine.log.redacted" "${OUT}/engine.log"
kill "${PID}" 2>/dev/null; for _ in $(seq 1 30); do kill -0 "${PID}" 2>/dev/null || break; sleep 1; done
kill -0 "${PID}" 2>/dev/null && echo "runtime still alive" > "${OUT}/after-stop.txt" || echo "runtime stopped (pid ${PID})" > "${OUT}/after-stop.txt"
PID=""
echo "COMPLETED" > "${OUT}/RESULT.txt"
