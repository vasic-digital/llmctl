#!/usr/bin/env bash
# service_linux.sh - systemd --user backend for llmctl services.
#
# Installs two template units:
#   llmctl-llama@.service    - runs llama-server for a GGUF profile
#   llmctl-colibri@.service  - runs the colibri `coli serve` launcher
# Each instance gets its launch parameters from an EnvironmentFile at
# $LLMCTL_SERVICES_DIR/<profile>.env written by svc_write_env().
#
# LLMCTL_DRY_RUN=1: unit/env files are still written (so their content is
# testable), but every systemctl/loginctl invocation is printed instead of
# executed.
set -euo pipefail

_svl_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_svl_dir}/common.sh"
# shellcheck source=hardware.sh
source "${_svl_dir}/hardware.sh"

svc_backend_name() { echo "systemd-user"; }

svc_unit_dir() {
  echo "${LLMCTL_UNIT_DIR:-${XDG_CONFIG_HOME}/systemd/user}"
}

_svc_sys() {
  if [[ "${LLMCTL_DRY_RUN}" == "1" ]]; then
    printf '[dry-run] systemctl --user %s\n' "$*"
    return 0
  fi
  systemctl --user "$@"
}

# --- unit installation -------------------------------------------------------
svc_install() {
  local unit_dir; unit_dir="$(svc_unit_dir)"
  ensure_dir "${unit_dir}"
  ensure_state_dirs

  # Memory limits from a live probe (fixtures allowed for tests).
  local total memmax memhigh
  total="$(hw_probe_json | json_stdin 'd["memory"]["total_mb"]')" \
    || die "cannot probe memory for service limits"
  memmax=$(( total - 4096 ))
  (( memmax > 0 )) || memmax=$(( total * 9 / 10 ))
  memhigh=$(( memmax * 9 / 10 ))

  cat > "${unit_dir}/llmctl-llama@.service" <<EOF
[Unit]
Description=llmctl llama.cpp inference server (profile %i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${LLMCTL_SERVICES_DIR}/%i.env
ExecStart=\${LLMCTL_EXEC} \${LLMCTL_ARGS}
Restart=always
RestartSec=5
StartLimitIntervalSec=0
MemoryHigh=${memhigh}M
MemoryMax=${memmax}M
StandardOutput=append:${LLMCTL_LOG_DIR}/%i.log
StandardError=append:${LLMCTL_LOG_DIR}/%i.log

[Install]
WantedBy=default.target
EOF

  cat > "${unit_dir}/llmctl-colibri@.service" <<EOF
[Unit]
Description=llmctl colibri inference server (profile %i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${LLMCTL_SERVICES_DIR}/%i.env
ExecStart=\${LLMCTL_EXEC} \${LLMCTL_ARGS}
Restart=always
RestartSec=5
StartLimitIntervalSec=0
MemoryHigh=${memhigh}M
MemoryMax=${memmax}M
StandardOutput=append:${LLMCTL_LOG_DIR}/%i.log
StandardError=append:${LLMCTL_LOG_DIR}/%i.log

[Install]
WantedBy=default.target
EOF
  info "installed systemd user units into ${unit_dir} (MemoryHigh=${memhigh}M MemoryMax=${memmax}M)"

  _svc_sys daemon-reload

  # Linger lets user services survive logout.
  if [[ "${LLMCTL_DRY_RUN}" == "1" ]]; then
    printf '[dry-run] loginctl enable-linger %s\n' "${USER:-$(id -un)}"
  elif have_cmd loginctl; then
    if ! loginctl enable-linger "${USER:-$(id -un)}" 2>/dev/null; then
      warn "loginctl enable-linger failed; retry with: sudo loginctl enable-linger ${USER:-$(id -un)}"
    fi
  else
    warn "loginctl not found; user services will stop at logout"
  fi
}

# --- per-profile environment -------------------------------------------------
# svc_write_env <profile> <engine> <exec> <args...>
svc_write_env() {
  local profile="$1" engine="$2" exec_bin="$3"; shift 3
  ensure_dir "${LLMCTL_SERVICES_DIR}"
  local env_file="${LLMCTL_SERVICES_DIR}/${profile}.env"
  {
    printf 'LLMCTL_PROFILE=%q\n' "${profile}"
    printf 'LLMCTL_ENGINE=%q\n' "${engine}"
    printf 'LLMCTL_EXEC=%q\n' "${exec_bin}"
    printf 'LLMCTL_ARGS='
    printf '%q ' "$@"
    printf '\n'
  } > "${env_file}"
  log "wrote ${env_file}"
}

_svc_unit_for() {
  local profile="$1"
  local engine=""
  [[ -f "${LLMCTL_SERVICES_DIR}/${profile}.env" ]] && \
    engine="$(sed -n 's/^LLMCTL_ENGINE=//p' "${LLMCTL_SERVICES_DIR}/${profile}.env" | tr -d "'")"
  engine="${engine:-llama}"
  echo "llmctl-${engine}@${profile}.service"
}

# --- lifecycle ---------------------------------------------------------------
svc_enable() {
  local unit; unit="$(_svc_unit_for "$1")"
  _svc_sys enable "${unit}"
  _svc_sys start "${unit}"
}

svc_disable() {
  local unit; unit="$(_svc_unit_for "$1")"
  _svc_sys stop "${unit}" || true
  _svc_sys disable "${unit}" || true
  [[ "${LLMCTL_DRY_RUN}" == "1" ]] || rm -f "${LLMCTL_SERVICES_DIR}/$1.env"
}

svc_start()   { _svc_sys start "$(_svc_unit_for "$1")"; }
svc_stop()    { _svc_sys stop  "$(_svc_unit_for "$1")"; }
svc_restart() { _svc_sys restart "$(_svc_unit_for "$1")"; }

svc_status() {
  local unit; unit="$(_svc_unit_for "$1")"
  if [[ "${LLMCTL_DRY_RUN}" == "1" ]]; then
    printf '[dry-run] systemctl --user status %s\n' "${unit}"
    return 0
  fi
  systemctl --user --no-pager status "${unit}" || true
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
    # In dry-run mode the runtime reservation record is the source of truth.
    [[ -f "${LLMCTL_RUNTIME_DIR}/${profile}.run" ]]
    return
  fi
  systemctl --user is-active --quiet "$(_svc_unit_for "${profile}")"
}

# Profiles with an env file (i.e. known to llmctl).
svc_known_profiles() {
  local f
  for f in "${LLMCTL_SERVICES_DIR}"/*.env; do
    [[ -e "${f}" ]] || continue
    basename "${f}" .env
  done
}
