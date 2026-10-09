#!/usr/bin/env bash
# svc_backend_direct.sh - a REAL process backend for tests (not a stub): it
# loads the production Linux backend (so svc_write_env produces the genuine
# env record, key paths, registration metadata) and replaces only the
# service-MANAGER half: instead of `systemctl --user`, svc_start spawns the
# profile's real exec from that env record as a plain background process the
# same way the unit's ExecStart does (no globbing, LLMCTL_ARGS word-split),
# tracks its pid and stops it with signals after proving the pid's identity.
#
# Selected through LLMCTL_SERVICE_BACKEND_FILE (lib/scheduler.sh
# sched_load_backend). It lets the dynamic-port and registry tests drive the
# actual scheduler start/stop/switch/enable paths and the real llmctl-decide
# binary end to end on any host, without touching the developer's systemd
# user manager. It is never installed or shipped.
set -euo pipefail

_sbd_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/service_linux.sh
source "${_sbd_dir}/../../lib/service_linux.sh"

svc_backend_name() { echo "direct-test"; }

_sbd_pidfile() { echo "${LLMCTL_STATE_DIR}/direct/$(_svc_instance_key "$1").pid"; }

# _sbd_alive <profile> -> rc 0 when the recorded pid is alive and is the
# exec recorded in the env record (identity from /proc, never the pid alone).
_sbd_alive() {
  local pf pid exec_bin
  pf="$(_sbd_pidfile "$1")"
  [[ -f "${pf}" ]] || return 1
  pid="$(cat "${pf}")"
  [[ "${pid}" =~ ^[0-9]+$ && "${pid}" -gt 1 ]] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  exec_bin="$(basename "$(sed -n 's/^LLMCTL_EXEC=//p' "${LLMCTL_SERVICES_DIR}/$(_svc_instance_key "$1").env" | head -1)")"
  tr '\0' '\n' < "/proc/${pid}/cmdline" 2>/dev/null | grep -qxF -- "${exec_bin}" \
    || tr '\0' '\n' < "/proc/${pid}/cmdline" 2>/dev/null | grep -q -- "/${exec_bin}\$"
}

svc_start() {
  local inst envf exec_bin
  inst="$(_svc_instance_key "$1")"
  envf="${LLMCTL_SERVICES_DIR}/${inst}.env"
  [[ -f "${envf}" ]] || { echo "svc_start: no env record ${envf}" >&2; return 1; }
  if _sbd_alive "$1"; then return 0; fi
  # shellcheck disable=SC1090
  eval "exec_bin=$(sed -n 's/^LLMCTL_EXEC=//p' "${envf}" | head -1)"
  local -a args
  eval "args=( $(sed -n 's/^LLMCTL_ARGS=//p' "${envf}" | head -1) )"
  mkdir -p "$(dirname "$(_sbd_pidfile "$1")")" "${LLMCTL_LOG_DIR}"
  "${exec_bin}" "${args[@]}" >> "${LLMCTL_LOG_DIR}/${inst}.log" 2>&1 < /dev/null &
  echo "$!" > "$(_sbd_pidfile "$1")"
  disown "$!" 2>/dev/null || true
  return 0
}

svc_stop() {
  local pid
  if ! _sbd_alive "$1"; then rm -f "$(_sbd_pidfile "$1")"; return 0; fi
  pid="$(cat "$(_sbd_pidfile "$1")")"
  kill -TERM "${pid}" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "${pid}" 2>/dev/null || break; sleep 0.3; done
  kill -0 "${pid}" 2>/dev/null && kill -KILL "${pid}" 2>/dev/null || true
  rm -f "$(_sbd_pidfile "$1")"
  return 0
}

svc_restart() { svc_stop "$1"; svc_start "$1"; }
svc_enable()  { svc_start "$1"; }
svc_disable() { svc_stop "$1"; rm -f "${LLMCTL_SERVICES_DIR}/$(_svc_instance_key "$1").env"; }
svc_is_active() { _sbd_alive "$1"; }
svc_is_failed() { return 1; }
svc_status() { if _sbd_alive "$1"; then echo "active (direct)"; else echo "inactive"; fi; }
svc_logs() { tail -n "${2:-100}" "${LLMCTL_LOG_DIR}/$(_svc_instance_key "$1").log" 2>/dev/null || true; }
svc_main_pid() { if _sbd_alive "$1"; then cat "$(_sbd_pidfile "$1")"; fi; }
# This backend manages no gateway UNIT (tests start the gateway directly through lib/svc_hook.sh run-gateway).
# The inherited production version asks `systemctl --user` for llmctl-decide-gateway.service, i.e. the developer's
# real user manager: on a host that runs a persistent gateway its pid leaked into portreg_live_set and every
# registry == live comparison reported "live service without a registry row: decide-gateway".
decide_service_main_pid() { return 0; }
