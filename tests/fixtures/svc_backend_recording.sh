#!/usr/bin/env bash
# svc_backend_recording.sh - a RECORDING service-manager backend for the gate-wiring RED tests.
# It loads the production Linux backend (real svc_write_env / env records / unit naming) and replaces only the
# service-MANAGER half: no systemd, no process. Every lifecycle verb is appended to $GW_CALLS
# ("svc_start <p>", "svc_stop <p>", "svc_restart <p>", "svc_enable <p>", "svc_disable <p>") and "active" is a
# marker file under $GW_ACTIVE_DIR, so the scheduler's reservation reconciliation sees a consistent world.
# Selected through LLMCTL_SERVICE_BACKEND_FILE. Never installed or shipped.
set -euo pipefail
_sbr_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/service_linux.sh
# service_linux.sh re-sources the REAL lib/hardware.sh (by its real path), which would overwrite the test overlay of
# hw_pressure_gate that tests/gate_wiring_lib.sh installed in the throw-away tree: keep the caller's definition.
_sbr_gate_def="$(declare -f hw_pressure_gate 2>/dev/null || true)"
source "${_sbr_dir}/../../lib/service_linux.sh"
[[ -z "${_sbr_gate_def}" ]] || eval "${_sbr_gate_def}"

svc_backend_name() { echo "recording-test"; }
_sbr_rec() { printf '%s\n' "$*" >> "${GW_CALLS:?GW_CALLS unset}"; }
_sbr_mark() { mkdir -p "${GW_ACTIVE_DIR:?}"; : > "${GW_ACTIVE_DIR}/$(_svc_instance_key "$1")"; }
_sbr_unmark() { rm -f "${GW_ACTIVE_DIR:?}/$(_svc_instance_key "$1")"; }

svc_start()   { _sbr_rec "svc_start $1"; [[ "${GW_SVC_START_FAIL:-0}" == 1 ]] && return 1; _sbr_mark "$1"; }
svc_stop()    { _sbr_rec "svc_stop $1"; _sbr_unmark "$1"; return 0; }
svc_restart() { _sbr_rec "svc_restart $1"; _sbr_mark "$1"; }
svc_enable()  { _sbr_rec "svc_enable $1"; _sbr_mark "$1"; }
svc_disable() { _sbr_rec "svc_disable $1"; _sbr_unmark "$1"; }
svc_is_active() { [[ -f "${GW_ACTIVE_DIR:?}/$(_svc_instance_key "$1")" ]]; }
svc_is_failed() { return 1; }
# The hardening branch's scheduler verifies a start with svc_started_ok (real: `systemctl --user is-active`). The recording
# backend must answer from its own marker files, or the hermetic tests would query the HOST's systemd user manager.
svc_started_ok() { svc_is_active "$1"; }
svc_status() { if svc_is_active "$1"; then echo "active (recording)"; else echo "inactive"; fi; }
svc_logs() { return 0; }
svc_main_pid() { return 0; }
decide_service_main_pid() { return 0; }
