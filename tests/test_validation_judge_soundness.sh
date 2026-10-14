#!/usr/bin/env bash
# test_validation_judge_soundness.sh - RED-first (independent review 2026-10-14, finding 7). Every answer below used to be
# judged PASS by lib/validate_judge.py although it is wrong, hedged, negated or the check itself is empty:
#   '3 or 4' / 'I count 3... no, 4'      first number won                   -> must FAIL (several different numbers)
#   'Red, green, blue, red'               ordered = any subsequence          -> must FAIL (occurrence order != expected order)
#   'There is no ORANGE TIGER 42 here'    negation ignored                   -> must FAIL (a negated mention is not a claim)
#   'return a - b # not: return a + b'    regex matched inside a comment     -> must FAIL (comments are not code)
#   checks={} / contains_all=[]           vacuous truth                       -> suite DEFECT (UNDETERMINED, refused at load)
#   JSON 1 for true                       Python 1 == True                    -> must FAIL (type-exact JSON equality)
# plus: canned PASS+FAIL judge controls for EVERY golden vision probe; every probe repeated N=3 times (determinism,
# Constitution 11.4.50) with LLMCTL_VALIDATE_REPEAT=1 as the documented quick mode; and the REAL answers recorded in docs/qa
# keep their verdicts (a stricter judge must not invent false FAILs on real correct answers).
# JUDGE may be pointed at a mutant copy (tests/test_validation_mutants.sh): every section asserts behaviour, not text.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
JUDGE="${JUDGE_UNDER_TEST:-${LLMCTL_ROOT}/lib/validate_judge.py}"
FIX="${LLMCTL_ROOT}/tests/fixtures/validation"
SUITES="${LLMCTL_ROOT}/validation/suites"
FAKE_PIDS_FILE="$(mktemp)"
cleanup() { local p; while read -r p; do [[ -n "${p}" ]] && kill "${p}" 2>/dev/null || true; done < "${FAKE_PIDS_FILE}"; rm -f "${FAKE_PIDS_FILE}"; test_teardown_env; }
trap cleanup EXIT
export LLMCTL_VALIDATE_TIMEOUT=20

# v <suite> <probe-key> <answer> -> PASS | FAIL | DEFECT:<reason>   (the real probe of the real suite, judged by $JUDGE)
v() {
  python3 -I - "${JUDGE}" "${SUITES}/$1" "$2" "$3" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("vj", sys.argv[1]); vj = importlib.util.module_from_spec(spec); spec.loader.exec_module(vj)
suite = vj.load_suite(sys.argv[2])
pr = {k: p for k, _, p in vj.probes_of(suite)}[sys.argv[3]]
try:
    ok, reasons = vj.judge_probe(pr, sys.argv[4])
    print("PASS" if ok else "FAIL")
except vj.SuiteDefect as e:
    print("DEFECT:%s" % e)
PY
}
# c <checks-json> <answer> -> PASS | FAIL | DEFECT:<reason>   (synthetic checks)
c() {
  python3 -I - "${JUDGE}" "$1" "$2" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("vj", sys.argv[1]); vj = importlib.util.module_from_spec(spec); spec.loader.exec_module(vj)
try:
    ok, _ = vj.judge_probe({"id": "x", "prompt": "p", "checks": json.loads(sys.argv[2])}, sys.argv[3])
    print("PASS" if ok else "FAIL")
except vj.SuiteDefect as e:
    print("DEFECT:%s" % e)
PY
}

echo "== 1. number_equals: a hedged / self-corrected answer states several different numbers -> FAIL"
assert_eq FAIL "$(v vision-golden-v1 02_shapes_count/red_circles '3 or 4')" "'3 or 4' for 3 red circles -> FAIL"
assert_eq FAIL "$(v vision-golden-v1 02_shapes_count/red_circles 'I count 3... no, 4')" "'I count 3... no, 4' -> FAIL"
assert_eq FAIL "$(v vision-golden-v1 02_shapes_count/red_circles 'three or four')" "'three or four' (number words) -> FAIL"
assert_eq FAIL "$(v chat-v1 arith '17 + 25 = 42, or maybe 43')" "an equation restated, then hedged after the '=' -> FAIL"
assert_eq PASS "$(v vision-golden-v1 02_shapes_count/red_circles '3')" "control: '3' -> PASS"
assert_eq PASS "$(v vision-golden-v1 02_shapes_count/red_circles 'There are three red circles.')" "control: 'There are three red circles.' -> PASS"
assert_eq PASS "$(v vision-golden-v1 02_shapes_count/red_circles '3 red circles - yes, 3.')" "control: the same number repeated -> PASS"
assert_eq PASS "$(v chat-v1 arith '17 + 25 = 42')" "control: operands before the last '=' are not answers -> PASS"
assert_eq PASS "$(v chat-v1 arith '17 + 25 = 42. The answer is 42.')" "control: the answer restated after the equation -> PASS"

echo "== 2. ordered: the occurrence sequence must BE the expected order (a repeated / extra item is not that order)"
assert_eq FAIL "$(v vision-golden-v1 09_color_blocks/colors 'Red, green, blue, red')" "'Red, green, blue, red' -> FAIL"
assert_eq FAIL "$(c '{"ordered": ["BLUE", "RED", "GREEN"]}' 'Blue, red, green, blue')" "'Blue, red, green, blue' vs [BLUE,RED,GREEN] -> FAIL"
assert_eq FAIL "$(v vision-golden-v1 04_list_view/items $'APPLE\nBANANA\nAPPLE\nCHERRY\nGRAPE')" "a list with an item read twice -> FAIL"
assert_eq PASS "$(v vision-golden-v1 09_color_blocks/colors 'Red, Green, Blue')" "control: 'Red, Green, Blue' -> PASS"
assert_eq PASS "$(v vision-golden-v1 04_list_view/items $'APPLE\nBANANA\nCHERRY\nGRAPE')" "control: the list in order -> PASS"

echo "== 3. negation: a negated mention is not a claim (contains_* must not pass on it, forbidden must not fire on it)"
assert_eq FAIL "$(v vision-golden-v1 01_text_large/read 'There is no ORANGE TIGER 42 here')" "'There is no ORANGE TIGER 42 here' -> FAIL"
assert_eq FAIL "$(v vision-golden-v1 01_text_large/read "I don't see ORANGE TIGER 42 in this image")" "\"I don't see ORANGE TIGER 42\" -> FAIL"
assert_eq FAIL "$(v vision-golden-v1 05_table/lookup 'It is not OSLO')" "'It is not OSLO' -> FAIL"
assert_eq PASS "$(v vision-golden-v1 01_text_large/read 'No problem. ORANGE TIGER 42')" "control: a negation in ANOTHER sentence does not negate the claim -> PASS"
assert_eq PASS "$(v vision-golden-v1 05_table/lookup 'OSLO (not PARIS)')" "control: a negated forbidden word is not a claim -> PASS"
assert_eq FAIL "$(v vision-golden-v1 05_table/lookup 'OSLO or PARIS')" "control: an asserted forbidden word still FAILs"
assert_eq PASS "$(v vision-golden-v1 90_bad_blank/read 'NO TEXT')" "control: 'NO TEXT' (the needle itself starts with NO) -> PASS"

echo "== 4. code: checks are applied to the code with comments removed"
assert_eq FAIL "$(v coder-v1 def_add $'def add(a, b):\n    return a - b # not: return a + b')" "'return a - b # not: return a + b' -> FAIL"
assert_eq FAIL "$(v coder-v1 def_add $'```python\ndef add(a, b):\n    # return a + b\n    return a * b\n```')" "the right line only inside a comment -> FAIL"
assert_eq PASS "$(v coder-v1 def_add $'```python\ndef add(a, b):\n    return a + b  # the sum\n```')" "control: right code with a trailing comment -> PASS"
assert_eq PASS "$(v coder-v1 def_add $'def add(x, y):\n    s = "# not a comment"\n    return x + y')" "control: a '#' inside a string literal is not a comment -> PASS"

echo "== 5. empty checks are a SUITE DEFECT (never a vacuous PASS)"
assert_contains "$(c '{}' 'anything at all')" "DEFECT:" "checks={} -> suite defect"
assert_contains "$(c '{"contains_all": []}' 'anything at all')" "DEFECT:" "contains_all=[] -> suite defect"
assert_contains "$(c '{"ordered": []}' 'x')" "DEFECT:" "ordered=[] -> suite defect"
assert_contains "$(c '{"json_subset": {}}' '{}')" "DEFECT:" "json_subset={} -> suite defect"
assert_contains "$(c '{"regex_all": ["("]}' 'x')" "DEFECT:" "an uncompilable regex -> suite defect"
assert_contains "$(c '{"bogus_check": 1}' 'x')" "DEFECT:" "an unknown check type -> suite defect"
assert_eq PASS "$(c '{"contains_all": ["X"]}' 'x')" "control: a non-empty check still judges"
DS="${TEST_TMP}/defect_suite"; cp -r "${SUITES}/chat-v1" "${DS}"
python3 -I - "${DS}/suite.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["cases"][2]["checks"] = {}; json.dump(d, open(p, "w"))
PY
rc=0; python3 -I "${JUDGE}" run --suite "${DS}" --endpoint http://127.0.0.1:9 > "${TEST_TMP}/defect.out" 2>&1 || rc=$?
assert_eq 2 "${rc}" "run with a probe whose checks are {} -> UNDETERMINED (exit 2) before any request"
assert_contains "$(cat "${TEST_TMP}/defect.out")" "suite defect" "the defect is named"
rc=0; python3 -I "${JUDGE}" selftest --suite "${DS}" > "${TEST_TMP}/defect.st" 2>&1 || rc=$?
assert_eq 1 "${rc}" "selftest refuses a suite with an empty check"

echo "== 6. json_subset is type-exact (1 is not true, 0 is not false, \"1\" is not 1)"
assert_eq FAIL "$(c '{"json_subset": {"ok": true}}' '{"ok": 1}')" "JSON 1 for true -> FAIL"
assert_eq FAIL "$(c '{"json_subset": {"ok": false}}' '{"ok": 0}')" "JSON 0 for false -> FAIL"
assert_eq FAIL "$(c '{"json_subset": {"n": 1}}' '{"n": true}')" "JSON true for 1 -> FAIL"
assert_eq FAIL "$(c '{"json_subset": {"n": 1}}' '{"n": "1"}')" "JSON \"1\" for 1 -> FAIL"
assert_eq PASS "$(c '{"json_subset": {"ok": true}}' '{"ok": true}')" "control: true for true -> PASS"
assert_eq PASS "$(c '{"json_subset": {"n": 1}}' '{"n": 1.0}')" "control: 1.0 for 1 (same JSON number) -> PASS"
assert_eq FAIL "$(c '{"json_subset": {"l": [1, true]}}' '{"l": [true, 1]}')" "nested: [true,1] for [1,true] -> FAIL"

echo "== 7. canned PASS and FAIL judge controls for EVERY golden vision probe; the self-test proves them"
cov="$(python3 -I - "${SUITES}/vision-golden-v1/expectations.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
keys = ["%s/%s" % (f["id"], p["id"]) for f in d["fixtures"] if f.get("role") != "control-bad" for p in f["probes"]]
miss = [k for k in keys if not ({c["expect"] for c in d["judge_controls"] if c["probe"] == k} >= {"pass", "fail"})]
print(len(keys), ",".join(miss) or "none")
PY
)"
assert_eq "16 none" "${cov}" "all 16 golden vision probes carry at least one PASS and one FAIL canned control"
for s in vision-golden-v1 chat-v1 coder-v1; do
  rc=0; python3 -I "${JUDGE}" selftest --suite "${SUITES}/${s}" > "${TEST_TMP}/st.${s}" 2>&1 || rc=$?
  assert_eq 0 "${rc}" "judge self-test green for ${s} ($(tail -1 "${TEST_TMP}/st.${s}"))"
done

echo "== 8. the REAL answers recorded in docs/qa keep their verdicts"
res="$(python3 -I - "${JUDGE}" "${SUITES}" "${FIX}/recorded_live_answers.json" <<'PY'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("vj", sys.argv[1]); vj = importlib.util.module_from_spec(spec); spec.loader.exec_module(vj)
idx = {}
for s in ("vision-golden-v1", "chat-v1", "coder-v1"):
    for k, _, p in vj.probes_of(vj.load_suite(os.path.join(sys.argv[2], s))):
        idx[k] = p
rec = json.load(open(sys.argv[3]))["answers"]
bad = []
for r in rec:
    ok, why = vj.judge_probe(idx[r["key"]], r["answer"])
    if ("PASS" if ok else "FAIL") != r["verdict"]:
        bad.append("%s %r %s" % (r["key"], r["answer"], why))
print(len(rec), len(bad)); print("\n".join(bad))
PY
)"
assert_eq "26 0" "$(head -1 <<<"${res}")" "every recorded real answer keeps its recorded verdict ($(tail -n +2 <<<"${res}" | head -3))"

echo "== 9. determinism: every probe is asked N=3 times (default); LLMCTL_VALIDATE_REPEAT=1 is the quick mode"
pf="${TEST_TMP}/port.nd3"
python3 -I "${FIX}/fake_openai.py" --suite "${SUITES}/chat-v1" --answers "${FIX}/answers_good.json" --port-file "${pf}" \
  --model-id test-model --mode nondeterministic-third >/dev/null 2>&1 &
echo "$!" >> "${FAKE_PIDS_FILE}"
for (( i=0; i<100; i++ )); do [[ -s "${pf}" ]] && break; sleep 0.1; done
U="http://127.0.0.1:$(cat "${pf}")"
rc=0; python3 -I "${JUDGE}" run --suite "${SUITES}/chat-v1" --endpoint "${U}" > "${TEST_TMP}/nd3.out" 2>&1 || rc=$?
assert_eq 1 "${rc}" "a model whose THIRD answer differs -> FAIL with the default N=3"
assert_contains "$(cat "${TEST_TMP}/nd3.out")" "[FAIL] determinism" "the non-deterministic probe is named"
assert_contains "$(cat "${TEST_TMP}/nd3.out")" "repeat=3" "the repeat count is printed"
rc=0; LLMCTL_VALIDATE_REPEAT=1 python3 -I "${JUDGE}" run --suite "${SUITES}/chat-v1" --endpoint "${U}" > "${TEST_TMP}/nd1.out" 2>&1 || rc=$?
assert_eq 0 "${rc}" "quick mode (LLMCTL_VALIDATE_REPEAT=1) only repeats the suite's determinism probe once -> it cannot see the third answer"
assert_contains "$(cat "${TEST_TMP}/nd1.out")" "quick mode" "quick mode says so"
rc=0; LLMCTL_VALIDATE_REPEAT=nan python3 -I "${JUDGE}" run --suite "${SUITES}/chat-v1" --endpoint "${U}" > "${TEST_TMP}/ndn.out" 2>&1 || rc=$?
assert_eq 2 "${rc}" "LLMCTL_VALIDATE_REPEAT=nan -> refused (exit 2)"

test_finish
