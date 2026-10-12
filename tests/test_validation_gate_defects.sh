#!/usr/bin/env bash
# test_validation_gate_defects.sh - regression guards for the defects found in the independent review of the
# validation gate (lib/validate.sh, lib/validate_judge.py). One numbered section per defect; each section was
# written RED first (see the commit messages) and is hermetic: fixture OpenAI server only, no model, no
# systemd, no real service.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

LLMCTL="${LLMCTL_ROOT}/bin/llmctl"
FIX="${LLMCTL_ROOT}/tests/fixtures/validation"
VSUITE="${LLMCTL_ROOT}/validation/suites/vision-golden-v1"
CSUITE="${LLMCTL_ROOT}/validation/suites/chat-v1"
KSUITE="${LLMCTL_ROOT}/validation/suites/coder-v1"
JUDGE="${LLMCTL_ROOT}/lib/validate_judge.py"
export LLMCTL_VALIDATE_TIMEOUT=20

# fake_start runs inside $(...), so its PIDs are recorded in a FILE (an array append would die with the subshell);
# the file lives OUTSIDE TEST_TMP because test_finish removes TEST_TMP before the EXIT trap runs.
FAKE_PIDS_FILE="$(mktemp)"
cleanup() {
  local p
  while read -r p; do [[ -n "${p}" ]] && kill "${p}" 2>/dev/null || true; done < "${FAKE_PIDS_FILE}"
  rm -f "${FAKE_PIDS_FILE}"
  test_teardown_env
}
trap cleanup EXIT

fake_start() {
  local answers="$1"; shift
  local pf; pf="$(mktemp -u "${TEST_TMP}/port.XXXXXX")"
  python3 -I "${FIX}/fake_openai.py" --suite "${VSUITE}" --suite "${CSUITE}" --suite "${KSUITE}" \
    --answers "${answers}" --port-file "${pf}" "$@" >/dev/null 2>&1 &
  echo "$!" >> "${FAKE_PIDS_FILE}"
  local i
  for (( i=0; i<100; i++ )); do [[ -s "${pf}" ]] && break; sleep 0.1; done
  printf 'http://127.0.0.1:%s\n' "$(cat "${pf}")"
}
answers_with() {
  local out; out="$(mktemp "${TEST_TMP}/answers.XXXXXX")"
  python3 -I - "${FIX}/answers_good.json" "$1" "$2" "${out}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d[sys.argv[2]] = sys.argv[3]; json.dump(d, open(sys.argv[4], "w"))
PY
  printf '%s\n' "${out}"
}
run_rc() { local rc=0; "$@" >"${TEST_TMP}/last.out" 2>&1 || rc=$?; echo "${rc}"; }
write_run() { printf 'profile=%s\nmode=gpu\nport=%s\nram_mb=1\nvram_mb=1\nstarted_epoch=%s\n' "$1" "$2" "$(date +%s)" > "${LLMCTL_RUNTIME_DIR}/$1.run"; }

echo "== 1. HIGH: a scaled instance key (profile.N) must not abort the post-start hook"
write_run decide 9
write_run decide.2 9
assert_eq 0 "$(run_rc env LLMCTL_VALIDATE_ON_START=1 "${LLMCTL}" validate-after-start decide.2)" \
  "validate-after-start decide.2 does not abort"
out="$(cat "${TEST_TMP}/last.out")"
if [[ "${out}" == *Traceback* || "${out}" == *KeyError* ]]; then
  printf '  FAIL: python traceback leaked into the hook output\n' >&2; TEST_FAILS=$((TEST_FAILS+1))
else printf '  ok: no traceback in hook output\n'; fi
assert_contains "${out}" "scaled instance" "the skip is announced, not silent"
# the judge CLI itself must never traceback on an unknown profile key
assert_eq 2 "$(run_rc python3 -I "${JUDGE}" key --catalog "${LLMCTL_ROOT}/models/catalog.json" --profile decide.2 \
  --models-dir "${LLMCTL_MODELS_DIR}" --suites-dir "${LLMCTL_ROOT}/validation/suites")" "judge key for an unknown profile -> rc 2"
out="$(cat "${TEST_TMP}/last.out")"
if [[ "${out}" == *Traceback* ]]; then printf '  FAIL: traceback from judge key\n' >&2; TEST_FAILS=$((TEST_FAILS+1))
else printf '  ok: judge key prints a message, not a traceback\n'; fi
# a multi-profile hook (the `auto` shape) must still validate the other profile after the instance key
assert_eq 0 "$(run_rc env LLMCTL_VALIDATE_ON_START=1 "${LLMCTL}" validate-after-start decide.2 decide)" \
  "an instance key amongst other keys does not stop the loop"
rm -f "${LLMCTL_RUNTIME_DIR}"/decide*.run

echo "== 5. models verify: a profile with no suite is reported as NOT validated and the usage text says exactly that"
gate() { bash -c 'source "$1/lib/common.sh"; source "$1/lib/catalog.sh"; source "$1/lib/validate.sh"; shift; models_verify_gate "$@"' _ "${LLMCTL_ROOT}" "$@"; }
assert_eq 0 "$(run_rc gate decide)" "no-suite profile: exit 0 (checksum verification is the exit-code contract)"
assert_contains "$(cat "${TEST_TMP}/last.out")" "NOT validated" "...but the output states in words that the profile is NOT validated"
assert_eq 2 "$(run_rc gate decide --live)" "no-suite profile with --live: exit 2"
help_txt="$("${LLMCTL}" help 2>&1 || true)"
assert_contains "${help_txt}" "warns and exits 0 when" "usage text documents the no-suite behaviour"
assert_contains "$(cat "${LLMCTL_ROOT}/docs/user-manual.md")" "names no validation suite" "user manual documents the no-suite behaviour"

echo "== 6. the auto hook validates only the profiles auto STARTED, not every running one"
rm -f "${LLMCTL_RUNTIME_DIR}"/*.run
write_run colibri-qwen36 9; write_run decide 9; write_run decide.2 9     # already running before `auto`
auto_probe() {
  bash -c '
    source "$1/lib/common.sh"; source "$1/lib/catalog.sh"; source "$1/lib/validate.sh"
    sched_auto() { printf "profile=vision\nmode=gpu\nport=9\nram_mb=1\nvram_mb=1\nstarted_epoch=%s\n" "$(date +%s)" > "${LLMCTL_RUNTIME_DIR}/vision.run"; }
    validate_after_start() { echo "HOOK-ARGS: $*"; }
    validate_auto vision
  ' _ "${LLMCTL_ROOT}"
}
out="$(auto_probe 2>&1 || true)"
assert_eq "HOOK-ARGS: vision" "${out}" "only the newly started profile reaches the validation hook"
# an unchanged `auto` (nothing new started) validates nothing
out="$(bash -c '
    source "$1/lib/common.sh"; source "$1/lib/catalog.sh"; source "$1/lib/validate.sh"
    sched_auto() { :; }
    validate_after_start() { echo "HOOK-ARGS: $*"; }
    validate_auto
  ' _ "${LLMCTL_ROOT}" 2>&1 || true)"
assert_eq "HOOK-ARGS: " "${out}" "auto that started nothing hands the hook no profile"
# a profile that was restarted by auto (same key, new started_epoch) IS handed over
out="$(bash -c '
    source "$1/lib/common.sh"; source "$1/lib/catalog.sh"; source "$1/lib/validate.sh"
    sched_auto() { sed -i "s/^started_epoch=.*/started_epoch=1/" "${LLMCTL_RUNTIME_DIR}/decide.run"; }
    validate_after_start() { echo "HOOK-ARGS: $*"; }
    validate_auto
  ' _ "${LLMCTL_ROOT}" 2>&1 || true)"
assert_eq "HOOK-ARGS: decide" "${out}" "a profile auto restarted (new started_epoch) is validated again"
assert_contains "$(grep -n 'auto)' "${LLMCTL_ROOT}/bin/llmctl")" "validate_auto" "bin/llmctl routes auto through validate_auto"
rm -f "${LLMCTL_RUNTIME_DIR}"/*.run

echo "== 7. false FAILs: budget exhaustion / reasoning channel is UNDETERMINED, a wrong answer is still FAIL"
CHATM=/m/fast/Llama-3.1-8B-Instruct-Q4_K_M.gguf
U="$(fake_start "${FIX}/answers_good.json" --mode reasoning-budget --model-id "${CHATM}")"
assert_eq 2 "$(run_rc python3 -I "${JUDGE}" run --suite "${CSUITE}" --endpoint "${U}")" \
  "reasoning model exhausted max_tokens in the reasoning channel (empty content, finish=length) -> exit 2, not FAIL"
assert_contains "$(cat "${TEST_TMP}/last.out")" "reasoning" "the output names the reasoning channel as the cause"
U="$(fake_start "${FIX}/answers_good.json" --mode reasoning-empty-stop --model-id "${CHATM}")"
assert_eq 2 "$(run_rc python3 -I "${JUDGE}" run --suite "${CSUITE}" --endpoint "${U}")" \
  "empty content with reasoning content present (finish=stop) -> exit 2"
U="$(fake_start "${FIX}/answers_good.json" --mode truncate --model-id "${CHATM}")"
assert_eq 2 "$(run_rc python3 -I "${JUDGE}" run --suite "${CSUITE}" --endpoint "${U}")" "finish_reason=length -> exit 2 (budget, not a wrong answer)"
assert_contains "$(cat "${TEST_TMP}/last.out")" "max_tokens" "...and the hint says to raise max_tokens"
# a genuinely wrong answer, and a genuinely empty answer WITHOUT reasoning, stay FAIL
U="$(fake_start "$(answers_with arith 41)" --model-id "${CHATM}")"
assert_eq 1 "$(run_rc python3 -I "${JUDGE}" run --suite "${CSUITE}" --endpoint "${U}")" "wrong answer 41 is still exit 1"
U="$(fake_start "$(answers_with arith '')" --model-id "${CHATM}")"
assert_eq 1 "$(run_rc python3 -I "${JUDGE}" run --suite "${CSUITE}" --endpoint "${U}")" "empty answer with NO reasoning content is still exit 1"
# the request budget leaves room for reasoning models
mt="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["request"]["max_tokens"])' "${CSUITE}/suite.json")"
if (( mt >= 2048 )); then printf '  ok: chat-v1 max_tokens=%s\n' "${mt}"; else printf '  FAIL: chat-v1 max_tokens=%s < 2048\n' "${mt}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi

echo "== 7b. number_equals rule: the number after the LAST '=' when the answer restates the equation, else the FIRST number"
U="$(fake_start "$(answers_with arith '17+25=42')" --model-id "${CHATM}")"
assert_eq 0 "$(run_rc python3 -I "${JUDGE}" run --suite "${CSUITE}" --endpoint "${U}")" "'17+25=42' passes"
U="$(fake_start "$(answers_with arith '17 + 25 = 41')" --model-id "${CHATM}")"
assert_eq 1 "$(run_rc python3 -I "${JUDGE}" run --suite "${CSUITE}" --endpoint "${U}")" "'17 + 25 = 41' still fails"
jt() { python3 -I - "${JUDGE}" "$1" <<'PY'
import importlib.util, sys
sp = importlib.util.spec_from_file_location("vj", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
print(m.judge({"number_equals": 42}, sys.argv[2])[0])
PY
}
assert_eq True  "$(jt '17 + 25 = 42.')" "equation with trailing period passes"
assert_eq True  "$(jt '42')" "bare number passes"
assert_eq True  "$(jt 'Answer: 42')" "first number rule unchanged when no '='"
jt2() { python3 -I - "${JUDGE}" "$1" <<'PY'
import importlib.util, sys
sp = importlib.util.spec_from_file_location("vj", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
print(m.judge({"number_equals": 2}, sys.argv[2])[0])
PY
}
assert_eq False "$(jt2 'twenty-two')" "hyphenated compound 'twenty-two' is not read as the word 'two' (false PASS guard)"
assert_eq True  "$(jt2 'two')" "plain word 'two' still counts"
assert_eq False "$(jt '41, not 42')" "first number 41 fails even though 42 is mentioned later"
assert_eq False "$(jt '17 + 25 = 42 = 41')" "the LAST '=' decides: 41 fails"
assert_eq False "$(jt '17 + 25')" "operands only: first number 17 fails"
assert_eq False "$(jt 'The answer is 41.')" "wrong number fails"

echo "== 8. a record from the future (or with a garbage epoch) is never fresh"
CAT="${LLMCTL_ROOT}/models/catalog.json"
python3 -I "${JUDGE}" key --catalog "${CAT}" --profile vision --models-dir "${LLMCTL_MODELS_DIR}" \
  --suites-dir "${LLMCTL_ROOT}/validation/suites" --engine-tag t > "${TEST_TMP}/key.json"
python3 -I "${JUDGE}" record --key "${TEST_TMP}/key.json" --status pass --out "${TEST_TMP}/state.json"
chk() { run_rc python3 -I "${JUDGE}" check --state "${TEST_TMP}/state.json" --key "${TEST_TMP}/key.json" --max-age 604800; }
assert_eq 0 "$(chk)" "a just-recorded pass is fresh"
set_epoch() { python3 -I - "${TEST_TMP}/state.json" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["epoch"] = json.loads(sys.argv[2]); json.dump(d, open(sys.argv[1], "w"))
PY
}
set_epoch "$(( $(date +%s) + 86400 ))"
assert_eq 1 "$(chk)" "epoch one day in the future -> not fresh"
assert_contains "$(cat "${TEST_TMP}/last.out")" "future" "the reason says the record is from the future"
set_epoch '"banana"'
assert_eq 1 "$(chk)" "non-numeric epoch -> not fresh (no traceback)"
if grep -q Traceback "${TEST_TMP}/last.out"; then printf '  FAIL: traceback on a garbage epoch\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: no traceback\n'; fi
set_epoch 'null'
assert_eq 1 "$(chk)" "null epoch -> not fresh"

echo "== 9. an UNDETERMINED run never overwrites a prior PASS record"
rm -f "${TEST_TMP}/state.json"
rec() { python3 -I "${JUDGE}" record --key "${TEST_TMP}/key.json" --status "$1" --out "${TEST_TMP}/state.json" >"${TEST_TMP}/rec.out" 2>&1; }
st() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "${TEST_TMP}/state.json"; }
rec pass
assert_eq pass "$(st)" "pass recorded"
rec undetermined
assert_eq pass "$(st)" "undetermined run (endpoint down) did not replace the prior pass"
assert_eq 0 "$(chk)" "...so the still-matching pass stays fresh"
rec fail
assert_eq fail "$(st)" "a real FAIL does replace a pass"
rec undetermined
assert_eq undetermined "$(st)" "undetermined may replace a fail (the wrong-answer evidence stays in the evidence log)"
rec pass
assert_eq pass "$(st)" "a new pass replaces anything"
# end to end through validate_profile: a running profile whose endpoint is down must not wipe its PASS
mkdir -p "${LLMCTL_MODELS_DIR}/vision"; : > "${LLMCTL_MODELS_DIR}/vision/gemma-3-4b-it-Q4_K_M.gguf"; : > "${LLMCTL_MODELS_DIR}/vision/mmproj-model-f16.gguf"
U="$(fake_start "${FIX}/answers_good.json" --model-id "${LLMCTL_MODELS_DIR}/vision/gemma-3-4b-it-Q4_K_M.gguf")"
write_run vision "${U##*:}"
assert_eq 0 "$(run_rc "${LLMCTL}" vision validate)" "vision validates against the fixture endpoint"
assert_eq pass "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "${LLMCTL_STATE_DIR}/validation/vision.json")" "state: pass"
sed -i "s/^port=.*/port=9/" "${LLMCTL_RUNTIME_DIR}/vision.run"
assert_eq 2 "$(run_rc "${LLMCTL}" vision validate)" "endpoint down -> exit 2"
assert_eq pass "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "${LLMCTL_STATE_DIR}/validation/vision.json")" "state still pass after the undetermined run"
rm -f "${LLMCTL_RUNTIME_DIR}/vision.run"

echo "== 10. an interrupt (SIGTERM/SIGINT) mid-validation removes the temp key file and stops a profile it started"
mkdir -p "${LLMCTL_MODELS_DIR}/vision" "${TEST_TMP}/tmpd"
U="$(fake_start "${FIX}/answers_good.json" --mode slow --model-id "${LLMCTL_MODELS_DIR}/vision/gemma-3-4b-it-Q4_K_M.gguf")"
SPORT="${U##*:}"
SLOG="${TEST_TMP}/sig.log"
cat > "${TEST_TMP}/sig_driver.sh" <<'DRV'
#!/usr/bin/env bash
# args: llmctl-root port log ; stubs sched_start/sched_stop (no real service, no systemd)
source "$1/lib/common.sh"; source "$1/lib/catalog.sh"; source "$1/lib/validate.sh"
SIG_PORT="$2"; SIG_LOG="$3"
sched_start() {
  echo "START $1" >> "${SIG_LOG}"
  printf 'profile=%s\nmode=gpu\nport=%s\nram_mb=1\nvram_mb=1\nstarted_epoch=%s\n' "$1" "${SIG_PORT}" "$(date +%s)" > "${LLMCTL_RUNTIME_DIR}/$1.run"
}
sched_stop() { echo "STOP $1" >> "${SIG_LOG}"; rm -f "${LLMCTL_RUNTIME_DIR}/$1.run"; }
validate_profile vision
DRV
run_interrupted() {   # $1 = signal name -> prints the driver's exit status
  : > "${SLOG}"; rm -f "${TEST_TMP}/tmpd"/* "${LLMCTL_RUNTIME_DIR}/vision.run"
  TMPDIR="${TEST_TMP}/tmpd" timeout -k 5 40 bash "${TEST_TMP}/sig_driver.sh" "${LLMCTL_ROOT}" "${SPORT}" "${SLOG}" >"${TEST_TMP}/sig.out" 2>&1 &
  local tpid=$! i dpid=""
  for (( i=0; i<100; i++ )); do grep -q "START vision" "${SLOG}" 2>/dev/null && break; sleep 0.1; done
  sleep 1.5                                  # let the judge reach the hung probe
  dpid="$(pgrep -P "${tpid}" -f sig_driver.sh | head -1 || true)"
  kill -"$1" "${dpid:-${tpid}}" 2>/dev/null || true
  local rc=0; wait "${tpid}" || rc=$?
  echo "${rc}"
}
for sig in TERM INT; do
  rc="$(run_interrupted "${sig}")"
  if [[ "${rc}" == "143" || "${rc}" == "130" ]]; then printf '  ok: SIG%s ends validate with a signal exit status (%s)\n' "${sig}" "${rc}"
  else printf '  FAIL: SIG%s exit status %s (124/137 = it hung until the timeout)\n' "${sig}" "${rc}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
  assert_contains "$(cat "${SLOG}")" "STOP vision" "SIG${sig}: the profile validate started is stopped"
  assert_eq "" "$(ls -A "${TEST_TMP}/tmpd")" "SIG${sig}: no temp key file left behind"
  assert_eq "" "$(pgrep -f "validate_judge.py run .*--endpoint http://127.0.0.1:${SPORT}" || true)" "SIG${sig}: the judge child is gone"
  pkill -f "validate_judge.py run .*--endpoint http://127.0.0.1:${SPORT}" 2>/dev/null || true
done

echo "== 11. LLMCTL_VALIDATE_API_KEY is only ever sent to loopback hosts (or an explicit allowlist)"
TOKEN="dummy-validate-token-1234"
AUTHLOG="${TEST_TMP}/auth.log"; : > "${AUTHLOG}"
U="$(fake_start "${FIX}/answers_good.json" --record-auth "${AUTHLOG}" --model-id /m/fast/Llama-3.1-8B-Instruct-Q4_K_M.gguf)"
assert_eq 0 "$(run_rc env LLMCTL_VALIDATE_API_KEY="${TOKEN}" python3 -I "${JUDGE}" run --suite "${CSUITE}" --endpoint "${U}")" "chat suite against the loopback fixture"
assert_contains "$(cat "${AUTHLOG}")" "Bearer ${TOKEN}" "loopback endpoint DOES receive the bearer token"
akey() { python3 -I - "${JUDGE}" "$1" <<'PY'
import importlib.util, os, sys
sp = importlib.util.spec_from_file_location("vj", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
print(m.api_key_for(sys.argv[2]) or "NONE")
PY
}
export LLMCTL_VALIDATE_API_KEY="${TOKEN}"
assert_eq "${TOKEN}" "$(akey http://127.0.0.1:8082)" "127.0.0.1 -> key"
assert_eq "${TOKEN}" "$(akey 'http://[::1]:8082')" "::1 -> key"
assert_eq "${TOKEN}" "$(akey http://localhost:8082/v1)" "localhost -> key"
assert_eq NONE "$(akey http://evil.example.com:8082)" "a foreign hostname -> no key"
assert_eq NONE "$(akey http://203.0.113.9:8082)" "a foreign IP -> no key"
assert_eq NONE "$(akey http://127.0.0.1.evil.example.com:8082)" "a hostname that merely starts with 127.0.0.1 -> no key"
assert_eq NONE "$(akey http://localhost.evil.example.com)" "localhost.<foreign> -> no key"
assert_eq NONE "$(akey http://127.0.0.1@evil.example.com)" "userinfo trickery: the host is evil.example.com, not 127.0.0.1 -> no key"
assert_eq "${TOKEN}" "$(LLMCTL_VALIDATE_API_KEY_HOSTS=gw.lan.example,other akey http://gw.lan.example:8443)" "an explicitly allow-listed host -> key"
assert_eq NONE "$(LLMCTL_VALIDATE_API_KEY_HOSTS=gw.lan.example akey http://gw2.lan.example:8443)" "...only that exact host"
unset LLMCTL_VALIDATE_API_KEY
# a redirect must never be followed (urllib would forward the Authorization header to the Location host)
: > "${AUTHLOG}"; TARGETLOG="${TEST_TMP}/target.log"; : > "${TARGETLOG}"
T="$(fake_start "${FIX}/answers_good.json" --record-auth "${TARGETLOG}" --model-id /m/fast/Llama-3.1-8B-Instruct-Q4_K_M.gguf)"
U="$(fake_start "${FIX}/answers_good.json" --record-auth "${AUTHLOG}" --mode redirect --redirect-to "${T}/v1/chat/completions" --model-id /m/fast/Llama-3.1-8B-Instruct-Q4_K_M.gguf)"
assert_eq 2 "$(run_rc env LLMCTL_VALIDATE_API_KEY="${TOKEN}" python3 -I "${JUDGE}" run --suite "${CSUITE}" --endpoint "${U}")" "a redirecting endpoint -> exit 2"
assert_eq 0 "$(grep -c . "${TARGETLOG}" || true)" "the redirect target received NO request at all (redirect not followed, token not forwarded)"
assert_eq 0 "$(grep -c "${TOKEN}" "${TEST_TMP}/last.out" || true)" "the token is never echoed into the output"

echo "== 12. an http_proxy in the environment never carries loopback validation traffic"
PLOG="${TEST_TMP}/proxy.log"; : > "${PLOG}"; PPF="${TEST_TMP}/proxy.port"
python3 -I - "${PPF}" "${PLOG}" <<'PY' &
import socket, sys, threading, os
srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(5)
open(sys.argv[1] + ".tmp", "w").write(str(srv.getsockname()[1])); os.replace(sys.argv[1] + ".tmp", sys.argv[1])
threading.Timer(120, lambda: os._exit(0)).start()
while True:
    c, _ = srv.accept()
    data = c.recv(65536)
    open(sys.argv[2], "ab").write(data[:200] + b"\n")
    c.close()
PY
echo "$!" >> "${FAKE_PIDS_FILE}"
for (( i=0; i<50; i++ )); do [[ -s "${PPF}" ]] && break; sleep 0.1; done
PPORT="$(cat "${PPF}")"
U="$(fake_start "${FIX}/answers_good.json" --model-id /m/fast/Llama-3.1-8B-Instruct-Q4_K_M.gguf)"
assert_eq 0 "$(run_rc env http_proxy="http://127.0.0.1:${PPORT}" HTTP_PROXY="http://127.0.0.1:${PPORT}" no_proxy= NO_PROXY= LLMCTL_VALIDATE_API_KEY="${TOKEN}" python3 -I "${JUDGE}" run --suite "${CSUITE}" --endpoint "${U}")" "validation passes straight to the loopback endpoint with http_proxy set"
assert_eq 0 "$(wc -c < "${PLOG}")" "the recording proxy received nothing (no prompts, no bearer token)"

echo "== 13. number_equals: a thousands separator or a leading dot is not a decimal point"
assert_eq False "$(jt '42,000')" "'42,000' is not 42"
assert_eq False "$(jt '.42')" "'.42' is not 42"
assert_eq False "$(jt '1,042')" "'1,042' is not 42"
jt10() { python3 -I - "${JUDGE}" "$1" <<'PY'
import importlib.util, sys
sp = importlib.util.spec_from_file_location("vj", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
print(m.judge({"number_equals": 10}, sys.argv[2])[0])
PY
}
assert_eq False "$(jt10 '10,000')" "'10,000' is not 10 (coder-v1 py_output)"
assert_eq True  "$(jt10 '10')" "'10' passes"
assert_eq True  "$(jt10 '10.')" "'10.' (sentence period) passes"
assert_eq True  "$(jt10 '10, then more')" "'10,' followed by a space passes"
assert_eq True  "$(jt '42.0')" "'42.0' equals 42"
assert_eq False "$(jt '41.5')" "'41.5' is not 42"
jt15() { python3 -I - "${JUDGE}" "$1" <<'PY'
import importlib.util, sys
sp = importlib.util.spec_from_file_location("vj", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
print(m.judge({"number_equals": 1.5}, sys.argv[2])[0])
PY
}
assert_eq True  "$(jt15 '1.5')" "'1.5' still passes for 1.5"

test_finish
