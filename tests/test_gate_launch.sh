#!/usr/bin/env bash
# test_gate_launch.sh - review 2026-10-15 findings 3, 5 and 9 (the validation gate's decision inputs):
#   finding 5: the start gate decided on the PREVIOUS launch's env record, so `LLMCTL_SEED=7 llmctl start vision` was
#              published unvalidated on the strength of a record for another launch; and the publish step forced
#              "public" without re-checking the record against the launch it published;
#   finding 3: a fresh record did not count when LLMCTL_VALIDATE_ON_START=0 (refused even a validated profile), and
#              `switch` stopped the resident set BEFORE the target was refused (the rollback was refused too);
#              scripts/livetest uses LLMCTL_VALIDATE_ON_START=external (unpublished, validated by the caller);
#   finding 9: LLMCTL_VALIDATE_HERMETIC=1 alone relaxed production gates; it now needs the harness file too.
# Hermetic: recording service manager, fixture OpenAI server, every catalog port remapped, nothing real started.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
source "$(dirname "${BASH_SOURCE[0]}")/gate_wiring_lib.sh"
trap 'gw_cleanup_bg; vl_cleanup 2>/dev/null || true; test_teardown_env' EXIT
gw_init
# mutation hook (tests/test_validation_mutants.sh group "gate"): GATE_MUT_FILE/OLD/NEW change ONE lib file of the tree
if [[ -n "${GATE_MUT_FILE:-}" ]]; then
  _mf="${GW_TREE}/lib/${GATE_MUT_FILE}"; rm -f -- "${_mf:?}"; cp "${LLMCTL_ROOT}/lib/${GATE_MUT_FILE}" "${_mf}"
  python3 -I - "${_mf}" "${GATE_MUT_OLD}" "${GATE_MUT_NEW}" <<'PY2'
import sys
f, old, new = sys.argv[1:4]
s = open(f).read()
if s.count(old) != 1: sys.exit("mutation anchor found %d times" % s.count(old))
open(f, "w").write(s.replace(old, new))
PY2
  echo "MUTANT applied to ${GATE_MUT_FILE}"
fi
L="${GW_LLMCTL}"
b2i() { if "$@"; then echo 1; else echo 0; fi; }
# shellcheck disable=SC2010  # the runtime dir holds only <name>.run files written by the harness; names are plain
running() { ls "${LLMCTL_RUNTIME_DIR}" | grep '\.run$' | sed 's/\.run$//' | sort | tr '\n' ' '; }
reset() { gw_calls_reset; rm -f "${LLMCTL_RUNTIME_DIR:?}"/*.run "${GW_ACTIVE_DIR:?}"/* 2>/dev/null || true; }

echo "== finding 9: LLMCTL_VALIDATE_HERMETIC=1 without the harness file relaxes nothing"
reset
rm -f -- "${LLMCTL_STATE_DIR:?}/.test-harness"
rc="$(gw_run env LLMCTL_VALIDATE_HERMETIC=1 LLMCTL_VALIDATE_ON_START=0 "${L}" start small)"
assert_eq 1 "${rc}" "HERMETIC=1 + ON_START=0, no harness file: the consumer-facing start is refused"
assert_contains "$(gw_out)" "LLMCTL_VALIDATE_HERMETIC=1 ignored" "...and the ignored variable is reported"
assert_eq 0 "$(gw_count '^svc_start small')" "...nothing was started"
mkdir -p "${TEST_TMP}/hk"; printf 'LLMCTL_ENGINE=llama\nLLMCTL_REG_KIND=llm\nLLMCTL_REG_PROFILE=small\n' > "${TEST_TMP}/hk/small.env"
hk_rc() { local rc=0; env LLMCTL_VALIDATE_HERMETIC=1 LLMCTL_VALIDATE_ON_START=0 bash -c 'source "$1/lib/svc_hook.sh"; _hk_validate_after_ready small 1 "$2"' _ "${GW_TREE}" "${TEST_TMP}/hk/small.env" >/dev/null 2>&1 || rc=$?; echo "${rc}"; }
assert_eq 1 "$(hk_rc)" "unit waiter: HERMETIC=1 + ON_START=0 without the harness file -> NOT registered"
( umask 077; printf 'llmctl test harness\n' > "${LLMCTL_STATE_DIR}/.test-harness" )
assert_eq 0 "$(hk_rc)" "unit waiter: inside the harness the test relaxation still works (control)"
reset
rc="$(gw_run env LLMCTL_VALIDATE_HERMETIC=1 LLMCTL_VALIDATE_ON_START=0 "${L}" start small)"
assert_eq 0 "${rc}" "inside the harness (file + variable): the hermetic start is served (control)"
gw_run env LLMCTL_VALIDATE_HERMETIC=1 "${L}" status >/dev/null
assert_contains "$(gw_out)" "TEST-HARNESS MODE" "status says loudly that the harness relaxation is in effect"

unset LLMCTL_VALIDATE_HERMETIC     # everything below: production semantics
echo "== finding 3: a FRESH record counts before the ON_START=0 refusal"
reset
rc="$(GW_FRESH='small fast' gw_run env LLMCTL_VALIDATE_ON_START=0 "${L}" start small)"
assert_eq 0 "${rc}" "ON_START=0 start of a profile WITH a fresh record: served"
assert_eq 1 "$(gw_count '^svc_start small')" "...started"
assert_eq 0 "$(b2i grep -q '^quarantine=1' "${LLMCTL_RUNTIME_DIR}/small.run")" "...published, not quarantined"
rc="$(GW_FRESH='small fast' gw_run env LLMCTL_VALIDATE_ON_START=0 "${L}" switch fast)"
assert_eq 0 "${rc}" "ON_START=0 switch to a target WITH a fresh record: done"
assert_eq "fast " "$(running)" "...fast runs, small was stopped by the switch"

echo "== finding 3: a refused switch target stops NOTHING"
gw_calls_reset
rc="$(GW_FRESH='small fast' gw_run env LLMCTL_VALIDATE_ON_START=0 "${L}" switch vision)"
assert_eq 1 "${rc}" "ON_START=0 switch to a target WITHOUT a record: refused"
assert_contains "$(gw_out)" "nothing was stopped" "...said so"
assert_eq 0 "$(gw_count '^svc_stop')" "...no svc_stop at all"
assert_eq "fast " "$(running)" "...the resident set is untouched"

echo "== finding 3: LLMCTL_VALIDATE_ON_START=external starts UNPUBLISHED and leaves the validation to the caller"
reset
rc="$(gw_run env LLMCTL_VALIDATE_ON_START=external "${L}" start vision)"
assert_eq 0 "${rc}" "ON_START=external start: rc 0"
assert_eq 1 "$(b2i grep -q '^quarantine=1' "${LLMCTL_RUNTIME_DIR}/vision.run")" "...quarantined (loopback, private port, unpublished)"
assert_eq 0 "$(gw_count '^validate_profile ')" "...not validated by llmctl"
assert_contains "$(gw_out)" "left in QUARANTINE for an external validator" "...and it says so"
assert_contains "$(sed -n 's/^LLMCTL_ARGS=//p' "${LLMCTL_SERVICES_DIR}/vision.env")" "--host 127.0.0.1" "...bound to loopback"

echo "== finding 3: the live test script no longer asks for ON_START=0"
assert_eq 0 "$(grep -v '^[[:space:]]*#' "${LLMCTL_ROOT}/scripts/livetest/vision_live_test.sh" | grep -c 'LLMCTL_VALIDATE_ON_START=0' || true)" "scripts/livetest/vision_live_test.sh runs nothing with LLMCTL_VALIDATE_ON_START=0"

echo "== finding 5: the gate decides on the launch ABOUT TO RUN (real signed records, fixture server)"
reset
source "${LLMCTL_ROOT}/tests/validation_local_lib.sh"
vl_setup
# vl_setup re-copies the catalog with the real ports: move every port to an unused one again (nothing may reach a host
# service)
python3 -I - "${LLMCTL_CATALOG}" <<'PY2'
import json, random, socket, sys
p = sys.argv[1]; d = json.load(open(p)); used = set()
def busy(port):
    s = socket.socket(); s.settimeout(0.2)
    try: s.connect(("127.0.0.1", port)); return True
    except OSError: return False
    finally: s.close()
for prof in d["profiles"].values():
    while True:
        port = random.randint(41000, 58999)
        if port not in used and not busy(port): used.add(port); prof["port"] = port; break
json.dump(d, open(p, "w"))
PY2
unset LLMCTL_VALIDATE_HERMETIC; export LLMCTL_VALIDATE_HERMETIC=1     # machine-id override only (harness file present)
export GW_REAL_VALIDATE=1
GOOD="${VL_FIX}/answers_good.json"
U="$(vl_fake_start "${GOOD}" --model "${VL_MODEL}")"; PORT="${U##*:}"
# launch A: the quarantine start writes the env record of launch A (ON_START=external: left unvalidated in quarantine, so
# the record stays - a STOPPED quarantine start puts the previous record back, review 3 of 2026-10-15 finding 6)
gw_run env LLMCTL_VALIDATE_ON_START=external "${L}" start vision >/dev/null
vl_mark_running "${PORT}"; : > "${GW_ACTIVE_DIR}/vision"
assert_eq 0 "$(gw_run "${L}" validate vision)" "a real signed PASS record for launch A"
assert_eq 0 "$(gw_run "${L}" require-validated vision)" "...require-validated accepts it"
rm -f "${LLMCTL_RUNTIME_DIR}/vision.run" "${GW_ACTIVE_DIR}/vision"; gw_calls_reset
rc="$(gw_run env LLMCTL_VALIDATE_ON_START=1 LLMCTL_SEED=7 "${L}" start vision)"
assert_contains "$(gw_out)" "UNPUBLISHED" "a start with CHANGED flags (LLMCTL_SEED=7) is quarantined - the record is for another launch"
assert_contains "$(sed -n 's/^LLMCTL_ARGS=//p' "${GW_CALLS}.env_at_validate.vision")" "--host 127.0.0.1" "...loopback, never the documented port (the record it ran with while validated)"
rm -f "${LLMCTL_RUNTIME_DIR}/vision.run" "${GW_ACTIVE_DIR}/vision"
# the env record now holds the seed-7 quarantine launch: put launch A back (a start with the original flags)
gw_run env LLMCTL_VALIDATE_ON_START=external "${L}" start vision >/dev/null
rm -f "${LLMCTL_RUNTIME_DIR}/vision.run" "${GW_ACTIVE_DIR}/vision"; gw_calls_reset
rc="$(gw_run env LLMCTL_VALIDATE_ON_START=1 "${L}" start vision)"
assert_eq 0 "${rc}" "control: the SAME launch as the record starts"
assert_eq 0 "$(b2i grep -q 'UNPUBLISHED' "${TEST_TMP}/last.out")" "control: ...published at once (the candidate launch matches the record)"
assert_eq "" "$(sed -n 's/^LLMCTL_QUARANTINE_UNTIL=//p' "${LLMCTL_SERVICES_DIR}/vision.env")" "control: ...no quarantine marker"

echo "== finding 5: the publish step re-checks the record against the launch it publishes"
rm -f "${LLMCTL_RUNTIME_DIR}/vision.run" "${GW_ACTIVE_DIR}/vision"
rm -f "${LLMCTL_STATE_DIR}/validation/vision.json"                            # no record: it is quarantined, then validated
gw_run env LLMCTL_VALIDATE_ON_START=external "${L}" start vision >/dev/null     # quarantined launch A (no seed)
assert_eq 1 "$(b2i grep -q '^quarantine=1' "${LLMCTL_RUNTIME_DIR}/vision.run")" "setup: launch A runs quarantined"
sed -i "s/^port=.*/port=${PORT}/" "${LLMCTL_RUNTIME_DIR}/vision.run"            # its "engine" is the fixture server
gw_calls_reset
rc="$(gw_run env LLMCTL_VALIDATE_ON_START=1 LLMCTL_SEED=7 "${L}" validate-after-start vision)"
assert_eq 1 "${rc}" "validated launch A, publishing a seed-7 launch: refused (rc 1)"
assert_contains "$(gw_out)" "is not the one that was validated" "...the reason is named"
assert_eq 0 "$(gw_count '^svc_start vision')" "...nothing was started on the documented port"

test_finish
