#!/usr/bin/env bash
# test_validation_served_identity.sh - RED-first (independent review 2026-10-14, finding 6). The validation key described
# the files on disk / in the env file, not the PROCESS that answered the probes: a server loading another file whose
# /v1/models id merely had the same basename validated the profile. The judge now establishes the model file of the
# probed server - from /proc/<pid>/cmdline of the process listening on the (loopback) port (only processes of this user,
# Constitution 11.4.174), from absolute-path ids of /v1/models and from /props model_path - compares every one it finds
# with the profile's file (realpath), refuses a mismatch (UNDETERMINED, never a PASS record) and records what it found.
# Fixture server only (tests/fixtures/validation/fake_openai.py): its --model argument is never read, it only shapes the
# process cmdline exactly like llama-server's.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
source "$(dirname "${BASH_SOURCE[0]}")/validation_local_lib.sh"
trap 'vl_cleanup; test_teardown_env' EXIT
vl_setup
L="${VL_LLMCTL}"
REC="${LLMCTL_STATE_DIR}/validation/vision.json"
GOOD="${VL_FIX}/answers_good.json"
OTHER="${TEST_TMP}/elsewhere/gemma-3-4b-it-Q4_K_M.gguf"; mkdir -p "$(dirname "${OTHER}")"; cp "${VL_MODEL}" "${OTHER}"

echo "== 1. the probed process loads ANOTHER file (its cmdline says so) -> refused"
U="$(vl_fake_start "${GOOD}" --model "${OTHER}")"; vl_mark_running "${U##*:}"
assert_eq 2 "$(vl_rc "${L}" validate vision)" "server process loads a different file -> UNDETERMINED (exit 2)"
assert_contains "$(cat "${TEST_TMP}/last.out")" "${OTHER}" "the reason names the file the process really loads"
assert_eq undetermined "$(vl_json "${REC}" 'd["status"]')" "no PASS record for a profile whose served file is not its model (status undetermined)"
rm -f "${REC}"

echo "== 2. /v1/models names an absolute path with the right BASENAME in another directory -> refused"
pf="$(mktemp -u "${TEST_TMP}/p2.XXXXXX")"
python3 -I "${VL_FIX}/fake_openai.py" --suite "${LLMCTL_ROOT}/validation/suites/vision-golden-v1" --answers "${GOOD}" \
  --port-file "${pf}" --model-id "${OTHER}" >/dev/null 2>&1 & echo "$!" >> "${VL_PIDS_FILE}"
for (( i=0; i<100; i++ )); do [[ -s "${pf}" ]] && break; sleep 0.1; done
vl_mark_running "$(cat "${pf}")"
assert_eq 2 "$(vl_rc "${L}" validate vision)" "a same-basename path elsewhere is not the profile's model -> exit 2"
assert_contains "$(cat "${TEST_TMP}/last.out")" "not the profile's model file" "the mismatch is stated"
assert_eq undetermined "$(vl_json "${REC}" 'd["status"]')" "no PASS record (status undetermined)"
rm -f "${REC}"

echo "== 3. /props model_path names another file -> refused"
U="$(vl_fake_start "${GOOD}" --props-model-path "${OTHER}")"; vl_mark_running "${U##*:}"
assert_eq 2 "$(vl_rc "${L}" validate vision)" "/props names another file -> exit 2"
assert_eq undetermined "$(vl_json "${REC}" 'd["status"]')" "no PASS record (status undetermined)"
rm -f "${REC}"

echo "== 4. every source agrees (cmdline + /v1/models + /props) -> PASS, and the record says what was served"
U="$(vl_fake_start "${GOOD}" --model "${VL_MODEL}" --props-model-path "${VL_MODEL}")"; vl_mark_running "${U##*:}"
assert_eq 0 "$(vl_rc "${L}" validate vision)" "the served file is the profile's model -> PASS"
assert_eq "${VL_MODEL}" "$(vl_json "${REC}" 'd["served_model"]["path"]')" "the record names the served model path"
assert_eq True "$(vl_json "${REC}" 'd["served_model"]["confirmed"]')" "...as confirmed"
assert_eq "cmdline,props,v1/models" "$(vl_json "${REC}" '",".join(sorted(d["served_model"]["sources"]))')" "...by all three sources"
assert_eq "$(stat -c %s "${VL_MODEL}")" "$(vl_json "${REC}" 'd["served_model"]["size"]')" "...with its size"
assert_eq 0 "$(vl_rc "${L}" require-validated vision)" "require-validated accepts it"

echo "== 5. a symlink to the same file is the same file (realpath)"
ln -s "${VL_MODEL}" "${TEST_TMP}/link.gguf"
U="$(vl_fake_start "${GOOD}" --model "${TEST_TMP}/link.gguf")"; vl_mark_running "${U##*:}"
assert_eq 0 "$(vl_rc "${L}" validate vision)" "symlink to the profile's file -> PASS"

echo "== 6. nothing establishes the served file -> PASS is allowed but FLAGGED (never silent)"
pf="$(mktemp -u "${TEST_TMP}/p6.XXXXXX")"
python3 -I "${VL_FIX}/fake_openai.py" --suite "${LLMCTL_ROOT}/validation/suites/vision-golden-v1" --answers "${GOOD}" \
  --port-file "${pf}" --model-id "gemma-3-4b-it-Q4_K_M.gguf" >/dev/null 2>&1 & echo "$!" >> "${VL_PIDS_FILE}"
for (( i=0; i<100; i++ )); do [[ -s "${pf}" ]] && break; sleep 0.1; done
vl_mark_running "$(cat "${pf}")"
assert_eq 0 "$(vl_rc "${L}" validate vision)" "basename-only id, no model path anywhere -> still judged"
assert_contains "$(cat "${TEST_TMP}/last.out")" "served model file UNCONFIRMED" "the output flags that the served file was not established"
assert_eq False "$(vl_json "${REC}" 'd["served_model"]["confirmed"]')" "the record says confirmed=false"

test_finish
