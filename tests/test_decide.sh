#!/usr/bin/env bash
# test_decide.sh - the decision front end (lib/decide.sh) at unit level: the post-download smoke path
# through the real Go binary (`llmctl-decide smoke`, exact math computed IN the test with python3), the
# thin delegation to the Go binary (checked with a recording stand-in binary: unit tier, so a stub is
# allowed), the interactive wizard, and the
# capacity/status reports. The real client against a real TLS gateway is tests/test_decide_cli.sh;
# the Go client/gateway logic has its own go tests (internal/client, cmd/llmctl-decide).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/os_detect.sh"
source "${LLMCTL_ROOT}/lib/hardware.sh"
source "${LLMCTL_ROOT}/lib/catalog.sh"
source "${LLMCTL_ROOT}/lib/decide.sh"
source "${LLMCTL_ROOT}/lib/scheduler.sh"

CRITERIA_CHOICE='{"billing":"handles invoices","legal":"contracts"}'

# --- 1-4. the decision smoke path: `llmctl-decide smoke` (the production Go driver) -------------
# Retired with the Python gateway: the shell/Python decide_build_prompt / decide_shape_response /
# decide_options_json / decide_query_logprobs / _decide_opts_part helpers. Their assertions now live
# in Go (prompt template + forged-option neutralisation: internal/contract/prompt_test.go; exact
# renormalised probabilities, noul, score expectation, temperature: internal/gateway/letter_parity_test.go;
# readout filtering: internal/readout) and here, end to end through the real binary against the Go
# fake engine (a stand-in for the MODEL only: HTTP, the prompt, the readout and the validation are real).
if command -v go >/dev/null 2>&1; then
  REALBIN="${TEST_TMP}/bin/llmctl-decide"; FAKE="${TEST_TMP}/bin/fakebackends"
  mkdir -p "${TEST_TMP}/bin"
  ( cd "${LLMCTL_ROOT}" && go build -o "${REALBIN}" ./cmd/llmctl-decide && go build -o "${FAKE}" ./internal/gateway/internal/fakebackends )
  "${FAKE}" -ports-file "${TEST_TMP}/ports" >/dev/null 2>&1 &
  FAKE_PID=$!
  trap 'kill ${FAKE_PID} 2>/dev/null || true' EXIT
  for _ in $(seq 1 50); do [[ -s "${TEST_TMP}/ports" ]] && break; sleep 0.1; done
  LP="$(sed -E 's/llama=([0-9]+) .*/\1/' "${TEST_TMP}/ports")"
  URL="http://127.0.0.1:${LP}"

  out="$("${REALBIN}" smoke --url "${URL}" --protocol letter-logit --options 2 --expect-choice billing --json)" && rc=0 || rc=$?
  assert_eq 0 "${rc}" "smoke (2 options, expect billing) -> rc 0"
  assert_eq "billing" "$(printf '%s' "${out}" | json_stdin 'd["choice"]')" "smoke: typed choice answer is the first option"
  # The fake engine returns A=-0.1 and B..Z=-3.0; expected values are computed here, not hardcoded.
  assert_eq "True" "$(SMOKE_OUT="${out}" python3 - <<'PYEOF'
import json, math, os
d = json.loads(os.environ["SMOKE_OUT"])
e = [math.exp(-0.1), math.exp(-3.0)]
want = [x / sum(e) for x in e]
got = [d["probabilities"]["billing"], d["probabilities"]["legal"]]
print(all(abs(g - w) < 1e-8 for g, w in zip(got, want)) and abs(sum(got) - 1) < 1e-8 and d["ok"] is True)
PYEOF
)" "smoke: exact renormalised probabilities (computed in-test), finite, summing to 1"
  out4="$("${REALBIN}" smoke --url "${URL}" --protocol letter-logit --options 4 --json)" && rc=0 || rc=$?
  assert_eq 0 "${rc}" "smoke --options 4 -> rc 0"
  assert_eq 4 "$(printf '%s' "${out4}" | json_stdin 'len(d["probabilities"])')" "smoke --options 4: four lettered options answered"
  human="$("${REALBIN}" smoke --url "${URL}" --protocol letter-logit)" && rc=0 || rc=$?
  assert_contains "${human}" "smoke ok: protocol=letter-logit choice=billing" "smoke human output names the typed answer"
  "${REALBIN}" smoke --url "${URL}" --protocol letter-logit --expect-choice legal >/dev/null 2>&1 && rc=0 || rc=$?
  assert_eq 1 "${rc}" "smoke with a wrong expected choice -> rc 1 (backend failure, never a false PASS)"
  "${REALBIN}" smoke --url "${URL}" --protocol bogus >/dev/null 2>&1 && rc=0 || rc=$?
  assert_eq 2 "${rc}" "smoke with an unknown protocol -> rc 2"
  "${REALBIN}" smoke --url "http://127.0.0.1:1" --protocol letter-logit >/dev/null 2>&1 && rc=0 || rc=$?
  assert_eq 6 "${rc}" "smoke against a closed port -> rc 6 (unreachable)"
  kill "${FAKE_PID}" 2>/dev/null || true
else
  assert_skip "go is not installed; the smoke path needs the llmctl-decide binary" "decision smoke via llmctl-decide"
fi

# The retired shell/Python helpers must not come back (one implementation per rule, Helix 11.4.251).
for fn in decide_options_json _decide_opts_part decide_build_prompt decide_query_logprobs decide_shape_response; do
  if declare -F "${fn}" >/dev/null 2>&1; then def=1; else def=0; fi
  assert_eq 0 "${def}" "retired helper ${fn} is no longer defined"
done
if [[ -e "${LLMCTL_ROOT}/lib/decide_gateway.py" ]]; then gw=1; else gw=0; fi
assert_eq 0 "${gw}" "lib/decide_gateway.py (retired Python gateway) is gone"


# --- 5. thin delegation: arguments pass through verbatim, exit codes unchanged ---
# A recording stand-in for the Go binary (unit tier). It stores its argv (one per line) and
# its stdin (only when asked to read it: --stdin), prints a canned answer, and exits with $STUB_RC.
STUB="${TEST_TMP}/stub-decide"
cat > "${STUB}" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${STUB_ARGS}"
case " $* " in *" --stdin "*) cat > "${STUB_STDIN}" ;; esac
printf '{"model":"decide-tiny","answers":{"q":{"type":"noul","noul":0.97}}}\n'
exit "${STUB_RC:-0}"
STUBEOF
chmod +x "${STUB}"
export LLMCTL_DECIDE_BIN="${STUB}" STUB_ARGS="${TEST_TMP}/stub.args" STUB_STDIN="${TEST_TMP}/stub.stdin"

out="$(decide_ask --type choice --state-file /some/state.txt --instructions "Which?" --criteria "${CRITERIA_CHOICE}" --json </dev/null)" \
  && rc=0 || rc=$?
assert_eq 0 "${rc}" "decide_ask delegates: exit 0"
assert_contains "${out}" '"noul":0.97' "decide_ask prints the Go client's answer unchanged"
assert_eq "ask|--type|choice|--state-file|/some/state.txt|--instructions|Which?|--criteria|${CRITERIA_CHOICE}|--json" \
  "$(paste -sd'|' "${STUB_ARGS}")" "decide_ask passes subcommand and every flag through verbatim (no flag parsing here)"
for code in 1 2 4 5 6 10; do
  rc=0; STUB_RC="${code}" decide_ask --type noul --state s --instructions q </dev/null >/dev/null 2>&1 || rc=$?
  assert_eq "${code}" "${rc}" "decide_ask returns the client's exit code ${code} unchanged"
done
decide_batch --in x </dev/null >/dev/null; assert_eq "batch|--in|x" "$(paste -sd'|' "${STUB_ARGS}")" "decide_batch delegates"
decide_models --json </dev/null >/dev/null; assert_eq "models|--json" "$(paste -sd'|' "${STUB_ARGS}")" "decide_models delegates"
decide_key path </dev/null >/dev/null; assert_eq "key|path" "$(paste -sd'|' "${STUB_ARGS}")" "decide_key delegates"
decide_cert show </dev/null >/dev/null; assert_eq "cert|show" "$(paste -sd'|' "${STUB_ARGS}")" "decide_cert delegates"
decide_serve --status </dev/null >/dev/null; assert_eq "serve|--status" "$(paste -sd'|' "${STUB_ARGS}")" "decide_serve delegates generically"
out="$(LLMCTL_DRY_RUN=1 decide_serve --foreground --port 9000)"
assert_contains "${out}" "DRY-RUN:" "decide_serve honours LLMCTL_DRY_RUN"
assert_contains "${out}" "serve --foreground --port 9000" "dry-run shows the generic delegation"
cmd_decide calibrate --profile decide-tiny </dev/null >/dev/null; assert_eq "calibrate|--profile|decide-tiny" "$(paste -sd'|' "${STUB_ARGS}")" "cmd_decide delegates the other Go subcommands"
# scale is NOT a Go subcommand: it is handled by the scheduler (tests/test_decide_scale.sh) and must never reach the binary
: > "${STUB_ARGS}"; cmd_decide scale decide-tiny abc </dev/null >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 2 "${rc}" "cmd_decide scale routes to the scheduler (bad N -> rc 2)"
assert_eq "" "$(cat "${STUB_ARGS}")" "cmd_decide scale is not forwarded to the Go binary"
out="$(cmd_decide bogus 2>&1)" && rc=0 || rc=$?
assert_eq 2 "${rc}" "unknown decide subcommand -> rc 2"

# --- 6. the front end never reads the key and never puts state on a command line -----
src="${LLMCTL_ROOT}/lib/decide.sh"
assert_eq "0" "$(grep -v '^[[:space:]]*#' "${src}" | grep -c 'LLMCTL_API_KEY\|LLMCTL_DECIDE_API_KEY\|--api-key' | tr -d ' ')" \
  "lib/decide.sh never touches the access key (the Go client resolves it)"

# --- 7. the binary is located, or the error says what to run -----------------------
out="$(LLMCTL_DECIDE_BIN="${TEST_TMP}/does-not-exist" decide_ask --type noul 2>&1)" && rc=0 || rc=$?
assert_eq 1 "${rc}" "unusable LLMCTL_DECIDE_BIN -> rc 1"
assert_contains "${out}" "LLMCTL_DECIDE_BIN" "unusable LLMCTL_DECIDE_BIN: names the variable"
export LLMCTL_DECIDE_BIN="${STUB}"

# --- 9. interactive wizard: refusal paths + scripted heredoc happy path ------
# Refusal: non-TTY stdin WITHOUT the --interactive flag -> rc 2 (design §2.4).
out="$(decide_interactive 2>&1 </dev/null)" && rc=0 || rc=$?
assert_eq 2 "${rc}" "decide interactive (non-TTY) -> rc 2"
assert_contains "${out}" "interactive mode requires a TTY" "interactive non-TTY refusal message"
out="$(LLMCTL_DECIDE_NO_INTERACTIVE=1 decide_interactive 2>&1 </dev/null)" && rc=0 || rc=$?
assert_eq 2 "${rc}" "decide interactive with LLMCTL_DECIDE_NO_INTERACTIVE=1 -> rc 2"
assert_contains "${out}" "LLMCTL_DECIDE_NO_INTERACTIVE=1" "interactive disabled message"
# NO_INTERACTIVE wins even with the explicit --interactive flag.
out="$(LLMCTL_DECIDE_NO_INTERACTIVE=1 decide_interactive --interactive 2>&1 <<'EOF'
EOF
)" && rc=0 || rc=$?
assert_eq 2 "${rc}" "--interactive flag cannot override LLMCTL_DECIDE_NO_INTERACTIVE=1 -> rc 2"
# End of input at a prompt is rc 2 with a message (N-06), not a silent exit of the caller.
out="$(decide_interactive --interactive --profile decide --type noul --state "s" --instructions "q?" 2>&1 <<'EOF'
EOF
)" && rc=0 || rc=$?
assert_eq 2 "${rc}" "wizard: end of input at a prompt -> rc 2"
assert_contains "${out}" "end of input" "wizard: end of input -> explanatory message"
# Prompts go to stderr via printf, so they are visible with piped stdin (N-09).
assert_contains "${out}" "Description for 'yes'" "wizard: prompt text is emitted with piped stdin"

# `decide ask --interactive` delegates to the wizard (a sanctioned activation path, so piped stdin
# is allowed); with all steps flag-given, the two noul description prompts + the confirmation are
# the only lines consumed (three blank lines), and the SAME client is invoked.
out="$(decide_ask --interactive --profile decide --type noul \
  --state "Arithmetic facts." --instructions "Is 2+2=4?" 2>/dev/null <<'EOF'



EOF
)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "decide ask --interactive (flag activation) -> rc 0"
assert_eq "0.97" "$(printf '%s' "${out}" | json_stdin 'd["answers"]["q"]["noul"]')" "decide ask --interactive: the client's answer is printed"
assert_eq "ask|--type|noul|--instructions|Is 2+2=4?|--stdin|--json|--profile|decide" "$(paste -sd'|' "${STUB_ARGS}")" \
  "wizard calls the client with the state on --stdin, never as an argument"
assert_eq "Arithmetic facts." "$(cat "${STUB_STDIN}")" "wizard sends the state through the client's stdin"

# Happy path: with --interactive the wizard reads a scripted heredoc from (piped, non-TTY) stdin,
# then runs the client. Input order: profile (empty -> gateway default), type, state lines + lone
# '.', instructions, choice criteria 'key = description' lines + empty line, confirmation (empty
# -> Proceed).
wiz_out="$(decide_interactive --interactive 2>/dev/null <<'EOF'

choice
Routing.
.
Which team handles invoices?
billing = handles invoices
legal = contracts


EOF
)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "wizard happy path (scripted heredoc) -> rc 0"
assert_eq 1 "$(printf '%s\n' "${wiz_out}" | wc -l | tr -d ' ')" "wizard stdout is single-line JSON (prompts went to stderr)"
assert_eq "Routing." "$(cat "${STUB_STDIN}")" "wizard happy path: multi-line state read until the lone '.'"
assert_eq "ask|--type|choice|--instructions|Which team handles invoices?|--stdin|--json|--criteria|{\"billing\": \"handles invoices\", \"legal\": \"contracts\"}" \
  "$(paste -sd'|' "${STUB_ARGS}")" "wizard happy path: criteria built in option order, no --profile (gateway default)"
# A client failure surfaces as the wizard's exit code; an abstention (10) still prints the JSON.
rc=0; wiz_fail="$(STUB_RC=4 decide_interactive --interactive --profile decide --type noul --state s --instructions "q?" 2>/dev/null <<'EOF'



EOF
)" || rc=$?
assert_eq 4 "${rc}" "wizard returns the client's exit code (4)"
assert_eq "" "${wiz_fail}" "wizard prints no answer when the client failed"
rc=0; wiz_ab="$(STUB_RC=10 decide_interactive --interactive --profile decide --type noul --state s --instructions "q?" 2>/dev/null <<'EOF'



EOF
)" || rc=$?
assert_eq 10 "${rc}" "wizard returns exit code 10 on abstention"
assert_contains "${wiz_ab}" '"answers"' "wizard prints the withheld answer's JSON on abstention"
# User abort at the confirmation prompt -> rc 0, no JSON on stdout. (noul's two optional
# description prompts come first: two empty lines, then 'n'.)
wiz_abort="$(decide_interactive --interactive --profile decide --type noul \
  --state "s" --instructions "q?" 2>/dev/null <<'EOF'


n
EOF
)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "wizard abort at Proceed? -> rc 0"
assert_eq "" "${wiz_abort}" "wizard abort: no JSON emitted on stdout"

# --- 10. decide capacity / status --------------------------------------------
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
cap_json="$(decide_capacity --json)"
assert_eq "baseline" "$(printf '%s' "${cap_json}" | json_stdin 'd["tier"]')" "decide capacity --json: tier"
# decide-tiny on the baseline fixture: size 504 MiB + KV ceil(4096*4*0.53125/8)
# = 1088 MiB -> gpu per-instance vram 1592; VRAM budget 10444 -> 10444//1592 = 6,
# RAM budget 25904 // 2048 = 12 -> instances_gpu = min(6,12) = 6.
assert_eq 6 "$(printf '%s' "${cap_json}" | json_stdin 'd["decision_instances"]["decide-tiny"]["instances_gpu"]')" \
  "decide capacity --json: decide-tiny gpu instances (10444//1592=6, 25904//2048=12 -> min=6)"
cap_human="$(decide_capacity)"
assert_contains "${cap_human}" "decide-tiny" "decide capacity human: lists decide-tiny"
assert_contains "${cap_human}" "gpu-instances" "decide capacity human: table header"
out="$(decide_capacity --jsno 2>&1)" && rc=0 || rc=$?
assert_eq 2 "${rc}" "decide capacity: unknown argument -> rc 2 (N-07)"

# status --json is {profiles, gateway, registry}; the gateway/registry parts come from the Go
# binary (here: the recording stand-in answers `serve --status`; `discover` yields nothing).
st_json="$(decide_status --json)"
assert_eq "decide" "$(printf '%s' "${st_json}" | json_stdin '[r["profile"] for r in d["profiles"]]' | grep -o 'decide' | head -n1)" \
  "decide status --json: decide profile row present"
assert_eq "False" "$(printf '%s' "${st_json}" | json_stdin '[r["running"] for r in d["profiles"] if r["profile"] == "decide"][0]')" \
  "decide status --json: decide not running in the isolated env"
assert_eq "True" "$(printf '%s' "${st_json}" | json_stdin 'd["gateway"]["available"]')" "decide status --json: gateway part present when the binary exists"
out="$(LLMCTL_DECIDE_BIN="${TEST_TMP}/absent-binary" decide_status --json)"
assert_eq "False" "$(printf '%s' "${out}" | json_stdin 'd["gateway"]["available"]')" "decide status --json: absent binary is tolerated, not an error"
out="$(decide_status --jsno 2>&1)" && rc=0 || rc=$?
assert_eq 2 "${rc}" "decide status: unknown argument -> rc 2 (N-07)"

# --- 11. catalog engine classes (decide-nli is the encoder/onnx class) --------
assert_eq "onnx" "$(catalog_engine decide-nli)" "engine class: decide-nli is an onnx-engine profile"
assert_eq "llama" "$(catalog_engine decide)" "engine class: decide stays llama-engine"
assert_eq "llama" "$(catalog_engine decide-2b)" "engine class: decide-2b is llama-engine"

test_finish
