#!/usr/bin/env bash
# test_validation_lock.sh - RED-first (wiring review #4). `llmctl enable|restart` validated the profile in the CLI hook AND the
# systemd waiter validated it again, concurrently: two probe loops hammering one model. A per-profile validation lock (flock on
# <runtime>/.validate-<profile>.lock - NOT the scheduler lock) serialises them: the second waits for the first and then re-checks
# freshness (a real validation leaves a fresh PASS record; the stub validator used here records none, so it simply runs second).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source "$(dirname "${BASH_SOURCE[0]}")/gate_wiring_lib.sh"
test_setup_env
cleanup() { local p; for p in $(pgrep -f "${TEST_TMP}/tree/" 2>/dev/null || true); do kill "${p}" 2>/dev/null || true; done; gw_cleanup_bg; test_teardown_env; }
trap cleanup EXIT
gw_init
if [[ -n "${LOCK_MUT_FILE:-}" ]]; then    # mutation hook (tests/test_validation_mutants.sh group "vlock")
  # mutated IN PLACE when gate_wiring_lib made a real copy (validate.sh carries its recorder overlay); a symlinked file
  # is replaced by a copy first (the repository is never touched)
  _mf="${GW_TREE}/lib/${LOCK_MUT_FILE}"
  if [[ -L "${_mf}" ]]; then rm -f -- "${_mf:?}"; cp "${LLMCTL_ROOT}/lib/${LOCK_MUT_FILE}" "${_mf}"; fi
  python3 -I - "${_mf}" "${LOCK_MUT_OLD}" "${LOCK_MUT_NEW}" <<'PY2'
import sys
f, old, new = sys.argv[1:4]
s = open(f).read()
if s.count(old) != 1: sys.exit("mutation anchor found %d times" % s.count(old))
open(f, "w").write(s.replace(old, new))
PY2
  echo "MUTANT applied to ${LOCK_MUT_FILE}"
fi
L="${GW_LLMCTL}"
FAKEBIN="${TEST_TMP}/fakebin"; mkdir -p "${FAKEBIN}"
printf '#!/usr/bin/env bash\nprintf "systemctl %%s\\n" "$*" >> "${GW_CALLS:?}"\nexit 0\n' > "${FAKEBIN}/systemctl"; chmod +x "${FAKEBIN}/systemctl"
export PATH="${FAKEBIN}:${PATH}"
GW_HTTP_FIXED_PORT=0 gw_http_server "${TEST_TMP}/ready.req"; PORT="${GW_HTTP_PORT}"
gw_mark_running small "${PORT}"
mkdir -p "${LLMCTL_SERVICES_DIR}" "${LLMCTL_LOG_DIR}"
{ printf 'LLMCTL_ENGINE=llama\nLLMCTL_PORT=%s\nLLMCTL_REG_TOKEN=tok\nLLMCTL_REG_PROTOCOL=http\n' "${PORT}"
  printf 'LLMCTL_REG_HEALTH=/health\nLLMCTL_REG_KIND=llm\nLLMCTL_REG_PROFILE=small\nLLMCTL_REG_LOOPBACK=1\n'; } > "${LLMCTL_SERVICES_DIR}/small.env"
sleep 300 >/dev/null 2>&1 & ENGINE_PID=$!; GW_BG_PIDS+=("${ENGINE_PID}")
export LLMCTL_ROOT="${GW_TREE}" LLMCTL_REGISTER_WAIT=15 LLMCTL_REGISTER_POLL=1 LLMCTL_REGISTER_IDENTITY_WAIT=1 LLMCTL_VALIDATE_ON_START=1
export GW_VALIDATE_SLEEP=3 GW_VALIDATE_RC=0

gw_calls_reset
( "${L}" validate-after-start small >"${TEST_TMP}/cli.out" 2>&1 || true ) &
P1=$!
sleep 1
( timeout 60 bash "${GW_TREE}/lib/svc_hook.sh" _wait_register small "${ENGINE_PID}" >"${TEST_TMP}/waiter.out" 2>&1 || true ) &
P2=$!
wait "${P1}" "${P2}"
n="$(gw_count '^validate_profile_begin small ')"
assert_eq 2 "${n}" "both entry points validated (the stub records no PASS, so the second still runs): ${n} begin lines"
e1="$(awk '$1=="validate_profile_end"{print $4}' "${GW_CALLS}" | sed -n 1p)"
b2="$(awk '$1=="validate_profile_begin"{print $3}' "${GW_CALLS}" | sed -n 2p)"
assert_eq 1 "$(python3 -I -c 'import sys; e1,b2=float(sys.argv[1] or 0),float(sys.argv[2] or 0); print(1 if e1>0 and b2>=e1 else 0)' "${e1:-0}" "${b2:-0}")" "the second validation began (${b2:-none}) only after the first ended (${e1:-none}): no concurrent probe loops"

echo "== review 3 of 2026-10-15, finding 10: a MANUAL 'llmctl validate' serialises on the same lock"
LOCKF="${LLMCTL_RUNTIME_DIR}/.validate-small.lock"
gw_mark_running small "${PORT}"; gw_calls_reset
( flock -x 9; date +%s.%N > "${TEST_TMP}/held.start"; sleep 3; date +%s.%N > "${TEST_TMP}/held.end" ) 9>"${LOCKF}" &
H=$!
for (( i=0; i<50; i++ )); do [[ -s "${TEST_TMP}/held.start" ]] && break; sleep 0.1; done
rc=0; GW_VALIDATE_SLEEP=0 "${L}" validate small >"${TEST_TMP}/man.out" 2>&1 || rc=$?
wait "${H}" || true
b="$(awk '$1=="validate_profile_begin"{print $3}' "${GW_CALLS}" | sed -n 1p)"
assert_eq 0 "${rc}" "the manual validate ran (PASS) once the lock was free"
assert_eq 1 "$(python3 -I -c 'import sys; b,e=float(sys.argv[1] or 0),float(sys.argv[2] or 0); print(1 if b>0 and b>=e else 0)' "${b:-0}" "$(cat "${TEST_TMP}/held.end")")" "it began (${b:-none}) only after the holder released the lock ($(cat "${TEST_TMP}/held.end"))"

gw_mark_running small "${PORT}"; gw_calls_reset
( flock -x 9; sleep 6 ) 9>"${LOCKF}" &
H=$!; sleep 0.5
rc=0; LLMCTL_VALIDATE_LOCK_WAIT=1 GW_VALIDATE_SLEEP=0 "${L}" validate small >"${TEST_TMP}/man2.out" 2>&1 || rc=$?
assert_eq 2 "${rc}" "a lock held past LLMCTL_VALIDATE_LOCK_WAIT -> UNDETERMINED (2)"
assert_eq 0 "$(gw_count '^validate_profile_begin small ')" "...and no probe loop ran beside the holder"
assert_contains "$(cat "${TEST_TMP}/man2.out")" "being validated by another process" "...and the reason is printed"
rc=0; LLMCTL_VALIDATE_LOCK_WAIT=1 LLMCTL_VALIDATE_LOCK_HELD="small:1" GW_VALIDATE_SLEEP=0 "${L}" validate small >"${TEST_TMP}/man3.out" 2>&1 || rc=$?
assert_eq 2 "${rc}" "a forged LLMCTL_VALIDATE_LOCK_HELD (pid 1 is no ancestor holding it) does not skip the lock"
kill "${H}" 2>/dev/null || true; wait "${H}" 2>/dev/null || true

gw_mark_running small "${PORT}"; gw_calls_reset
rc=0; LLMCTL_VALIDATE_LOCK_WAIT=2 GW_VALIDATE_SLEEP=0 L="${L}" timeout 30 bash -c 'exec 9>"$1"; flock -x 9; LLMCTL_VALIDATE_LOCK_HELD="small:$$" "${L}" validate small' _ "${LOCKF}" >"${TEST_TMP}/man4.out" 2>&1 || rc=$?
assert_eq 0 "${rc}" "re-entrant: the holder's own 'llmctl validate' child (the waiter's pattern) runs inline, no self-deadlock"
assert_eq 1 "$(gw_count '^validate_profile_begin small ')" "...and it validated"
rm -f "${LLMCTL_RUNTIME_DIR}/small.run"
test_finish
