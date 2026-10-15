#!/usr/bin/env bash
# test_validation_judge_adversarial_r3.sh - independent review 3 of 2026-10-15, findings 1-5 (RED first): of 144 NEW
# adversarial answers judged against the REAL suite probes, 30 clearly wrong answers PASSED and 4 clearly right ones FAILED:
#   1 HIGH   number_equals took ANY 1-4 trailing words: '42 thousand', '42 squared', 'The answer is 42 in hex', '3 pairs',
#            '42 I think', '3 red circles presumably' ... PASSED   -> only the probe's own number_allow words may stand next
#            to N (a positive allow-list; no list of blocked words, Constitution 11.4.250)
#   2 HIGH   `ordered` ignored items not in its list: 'red green blue yellow', a hallucinated fifth list item or table row
#            PASSED -> the transcription probes check exact_words (+ the probe's own framing phrases: words_allow)
#   3 MEDIUM contains_*: 'Cancel, Delete, OK' (the two labels only) and 'A dashboard (login screen is next).' PASSED
#            -> label_set (exactly these labels, nothing else), contains_any ignores a parenthetical aside, the screen
#            type probe forbids the other screen types
#   4 MEDIUM python_function_sum: 'add.__code__ = ...' / "globals()['add'] = ..." PASSED -> the module holds only the def,
#            imports and a docstring; nothing calls anything or stores through an attribute / subscript
#   5 MEDIUM right answers FAILED: 'London. No, Paris.', 'light? no, dark' (the retraction word negated the correction),
#            'Invoice No. 7731' / 'No. 7731' (the abbreviation period split the sentence)
# The table is tests/fixtures/validation/adversarial_answers_r3.json: 'clear' rows must be judged as their truth;
# 'tradeoff' rows must be judged as their pinned verdict, and every refused right answer carries its justification
# (docs/validation.md "Known trade-offs"). JUDGE_UNDER_TEST: a mutant copy (tests/test_validation_mutants.sh "judge3").
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
JUDGE="${JUDGE_UNDER_TEST:-${LLMCTL_ROOT}/lib/validate_judge.py}"
res="$(python3 -I - "${JUDGE}" "${LLMCTL_ROOT}/validation/suites" "${LLMCTL_ROOT}/tests/fixtures/validation/adversarial_answers_r3.json" <<'PY'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("vj", sys.argv[1]); vj = importlib.util.module_from_spec(spec); spec.loader.exec_module(vj)
P = {s: {k: pr for k, _, pr in vj.probes_of(vj.load_suite(os.path.join(sys.argv[2], s)))}
     for s in ("chat-v1", "coder-v1", "vision-golden-v1", "decide-v1")}
rows = json.load(open(sys.argv[3]))["rows"]
fp, ff, tmoved, unjust = [], [], [], []
for r in rows:
    ok, why = vj.judge_probe(P[r["suite"]][r["probe"]], r["answer"])
    got = "pass" if ok else "fail"
    line = "%s %s %r (%s)" % (r["class"], r["probe"], r["answer"][:50], "; ".join(why)[:90])
    if r["grade"] == "clear":
        if got != r["truth"]:
            (fp if got == "pass" else ff).append(line)
    else:
        if got != r["judged"]:
            tmoved.append("%s -> %s" % (line, got))
        if r["judged"] != r["truth"] and not r.get("justification"):
            unjust.append(line)
nclear = sum(1 for r in rows if r["grade"] == "clear")
ntrade = sum(1 for r in rows if r["grade"] == "tradeoff" and r["judged"] != r["truth"])
print(len(rows), nclear, len(fp), len(ff), len(tmoved), len(unjust), ntrade)
for x in fp: print("FALSE-PASS", x)
for x in ff: print("false-fail", x)
for x in tmoved: print("trade-off verdict moved", x)
for x in unjust: print("trade-off without justification", x)
PY
)"
read -r n nclear fp ff tm uj ntrade <<<"$(head -1 <<<"${res}")"
echo "${res}" | tail -n +2 | head -40
assert_eq "144 118" "${n} ${nclear}" "the review-3 table is complete (144 rows, 118 clear)"
assert_eq 0 "${fp}" "no clearly wrong answer is judged PASS (false PASS)"
assert_eq 0 "${ff}" "no clearly right answer is judged FAIL (false FAIL)"
assert_eq 0 "${tm}" "every trade-off row is judged exactly as documented (a moved trade-off verdict is noticed)"
assert_eq 0 "${uj}" "every refused right answer carries a justification"
printf '  info: %s documented trade-off rows refuse a debatable right answer\n' "${ntrade}"

# finding 4: the module may hold only the def, imports and a docstring - and the code is still never executed
marker="${TEST_TMP}/executed"
res2="$(python3 -I - "${JUDGE}" "${marker}" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("vj", sys.argv[1]); vj = importlib.util.module_from_spec(spec); spec.loader.exec_module(vj)
code = "open(%r, 'w').write('x')\ndef add(a, b):\n    return a + b" % sys.argv[2]
print(vj.python_function_sum(code, "add") is None)
PY
)"
assert_eq False "${res2}" "a module-level statement next to a correct add() is refused (it could re-bind add)"
assert_file_absent "${marker}" "...and the code was never executed"

# every new judge class is proven by the self-test before any request: canned PASS and FAIL controls per class
cls="$(python3 -I - "${JUDGE}" "${LLMCTL_ROOT}/validation/suites" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("vj", sys.argv[1]); vj = importlib.util.module_from_spec(spec); spec.loader.exec_module(vj)
have = {}
for s in ("chat-v1", "coder-v1", "vision-golden-v1"):
    suite = vj.load_suite(os.path.join(sys.argv[2], s))
    probes = {k: p for k, _, p in vj.probes_of(suite)}
    for c in suite["judge_controls"]:
        for key in probes[c["probe"]]["checks"]:
            have.setdefault(key, set()).add(c["expect"])
need = ["label_set", "words_allow", "number_allow", "exact_words", "contains_any", "python_function_sum"]
print(" ".join("%s=%s" % (k, ",".join(sorted(have.get(k, ())))) for k in need))
PY
)"
assert_eq "label_set=fail,pass words_allow=fail,pass number_allow=fail,pass exact_words=fail,pass contains_any=fail,pass python_function_sum=fail,pass" "${cls}" "canned PASS and FAIL controls for every new / changed judge class"
for s in vision-golden-v1 chat-v1 coder-v1; do
  rc=0; python3 -I "${JUDGE}" selftest --suite "${LLMCTL_ROOT}/validation/suites/${s}" > "${TEST_TMP}/st.${s}" 2>&1 || rc=$?
  assert_eq 0 "${rc}" "judge self-test green for ${s}: $(tail -1 "${TEST_TMP}/st.${s}")"
done
# a words_allow that could hide an expected or a negation word is a SUITE DEFECT, never a vacuous pass
d="$(python3 -I - "${JUDGE}" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("vj", sys.argv[1]); vj = importlib.util.module_from_spec(spec); spec.loader.exec_module(vj)
out = []
for checks in ({"exact_words": "RED GREEN", "words_allow": ["RED"]}, {"label_set": ["A", "B"], "words_allow": ["NOT"]},
               {"contains_all": ["X"], "words_allow": ["AND"]}, {"label_set": ["A", "a"]}):
    try:
        vj.validate_checks(checks); out.append("ok")
    except vj.SuiteDefect:
        out.append("defect")
print(" ".join(out))
PY
)"
assert_eq "defect defect defect defect" "${d}" "words_allow hiding an expected / negation word, a stray words_allow, duplicate labels -> suite defect"
test_finish
