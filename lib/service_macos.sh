#!/usr/bin/env bash
# service_macos.sh - launchd LaunchAgent backend for llmctl services.
#
# Each enabled profile gets ~/Library/LaunchAgents/com.llmctl.<profile>.plist
# with KeepAlive + ThrottleInterval and append logs under $LLMCTL_LOG_DIR.
#
# LLMCTL_DRY_RUN=1: plist/env files are still written (so their content is
# testable), but every launchctl invocation is printed instead of executed.
set -euo pipefail

_svm_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_svm_dir}/common.sh"

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

# plist-escape a single argument into an <string> element.
_svc_plist_str() {
  local s="$1"
  s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"
  printf '    <string>%s</string>\n' "${s}"
}

# svc_write_env <profile> <engine> <exec> <args...>
# Keeps the same env record as the Linux backend (source of truth for the
# scheduler) AND renders the LaunchAgent plist.
svc_write_env() {
  local profile="$1" engine="$2" exec_bin="$3"; shift 3
  ensure_dir "${LLMCTL_SERVICES_DIR}"
  ensure_dir "$(svc_plist_dir)"

  local env_file="${LLMCTL_SERVICES_DIR}/${profile}.env"
  {
    printf 'LLMCTL_PROFILE=%q\n' "${profile}"
    printf 'LLMCTL_ENGINE=%q\n' "${engine}"
    printf 'LLMCTL_EXEC=%q\n' "${exec_bin}"
    printf 'LLMCTL_ARGS='
    printf '%q ' "$@"
    printf '\n'
  } > "${env_file}"

  local plist; plist="$(_svc_plist_path "${profile}")"
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
    _svc_plist_str "${exec_bin}"
    local a
    for a in "$@"; do _svc_plist_str "${a}"; done
    cat <<PLISTTAIL
  </array>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>5</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LLMCTL_LOG_DIR}/${profile}.log</string>
  <key>StandardErrorPath</key>
  <string>${LLMCTL_LOG_DIR}/${profile}.log</string>
  <key>WorkingDirectory</key>
  <string>${LLMCTL_ROOT}</string>
</dict>
</plist>
PLISTTAIL
  } > "${plist}"
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

svc_start()   { _svc_launchctl kickstart -k "$(_svc_domain)/$(_svc_label "$1")"; }
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

svc_known_profiles() {
  local f
  for f in "${LLMCTL_SERVICES_DIR}"/*.env; do
    [[ -e "${f}" ]] || continue
    basename "${f}" .env
  done
}
