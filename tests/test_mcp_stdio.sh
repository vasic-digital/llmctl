#!/usr/bin/env bash
# test_mcp_stdio.sh - `llmctl-decide mcp` driven over REAL stdio (newline-delimited JSON-RPC) against a
# REAL TLS gateway (internal/client/internal/clienttest), plus `schema` emission (T084 schema/mcp parts, FR-081, FR-086).
# Builds the real binaries into a temp dir; nothing lands in the repo tree.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
GW_PIDS=()
cleanup() {
  local p
  for p in ${GW_PIDS[@]+"${GW_PIDS[@]}"}; do kill "${p}" 2>/dev/null || true; done
  for p in ${GW_PIDS[@]+"${GW_PIDS[@]}"}; do wait "${p}" 2>/dev/null || true; done
  test_teardown_env
}
trap cleanup EXIT
command -v go >/dev/null 2>&1 || { echo "SKIP-SUITE: go not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP-SUITE: python3 not installed"; exit 0; }

BIN="${TEST_TMP}/bin/llmctl-decide"; CT="${TEST_TMP}/bin/clienttest"
mkdir -p "${TEST_TMP}/bin"
( cd "${LLMCTL_ROOT}" && go build -o "${BIN}" ./cmd/llmctl-decide && go build -o "${CT}" ./internal/client/internal/clienttest )
unset LLMCTL_API_KEY LLMCTL_ENDPOINT LLMCTL_CACERT LLMCTL_HOME LLMCTL_DECIDE_PORT LLMCTL_DECIDE_TIMEOUT LLMCTL_ENV_FILE HTTPS_PROXY https_proxy
export LLMCTL_ROOT

FD=20
start_gw() { # start_gw <name> <mode>
  local name="$1" mode="$2" d="${TEST_TMP}/gw-$1"
  mkdir -p "${d}/home"; mkfifo "${d}/in"
  eval "exec ${FD}<>\"${d}/in\""; FD=$((FD + 1))
  "${CT}" -home "${d}/home" -envfile "${d}/env" -mode "${mode}" <"${d}/in" >"${d}/out" 2>"${d}/err" &
  GW_PIDS+=("$!")
  for _ in $(seq 1 100); do grep -q '^READY ' "${d}/out" 2>/dev/null && break; sleep 0.1; done
  grep -q '^READY ' "${d}/out" || { cat "${d}/err" >&2; echo "gateway ${name} did not start" >&2; exit 1; }
  GW_URL="$(sed -n 's/^READY //p' "${d}/out" | head -n1)"
  GW_HOME="${d}/home"; GW_ENV="${d}/env"
  GW_KEY="$(sed -n 's/^LLMCTL_API_KEY=//p' "${d}/env" | head -n1)"
}

# The stdio driver: spawns the server, feeds the given JSON lines, prints one response line each.
cat >"${TEST_TMP}/drive.py" <<'PY'
import json, subprocess, sys, os
binary, linesfile = sys.argv[1], sys.argv[2]
lines = open(linesfile, encoding="utf-8").read().split("\n")
p = subprocess.Popen([binary, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=os.environ)
out, err = p.communicate("\n".join(lines), timeout=60)
sys.stdout.write(out)
open(linesfile + ".stderr", "w").write(err)
sys.exit(p.returncode)
PY
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}'
NOTIF='{"jsonrpc":"2.0","method":"notifications/initialized"}'
ARGS='{"state":"The disk is 97% full.","questions":{"q":{"type":"choice","instructions":"What now?","criteria":{"clean":"free space","ignore":"do nothing"}}}}'
CALL="{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"decide\",\"arguments\":${ARGS}}}"
jget() { python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(eval(sys.argv[1]))' "$1"; }
session() { # session <lines...> -> prints stdout of the server (env from the caller)
  printf '%s\n' "$@" >"${TEST_TMP}/lines"
  python3 "${TEST_TMP}/drive.py" "${BIN}" "${TEST_TMP}/lines"
}
gwenv() { LLMCTL_HOME="${GW_HOME}" LLMCTL_ENV_FILE="${GW_ENV}" LLMCTL_ENDPOINT="${GW_URL}" "$@"; }

echo "== schema emitters =="
for f in json-schema openai-tool mcp; do
  out="$("${BIN}" schema --format "${f}")"
  assert_eq "True" "$(printf '%s' "${out}" | jget 'isinstance(d, dict)')" "schema --format ${f} is a JSON object"
done
assert_eq "decide" "$("${BIN}" schema --format mcp | jget 'd["name"]')" "mcp tool is named decide"
assert_eq "function" "$("${BIN}" schema --format openai-tool | jget 'd["type"]')" "openai tool is a function"
assert_rc 2 "schema rejects an unknown format" "${BIN}" schema --format xml
assert_eq "$("${BIN}" schema --format mcp | md5sum)" "$("${BIN}" schema --format mcp | md5sum)" "schema output is deterministic"

echo "== mcp over stdio against a real gateway =="
start_gw ok uniform
out="$(gwenv session "${INIT}" "${NOTIF}" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' "${CALL}")"
nl="$(printf '%s\n' "${out}" | wc -l | tr -d ' ')"
assert_eq 3 "${nl}" "three responses (the notification gets none)"
r1="$(printf '%s\n' "${out}" | sed -n 1p)"; r2="$(printf '%s\n' "${out}" | sed -n 2p)"; r3="$(printf '%s\n' "${out}" | sed -n 3p)"
assert_eq "2025-06-18" "$(printf '%s' "${r1}" | jget 'd["result"]["protocolVersion"]')" "initialize negotiates 2025-06-18"
assert_eq "decide" "$(printf '%s' "${r2}" | jget 'd["result"]["tools"][0]["name"]')" "tools/list lists decide"
assert_eq "$("${BIN}" schema --format mcp | jget 'json.dumps(d,sort_keys=True)')" "$(printf '%s' "${r2}" | jget 'json.dumps(d["result"]["tools"][0],sort_keys=True)')" "tools/list equals the schema emitter output"
assert_eq "False" "$(printf '%s' "${r3}" | jget 'd["result"]["isError"]')" "decide succeeds against the gateway"
assert_eq "clean" "$(printf '%s' "${r3}" | jget 'd["result"]["structuredContent"]["answers"]["q"]["choice"]')" "structured answer is the gateway's (first option, peaked backend)"
assert_eq "decide-tiny" "$(printf '%s' "${r3}" | jget 'd["result"]["structuredContent"]["evidence"]["profile"]')" "evidence names the served profile"
assert_eq "False" "$([[ "${out}" == *"${GW_KEY}"* ]] && echo True || echo False)" "the key never appears on stdout"
assert_eq "False" "$([[ "$(cat "${TEST_TMP}/lines.stderr")" == *"${GW_KEY}"* ]] && echo True || echo False)" "the key never appears on stderr"

echo "== min_confidence withholds (fail closed) =="
HI="{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"decide\",\"arguments\":{\"min_confidence\":0.999,\"state\":\"x\",\"questions\":{\"q\":{\"type\":\"choice\",\"instructions\":\"?\",\"criteria\":{\"a\":\"1\",\"b\":\"2\"}}}}}}"
r="$(gwenv session "${INIT}" "${NOTIF}" "${HI}" | sed -n 2p)"
assert_eq "True" "$(printf '%s' "${r}" | jget 'd["result"]["isError"]')" "low confidence is an error result"
assert_eq "False" "$(printf '%s' "${r}" | jget '"structuredContent" in d["result"]')" "no structured answer when withheld"

echo "== fail closed: gateway down, wrong key, not ready, readout =="
r="$(LLMCTL_HOME="${GW_HOME}" LLMCTL_ENV_FILE="${GW_ENV}" LLMCTL_ENDPOINT=https://127.0.0.1:1 session "${INIT}" "${NOTIF}" "${CALL}" | sed -n 2p)"
assert_eq "True" "$(printf '%s' "${r}" | jget 'd["result"]["isError"]')" "unreachable gateway: isError"
assert_contains "${r}" "exit code 6" "unreachable gateway: exit code 6 named"
r="$(LLMCTL_API_KEY="llmctl_wrong_key_for_the_test_0000000000000000" gwenv session "${INIT}" "${NOTIF}" "${CALL}" | sed -n 2p)"
assert_eq "True" "$(printf '%s' "${r}" | jget 'd["result"]["isError"]')" "wrong key (401): isError"
assert_eq "False" "$(printf '%s' "${r}" | jget '"structuredContent" in d["result"]')" "wrong key: no structured answer"
assert_contains "${r}" "exit code 4" "wrong key is reported as a key problem (exit code 4)"
start_gw notready notready
r="$(gwenv session "${INIT}" "${NOTIF}" "${CALL}" | sed -n 2p)"
assert_eq "True" "$(printf '%s' "${r}" | jget 'd["result"]["isError"]')" "not-ready gateway (503): isError"
assert_contains "${r}" "exit code" "not-ready: classified failure"
assert_contains "${r}" "exit code" "not-ready: classified failure"
start_gw readout readout
r="$(gwenv session "${INIT}" "${NOTIF}" "${CALL}" | sed -n 2p)"
assert_eq "True" "$(printf '%s' "${r}" | jget 'd["result"]["isError"]')" "readout failure (422): isError"

echo "== no key at all: the server still starts and refuses every call =="
rc=0
out="$(HOME="${TEST_TMP}/emptyhome" LLMCTL_ROOT="${TEST_TMP}/emptyroot" LLMCTL_ENDPOINT="${GW_URL}" session "${INIT}" "${NOTIF}" "${CALL}")" || rc=$?
assert_eq 0 "${rc}" "server exits 0 on EOF even when misconfigured"
assert_eq "True" "$(printf '%s\n' "${out}" | sed -n 2p | jget 'd["result"]["isError"]')" "unconfigured: isError"

echo "== malformed input never kills the server =="
big="$(python3 -c 'print("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\",\"params\":{\"x\":\"" + "a"*100 + "\"}}")')"
out="$(gwenv session "${INIT}" '{broken' '[1,2]' '{"jsonrpc":"2.0","id":5,"method":"nope"}' "${big}" '{"jsonrpc":"2.0","id":6,"method":"ping"}')"
assert_eq 6 "$(printf '%s\n' "${out}" | wc -l | tr -d ' ')" "one response per message"
assert_eq "-32700" "$(printf '%s\n' "${out}" | sed -n 2p | jget 'd["error"]["code"]')" "bad JSON -> -32700"
assert_eq "-32600" "$(printf '%s\n' "${out}" | sed -n 3p | jget 'd["error"]["code"]')" "batch -> -32600"
assert_eq "-32601" "$(printf '%s\n' "${out}" | sed -n 4p | jget 'd["error"]["code"]')" "unknown method -> -32601"
assert_eq "6" "$(printf '%s\n' "${out}" | sed -n 6p | jget 'd["id"]')" "the server answered after the garbage"
bad="$(printf '%s\n' "${out}" | python3 -c 'import json,sys
n=0
for l in sys.stdin:
    try: json.loads(l)
    except Exception: n+=1
print(n)')"
assert_eq 0 "${bad}" "every stdout line is valid JSON"
test_finish
