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

# --- per-tenant isolation (Phase 11 US9, Clarification 18/FR-049) -----------
# LLMCTL_TENANT_ID: optional. Unset (the default) is the single-host path,
# completely unchanged from every prior release - _svc_instance_key returns
# the bare profile name, byte-identical to this file's original behavior.
#
# When set, every profile-keyed artifact (env file, unit instance) is
# TENANT-QUALIFIED (<tenant>--<profile>), so two tenants registering the
# SAME profile NAME never share an env file, a systemd unit instance, or
# (via _svc_ensure_tenant_slice_dropin below) a cgroup.
#
# Investigated real mechanism (Constitution §11.4.102 - root-caused before
# implementing, not assumed): internal/isolation/cgroup.go's WrapCommand
# (T072) prepends `systemd-run --user --scope --slice=...` to an arbitrary
# COMMAND, which is the correct mechanism for a process llmctld spawns
# directly. It is NOT the correct mechanism for THIS project's actual
# service architecture: `bin/llmctl start <profile>` merely invokes
# `systemctl --user start llmctl-<engine>@<profile>.service`, and systemd
# then manages that unit as an INDEPENDENT process under its own user
# manager - the unit's cgroup placement is resolved from the UNIT's own
# `Slice=` property, never inherited from whatever short-lived process
# happened to call `systemctl --user start`. Wrapping the CLI invocation
# in a systemd-run scope would isolate only the CLI call itself (which
# exits in milliseconds) and would NOT affect where the real, long-running
# llama-server/colibri process's cgroup lands - a bluff this investigation
# exists to prevent. The real, working mechanism is a per-instance systemd
# drop-in setting `Slice=llmctl-tenant-<id>.slice` directly on the unit.
_svc_validate_tenant_id() {
  local id="$1"
  # Mirrors internal/isolation/cgroup.go's Go-side tenantIDPattern
  # exactly (`^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$`) plus its second,
  # independent ".." rejection - an independent code review (2026-09-15)
  # found the PRIOR bash pattern (`^[A-Za-z0-9_-]+$`) genuinely differed
  # from the Go one (no dots permitted, no first-character-alnum
  # requirement, no length cap), causing a real user-visible
  # inconsistency: the SAME tenant ID could succeed against one
  # language's validated routes and fail against the other's, despite
  # both languages' comments claiming to enforce "the same allow-list".
  [[ "${id}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] || die "invalid LLMCTL_TENANT_ID: '${id}' (must match ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\$ - the same allow-list internal/isolation/cgroup.go's Go-side tenantIDPattern enforces, T072)"
  # Defense in depth beyond the charset check above, mirroring Go's
  # validateTenantID: ".." alone matches the charset (dots are a
  # permitted character for ordinary tenant IDs like "tenant.3"), but an
  # id containing ".." ANYWHERE is exactly the path-traversal component
  # a filesystem join would otherwise resolve upward through.
  [[ "${id}" != *..* ]] || die "invalid LLMCTL_TENANT_ID: '${id}' (must not contain \"..\")"
}

_svc_instance_key() {
  local profile="$1"
  if [[ -n "${LLMCTL_TENANT_ID:-}" ]]; then
    _svc_validate_tenant_id "${LLMCTL_TENANT_ID}"
    echo "${LLMCTL_TENANT_ID}--${profile}"
  else
    echo "${profile}"
  fi
}

# _svc_ensure_tenant_slice_dropin <unit> - idempotently ensures unit's real
# systemd drop-in carries Slice=llmctl-tenant-<id>.slice. A no-op when
# LLMCTL_TENANT_ID is unset. Writing the drop-in file is plain filesystem
# I/O (safe to do for real even under LLMCTL_DRY_RUN=1, exactly like
# svc_install's own unit-file writes already are) - only the subsequent
# daemon-reload is dry-run-gated via _svc_sys.
_svc_ensure_tenant_slice_dropin() {
  local unit="$1"
  [[ -n "${LLMCTL_TENANT_ID:-}" ]] || return 0
  _svc_validate_tenant_id "${LLMCTL_TENANT_ID}"
  local dropin_dir="$(svc_unit_dir)/${unit}.d"
  local dropin_file="${dropin_dir}/tenant-slice.conf"
  local want
  want="$(printf '[Service]\nSlice=llmctl-tenant-%s.slice\n' "${LLMCTL_TENANT_ID}")"
  if [[ -f "${dropin_file}" ]] && [[ "$(cat "${dropin_file}")" == "${want}" ]]; then
    return 0
  fi
  ensure_dir "${dropin_dir}"
  printf '%s' "${want}" > "${dropin_file}"
  _svc_sys daemon-reload
}

# --- unit installation -------------------------------------------------------
svc_install() {
  local unit_dir; unit_dir="$(svc_unit_dir)"
  ensure_dir "${unit_dir}"
  ensure_state_dirs

  # Memory limits from a live probe (fixtures allowed for tests). Operator
  # decision (2026-09-15): served profiles carry NO artificial ceiling below
  # the physical hardware - maximal performance and resources, not a
  # percentage/headroom-reduced cap. MemoryMax is set to the FULL probed
  # total RAM (not total-minus-headroom, not a 60%-style fraction), and
  # MemoryHigh equals MemoryMax so there is no soft-throttle zone below it.
  # The directives themselves stay present (satisfying the OS-level
  # protection half of FR-015/Constitution §12.6 - a hard cgroup ceiling at
  # the machine's own physical limit still contains a runaway profile to a
  # clean, cgroup-level OOM-kill of just that one service rather than an
  # uncontrolled whole-host kernel OOM event) - only the ARTIFICIAL
  # reduction below that hardware ceiling is removed.
  local total memmax memhigh
  total="$(hw_probe_json | json_stdin 'd["memory"]["total_mb"]')" \
    || die "cannot probe memory for service limits"
  memmax="${total}"
  memhigh="${total}"

  cat > "${unit_dir}/llmctl-llama@.service" <<EOF
[Unit]
Description=llmctl llama.cpp inference server (profile %i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${LLMCTL_SERVICES_DIR}/%i.env
# Root-caused 2026-09-17 (real repro on this host's systemd 259, not
# guessed): systemd's \$VAR/\${VAR} expansion in ExecStart= applies ONLY to
# the argument list, NEVER to the executable path itself (word 0) - it
# needs that path resolvable at unit-parse time. A bare
# "ExecStart=\${LLMCTL_EXEC} \${LLMCTL_ARGS}" therefore made systemd try to
# literally exec a program named "\${LLMCTL_EXEC}", which always fails
# with status=203/EXEC ("Unable to locate executable '\${LLMCTL_EXEC}'")
# regardless of profile, host, or how correct the .env file's real values
# are - reproduced directly with a minimal two-line test unit before this
# fix, and confirmed the argument-position case (\${VAR} after a literal
# executable path) DOES expand correctly. The fix: exec through a shell,
# whose OWN path is a fixed, parse-time-resolvable literal, and let that
# shell resolve the dynamic executable from its inherited environment at
# RUN time - proven with the exact real form below before landing it here.
ExecStart=/bin/bash -c 'exec "\$LLMCTL_EXEC" \$LLMCTL_ARGS'
Restart=always
RestartSec=5
StartLimitBurst=5
StartLimitIntervalSec=60
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
# See the matching note in the llmctl-llama@.service template above -
# same systemd ExecStart= executable-path-expansion limitation, same fix.
ExecStart=/bin/bash -c 'exec "\$LLMCTL_EXEC" \$LLMCTL_ARGS'
Restart=always
RestartSec=5
StartLimitBurst=5
StartLimitIntervalSec=60
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
#
# LD_LIBRARY_PATH (llama engine only, root-caused 2026-09-17): a freshly
# `llmctl build llama`-built llama-server links against libggml.so.0/
# libggml-base.so.0/libggml-cpu.so.0 alongside it in submodules/llama.cpp/
# build/bin/, but the built libllama.so.0 sets no RPATH covering those
# sibling libs - so when a package with a COLLIDING SONAME is already
# installed system-wide (confirmed on this host: an unrelated
# /usr/lib/x86_64-linux-gnu/libggml.so.0 from a distro/other-tool package,
# missing symbols the fresh build exports, e.g.
# ggml_flash_attn_ext_set_n_kv_max), the dynamic linker silently prefers
# the STALE system copy over the correct sibling in the exec's own
# directory, and llama-server dies immediately with a symbol-lookup
# error - reproduced directly via `ldd`, confirmed fixed by prepending
# the exec's own directory to LD_LIBRARY_PATH (verified: a real /health
# 200 in ~4s with the fix, a hard crash within milliseconds without it).
# Derived from exec_bin's own directory (never a hardcoded path per
# CONST-045/§11.4.111) so a custom LLMCTL_LLAMA_SERVER override is
# honored automatically; colibri's engine is a single self-contained gcc
# binary with no equivalent shared-lib dependency, so this is scoped to
# engine=llama only, never applied unconditionally.
svc_write_env() {
  local profile="$1" engine="$2" exec_bin="$3"; shift 3
  ensure_dir "${LLMCTL_SERVICES_DIR}"
  local instance; instance="$(_svc_instance_key "${profile}")"
  local env_file="${LLMCTL_SERVICES_DIR}/${instance}.env"
  {
    printf 'LLMCTL_PROFILE=%q\n' "${profile}"
    printf 'LLMCTL_ENGINE=%q\n' "${engine}"
    printf 'LLMCTL_EXEC=%q\n' "${exec_bin}"
    if [[ "${engine}" == "llama" ]]; then
      local exec_dir; exec_dir="$(cd "$(dirname "${exec_bin}")" && pwd)"
      printf 'LD_LIBRARY_PATH=%q\n' "${exec_dir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
    fi
    printf 'LLMCTL_ARGS='
    printf '%q ' "$@"
    printf '\n'
  } > "${env_file}"
  log "wrote ${env_file}"
}

_svc_unit_for() {
  local profile="$1"
  local instance; instance="$(_svc_instance_key "${profile}")"
  local engine=""
  [[ -f "${LLMCTL_SERVICES_DIR}/${instance}.env" ]] && \
    engine="$(sed -n 's/^LLMCTL_ENGINE=//p' "${LLMCTL_SERVICES_DIR}/${instance}.env" | tr -d "'")"
  engine="${engine:-llama}"
  echo "llmctl-${engine}@${instance}.service"
}

# --- lifecycle ---------------------------------------------------------------
svc_enable() {
  local unit; unit="$(_svc_unit_for "$1")"
  _svc_ensure_tenant_slice_dropin "${unit}"
  _svc_sys enable "${unit}"
  _svc_sys start "${unit}"
}

svc_disable() {
  local unit; unit="$(_svc_unit_for "$1")"
  _svc_sys stop "${unit}" || true
  _svc_sys disable "${unit}" || true
  [[ "${LLMCTL_DRY_RUN}" == "1" ]] || rm -f "${LLMCTL_SERVICES_DIR}/$(_svc_instance_key "$1").env"
}

svc_start()   { local unit; unit="$(_svc_unit_for "$1")"; _svc_ensure_tenant_slice_dropin "${unit}"; _svc_sys start "${unit}"; }
svc_stop()    { _svc_sys stop  "$(_svc_unit_for "$1")"; }
svc_restart() { local unit; unit="$(_svc_unit_for "$1")"; _svc_ensure_tenant_slice_dropin "${unit}"; _svc_sys restart "${unit}"; }

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
  local instance; instance="$(_svc_instance_key "${profile}")"
  local logf="${LLMCTL_LOG_DIR}/${instance}.log"
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

# svc_is_failed <profile> - true once the unit has exceeded its restart
# bound (StartLimitBurst within StartLimitIntervalSec, see svc_install) and
# systemd has given up restarting it (Restart=always never fires again until
# `systemctl --user reset-failed`). This is the crash-loop signal FR-044
# expects `llmctl status` to surface.
svc_is_failed() {
  local profile="$1"
  if [[ "${LLMCTL_DRY_RUN}" == "1" ]]; then
    # Dry-run marker file, same testability convention as svc_is_active's
    # dry-run branch above (no real systemd session needed to test the
    # status-reporting logic that consumes this).
    [[ -f "${LLMCTL_RUNTIME_DIR}/${profile}.failed" ]]
    return
  fi
  systemctl --user is-failed --quiet "$(_svc_unit_for "${profile}")"
}

# Profiles with an env file (i.e. known to llmctl).
svc_known_profiles() {
  local f
  for f in "${LLMCTL_SERVICES_DIR}"/*.env; do
    [[ -e "${f}" ]] || continue
    basename "${f}" .env
  done
}
