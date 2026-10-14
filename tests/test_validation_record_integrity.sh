#!/usr/bin/env bash
# test_validation_record_integrity.sh - RED-first (independent review 2026-10-14, findings 3, 5 and 9).
#  (3) the validation record had no integrity protection and was not bound to the model's BYTES: model_sha256 hashed the
#      catalog's name:sha strings, files were compared by size+mtime only, and LLMCTL_VALIDATION_MAX_AGE=nan/inf was
#      accepted. Now: every model file is hashed for real (streaming sha256, cached by size/mtime_ns/ctime_ns/inode/dev
#      and re-hashed when any of them changes), a PASS record requires the catalog-pinned sha256, the record is signed
#      (HMAC-SHA256, key 0600 in the state dir) and binds the sha256 of its own evidence file.
#  (5) the record named the host by socket.gethostname(): it now carries a host id derived from /etc/machine-id
#      (hashed; documented fallback /var/lib/dbus/machine-id, then the hostname - weaker) and a spoofed hostname changes
#      nothing.
#  (9) an UNDETERMINED run overwrote a prior FAIL record: it now never replaces a PASS or a FAIL record.
#  plus: a quick-mode run (LLMCTL_VALIDATE_REPEAT=1) is never recorded.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
source "$(dirname "${BASH_SOURCE[0]}")/validation_local_lib.sh"
trap 'vl_cleanup; test_teardown_env' EXIT
vl_setup
L="${VL_LLMCTL}"
REC="${LLMCTL_STATE_DIR}/validation/vision.json"
GOOD="${VL_FIX}/answers_good.json"

U="$(vl_fake_start "${GOOD}")"; PORT="${U##*:}"; vl_mark_running "${PORT}"

echo "== 1. a real PASS record: signed, bound to the model bytes, the evidence and the machine id"
assert_eq 0 "$(vl_rc "${L}" validate vision)" "local validation passes against the fixture endpoint"
assert_file_exists "${REC}" "record written"
assert_eq 0 "$(vl_rc "${L}" require-validated vision)" "require-validated accepts it"
assert_eq "600" "$(stat -c '%a' "${REC}")" "record is 0600"
KEYF="${LLMCTL_STATE_DIR}/validation/.hmac.key"
assert_file_exists "${KEYF}" "the HMAC key was created on first use"
assert_eq "600" "$(stat -c '%a' "${KEYF}")" "the HMAC key is 0600"
assert_eq 64 "$(vl_json "${REC}" 'len(d.get("signature",""))')" "the record carries a 64-hex HMAC-SHA256 signature"
sha_real="$(sha256sum "${VL_MODEL}" | cut -d' ' -f1)"
assert_eq "${sha_real}" "$(vl_json "${REC}" '[f["sha256"] for f in d["model_files"] if f["name"].startswith("gemma")][0]')" "the record carries the REAL sha256 of the model file"
assert_eq "machine-id" "$(vl_json "${REC}" 'd.get("host_id_source")')" "host identity comes from the machine id"
mid_hash="$(vl_json "${REC}" 'd.get("host_id","")')"
assert_eq 64 "${#mid_hash}" "the host id is a 64-hex hash"
assert_eq 0 "$(grep -c '0123456789abcdef0123456789abcdef' "${REC}" || true)" "the raw machine id is never written into the record"
EVF="$(vl_json "${REC}" 'd.get("evidence_file","")')"
assert_file_exists "${EVF}" "the record names its own evidence file"
assert_eq "$(sha256sum "${EVF}" | cut -d' ' -f1)" "$(vl_json "${REC}" 'd.get("evidence_sha256","")')" "the record binds the sha256 of that evidence"
assert_eq 3 "$(vl_json "${REC}" 'd.get("repeat")')" "the record says every probe was asked 3 times"
cp "${REC}" "${TEST_TMP}/rec.orig"; if [[ -f "${EVF}" ]]; then cp "${EVF}" "${TEST_TMP}/ev.orig"; else : > "${TEST_TMP}/ev.orig"; EVF="${TEST_TMP}/no-evidence-file"; fi

echo "== 2. a hand-written record with junk model files -> refused"
python3 -I - "${REC}" <<'PY'
import json, sys, time
p = sys.argv[1]; d = json.load(open(p))
d["model_files"] = [{"name": f["name"], "size": 1, "sha256": "0" * 64} for f in d["model_files"]]
d["epoch"] = int(time.time()); d.pop("signature", None)
json.dump(d, open(p, "w"))
PY
assert_eq 1 "$(vl_rc "${L}" require-validated vision)" "hand-written record (no signature, junk files) -> refused"
assert_contains "$(cat "${TEST_TMP}/last.out")" "signature" "the reason names the signature"
# the most convincing forgery: llmctl's OWN current key + status pass + a fresh epoch, everything matching - but not signed
python3 -I "${LLMCTL_ROOT}/lib/validate_judge.py" key --catalog "${LLMCTL_CATALOG}" --profile vision --models-dir "${LLMCTL_MODELS_DIR}" \
  --suites-dir "${LLMCTL_ROOT}/validation/suites" --engine-tag "build 4242, commit deadbeef" > "${TEST_TMP}/key.json"
python3 -I - "${TEST_TMP}/key.json" "${REC}" "${TEST_TMP}/rec.orig" <<'PY'
import json, sys, time
k = json.load(open(sys.argv[1])); o = json.load(open(sys.argv[3]))
for f in k["model_files"]:
    f.pop("stat", None); f.pop("hash_source", None)
k.update({"status": "pass", "epoch": int(time.time()), "repeat": 3, "evidence_file": o["evidence_file"],
          "evidence_sha256": o["evidence_sha256"], "launch_fingerprint": o["launch_fingerprint"]})
json.dump(k, open(sys.argv[2], "w"))
PY
assert_eq 1 "$(vl_rc "${L}" require-validated vision)" "a hand-written record built from llmctl's own current key (unsigned) -> refused"
assert_contains "$(cat "${TEST_TMP}/last.out")" "signature" "...because it carries no valid signature"
cp "${TEST_TMP}/rec.orig" "${REC}"
python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["signature"]="0"*64; json.dump(d,open(p,"w"))' "${REC}"
assert_eq 1 "$(vl_rc "${L}" require-validated vision)" "tampered signature -> refused"
cp "${TEST_TMP}/rec.orig" "${REC}"
python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["engine_tag"]="build 1, commit 0"; json.dump(d,open(p,"w"))' "${REC}"
assert_eq 1 "$(vl_rc "${L}" require-validated vision)" "a signed record with ONE field edited -> refused"
cp "${TEST_TMP}/rec.orig" "${REC}"
assert_eq 0 "$(vl_rc "${L}" require-validated vision)" "control: the original record is accepted again"

echo "== 3. the model's bytes replaced, size and mtime restored -> refused"
mt="$(stat -c '%y' "${VL_MODEL}")"
python3 -I - "${VL_MODEL}" <<'PY'
import sys
p = sys.argv[1]; b = bytearray(open(p, "rb").read()); b[0] ^= 0x01; open(p, "r+b").write(bytes(b))
PY
touch -d "${mt}" "${VL_MODEL}"
assert_eq "${mt}" "$(stat -c '%y' "${VL_MODEL}")" "mtime restored to the nanosecond"
assert_eq 1 "$(vl_rc "${L}" require-validated vision)" "same size + same mtime, different bytes -> refused"
assert_contains "$(cat "${TEST_TMP}/last.out")" "model" "the reason names the model files"
python3 -I - "${VL_MODEL}" <<'PY'
import sys
p = sys.argv[1]; b = bytearray(open(p, "rb").read()); b[0] ^= 0x01; open(p, "r+b").write(bytes(b))
PY
assert_eq 0 "$(vl_rc "${L}" require-validated vision)" "control: original bytes back (new mtime, same content) -> accepted"

echo "== 4. the evidence the record is bound to is edited or removed -> refused"
printf 'edited\n' >> "${EVF}"
assert_eq 1 "$(vl_rc "${L}" require-validated vision)" "edited evidence -> refused"
assert_contains "$(cat "${TEST_TMP}/last.out")" "evidence" "the reason names the evidence"
rm -f "${EVF}"
assert_eq 1 "$(vl_rc "${L}" require-validated vision)" "missing evidence -> refused"
cp "${TEST_TMP}/ev.orig" "${EVF}"; chmod 600 "${EVF}"
assert_eq 0 "$(vl_rc "${L}" require-validated vision)" "control: evidence restored -> accepted"

echo "== 5. LLMCTL_VALIDATION_MAX_AGE must be a finite, non-negative number of seconds"
for bad in nan inf -inf NaN -1 1e309 abc 1.5; do
  assert_eq 2 "$(vl_rc env LLMCTL_VALIDATION_MAX_AGE="${bad}" "${L}" require-validated vision)" "LLMCTL_VALIDATION_MAX_AGE='${bad}' -> refused with exit 2"
done
assert_eq 0 "$(vl_rc env LLMCTL_VALIDATION_MAX_AGE=600 "${L}" require-validated vision)" "control: a finite age is honoured"
rc=0; python3 -I "${LLMCTL_ROOT}/lib/validate_judge.py" check --state "${REC}" --key "${REC}" --max-age nan >/dev/null 2>&1 || rc=$?
assert_eq 2 "${rc}" "the judge itself refuses --max-age nan with exit 2"

echo "== 6. host identity: the machine id, never the hostname"
assert_eq 1 "$(vl_rc env LLMCTL_MACHINE_ID_FILE="${TEST_TMP}/machine-id.B" "${L}" require-validated vision)" "same hostname, different machine id -> refused"
assert_contains "$(cat "${TEST_TMP}/last.out")" "host_id" "the reason names the host id"
assert_eq 0 "$(vl_rc env LLMCTL_TEST_HOSTNAME=spoofed.example "${L}" require-validated vision)" "same machine id, spoofed hostname -> still this host (accepted)"

echo "== 7. a model file that does not match its catalog pin is never recorded as PASS"
cp "${LLMCTL_CATALOG}" "${TEST_TMP}/catalog.good"
python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["profiles"]["vision"]["files"][0]["sha256"]="1"*64; json.dump(d,open(p,"w"))' "${LLMCTL_CATALOG}"
assert_eq 1 "$(vl_rc "${L}" require-validated vision)" "the catalog pin no longer matches the bytes -> refused"
assert_contains "$(cat "${TEST_TMP}/last.out")" "catalog" "the reason names the catalog pin"
rm -f "${REC}"
assert_eq 2 "$(vl_rc "${L}" validate vision)" "validation against a pin mismatch -> UNDETERMINED (exit 2), no PASS record"
assert_file_absent "${REC}" "no PASS record written for a model that is not the pinned file"
cp "${TEST_TMP}/catalog.good" "${LLMCTL_CATALOG}"

echo "== 8. an UNDETERMINED run never replaces a FAIL (or a PASS) record"
U2="$(vl_fake_start "$(vl_answers_with "05_table/lookup" "PARIS")")"; vl_mark_running "${U2##*:}"
assert_eq 1 "$(vl_rc "${L}" validate vision)" "wrong answer -> FAIL"
assert_eq fail "$(vl_json "${REC}" 'd["status"]')" "record says fail"
U3="$(vl_fake_start "${GOOD}" --mode error500)"; vl_mark_running "${U3##*:}"
assert_eq 2 "$(vl_rc "${L}" validate vision)" "endpoint errors -> UNDETERMINED"
assert_eq fail "$(vl_json "${REC}" 'd["status"]')" "the FAIL record is kept (an UNDETERMINED run is not evidence against it)"
assert_contains "$(cat "${TEST_TMP}/last.out")" "kept prior fail record" "...and says so"
vl_mark_running "${PORT}"
assert_eq 0 "$(vl_rc "${L}" validate vision)" "a real PASS replaces the FAIL"
assert_eq pass "$(vl_json "${REC}" 'd["status"]')" "record says pass"
vl_mark_running "${U3##*:}"
assert_eq 2 "$(vl_rc "${L}" validate vision)" "UNDETERMINED after a PASS"
assert_eq pass "$(vl_json "${REC}" 'd["status"]')" "...keeps the PASS"

echo "== 9. a quick-mode run (LLMCTL_VALIDATE_REPEAT=1) is never recorded and never validates"
rm -f "${REC}"; vl_mark_running "${PORT}"
assert_eq 2 "$(vl_rc env LLMCTL_VALIDATE_REPEAT=1 "${L}" validate vision)" "a quick-mode PASS is not a validation (exit 2)"
assert_contains "$(cat "${TEST_TMP}/last.out")" "quick mode" "...and says why"
assert_file_absent "${REC}" "no record from a quick-mode run"
assert_eq 1 "$(vl_rc "${L}" require-validated vision)" "require-validated still refuses"

test_finish
