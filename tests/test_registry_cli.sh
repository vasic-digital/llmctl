#!/usr/bin/env bash
# test_registry_cli.sh - builds the REAL llmctl-decide binary (into a temp dir, nothing in the
# repo tree) and drives `port`, `registry` and `discover` end to end with real listener
# processes (FR-088..FR-090, SC-015). Exit status, stdout and the live process set are judged.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
SVC_PIDS=()
cleanup() { for p in "${SVC_PIDS[@]:-}"; do [[ -n "${p}" ]] && kill -9 "${p}" 2>/dev/null || true; done; test_teardown_env; }
trap cleanup EXIT

command -v go >/dev/null 2>&1 || { echo "SKIP-SUITE: go not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP-SUITE: python3 not installed; needed for the listener processes"; exit 0; }
BIN="${TEST_TMP}/bin/llmctl-decide"
mkdir -p "${TEST_TMP}/bin"
( cd "${LLMCTL_ROOT}" && go build -o "${BIN}" ./cmd/llmctl-decide )

unset LLMCTL_PORT_STRATEGY LLMCTL_PORT_RANGE
D() { "${BIN}" "$@"; }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }

# a real service: argv carries the token, answers 200 on /health
LISTENER='import http.server,sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self,*a): pass
http.server.HTTPServer(("127.0.0.1",int(sys.argv[2])),H).serve_forever()'
start_svc() { # <token> <port> -> pid in SVC_LAST
  python3 -c "${LISTENER}" "$1" "$2" >/dev/null 2>&1 &
  SVC_LAST=$!; SVC_PIDS+=("${SVC_LAST}")
  for _ in $(seq 1 100); do python3 -c "import socket,sys;socket.create_connection(('127.0.0.1',$2),0.2)" 2>/dev/null && return 0; sleep 0.05; done
  echo "listener on $2 never came up" >&2; return 1
}
LO="$(free_port)"; LO=$(( (LO / 100) * 100 + 100 )); HI=$(( LO + 49 ))
export LLMCTL_PORT_RANGE="${LO}-${HI}"

echo "== usage errors exit 2 =="
assert_rc 2 "no subcommand arguments" D port
assert_rc 2 "unknown port command" D port bogus
assert_rc 2 "allocate without name" D port allocate
assert_rc 2 "fixed allocation without a documented port" D port allocate svc
assert_rc 2 "register without --token" D registry register svc --port 9000 --pid 4242
assert_rc 2 "register with pid 1" D registry register svc --port 9000 --pid 1 --token x
assert_rc 2 "bad strategy" D port allocate svc --strategy random --fixed 9000

echo "== fixed strategy: documented port, taken port fails with number + variable =="
P1="$(free_port)"
out="$(D port allocate chat-fast --fixed "${P1}")"
assert_eq "${P1}" "${out}" "documented port returned"
D port release chat-fast >/dev/null
python3 -c "import socket,time;s=socket.socket();s.bind(('127.0.0.1',${P1}));s.listen();time.sleep(30)" &
OCC=$!; SVC_PIDS+=("${OCC}"); sleep 0.3
rc=0; err="$(D port allocate chat-fast --fixed "${P1}" 2>&1 >/dev/null)" || rc=$?
assert_eq "1" "${rc}" "taken documented port exits 1"
assert_contains "${err}" "${P1}" "message names the port"
assert_contains "${err}" "LLMCTL_PORT_CHAT_FAST" "message names the override variable"
echo "== explicit numeric wins; =auto switches that profile to dynamic =="
P2="$(free_port)"
out="$(LLMCTL_PORT_CHAT_FAST="${P2}" D port allocate chat-fast --fixed "${P1}")"
assert_eq "${P2}" "${out}" "explicit numeric override wins"
D port release chat-fast >/dev/null
out="$(LLMCTL_PORT_CHAT_FAST=auto D port allocate chat-fast --fixed "${P1}")"
assert_eq "1" "$(( out >= LO && out <= HI ))" "auto -> dynamic port inside LLMCTL_PORT_RANGE (${out})"
D port release chat-fast >/dev/null
kill -9 "${OCC}" 2>/dev/null || true

echo "== SC-015: three dynamic services, one default port occupied =="
export LLMCTL_PORT_STRATEGY=dynamic
python3 -c "import socket,time;s=socket.socket();s.bind(('127.0.0.1',${LO}));s.listen();time.sleep(60)" &
OCC2=$!; SVC_PIDS+=("${OCC2}"); sleep 0.3
declare -A PORT PID
for n in svc-a svc-b svc-c; do
  PORT[$n]="$(D port allocate "$n")"
  start_svc "tok-$n" "${PORT[$n]}"; PID[$n]="${SVC_LAST}"
  D registry register "$n" --port "${PORT[$n]}" --pid "${PID[$n]}" --token "tok-$n" \
    --protocol http --health-path /health --kind decision --profile "$n" --instance 1 --loopback-only >/dev/null
done
assert_eq "3" "$(printf '%s\n' "${PORT[@]}" | sort -u | wc -l)" "three distinct ports"
assert_eq "0" "$(printf '%s\n' "${PORT[@]}" | grep -c "^${LO}$" || true)" "the occupied port was not handed out"
json="$(D discover --json)"
assert_eq "3" "$(python3 -c 'import json,sys;print(len(json.load(sys.stdin)["services"]))' <<<"${json}")" "discover lists three services"
assert_eq "3" "$(python3 -c 'import json,sys;print(sum(1 for s in json.load(sys.stdin)["services"] if s["healthy"]))' <<<"${json}")" "all healthy"
assert_contains "${json}" "http://127.0.0.1:${PORT[svc-a]}" "URL scheme+address present"
assert_eq "0" "$(D registry diff --live "svc-a=${PID[svc-a]},svc-b=${PID[svc-b]},svc-c=${PID[svc-c]}" >/dev/null; echo $?)" "registry == live set"

echo "== kill -9 one: gone from the registry after one reconcile =="
kill -9 "${PID[svc-b]}"; wait "${PID[svc-b]}" 2>/dev/null || true
out="$(D registry reconcile --grace 1m)"
assert_contains "${out}" "removed svc-b" "reconcile reports the removal with a reason"
assert_eq "2" "$(D discover --json | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["services"]))')" "two services left"
assert_eq "0" "$(D registry diff --live "svc-a=${PID[svc-a]},svc-c=${PID[svc-c]}" >/dev/null; echo $?)" "registry == live set after the kill"
rc=0; D registry diff --live "svc-a=${PID[svc-a]},svc-c=${PID[svc-c]},svc-b=${PID[svc-b]}" >/dev/null || rc=$?
assert_eq "1" "${rc}" "a live process with no row is reported (exit 1)"
assert_contains "$(D port list)" "svc-a" "other services keep their ports"
assert_eq "" "$(D port list | grep '^svc-b' || true)" "dead service's port hold released"

echo "== clean stop: unregister + release =="
D registry unregister svc-a >/dev/null; D port release svc-a >/dev/null
assert_eq "1" "$(D discover --json | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["services"]))')" "one service left"

echo "== sticky reuse =="
s1="$(D port allocate sticky)"; D port release sticky >/dev/null
D port allocate other >/dev/null
s2="$(D port allocate sticky)"
assert_eq "${s1}" "${s2}" "same service gets the same port back after release"

echo "== concurrent allocation from separate processes =="
for i in 1 2 3 4 5 6 7 8; do ( D port allocate "conc$i" > "${TEST_TMP}/conc$i" ) & done
for _ in $(seq 1 100); do [[ $(cat "${TEST_TMP}"/conc? 2>/dev/null | grep -c .) -ge 8 ]] && break; sleep 0.05; done
assert_eq "8" "$(cat "${TEST_TMP}"/conc? | sort -u | wc -l)" "eight concurrent processes got eight distinct ports"

echo "== two users: separate state dirs, disjoint ports =="
U1="${TEST_TMP}/u1"; U2="${TEST_TMP}/u2"
ports=()
for i in 1 2 3; do
  for u in "${U1}" "${U2}"; do
    p="$(D port allocate "svc$i" --state-dir "${u}")"
    python3 -c "import socket,time;s=socket.socket();s.bind(('127.0.0.1',${p}));s.listen();time.sleep(30)" &
    SVC_PIDS+=("$!"); sleep 0.15; ports+=("${p}")
  done
done
assert_eq "6" "$(printf '%s\n' "${ports[@]}" | sort -u | wc -l)" "two users: six distinct ports"

echo "== discover never prints a key =="
export LLMCTL_DECIDE_API_KEY="sk-SECRET-VALUE-XYZ"
out="$(D discover --json 2>&1; D discover 2>&1)"
assert_not_contains() { if [[ "$1" != *"$2"* ]]; then printf '  ok: %s\n' "$3"; else printf '  FAIL: %s\n' "$3" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi; }
assert_not_contains "${out}" "SECRET" "no key material in discover output"
find "${LLMCTL_ROOT}" -maxdepth 2 \( -name 'llmctl-decide' -o -name '*.test' \) -newer "${BIN}" -type f 2>/dev/null | grep -q . && { echo "  FAIL: binary written into the work tree" >&2; TEST_FAILS=$((TEST_FAILS+1)); } || echo "  ok: nothing written into the repo tree"

[[ ${TEST_FAILS} -eq 0 ]] && echo "test_registry_cli: ALL PASS" || { echo "test_registry_cli: ${TEST_FAILS} FAILED" >&2; exit 1; }
