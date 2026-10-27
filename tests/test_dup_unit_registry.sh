#!/usr/bin/env bash
# test_dup_unit_registry.sh - RED-first. Two units (llmctl-llama@P, llmctl-onnx@P) run ONE profile on ONE port. The winner
# answers /health; the loser (alive while it loads its model) sees that answer and its registration waiter publishes the
# LOSER's pid over the winner's row, then the loser dies on EADDRINUSE and its ExecStopPost (MAINPID == its own pid, so the
# unregister ownership guard rightly lets it through) deletes the row: the live winner ends up with NO row (llmctl status
# shows nothing; doctor: "live engine process(es) with no registry row"). Second half: the loser's ExecStopPost also killed
# the WINNER's registration waiter (one waiter pid file per instance), so a winner that had not registered yet never would.
# Contract: a waiter never publishes over another LIVE engine's row; a stop kills only ITS OWN waiter.
# Hermetic: stateful fake llmctl-decide registry (a file), free high port, own sleep pids only.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
HOOK="${LLMCTL_ROOT}/lib/svc_hook.sh"
PIDS=()
cleanup() { local p; for p in "${PIDS[@]:-}"; do [[ -n "${p}" ]] && kill "${p}" 2>/dev/null || true; done; test_teardown_env; }
trap cleanup EXIT
export LLMCTL_PORTREG=1 LLMCTL_LOG_DIR="${TEST_TMP}/logs" LLMCTL_VALIDATE_ON_START=0
export LLMCTL_REGISTER_WAIT=20 LLMCTL_REGISTER_POLL=1 LLMCTL_REGISTER_IDENTITY_WAIT=1
mkdir -p "${LLMCTL_LOG_DIR}" "${LLMCTL_SERVICES_DIR}"
ROW="${TEST_TMP}/row"          # the fake registry: one file "pid cmd_token" per name
# the stub keeps its own cmdline (the registry identity check matches the "llama-server" token) and forwards TERM to its
# sleep: the cleanup kills the recorded sh pid, and a plain `sleep 120` child survived that as an orphan
printf '#!/bin/sh\ntrap '\''kill $c 2>/dev/null; exit 0'\'' TERM\nsleep 120 & c=$!\nwait $c\n' > "${TEST_TMP}/llama-server"; chmod +x "${TEST_TMP}/llama-server"
cat > "${TEST_TMP}/fake-decide" <<F
#!/bin/sh
[ "\$1" = registry ] || exit 0
case "\$2" in
  register) shift 3; while [ \$# -gt 0 ]; do [ "\$1" = --pid ] && pid="\$2"; shift; done; echo "\$pid llama-server" > "${ROW}" ;;
  unregister) rm -f "${ROW}" ;;
  list) if [ -f "${ROW}" ]; then set -- \$(cat "${ROW}"); printf '{"services":[{"name":"decide-nli","pid":%s,"port":1,"cmd_token":"%s"}]}\n' "\$1" "\$2"; else echo '{"services":[]}'; fi ;;
esac
exit 0
F
chmod +x "${TEST_TMP}/fake-decide"; export LLMCTL_DECIDE_BIN="${TEST_TMP}/fake-decide"
# the winner's HTTP surface: a real listener on a free high loopback port answering /health 200
python3 -c '
import http.server, socketserver
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass
s = socketserver.TCPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True); s.serve_forever()' > "${TEST_TMP}/port" &
PIDS+=("$!")
for _ in $(seq 1 50); do [[ -s "${TEST_TMP}/port" ]] && break; sleep 0.1; done
PORT="$(head -1 "${TEST_TMP}/port")"
{ printf 'LLMCTL_ENGINE=onnx\nLLMCTL_PORT=%s\nLLMCTL_REG_TOKEN=llama-server\nLLMCTL_REG_PROTOCOL=http\n' "${PORT}"
  printf 'LLMCTL_REG_HEALTH=/health\nLLMCTL_REG_KIND=llm\nLLMCTL_REG_PROFILE=decide-nli\nLLMCTL_REG_LOOPBACK=1\n'; } > "${LLMCTL_SERVICES_DIR}/decide-nli.env"
"${TEST_TMP}/llama-server" --winner & WINNER=$!; PIDS+=("${WINNER}")
"${TEST_TMP}/llama-server" --loser & LOSER=$!; PIDS+=("${LOSER}")
sleep 0.3
row_pid() { [[ -f "${ROW}" ]] && cut -d' ' -f1 "${ROW}" || echo none; }
waiter() { timeout 30 bash "${HOOK}" _wait_register decide-nli "$1" >>"${TEST_TMP}/w.out" 2>&1 || true; }

echo "== A: winner registered first; the loser's waiter must not publish over it, and the loser's stop keeps the row"
waiter "${WINNER}"
assert_eq "${WINNER}" "$(row_pid)" "setup: the winner's row is published"
waiter "${LOSER}"
assert_eq "${WINNER}" "$(row_pid)" "loser's waiter did NOT overwrite the live winner's row"
kill "${LOSER}" 2>/dev/null || true; wait "${LOSER}" 2>/dev/null || true
MAINPID="${LOSER}" timeout 20 bash "${HOOK}" unregister decide-nli >/dev/null 2>&1 || true
assert_eq "${WINNER}" "$(row_pid)" "after the loser's ExecStopPost the live winner still has its row"

echo "== B: the loser's stop must not kill the WINNER's still-polling registration waiter"
# instance 'slowp': its port is closed, so the winner's waiter keeps polling (it is the one the pid file points at)
FREE="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
{ printf 'LLMCTL_ENGINE=onnx\nLLMCTL_PORT=%s\nLLMCTL_REG_TOKEN=llama-server\nLLMCTL_REG_PROTOCOL=http\n' "${FREE}"
  printf 'LLMCTL_REG_HEALTH=/health\nLLMCTL_REG_KIND=llm\nLLMCTL_REG_PROFILE=slowp\nLLMCTL_REG_LOOPBACK=1\n'; } > "${LLMCTL_SERVICES_DIR}/slowp.env"
"${TEST_TMP}/llama-server" --loser2 & LOSER2=$!; PIDS+=("${LOSER2}")
MAINPID="${WINNER}" timeout 20 bash "${HOOK}" register slowp >/dev/null 2>&1 || true
sleep 0.5
WPID="$(head -1 "${LLMCTL_RUNTIME_DIR:-${LLMCTL_STATE_DIR}/run}/waiters/slowp.pid" 2>/dev/null || echo 0)"; PIDS+=("${WPID}")
assert_eq 1 "$(kill -0 "${WPID}" 2>/dev/null && echo 1 || echo 0)" "setup: the winner's waiter (pid ${WPID}) is polling"
MAINPID="${LOSER2}" timeout 20 bash "${HOOK}" unregister slowp >/dev/null 2>&1 || true
sleep 0.3
assert_eq 1 "$(kill -0 "${WPID}" 2>/dev/null && echo 1 || echo 0)" "the loser's ExecStopPost left the winner's waiter alive"
test_finish
