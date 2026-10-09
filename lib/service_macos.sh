#!/usr/bin/env bash
# service_macos.sh - launchd LaunchAgent backend for llmctl services.
#
# Each enabled profile gets ~/Library/LaunchAgents/com.llmctl.<profile>.plist
# with KeepAlive + ThrottleInterval and append logs under $LLMCTL_LOG_DIR.
#
# Crash-loop bounding (FR-044): ThrottleInterval=60 rate-limits restarts to
# at most once per 60s. Unlike systemd's StartLimitBurst, launchd has NO
# native "give up after N failures" primitive for a KeepAlive=true job - a
# permanently-broken model restarts forever here, just slowly. This is an
# honest platform gap (documented, not silently claimed equivalent to
# Linux); see svc_is_failed below.
#
# LLMCTL_DRY_RUN=1: plist/env files are still written (so their content is
# testable), but every launchctl invocation is printed instead of executed.
set -euo pipefail

_svm_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_svm_dir}/common.sh"
# shellcheck source=portreg.sh
source "${_svm_dir}/portreg.sh"

svc_backend_name() { echo "launchd"; }

svc_plist_dir() {
  echo "${LLMCTL_PLIST_DIR:-${HOME}/Library/LaunchAgents}"
}

_svc_label() { echo "com.llmctl.$1"; }

_svc_plist_path() { echo "$(svc_plist_dir)/$(_svc_label "$1").plist"; }

_svc_launchctl() {
  if [[ "${LLMCTL_DRY_RUN}" == "1" ]]; then
    printf '[dry-run] launchctl %s\n' "$*"
    return 0
  fi
  launchctl "$@"
}

# On macOS there is no global unit install step; plists are per-profile.
svc_install() {
  ensure_dir "$(svc_plist_dir)"
  ensure_state_dirs
  info "launchd backend ready (agents dir: $(svc_plist_dir))"
}

# _svc_plist_xml <string> -> the string XML-escaped (& < > " '), for <string> elements.
# C3-07: NOT done with ${s//</&lt;}. Since bash 5.2 (shopt patsub_replacement, ON by default) an unquoted '&' in the
# replacement means "the matched text", so '<' became '<lt;' - and quoting that '&' is not portable to bash 3.2 (macOS
# /bin/bash and Homebrew bash differ). sed is POSIX and identical on GNU and BSD; the '&' of each replacement is
# escaped for sed (\&), and '&' itself is escaped FIRST. The sentinel 'x' keeps trailing newlines intact.
_svc_plist_xml() {
  local s="$1" out
  out="$(printf '%sx' "${s}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\\&apos;/g")"
  printf '%s' "${out%x}"
}

# plist-escape a single argument into an <string> element.
_svc_plist_str() {
  printf '    <string>%s</string>\n' "$(_svc_plist_xml "$1")"
}

# _svc_plist_env_dict [decide-bin] -> the `EnvironmentVariables` key + dict shared by EVERY llmctl agent (engines and
# the gateway), the launchd counterpart of the Environment= lines of the Linux units. launchd starts a job with its
# own minimal environment, so without this the hook (svc_hook.sh) falls back to the default state/services/log
# directories and, with LLMCTL_STATE_DIR & co. overridden, finds no env record: it neither rotates the key nor
# registers the service (C2-04). LLMCTL_DECIDE_BIN is written when the registry binary resolves.
_svc_plist_env_dict() {
  local bin="${1:-}" kv k v
  printf '  <key>EnvironmentVariables</key>\n  <dict>\n'
  for kv in "LLMCTL_ROOT=${LLMCTL_ROOT}" "LLMCTL_STATE_DIR=${LLMCTL_STATE_DIR}" \
            "LLMCTL_LOG_DIR=${LLMCTL_LOG_DIR}" "LLMCTL_SERVICES_DIR=${LLMCTL_SERVICES_DIR}" \
            "LLMCTL_CONFIG_DIR=${LLMCTL_CONFIG_DIR}" "LLMCTL_DATA_DIR=${LLMCTL_DATA_DIR}" \
            "LLMCTL_RUNTIME_DIR=${LLMCTL_RUNTIME_DIR}"${bin:+ "LLMCTL_DECIDE_BIN=${bin}"}; do
    k="${kv%%=*}"; v="${kv#*=}"
    printf '    <key>%s</key>\n' "${k}"
    _svc_plist_str "${v}"
  done
  printf '  </dict>\n'
}

# svc_write_env <profile> <engine> <exec> <args...>
# Keeps the same env record as the Linux backend (source of truth for the
# scheduler) AND renders the LaunchAgent plist.
svc_write_env() {
  local profile="$1" engine="$2" exec_bin="$3"; shift 3
  ensure_dir "${LLMCTL_SERVICES_DIR}"
  ensure_dir "$(svc_plist_dir)"

  local env_file="${LLMCTL_SERVICES_DIR}/${profile}.env"
  ( umask 077; : > "${env_file}" )   # owner-only from the first byte
  {
    printf 'LLMCTL_PROFILE=%q\n' "${profile}"
    printf 'LLMCTL_ENGINE=%q\n' "${engine}"
    printf 'LLMCTL_EXEC=%q\n' "${exec_bin}"
    printf 'LLMCTL_ARGS='
    printf '%q ' "$@"
    printf '\n'
    portreg_env_lines "${profile}" "${engine}" "${exec_bin}" "$@"
  } > "${env_file}"
  chmod 600 "${env_file}"

  local plist; plist="$(_svc_plist_path "${profile}")"
  ( umask 077; : > "${plist}" )      # plist is 0600 too: it names key-file PATHS
  {
    cat <<'PLISTHDR'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
PLISTHDR
    printf '  <string>%s</string>\n' "$(_svc_label "${profile}")"
    cat <<'PLISTARGS'
  <key>ProgramArguments</key>
  <array>
PLISTARGS
    # Wrapped in `svc_hook.sh run-engine <profile> --`: launchd has no ExecStartPost, so the wrapper
    # (prestart key rotation, a detached registration waiter, then exec of the engine) is what
    # re-registers the service after a KeepAlive respawn (C-13). The engine command follows `--`.
    _svc_plist_str "/bin/bash"
    _svc_plist_str "${_svm_dir}/svc_hook.sh"
    _svc_plist_str "run-engine"
    _svc_plist_str "${profile}"
    _svc_plist_str "--"
    _svc_plist_str "${exec_bin}"
    local a
    for a in "$@"; do _svc_plist_str "${a}"; done
    printf '  </array>\n'
    _svc_plist_env_dict "$(portreg_bin 2>/dev/null || true)"
    cat <<PLISTTAIL
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>60</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$(_svc_plist_xml "${LLMCTL_LOG_DIR}/${profile}.log")</string>
  <key>StandardErrorPath</key>
  <string>$(_svc_plist_xml "${LLMCTL_LOG_DIR}/${profile}.log")</string>
  <key>WorkingDirectory</key>
  <string>$(_svc_plist_xml "${LLMCTL_ROOT}")</string>
</dict>
</plist>
PLISTTAIL
  } > "${plist}"
  chmod 600 "${plist}"
  log "wrote ${plist}"
}

# --- lifecycle ---------------------------------------------------------------
_svc_domain() { echo "gui/$(id -u)"; }

svc_enable() {
  local plist; plist="$(_svc_plist_path "$1")"
  _svc_launchctl bootstrap "$(_svc_domain)" "${plist}"
}

svc_disable() {
  _svc_launchctl bootout "$(_svc_domain)/$(_svc_label "$1")" || true
  [[ "${LLMCTL_DRY_RUN}" == "1" ]] || rm -f "$(_svc_plist_path "$1")" "${LLMCTL_SERVICES_DIR}/$1.env"
}

# svc_start rotates the service's internal key file first (a no-op for
# services without one). The plist's ProgramArguments run through
# `svc_hook.sh run-engine`, which rotates the key and re-registers the service
# on EVERY (re)spawn - `launchctl kickstart -k` below and a KeepAlive respawn
# alike (C-13); rotating here as well would rotate twice per start.
svc_start() {
  _svc_launchctl kickstart -k "$(_svc_domain)/$(_svc_label "$1")"
}
svc_stop()    { _svc_launchctl kill SIGTERM "$(_svc_domain)/$(_svc_label "$1")"; }
svc_restart() { svc_start "$1"; }

svc_status() {
  if [[ "${LLMCTL_DRY_RUN}" == "1" ]]; then
    printf '[dry-run] launchctl print %s\n' "$(_svc_domain)/$(_svc_label "$1")"
    return 0
  fi
  launchctl print "$(_svc_domain)/$(_svc_label "$1")" || true
}

svc_logs() {
  local profile="$1" lines="${2:-100}"
  local logf="${LLMCTL_LOG_DIR}/${profile}.log"
  if [[ "${LLMCTL_DRY_RUN}" == "1" ]]; then
    printf '[dry-run] tail -n %s %s\n' "${lines}" "${logf}"
    return 0
  fi
  [[ -f "${logf}" ]] || die "no log file yet: ${logf}"
  tail -n "${lines}" "${logf}"
}

svc_is_active() {
  local profile="$1"
  if [[ "${LLMCTL_DRY_RUN}" == "1" ]]; then
    [[ -f "${LLMCTL_RUNTIME_DIR}/${profile}.run" ]]
    return
  fi
  launchctl print "$(_svc_domain)/$(_svc_label "${profile}")" >/dev/null 2>&1
}

# svc_is_failed <profile> - see the crash-loop bounding note at the top of
# this file: launchd has no native equivalent of systemd's "permanently
# failed after N restarts" state for a KeepAlive=true job, so the real
# (non-dry-run) case honestly reports false rather than fabricating a
# signal launchd does not provide. The dry-run branch still supports the
# marker-file convention so the OS-agnostic status-reporting logic in
# lib/scheduler.sh is testable the same way on both backends.
svc_is_failed() {
  local profile="$1"
  if [[ "${LLMCTL_DRY_RUN}" == "1" ]]; then
    [[ -f "${LLMCTL_RUNTIME_DIR}/${profile}.failed" ]]
    return
  fi
  return 1
}

# svc_stale_units - launchd agents are regenerated per profile on every start; there is no
# install-time unit body to go stale (the Linux backend's StartLimit check does not apply).
svc_stale_units() { return 0; }

svc_known_profiles() {
  local f
  for f in "${LLMCTL_SERVICES_DIR}"/*.env; do
    [[ -e "${f}" ]] || continue
    basename "${f}" .env
  done
}

# svc_main_pid <profile> -> the job's pid from `launchctl print` (empty when
# not running). Registry liveness on macOS uses `ps -o args=` (no procfs) -
# documented gap G-009: this path is validated by fixtures, not on a Mac.
svc_main_pid() {
  local pid=""
  if [[ "${LLMCTL_DRY_RUN:-0}" == "1" ]]; then return 0; fi
  pid="$(launchctl print "$(_svc_domain)/$(_svc_label "$1")" 2>/dev/null | awk '/^[[:space:]]*pid = /{print $3; exit}')"
  [[ "${pid}" =~ ^[0-9]+$ && "${pid}" -gt 1 ]] && printf '%s\n' "${pid}"
  return 0
}

# --- decision gateway as a LaunchAgent (spec 009 FR-031, T081) ----------------
DECIDE_GATEWAY_LABEL="com.llmctl.decide-gateway"

_decide_gateway_plist_path() { echo "$(svc_plist_dir)/${DECIDE_GATEWAY_LABEL}.plist"; }

# _decide_gateway_plist_body <bin>
# ProgramArguments is an ARRAY (never a shell string); the wrapper
# (lib/svc_hook.sh run-gateway) allocates the port, resolves backends from the
# registry and EXECs `llmctl-decide serve --foreground`. No key and no secret
# is in the file: the access key is read by the gateway itself from the
# installation .env (0600). KeepAlive + ThrottleInterval bound the restarts;
# launchd has no give-up-after-N primitive (platform gap, see the file header).
_decide_gateway_plist_body() {
  local bin="$1"
  cat <<'HDR'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
HDR
  printf '  <string>%s</string>\n' "${DECIDE_GATEWAY_LABEL}"
  cat <<'ARGS'
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
ARGS
  _svc_plist_str "${_svm_dir}/svc_hook.sh"
  _svc_plist_str "run-gateway"
  printf '  </array>\n'
  _svc_plist_env_dict "${bin}"
  cat <<TAIL
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$(_svc_plist_xml "${LLMCTL_LOG_DIR}/decide-gateway.log")</string>
  <key>StandardErrorPath</key>
  <string>$(_svc_plist_xml "${LLMCTL_LOG_DIR}/decide-gateway.log")</string>
  <key>WorkingDirectory</key>
  <string>$(_svc_plist_xml "${LLMCTL_ROOT}")</string>
</dict>
</plist>
TAIL
}

# _decide_gateway_write_plist - writes the agent file 0600, prints its path.
_decide_gateway_write_plist() {
  local bin plist
  bin="$(portreg_bin)" || die "llmctl-decide binary not found - build it first: llmctl build decide"
  ensure_dir "$(svc_plist_dir)"
  ensure_state_dirs
  ensure_dir "${LLMCTL_STATE_DIR}/decide"
  plist="$(_decide_gateway_plist_path)"
  ( umask 077; : > "${plist}" )
  _decide_gateway_plist_body "${bin}" > "${plist}"
  chmod 600 "${plist}"
  printf '%s\n' "${plist}"
}

decide_service_enable() {
  local plist
  if [[ "${LLMCTL_DRY_RUN}" == "1" ]]; then
    plist="$(_decide_gateway_plist_path)"
    printf '[dry-run] write %s\n' "${plist}"     # a dry run writes no plist
  else
    plist="$(_decide_gateway_write_plist)"
    info "installed ${DECIDE_GATEWAY_LABEL} agent: ${plist}"
  fi
  # `launchctl bootstrap` on an already loaded label fails; boot it out first (failure ignored: not loaded yet) so
  # a re-enable is idempotent and also applies a changed plist.
  _svc_launchctl bootout "$(_svc_domain)/${DECIDE_GATEWAY_LABEL}" || true
  _decide_launchctl_bootstrap_retry "${plist}"
}

# _decide_launchctl_bootstrap_retry <plist> - `launchctl bootout` returns before the job is gone, so an
# immediate `bootstrap` can fail (error 5, I/O error). Retry up to LLMCTL_LAUNCHD_BOOTSTRAP_TRIES (default 5)
# times, sleeping LLMCTL_LAUNCHD_RETRY_SLEEP seconds (default 1) between tries; the last failure is returned.
_decide_launchctl_bootstrap_retry() {
  local plist="$1" tries="${LLMCTL_LAUNCHD_BOOTSTRAP_TRIES:-5}" n=1 rc=0
  while :; do
    rc=0
    _svc_launchctl bootstrap "$(_svc_domain)" "${plist}" || rc=$?
    (( rc == 0 )) && return 0
    (( n >= tries )) && return "${rc}"
    sleep "${LLMCTL_LAUNCHD_RETRY_SLEEP:-1}"
    n=$((n+1))
  done
}

decide_service_disable() {
  _svc_launchctl bootout "$(_svc_domain)/${DECIDE_GATEWAY_LABEL}" || true
  if [[ "${LLMCTL_DRY_RUN}" == "1" ]]; then   # a dry run leaves the real agent alone (C-12)
    printf '[dry-run] rm -f %s\n' "$(_decide_gateway_plist_path)"
  else
    rm -f "$(_decide_gateway_plist_path)"
  fi
  portreg_unregister decide-gateway
  portreg_release gateway
  info "removed ${DECIDE_GATEWAY_LABEL}"
}

decide_service_main_pid() {
  local pid=""
  [[ "${LLMCTL_DRY_RUN:-0}" == "1" ]] && return 0
  pid="$(launchctl print "$(_svc_domain)/${DECIDE_GATEWAY_LABEL}" 2>/dev/null | awk '/^[[:space:]]*pid = /{print $3; exit}')"
  [[ "${pid}" =~ ^[0-9]+$ && "${pid}" -gt 1 ]] && printf '%s\n' "${pid}"
  return 0
}

decide_service_status() {
  if [[ "${LLMCTL_DRY_RUN}" == "1" ]]; then
    printf '[dry-run] launchctl print %s\n' "$(_svc_domain)/${DECIDE_GATEWAY_LABEL}"
    return 0
  fi
  launchctl print "$(_svc_domain)/${DECIDE_GATEWAY_LABEL}" || true
}
