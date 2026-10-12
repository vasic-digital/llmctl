#!/usr/bin/env bash
# test_enable_failure_paths.sh - RED-first (independent review of the hardening tip), against a FAKE `systemctl`.
#  M1: `llmctl enable` whose unit is NOT active after the start (ExecCondition skip / exited) returned 1 but left the unit
#      symlink-enabled and ${profile}.enabled touched. Contract: that failure path undoes both (svc_disable + marker removed).
#  M2: `llmctl enable` whose bounded start timed out (unit still activating) wrote the reservation for a unit that may later
#      fail (rc 75 gate). Contract: no reservation until the unit is ACTIVE (reconcile writes it later for enabled+active units).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap 'test_teardown_env' EXIT
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
LLMCTL="${LLMCTL_ROOT}/bin/llmctl"
FAKEBIN="${TEST_TMP}/fakebin"; mkdir -p "${FAKEBIN}"
export FAKE_STATE="${TEST_TMP}/fake_state"; mkdir -p "${FAKE_STATE}"
export FAKE_LOG="${TEST_TMP}/systemctl.log"; : > "${FAKE_LOG}"
cat > "${FAKEBIN}/systemctl" <<'F'
#!/usr/bin/env bash
[[ "${1:-}" == "--user" ]] || exit 1; shift
printf '%s\n' "$*" >> "${FAKE_LOG}"
verb="${1:-}"; shift || true; unit=""; for a in "$@"; do unit="${a}"; done
case "${verb}" in
  is-active) s="$(cat "${FAKE_STATE}/${unit}" 2>/dev/null || echo inactive)"; echo "${s}"; [[ "${s}" == active ]]; exit $? ;;
  is-failed) exit 1 ;;
  start)
    case "${FAKE_START_MODE:-ok}" in
      skip) exit 0 ;;
      slow) echo activating > "${FAKE_STATE}/${unit}"; sleep 60; exit 0 ;;
      *)    echo active > "${FAKE_STATE}/${unit}"; exit 0 ;;
    esac ;;
  stop) rm -f "${FAKE_STATE}/${unit}"; exit 0 ;;
  *) exit 0 ;;
esac
F
chmod +x "${FAKEBIN}/systemctl"; export PATH="${FAKEBIN}:${PATH}"
mkdir -p "${LLMCTL_MODELS_DIR}/fast"; : > "${LLMCTL_MODELS_DIR}/fast/Llama-3.1-8B-Instruct-Q4_K_M.gguf"
export LLMCTL_READY_TIMEOUT=0
UNIT="llmctl-llama@fast.service"

echo "== M1: enable whose unit is not active after the start undoes the enable =="
rc=0; out="$(FAKE_START_MODE=skip timeout 60 "${LLMCTL}" enable fast 2>&1)" || rc=$?
assert_eq "1" "${rc}" "M1: enable fails when the unit is not active after the start"
assert_contains "${out}" "unit not active after start" "M1: clear message"
assert_file_absent "${LLMCTL_SERVICES_DIR}/fast.enabled" "M1: the .enabled marker is removed again"
assert_contains "$(cat "${FAKE_LOG}")" "disable ${UNIT}" "M1: the unit symlink is undone through the backend (systemctl --user disable)"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/fast.run" "M1: no reservation"

echo "== control: enable of a unit that becomes active keeps marker + reservation =="
: > "${FAKE_LOG}"; rm -rf "${FAKE_STATE:?}"/*
rc=0; out="$(FAKE_START_MODE=ok timeout 60 "${LLMCTL}" enable fast 2>&1)" || rc=$?
assert_eq "0" "${rc}" "control: enable succeeds"
assert_file_exists "${LLMCTL_SERVICES_DIR}/fast.enabled" "control: marker kept"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/fast.run" "control: reservation written for an ACTIVE unit"
"${LLMCTL}" disable fast >/dev/null 2>&1 || true; rm -rf "${FAKE_STATE:?}"/*

echo "== M2: enable whose bounded start timed out (unit still activating) writes no reservation yet =="
rc=0; out="$(FAKE_START_MODE=slow LLMCTL_START_WAIT=2 timeout 60 "${LLMCTL}" enable fast 2>&1)" || rc=$?
assert_eq "0" "${rc}" "M2: enable still exits 0 (a slow load must not make enable fail)"
assert_contains "${out}" "still starting" "M2: loud warning"
assert_eq "activating" "$(cat "${FAKE_STATE}/${UNIT}" 2>/dev/null || echo MISSING)" "M2: the unit is left activating"
assert_file_exists "${LLMCTL_SERVICES_DIR}/fast.enabled" "M2: the unit stays enabled (it restarts on its own)"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/fast.run" "M2: no reservation for a unit that may still fail (reconcile writes it once active)"
test_finish
