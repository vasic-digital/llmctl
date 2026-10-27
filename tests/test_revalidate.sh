#!/usr/bin/env bash
# test_revalidate.sh - `llmctl revalidate` + the user timer that runs it (llmctl-revalidate.{service,timer}).
#
# Problem (2026-10-26): a signed validation PASS record expires (LLMCTL_VALIDATION_MAX_AGE; 30 d on the authoring host, 7 d by
# default). An engine validated once and left running is then SKIPPED at the next boot (ExecCondition `validated` -> exit 77:
# skipped, not failed, not restarted) - on this host every decision engine, after ~2026-11-25.
# A periodic job must refresh the records WITHOUT the failure modes of `llmctl validate` on a served profile (FAIL stops the
# engine; UNDETERMINED overwrites the record, demoting a healthy engine to NOT VALIDATED).  Proven here against the validation
# fixture server (a RUNNING profile, a real signed record, a real engine process):
#   1. not due            -> nothing runs, the record is byte-identical, exit 0
#   2. due + correct      -> PASS, the record is replaced by a NEWER signed one, require-validated 0, the engine still runs
#   3. due + WRONG answers-> exit 1, the previous record is BYTE-IDENTICAL, require-validated still 0, the engine still runs
#   4. due + engine gone  -> exit 2, the previous record is BYTE-IDENTICAL, no process was started
#   5. nothing running / quarantined profile -> exit 0, nothing touched
#   6. units: the timer + oneshot service are written by install, enabled (printed under a dry run), contain no stop/restart verb
# Paired mutations (each turns the suite RED): staging removed (a non-PASS overwrites the record), the manual verdict policy
# applied (a FAIL stops the engine), the install no longer writes the units.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
source "$(dirname "${BASH_SOURCE[0]}")/validation_local_lib.sh"
trap 'vl_cleanup; test_teardown_env' EXIT
vl_setup
L="${VL_LLMCTL}"
unset LLMCTL_DRY_RUN_WRITE
export LLMCTL_VALIDATION_MAX_AGE=2592000     # 30 d, like the authoring host
REC="${LLMCTL_STATE_DIR}/validation/vision.json"
md5() { md5sum "$1" | cut -d' ' -f1; }
alive() { kill -0 "$1" 2>/dev/null && echo yes || echo no; }

# start_engine <answers.json> [extra fake_openai args] - sets U (url) and EPID (pid) and marks the profile running
start_engine() {
  local ans="$1"; shift
  U="$(vl_fake_start "${ans}" "$@")"
  EPID="$(tail -1 "${VL_PIDS_FILE}")"
  vl_mark_running "${U##*:}"
}
stop_engine() { kill "${EPID}" 2>/dev/null || true; wait "${EPID}" 2>/dev/null || true; rm -f "${LLMCTL_RUNTIME_DIR}/vision.run"; }

echo "== 0. setup: a running profile with a real signed PASS record"
start_engine "${VL_FIX}/answers_good.json"
rc="$(vl_rc "${L}" validate vision)"
assert_eq 0 "${rc}" "llmctl validate vision (running, fixture engine) -> PASS and a record is written ($(tail -2 "${TEST_TMP}/last.out" | head -1))"
assert_eq 0 "$(vl_rc "${L}" require-validated vision)" "require-validated vision -> 0"
M0="$(md5 "${REC}")"

echo "== 1. not due: nothing runs, the record is byte-identical"
rc="$(vl_rc env LLMCTL_REVALIDATE_AFTER=1000000 "${L}" revalidate)"
assert_eq 0 "${rc}" "revalidate with a young record -> exit 0"
assert_contains "$(cat "${TEST_TMP}/last.out")" "not due" "the profile is reported as not due"
assert_eq "${M0}" "$(md5 "${REC}")" "the record is byte-identical"
assert_eq yes "$(alive "${EPID}")" "the engine still runs"

echo "== 2. due + correct engine: PASS, the record is replaced by a NEWER signed one, the engine is untouched"
sleep 1.2
rc="$(vl_rc env LLMCTL_REVALIDATE_AFTER=0 "${L}" revalidate)"
assert_eq 0 "${rc}" "revalidate of a due profile against a correct engine -> exit 0"
assert_contains "$(cat "${TEST_TMP}/last.out")" "vision: PASS - record refreshed" "the summary says the record was refreshed"
M1="$(md5 "${REC}")"
if [[ "${M1}" != "${M0}" ]]; then printf '  ok: the record was replaced\n'; else printf '  FAIL: the record was not replaced\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
assert_eq 0 "$(vl_rc "${L}" require-validated vision)" "require-validated vision -> 0 with the NEW record (signature verifies)"
assert_eq yes "$(alive "${EPID}")" "the engine still runs"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/vision.run" "the reservation is still there"
assert_eq pass "$(vl_json "${LLMCTL_STATE_DIR}/validation/vision.revalidate.json" 'd["result"]')" "the last-revalidation note says pass"
if compgen -G "${LLMCTL_STATE_DIR}/validation/.revalidate.*" >/dev/null; then printf '  FAIL: a staging directory was left behind\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: no staging directory left behind\n'; fi

echo "== 3. due + WRONG answers: exit 1 - and the previous record is byte-identical, the engine is NOT stopped"
stop_engine
BADANS="$(vl_answers_with 05_table/lookup PARIS)"
start_engine "${BADANS}"
M2="$(md5 "${REC}")"
rc="$(vl_rc env LLMCTL_REVALIDATE_AFTER=0 "${L}" revalidate)"
assert_eq 1 "${rc}" "revalidate against a wrong-answering engine -> exit 1 (the unit shows FAILED)"
assert_contains "$(cat "${TEST_TMP}/last.out")" "vision: FAIL" "the summary names the FAIL"
assert_eq "${M2}" "$(md5 "${REC}")" "the previous PASS record is BYTE-IDENTICAL (a FAIL never overwrites it)"
assert_eq yes "$(alive "${EPID}")" "the engine was NOT stopped"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/vision.run" "the reservation was NOT withdrawn"
assert_eq fail "$(vl_json "${LLMCTL_STATE_DIR}/validation/vision.revalidate.json" 'd["result"]')" "the last-revalidation note says fail"
assert_file_exists "${LLMCTL_STATE_DIR}/validation/vision.revalidate-failed.json" "the failed run's record is kept for diagnosis"

echo "== 4. due + engine unreachable: exit 2 - the previous record is byte-identical, nothing is started"
stop_engine
printf 'profile=vision\nmode=gpu\nport=9\nram_mb=1\nvram_mb=1\nstarted_epoch=%s\n' "$(date +%s)" > "${LLMCTL_RUNTIME_DIR}/vision.run"
M3="$(md5 "${REC}")"
rc="$(vl_rc env LLMCTL_REVALIDATE_AFTER=0 "${L}" revalidate)"
assert_eq 2 "${rc}" "revalidate with an unreachable engine -> exit 2 (could not determine)"
assert_eq "${M3}" "$(md5 "${REC}")" "the previous record is BYTE-IDENTICAL (UNDETERMINED never demotes a healthy record)"
assert_eq 0 "$(vl_rc "${L}" require-validated vision)" "require-validated vision still 0"
rm -f "${LLMCTL_RUNTIME_DIR}/vision.run"

echo "== 5. nothing running / quarantined profile"
rc="$(vl_rc "${L}" revalidate)"
assert_eq 0 "${rc}" "no running profile -> exit 0 (a timer tick on an idle host is not a failure)"
assert_contains "$(cat "${TEST_TMP}/last.out")" "no running profile" "says so"
printf 'profile=vision\nmode=gpu\nport=9\nram_mb=1\nvram_mb=1\nquarantine=1\nstarted_epoch=%s\n' "$(date +%s)" > "${LLMCTL_RUNTIME_DIR}/vision.run"
rc="$(vl_rc env LLMCTL_REVALIDATE_AFTER=0 "${L}" revalidate)"
assert_eq 0 "${rc}" "a quarantined profile is skipped (its starter validates it)"
assert_contains "$(cat "${TEST_TMP}/last.out")" "quarantined" "says so"
assert_eq "${M3}" "$(md5 "${REC}")" "the record is untouched"
rm -f "${LLMCTL_RUNTIME_DIR}/vision.run"
assert_eq 2 "$(vl_rc "${L}" revalidate --bogus)" "an unknown option is a usage error (2)"

echo "== 6. units: written by install, enabled (printed under a dry run), no stop/restart verb"
rm -rf "${LLMCTL_UNIT_DIR}"
rc="$(vl_rc env LLMCTL_DRY_RUN=1 LLMCTL_DRY_RUN_WRITE=1 "${L}" install)"
assert_eq 0 "${rc}" "install (legacy write mode of a dry run) exits 0"
SVC="${LLMCTL_UNIT_DIR}/llmctl-revalidate.service"; TMR="${LLMCTL_UNIT_DIR}/llmctl-revalidate.timer"
assert_file_exists "${SVC}" "llmctl-revalidate.service written"
assert_file_exists "${TMR}" "llmctl-revalidate.timer written"
assert_contains "$(cat "${TEST_TMP}/last.out")" "systemctl --user enable --now llmctl-revalidate.timer" "install enables the timer (printed under the dry run)"
assert_file_contains "${SVC}" "Type=oneshot" "oneshot service"
assert_file_contains "${SVC}" "/bin/llmctl\" revalidate" "ExecStart runs llmctl revalidate"
assert_file_contains "${TMR}" "OnCalendar=daily" "daily"
assert_file_contains "${TMR}" "Persistent=true" "a missed run fires at the next start"
assert_file_contains "${TMR}" "WantedBy=timers.target" "installable into timers.target"
if grep -Eq '^(Restart=|ExecStop|ExecStartPre=.*(stop|restart)|ExecStart=.*(stop|restart|disable))' "${SVC}"; then printf '  FAIL: the service carries a Restart=/stop/restart verb\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: the service carries no Restart=, ExecStop or stop/restart verb\n'; fi
if command -v systemd-analyze >/dev/null 2>&1; then
  v="$(systemd-analyze --user verify "${SVC}" "${TMR}" 2>&1 | grep -v 'llmctl-revalidate' | grep -i 'revalidate' || true)"
  assert_eq "" "${v}" "systemd-analyze verify finds nothing wrong with the two units"
fi
# a freshly installed revalidate unit is NOT stale (it is a oneshot without Restart=; the "restart bound too weak" check must not apply)
stale="$( export LC_ALL=C; source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_linux.sh"; svc_stale_units 2>&1 )"
assert_eq "" "${stale}" "svc_stale_units: nothing is stale right after an install (the revalidate oneshot is not flagged)"
rc="$(vl_rc env LLMCTL_DRY_RUN=1 LLMCTL_DRY_RUN_WRITE=1 LLMCTL_REVALIDATE_TIMER=0 "${L}" install)"
assert_eq 0 "${rc}" "install with LLMCTL_REVALIDATE_TIMER=0 exits 0"
if grep -q 'enable --now llmctl-revalidate.timer' "${TEST_TMP}/last.out"; then printf '  FAIL: the timer is enabled despite LLMCTL_REVALIDATE_TIMER=0\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: LLMCTL_REVALIDATE_TIMER=0 leaves the timer disabled\n'; fi

echo "== 7. paired mutations - each must turn the matching section RED"
mtree() { # mtree <name> <lib-file> <old> <new> - a throw-away tree whose <lib-file> has ONE exact replacement
  local d="${TEST_TMP}/tree.$1" e f
  mkdir -p "${d}/bin" "${d}/lib"
  for e in "${LLMCTL_ROOT}"/*; do case "$(basename "${e}")" in bin|lib) ;; *) ln -s "${e}" "${d}/$(basename "${e}")" ;; esac; done
  cp "${LLMCTL_ROOT}/bin/llmctl" "${d}/bin/llmctl"
  for f in "${LLMCTL_ROOT}"/lib/*; do [[ "$(basename "${f}")" == "$2" ]] || ln -sf "${f}" "${d}/lib/"; done
  python3 -I - "${LLMCTL_ROOT}/lib/$2" "${d}/lib/$2" "$3" "$4" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
if s.count(old) != 1:
    sys.exit("mutation anchor found %d times: %r" % (s.count(old), old))
open(dst, "w").write(s.replace(old, new))
PY
  printf '%s\n' "${d}/bin/llmctl"
}
# M-A: no staging - the run writes the LIVE record (a FAIL/UNDETERMINED overwrites it)
MA="$(mtree nostage validate.sh 'LLMCTL_VALIDATE_RECORD_DIR="${stage}" _val_locked_profile_validate' '_val_locked_profile_validate')"
stop_engine; start_engine "${BADANS}"; Mb="$(md5 "${REC}")"
rc="$(vl_rc env LLMCTL_REVALIDATE_AFTER=0 "${MA}" revalidate)"
if [[ "$(md5 "${REC}")" != "${Mb}" ]]; then printf '  ok: MUTANT no-staging: a FAIL overwrote the live record -> section 3 goes RED (rc=%s)\n' "${rc}"; else printf '  FAIL: mutant no-staging was not caught (record unchanged)\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
# restore the PASS record for the next mutants (the mutant destroyed it): re-validate against the good engine
stop_engine; start_engine "${VL_FIX}/answers_good.json"; rc="$(vl_rc "${L}" validate vision)"
assert_eq 0 "${rc}" "re-validated after mutant A (record restored)"
# M-B: the manual verdict policy applied - a FAIL stops the engine
MB="$(mtree policy validate.sh '    rm -rf -- "${stage:?}"
  done
  if (( n == 0 )); then' '    _val_cli_policy "${one}" "${p}" || true
    rm -rf -- "${stage:?}"
  done
  if (( n == 0 )); then')"
stop_engine; start_engine "${BADANS}"
rc="$(vl_rc env LLMCTL_REVALIDATE_AFTER=0 LLMCTL_DRY_RUN=1 "${MB}" revalidate)"
if grep -q 'gave WRONG answers - stopping it' "${TEST_TMP}/last.out"; then printf '  ok: MUTANT manual-policy: the FAIL was treated as "stop the served engine" -> section 3 (no stop) goes RED\n'; else printf '  FAIL: mutant manual-policy was not caught\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
# M-C: install forgets the timer units
MC="$(mtree nounits service_linux.sh '  _svc_revalidate_timer_body > "${unit_dir}/${REVALIDATE_TIMER_UNIT}"' ':')"
rm -rf "${LLMCTL_UNIT_DIR}"
rc="$(vl_rc env LLMCTL_DRY_RUN=1 LLMCTL_DRY_RUN_WRITE=1 "${MC}" install)"
if [[ ! -f "${LLMCTL_UNIT_DIR}/llmctl-revalidate.timer" ]]; then printf '  ok: MUTANT no-timer-unit: install writes no timer -> section 6 goes RED\n'; else printf '  FAIL: mutant no-timer-unit was not caught\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
# M-D: the stale-unit detector flags the revalidate oneshot again ("restart bound too weak" applied to a unit with no Restart=)
MD="$(mtree stale service_linux.sh '    [[ "${base}" == "${REVALIDATE_SERVICE_UNIT}" ]] && continue' ':')"
mlib="$(dirname "$(dirname "${MD}")")/lib"
rm -rf "${LLMCTL_UNIT_DIR}"; vl_rc env LLMCTL_DRY_RUN=1 LLMCTL_DRY_RUN_WRITE=1 "${L}" install >/dev/null
stale="$( export LC_ALL=C; source "${mlib}/common.sh"; source "${mlib}/service_linux.sh"; svc_stale_units 2>&1 )"
if grep -q 'llmctl-revalidate.service' <<<"${stale}"; then printf '  ok: MUTANT stale-skip removed: the revalidate unit is reported stale -> section 6 goes RED\n'; else printf '  FAIL: mutant stale-skip was not caught\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
stop_engine

test_finish
