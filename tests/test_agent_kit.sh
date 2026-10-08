#!/usr/bin/env bash
# test_agent_kit.sh - the agent integration kit (T102, FR-086): the fail-closed gating hook for Claude Code /
# crush / generic callers, the opencode plugin and the pi extension (run under a stub agent harness), and the
# consumer-side router example - all against a REAL TLS gateway (internal/client/internal/clienttest), a
# TLS stub that answers 529, a wrong key (401), a closed port and fake decision binaries.
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

KIT="${LLMCTL_ROOT}/templates/agents"; FX="${LLMCTL_ROOT}/tests/fixtures/agents"
BIN="${TEST_TMP}/bin/llmctl-decide"; CT="${TEST_TMP}/bin/clienttest"
mkdir -p "${TEST_TMP}/bin"
( cd "${LLMCTL_ROOT}" && go build -o "${BIN}" ./cmd/llmctl-decide && go build -o "${CT}" ./internal/client/internal/clienttest )
unset LLMCTL_API_KEY LLMCTL_ENDPOINT LLMCTL_CACERT LLMCTL_HOME LLMCTL_DECIDE_PORT LLMCTL_DECIDE_TIMEOUT LLMCTL_ENV_FILE HTTPS_PROXY https_proxy \
      LLMCTL_HOOK_ON_ERROR LLMCTL_HOOK_ON_SAFE LLMCTL_HOOK_MIN_CONFIDENCE LLMCTL_HOOK_QUESTION_FILE
export LLMCTL_ROOT LLMCTL_DECIDE_BIN="${BIN}"

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

# sc VAR=val ... -- cmd args: run cmd in THIS shell with the variables exported, then restore them
# (a ( ... ) subshell would lose the assertion failure counter).
sc() {
  local -a names=() olds=() had=()
  while [[ "$1" != "--" ]]; do
    local n="${1%%=*}"; names+=("${n}")
    if [[ -n "${!n+x}" ]]; then had+=(1); olds+=("${!n}"); else had+=(0); olds+=(""); fi
    declare -gx "$1"; shift
  done
  shift
  local rc=0; "$@" || rc=$?
  local i
  for i in "${!names[@]}"; do
    if [[ "${had[$i]}" == 1 ]]; then export "${names[$i]}=${olds[$i]}"; else unset "${names[$i]}"; fi
  done
  return "${rc}"
}
use_gw() { export LLMCTL_HOME="${GW_HOME}" LLMCTL_ENV_FILE="${GW_ENV}" LLMCTL_ENDPOINT="${GW_URL}" LLMCTL_CACERT="${GW_HOME}/cert/ca/ca.crt"; }

start_gw ok uniform;      OK_URL="${GW_URL}"; OK_HOME="${GW_HOME}"; OK_ENV="${GW_ENV}"; OK_KEY="${GW_KEY}"
start_gw notready notready; NR_URL="${GW_URL}"; NR_HOME="${GW_HOME}"; NR_ENV="${GW_ENV}"
start_gw readout readout;   RO_URL="${GW_URL}"; RO_HOME="${GW_HOME}"; RO_ENV="${GW_ENV}"
# 529 stub, TLS-signed by the ok gateway's CA
mkfifo "${TEST_TMP}/stub.in"; eval "exec 9<>\"${TEST_TMP}/stub.in\""
chain="$(find "${OK_HOME}"/cert -name chain.pem | head -n1)"; leafkey="$(find "${OK_HOME}"/cert -name leaf.key | head -n1)"
python3 "${FX}/status_stub.py" "${chain}" "${leafkey}" 529 <"${TEST_TMP}/stub.in" >"${TEST_TMP}/stub.out" &
GW_PIDS+=("$!")
for _ in $(seq 1 100); do grep -q '^READY ' "${TEST_TMP}/stub.out" 2>/dev/null && break; sleep 0.1; done
S529_URL="$(sed -n 's/^READY //p' "${TEST_TMP}/stub.out" | head -n1)"

use_ok() { GW_URL="${OK_URL}" GW_HOME="${OK_HOME}" GW_ENV="${OK_ENV}"; use_gw; }
use_ok

HOOK="${KIT}/llmctl-gate-hook.sh"
# run_hook <agent> <stdin-json> -> HOOK_OUT HOOK_ERR HOOK_RC (env of the caller applies)
run_hook() {
  HOOK_RC=0
  HOOK_OUT="$(printf '%s' "$2" | bash "${HOOK}" --agent "$1" 2>"${TEST_TMP}/hook.err")" || HOOK_RC=$?
  HOOK_ERR="$(cat "${TEST_TMP}/hook.err")"
}
jget() { python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(eval(sys.argv[1]))' "$1"; }

BASH_CALL='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf ./build"},"cwd":"/tmp","session_id":"s1"}'
python3 - "${TEST_TMP}/block_first.json" <<'PY'
import json, sys
q = {"type": "choice", "instructions": "Should this tool call be blocked?", "criteria": {"block": "destructive", "review": "needs a human", "allow": "safe"}}
json.dump(q, open(sys.argv[1], "w"))
PY
BLOCKQ="${TEST_TMP}/block_first.json"

echo "== claude-code PreToolUse: decisions =="
LLMCTL_HOOK_MIN_CONFIDENCE=0 run_hook claude-code "${BASH_CALL}"
assert_eq 0 "${HOOK_RC}" "safe answer: exit 0"
assert_eq "" "${HOOK_OUT}" "safe answer: no decision printed (normal permission flow)"
LLMCTL_HOOK_MIN_CONFIDENCE=0 LLMCTL_HOOK_ON_SAFE=allow run_hook claude-code "${BASH_CALL}"
assert_eq "allow" "$(printf '%s' "${HOOK_OUT}" | jget 'd["hookSpecificOutput"]["permissionDecision"]')" "ON_SAFE=allow: explicit allow"
assert_eq "PreToolUse" "$(printf '%s' "${HOOK_OUT}" | jget 'd["hookSpecificOutput"]["hookEventName"]')" "allow names the event"
LLMCTL_HOOK_MIN_CONFIDENCE=0 LLMCTL_HOOK_QUESTION_FILE="${BLOCKQ}" run_hook claude-code "${BASH_CALL}"
assert_eq 2 "${HOOK_RC}" "block answer: exit 2 (blocks the tool call)"
assert_contains "${HOOK_ERR}" "block" "block answer: reason on stderr"
run_hook claude-code "${BASH_CALL}"
assert_eq 0 "${HOOK_RC}" "low confidence: exit 0 with an ask decision"
assert_eq "ask" "$(printf '%s' "${HOOK_OUT}" | jget 'd["hookSpecificOutput"]["permissionDecision"]')" "low confidence escalates to the human (ask)"
assert_contains "${HOOK_OUT}" "confidence" "the escalation reason names the confidence"

echo "== claude-code: fail closed on every failure =="
fc() { # fc <label> -- expects an "ask" decision (rc 0) from the current env
  run_hook claude-code "${BASH_CALL}"
  assert_eq "ask" "$(printf '%s' "${HOOK_OUT}" | jget 'd["hookSpecificOutput"]["permissionDecision"]' 2>/dev/null || echo "NOJSON rc=${HOOK_RC}")" "$1: escalates (ask), never allows"
}
sc LLMCTL_ENDPOINT=https://127.0.0.1:1 -- fc "gateway down"
sc LLMCTL_API_KEY="llmctl_wrong_key_for_the_test_0000000000000000" -- fc "wrong key (401)"
sc LLMCTL_ENDPOINT="${S529_URL}" -- fc "overloaded (529)"
sc LLMCTL_ENDPOINT="${NR_URL}" LLMCTL_HOME="${NR_HOME}" LLMCTL_ENV_FILE="${NR_ENV}" LLMCTL_CACERT="${NR_HOME}/cert/ca/ca.crt" -- fc "not ready (503)"
sc LLMCTL_ENDPOINT="${RO_URL}" LLMCTL_HOME="${RO_HOME}" LLMCTL_ENV_FILE="${RO_ENV}" LLMCTL_CACERT="${RO_HOME}/cert/ca/ca.crt" -- fc "readout failure (422)"
sc LLMCTL_CACERT=/nonexistent/ca.crt -- fc "unreadable CA"
sc LLMCTL_DECIDE_BIN=/nonexistent/llmctl-decide -- fc "decision binary missing"
for m in garbage noconf nochoice crash abstain surprise lowconf; do
  sc LLMCTL_DECIDE_BIN="${FX}/bad_decide.sh" BAD_DECIDE_MODE="${m}" -- fc "bad decision binary (${m})"
done
sc LLMCTL_DECIDE_BIN="${FX}/bad_decide.sh" BAD_DECIDE_MODE=hang LLMCTL_HOOK_TIMEOUT=1 -- fc "hung decision binary (timeout)"
HOOK_RC=0; HOOK_OUT="$(printf '%s' 'not json at all' | bash "${HOOK}" --agent claude-code 2>/dev/null)" || HOOK_RC=$?
assert_eq "ask" "$(printf '%s' "${HOOK_OUT}" | jget 'd["hookSpecificOutput"]["permissionDecision"]')" "garbage on stdin: escalates"
HOOK_RC=0; HOOK_OUT="$(printf '' | bash "${HOOK}" --agent claude-code 2>/dev/null)" || HOOK_RC=$?
assert_eq "ask" "$(printf '%s' "${HOOK_OUT}" | jget 'd["hookSpecificOutput"]["permissionDecision"]')" "empty stdin: escalates"
sc LLMCTL_ENDPOINT=https://127.0.0.1:1 LLMCTL_HOOK_ON_ERROR=deny -- run_hook claude-code "${BASH_CALL}"; assert_eq 2 "${HOOK_RC}" "ON_ERROR=deny: exit 2"
sc LLMCTL_ENDPOINT=https://127.0.0.1:1 LLMCTL_HOOK_ON_ERROR=allow -- run_hook claude-code "${BASH_CALL}"
  assert_eq 0 "${HOOK_RC}" "ON_ERROR=allow (explicit fail-open): exit 0"; assert_eq "" "${HOOK_OUT}" "ON_ERROR=allow: no deny/ask printed"
sc LLMCTL_ENDPOINT=https://127.0.0.1:1 LLMCTL_HOOK_ON_ERROR=bogus -- run_hook claude-code "${BASH_CALL}"; assert_eq 2 "${HOOK_RC}" "unknown ON_ERROR value fails closed (exit 2)"
# python3 missing: the wrapper must still block (exit 2), not fall through with an error code Claude Code ignores
HOOK_RC=0; printf '%s' "${BASH_CALL}" | env PATH="${TEST_TMP}/emptybin" "$(command -v bash)" "${HOOK}" --agent claude-code >/dev/null 2>"${TEST_TMP}/hook.err" || HOOK_RC=$?
assert_eq 2 "${HOOK_RC}" "python3 missing: wrapper blocks with exit 2"
HOOK_RC=0; printf '%s' "${BASH_CALL}" | bash "${HOOK}" --agent nonsense >/dev/null 2>&1 || HOOK_RC=$?
assert_eq 2 "${HOOK_RC}" "unknown --agent: blocks with exit 2"

echo "== entry points and config templates =="
for ep in claude-code-pretool.sh:claude-code claude-code-prompt.sh:claude-code-prompt crush-pretool.sh:crush; do
  f="${ep%%:*}"; ag="${ep##*:}"
  case "${ag}" in claude-code) ev="${BASH_CALL}" ;; claude-code-prompt) ev='{"hook_event_name":"UserPromptSubmit","prompt":"hi"}' ;; crush) ev='{"event":"PreToolUse","tool_name":"bash","tool_input":{"command":"ls"}}' ;; esac
  HOOK_RC=0; HOOK_OUT="$(printf '%s' "${ev}" | LLMCTL_HOOK_MIN_CONFIDENCE=0 LLMCTL_HOOK_QUESTION_FILE="${BLOCKQ}" bash "${KIT}/${f}" 2>/dev/null)" || HOOK_RC=$?
  assert_eq 2 "${HOOK_RC}" "${f}: a block answer exits 2 through the entry point"
done
for t in claude-code.settings.json crush.hooks.json routes.example.json question.json; do
  assert_eq "True" "$(python3 -c 'import json,sys; json.load(open(sys.argv[1])); print(True)' "${KIT}/${t}" 2>/dev/null || echo False)" "${t} is valid JSON"
done
for t in claude-code.settings.json crush.hooks.json; do
  cmdbase="$(python3 -c 'import json,sys,os; d=json.load(open(sys.argv[1])); c=d["hooks"]["PreToolUse"][0]; c=c.get("command") or c["hooks"][0]["command"]; print(os.path.basename(c))' "${KIT}/${t}")"
  assert_file_exists "${KIT}/${cmdbase}" "${t} points at an entry script the kit ships (${cmdbase})"
  if [[ -x "${KIT}/${cmdbase}" ]]; then assert_eq 1 1 "${cmdbase} is executable"; else assert_eq executable not "${cmdbase} is executable"; fi
done
assert_eq "True" "$(python3 -c 'import json,sys; q=json.load(open(sys.argv[1])); print(list(q["criteria"])==["allow","review","block"] and q["type"]=="choice")' "${KIT}/question.json")" "question.json is a choice question over allow/review/block"

echo "== no secret leaves the hook =="
assert_eq "False" "$([[ "${HOOK_OUT}${HOOK_ERR}$(cat "${TEST_TMP}/hook.err")" == *"${OK_KEY}"* ]] && echo True || echo False)" "the access key is not on stdout/stderr"
LLMCTL_HOOK_MIN_CONFIDENCE=0 run_hook claude-code "${BASH_CALL}"
assert_eq "False" "$([[ "${HOOK_OUT}${HOOK_ERR}" == *"${OK_KEY}"* ]] && echo True || echo False)" "the access key is not in a normal run either"

echo "== claude-code UserPromptSubmit =="
PROMPT_CALL='{"hook_event_name":"UserPromptSubmit","prompt":"delete everything in /","cwd":"/tmp"}'
LLMCTL_HOOK_MIN_CONFIDENCE=0 run_hook claude-code-prompt "${PROMPT_CALL}"
assert_eq 0 "${HOOK_RC}" "prompt: safe answer passes"
LLMCTL_HOOK_MIN_CONFIDENCE=0 LLMCTL_HOOK_QUESTION_FILE="${BLOCKQ}" run_hook claude-code-prompt "${PROMPT_CALL}"
assert_eq 2 "${HOOK_RC}" "prompt: block answer exits 2"
sc LLMCTL_ENDPOINT=https://127.0.0.1:1 -- run_hook claude-code-prompt "${PROMPT_CALL}"; assert_eq 2 "${HOOK_RC}" "prompt: gateway down blocks (fail closed)"

echo "== crush PreToolUse =="
CRUSH_CALL='{"event":"PreToolUse","tool_name":"bash","tool_input":{"command":"rm -rf ./build"},"cwd":"/tmp","session_id":"c1"}'
LLMCTL_HOOK_MIN_CONFIDENCE=0 run_hook crush "${CRUSH_CALL}"
assert_eq 0 "${HOOK_RC}" "crush: safe answer exits 0"
assert_eq "" "${HOOK_OUT}" "crush: safe answer prints nothing (falls through to the normal permission flow)"
LLMCTL_HOOK_MIN_CONFIDENCE=0 LLMCTL_HOOK_ON_SAFE=allow run_hook crush "${CRUSH_CALL}"
assert_eq "allow" "$(printf '%s' "${HOOK_OUT}" | jget 'd["decision"]')" "crush: ON_SAFE=allow prints the allow envelope"
LLMCTL_HOOK_MIN_CONFIDENCE=0 LLMCTL_HOOK_QUESTION_FILE="${BLOCKQ}" run_hook crush "${CRUSH_CALL}"
assert_eq 2 "${HOOK_RC}" "crush: block answer exits 2"
assert_contains "${HOOK_ERR}" "block" "crush: reason on stderr"
run_hook crush "${CRUSH_CALL}"
assert_eq 2 "${HOOK_RC}" "crush: low confidence is a deny (crush has no ask; fall-through would auto-approve under --yolo)"
sc LLMCTL_ENDPOINT=https://127.0.0.1:1 -- run_hook crush "${CRUSH_CALL}"; assert_eq 2 "${HOOK_RC}" "crush: gateway down denies"
sc LLMCTL_ENDPOINT="${S529_URL}" -- run_hook crush "${CRUSH_CALL}"; assert_eq 2 "${HOOK_RC}" "crush: 529 denies"
sc LLMCTL_ENDPOINT=https://127.0.0.1:1 LLMCTL_HOOK_ON_ERROR=allow -- run_hook crush "${CRUSH_CALL}"; assert_eq 0 "${HOOK_RC}" "crush: explicit fail-open exits 0"

echo "== generic caller (used by the opencode plugin and the pi extension) =="
GEN_CALL='{"tool_name":"bash","tool_input":{"command":"ls"}}'
LLMCTL_HOOK_MIN_CONFIDENCE=0 run_hook generic "${GEN_CALL}"
assert_eq "ALLOW" "${HOOK_OUT%%$'\t'*}" "generic: ALLOW"
LLMCTL_HOOK_MIN_CONFIDENCE=0 LLMCTL_HOOK_QUESTION_FILE="${BLOCKQ}" run_hook generic "${GEN_CALL}"
assert_eq "DENY" "${HOOK_OUT%%$'\t'*}" "generic: DENY"
run_hook generic "${GEN_CALL}"
assert_eq "ESCALATE" "${HOOK_OUT%%$'\t'*}" "generic: ESCALATE on low confidence"
sc LLMCTL_ENDPOINT=https://127.0.0.1:1 -- run_hook generic "${GEN_CALL}"; assert_eq "ESCALATE" "${HOOK_OUT%%$'\t'*}" "generic: gateway down escalates"
sc LLMCTL_ENDPOINT=https://127.0.0.1:1 LLMCTL_HOOK_ON_ERROR=allow -- run_hook generic "${GEN_CALL}"; assert_eq "ALLOW" "${HOOK_OUT%%$'\t'*}" "generic: explicit fail-open ALLOW"

echo "== opencode plugin and pi extension under a stub agent harness =="
if command -v node >/dev/null 2>&1; then
  export LLMCTL_GATE_HOOK="${HOOK}" HARNESS_BLOCKQ="${BLOCKQ}"
  nout="$(node "${FX}/agent_harness.mjs" "${KIT}/opencode-plugin.js" "${KIT}/pi-extension.ts" 2>&1)" && nrc=0 || nrc=$?
  assert_eq 0 "${nrc}" "node harness exits 0"
  printf '%s\n' "${nout}" | sed 's/^/    /'
  assert_contains "${nout}" "HARNESS-DONE" "harness ran to completion"
  assert_eq "False" "$([[ "${nout}" == *"HARNESS-FAIL"* ]] && echo True || echo False)" "no harness expectation failed"
else
  assert_skip "node not installed" "opencode plugin / pi extension harness"
fi

echo "== consumer-side router (fixes the Jev.md J3-038 / J3-058 snippets) =="
ROUTES="${TEST_TMP}/routes.json"
python3 - "${ROUTES}" <<'PY'
import json, sys
json.dump({"routes": {
  "tool_selection_small": {"model": "decide-tiny", "min_confidence": 0.0, "max_labels": 5, "fallback": "tool_selection_large"},
  "tool_selection_large": {"model": "decide-tiny", "min_confidence": 0.0, "fallback": "escalate"},
  "tool_selection": {"switch": {"label_count_over": 5, "to": "tool_selection_large"}, "to": "tool_selection_small"},
  "strict": {"model": "decide-tiny", "min_confidence": 0.99, "fallback": "deny"},
  "strict_chain": {"model": "decide-tiny", "min_confidence": 0.99, "fallback": "strict_chain2"},
  "strict_chain2": {"model": "decide-tiny", "min_confidence": 0.99, "fallback": "strict_chain"},
  "dangling": {"model": "decide-tiny", "min_confidence": 0.99, "fallback": "nope"},
  "no_model": {"min_confidence": 0.0, "fallback": "escalate"}}}, open(sys.argv[1], "w"))
PY
rout="$(LLMCTL_ENDPOINT="${OK_URL}" LLMCTL_CACERT="${OK_HOME}/cert/ca/ca.crt" LLMCTL_API_KEY="${OK_KEY}" \
        S529_URL="${S529_URL}" ROUTER="${KIT}/router.py" ROUTES="${ROUTES}" OK_ENV="${OK_ENV}" DEAD_URL=https://127.0.0.1:1 \
        python3 "${FX}/router_driver.py" 2>&1)" && rrc=0 || rrc=$?
assert_eq 0 "${rrc}" "router driver exits 0"
printf '%s\n' "${rout}" | sed 's/^/    /'
assert_contains "${rout}" "ROUTER-DONE" "router driver ran to completion"
assert_eq "False" "$([[ "${rout}" == *"ROUTER-FAIL"* ]] && echo True || echo False)" "no router expectation failed"
assert_eq "False" "$([[ "${rout}" == *"${OK_KEY}"* ]] && echo True || echo False)" "the router never prints the key"

echo "== docs record the measured live-exercise facts (T101, evidence/agents/AGENTS-REPORT.md) =="
DOCS="${LLMCTL_ROOT}/docs/agents"
assert_file_contains "${DOCS}/README.md" "## Driving models" "README has the driving-model section"
assert_file_contains "${DOCS}/README.md" "weak driver" "README says a weak driver may not issue the call"
assert_file_contains "${DOCS}/README.md" "--question-file question.json --state" "README shows the quote-light call form for weak drivers"
assert_file_contains "${DOCS}/opencode.md" "isolated HOME" "opencode page: isolate HOME so operator skills are not loaded"
assert_file_contains "${DOCS}/opencode.md" "timeout" "opencode page: bound a headless run (no step limit)"
assert_file_contains "${DOCS}/crush.md" "alternate" "crush page: roles-must-alternate template rejection"
assert_file_contains "${DOCS}/claude-code.md" "--model haiku" "claude page: cheapest-model live form"
test_finish
