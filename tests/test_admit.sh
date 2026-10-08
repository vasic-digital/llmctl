#!/usr/bin/env bash
# test_admit.sh - admission gate (lib/admit.sh, `llmctl admit`), T090.
#
# Network-free: the Hugging Face API is served from tests/fixtures/admission/
# by a local HTTP server (127.0.0.1, ephemeral port) selected through
# LLMCTL_HF_BASE. Golden-good AND golden-bad fixtures: every gate that can
# reject is shown rejecting (a gate never seen to FAIL is unvalidated).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

FIX="${LLMCTL_ROOT}/tests/fixtures/admission"
LLMCTL="${LLMCTL_ROOT}/bin/llmctl"

AUTH_LOG="${TEST_TMP}/auth.log" python3 "${FIX}/server.py" "${FIX}" "${TEST_TMP}/port" &
SRV_PID=$!
trap 'kill "${SRV_PID}" 2>/dev/null || true; test_teardown_env' EXIT
for _ in $(seq 1 50); do [[ -s "${TEST_TMP}/port" ]] && break; sleep 0.1; done
PORT="$(cat "${TEST_TMP}/port")"

export LLMCTL_HF_BASE="http://127.0.0.1:${PORT}"
export LLMCTL_ADMIT_EVIDENCE_DIR="${TEST_TMP}/evidence"
export LLMCTL_ADMIT_LLAMA_SRC="${FIX}/llama_src"
export LLMCTL_ADMIT_CANDIDATES="${FIX}/candidates.tsv"
export LLMCTL_ADMIT_DELAY=0
export LLMCTL_ADMIT_MEM_BYTES=$((64*1024*1024*1024))
unset HF_TOKEN LLMCTL_ADMIT_REAL_RUN || true

# run <repo> [args...]: captures JSON on stdout into $OUT and rc into $RC.
run() { RC=0; OUT="$("${LLMCTL}" admit "$@" --json 2>"${TEST_TMP}/err")" || RC=$?; }
# jf <python-expr over d>: evaluate an expression against the JSON in $OUT.
jf() { printf '%s' "${OUT}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

echo "== usage / dispatch =="
rc=0; "${LLMCTL}" admit >/dev/null 2>&1 || rc=$?
assert_eq 2 "${rc}" "admit with no argument is a usage error (rc 2)"
assert_contains "$("${LLMCTL}" help 2>&1)" "admit" "usage text lists admit"

echo "== golden-good: permitted licence, pinned sha256, supported protocol =="
run fixt/good-letter-gguf --paper-only --protocol letter-logit --pin good-Q4_K_M.gguf
assert_eq 0 "${RC}" "good candidate exits 0"
assert_eq ADMIT-CANDIDATE "$(jf 'd["disposition"]')" "paper-only pass is ADMIT-CANDIDATE (real run still owed)"
assert_eq PASS "$(jf '[g["status"] for g in d["gates"] if g["gate"]=="G1"][0]')" "G1 licence PASS"
assert_eq PASS "$(jf '[g["status"] for g in d["gates"] if g["gate"]=="G3"][0]')" "G3 size+sha256 pinned PASS"
assert_eq PASS "$(jf '[g["status"] for g in d["gates"] if g["gate"]=="G4"][0]')" "G4 arch exists in pinned engine tree PASS"
assert_eq PENDING "$(jf '[g["status"] for g in d["gates"] if g["gate"]=="G10"][0]')" "G10 real run PENDING in paper-only"
assert_eq "0123456789abcdef0123456789abcdef01234567" "$(jf 'd["api"]["sha"]')" "revision sha recorded"
assert_eq "$(printf 'a%.0s' $(seq 1 64))" "$(jf 'd["pins"][0]["sha256"]')" "pinned sha256 comes from the API LFS oid"
assert_eq 529296864 "$(jf 'd["pins"][0]["size"]')" "pinned size comes from the API"
assert_eq VERIFIED "$(jf 'd["existence"]["verdict"]')" "existence VERIFIED on HTTP 200"
assert_eq 5 "$(jf 'len(d["g10_subchecks"])')" "five real-run sub-checks listed"
assert_eq "PENDING" "$(jf 'sorted({s["status"] for s in d["g10_subchecks"]})[0]')" "all sub-checks PENDING in paper-only"
assert_file_exists "${LLMCTL_ADMIT_EVIDENCE_DIR}/fixt__good-letter-gguf.json" "outcome file written under the slug name"
assert_eq "fixt__good-letter-gguf" "$(jf 'd["slug"]')" "slug recorded"

echo "== golden-bad: forbidden licence MUST be rejected =="
run fixt/forbidden-licence --paper-only --protocol letter-logit
assert_eq 11 "${RC}" "NC licence exits 11 (REJECTED)"
assert_eq REJECTED "$(jf 'd["disposition"]')" "cc-by-nc-4.0 weights are REJECTED"
assert_eq FAIL "$(jf '[g["status"] for g in d["gates"] if g["gate"]=="G1"][0]')" "G1 FAIL on non-commercial licence"
assert_contains "$(jf 'd["reasons"]')" "cc-by-nc-4.0" "reason names the licence"

echo "== golden-bad: unknown licence fails closed =="
run fixt/unknown-licence --paper-only --protocol letter-logit
assert_eq REJECTED "$(jf 'd["disposition"]')" "no stated licence is REJECTED (fail closed)"
assert_contains "$(jf '[g["evidence"] for g in d["gates"] if g["gate"]=="G1"][0]')" "unknown" "G1 evidence says licence unknown"

echo "== golden-bad: GGUF over budget is USER-ONLY =="
run fixt/over-budget-gguf --paper-only --protocol letter-logit
assert_eq 10 "${RC}" "over-budget exits 10 (USER-ONLY)"
assert_eq USER-ONLY "$(jf 'd["disposition"]')" "12.7 GB GGUF is USER-ONLY"
assert_eq FAIL "$(jf '[g["status"] for g in d["gates"] if g["gate"]=="G5"][0]')" "G5 FAIL over file budget"
LLMCTL_ADMIT_MAX_BYTES=20000000000 run fixt/over-budget-gguf --paper-only --protocol letter-logit
assert_eq PASS "$(jf '[g["status"] for g in d["gates"] if g["gate"]=="G5"][0]')" "same file passes G5 when the budget is raised (the gate is the budget, not the file)"

echo "== memory fit uses the host memory budget =="
LLMCTL_ADMIT_MEM_BYTES=100000000 run fixt/good-letter-gguf --paper-only --protocol letter-logit --pin good-Q4_K_M.gguf
assert_eq FAIL "$(jf '[g["status"] for g in d["gates"] if g["gate"]=="G5"][0]')" "G5 FAIL when estimated memory exceeds the host budget"

echo "== other rejecting gates =="
run fixt/gated-model --paper-only --protocol letter-logit
assert_eq FAIL "$(jf '[g["status"] for g in d["gates"] if g["gate"]=="G2"][0]')" "G2 FAIL on a gated repo"
assert_eq USER-ONLY "$(jf 'd["disposition"]')" "gated repo is USER-ONLY"
run fixt/pickle-pin --paper-only --protocol letter-logit --pin weights.bin
assert_eq FAIL "$(jf '[g["status"] for g in d["gates"] if g["gate"]=="G7"][0]')" "G7 FAIL on a pickle-format pin"
run fixt/non-lfs-model --paper-only --protocol letter-logit
assert_eq FAIL "$(jf '[g["status"] for g in d["gates"] if g["gate"]=="G3"][0]')" "G3 FAIL when the model file has no LFS sha256"
run fixt/safetensors-only --paper-only --protocol letter-logit
assert_eq FAIL "$(jf '[g["status"] for g in d["gates"] if g["gate"]=="G3"][0]')" "G3 FAIL when nothing pinnable (safetensors only)"
assert_eq USER-ONLY "$(jf 'd["disposition"]')" "no pinnable artifact is USER-ONLY"
run fixt/arch-missing --paper-only --protocol letter-logit
assert_eq FAIL "$(jf '[g["status"] for g in d["gates"] if g["gate"]=="G4"][0]')" "G4 FAIL when the GGUF architecture is absent from the pinned tree"
run otherowner/author-mismatch --paper-only --protocol letter-logit
assert_eq FAIL "$(jf '[g["status"] for g in d["gates"] if g["gate"]=="G8"][0]')" "G8 FAIL when the API author differs from the repo owner"
run fixt/known-issue --paper-only --protocol letter-logit --known-issue "block:upstream bug #1 on this exact file"
assert_eq 12 "${RC}" "blocking known issue exits 12 (HOLD)"
assert_eq HOLD "$(jf 'd["disposition"]')" "blocking known issue is HOLD"
run fixt/known-issue --paper-only --protocol letter-logit --known-issue "note:batch size caveat"
assert_eq ADMIT-CANDIDATE "$(jf 'd["disposition"]')" "a non-blocking note does not block"
assert_eq PENDING "$(jf '[g["status"] for g in d["gates"] if g["gate"]=="G9"][0]')" "G9 stays PENDING (live tracker sweep not done) with a note"

echo "== protocol classification =="
run fixt/native-decision --paper-only --protocol systemone-native
assert_eq systemone-native "$(jf 'd["protocol"]["class"]')" "native decision GGUF classified systemone-native"
assert_eq PENDING "$(jf '[g["status"] for g in d["gates"] if g["gate"]=="G4"][0]')" "G4 PENDING: pinned tree lacks /v1/systemone (engine advance, FR-085)"
assert_eq ADMIT-CANDIDATE "$(jf 'd["disposition"]')" "native model is ADMIT-CANDIDATE pending the engine advance"
assert_eq True "$(jf 'd["needs_engine_advance"]')" "needs_engine_advance recorded"
run fixt/arch-missing --paper-only --protocol systemone-native
assert_eq FAIL "$(jf '[g["status"] for g in d["gates"] if g["gate"]=="G4"][0]')" "native model whose arch is absent from the pinned tree is FAIL (a bump is not proven to add it)"
run fixt/native-decision --paper-only
assert_eq systemone-native "$(jf 'd["protocol"]["class"]')" "gguf.decision_type alone classifies native (API-derived, no curated hint)"
run fixt/known-issue --paper-only
assert_eq FAIL "$(jf '[g["status"] for g in d["gates"] if g["gate"]=="G6"][0]')" "G6 FAIL: no hint and no API signal -> unsupported (fail closed)"
run fixt/nli-good --paper-only --protocol nli-onnx --pin onnx/model.onnx --pin onnx/spm.model
assert_eq PASS "$(jf '[g["status"] for g in d["gates"] if g["gate"]=="G6"][0]')" "nli-onnx with tokenizer file PASS"
run fixt/nli-no-tokenizer --paper-only --protocol nli-onnx --pin onnx/model.onnx
assert_eq FAIL "$(jf '[g["status"] for g in d["gates"] if g["gate"]=="G6"][0]')" "nli-onnx without a tokenizer file FAIL"

echo "== existence verdicts =="
run fixt/does-not-exist --paper-only
assert_eq 13 "${RC}" "missing repo exits 13 (NOT-FOUND)"
assert_eq NOT-FOUND "$(jf 'd["disposition"]')" "404 -> NOT-FOUND"
assert_eq UNVERIFIED "$(jf 'd["existence"]["verdict"]')" "404 -> existence UNVERIFIED"
run fixt/private-or-missing --paper-only
assert_eq AMBIGUOUS "$(jf 'd["existence"]["verdict"]')" "401 -> existence AMBIGUOUS (private and missing look alike)"
assert_eq NOT-FOUND "$(jf 'd["disposition"]')" "401 -> NOT-FOUND"

echo "== real-run executor (non paper-only) =="
LLMCTL_ADMIT_REAL_RUN="${FIX}/real_run_ok.sh" run fixt/good-letter-gguf --protocol letter-logit --pin good-Q4_K_M.gguf
assert_eq 0 "${RC}" "real-run pass exits 0"
assert_eq PASS "$(jf '[g["status"] for g in d["gates"] if g["gate"]=="G10"][0]')" "G10 PASS from the executor"
assert_eq ADMIT-CANDIDATE "$(jf 'd["disposition"]')" "G9 still PENDING (no live sweep) -> not ADMITTED yet"
LLMCTL_ADMIT_REAL_RUN="${FIX}/real_run_ok.sh" run fixt/good-letter-gguf --protocol letter-logit --pin good-Q4_K_M.gguf --known-issue "none-verified:live tracker sweep 2026-10-07 found none"
assert_eq ADMITTED "$(jf 'd["disposition"]')" "all ten gates PASS -> ADMITTED"
LLMCTL_ADMIT_REAL_RUN="${FIX}/real_run_bad.sh" run fixt/good-letter-gguf --protocol letter-logit --pin good-Q4_K_M.gguf
assert_eq FAIL "$(jf '[g["status"] for g in d["gates"] if g["gate"]=="G10"][0]')" "failing real run -> G10 FAIL"
assert_eq USER-ONLY "$(jf 'd["disposition"]')" "failing real run is never ADMITTED"
run fixt/good-letter-gguf --protocol letter-logit --pin good-Q4_K_M.gguf
assert_eq PENDING "$(jf '[g["status"] for g in d["gates"] if g["gate"]=="G10"][0]')" "no executor configured -> G10 PENDING, never a faked PASS"

echo "== HF_TOKEN honoured, never persisted =="
: > "${TEST_TMP}/auth.log"
HF_TOKEN="hf_SECRETTOKENVALUE123" run fixt/good-letter-gguf --paper-only --protocol letter-logit --pin good-Q4_K_M.gguf
assert_file_contains "${TEST_TMP}/auth.log" "Bearer hf_SECRETTOKENVALUE123" "token sent as a bearer header"
leak=0
grep -rqF "hf_SECRETTOKENVALUE123" "${LLMCTL_ADMIT_EVIDENCE_DIR}" "${TEST_TMP}/err" 2>/dev/null && leak=1
grep -qF "hf_SECRETTOKENVALUE123" <<<"${OUT}" && leak=1
assert_eq 0 "${leak}" "token appears in no output, evidence file or stderr"

echo "== batch + summary =="
rm -rf "${LLMCTL_ADMIT_EVIDENCE_DIR}"
rc=0; "${LLMCTL}" admit --all --paper-only >"${TEST_TMP}/all.out" 2>&1 || rc=$?
assert_eq 0 "${rc}" "--all completes (rc 0) even though dispositions differ"
assert_file_exists "${LLMCTL_ADMIT_EVIDENCE_DIR}/SUMMARY.json" "SUMMARY.json written"
assert_file_exists "${LLMCTL_ADMIT_EVIDENCE_DIR}/SUMMARY.md" "SUMMARY.md written"
S="$(cat "${LLMCTL_ADMIT_EVIDENCE_DIR}/SUMMARY.json")"
sj() { printf '%s' "${S}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }
assert_eq 5 "$(sj 'd["total"]')" "five candidate records"
assert_eq 2 "$(sj 'd["by_disposition"]["REJECTED"]')" "two REJECTED (NC licence + harness without weights)"
assert_eq 1 "$(sj 'd["by_disposition"]["NOT-FOUND"]')" "one NOT-FOUND"
assert_eq 2 "$(sj 'd["by_disposition"]["ADMIT-CANDIDATE"]')" "two ADMIT-CANDIDATE"
assert_eq "['fixt/does-not-exist']" "$(sj '[c["repo"] for c in d["candidates"] if c["disposition"]=="NOT-FOUND"]')" "NOT-FOUND repo listed"
assert_contains "$(sj 'd["admit_candidates_needing_real_runs"]')" "llmctl admit fixt/good-letter-gguf" "exact real-run command listed"
assert_file_exists "${LLMCTL_ADMIT_EVIDENCE_DIR}/harness.json" "non-HF name gets a record too"
assert_eq UNVERIFIED "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["existence"]["verdict"])' "${LLMCTL_ADMIT_EVIDENCE_DIR}/harness.json")" "non-HF name existence UNVERIFIED (not probed)"
assert_file_contains "${LLMCTL_ADMIT_EVIDENCE_DIR}/SUMMARY.md" "ADMIT-CANDIDATE" "SUMMARY.md lists dispositions"

echo "== C-19: the scratch directory is removed even when the evaluation dies (and TMPDIR may hold a quote) =="
SCR="${TEST_TMP}/it's scratch"; mkdir -p "${SCR}"
rc=0
( export TMPDIR="${SCR}"
  source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/admit.sh"
  _admit_eval() { return 1; }                       # the python evaluation fails -> die
  _admit_one - cand - auto - - - weights full 0 0 ) >/dev/null 2>&1 || rc=$?
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "the failing evaluation dies (non-zero exit)"
assert_eq "" "$(ls -A "${SCR}")" "...and left no scratch directory behind in TMPDIR (even with a ' in the path)"
rc=0
( export TMPDIR="${SCR}"
  source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/admit.sh"
  _admit_one - cand - auto - - - weights paper-only 1 0 ) >/dev/null 2>&1 || rc=$?
assert_eq "" "$(ls -A "${SCR}")" "a normal run cleans its scratch directory too"

test_finish
