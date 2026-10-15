#!/usr/bin/env bash
# test_validation_quarantine_env.sh - review 3 of 2026-10-15, finding 6 (RED first, reproduced with the reviewer's
# r13_enabled_start.sh): an ENABLED profile, stopped, then `LLMCTL_SEED=7 llmctl start small` (no record for that launch ->
# QUARANTINE start) whose validation FAILS was stopped - but small.env kept the quarantine launch (--host 127.0.0.1
# --port <private> --seed 7, LLMCTL_QUARANTINE_UNTIL) while small.enabled stood. At the next boot the unit ran that
# launch (marker absent: unregistered, unserved) or was refused (marker present). Now:
#   * every stop of a quarantined instance (FAIL, UNDETERMINED, a signal, `llmctl stop`, publication) puts the env record
#     back as it was before the quarantine start, byte for byte - or removes it when there was none;
#   * the unit's ExecCondition honours a quarantine record only while the llmctl process that validates it is ALIVE
#     (LLMCTL_QUARANTINE_VALIDATOR = pid:start-time); a record left by a dead validator is refused even before its deadline.
# Harness: tests/gate_wiring_lib.sh (recording service manager, recorder validate_profile). Nothing real is started.
# QE_MUT_FILE / QE_MUT_OLD / QE_MUT_NEW: a mutant copy (tests/test_validation_mutants.sh group "qenv").
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap 'gw_cleanup_bg; test_teardown_env' EXIT
source "$(dirname "${BASH_SOURCE[0]}")/gate_wiring_lib.sh"
gw_init
if [[ -n "${QE_MUT_FILE:-}" ]]; then
  _mf="${GW_TREE}/lib/${QE_MUT_FILE}"; rm -f -- "${_mf:?}"; cp "${LLMCTL_ROOT}/lib/${QE_MUT_FILE}" "${_mf}"
  python3 -I - "${_mf}" "${QE_MUT_OLD}" "${QE_MUT_NEW}" <<'PY2'
import sys
f, old, new = sys.argv[1:4]
s = open(f).read()
if s.count(old) != 1: sys.exit("mutation anchor found %d times" % s.count(old))
open(f, "w").write(s.replace(old, new))
PY2
  echo "MUTANT applied to ${QE_MUT_FILE}"
fi
L="${GW_LLMCTL}"
ENVF="${LLMCTL_SERVICES_DIR}/small.env"
SIDE="${LLMCTL_SERVICES_DIR}/small.env.prequarantine"
b2i() { if "$@"; then echo 1; else echo 0; fi; }
qv() { sed -n "s/^$1=//p" "${ENVF}" 2>/dev/null | head -1; }
hk() { local rc=0; LLMCTL_ROOT="${GW_TREE}" bash "${GW_TREE}/lib/svc_hook.sh" validated small >"${TEST_TMP}/hk.out" 2>&1 || rc=$?; echo "${rc}"; }
ident() { LLMCTL_ROOT="${GW_TREE}" bash -c 'source "${LLMCTL_ROOT}/lib/common.sh"; proc_identity "$1"' _ "$1"; }

enable_and_stop() {
  gw_calls_reset
  assert_eq 0 "$(GW_FRESH=small GW_VALIDATE_RC=0 gw_run "${L}" enable small)" "setup: enable small (validated)"
  gw_run "${L}" stop small >/dev/null
  assert_file_exists "${LLMCTL_SERVICES_DIR}/small.enabled" "setup: small stays enabled after the stop"
  cp -p "${ENVF}" "${TEST_TMP}/small.env.before"
  gw_calls_reset
}
restored() {   # restored <what>
  assert_eq 1 "$(b2i cmp -s "${TEST_TMP}/small.env.before" "${ENVF}")" "$1: the env record is the enabled one again, byte for byte"
  assert_eq "" "$(qv LLMCTL_QUARANTINE_UNTIL)" "$1: no quarantine deadline left in it"
  assert_file_absent "${SIDE}" "$1: no saved copy left behind"
}

echo "== FAIL of a quarantine start of an ENABLED profile (the reviewer's r13 sequence)"
enable_and_stop
rc="$(GW_VALIDATE_RC=1 gw_run env LLMCTL_SEED=7 "${L}" start small)"
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "the failing quarantine start exits non-zero (rc=${rc})"
assert_contains "$(sed -n 's/^LLMCTL_ARGS=//p' "${GW_CALLS}.env_at_validate.small")" "--host 127.0.0.1" "it really ran in quarantine (loopback) while validated"
assert_contains "$(sed -n 's/^LLMCTL_ARGS=//p' "${GW_CALLS}.env_at_validate.small")" "--seed 7" "...with the new launch"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/small.run" "it was stopped"
restored "FAIL"
assert_eq 0 "$(b2i grep -q -- '--seed 7' "${ENVF}")" "FAIL: the quarantine launch (--seed 7) is not what the enabled unit boots"
rm -f "${LLMCTL_STATE_DIR}/unit-enforcement"
assert_eq 0 "$(hk)" "marker ABSENT (c23c2e6 behaviour): the unit boots - and it boots the ENABLED record"
printf 'validation-gate=1\n' > "${LLMCTL_STATE_DIR}/unit-enforcement"; chmod 600 "${LLMCTL_STATE_DIR}/unit-enforcement"
assert_eq 0 "$(b2i grep -q 'quarantine' "${TEST_TMP}/hk.out")" "marker present: no quarantine record is seen at all"
rm -f "${LLMCTL_STATE_DIR}/unit-enforcement"

echo "== UNDETERMINED (strict default): the same restoration"
enable_and_stop
rc="$(GW_VALIDATE_RC=2 gw_run env LLMCTL_SEED=7 "${L}" start small)"
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "UNDETERMINED: start exits non-zero"
restored "UNDETERMINED"

echo "== a SIGNAL during the validation of the quarantine start: the same restoration"
enable_and_stop
GW_VALIDATE_RC=0 GW_VALIDATE_SLEEP=3 LLMCTL_SEED=7 "${L}" start small > "${TEST_TMP}/sig.out" 2>&1 & LP=$!
for (( i=0; i<100; i++ )); do grep -q '^validate_profile_begin small' "${GW_CALLS}" 2>/dev/null && break; sleep 0.1; done
assert_eq 1 "$(b2i grep -q '^validate_profile_begin small' "${GW_CALLS}")" "setup: the quarantine start reached its validation"
kill -TERM "${LP}" 2>/dev/null || true
wait "${LP}" 2>/dev/null || true
assert_file_absent "${LLMCTL_RUNTIME_DIR}/small.run" "SIGTERM: the quarantined start was stopped"
restored "SIGTERM"

echo "== while it is validated, the record names its LIVE validator; afterwards it is reverted"
enable_and_stop
GW_VALIDATE_RC=1 GW_VALIDATE_SLEEP=4 LLMCTL_SEED=7 "${L}" start small > "${TEST_TMP}/stop.out" 2>&1 & LP=$!
for (( i=0; i<100; i++ )); do grep -q '^validate_profile_begin small' "${GW_CALLS}" 2>/dev/null && break; sleep 0.1; done
cp -p "${ENVF}" "${TEST_TMP}/during.env"
assert_eq 1 "$(b2i grep -q '^LLMCTL_QUARANTINE_VALIDATOR=' "${TEST_TMP}/during.env")" "the quarantine record names its validator"
assert_eq "$(ident "${LP}")" "$(sed -n 's/^LLMCTL_QUARANTINE_VALIDATOR=//p' "${TEST_TMP}/during.env")" "...which is the llmctl process that started it"
printf 'validation-gate=1\n' > "${LLMCTL_STATE_DIR}/unit-enforcement"; chmod 600 "${LLMCTL_STATE_DIR}/unit-enforcement"
assert_eq 0 "$(hk)" "marker present, validator ALIVE: the quarantine start is allowed"
wait "${LP}" 2>/dev/null || true
restored "FAIL after a validation in progress"
rm -f "${LLMCTL_STATE_DIR}/unit-enforcement"

echo "== a profile with NO env record before its quarantine start: the quarantine record is removed"
gw_run "${L}" disable small >/dev/null 2>&1 || true
rm -f "${ENVF}" "${LLMCTL_SERVICES_DIR}/small.enabled"; gw_calls_reset
rc="$(GW_VALIDATE_RC=1 gw_run "${L}" start small)"
assert_file_absent "${ENVF}" "no env record before -> none after the failed quarantine start"
assert_file_absent "${SIDE}" "...and no saved copy left behind"

echo "== PASS: published; the published record stands and no saved copy is left"
gw_calls_reset
rc="$(GW_VALIDATE_RC=0 gw_run "${L}" start small)"
assert_eq 0 "${rc}" "PASS: start exits 0"
assert_eq "" "$(qv LLMCTL_QUARANTINE_UNTIL)" "PASS: the published record has no quarantine deadline"
assert_file_absent "${SIDE}" "PASS: no saved copy left behind"
gw_run "${L}" stop small >/dev/null
assert_file_exists "${ENVF}" "stopping a PUBLISHED profile keeps its env record (only a quarantine record is reverted)"

echo "== a quarantine record of an older llmctl (no saved copy) is removed by a stop"
{ cat "${ENVF}"; printf 'LLMCTL_QUARANTINE_UNTIL=%s\n' "$(( $(date +%s) + 600 ))"; } > "${TEST_TMP}/legacy.env"; cp "${TEST_TMP}/legacy.env" "${ENVF}"
gw_mark_running small 9; printf 'quarantine=1\n' >> "${LLMCTL_RUNTIME_DIR}/small.run"
gw_run "${L}" stop small >/dev/null
assert_file_absent "${ENVF}" "legacy quarantine record without a saved copy: removed on stop"

echo "== the unit's ExecCondition (marker present): a quarantine record is honoured only while its validator lives"
printf 'validation-gate=1\n' > "${LLMCTL_STATE_DIR}/unit-enforcement"; chmod 600 "${LLMCTL_STATE_DIR}/unit-enforcement"
uenv() { { printf 'LLMCTL_ENGINE=llama\nLLMCTL_PORT=9\nLLMCTL_REG_KIND=chat\nLLMCTL_REG_PROFILE=small\n'; printf '%s\n' "$@"; } > "${ENVF}"; }
FUT=$(( $(date +%s) + 600 ))
uenv "LLMCTL_QUARANTINE_UNTIL=${FUT}" "LLMCTL_QUARANTINE_VALIDATOR=$(ident "$$")"
assert_eq 0 "$(hk)" "live validator (this test process) -> allowed"
sleep 0.1 & DEAD=$!; DEADID="$(ident "${DEAD}" || true)"; wait "${DEAD}" 2>/dev/null || true
[[ -n "${DEADID}" ]] || DEADID="${DEAD}:1"
uenv "LLMCTL_QUARANTINE_UNTIL=${FUT}" "LLMCTL_QUARANTINE_VALIDATOR=${DEADID}"
assert_eq 77 "$(hk)" "validator gone (process exited) -> refused before the deadline"
assert_contains "$(cat "${TEST_TMP}/hk.out")" "validator is gone" "...and the reason is printed"
uenv "LLMCTL_QUARANTINE_UNTIL=${FUT}" "LLMCTL_QUARANTINE_VALIDATOR=$$:1"
assert_eq 77 "$(hk)" "a reused PID (same pid, another start time) -> refused"
uenv "LLMCTL_QUARANTINE_UNTIL=${FUT}"
assert_eq 77 "$(hk)" "a quarantine record naming no validator -> refused"
uenv "LLMCTL_QUARANTINE_UNTIL=$(( $(date +%s) - 1 ))" "LLMCTL_QUARANTINE_VALIDATOR=$(ident "$$")"
assert_eq 77 "$(hk)" "an expired record -> refused even with a live validator"
rm -f "${LLMCTL_STATE_DIR}/unit-enforcement" "${ENVF}"
test_finish
