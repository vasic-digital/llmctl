#!/usr/bin/env bash
# test_validation_decide_colibri.sh - RED-first (independent review 2026-10-14, finding 2). Some profiles could NEVER be
# validated:
#   * the 12 decide-* profiles named an EMPTY suite list (llmctl validate -> "no llmctl validation suite", exit 2 forever);
#   * the colibri profiles were always UNDETERMINED: _val_expect_model expected the first catalog file (config.hf.json /
#     config.json) while colibri's /v1/models reports family.default_model_id (submodules/colibri/c/openai_server.py:4552
#     and :3761-3763; family_registry.py:1218 'qwen3.6-colibri' for model_type qwen3_5_moe_text, :1093 'glm-5.2-colibri').
# Now: every decide profile names the decide-v1 suite (known-answer choice questions asked through the production Go
# driver of its protocol: `llmctl-decide smoke --question-file`), the colibri profiles name their served model id in the
# catalog (validation.expect_model_id), and suites/profiles never run against a real model are marked unexecuted and
# reported by validate-all as NOT VALIDATED. A live colibri or decide run is NOT possible on the authoring host: the
# fixtures below mirror the shapes those engines report; the live behaviour is UNCONFIRMED (docs/validation.md).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
source "$(dirname "${BASH_SOURCE[0]}")/validation_local_lib.sh"
trap 'vl_cleanup; test_teardown_env' EXIT
vl_setup
L="${VL_LLMCTL}"
J="${LLMCTL_ROOT}/lib/validate_judge.py"
CAT="${LLMCTL_ROOT}/models/catalog.json"

echo "== 1. the catalog: every profile names at least one existing suite; decide-* name decide-v1; colibri names its served id"
res="$(python3 -I - "${CAT}" "${LLMCTL_ROOT}/validation/suites" <<'PY'
import json, os, sys
c = json.load(open(sys.argv[1]))["profiles"]
empty = [n for n, p in c.items() if not (p.get("validation") or {}).get("suites")]
missing = [(n, s) for n, p in c.items() for s in (p.get("validation") or {}).get("suites", [])
           if not os.path.isdir(os.path.join(sys.argv[2], s))]
dec = sorted(n for n, p in c.items() if "decide" in (p.get("capability") or []))
dec_ok = all("decide-v1" in c[n]["validation"]["suites"] for n in dec)
col = {n: (p.get("validation") or {}).get("expect_model_id") for n, p in c.items() if p.get("engine") == "colibri"}
print(len(empty), len(missing), len(dec), dec_ok, json.dumps(col, sort_keys=True))
PY
)"
assert_eq '0 0 12 True {"colibri-glm": "glm-5.2-colibri", "colibri-qwen36": "qwen3.6-colibri"}' "${res}" \
  "no profile with an empty suite list, no missing suite, 12 decide profiles on decide-v1, colibri served ids"
unex="$(python3 -I -c 'import json,sys; c=json.load(open(sys.argv[1]))["profiles"]; print(" ".join(sorted(n for n,p in c.items() if (p.get("validation") or {}).get("executed") is False)))' "${CAT}")"
for n in colibri-glm colibri-qwen36 decide decide-tiny decide-nli; do
  assert_contains " ${unex} " " ${n} " "${n} is marked validation.executed=false (never run against its real model here)"
done
assert_eq unexecuted "$(vl_json "${LLMCTL_ROOT}/validation/suites/decide-v1/suite.json" 'd.get("execution_status")')" "decide-v1 says its expectations were never executed against a real model"
assert_eq 0 "$(vl_rc python3 -I "${J}" selftest --suite "${LLMCTL_ROOT}/validation/suites/decide-v1")" "decide-v1 judge self-test green ($(tail -1 "${TEST_TMP}/last.out"))"

echo "== 2. colibri: the served id is the family default model id, not the first catalog file"
pf="${TEST_TMP}/port.col"
python3 -I "${VL_FIX}/fake_openai.py" --suite "${LLMCTL_ROOT}/validation/suites/chat-v1" --suite "${LLMCTL_ROOT}/validation/suites/coder-v1" \
  --answers "${VL_FIX}/answers_good.json" --port-file "${pf}" --model-id qwen3.6-colibri --owned-by colibri >/dev/null 2>&1 &
echo "$!" >> "${VL_PIDS_FILE}"
for (( i=0; i<100; i++ )); do [[ -s "${pf}" ]] && break; sleep 0.1; done
COLU="http://127.0.0.1:$(cat "${pf}")"
assert_contains "$(curl -s "${COLU}/v1/models")" '"owned_by": "colibri"' "the fixture mirrors colibri's /v1/models shape (model_object: id, object, created, owned_by)"
assert_eq 0 "$(vl_rc "${L}" validate colibri-qwen36 --host "${COLU}")" "colibri-qwen36 against a colibri-shaped endpoint -> PASS (was always UNDETERMINED)"
assert_eq 2 "$(vl_rc "${L}" validate colibri-glm --host "${COLU}")" "colibri-glm against a qwen3.6 endpoint -> UNDETERMINED (wrong model)"
assert_contains "$(cat "${TEST_TMP}/last.out")" "not the expected model glm-5.2-colibri" "the expected glm id is named"
ex() { bash -c 'for l in common os_detect hardware catalog; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done; source "${LLMCTL_ROOT}/lib/validate.sh"; "$@"' _ "$@"; }
assert_eq "qwen3.6-colibri" "$(ex _val_expect_model colibri-qwen36)" "_val_expect_model colibri-qwen36"
assert_eq "Llama-3.2-3B-Instruct-Q4_K_M.gguf" "$(ex _val_expect_model small)" "control: a llama profile still expects its model file"
assert_eq "${LLMCTL_MODELS_DIR}/colibri-qwen36" "$(ex _val_expect_model_path colibri-qwen36)" "a colibri server loads the profile DIRECTORY"

echo "== 3. decide: known-answer choice questions through the decide driver (a STUB of llmctl-decide; the real flag is checked in section 5)"
STUB="${TEST_TMP}/bin/llmctl-decide"
cat > "${STUB}" <<'SH'
#!/usr/bin/env python3
# stub of `llmctl-decide smoke --question-file F --json`: answers from a table keyed by the question's instructions
import json, os, sys
a = sys.argv[1:]
if a[:1] != ["smoke"] or "--question-file" not in a:
    sys.exit(2)
log = os.environ.get("DECIDE_STUB_LOG")
if log:
    open(log, "a").write(" ".join(a) + "\n")
mode = os.environ.get("DECIDE_STUB_MODE", "good")
if mode == "unreachable":
    sys.stderr.write("llmctl-decide smoke: smoke: engine unreachable\n"); sys.exit(6)
q = json.load(open(a[a.index("--question-file") + 1]))["questions"]["q"]
table = json.load(open(os.environ["DECIDE_STUB_TABLE"]))
choice = table[q["instructions"]]
if mode == "wrong" and q["instructions"].startswith("Which team reviews"):
    choice = "billing"
cnt = os.environ.get("DECIDE_STUB_COUNT")
n = 0
if cnt:
    n = int(open(cnt).read() or 0) if os.path.exists(cnt) else 0
    open(cnt, "w").write(str(n + 1))
conf = 0.9
if mode == "flaky" and n >= 2:
    conf = 0.8
keys = list(q["criteria"])
probs = {k: (conf if k == choice else round((1 - conf) / (len(keys) - 1), 6)) for k in keys}
print(json.dumps({"protocol": a[a.index("--protocol") + 1], "type": "choice", "choice": choice, "confidence": conf,
                  "ok": True, "probabilities": probs}))
SH
chmod +x "${STUB}"
python3 -I - "${LLMCTL_ROOT}/validation/suites/decide-v1/suite.json" "${TEST_TMP}/table.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
json.dump({c["question"]["instructions"]: c["checks"]["choice_equals"] for c in d["cases"]}, open(sys.argv[2], "w"))
PY
export DECIDE_STUB_TABLE="${TEST_TMP}/table.json" DECIDE_STUB_LOG="${TEST_TMP}/stub.log" LLMCTL_DECIDE_BIN="${STUB}"
DU="http://127.0.0.1:9"   # the stub never connects; a loopback URL as the real driver requires
assert_eq 0 "$(vl_rc "${L}" validate decide --host "${DU}")" "decide (letter-logit) with the right choices -> PASS"
out="$(cat "${TEST_TMP}/last.out")"
assert_contains "${out}" "suite decide-v1" "decide-v1 ran"
assert_contains "$(cat "${TEST_TMP}/stub.log")" "--protocol letter-logit" "the profile's protocol is passed to the driver"
assert_contains "${out}" "repeat=3 byte-identical" "every decision question is asked 3 times"
assert_eq 0 "$(vl_rc "${L}" validate decide-kev-4b --host "${DU}")" "decide-kev-4b (systemone-native) -> PASS"
assert_contains "$(cat "${TEST_TMP}/stub.log")" "--protocol systemone-native" "systemone-native is passed"
assert_eq 1 "$(vl_rc env DECIDE_STUB_MODE=wrong "${L}" validate decide --host "${DU}")" "a WRONG choice -> FAIL (exit 1)"
assert_contains "$(cat "${TEST_TMP}/last.out")" "choice_equals" "the wrong choice is named"
rm -f "${TEST_TMP}/cnt"
assert_eq 1 "$(vl_rc env DECIDE_STUB_MODE=flaky DECIDE_STUB_COUNT="${TEST_TMP}/cnt" "${L}" validate decide --host "${DU}")" "third answer differs (probabilities) -> FAIL (determinism)"
assert_eq 2 "$(vl_rc env DECIDE_STUB_MODE=unreachable "${L}" validate decide --host "${DU}")" "engine unreachable (driver exit 6) -> UNDETERMINED"
assert_eq 2 "$(vl_rc "${L}" validate decide-tiny --host "${DU}")" "decide-tiny (jev-verdict: no driver implements it) -> UNDETERMINED, never green"
assert_contains "$(cat "${TEST_TMP}/last.out")" "jev-verdict" "the reason names the unimplemented protocol"
assert_eq 2 "$(vl_rc env LLMCTL_DECIDE_BIN="${TEST_TMP}/nonexistent" "${L}" validate decide --host "${DU}")" "no decide driver binary -> UNDETERMINED"

echo "== 4. validate-all reports every never-executed / unvalidated catalog profile as NOT VALIDATED"
U="$(vl_fake_start "${VL_FIX}/answers_good.json")"; vl_mark_running "${U##*:}"
rc="$(vl_rc "${L}" validate-all)"
out="$(cat "${TEST_TMP}/last.out")"
assert_contains "${out}" "vision: PASS" "the running profile is validated"
assert_contains "${out}" "NOT VALIDATED" "the coverage section exists"
for n in decide decide-tiny colibri-glm colibri-qwen36 fast; do
  assert_contains "${out}" "${n}: NOT VALIDATED" "${n} is listed as NOT VALIDATED"
done
assert_contains "${out}" "never executed against its real model" "the unexecuted ones say so"
if grep -qE '^ *decide(-[a-z0-9]+)?: PASS' <<<"${out}"; then printf '  FAIL: a decide profile is reported green\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: no decide profile is reported green\n'; fi
rm -f "${LLMCTL_RUNTIME_DIR}/vision.run"

echo "== 5. the REAL llmctl-decide (built from this tree) has the --question-file flag the validator relies on"
if command -v go >/dev/null 2>&1; then
  ( cd "${LLMCTL_ROOT}" && go build -o "${TEST_TMP}/real-decide" ./cmd/llmctl-decide ) >"${TEST_TMP}/build.out" 2>&1 || true
  if [[ -x "${TEST_TMP}/real-decide" ]]; then
    printf '{"model":"smoke","state":"s","questions":{"q":{"type":"choice","instructions":"i","criteria":{"a":"x","b":"y"}}}}' > "${TEST_TMP}/q.json"
    rc=0; "${TEST_TMP}/real-decide" smoke --url http://127.0.0.1:9 --protocol letter-logit --question-file "${TEST_TMP}/q.json" >/dev/null 2>&1 || rc=$?
    assert_eq 6 "${rc}" "real binary: --question-file accepted, closed port -> 6 (unreachable), the stub's contract"
    rc=0; "${TEST_TMP}/real-decide" smoke --url http://127.0.0.1:9 --protocol letter-logit --question-file /nonexistent >/dev/null 2>&1 || rc=$?
    assert_eq 2 "${rc}" "real binary: unreadable question file -> 2"
  else
    assert_skip "go build failed: $(tail -1 "${TEST_TMP}/build.out")" "real llmctl-decide --question-file"
  fi
else
  assert_skip "go is not installed" "real llmctl-decide --question-file"
fi

test_finish
