#!/usr/bin/env bash
# svc_hook.sh - service-manager hooks for llmctl units and agents.
#
# Invoked BY the generated systemd units / launchd agents (never by users):
#
#   svc_hook.sh prestart <instance>      ExecStartPre: (re)create the engine's
#                                        internal key file - true per-start
#                                        rotation (gap G-028). No-op for
#                                        services without a key file.
#   svc_hook.sh register <instance>      ExecStartPost: detach a waiter that
#                                        registers the service in the registry
#                                        once its health endpoint answers.
#   svc_hook.sh unregister <instance>    ExecStopPost: drop the registry row
#                                        (the port hold is kept so a restart
#                                        reuses the port, FR-088).
#   svc_hook.sh run-engine <instance> -- <cmd...>
#                                        launchd ProgramArguments wrapper (macOS has no
#                                        ExecStartPre/Post): rotate the key, start the
#                                        detached registration waiter for THIS pid, then
#                                        exec the engine command - so a KeepAlive respawn
#                                        re-registers the service exactly like a systemd
#                                        Restart=always does (C-13).
#   svc_hook.sh run-gateway              ExecStart wrapper of the decision
#                                        gateway: allocate its port (fixed 8095
#                                        by default, dynamic on request), select
#                                        registry-based backend resolution, exec
#                                        `llmctl-decide serve --foreground` (which
#                                        publishes itself, kind=gateway).
#
# <instance> names the env record $LLMCTL_SERVICES_DIR/<instance>.env written
# by svc_write_env. The record is PARSED (never sourced: its LLMCTL_ARGS line
# is shell-quoted words, not a shell assignment).
#
# No secret ever passes through this file: only key-file PATHS are handled;
# new keys are written 0600 into a 0700 directory and never printed.
set -euo pipefail

_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_sh_dir}/common.sh"
# shellcheck source=portreg.sh
source "${_sh_dir}/portreg.sh"
# shellcheck source=decide_timeout.sh
source "${_sh_dir}/decide_timeout.sh"

# _hk_get <env-file> <KEY> -> value of KEY (shell-unquoted for the simple
# escapes printf %q produces), empty when absent.
_hk_get() {
  local raw
  raw="$(sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1)"
  printf '%s' "${raw}" | sed -e 's/\\\(.\)/\1/g' -e "s/^'\\(.*\\)'\$/\\1/"
}

# _hk_log <message> - append to the shared hook log (never fails the unit).
_hk_log() {
  ensure_dir "${LLMCTL_LOG_DIR}" 2>/dev/null || true
  printf '%s svc_hook[%s]: %s\n' "$(date -u +%FT%TZ)" "$$" "$*" >> "${LLMCTL_LOG_DIR}/svc_hook.log" 2>/dev/null || true
}

# _hk_new_key <path> - atomically replace <path> with a fresh random key
# (0600 file in a 0700 directory). Uses /dev/urandom only.
_hk_new_key() {
  local f="$1" d tmp made=0 own=0
  d="$(dirname "${f}")"
  # Only a directory llmctl owns (under $LLMCTL_STATE_DIR/keys) or one created right here is
  # chmod 700: a key path an operator points elsewhere (LLMCTL_ONNX_KEY_FILE=~/onnx.key) must never
  # turn $HOME - or any directory it merely lives in - into 0700 (C-14).
  case "${d}/" in "${LLMCTL_STATE_DIR}/keys/"*) own=1 ;; esac
  [[ -d "${d}" ]] || made=1
  ( umask 077; mkdir -p "${d}" ) || return 1
  if (( own || made )); then chmod 700 "${d}" 2>/dev/null || true; fi
  tmp="$(umask 077; mktemp "${f}.XXXXXX")" || return 1
  if ! head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "${tmp}"; then
    rm -f "${tmp}"; return 1
  fi
  printf '\n' >> "${tmp}"
  chmod 600 "${tmp}"
  mv -f "${tmp}" "${f}"
}

# _hk_http_ready <port> <path> -> rc 0 once the endpoint answers HTTP 2xx
# (curl) or at least accepts a TCP connection (no curl).
_hk_ready() {
  local port="$1" path="$2" proto="${3:-http}"
  if [[ "${proto}" == "http" ]] && command -v curl >/dev/null 2>&1; then
    curl -sf --max-time 2 "http://127.0.0.1:${port}${path}" >/dev/null 2>&1
  else
    ( exec 3<>"/dev/tcp/127.0.0.1/${port}" ) 2>/dev/null
  fi
}

# _hk_wait_register <name> <port> <pid> <token> <proto> <health> <kind> <profile> <instance> <loopback> [keyfile]
# Waits (bounded by LLMCTL_REGISTER_WAIT seconds, default 600 - a cold model
# load can be slow) until the service answers, then registers it. Returns 1 when
# the process died or never became ready.
_hk_wait_register() {
  local name="$1" port="$2" pid="$3"
  local waited=0 limit="${LLMCTL_REGISTER_WAIT:-600}" iv="${LLMCTL_REGISTER_POLL:-1}"
  local proto="$5" health="$6"
  while (( waited < limit )); do
    kill -0 "${pid}" 2>/dev/null || { _hk_log "${name}: pid ${pid} exited before becoming ready; not registered"; return 1; }
    if _hk_ready "${port}" "${health}" "${proto}"; then
      portreg_register "$@" || { _hk_log "${name}: registry register failed"; return 1; }
      _hk_log "${name}: registered port ${port} pid ${pid}"
      return 0
    fi
    sleep "${iv}"
    waited=$(( waited + iv ))
  done
  _hk_log "${name}: not ready within ${limit}s; not registered"
  return 1
}

_hk_envfile() { printf '%s/%s.env' "${LLMCTL_SERVICES_DIR}" "$1"; }

hk_prestart() {
  local inst="$1" f keyf
  f="$(_hk_envfile "${inst}")"
  [[ -f "${f}" ]] || return 0
  keyf="$(_hk_get "${f}" LLMCTL_KEY_FILE)"
  [[ -n "${keyf}" ]] || return 0
  _hk_new_key "${keyf}" || { _hk_log "${inst}: cannot rotate key file ${keyf}"; return 1; }
  _hk_log "${inst}: internal key rotated"
}

hk_register() {
  local inst="$1" pid="${MAINPID:-${2:-}}"
  [[ -n "${pid}" && "${pid}" -gt 1 ]] 2>/dev/null || { _hk_log "${inst}: no MAINPID; not registered"; return 0; }
  portreg_active || return 0
  ensure_dir "${LLMCTL_LOG_DIR}"
  # Detached: ExecStartPost must return immediately so `systemctl start` is
  # not held for the model load. stdio goes to the hook log so the waiter
  # never keeps the manager's pipes open.
  # (macOS has no setsid(1): the waiter then runs under nohup, which is enough for it to outlive the
  # hook that spawned it.)
  if command -v setsid >/dev/null 2>&1; then
    setsid bash "${BASH_SOURCE[0]}" _wait_register "${inst}" "${pid}" \
      >> "${LLMCTL_LOG_DIR}/svc_hook.log" 2>&1 < /dev/null &
  else
    nohup bash "${BASH_SOURCE[0]}" _wait_register "${inst}" "${pid}" \
      >> "${LLMCTL_LOG_DIR}/svc_hook.log" 2>&1 < /dev/null &
  fi
  disown 2>/dev/null || true
  return 0
}

hk__wait_register() {
  local inst="$1" pid="$2" f port
  f="$(_hk_envfile "${inst}")"
  [[ -f "${f}" ]] || return 1
  port="$(_hk_get "${f}" LLMCTL_PORT)"
  [[ -n "${port}" ]] || return 1
  _hk_wait_register "${inst}" "${port}" "${pid}" "$(_hk_get "${f}" LLMCTL_REG_TOKEN)" \
    "$(_hk_get "${f}" LLMCTL_REG_PROTOCOL)" "$(_hk_get "${f}" LLMCTL_REG_HEALTH)" \
    "$(_hk_get "${f}" LLMCTL_REG_KIND)" "$(_hk_get "${f}" LLMCTL_REG_PROFILE)" "${inst}" \
    "$(_hk_get "${f}" LLMCTL_REG_LOOPBACK)" "$(_hk_get "${f}" LLMCTL_KEY_FILE)"
}

# The gateway publishes itself as "decide-gateway" (Go side); "gateway" is its
# port-hold name, so both rows are cleared when asked to unregister "gateway".
hk_unregister() {
  portreg_unregister "$1"
  [[ "$1" == "gateway" ]] && portreg_unregister decide-gateway
  return 0
}

# hk_engine_libpath <exe> - G-129. A llama.cpp build is a shared-library build (libllama/libggml* next to the
# binary, found via RUNPATH). RUNPATH ranks BELOW LD_LIBRARY_PATH, so a caller whose LD_LIBRARY_PATH names a system
# directory holding a libggml.so.0 of another version makes the engine bind THAT one and die with "undefined symbol
# ggml_flash_attn_ext_set_n_kv_max" (measured; reproduced with LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu, which is
# this very host's ambient value). The fix PREPENDS the engine's own directory instead of clearing the variable: the
# caller's other entries (a CUDA library directory) stay reachable behind it. Applied only when that directory
# actually ships libggml* (colibri and the python runners are untouched). macOS resolves with DYLD_LIBRARY_PATH.
hk_engine_libpath() {
  local exe="$1" dir
  case "${exe}" in /*) ;; *) exe="$(command -v -- "${exe}" 2>/dev/null || true)" ;; esac
  [[ -n "${exe}" && -x "${exe}" ]] || return 0
  dir="$(cd "$(dirname "${exe}")" 2>/dev/null && pwd)" || return 0
  compgen -G "${dir}/libggml*" >/dev/null || return 0
  export LD_LIBRARY_PATH="${dir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
  [[ "$(uname -s)" == "Darwin" ]] && export DYLD_LIBRARY_PATH="${dir}${DYLD_LIBRARY_PATH:+:${DYLD_LIBRARY_PATH}}"
  return 0
}

# hk_run_engine <instance> -- <cmd...> - launchd wrapper; see the header. The waiter is given THIS
# shell's pid, which `exec` keeps: it becomes the engine's own pid, the one the registry must
# prove (process identity + start time).
hk_run_engine() {
  local inst="$1"; shift
  [[ "${1:-}" == "--" ]] || { echo "usage: svc_hook.sh run-engine <instance> -- <cmd...>" >&2; exit 2; }
  shift
  [[ "$#" -gt 0 ]] || { echo "svc_hook.sh run-engine: no command" >&2; exit 2; }
  hk_prestart "${inst}" || exit 1
  hk_register "${inst}" "$$"
  hk_engine_libpath "$1"
  exec "$@"
}

# hk_run_gateway - exec wrapper; see the header. Everything before the final
# exec is bounded and non-interactive; a failure aborts the start (systemd /
# launchd then apply their restart limits).
#
# Port: LLMCTL_PORT_GATEWAY (numeric, or "auto") > LLMCTL_PORT_STRATEGY >
# LLMCTL_DECIDE_PORT (default 8095, the documented port). Backends: the gateway
# resolves decision instances from the registry itself and follows changes
# without a restart (LLMCTL_DECIDE_RESOLVER=registry, FR-090), and publishes
# itself there (kind=gateway) once it listens - so no endpoint table and no
# registration are needed here.
hk_run_gateway() {
  local bin port
  ensure_dir "${LLMCTL_LOG_DIR}"
  bin="$(portreg_bin)" || die "llmctl-decide binary not found (build it: llmctl build decide)"
  port="$(portreg_allocate gateway gateway "${LLMCTL_DECIDE_PORT:-8095}")" || exit 1
  export LLMCTL_DECIDE_PORT="${port}"
  export LLMCTL_DECIDE_RESOLVER="${LLMCTL_DECIDE_RESOLVER:-registry}"
  # G-156: CPU-placed decision engines get a larger documented deadline unless one is set explicitly.
  decide_timeout_adapt
  exec "${bin}" serve --foreground
}

case "${1:-}" in
  prestart)      hk_prestart "${2:?instance required}" ;;
  register)      hk_register "${2:?instance required}" "${3:-}" ;;
  _wait_register) hk__wait_register "${2:?instance required}" "${3:?pid required}" ;;
  unregister)    hk_unregister "${2:?instance required}" ;;
  run-gateway)   hk_run_gateway ;;
  run-engine)    shift; hk_run_engine "${1:?instance required}" "${@:2}" ;;
  "")            : ;;   # sourced for testing
  *)             echo "usage: svc_hook.sh prestart|register|unregister <instance> | run-engine <instance> -- <cmd...> | run-gateway" >&2; exit 2 ;;
esac
