#!/usr/bin/env bash
# svc_hook.sh - service-manager hooks for llmctl units and agents.
#
# Invoked BY the generated systemd units / launchd agents (never by users):
#
#   svc_hook.sh gate [<instance>]        ExecStartPre (first): refuse with exit 75 under memory pressure
#                                        (PSI / MemAvailable) - see hw_pressure_gate in lib/hardware.sh.
#   svc_hook.sh portcheck <instance>     ExecCondition: exit 98 (unit skipped, not retried) if the port is taken.
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
#                                        Restart=on-failure does (C-13).
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
# shellcheck source=hardware.sh
source "${_sh_dir}/hardware.sh"

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
      # Two units of one profile share this port: the answer may come from the OTHER unit's engine (we are the loser, still
      # loading until our bind fails). Never publish over a live engine's row, or our later unregister (pid == ours) would
      # delete the row of the engine that actually serves the port.
      if portreg_row_live_other "${name}" "${pid}"; then
        _hk_log "${name}: pid ${pid} not registered: the row is held by another live engine (a duplicate unit for this profile?)"
        return 1
      fi
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

# hk_portcheck <instance> - ExecCondition= of every engine unit: exit 98 when the profile's port is already listening.
# systemd tests RestartPreventExitStatus= only against the MAIN process, so a failing ExecStartPre (even exit 98) is
# retried (proved in tests/test_portguard_condition.sh); an ExecCondition exit of 1-254 instead skips the unit cleanly
# - not failed, not restarted. Never touches the key file.
hk_portcheck() {
  local inst="$1" f port
  f="$(_hk_envfile "${inst}")"
  [[ -f "${f}" ]] || return 0
  port="$(_hk_get "${f}" LLMCTL_PORT)"
  if [[ "${port}" =~ ^[0-9]+$ ]] && timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
    _hk_log "${inst}: port ${port} is already in use; not starting (ExecCondition exit 98)"
    printf 'llmctl: port %s is already in use on 127.0.0.1 (profile %s is probably running under another unit); not starting\n' "${port}" "${inst}" >&2
    return 98
  fi
  return 0
}

hk_prestart() {
  local inst="$1" f keyf port
  f="$(_hk_envfile "${inst}")"
  [[ -f "${f}" ]] || return 0
  # Port-in-use guard (second unit for the same profile, or a stray engine): fail FAST with the distinct code 98
  # (EADDRINUSE; every engine unit lists it in RestartPreventExitStatus) BEFORE the model is loaded and BEFORE the
  # key file is rotated under the live server. UNKNOWN: whether this systemd applies RestartPreventExitStatus to a
  # failed ExecStartPre; the StartLimit bound applies either way.
  port="$(_hk_get "${f}" LLMCTL_PORT)"
  if [[ "${port}" =~ ^[0-9]+$ ]] && timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
    _hk_log "${inst}: port ${port} is already in use; refusing to start (exit 98), key file untouched"
    printf 'llmctl: port %s is already in use on 127.0.0.1 (profile %s is probably running under another unit); not starting\n' "${port}" "${inst}" >&2
    return 98
  fi
  keyf="$(_hk_get "${f}" LLMCTL_KEY_FILE)"
  [[ -n "${keyf}" ]] || return 0
  _hk_new_key "${keyf}" || { _hk_log "${inst}: cannot rotate key file ${keyf}"; return 1; }
  _hk_log "${inst}: internal key rotated"
}

# hk_gate <instance> - ExecStartPre of every engine unit, BEFORE prestart (so a refused start never rotates a key and a
# systemd RESTART is gated exactly like a first start). It WAITS for the pressure to clear (LLMCTL_GATE_WAIT s, default
# 120; LLMCTL_GATE_POLL s, default 5) and fails closed with 75 (EX_TEMPFAIL) only if it persists: an immediate 75 was
# retried by Restart=on-failure and every retry burns StartLimitBurst, so a short spike ended in a 900 s lockout.
# TimeoutStartSec (600) covers wait + model load. A pressure that lasts through ~3 waits still ends in start-limit-hit:
# the deliberate fail-closed end state (docs/host-safety.md).
hk_gate() {
  local inst="${1:-}" f fp=0 wait="${LLMCTL_GATE_WAIT:-120}" poll="${LLMCTL_GATE_POLL:-5}" waited=0 rc=0
  [[ "${wait}" =~ ^[0-9]+$ ]] || wait=120
  [[ "${poll}" =~ ^[1-9][0-9]*$ ]] || poll=5
  if [[ -n "${inst}" ]]; then
    f="$(_hk_envfile "${inst}")"
    [[ -f "${f}" ]] && fp="$(_hk_get "${f}" LLMCTL_FOOTPRINT_MB)"
  fi
  local msg=""
  while :; do
    rc=0; msg="$(hw_pressure_gate "${fp:-0}" "${inst:-service}" 2>&1 >/dev/null)" || rc=$?
    if [[ "${rc}" -eq 0 ]]; then (( waited == 0 )) || _hk_log "${inst}: pressure cleared after ${waited}s"; return 0; fi
    if [[ "${rc}" -ne 75 || "${waited}" -ge "${wait}" ]]; then printf '%s\n' "${msg}" >&2; return "${rc}"; fi
    sleep "${poll}"; waited=$(( waited + poll ))
  done
}


# Registration waiters are tracked by pid file so a stop can end them (they otherwise poll /health for up to 600 s,
# inside the unit's cgroup, after the engine is gone).
_hk_waiter_file() { printf '%s/waiters/%s.pid' "${LLMCTL_RUNTIME_DIR:-${LLMCTL_STATE_DIR}/run}" "$1"; }
_hk_track_waiter() { ( umask 077; mkdir -p "$(dirname "$(_hk_waiter_file "$1")")" && printf '%s\n' "$2" > "$(_hk_waiter_file "$1")" ) 2>/dev/null || true; }
# _hk_kill_waiter <inst> [<stop_pid>] - kills the tracked waiter ONLY when /proc says it is our `_wait_register <inst>`
# process. With <stop_pid> (the stopping unit's MAINPID) only the waiter of THAT pid is ours: two units of one profile share
# the pid file, and a stopping loser must not kill (or untrack) the winner's waiter.
_hk_kill_waiter() {
  local f pid cmd want="${1}"
  [[ "${2:-}" =~ ^[0-9]+$ ]] && want="${1} ${2}"
  f="$(_hk_waiter_file "$1")"
  [[ -f "${f}" ]] || return 0
  pid="$(head -1 "${f}" 2>/dev/null || true)"
  [[ "${pid}" =~ ^[0-9]+$ && "${pid}" -gt 1 ]] || { rm -f "${f}"; return 0; }
  cmd="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
  case "${cmd}" in
    *"_wait_register ${want} "*) kill "${pid}" 2>/dev/null || true; rm -f "${f}" ;;
    *"_wait_register ${1} "*) : ;;          # another unit's waiter: neither killed nor untracked
    *) rm -f "${f}" ;;                      # stale pid file
  esac
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
    _hk_track_waiter "${inst}" "$!"
  else
    nohup bash "${BASH_SOURCE[0]}" _wait_register "${inst}" "${pid}" \
      >> "${LLMCTL_LOG_DIR}/svc_hook.log" 2>&1 < /dev/null &
    _hk_track_waiter "${inst}" "$!"
  fi
  disown 2>/dev/null || true
  return 0
}

# _hk_validate_after_ready <inst> <port> <envfile> [pid] - the validation gate of the systemd path (docs/validation.md).
# Runs in the detached waiter AFTER the engine answered its health endpoint, exactly once per start, through the
# public CLI (`llmctl validate`, with LLMCTL_VALIDATE_ATTACH_PORT so it probes THIS unit and never starts a second
# one). Only for catalog LLM profiles (kind llm, profile == instance; scaled/other instances are not its business).
#   PASS -> nothing;  UNDETERMINED -> logged loudly, nothing stopped (strict mode: stopped);
#   FAIL -> `systemctl --user stop <unit>` (the normal stop path; the engine never exits non-zero by itself, so
#           Restart=on-failure cannot loop), the reservation is removed, the failure is logged.
_hk_validate_after_ready() {
  local inst="$1" port="$2" f="$3" pid="${4:-}" prof kind engine llmctl rc=0 unit st
  # the engine must still be ALIVE (kill -0 alone also succeeds on a zombie): never validate (or stop) a dead service
  if [[ -n "${pid}" ]]; then
    sleep "${LLMCTL_VALIDATE_SETTLE:-1}"   # settle: an engine that dies right after answering must not be validated
    kill -0 "${pid}" 2>/dev/null || return 0
    st="$(awk '{print $3}' "/proc/${pid}/stat" 2>/dev/null || true)"
    [[ "${st}" != "Z" ]] || return 0
  fi
  [[ "${LLMCTL_VALIDATE_ON_START:-1}" == "0" ]] && { _hk_log "${inst}: validation on start disabled (LLMCTL_VALIDATE_ON_START=0) - NOT validated"; return 0; }
  [[ "${LLMCTL_DRY_RUN:-0}" == "1" ]] && return 0
  prof="$(_hk_get "${f}" LLMCTL_REG_PROFILE)"; kind="$(_hk_get "${f}" LLMCTL_REG_KIND)"
  [[ "${kind}" == "llm" && -n "${prof}" && "${prof}" == "${inst}" ]] || return 0
  llmctl="${LLMCTL_ROOT}/bin/llmctl"
  [[ -x "${llmctl}" ]] || { _hk_log "${inst}: ${llmctl} not executable - NOT validated"; return 0; }
  # per-profile validation lock (the same file validate_after_start of lib/validate.sh uses): `enable`/`restart` are also
  # validated by the CLI hook; the second validator waits, then finds the first one's fresh record. Not the scheduler lock.
  mkdir -p "${LLMCTL_RUNTIME_DIR}" 2>/dev/null || true
  _hk_log "${inst}: validation: waiting for / running the validation suite(s) against the started unit (port ${port})"
  (
    flock -w "${LLMCTL_VALIDATE_LOCK_WAIT:-900}" 9 || exit 98
    if "${llmctl}" require-validated "${prof}" >/dev/null 2>&1; then exit 97; fi
    # LLMCTL_VALIDATE_FAIL_RC: the explicit-verdict code (64). A bare exit 1 (llmctl crashed / die() / set -e) is NOT a wrong
    # answer and never stops the unit.
    LLMCTL_VALIDATE_FAIL_RC=64 LLMCTL_VALIDATE_ATTACH_PROFILE="${prof}" LLMCTL_VALIDATE_ATTACH_PORT="${port}" \
      "${llmctl}" validate "${prof}" >> "${LLMCTL_LOG_DIR}/svc_hook.log" 2>&1
  ) 9>"${LLMCTL_RUNTIME_DIR}/.validate-${prof}.lock" || rc=$?
  if [[ "${rc}" == "97" ]]; then _hk_log "${inst}: validation: a fresh passing record exists - not re-run"; return 0; fi
  if [[ "${rc}" == "98" ]]; then _hk_log "${inst}: validation UNDETERMINED: another validator held the lock too long - nothing stopped"; return 0; fi
  case "${rc}" in
    0) _hk_log "${inst}: validation PASSED"; return 0 ;;
    64) _hk_log "${inst}: validation FAILED (wrong answers) - stopping the unit through the normal stop path" ;;
    *) if [[ "${LLMCTL_VALIDATE_STRICT:-0}" == "1" ]]; then
         _hk_log "${inst}: validation UNDETERMINED and LLMCTL_VALIDATE_STRICT=1 - stopping the unit"
       else
         _hk_log "${inst}: validation UNDETERMINED (could not be validated) - the unit keeps running, NOT validated; llmctl require-validated ${prof} refuses"
         return 0
       fi ;;
  esac
  engine="$(_hk_get "${f}" LLMCTL_ENGINE)"
  # the reservation goes FIRST: `systemctl stop` (KillMode=control-group) SIGTERMs this very waiter, so nothing after it runs
  rm -f "${LLMCTL_RUNTIME_DIR}/${inst}.run"
  if command -v systemctl >/dev/null 2>&1 && [[ -n "${engine}" ]]; then
    unit="llmctl-${engine}@${inst}.service"
    systemctl --user stop "${unit}" >> "${LLMCTL_LOG_DIR}/svc_hook.log" 2>&1 || _hk_log "${inst}: could not stop ${unit} - stop it by hand: llmctl stop ${inst}"
  else
    "${llmctl}" stop "${inst}" >> "${LLMCTL_LOG_DIR}/svc_hook.log" 2>&1 || _hk_log "${inst}: could not stop - run: llmctl stop ${inst}"
  fi
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
    "$(_hk_get "${f}" LLMCTL_REG_LOOPBACK)" "$(_hk_get "${f}" LLMCTL_KEY_FILE)" || return 1
  _hk_validate_after_ready "${inst}" "${port}" "${f}" "${pid}"
}

# The gateway publishes itself as "decide-gateway" (Go side); "gateway" is its
# port-hold name, so both rows are cleared when asked to unregister "gateway".
hk_unregister() {
  _hk_kill_waiter "$1" "${MAINPID:-}"
  portreg_unregister "$1" "${MAINPID:-}"
  [[ "$1" == "gateway" ]] && portreg_unregister decide-gateway "${MAINPID:-}"
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

# Sourced (by a test or another script that has its own positional parameters): define the functions, dispatch
# nothing. Only an execution of this file as a program dispatches on its own arguments.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] || return 0 2>/dev/null || true

case "${1:-}" in
  gate)          hk_gate "${2:-}" ;;
  portcheck)     hk_portcheck "${2:?instance required}" ;;
  prestart)      hk_prestart "${2:?instance required}" ;;
  register)      hk_register "${2:?instance required}" "${3:-}" ;;
  _wait_register) hk__wait_register "${2:?instance required}" "${3:?pid required}" ;;
  unregister)    hk_unregister "${2:?instance required}" ;;
  run-gateway)   hk_run_gateway ;;
  run-engine)    shift; hk_run_engine "${1:?instance required}" "${@:2}" ;;
  "")            : ;;   # sourced for testing
  *)             echo "usage: svc_hook.sh gate|portcheck|prestart|register|unregister <instance> | run-engine <instance> -- <cmd...> | run-gateway" >&2; exit 2 ;;
esac
