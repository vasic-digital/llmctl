#!/usr/bin/env bash
# test_decide_cli.sh - llmctl's own decision CLIENT, end to end (T043/T052, FR-057..063, FR-068, FR-081).
#
# Builds the REAL Go binary and a REAL gateway process (internal/server over a throw-away CA made by
# the production cert code, internal/client/internal/clienttest) into a temp dir - nothing lands in
# the repo tree - and drives `llmctl-decide ask|batch|models` and the thin bash front end
# (lib/decide.sh) against it. Asserts exit codes 0/1/2/4/5/6/10, JSON shapes, a 5 MB state, that no
# process command line ever carries the access key or the state, and the wizard/strict-flag fixes.
set -euo pipefail
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

# Hermetic client environment: nothing from the operator's shell may leak in.
unset LLMCTL_API_KEY LLMCTL_ENDPOINT LLMCTL_CACERT LLMCTL_HOME LLMCTL_DECIDE_PORT LLMCTL_DECIDE_TIMEOUT \
      LLMCTL_DECIDE_MAX_OPTIONS LLMCTL_DECIDE_MAX_STATE_CHARS LLMCTL_DECIDE_BIN LLMCTL_ENV_FILE HTTPS_PROXY https_proxy
export LLMCTL_DECIDE_BIN="${BIN}"
export LLMCTL_ROOT="${LLMCTL_ROOT}"

FD=20
# start_gw <name> <mode> -> sets GW_URL GW_HOME GW_ENV GW_PID GW_KEY
start_gw() {
  local name="$1" mode="$2" d="${TEST_TMP}/gw-$1"
  mkdir -p "${d}/home"; mkfifo "${d}/in"
  eval "exec ${FD}<>\"${d}/in\""; FD=$((FD + 1))
  "${CT}" -home "${d}/home" -envfile "${d}/env" -mode "${mode}" <"${d}/in" >"${d}/out" 2>"${d}/err" &
  GW_PID=$!; GW_PIDS+=("${GW_PID}")

  for _ in $(seq 1 100); do grep -q '^READY ' "${d}/out" 2>/dev/null && break; sleep 0.1; done
  grep -q '^READY ' "${d}/out" || { cat "${d}/err" >&2; echo "gateway ${name} did not start" >&2; exit 1; }
  GW_URL="$(sed -n 's/^READY //p' "${d}/out" | head -n1)"
  GW_HOME="${d}/home"; GW_ENV="${d}/env"
  GW_KEY="$(sed -n 's/^LLMCTL_API_KEY=//p' "${d}/env" | head -n1)"
}
# client <args...>: the Go binary pointed at the current gateway through the documented env only
client() { LLMCTL_HOME="${GW_HOME}" LLMCTL_ENV_FILE="${GW_ENV}" LLMCTL_ENDPOINT="${GW_URL}" "${BIN}" "$@"; }
rc_of() { local rc=0; "$@" >"${TEST_TMP}/o" 2>"${TEST_TMP}/e" || rc=$?; echo "${rc}"; }
json_get() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

start_gw ok uniform
CRIT='{"billing":"handles invoices","legal":"contracts"}'

echo "== ask: success, JSON shape, evidence =="
out="$(client ask --type choice --instructions "Which team?" --criteria "${CRIT}" --state "The invoice is overdue." --json)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "ask choice exits 0"
assert_eq "billing" "$(printf '%s' "${out}" | json_get 'd["answers"]["q"]["choice"]')" "choice answer present (billing = first option, mildly peaked backend)"
assert_eq "decide-tiny" "$(printf '%s' "${out}" | json_get 'd["model"]')" "model is the served profile"
assert_eq "${GW_URL##*:}" "$(printf '%s' "${out}" | json_get 'd["evidence"]["port"]')" "evidence.port is the endpoint port"
assert_eq "True" "$(printf '%s' "${out}" | json_get 'isinstance(d["evidence"]["latency_ms"], float) and d["evidence"]["latency_ms"] > 0')" "latency_ms is a real positive millisecond figure"
assert_eq "False" "$(printf '%s' "${out}" | json_get 'd["evidence"]["latency_ms"] % 1000 == 0')" "latency_ms is not a whole-second multiple (D-20)"
assert_eq "True" "$(printf '%s' "${out}" | json_get 'abs(sum(d["answers"]["q"]["probabilities"].values()) - 1) < 1e-6')" "probabilities sum to 1"
nl="$(client ask --type noul --instructions "Is 2+2=4?" --state "Arithmetic facts." --json)"
assert_eq "noul" "$(printf '%s' "${nl}" | json_get 'd["answers"]["q"]["type"]')" "noul answer type"
sc="$(client ask --type score --instructions "Rate it" --criteria '["bad","ok","good"]' --state "fine" --json)"
assert_eq "True" "$(printf '%s' "${sc}" | json_get '0 <= d["answers"]["q"]["score"] <= 2')" "score answer in range"
assert_eq "ok" "$(printf '%s' "${sc}" | json_get 'd["answers"]["q"]["legend"]["1"]')" "score legend echoed"

echo "== ask: question file, profile, explain, dry-run =="
printf '{"type":"choice","instructions":"Which team?","criteria":{"billing":"inv","legal":"con"}}' > "${TEST_TMP}/q.json"
out="$(client ask --question-file "${TEST_TMP}/q.json" --state "s" --profile decide-tiny --json)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "question-file + --profile exits 0"
explain_err="$(client ask --type choice --instructions "Which team?" --criteria "${CRIT}" --state "Ticket text." --explain --json 2>&1 >/dev/null)"
assert_contains "${explain_err}" "=== STATE BEGIN ===" "--explain shows the rendered prompt"
assert_contains "${explain_err}" "A -> billing" "--explain shows the letter map"
assert_contains "${explain_err}" "per-option probabilities" "--explain shows probabilities"
assert_eq "False" "$([[ "${explain_err}" == *"${GW_KEY}"* ]] && echo True || echo False)" "--explain never prints the key"
dry="$(LLMCTL_ENDPOINT=https://127.0.0.1:1 "${BIN}" ask --type noul --instructions q --state s --dry-run)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "--dry-run needs no key, no gateway, no network"
assert_contains "${dry}" "nothing was sent" "--dry-run says it sent nothing"

echo "== N-01: a 5 MB state works from a file and from stdin, nothing on argv =="
python3 - "${TEST_TMP}/big.txt" <<'PY'
import sys
open(sys.argv[1], "w").write(("0123456789abcdef " * 16 + "\n") * 19300)
PY
size="$(wc -c < "${TEST_TMP}/big.txt" | tr -d ' ')"
assert_eq "True" "$([[ ${size} -ge 5000000 ]] && echo True || echo False)" "fixture is at least 5 MB (${size} bytes)"
out="$(client ask --type noul --instructions "Any errors?" --state-file "${TEST_TMP}/big.txt" --json)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "5 MB --state-file exits 0"
assert_eq "noul" "$(printf '%s' "${out}" | json_get 'd["answers"]["q"]["type"]')" "5 MB state answered"
out="$(client ask --type noul --instructions "Any errors?" --stdin --json < "${TEST_TMP}/big.txt")" && rc=0 || rc=$?
assert_eq 0 "${rc}" "5 MB --stdin exits 0"
out="$(LLMCTL_HOME="${GW_HOME}" LLMCTL_ENV_FILE="${GW_ENV}" LLMCTL_ENDPOINT="${GW_URL}" bash -c '
  source "$1/lib/common.sh"; source "$1/lib/catalog.sh"; source "$1/lib/decide.sh"
  decide_ask --type noul --instructions "Any errors?" --state-file "$2" --json' _ "${LLMCTL_ROOT}" "${TEST_TMP}/big.txt")" && rc=0 || rc=$?
assert_eq 0 "${rc}" "5 MB state through the bash front end exits 0 (was rc 126 'Argument list too long')"
assert_contains "${out}" '"answers"' "front end returns the gateway answer"

echo "== no command line ever carries the key or the state (D-03, N-01) =="
start_gw slow slow:3000
secret_state="STATE-MARKER-$(date +%s%N)-xyzzy"
# needle_hits <text>: how many process command lines contain <text>. The needle travels in the
# environment and the program on stdin so the scanner's own argv can never match itself.
needle_hits() {
  NEEDLE="$1" python3 - <<'PY'
import glob, os
needle = os.environ["NEEDLE"].encode()
me = os.getpid()
n = 0
for f in glob.glob("/proc/[0-9]*/cmdline"):
    if f.split("/")[2] == str(me):
        continue
    try:
        if needle in open(f, "rb").read():
            n += 1
    except OSError:
        pass
print(n)
PY
}
# control needle: the detector must SEE a key that really is on a command line
bash -c 'sleep 30; :' _ "${GW_KEY}" & NEEDLE_PID=$!
sleep 0.3
assert_eq "True" "$([[ $(needle_hits "${GW_KEY}") -ge 1 ]] && echo True || echo False)" "control: the cmdline scan sees a key placed on argv"
pkill -P "${NEEDLE_PID}" 2>/dev/null || true; kill "${NEEDLE_PID}" 2>/dev/null || true; wait "${NEEDLE_PID}" 2>/dev/null || true
printf '%s' "${secret_state}" > "${TEST_TMP}/secret_state.txt"
client ask --type noul --instructions "ok?" --state-file "${TEST_TMP}/secret_state.txt" --json >"${TEST_TMP}/slow1.out" 2>&1 & CPID=$!
LLMCTL_HOME="${GW_HOME}" LLMCTL_ENV_FILE="${GW_ENV}" LLMCTL_ENDPOINT="${GW_URL}" \
  bash -c 'source "$1/lib/common.sh"; source "$1/lib/catalog.sh"; source "$1/lib/decide.sh"; decide_ask --type noul --instructions "ok?" --stdin --json < "$2"' \
  _ "${LLMCTL_ROOT}" "${TEST_TMP}/secret_state.txt" >"${TEST_TMP}/slow2.out" 2>&1 & FPID=$!
sleep 1
assert_eq "True" "$(kill -0 "${CPID}" 2>/dev/null && kill -0 "${FPID}" 2>/dev/null && echo True || echo False)" "both clients are mid-request (slow gateway)"
assert_eq "0" "$(needle_hits "${GW_KEY}")" "the access key is on no process command line during a request"
assert_eq "0" "$(needle_hits "${secret_state}")" "the state text is on no process command line during a request"
wait "${CPID}"; assert_eq 0 "$?" "slow request completed (direct)"
wait "${FPID}"; assert_eq 0 "$?" "slow request completed (front end)"
assert_eq "False" "$(grep -qF -- "${GW_KEY}" "${TEST_TMP}"/slow1.out "${TEST_TMP}"/slow2.out && echo True || echo False)" "the key is in no output"

echo "== exit codes: 4 key, 5 certificate, 6 unreachable/not ready, 1 readout, 10 abstained =="
start_gw ok2 uniform
assert_eq 4 "$(rc_of env LLMCTL_ENV_FILE="${TEST_TMP}/no-such.env" LLMCTL_HOME="${GW_HOME}" LLMCTL_ENDPOINT="${GW_URL}" "${BIN}" ask --type noul --instructions q --state s)" "no key anywhere -> 4"
assert_contains "$(cat "${TEST_TMP}/e")" "no access key" "missing-key message names the problem"
printf 'LLMCTL_API_KEY=   \n' > "${TEST_TMP}/blank.env"; chmod 600 "${TEST_TMP}/blank.env"
assert_eq 4 "$(rc_of env LLMCTL_ENV_FILE="${TEST_TMP}/blank.env" LLMCTL_HOME="${GW_HOME}" LLMCTL_ENDPOINT="${GW_URL}" "${BIN}" ask --type noul --instructions q --state s)" "blank key -> 4"
WRONG="WRONGk3y-0123456789abcdefghijklmnopqrstuvwxyz-QWERTY"
assert_eq 4 "$(rc_of env LLMCTL_API_KEY="${WRONG}" LLMCTL_HOME="${GW_HOME}" LLMCTL_ENDPOINT="${GW_URL}" "${BIN}" ask --type noul --instructions q --state s)" "wrong key (gateway answers 401) -> 4"
assert_eq "False" "$([[ "$(cat "${TEST_TMP}/e")" == *"${WRONG}"* ]] && echo True || echo False)" "the rejected key is not echoed"
# a second, unrelated CA: the right gateway, the wrong trust anchor
mkdir -p "${TEST_TMP}/other-home"
"${BIN}" cert --home "${TEST_TMP}/other-home" --hostname testhost --address 127.0.0.1 ensure >/dev/null 2>&1
assert_eq 5 "$(rc_of env LLMCTL_CACERT="${TEST_TMP}/other-home/cert/ca/ca.crt" LLMCTL_ENV_FILE="${GW_ENV}" LLMCTL_ENDPOINT="${GW_URL}" "${BIN}" ask --type noul --instructions q --state s)" "wrong CA -> 5"
assert_contains "$(cat "${TEST_TMP}/e")" "not trusted" "wrong-CA message says why"
assert_eq 5 "$(rc_of env LLMCTL_CACERT="${TEST_TMP}/does-not-exist.crt" LLMCTL_ENV_FILE="${GW_ENV}" LLMCTL_ENDPOINT="${GW_URL}" "${BIN}" ask --type noul --instructions q --state s)" "missing CA file -> 5"
assert_eq 6 "$(rc_of env LLMCTL_HOME="${GW_HOME}" LLMCTL_ENV_FILE="${GW_ENV}" LLMCTL_ENDPOINT="https://127.0.0.1:1" "${BIN}" ask --type noul --instructions q --state s)" "closed port -> 6"
assert_contains "$(cat "${TEST_TMP}/e")" "connection refused" "closed-port message says why"
assert_eq 2 "$(rc_of env LLMCTL_HOME="${GW_HOME}" LLMCTL_ENV_FILE="${GW_ENV}" LLMCTL_ENDPOINT="http://127.0.0.1:1" "${BIN}" ask --type noul --instructions q --state s)" "plain http endpoint is refused (never clear text) -> 2"
start_gw notready notready
assert_eq 6 "$(rc_of client ask --type noul --instructions q --state s --retries 1)" "gateway not ready (503) -> 6 after bounded retries"
start_gw readout readout
assert_eq 1 "$(rc_of client ask --type noul --instructions q --state s)" "readout failure (422 readout_failed) -> 1"
start_gw ok3 uniform
out="$(client ask --type choice --instructions "Which team?" --criteria "${CRIT}" --state s --json --min-confidence 0.9)" && rc=0 || rc=$?
assert_eq 10 "${rc}" "confidence below --min-confidence -> exit 10"
assert_eq "True" "$(printf '%s' "${out}" | json_get 'd["abstained"] is True and d["answers"]["q"]["choice"] == "billing"')" "abstained answer still printed with abstained true"
out="$(client ask --type choice --instructions "Which team?" --criteria "${CRIT}" --state s --json --min-confidence 0.1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "confidence above --min-confidence -> 0"
assert_eq "False" "$(printf '%s' "${out}" | json_get 'd["abstained"]')" "abstained false recorded"

echo "== usage errors exit 2 (strict flags, N-07; bad env, N-16) =="
assert_eq 2 "$(rc_of client ask --bogus)" "unknown flag -> 2"
assert_eq 2 "$(rc_of client ask --type noul --instructions q)" "no state -> 2"
assert_eq 2 "$(rc_of client ask --type maybe --instructions q --state s)" "bad type -> 2"
assert_eq 2 "$(rc_of client ask --type noul --instructions q --state s extra)" "stray positional -> 2"
assert_eq 2 "$(rc_of client models --nope)" "models: unknown flag -> 2"
assert_eq 2 "$(rc_of env LLMCTL_DECIDE_MAX_OPTIONS=abc LLMCTL_HOME="${GW_HOME}" LLMCTL_ENV_FILE="${GW_ENV}" LLMCTL_ENDPOINT="${GW_URL}" "${BIN}" ask --type noul --instructions q --state s)" "LLMCTL_DECIDE_MAX_OPTIONS=abc -> 2"
err="$(cat "${TEST_TMP}/e")"
assert_contains "${err}" "LLMCTL_DECIDE_MAX_OPTIONS" "bad numeric env names the variable"
assert_eq "False" "$([[ "${err}" == *"Traceback"* || "${err}" == *"goroutine"* ]] && echo True || echo False)" "no traceback for a bad numeric env"
assert_eq 2 "$(rc_of env LLMCTL_DECIDE_PORT=99999 "${BIN}" ask --type noul --instructions q --state s --dry-run)" "LLMCTL_DECIDE_PORT out of range -> 2"

echo "== batch: NDJSON in/out, per-line errors, highest-severity exit =="
printf '%s\n' \
  '{"id":1,"state":"a","questions":{"q":{"type":"noul","instructions":"ok?"}}}' \
  'not json' \
  '{"id":"three","state":"c","questions":{"q":{"type":"choice","instructions":"w","criteria":{"billing":"x","legal":"y"}}}}' > "${TEST_TMP}/batch.in"
out="$(client batch --in "${TEST_TMP}/batch.in")" && rc=0 || rc=$?
assert_eq 2 "${rc}" "batch exit code = highest severity seen (usage 2)"
assert_eq 3 "$(printf '%s\n' "${out}" | wc -l | tr -d ' ')" "one output line per input line"
assert_eq "1" "$(printf '%s\n' "${out}" | sed -n 1p | json_get 'd["id"]')" "line 1 keeps its id"
assert_eq "2" "$(printf '%s\n' "${out}" | sed -n 2p | json_get 'd["error"]["exit_code"]')" "line 2 is a per-line usage error"
assert_eq "billing" "$(printf '%s\n' "${out}" | sed -n 3p | json_get 'd["result"]["answers"]["q"]["choice"]')" "line 3 answered after a bad line"
out="$(client batch < "${TEST_TMP}/batch.in" 2>/dev/null)" || true
assert_eq 3 "$(printf '%s\n' "${out}" | wc -l | tr -d ' ')" "batch reads stdin by default"

echo "== models =="
out="$(client models)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "models exits 0"
assert_contains "${out}" "decide-tiny" "models lists the served profile"
assert_eq "decide-tiny" "$(client models --json | json_get 'd["data"][0]["id"]')" "models --json is the gateway document"

echo "== thin front end (lib/decide.sh) =="
fe() { LLMCTL_HOME="${GW_HOME}" LLMCTL_ENV_FILE="${GW_ENV}" LLMCTL_ENDPOINT="${GW_URL}" bash -c '
  source "$1/lib/common.sh"; source "$1/lib/catalog.sh"; source "$1/lib/decide.sh"; shift; cmd_decide "$@"' _ "${LLMCTL_ROOT}" "$@"; }
out="$(fe ask --type noul --instructions "ok?" --state s --json)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "cmd_decide ask delegates and exits 0"
assert_eq "noul" "$(printf '%s' "${out}" | json_get 'd["answers"]["q"]["type"]')" "front end prints the Go client's JSON"
assert_eq 4 "$(rc_of env LLMCTL_ENV_FILE="${TEST_TMP}/no-such.env" bash -c 'source "$1/lib/common.sh"; source "$1/lib/catalog.sh"; source "$1/lib/decide.sh"; cmd_decide ask --type noul --instructions q --state s' _ "${LLMCTL_ROOT}")" "front end passes exit code 4 through"
assert_eq 10 "$(rc_of fe ask --type choice --instructions w --criteria "${CRIT}" --state s --json --min-confidence 0.99)" "front end passes exit code 10 through"
assert_eq 2 "$(rc_of fe nonsense)" "unknown decide subcommand -> 2"
assert_eq 2 "$(rc_of fe ask --bogus)" "front end: unknown ask flag -> 2 (from the client)"
assert_eq 1 "$(rc_of env LLMCTL_DECIDE_BIN="${TEST_TMP}/nope" bash -c 'source "$1/lib/common.sh"; source "$1/lib/catalog.sh"; source "$1/lib/decide.sh"; cmd_decide ask --type noul --instructions q --state s' _ "${LLMCTL_ROOT}")" "unusable LLMCTL_DECIDE_BIN -> 1 with a message"
assert_contains "$(cat "${TEST_TMP}/e")" "LLMCTL_DECIDE_BIN" "message names the variable"
mkdir -p "${TEST_TMP}/emptybin"
assert_eq 1 "$(rc_of env -u LLMCTL_DECIDE_BIN LLMCTL_DECIDE_BUILD_OUT="${TEST_TMP}/absent/llmctl-decide" bash -c 'source "$1/lib/common.sh"; source "$1/lib/catalog.sh"; source "$1/lib/decide.sh"; PATH="$2"; cmd_decide ask --type noul --instructions q --state s' _ "${LLMCTL_ROOT}" "${TEST_TMP}/emptybin")" "binary absent and no Go -> 1 (never 3)"
assert_contains "$(cat "${TEST_TMP}/e")" "llmctl build decide" "the error says exactly what to run"
assert_eq "0" "$(grep -c 'LLMCTL_DECIDE_BACKEND\|LLMCTL_ONNX_FAKE\|LLMCTL_DECIDE_API_KEY' "${LLMCTL_ROOT}/lib/decide.sh" | tr -d ' ')" "retired seams/variables are gone from lib/decide.sh (D-11, D-29)"
assert_eq "0" "$(grep -c 'when it lands' "${LLMCTL_ROOT}/lib/decide.sh" | tr -d ' ')" "stale 'when it lands' comment is gone (D-24)"

echo "== strict arguments for capacity/status (N-07) =="
assert_eq 2 "$(rc_of fe capacity --jsno)" "capacity: unknown argument -> 2"
assert_eq 2 "$(rc_of fe status --jsno)" "status: unknown argument -> 2"
assert_eq 2 "$(rc_of fe status --json extra)" "status: extra argument -> 2"

echo "== wizard: end of input is a message and rc 2, never a silent exit (N-06); prompts on stderr (N-09) =="
wiz="$(LLMCTL_HOME="${GW_HOME}" LLMCTL_ENV_FILE="${GW_ENV}" LLMCTL_ENDPOINT="${GW_URL}" LLMCTL_CATALOG="${LLMCTL_ROOT}/models/catalog.json" bash -c '
  source "$1/lib/common.sh"; source "$1/lib/catalog.sh"; source "$1/lib/decide.sh"
  decide_interactive --interactive </dev/null 2>"$2" || echo "survived rc=$?"' _ "${LLMCTL_ROOT}" "${TEST_TMP}/wiz.err")" || true
assert_contains "${wiz}" "survived rc=2" "the calling shell survives wizard EOF and sees rc 2"
assert_contains "$(cat "${TEST_TMP}/wiz.err")" "end of input" "EOF produces a message"
assert_contains "$(cat "${TEST_TMP}/wiz.err")" "Profile [gateway default]:" "the prompt text reaches stderr even with piped stdin"
out="$(printf '\nnoul\nArithmetic facts.\n.\nIs 2+2=4?\n\n\n\n' | LLMCTL_HOME="${GW_HOME}" LLMCTL_ENV_FILE="${GW_ENV}" LLMCTL_ENDPOINT="${GW_URL}" LLMCTL_CATALOG="${LLMCTL_ROOT}/models/catalog.json" bash -c '
  source "$1/lib/common.sh"; source "$1/lib/catalog.sh"; source "$1/lib/decide.sh"
  decide_interactive --interactive 2>/dev/null' _ "${LLMCTL_ROOT}")" && rc=0 || rc=$?
assert_eq 0 "${rc}" "scripted wizard run exits 0"
assert_eq "noul" "$(printf '%s' "${out}" | json_get 'd["answers"]["q"]["type"]')" "wizard answers through the same client"

echo "== OD-23: probe-order / calibrate / completions through the real binary and the thin front end =="
# probe-order against the real gateway process (the test backend peaks on the FIRST listed option,
# a pure position bias): the order-sensitivity probe must SEE it.
cat > "${TEST_TMP}/probe.json" <<'JSON'
{"id":"p1","state":"The invoice is overdue.","questions":{"team":{"type":"choice","instructions":"Which team?","criteria":{"billing":"invoices","legal":"contracts","sales":"deals"}}}}
JSON
out="$(fe probe-order --questions "${TEST_TMP}/probe.json" --json)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "probe-order exits 0 against a live gateway"
assert_eq 3 "$(printf '%s' "${out}" | json_get 'd["calls"]')" "a full cycle of a 3-option question = 3 gateway calls"
assert_eq "True" "$(printf '%s' "${out}" | json_get 'd["summary"]["flip_rate"] > 0.5 and d["documents"][0]["questions"][0]["position_share"][0] == 1.0')" "the first-listed-option bias of the backend shows as flips and position-0 share 1.0"
out="$(fe probe-order --questions "${TEST_TMP}/probe.json")"
assert_contains "${out}" "flip rate" "text report prints the flip rate"
assert_contains "${out}" "answer at listing position" "text report prints the per-position bias"
assert_eq 2 "$(rc_of fe probe-order)" "probe-order without --questions -> 2"
assert_eq 2 "$(rc_of fe probe-order --questions "${TEST_TMP}/probe.json" --permute 1)" "probe-order --permute 1 -> 2"
start_gw probe_down notready
assert_eq 6 "$(rc_of fe probe-order --questions "${TEST_TMP}/probe.json" --retries 0)" "probe-order against a not-ready gateway -> 6"
start_gw ok4 uniform

# calibrate: pure computation through the front end; state in a temp dir, never the repo
python3 - "${TEST_TMP}/labels250.csv" "${TEST_TMP}/labels150.csv" <<'PY'
import random, sys
random.seed(7)
for path, n in ((sys.argv[1], 250), (sys.argv[2], 150)):
    with open(path, "w") as f:
        f.write("id,type,p_pred,correct\n")
        for i in range(n):
            p = 0.5 + 0.5 * random.random()
            q = 0.5 + (p - 0.5) * 0.5
            f.write("r%d,noul,%.4f,%d\n" % (i, p, 1 if random.random() < q else 0))
PY
CALSTATE="${TEST_TMP}/calstate"
out="$(LLMCTL_STATE_DIR="${CALSTATE}" fe calibrate --profile decide-tiny --labels "${TEST_TMP}/labels150.csv")" && rc=0 || rc=$?
assert_eq 0 "${rc}" "calibrate below 200 labels exits 0 (a report)"
assert_contains "${out}" "insufficient for ECE" "below 200 labels: the refusal text"
assert_eq "False" "$([[ -e "${CALSTATE}" ]] && echo True || echo False)" "below 200 labels nothing is written"
# T137: the catalog stores no decision.template_hash, so calibrate binds to the hash the GATEWAY computes
# (same function the gateway checks at load); a catalog entry the gateway cannot hash and that names no
# hash still cannot be bound.
cat >"${TEST_TMP}/nohash-catalog.json" <<JSON
{"profiles":{"decide-tiny":{"capability":["decide"],"files":[{"name":"m.gguf","size":1,"sha256":"$(printf 'a%.0s' $(seq 1 64))","role":"model"}],"decision":{"protocol":"future-proto"}}}}
JSON
out="$(LLMCTL_STATE_DIR="${TEST_TMP}/calstate-unres" fe calibrate --profile decide-tiny --labels "${TEST_TMP}/labels250.csv" --catalog "${TEST_TMP}/nohash-catalog.json" --json 2>/dev/null)" && rc=0 || rc=$?
assert_eq 2 "${rc}" "calibrate cannot write a BOUND profile when the template hash cannot be resolved -> 2"
assert_eq "False" "$([[ -e "${TEST_TMP}/calstate-unres/decide/calibration/decide-tiny.json" ]] && echo True || echo False)" "no bound profile written without its bindings"
out="$(LLMCTL_STATE_DIR="${CALSTATE}" fe calibrate --profile decide-tiny --labels "${TEST_TMP}/labels250.csv" --json 2>/dev/null)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "calibrate binds to the computed template hash and the catalog's model sha"
assert_eq "True" "$(json_get 'd["bound"] and len(d["template_hash"]) == 64 and len(d["model_sha256"]) == 64' < "${CALSTATE}/decide/calibration/decide-tiny.json")" "the written profile is bound (64-hex model sha and computed template hash)"
out="$(LLMCTL_STATE_DIR="${CALSTATE}" fe calibrate --profile decide-tiny --labels "${TEST_TMP}/labels250.csv" --model-sha "$(printf 'a%.0s' $(seq 1 64))" --template-hash "$(printf 'b%.0s' $(seq 1 64))" --json)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "calibrate with explicit bindings writes the bound profile"
assert_eq "True" "$(printf '%s' "${out}" | json_get 'd["profile_written"] and d["calibration"]["status"] == "ok" and d["fit"]["after_in_sample"]["ece"] < d["calibration"]["ece"]')" "report says written, ECE measured and improved"
assert_eq "600" "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "${CALSTATE}/decide/calibration/decide-tiny.json")" "profile file mode is 0600"
assert_eq "True" "$(json_get 'd["bound"] and d["n_samples"] == 250 and d["method"] == "temperature"' < "${CALSTATE}/decide/calibration/decide-tiny.json")" "profile content: bound, 250 samples, temperature"
assert_eq 2 "$(rc_of fe calibrate --profile decide-tiny)" "calibrate without --labels -> 2"
assert_eq 2 "$(rc_of fe calibrate --profile decide-tiny --labels "${TEST_TMP}/labels250.csv" --method nope)" "calibrate with an unknown method -> 2"

# completions: generated from the real binary; the script must parse and complete real commands
for sh in bash zsh; do
  assert_eq 0 "$(rc_of fe completions "${sh}")" "completions ${sh} exits 0"
done
assert_eq 2 "$(rc_of fe completions fish)" "completions fish -> 2"
fe completions bash > "${TEST_TMP}/comp.bash"
assert_eq 0 "$(rc_of bash -n "${TEST_TMP}/comp.bash")" "the bash completion script parses"
assert_contains "$(bash -c 'source "$1"; COMP_WORDS=(llmctl-decide c); COMP_CWORD=1; _llmctl_decide_complete; echo "${COMPREPLY[*]}"' _ "${TEST_TMP}/comp.bash")" "calibrate" "bash completion of 'c' offers calibrate"
assert_contains "$(bash -c 'source "$1"; COMP_WORDS=(llmctl-decide calibrate --me); COMP_CWORD=2; _llmctl_decide_complete; echo "${COMPREPLY[*]}"' _ "${TEST_TMP}/comp.bash")" "--method" "bash completion of a flag"
assert_contains "$(bash -c 'source "$1"; COMP_WORDS=(llmctl decide pro); COMP_CWORD=2; _llmctl_decide_complete; echo "${COMPREPLY[*]}"' _ "${TEST_TMP}/comp.bash")" "probe-order" "bash completion through 'llmctl decide'"

echo "== every subcommand the binary registers is reachable through the front end =="
# control: a fake binary that records its argv; the registered list comes from the REAL binary
REG="$("${BIN}" no-such-subcommand 2>&1 | sed -n 's/.*(known: \(.*\)).*/\1/p' | tr -d ",")" || true
assert_contains "${REG}" "calibrate" "the real binary reports its registered subcommands"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "${FAKE_ARGV}"\nexit 0\n' > "${TEST_TMP}/fakebin"; chmod +x "${TEST_TMP}/fakebin"
for w in ${REG}; do
  rm -f "${TEST_TMP}/argv"
  rc=0; FAKE_ARGV="${TEST_TMP}/argv" LLMCTL_DECIDE_BIN="${TEST_TMP}/fakebin" bash -c 'source "$1/lib/common.sh"; source "$1/lib/catalog.sh"; source "$1/lib/decide.sh"; shift; cmd_decide "$@"' _ "${LLMCTL_ROOT}" "${w}" --probe-arg x >/dev/null 2>&1 || rc=$?
  assert_eq "${w} --probe-arg x" "$(cat "${TEST_TMP}/argv" 2>/dev/null || echo NOT-FORWARDED)" "front end forwards '${w}' to the binary with its arguments"
done

test_finish
