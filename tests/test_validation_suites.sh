#!/usr/bin/env bash
# test_validation_suites.sh - structure and discrimination of EVERY validation suite under validation/suites/
# (cited by validation/suites/embedding-v1/suite.json). Hermetic: the fixture server tests/fixtures/validation/
# fake_openai.py answers from a table; no model, no service. Checks, per suite:
#   * the suite file loads, has schema 1, a known kind, only known check types, unique probe ids
#   * deterministic sampling (temperature 0, seed, top_k 1, no prompt cache) and a token budget with room for
#     reasoning models (chat/coder >= 1024)
#   * every judge_control names a real probe, every probe has at least one canned PASS and one canned FAIL control
#   * the judge self-test passes; vision fixture sha256 values match the files
#   * every probe DISCRIMINATES: replacing just that probe's right answer with garbage turns the run RED (exit 1)
#   * the embedding suite passes with ordered vectors and fails with swapped ones
# What this file does NOT prove: that any real model passes. See docs/qa/vision-validate-live-2026-10-12.md.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

SUITES="${LLMCTL_ROOT}/validation/suites"
FIX="${LLMCTL_ROOT}/tests/fixtures/validation"
JUDGE="${JUDGE_UNDER_TEST:-${LLMCTL_ROOT}/lib/validate_judge.py}"   # a mutant copy: tests/test_validation_mutants.sh "suites"
export LLMCTL_VALIDATE_TIMEOUT=20

FAKE_PIDS_FILE="$(mktemp)"
cleanup() {
  local p
  while read -r p; do [[ -n "${p}" ]] && kill "${p}" 2>/dev/null || true; done < "${FAKE_PIDS_FILE}"
  rm -f "${FAKE_PIDS_FILE}"
  test_teardown_env
}
trap cleanup EXIT

fake_start() {   # fake_start <answers.json> [extra args] -> base URL
  local answers="$1"; shift
  local pf; pf="$(mktemp -u "${TEST_TMP}/port.XXXXXX")"
  python3 -I "${FIX}/fake_openai.py" --suite "${SUITES}/vision-golden-v1" --suite "${SUITES}/chat-v1" \
    --suite "${SUITES}/coder-v1" --answers "${answers}" --port-file "${pf}" "$@" >/dev/null 2>&1 &
  echo "$!" >> "${FAKE_PIDS_FILE}"
  local i
  for (( i=0; i<100; i++ )); do [[ -s "${pf}" ]] && break; sleep 0.1; done
  printf 'http://127.0.0.1:%s\n' "$(cat "${pf}")"
}
run_rc() { local rc=0; "$@" >"${TEST_TMP}/last.out" 2>&1 || rc=$?; echo "${rc}"; }

echo "== 1. structure of every suite"
# The known check names come FROM THE JUDGE (finding 13 of the third 2026-10-15 review: a hand-kept copy of the list here
# went stale when max_words, exact_text, json_equals, exact_words, python_function_sum and number_allow were added, and
# this suite was RED for every one of them). A check a suite names but the judge does not know is an ERROR.
cat > "${TEST_TMP}/structure.py" <<'PY'
import hashlib, importlib.util, json, os, sys
sdir = sys.argv[1]
spec = importlib.util.spec_from_file_location("vj", sys.argv[2]); vj = importlib.util.module_from_spec(spec); spec.loader.exec_module(vj)
KNOWN = set(vj._KNOWN_CHECKS)
if not {"contains_all", "number_equals", "exact_words", "choice_equals"} <= KNOWN:
    sys.exit("ERROR: the judge's check list %s is implausibly small" % sorted(KNOWN))
errs, gaps, names = [], [], sorted(os.listdir(sdir))
for name in names:
    d = os.path.join(sdir, name)
    f = [n for n in ("expectations.json", "suite.json") if os.path.isfile(os.path.join(d, n))]
    if not f:
        errs.append("%s: no expectations.json / suite.json" % name); continue
    s = json.load(open(os.path.join(d, f[0])))
    kind = s.get("kind")
    if s.get("schema") != 1: errs.append("%s: schema != 1" % name)
    if s.get("suite") != name: errs.append("%s: suite field is %r" % (name, s.get("suite")))
    if kind not in ("vision", "chat", "coder", "embedding", "decide"): errs.append("%s: unknown kind %r" % (name, kind)); continue
    if kind == "decide":
        # typed decisions go through the Go driver (deterministic mode is the driver's); the checks are exact choices
        ids = [c["id"] for c in s["cases"]]
        for c in s["cases"]:
            q = c.get("question") or {}
            if set(c["checks"]) != {"choice_equals"} or c["checks"]["choice_equals"] not in (q.get("criteria") or {}):
                errs.append("%s: case %s must check choice_equals with one of its criteria" % (name, c["id"]))
        if s.get("execution_status") not in ("executed", "unexecuted"):
            errs.append("%s: execution_status must say whether the suite ever ran against a real model" % name)
        for pr in ids:
            if {c["expect"] for c in s.get("judge_controls", []) if c["probe"] == pr} != {"pass", "fail"}:
                errs.append("%s: probe %s needs a canned PASS and a canned FAIL judge control" % (name, pr))
        continue
    if kind == "embedding":
        for c in s["cases"]:
            for k in ("id", "anchor", "positive", "negative"):
                if k not in c: errs.append("%s: case missing %s" % (name, k))
        continue
    r = s.get("request", {})
    if r.get("temperature") != 0 or "seed" not in r or r.get("top_k") != 1 or r.get("cache_prompt") is not False:
        errs.append("%s: request is not deterministic (temperature 0, seed, top_k 1, cache_prompt false): %s" % (name, r))
    floor = 1024 if kind in ("chat", "coder") else 128
    if int(r.get("max_tokens", 0)) < floor: errs.append("%s: max_tokens %s < %d" % (name, r.get("max_tokens"), floor))
    probes = []
    if kind == "vision":
        for fx in s["fixtures"]:
            p = os.path.join(d, fx["image"])
            if not os.path.isfile(p): errs.append("%s: missing %s" % (name, fx["image"]))
            elif hashlib.sha256(open(p, "rb").read()).hexdigest() != fx["sha256"]: errs.append("%s: %s sha256 mismatch" % (name, fx["image"]))
            probes += ["%s/%s" % (fx["id"], pr["id"]) for pr in fx["probes"]]
            for pr in fx["probes"]:
                for k in pr["checks"]:
                    if k not in KNOWN: errs.append("%s: unknown check %s" % (name, k))
    else:
        for c in s["cases"]:
            probes.append(c["id"])
            for k in c["checks"]:
                if k not in KNOWN: errs.append("%s: unknown check %s" % (name, k))
    if len(set(probes)) != len(probes): errs.append("%s: duplicate probe ids" % name)
    for k in s.get("determinism_repeat", []):
        if k not in probes: errs.append("%s: determinism_repeat names unknown probe %s" % (name, k))
    ctl = s.get("judge_controls", [])
    for c in ctl:
        if c["probe"] not in probes: errs.append("%s: judge control for unknown probe %s" % (name, c["probe"]))
    for pr in probes:
        want = {c["expect"] for c in ctl if c["probe"] == pr}
        if want != {"pass", "fail"}:
            errs.append("%s: probe %s needs a canned PASS and a canned FAIL judge control (has %s)" % (name, pr, sorted(want)))
for e in errs: print("ERROR:", e)
for g in gaps: print("GAP:", g)
print("suites:", ",".join(names))
sys.exit(1 if errs else 0)
PY
report="$(python3 -I "${TEST_TMP}/structure.py" "${SUITES}" "${JUDGE}")" && rc=0 || rc=$?
printf '%s\n' "${report}" | sed 's/^/    | /'
assert_eq 0 "${rc}" "every suite is well-formed, deterministic, hash-pinned and fully controlled"
# negative control: a check name a suite uses but the judge does not define must turn the structure check RED
cp -r "${SUITES}" "${TEST_TMP}/suites_bogus"
python3 -I - "${TEST_TMP}/suites_bogus/chat-v1/suite.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["cases"][0]["checks"]["bogus_check"] = 1; json.dump(d, open(p, "w"))
PY
rep2="$(python3 -I "${TEST_TMP}/structure.py" "${TEST_TMP}/suites_bogus" "${JUDGE}")" && rc2=0 || rc2=$?
assert_eq 1 "${rc2}" "a suite naming a check the judge does not know is refused"
assert_contains "${rep2}" "chat-v1: unknown check bogus_check" "...and the unknown check is named"
gaps="$(grep -c '^    | GAP:' <<<"$(printf '%s\n' "${report}" | sed 's/^/    | /')" || true)"
if [[ "${gaps}" != "0" ]]; then
  assert_skip "vision-golden-v1 has ${gaps} probes without BOTH a canned PASS and a canned FAIL judge control (the text suites have full coverage); the vision probes are still proven to discriminate in section 3b" "per-probe judge-control completeness of the vision suite"
fi
assert_contains "${report}" "chat-v1" "chat-v1 present"
assert_contains "${report}" "coder-v1" "coder-v1 present"
assert_contains "${report}" "embedding-v1" "embedding-v1 present"
assert_contains "${report}" "vision-golden-v1" "vision-golden-v1 present"
assert_contains "${report}" "decide-v1" "decide-v1 present"

echo "== 2. judge self-test of every judged suite"
for s in chat-v1 coder-v1 vision-golden-v1 decide-v1; do
  assert_eq 0 "$(run_rc python3 -I "${JUDGE}" selftest --suite "${SUITES}/${s}")" "self-test green: ${s}"
done

echo "== 3. every text probe discriminates: one garbage answer turns the run RED and names that probe"
for s in chat-v1 coder-v1; do
  for id in $(python3 -c 'import json,sys; print(" ".join(c["id"] for c in json.load(open(sys.argv[1]))["cases"]))' "${SUITES}/${s}/suite.json"); do
    ans="$(mktemp "${TEST_TMP}/ans.XXXXXX")"
    python3 -I - "${FIX}/answers_good.json" "${id}" "${ans}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d[sys.argv[2]] = "zzz qqq"; json.dump(d, open(sys.argv[3], "w"))
PY
    U="$(fake_start "${ans}" --model-id /m/x.gguf)"
    assert_eq 1 "$(run_rc python3 -I "${JUDGE}" run --suite "${SUITES}/${s}" --endpoint "${U}")" "${s}/${id}: garbage answer -> exit 1"
    assert_contains "$(cat "${TEST_TMP}/last.out")" "[FAIL] ${id}" "${s}/${id}: the failing probe is named"
  done
  U="$(fake_start "${FIX}/answers_good.json" --model-id /m/x.gguf)"
  assert_eq 0 "$(run_rc python3 -I "${JUDGE}" run --suite "${SUITES}/${s}" --endpoint "${U}")" "${s}: the good answer table passes (the discrimination above is not a broken fixture)"
done

echo "== 3b. every vision probe discriminates"
for key in $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(" ".join("%s/%s"%(f["id"],p["id"]) for f in d["fixtures"] if not f.get("role")=="control-bad" for p in f["probes"]))' "${SUITES}/vision-golden-v1/expectations.json"); do
  ans="$(mktemp "${TEST_TMP}/ans.XXXXXX")"
  python3 -I - "${FIX}/answers_good.json" "${key}" "${ans}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d[sys.argv[2]] = "zzz qqq"; json.dump(d, open(sys.argv[3], "w"))
PY
  U="$(fake_start "${ans}" --model-id /m/vision/gemma-3-4b-it-Q4_K_M.gguf)"
  assert_eq 1 "$(run_rc python3 -I "${JUDGE}" run --suite "${SUITES}/vision-golden-v1" --endpoint "${U}")" "vision ${key}: garbage answer -> exit 1"
  assert_contains "$(cat "${TEST_TMP}/last.out")" "[FAIL] ${key}" "vision ${key}: the failing probe is named"
done

echo "== 4. embedding suite: ordered vectors pass, swapped vectors fail"
U="$(fake_start "${FIX}/answers_good.json" --model-id /m/embed.gguf)"
assert_eq 0 "$(run_rc python3 -I "${JUDGE}" run --suite "${SUITES}/embedding-v1" --endpoint "${U}")" "embedding-v1 passes with ordered vectors"
EM="$(mktemp "${TEST_TMP}/emb.XXXXXX")"
python3 -I - "${FIX}/answers_good.json" "${EM}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); e = d["embeddings"]
e["a kitten naps on the couch"], e["the quarterly tax filing deadline"] = e["the quarterly tax filing deadline"], e["a kitten naps on the couch"]
json.dump(d, open(sys.argv[2], "w"))
PY
U="$(fake_start "${EM}" --model-id /m/embed.gguf)"
assert_eq 1 "$(run_rc python3 -I "${JUDGE}" run --suite "${SUITES}/embedding-v1" --endpoint "${U}")" "embedding-v1 fails with swapped positive/negative"
assert_eq 2 "$(run_rc python3 -I "${JUDGE}" run --suite "${SUITES}/embedding-v1" --endpoint http://127.0.0.1:9)" "embedding-v1 against a dead endpoint is UNDETERMINED, never PASS"

echo "== 5. suite content hash covers every file (a changed byte changes the hash)"
h1="$(python3 -I "${JUDGE}" hash --suite "${SUITES}/chat-v1")"
cp -r "${SUITES}/chat-v1" "${TEST_TMP}/chat_copy"
sed -i 's/Which number is larger/Which number is bigger/' "${TEST_TMP}/chat_copy/suite.json"
h2="$(python3 -I "${JUDGE}" hash --suite "${TEST_TMP}/chat_copy")"
if [[ "${h1}" != "${h2}" && ${#h1} -eq 64 ]]; then printf '  ok: one edited word changes the suite hash\n'; else printf '  FAIL: suite hash did not change\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi

test_finish
