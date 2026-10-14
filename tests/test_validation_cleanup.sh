#!/usr/bin/env bash
# test_validation_cleanup.sh - RED-first (independent review 2026-10-14, findings 4 and 8).
#  (4) validate_profile started a profile that was not running and then returned 2 WITHOUT stopping it on two paths:
#      "started but has no port reservation" and "cannot compute the validation key". Every return after a start now goes
#      through ONE cleanup path that stops it (unless --keep, which says so).
#  (8) the pressure-gate messages: the post-start refusal said "nothing was started" right after a start, and the shared
#      gate said "refusing to start" for a profile that was already running.
# Stubs only: sched_start/sched_stop are replaced by recording functions; no profile, unit or model is started.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
CALLS="${TEST_TMP}/calls"; : > "${CALLS}"
mkdir -p "${LLMCTL_MODELS_DIR}/small"; : > "${LLMCTL_MODELS_DIR}/small/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
LIB="${VALIDATE_LIB_UNDER_TEST:-${LLMCTL_ROOT}/lib/validate.sh}"

# harness <scenario> [validate args...] -> runs validate_profile small with stubbed scheduler calls; prints its rc
harness() {
  local scen="$1"; shift
  local rc=0
  env SCEN="${scen}" CALLS="${CALLS}" LIB="${LIB}" bash -c '
    set -euo pipefail
    for l in common os_detect hardware catalog scheduler; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
    source "${LIB}"
    sched_start() { echo "sched_start $*" >> "${CALLS}"
      [[ "${SCEN}" == "no-reservation" ]] && return 0
      printf "profile=small\nport=9\n" > "${LLMCTL_RUNTIME_DIR}/small.run"; }
    sched_start_unpublished() { sched_start "$@"; }
    sched_stop() { echo "sched_stop $*" >> "${CALLS}"; rm -f "${LLMCTL_RUNTIME_DIR}/small.run"; }
    case "${SCEN}" in
      key-fails) _val_key() { return 1; } ;;
    esac
    validate_profile small "$@"' _ "$@" >"${TEST_TMP}/h.out" 2>&1 || rc=$?
  echo "${rc}"
}
nstop() { grep -c '^sched_stop small' "${CALLS}" || true; }

echo "== 1. started, but no port reservation -> the profile this call started is stopped again"
: > "${CALLS}"
assert_eq 2 "$(harness no-reservation)" "no reservation after the start -> UNDETERMINED (exit 2)"
assert_eq 1 "$(grep -c '^sched_start small' "${CALLS}" || true)" "the profile was started by the validator"
assert_eq 1 "$(nstop)" "...and stopped again on the 'no port reservation' return"

echo "== 2. started, then the validation key cannot be computed -> stopped again"
: > "${CALLS}"; rm -f "${LLMCTL_RUNTIME_DIR}/small.run"
assert_eq 2 "$(harness key-fails)" "key failure after the start -> exit 2"
assert_eq 1 "$(nstop)" "...and the started profile is stopped"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/small.run" "no reservation of it is left behind"

echo "== 3. --keep leaves it running, and says so (never silently)"
: > "${CALLS}"; rm -f "${LLMCTL_RUNTIME_DIR}/small.run"
assert_eq 2 "$(harness key-fails --keep)" "key failure with --keep -> exit 2"
assert_eq 0 "$(nstop)" "--keep: not stopped"
assert_contains "$(cat "${TEST_TMP}/h.out")" "keeps running (--keep)" "--keep: the message says it keeps running"
rm -f "${LLMCTL_RUNTIME_DIR}/small.run"

echo "== 4. a profile that was ALREADY running is never stopped by a failing validation call"
: > "${CALLS}"; printf 'profile=small\nport=9\n' > "${LLMCTL_RUNTIME_DIR}/small.run"
assert_eq 2 "$(harness key-fails)" "key failure on an already-running profile -> exit 2"
assert_eq 0 "$(nstop)" "...and it is NOT stopped (this call did not start it)"
rm -f "${LLMCTL_RUNTIME_DIR}/small.run"

echo "== 5. pressure-gate wording (finding 8)"
printf 'some avg10=50.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=40.00 avg60=0.00 avg300=0.00 total=0\n' > "${TEST_TMP}/psi.high"
: > "${CALLS}"
rc=0; out="$(env LLMCTL_PSI_FILE="${TEST_TMP}/psi.high" bash -c '
  for l in common os_detect hardware catalog scheduler; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done; source "$1"
  _val_pressure_gate small psi' _ "${LIB}" 2>&1)" || rc=$?
assert_eq 75 "${rc}" "post-start gate refuses under pressure (rc 75)"
if [[ "${out}" == *"nothing was started"* ]]; then printf '  FAIL: the post-start refusal claims "nothing was started"\n    %s\n' "${out}" >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: the post-start refusal does not claim "nothing was started"\n'; fi
if [[ "${out}" == *"refusing to start small"* ]]; then printf '  FAIL: the post-start refusal says "refusing to start" a running profile\n    %s\n' "${out}" >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: the post-start refusal does not say "refusing to start"\n'; fi
assert_contains "${out}" "probes were NOT sent" "it says what was actually withheld: the probes"
rc=0; out="$(env LLMCTL_PSI_FILE="${TEST_TMP}/psi.high" bash -c '
  for l in common os_detect hardware catalog scheduler; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done; source "$1"
  _val_pressure_gate small' _ "${LIB}" 2>&1)" || rc=$?
assert_eq 75 "${rc}" "pre-start gate refuses under pressure (rc 75)"
assert_contains "${out}" "nothing was started" "control: BEFORE a start the message rightly says nothing was started"

test_finish
