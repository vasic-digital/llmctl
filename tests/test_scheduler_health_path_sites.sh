#!/usr/bin/env bash
# test_scheduler_health_path_sites.sh - every scheduler readiness/registration site for a decision
# profile must use portreg_health_path (the single source), never a hard-coded /health.
# Sites: _sched_registry_publish, _sched_decision_scale_impl wait, _sched_start_impl wait, _enable_impl wait.
# portreg_health_path is overridden to return a sentinel per engine so a hard-coded path is detected.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-workstation.json"
source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/scheduler.sh"
sched_load_backend
sched_load_backend() { :; }   # backend already loaded; a reload would re-source portreg.sh over the sentinel stub
SCHED_ARGS=(); SCHED_EXEC=""

REC="${TEST_TMP}/rec"; : > "${REC}"
# --- stubs: no real services, no ports, no registry daemon ---
portreg_health_path() { printf '/SENTINEL-%s\n' "${1:-}"; }
portreg_active() { return 0; }
portreg_register() { printf 'REGISTER health=%s\n' "$6" >> "${REC}"; return 0; }
portreg_allocate() { printf '%s\n' "${3:-18999}"; }
portreg_allocate_dynamic() { printf '%s\n' "${3:-18999}"; }
portreg_release() { :; }
_sched_wait_ready() { printf 'WAIT port=%s path=%s\n' "$1" "${2:-}" >> "${REC}"; return 0; }
svc_start() { return 0; }
svc_enable() { return 0; }
svc_stop() { return 0; }
svc_main_pid() { printf '%s\n' "$$"; }
svc_is_active() { return 1; }
sched_build_launch() { SCHED_EXEC="/x/onnx_server.py"; SCHED_ARGS=(--port "$3"); return 0; }
_sched_svc_write_env() { return 0; }
_sched_write_reservation() { return 0; }
_sched_ensure_key_file() { return 0; }
_sched_reg_name() { printf '%s\n' "$1"; }
sched_running() { return 0; }
_sched_initial_used() { printf '0 0\n'; }
_sched_admission_fits() { return 0; }
hw_probe_json() { cat "${LLMCTL_FAKE_HW}"; }

PROFILE=decide-nli
ENGINE="$(catalog_engine "${PROFILE}")"
EXPECT="/SENTINEL-${ENGINE}"
assert_eq onnx "${ENGINE}" "fixture profile ${PROFILE} is an onnx decision profile"

echo "== site 1: registry publish =="
: > "${REC}"; ( _sched_registry_publish "${PROFILE}" 18999 "${PROFILE}" ) >"${TEST_TMP}/o1" 2>&1 || true; cat "${TEST_TMP}/o1" | head
assert_contains "$(cat "${REC}")" "REGISTER health=${EXPECT}" "publish registers the engine's health path"

echo "== site 2: decision scale wait =="
: > "${REC}"; _sched_decision_scale_impl "${PROFILE}" 1 >/dev/null 2>&1 || true
assert_contains "$(cat "${REC}")" "path=${EXPECT}" "scale waits on the engine's health path"

echo "== site 3: start wait =="
: > "${REC}"; _sched_start_impl "${PROFILE}" >/dev/null 2>&1 || true
assert_contains "$(cat "${REC}")" "path=${EXPECT}" "start waits on the engine's health path"

echo "== site 4: enable wait =="
: > "${REC}"; _enable_impl "${PROFILE}" >/dev/null 2>&1 || true
assert_contains "$(cat "${REC}")" "path=${EXPECT}" "enable waits on the engine's health path"

[[ "${TEST_FAILS}" -eq 0 ]] || { echo "FAILED: ${TEST_FAILS}" >&2; exit 1; }
echo "OK"
