#!/usr/bin/env bash
# test_vision_validate.sh - `llmctl vision validate` / `llmctl validate` / `validate-all` /
# `require-validated` and the deterministic judge, hermetically, against a FIXTURE OpenAI-compatible server
# (tests/fixtures/validation/fake_openai.py - an answer table, never a model). Every mutation of the judge,
# the expectations, the fixtures or the model answer MUST turn the verdict RED; a validator that passes
# everything is a bluff. The live run against the real model is documented separately
# (docs/qa/vision-validate-live-2026-10-12.md).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

LLMCTL="${LLMCTL_ROOT}/bin/llmctl"
FIX="${LLMCTL_ROOT}/tests/fixtures/validation"
VSUITE="${LLMCTL_ROOT}/validation/suites/vision-golden-v1"
CSUITE="${LLMCTL_ROOT}/validation/suites/chat-v1"
KSUITE="${LLMCTL_ROOT}/validation/suites/coder-v1"
ESUITE="${LLMCTL_ROOT}/validation/suites/embedding-v1"
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

# fake_start <answers.json> [extra fake_openai args...] -> prints the base URL
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

# answers_with <key> <answer> -> path of a copy of answers_good.json with one answer replaced
answers_with() {
  local out; out="$(mktemp "${TEST_TMP}/answers.XXXXXX")"
  python3 -I - "${FIX}/answers_good.json" "$1" "$2" "${out}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d[sys.argv[2]] = sys.argv[3]; json.dump(d, open(sys.argv[4], "w"))
PY
  printf '%s\n' "${out}"
}

run_rc() { local rc=0; "$@" >"${TEST_TMP}/last.out" 2>&1 || rc=$?; echo "${rc}"; }

echo "== 1. judge self-tests: every suite's canned controls are judged as required"
for s in "${VSUITE}" "${CSUITE}" "${KSUITE}"; do
  assert_eq 0 "$(run_rc python3 -I "${JUDGE}" selftest --suite "${s}")" "judge self-test green for $(basename "${s}")"
done

echo "== 2. GREEN baseline: correct answers -> exit 0, every probe PASS, controls discriminate"
URL="$(fake_start "${FIX}/answers_good.json" --model-id /m/vision/gemma-3-4b-it-Q4_K_M.gguf)"
rc="$(run_rc "${LLMCTL}" vision validate --profile vision --host "${URL}")"
out="$(cat "${TEST_TMP}/last.out")"
printf '%s\n' "${out}" | sed 's/^/    | /' | head -60
assert_eq 0 "${rc}" "vision validate exits 0 when every answer is right"
assert_contains "${out}" "VERDICT: PASS pass=38 fail=0 undetermined=0" "38 checks pass (18 probes + 2 controls + 18 determinism checks: every probe asked 3 times)"
assert_contains "${out}" "[PASS] determinism 05_table/lookup: repeat=3 byte-identical" "every probe is repeated (N=3), not only the suite's determinism probe"
assert_contains "$(LLMCTL_VALIDATE_REPEAT=1 "${LLMCTL}" vision validate --profile vision --host "${URL}" 2>&1 || true)" \
  "VERDICT: PASS pass=21 fail=0 undetermined=0" "quick mode (LLMCTL_VALIDATE_REPEAT=1): 18 probes + 2 controls + 1 determinism repeat"
assert_contains "${out}" "[PASS] control 90_bad_blank vs 01_text_large/read" "blank control discriminated"
assert_contains "${out}" "[PASS] control 91_bad_wrong_content vs 01_text_large/read" "wrong-content control discriminated"
assert_contains "${out}" 'answer: "ORANGE TIGER\n42"' "the raw model answer is printed next to the verdict"
assert_contains "${out}" "--host: external endpoint" "an external endpoint never writes the local validation state"
assert_file_absent "${LLMCTL_STATE_DIR}/validation/vision.json" "no state record from a --host run"

json_out="$("${LLMCTL}" vision validate --profile vision --host "${URL}" --json 2>/dev/null || true)"
verdict="$(printf '%s' "${json_out}" | python3 -c 'import json,sys
t=sys.stdin.read(); i=t.index("{"); d=json.loads(t[i:]); print(d["verdict"], d["exit_code"], len(d["results"]), len(d["controls"]))' 2>&1 || true)"
assert_eq "PASS 0 18 2" "${verdict}" "--json reports verdict, exit code, 18 probe results and 2 controls"

echo "== 3. MUTATION: model answer wrong -> exit 1 (never excused)"
for mut in "02_shapes_count/red_circles=4" "04_list_view/items=BANANA APPLE CHERRY GRAPE" \
           "08_small_text/invoice=7781" "07_dark_theme/theme=Light" "01_text_large/read="; do
  key="${mut%%=*}"; val="${mut#*=}"
  U="$(fake_start "$(answers_with "${key}" "${val}")" --model-id /m/vision/gemma-3-4b-it-Q4_K_M.gguf)"
  assert_eq 1 "$(run_rc "${LLMCTL}" vision validate --host "${U}")" "wrong answer for ${key} ('${val}') -> exit 1"
  assert_contains "$(cat "${TEST_TMP}/last.out")" "[FAIL] ${key}" "the failing probe ${key} is named"
done

echo "== 4. MUTATION: golden-bad control hallucinated as golden content -> exit 1"
U="$(fake_start "$(answers_with "90_bad_blank/read" "ORANGE TIGER 42")" --model-id /m/vision/gemma-3-4b-it-Q4_K_M.gguf)"
assert_eq 1 "$(run_rc "${LLMCTL}" vision validate --host "${U}")" "blank image answered with the golden text -> exit 1"
assert_contains "$(cat "${TEST_TMP}/last.out")" "[FAIL] control 90_bad_blank vs 01_text_large/read" "undiscriminated control is reported"

echo "== 5. MUTATION: the judge itself is broken -> exit 1 before any request"
JM="${TEST_TMP}/judge_mut"; mkdir -p "${JM}"
sed 's/    return (not reasons), reasons/    return True, reasons/' "${JUDGE}" > "${JM}/validate_judge.py"
assert_eq 1 "$(grep -c 'return True, reasons' "${JM}/validate_judge.py")" "mutant judge really differs (always-PASS)"
assert_eq 1 "$(run_rc python3 -I "${JM}/validate_judge.py" run --suite "${VSUITE}" --endpoint "${URL}")" "always-PASS judge -> exit 1"
assert_contains "$(cat "${TEST_TMP}/last.out")" "the judge itself is broken" "always-PASS judge refused by its self-test"
sed 's/^    return any(not neg for _, neg in claim_occurrences(raw, needle))$/    return True/' "${JUDGE}" > "${JM}/validate_judge.py"
assert_eq 1 "$(grep -c '^    return True$' "${JM}/validate_judge.py")" "mutant judge really differs (every needle counts as asserted)"
assert_eq 1 "$(run_rc python3 -I "${JM}/validate_judge.py" run --suite "${VSUITE}" --endpoint "${URL}")" "always-match substring judge -> exit 1"
sed 's/^    occ.sort()$/    pass/' "${JUDGE}" > "${JM}/validate_judge.py"
assert_eq 1 "$(grep -c '^    pass$' "${JM}/validate_judge.py")" "mutant judge really differs (occurrences no longer sorted by position: order-blind)"
assert_eq 1 "$(run_rc python3 -I "${JM}/validate_judge.py" selftest --suite "${VSUITE}")" "order-blind judge fails its self-test"
# Isolate the golden-bad discrimination layer: a LAX golden expectation (passes "NO TEXT" / "PURPLE ...")
# with its canned judge controls removed. Only the control images can expose it.
LAX="${TEST_TMP}/suite_lax"; cp -r "${VSUITE}" "${LAX}"
python3 -I - "${LAX}/expectations.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["fixtures"][0]["probes"][0]["checks"] = {"contains_any": ["ORANGE", "PURPLE", "NO TEXT"]}
# canned controls the LAX expectation satisfies (every probe must keep a PASS and a FAIL control, or the suite is a defect)
d["judge_controls"] = [c for c in d["judge_controls"] if c["probe"] != "01_text_large/read"] + [
    {"probe": "01_text_large/read", "answer": "ORANGE TIGER 42", "expect": "pass"},
    {"probe": "01_text_large/read", "answer": "ELEPHANT", "expect": "fail"}]
json.dump(d, open(p, "w"))
PY
assert_eq 1 "$(run_rc python3 -I "${JUDGE}" run --suite "${LAX}" --endpoint "${URL}")" "lax golden expectation exposed by the golden-bad controls -> exit 1"
assert_contains "$(cat "${TEST_TMP}/last.out")" "[FAIL] control 90_bad_blank vs 01_text_large/read" "blank control reports the non-discriminating expectation"
sed 's/            if golden_ok:/            if False:/' "${JUDGE}" > "${JM}/validate_judge.py"
assert_eq 0 "$(run_rc python3 -I "${JM}/validate_judge.py" run --suite "${LAX}" --endpoint "${URL}")" \
  "control-blind mutant judge + lax expectation -> exit 0 (proves the control layer is what catches it)"

echo "== 6. MUTATION: expectations / fixtures changed -> RED"
SM="${TEST_TMP}/suite_mut"; cp -r "${VSUITE}" "${SM}"
python3 -I - "${SM}/expectations.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
for fx in d["fixtures"]:
    for pr in fx["probes"]:
        if fx["id"] == "02_shapes_count" and pr["id"] == "red_circles":
            pr["checks"]["number_equals"] = 4
json.dump(d, open(p, "w"))
PY
assert_eq 1 "$(run_rc python3 -I "${JUDGE}" run --suite "${SM}" --endpoint "${URL}")" "expected count mutated 3->4 -> exit 1"
cp -r "${VSUITE}/." "${SM}/"
printf '\0' | dd of="${SM}/01_text_large.png" bs=1 seek=200 conv=notrunc status=none
assert_eq 2 "$(run_rc python3 -I "${JUDGE}" run --suite "${SM}" --endpoint "${URL}")" "a fixture byte changed -> integrity UNDETERMINED (exit 2)"
assert_contains "$(cat "${TEST_TMP}/last.out")" "suite integrity" "integrity failure named"

echo "== 7. could-not-determine: no endpoint / server error / wrong model -> exit 2 (never PASS)"
assert_eq 2 "$(run_rc "${LLMCTL}" vision validate --host http://127.0.0.1:9)" "endpoint down -> exit 2"
U="$(fake_start "${FIX}/answers_good.json" --mode error500 --model-id /m/vision/gemma-3-4b-it-Q4_K_M.gguf)"
assert_eq 2 "$(run_rc "${LLMCTL}" vision validate --host "${U}")" "HTTP 500 on every probe -> exit 2"
U="$(fake_start "${FIX}/answers_good.json" --model-id /m/fast/Llama-3.1-8B.gguf)"
assert_eq 2 "$(run_rc "${LLMCTL}" vision validate --profile vision --host "${U}")" "endpoint serves a different model -> exit 2"
assert_contains "$(cat "${TEST_TMP}/last.out")" "not the expected model" "wrong-model refusal named"

echo "== 8. served-wrong: images rejected (no mmproj) / non-deterministic -> exit 1; truncated -> exit 2"
U="$(fake_start "${FIX}/answers_good.json" --mode reject-images --model-id /m/vision/gemma-3-4b-it-Q4_K_M.gguf)"
assert_eq 1 "$(run_rc "${LLMCTL}" vision validate --host "${U}")" "server rejects image input -> exit 1"
U="$(fake_start "${FIX}/answers_good.json" --mode truncate --model-id /m/vision/gemma-3-4b-it-Q4_K_M.gguf)"
assert_eq 2 "$(run_rc "${LLMCTL}" vision validate --host "${U}")" "finish_reason=length -> exit 2 (UNDETERMINED: a budget problem, never PASS, never a wrong-answer FAIL)"
U="$(fake_start "${FIX}/answers_good.json" --mode nondeterministic --model-id /m/vision/gemma-3-4b-it-Q4_K_M.gguf)"
assert_eq 1 "$(run_rc "${LLMCTL}" vision validate --host "${U}")" "different answer on a repeated request -> exit 1"
assert_contains "$(cat "${TEST_TMP}/last.out")" "[FAIL] determinism 01_text_large/read" "non-determinism named"

echo "== 9. text suites (chat/coder) and the embedding suite"
U="$(fake_start "${FIX}/answers_good.json" --model-id /m/fast/Llama-3.1-8B-Instruct-Q4_K_M.gguf)"
assert_eq 0 "$(run_rc "${LLMCTL}" validate fast --host "${U}")" "chat suite passes with right answers"
assert_contains "$(cat "${TEST_TMP}/last.out")" "suite chat-v1" "fast runs chat-v1"
U="$(fake_start "$(answers_with arith 41)" --model-id /m/fast/Llama-3.1-8B-Instruct-Q4_K_M.gguf)"
assert_eq 1 "$(run_rc "${LLMCTL}" validate fast --host "${U}")" "17+25 answered 41 -> exit 1"
U="$(fake_start "${FIX}/answers_good.json" --model-id /m/coder/Qwen3-Coder.gguf)"
assert_eq 0 "$(run_rc python3 -I "${JUDGE}" run --suite "${KSUITE}" --endpoint "${U}")" "coder suite passes with right answers"
U="$(fake_start "$(answers_with def_add 'def add(a, b): return a - b')" --model-id /m/coder/Qwen3-Coder.gguf)"
assert_eq 1 "$(run_rc python3 -I "${JUDGE}" run --suite "${KSUITE}" --endpoint "${U}")" "add() returning a-b -> exit 1"
U="$(fake_start "${FIX}/answers_good.json" --model-id /m/embed.gguf)"
assert_eq 0 "$(run_rc python3 -I "${JUDGE}" run --suite "${ESUITE}" --endpoint "${U}")" "embedding ordering suite passes with ordered vectors"
EM="$(mktemp "${TEST_TMP}/emb.XXXXXX")"
python3 -I - "${FIX}/answers_good.json" "${EM}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); e = d["embeddings"]
e["a kitten naps on the couch"], e["the quarterly tax filing deadline"] = e["the quarterly tax filing deadline"], e["a kitten naps on the couch"]
json.dump(d, open(sys.argv[2], "w"))
PY
U="$(fake_start "${EM}" --model-id /m/embed.gguf)"
assert_eq 1 "$(run_rc python3 -I "${JUDGE}" run --suite "${ESUITE}" --endpoint "${U}")" "swapped positive/negative embeddings -> exit 1"

echo "== 10. local profile path: state record, require-validated, freshness"
mkdir -p "${LLMCTL_MODELS_DIR}/vision"
: > "${LLMCTL_MODELS_DIR}/vision/gemma-3-4b-it-Q4_K_M.gguf"
: > "${LLMCTL_MODELS_DIR}/vision/mmproj-model-f16.gguf"
FAKE_BIN="${TEST_TMP}/bin"; mkdir -p "${FAKE_BIN}"
printf '#!/usr/bin/env bash\necho "version: 0.0.0 (build 4242, commit deadbeef)"\n' > "${FAKE_BIN}/llama-server"
chmod +x "${FAKE_BIN}/llama-server"
export LLMCTL_LLAMA_SERVER="${FAKE_BIN}/llama-server"
assert_eq 1 "$(run_rc "${LLMCTL}" require-validated vision)" "require-validated refuses a never-validated profile"
assert_contains "$(cat "${TEST_TMP}/last.out")" "no validation record" "reason: no record"
U="$(fake_start "${FIX}/answers_good.json" --model-id "${LLMCTL_MODELS_DIR}/vision/gemma-3-4b-it-Q4_K_M.gguf")"
port="${U##*:}"
printf 'profile=vision\nmode=gpu\nport=%s\nram_mb=1\nvram_mb=1\nstarted_epoch=%s\n' "${port}" "$(date +%s)" > "${LLMCTL_RUNTIME_DIR}/vision.run"
assert_eq 0 "$(run_rc "${LLMCTL}" vision validate)" "running local profile validated (fixture endpoint on the reserved port)"
assert_file_exists "${LLMCTL_STATE_DIR}/validation/vision.json" "validation state record written"
rec="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["status"], d["engine_tag"], len(d["model_sha256"]), sorted(d["suites"]))' "${LLMCTL_STATE_DIR}/validation/vision.json")"
assert_eq "pass build 4242, commit deadbeef 64 ['vision-golden-v1']" "${rec}" "record carries status, engine tag, model sha, suite"
assert_eq 0 "$(run_rc "${LLMCTL}" require-validated vision)" "require-validated accepts the fresh passing record"
assert_eq 1 "$(run_rc "${LLMCTL}" require-validated vision-pro)" "...but not for a different profile"
# the record names the host it was produced on; a record from another host never validates this one
VREC="${LLMCTL_STATE_DIR}/validation/vision.json"
assert_eq "$(python3 -c 'import socket; print(socket.gethostname())')" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("host"))' "${VREC}")" "record carries the host it was validated on"
cp "${VREC}" "${TEST_TMP}/vision.json.orig"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["host"]="other-host.example"; json.dump(d,open(p,"w"))' "${VREC}"
assert_eq 1 "$(run_rc "${LLMCTL}" require-validated vision)" "a record from another host -> refused"
assert_contains "$(cat "${TEST_TMP}/last.out")" "host changed" "stale reason names the host"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d.pop("host"); json.dump(d,open(p,"w"))' "${VREC}"
assert_eq 1 "$(run_rc "${LLMCTL}" require-validated vision)" "a record without a host field -> refused"
cp "${TEST_TMP}/vision.json.orig" "${VREC}"
assert_eq 0 "$(run_rc "${LLMCTL}" require-validated vision)" "original record restored -> accepted"
# engine changed -> stale
printf '#!/usr/bin/env bash\necho "version: 0.0.0 (build 4243, commit cafef00d)"\n' > "${FAKE_BIN}/llama-server"
assert_eq 1 "$(run_rc "${LLMCTL}" require-validated vision)" "engine build changed -> record stale -> refused"
assert_contains "$(cat "${TEST_TMP}/last.out")" "engine_tag" "stale reason names the engine tag"
printf '#!/usr/bin/env bash\necho "version: 0.0.0 (build 4242, commit deadbeef)"\n' > "${FAKE_BIN}/llama-server"
assert_eq 0 "$(run_rc "${LLMCTL}" require-validated vision)" "engine restored -> accepted again"
# model file replaced -> stale
printf 'x' > "${LLMCTL_MODELS_DIR}/vision/gemma-3-4b-it-Q4_K_M.gguf"
assert_eq 1 "$(run_rc "${LLMCTL}" require-validated vision)" "model file changed on disk -> refused"
: > "${LLMCTL_MODELS_DIR}/vision/gemma-3-4b-it-Q4_K_M.gguf"
touch -d @"$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["model_files"][0]["mtime"])' "${LLMCTL_STATE_DIR}/validation/vision.json")" "${LLMCTL_MODELS_DIR}/vision/gemma-3-4b-it-Q4_K_M.gguf"
assert_eq 0 "$(run_rc "${LLMCTL}" require-validated vision)" "same size+mtime restored -> accepted"
assert_eq 1 "$(run_rc env LLMCTL_VALIDATION_MAX_AGE=0 "${LLMCTL}" require-validated vision)" "max age 0 -> too old -> refused"
# a failing validation replaces the record and require-validated refuses
U2="$(fake_start "$(answers_with "05_table/lookup" "PARIS")" --model-id "${LLMCTL_MODELS_DIR}/vision/gemma-3-4b-it-Q4_K_M.gguf")"
sed -i "s/^port=.*/port=${U2##*:}/" "${LLMCTL_RUNTIME_DIR}/vision.run"
assert_eq 1 "$(run_rc "${LLMCTL}" vision validate)" "wrong answer on the local profile -> exit 1"
assert_eq "fail" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "${LLMCTL_STATE_DIR}/validation/vision.json")" "record now says fail"
assert_eq 1 "$(run_rc "${LLMCTL}" require-validated vision)" "require-validated refuses a failed record"
assert_contains "$(cat "${TEST_TMP}/last.out")" "status=fail" "reason: status=fail"
sed -i "s/^port=.*/port=${port}/" "${LLMCTL_RUNTIME_DIR}/vision.run"

echo "== 11. validate-all + start hook + models verify gate + no-suite profiles"
assert_eq 0 "$(run_rc "${LLMCTL}" validate-all)" "validate-all over the running profiles (vision) -> 0"
assert_contains "$(cat "${TEST_TMP}/last.out")" "vision: PASS" "validate-all names each profile's verdict"
assert_eq 0 "$(run_rc env LLMCTL_VALIDATE_ON_START=1 "${LLMCTL}" validate-after-start vision)" "start hook: fresh record -> 0"
assert_contains "$(cat "${TEST_TMP}/last.out")" "already has a fresh passing record" "start hook reuses only a FRESH record"
rm -f "${LLMCTL_STATE_DIR}/validation/vision.json"
sed -i "s/^port=.*/port=${U2##*:}/" "${LLMCTL_RUNTIME_DIR}/vision.run"
cp "${LLMCTL_RUNTIME_DIR}/vision.run" "${TEST_TMP}/vision.run.bak"
assert_eq 1 "$(run_rc env LLMCTL_VALIDATE_ON_START=1 "${LLMCTL}" validate-after-start vision)" "start hook: wrong answer after start -> 1"
assert_contains "$(cat "${TEST_TMP}/last.out")" "gave WRONG answers" "start hook names the wrong-answer verdict"
# the gate is enforced (docs/validation.md "Enforcement of the gate"): a WRONG answer STOPS the profile through the normal stop path
assert_contains "$(cat "${TEST_TMP}/last.out")" "stopping it through the normal stop path" "start hook says the profile is stopped"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/vision.run" "start hook: the failed profile is stopped (reservation removed)"
cp "${TEST_TMP}/vision.run.bak" "${LLMCTL_RUNTIME_DIR}/vision.run"   # restore the fixture world for the sections below
assert_eq 0 "$(run_rc env LLMCTL_VALIDATE_ON_START=0 "${LLMCTL}" validate-after-start vision)" "LLMCTL_VALIDATE_ON_START=0 skips (exit 0)..."
assert_contains "$(cat "${TEST_TMP}/last.out")" "NOT validated" "...but says loudly that nothing was validated"
assert_eq 1 "$(run_rc "${LLMCTL}" require-validated vision)" "...and require-validated still refuses"
sed -i "s/^port=.*/port=${port}/" "${LLMCTL_RUNTIME_DIR}/vision.run"
gate() { bash -c 'source "$1/lib/common.sh"; source "$1/lib/catalog.sh"; source "$1/lib/validate.sh"; shift; models_verify_gate "$@"' _ "${LLMCTL_ROOT}" "$@"; }
assert_eq 0 "$(run_rc gate vision)" "models verify gate: running vision -> suite run -> 0"
assert_contains "$(cat "${TEST_TMP}/last.out")" "VERDICT: PASS" "models verify gate really ran the suite"
assert_eq 0 "$(run_rc gate decide)" "models verify gate: decide (no suite, not --live) -> warning only"
assert_contains "$(cat "${TEST_TMP}/last.out")" "no llmctl validation suite" "...with the documented reason"
assert_eq 2 "$(run_rc gate decide --live)" "models verify gate: decide --live -> 2 (cannot validate)"
assert_eq 0 "$(run_rc gate fast)" "models verify gate: fast not running -> suite named, live run NOT claimed"
assert_contains "$(cat "${TEST_TMP}/last.out")" "live validation NOT run" "...and says so"
rm -f "${LLMCTL_RUNTIME_DIR}/vision.run"
assert_eq 2 "$(run_rc "${LLMCTL}" validate-all)" "validate-all with nothing running -> 2 (nothing validated is not a pass)"
assert_eq 2 "$(run_rc "${LLMCTL}" vision validate --profile vision-pro)" "vision-pro not downloaded, not running -> exit 2"
assert_contains "$(cat "${TEST_TMP}/last.out")" "not downloaded" "reason: not downloaded"
assert_eq 2 "$(run_rc "${LLMCTL}" vision validate --profile fast)" "fast has no vision suite -> exit 2"
assert_eq 2 "$(run_rc "${LLMCTL}" validate decide --host http://127.0.0.1:9)" "decide profile has no llmctl suite -> exit 2"
assert_contains "$(cat "${TEST_TMP}/last.out")" "no llmctl validation suite" "no-suite reason printed"
assert_eq 2 "$(run_rc "${LLMCTL}" vision validate --bogus)" "unknown flag -> usage error (exit 2)"
out="$(LLMCTL_DRY_RUN=1 LLMCTL_VALIDATE_ON_START=1 "${LLMCTL}" validate-after-start vision 2>&1 || true)"
assert_contains "${out}" "validation not run (LLMCTL_DRY_RUN=1)" "start hook never claims a validation under dry-run"

test_finish
