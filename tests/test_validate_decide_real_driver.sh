#!/usr/bin/env bash
# test_validate_decide_real_driver.sh - the validator's decide suites against the REAL production driver (llmctl-decide
# smoke --question-file built from THIS tree), not a stub.
#
# Root cause (2026-10-26, captured: the live `llmctl restart decide-max` printed
#   "[UNDETERMINED] ... smoke: invalid configuration: question file refused: Unknown model."  5/5 cases):
#   lib/validate_judge.py decide_ask() wrote {"model": "validate", ...} into the question file, but the smoke driver
#   parses the file against ONE profile (internal/gateway/smoke.go BuildProfiles(..., "smoke", ...)) so the only model id
#   it serves is "smoke"; every other id is refused (gateway-shaped 422 "Unknown model.", driver exit 2).  Every decide
#   profile therefore ended UNDETERMINED on a real engine and, under the strict default, was stopped ("an unvalidated model
#   is never served").  The stub-based test (test_validation_decide_colibri.sh section 3) never reads the "model" field and
#   its section 5 dials a CLOSED port, which the driver reports (exit 6) BEFORE it parses the question file: both were
#   structurally unable to see the defect.  This suite closes that gap with a real driver and a LISTENING fake letter-logit
#   engine, and proves it is not vacuous with two controls (a wrong-answering engine must FAIL; the pre-fix model id must
#   turn the suite RED).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
require_containers_or_skip
source "$(dirname "${BASH_SOURCE[0]}")/validation_local_lib.sh"
trap 'vl_cleanup; test_teardown_env' EXIT
vl_setup
L="${VL_LLMCTL}"
J="${LLMCTL_ROOT}/lib/validate_judge.py"

if ! ( cd "${LLMCTL_ROOT}" && go build -o "${TEST_TMP}/real-decide" ./cmd/llmctl-decide ) >"${TEST_TMP}/build.out" 2>&1; then
  skip_suite "go build of ./cmd/llmctl-decide failed: $(tail -1 "${TEST_TMP}/build.out")"
fi
export LLMCTL_DECIDE_BIN="${TEST_TMP}/real-decide"

python3 -I - "${LLMCTL_ROOT}/validation/suites/decide-v1/suite.json" "${TEST_TMP}/table.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
json.dump({c["question"]["instructions"]: c["checks"]["choice_equals"] for c in d["cases"]}, open(sys.argv[2], "w"))
PY

start_engine() { # start_engine <name> [--wrong] -> prints the base URL
  local name="$1"; shift
  local pf="${TEST_TMP}/port.${name}" i
  python3 -I "${LLMCTL_ROOT}/tests/fixtures/validation/fake_letter_engine.py" --table "${TEST_TMP}/table.json" --port-file "${pf}" "$@" >/dev/null 2>&1 &
  echo "$!" >> "${VL_PIDS_FILE}"
  for (( i=0; i<100; i++ )); do [[ -s "${pf}" ]] && break; sleep 0.1; done
  printf 'http://127.0.0.1:%s\n' "$(cat "${pf}")"
}
GOOD="$(start_engine good)"
BAD="$(start_engine bad --wrong)"
assert_contains "$(curl -s "${GOOD}/health")" '"ok"' "precondition: the fake letter-logit engine listens"

echo "== 1. a correct letter-logit engine is validated PASS through the real driver (exit 0)"
rc="$(vl_rc "${L}" validate decide --host "${GOOD}")"
out="$(cat "${TEST_TMP}/last.out")"
assert_eq 0 "${rc}" "decide against a correct engine -> PASS (was UNDETERMINED 'Unknown model.' on every real engine)"
assert_contains "${out}" "VERDICT: PASS" "the verdict line says PASS"
assert_contains "${out}" "repeat=3 byte-identical" "every decision was asked 3 times and answered byte-identically by the real driver"
if grep -q 'Unknown model' <<<"${out}"; then printf '  FAIL: the driver refused the question file (Unknown model)\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: no "Unknown model" refusal\n'; fi

echo "== 2. control: a wrong-answering engine is FAIL (exit 1) - the PASS above is not vacuous"
rc="$(vl_rc "${L}" validate decide --host "${BAD}")"
assert_eq 1 "${rc}" "decide against a wrong engine -> FAIL"
assert_contains "$(cat "${TEST_TMP}/last.out")" "choice_equals" "the failed expectation is named"

echo "== 3. paired mutation: the pre-fix model id must turn this suite RED"
M="${TEST_TMP}/tree.mut"
mkdir -p "${M}/bin" "${M}/lib"
for e in "${LLMCTL_ROOT}"/*; do case "$(basename "${e}")" in bin|lib) ;; *) ln -s "${e}" "${M}/$(basename "${e}")" ;; esac; done
cp "${LLMCTL_ROOT}/bin/llmctl" "${M}/bin/llmctl"
for f in "${LLMCTL_ROOT}"/lib/*; do [[ "$(basename "${f}")" == validate_judge.py ]] || ln -sf "${f}" "${M}/lib/"; done
python3 -I - "${J}" "${M}/lib/validate_judge.py" <<'PY'
import sys
src, dst = sys.argv[1:3]
s = open(src).read()
old = 'body = {"model": "smoke", "state": q["state"],'
if s.count(old) != 1:
    sys.exit("mutation anchor found %d times (the decide_ask body line moved?)" % s.count(old))
open(dst, "w").write(s.replace(old, 'body = {"model": "validate", "state": q["state"],'))
PY
if cmp -s "${J}" "${M}/lib/validate_judge.py"; then printf '  FAIL: the mutant is identical to the original (a no-op mutation proves nothing)\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: the mutant differs from the original\n'; fi
rc="$(vl_rc "${M}/bin/llmctl" validate decide --host "${GOOD}")"
assert_eq 2 "${rc}" "MUTANT (model 'validate') -> UNDETERMINED (exit 2): this suite goes RED on the original defect"
assert_contains "$(cat "${TEST_TMP}/last.out")" "Unknown model" "the mutant fails for the root-cause reason (the driver refuses the model id)"

test_finish
