#!/usr/bin/env bash
# test_health_path_engines.sh - the registry health path must be the path the ENGINE actually serves
# (anton 2026-10-09: onnx engines were registered with /health but lib/onnx_server.py serves /healthz only,
# so the post-start waiter never registered decide-nli). Stub HTTP servers answer ONLY the path their real
# engine answers; the unit's registration waiter must succeed against each.
#   llama-server -> /health      onnx_server.py -> /healthz      colibri -> /v1/models
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap 'kill ${STUB_PIDS:-} 2>/dev/null || true; test_teardown_env' EXIT
command -v python3 >/dev/null 2>&1 || { echo "SKIP-SUITE: python3 not installed"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "SKIP-SUITE: curl not installed"; exit 0; }

export LLMCTL_PORTREG=1 LLMCTL_REGISTER_POLL=0.2 LLMCTL_REGISTER_WAIT=6
STUB_PIDS=""

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
# stub_only <port> <path> : answers 200 on exactly <path>, 404 elsewhere (like the real engines)
stub_only() {
  python3 -c '
import sys, http.server
port, only = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if self.path == only else 404); self.send_header("Content-Length","2"); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self,*a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()' "$1" "$2" >/dev/null 2>&1 </dev/null &
  STUB_PIDS="${STUB_PIDS} $!"
  for _ in $(seq 1 50); do curl -s --max-time 1 -o /dev/null "http://127.0.0.1:$1/__probe" && return 0; sleep 0.1; done
  return 1
}

reg_health_of() { # <engine> -> LLMCTL_REG_HEALTH value from portreg_env_lines
  ( source "${LLMCTL_ROOT}/lib/portreg.sh"
    portreg_env_lines p "$1" /usr/bin/x --port 1234 | sed -n 's/^LLMCTL_REG_HEALTH=//p' )
}

echo "== portreg_env_lines: health path per engine =="
assert_eq "/readyz"     "$(reg_health_of onnx)"    "onnx engine registers /readyz (truthful readiness; /healthz is liveness only)"
assert_eq "/health"     "$(reg_health_of llama)"   "llama engine registers /health"
assert_eq "/v1/models"  "$(reg_health_of colibri)" "colibri engine registers /v1/models"

echo "== end to end: the unit's waiter registers each engine against a stub that serves ONLY its real path =="
run_waiter() { # <engine> <served-path> -> prints REGISTERED or NOT
  local engine="$1" served="$2" port rec f
  port="$(free_port)"; stub_only "${port}" "${served}"
  f="${TEST_TMP}/${engine}.env"
  ( source "${LLMCTL_ROOT}/lib/portreg.sh"; portreg_env_lines prof "${engine}" /usr/bin/x --port "${port}" ) > "${f}"
  rec="${TEST_TMP}/${engine}.rec"; rm -f "${rec}"
  sleep 30 >/dev/null 2>&1 & local spid=$!
  (
    set --; source "${LLMCTL_ROOT}/lib/svc_hook.sh"
    portreg_register() { printf 'health=%s\n' "$6" > "${rec}"; }
    health="$(_hk_get "${f}" LLMCTL_REG_HEALTH)"
    _hk_wait_register "${engine}" "${port}" "${spid}" tok http "${health}" decide prof "${engine}" 1 "" >/dev/null 2>&1 || true
  )
  kill "${spid}" 2>/dev/null || true
  if [[ -s "${rec}" ]]; then printf 'REGISTERED'; else printf 'NOT'; fi
}
assert_eq "REGISTERED" "$(run_waiter onnx /readyz)"        "onnx: waiter registers when only /readyz answers"
assert_eq "REGISTERED" "$(run_waiter llama /health)"       "llama: waiter registers when only /health answers"
assert_eq "REGISTERED" "$(run_waiter colibri /v1/models)"  "colibri: waiter registers when only /v1/models answers"

echo "== scheduler readiness path for a decision profile follows the engine =="
assert_eq "/readyz"    "$( source "${LLMCTL_ROOT}/lib/portreg.sh"; portreg_health_path onnx )"    "portreg_health_path onnx"
assert_eq "/health"    "$( source "${LLMCTL_ROOT}/lib/portreg.sh"; portreg_health_path llama )"   "portreg_health_path llama"
assert_eq "/v1/models" "$( source "${LLMCTL_ROOT}/lib/portreg.sh"; portreg_health_path colibri )" "portreg_health_path colibri"

[[ "${TEST_FAILS}" -eq 0 ]] || { echo "FAILED: ${TEST_FAILS}" >&2; exit 1; }
echo "OK"
