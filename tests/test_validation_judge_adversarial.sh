#!/usr/bin/env bash
# test_validation_judge_adversarial.sh - review 2026-10-15 finding 4: 42 of 77 adversarial answers were judged wrongly
# (wrong answers PASSED: negated / hedged / comparative / ordinal / percent numbers, retractions, alternatives, negated
# order, Unicode look-alikes, code that only LOOKS right, nested or negated JSON literals, extra JSON keys, duplicate keys,
# self-corrections, mangled echoes, re-ordered or extended transcriptions) and 4 right answers FAILED. Every row of the
# reviewer's table (tests/fixtures/validation/adversarial_answers.json) is judged against the REAL suite probe; the judge
# must agree with the stated truth on EVERY row, wrong answers first (a false PASS is the defect that matters).
# JUDGE_UNDER_TEST: a mutant copy (tests/test_validation_mutants.sh group "judge2").
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
JUDGE="${JUDGE_UNDER_TEST:-${LLMCTL_ROOT}/lib/validate_judge.py}"
res="$(python3 -I - "${JUDGE}" "${LLMCTL_ROOT}/validation/suites" "${LLMCTL_ROOT}/tests/fixtures/validation/adversarial_answers.json" <<'PY'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("vj", sys.argv[1]); vj = importlib.util.module_from_spec(spec); spec.loader.exec_module(vj)
P = {s: {k: pr for k, _, pr in vj.probes_of(vj.load_suite(os.path.join(sys.argv[2], s)))}
     for s in ("chat-v1", "coder-v1", "vision-golden-v1")}
rows = json.load(open(sys.argv[3]))["rows"]
fp, ff = [], []
for r in rows:
    ok, why = vj.judge_probe(P[r["suite"]][r["probe"]], r["answer"])
    got = "pass" if ok else "fail"
    if got != r["truth"]:
        (fp if got == "pass" else ff).append("%s %s %r (%s)" % (r["class"], r["probe"], r["answer"], "; ".join(why)[:80]))
print(len(rows), len([r for r in rows if r["truth"] == "fail"]), len(fp), len(ff))
for x in fp: print("FALSE-PASS", x)
for x in ff: print("false-fail", x)
PY
)"
read -r n nfail fp ff <<<"$(head -1 <<<"${res}")"
echo "${res}" | tail -n +2 | head -20
assert_eq 1 "$(( n >= 84 && nfail >= 60 ? 1 : 0 ))" "the table is complete (${n} rows, ${nfail} wrong answers)"
assert_eq 0 "${fp}" "no wrong answer is judged PASS (false PASS)"
assert_eq 0 "${ff}" "no right answer is judged FAIL (false FAIL)"
for s in vision-golden-v1 chat-v1 coder-v1; do
  rc=0; python3 -I "${JUDGE}" selftest --suite "${LLMCTL_ROOT}/validation/suites/${s}" > "${TEST_TMP}/st.${s}" 2>&1 || rc=$?
  assert_eq 0 "${rc}" "judge self-test (canned controls of every class) green for ${s}: $(tail -1 "${TEST_TMP}/st.${s}")"
done
# the code is parsed, never executed: an answer that would run something when executed is judged without running it
marker="${TEST_TMP}/executed"
res2="$(python3 -I - "${JUDGE}" "${marker}" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("vj", sys.argv[1]); vj = importlib.util.module_from_spec(spec); spec.loader.exec_module(vj)
code = "open(%r, 'w').write('x')\ndef add(a, b):\n    return a + b" % sys.argv[2]
print(vj.python_function_sum(code, "add") is None)
PY
)"
assert_eq True "${res2}" "a module-level statement next to a correct add() does not make it wrong"
assert_file_absent "${marker}" "...and the code was never executed"
test_finish
