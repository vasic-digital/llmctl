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
# shellcheck source=portreg.sh
source "${_svl_dir}/portreg.sh"

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
  # C3-08: registry/service row names are "<tenant>--<profile>"; the FIRST "--" is the separator. A tenant id holding
  # "--" or ending in "-" would make "acme---small" / "acme--eu--small" belong to two tenants at once (and a tenant-
  # scoped doctor diff would leak across them). Stricter than the Go-side pattern for this one reason; llmctld's
  # internal/isolation applies the same two rules.
  [[ "${id}" != *--* && "${id}" != *- ]] || die "invalid LLMCTL_TENANT_ID: '${id}' (must not contain \"--\" or end with \"-\": row names are <tenant>--<profile>)"
}

_svc_instance_key() {
  local profile="$1"
  # C3-08: "--" is the tenant separator, so no profile name may hold it (a non-tenant profile "qwen--7b" would be
  # indistinguishable from tenant "qwen" / profile "7b" and a non-tenant doctor diff would drop its row).
  [[ "${profile}" != *--* ]] || die "invalid profile name '${profile}' (must not contain \"--\": it is the <tenant>--<profile> separator)"
  if [[ -n "${LLMCTL_TENANT_ID:-}" ]]; then
    _svc_validate_tenant_id "${LLMCTL_TENANT_ID}"
    [[ "${profile}" != -* ]] || die "invalid profile name '${profile}' for tenant row names (must not start with \"-\": row names are <tenant>--<profile>)"
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
  local dropin_dir
  dropin_dir="$(svc_unit_dir)/${unit}.d"
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

# --- unit bodies -------------------------------------------------------------
# Hardening directives (FR-083). ONLY directives verified to take effect in the
# systemd --user manager on the reference host are emitted; tests/
# test_unit_hardening.sh re-proves each one against a live transient unit
# (a probe that observes the effect, not a parse of the file) and SKIPs
# honestly where no user manager is reachable. Measured on systemd 259:
#   effective   NoNewPrivileges, ProtectSystem=full, UMask, and the seccomp
#               group (RestrictAddressFamilies, RestrictSUIDSGID,
#               LockPersonality, RestrictRealtime, SystemCallArchitectures)
#   NOT honoured by the user manager here (so deliberately NOT written, a
#   claim that is not true would be worse than no claim): PrivateTmp,
#   ProtectHome, ProtectControlGroups, ProtectProc, PrivateDevices,
#   ProtectClock, CapabilityBoundingSet.
# "basic" is applied to chat engines (their GPU/CUDA stacks are unrestricted
# beyond the two always-safe directives); "strict" to decision components,
# which only need TCP/unix sockets and the file system.
_svc_hardening() {
  printf 'NoNewPrivileges=yes\nProtectSystem=full\n'
  if [[ "${1:-basic}" == "strict" ]]; then
    printf 'UMask=0077\nRestrictAddressFamilies=AF_UNIX AF_INET AF_INET6\n'
    printf 'RestrictSUIDSGID=yes\nLockPersonality=yes\nRestrictRealtime=yes\n'
    printf 'SystemCallArchitectures=native\n'
  fi
}

# _svc_decide_bin_env_line -> "Environment=LLMCTL_DECIDE_BIN=<path>" when the
# registry binary resolves now (explicit override or build/llmctl-decide), else
# a comment (the hooks then fall back to the same search at run time).
_svc_decide_bin_env_line() {
  local b
  if b="$(portreg_bin 2>/dev/null)"; then _svc_env LLMCTL_DECIDE_BIN "${b}"
  else printf '# LLMCTL_DECIDE_BIN: registry binary not built at install time (llmctl build decide)'; fi
}

# _svc_q <string> -> the string as ONE systemd word: double-quoted, with systemd's C-style escapes
# (\\ and \") and every `%` doubled (systemd expands %-specifiers in unit values, and splits an
# unquoted value on whitespace). bash's printf %q is NOT systemd quoting. (C-18)
_svc_q() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//%/%%}"
  printf '"%s"' "${s}"
}

# _svc_qx <string> -> _svc_q for a word of an ExecStart*= LINE: systemd also expands $VAR / ${VAR} there, even
# inside double quotes, so a literal `$` must be written `$$` (systemd.service(5), "Command lines"). NOT for
# Environment= (see _svc_env), where the value is taken literally. (C2-12)
_svc_qx() { local q; q="$(_svc_q "$1")"; printf '%s' "${q//\$/\$\$}"; }

# _svc_env <KEY> <value> -> an `Environment="KEY=value"` line safe for paths with spaces or `%`.
_svc_env() { printf 'Environment=%s' "$(_svc_q "$1=$2")"; }

# _svc_pct <string> -> the string with every `%` doubled (for values that are one whole word
# already, e.g. EnvironmentFile= / StandardOutput=append: paths).
_svc_pct() { printf '%s' "${1//%/%%}"; }

# _svc_hook_cmd <args...> -> the ExecStart*-ready command line of svc_hook.sh (the script path is
# one quoted systemd word; the args are systemd specifiers such as %i and stay as given).
_svc_hook_cmd() { printf '/bin/bash %s %s' "$(_svc_qx "${_svl_dir}/svc_hook.sh")" "$*"; }

# --- resource policy (fix/bounded-restart-and-pressure-gates, root cause 2) ----------------------------------------
# The 2026-09-15 "no ceiling below physical RAM" policy let one runaway profile take the whole machine before its cgroup
# limit applied (MemoryHigh==MemoryMax==total also leaves no throttle zone). New policy:
#   * every PROFILE gets its own drop-in (written next to its env record, _svc_write_mem_dropin): MemoryHigh = 1.25x and
#     MemoryMax = 1.5x of the plan footprint (ram_mb), floor 1 GiB, always below 90% of total RAM;
#   * the TEMPLATE keeps a backstop below total (High 70%, Max 85%) for units whose drop-in is missing;
#   * MemorySwapMax=0 (a model that swaps is a stalled host, not a slow model), Nice/IOWeight/CPUWeight so the engine
#     yields to the desktop and the agent fleet, OOMScoreAdjust=500 (kernel picks the engine first), a bounded stop
#     (TimeoutStopSec=20) and start (TimeoutStartSec=600 covers the ExecStartPre gate wait (120 s)).
#   * ManagedOOMPreference=avoid: the engine is already bounded by its own MemoryMax, so systemd-oomd (which acts per
#     cgroup on PSI, see docs/host-safety.md) should pick other victims first. UNKNOWN: whether the user manager
#     honours the xattr for an unprivileged unit; the directive is harmless when ignored.
_svc_resource_directives() {
  cat <<'EOF'
MemorySwapMax=0
Nice=10
IOWeight=50
CPUWeight=50
OOMScoreAdjust=500
ManagedOOMPreference=avoid
TimeoutStopSec=20
KillMode=control-group
TimeoutStartSec=600
EOF
}

# _svc_template_caps <total-MiB> -> "<high> <max>" backstop for a template unit (always below total RAM).
_svc_template_caps() { echo "$(( $1 * 70 / 100 )) $(( $1 * 85 / 100 ))"; }

# _svc_gateway_caps <total-MiB> -> "<high> <max>": the gateway is a small Go process; 20%/25% of RAM, capped 3/4 GiB.
_svc_gateway_caps() {
  local h=$(( $1 * 20 / 100 )) m=$(( $1 * 25 / 100 ))
  (( h > 3072 )) && h=3072; (( m > 4096 )) && m=4096
  echo "${h} ${m}"
}

# _svc_profile_caps <footprint-MiB> <total-MiB> -> "<high> <max>" (1.25x / 1.5x, floor 1 GiB, max < 90% of total).
# For a GPU-mode profile whose provenance is NOT "measured" the plan's 2048 MiB RAM is a placeholder, not a measurement: the
# CUDA context, pinned staging and compute buffers (--ubatch-size 4096) live in host memory too, and a cgroup OOM kill of a
# HEALTHY model is final (RestartPreventExitStatus=SIGKILL). Such a profile gets a floor of High 5120 / Max 6144 MiB
# (about 3x the placeholder; still below 90% of RAM and below the app.slice ceiling of 80%). Tighten it by MEASURING:
# after the first live run read VmHWM of the engine pid (llmctl keeps it in the QA evidence) and record it in the catalog
# (memory.gpu status "measured"), which switches the profile back to the 1.25x / 1.5x rule.
# _svc_profile_caps <footprint-MiB> <total-MiB> [<mode> <provenance>]
_svc_profile_caps() {
  local fp="$1" total="$2" mode="${3:-}" prov="${4:-}" h m lim=$(( $2 * 90 / 100 ))
  h=$(( fp * 125 / 100 )); m=$(( fp * 150 / 100 ))
  (( h < 1024 )) && h=1024; (( m < 1280 )) && m=1280
  if [[ "${mode}" == gpu && "${prov}" != measured ]]; then
    (( h < 5120 )) && h=5120; (( m < 6144 )) && m=6144
  fi
  (( m > lim )) && m="${lim}"; (( h >= m )) && h=$(( m * 5 / 6 ))
  echo "${h} ${m}"
}

# _svc_rm_stale_layout <dropin-dir> - an earlier (never released) layout wrote 10-memory.conf, which sorts AFTER the operator's
# 10-hostsafety.conf and would override it. Removed only when it carries llmctl's own header.
_svc_rm_stale_layout() {
  local f="$1/10-memory.conf"
  [[ -f "${f}" ]] && head -1 "${f}" | grep -q '^# written by llmctl' && rm -f "${f}"
  return 0
}

# _svc_rm_mem_dropin <instance> <engine> - removes llmctl's OWN 05-memory.conf (never any other drop-in) and the
# directory when that leaves it empty.
_svc_rm_mem_dropin() {
  local d; d="$(svc_unit_dir)/llmctl-$2@$1.service.d"
  rm -f "${d}/05-memory.conf"
  _svc_rm_stale_layout "${d}"
  rmdir "${d}" 2>/dev/null || true
}

# _svc_write_mem_dropin <profile> <engine> - per-profile MemoryHigh/MemoryMax drop-in sized from the plan footprint.
# Plain file I/O (also under LLMCTL_DRY_RUN=1, like svc_install). Silently skipped when the planner is not loaded
# (the template backstop then applies) - never fatal.
_svc_write_mem_dropin() {
  local profile="$1" engine="$2" instance dir fp total caps
  valid_id "${profile}" || return 0      # security: allow-listed BEFORE any use; the name is data below, never code
  instance="$(_svc_instance_key "${profile}")"
  # a stale llmctl-written 10-memory.conf sorts AFTER the operator's 10-hostsafety.conf and would override it: it goes
  # away on EVERY path of this function, including the warn-and-return ones below (review L6)
  _svc_rm_stale_layout "$(svc_unit_dir)/llmctl-${engine}@${instance}.service.d"
  if ! declare -F catalog_plan_json >/dev/null 2>&1; then
    warn "no per-profile memory cap written for ${profile} (planner not loaded here); the template backstop applies - run: llmctl install"
    return 0
  fi
  # a scaled instance key (decide.2) has no catalog entry of its own: look its cap up under the base profile - but only
  # when that base IS a catalog profile (same semantics as _sched_base_profile in lib/scheduler.sh)
  local lookup="${profile}" _base=""
  [[ "${profile}" =~ ^(.+)\.[0-9]+$ ]] && _base="${BASH_REMATCH[1]}"      # copied: catalog_exists may clobber BASH_REMATCH
  if [[ -n "${_base}" ]] && ! catalog_exists "${profile}" 2>/dev/null; then
    if catalog_exists "${_base}" 2>/dev/null; then
      lookup="${_base}"
    else
      warn "no per-profile memory cap written for ${profile}: its base '${_base}' is not a catalog profile; the template backstop applies"
      return 0
    fi
  fi
  valid_id "${lookup}" || return 0
  fp="$(hw_probe_json | catalog_plan_json 2>/dev/null | json_stdin 'd["profiles"][argv[0]]["ram_mb"]' "${lookup}" 2>/dev/null)" || fp=""
  total="$(hw_probe_json | json_stdin 'd["memory"]["total_mb"]' 2>/dev/null)" || total=""
  local mp mode prov
  mp="$(hw_probe_json | catalog_plan_json 2>/dev/null | json_stdin 'd["profiles"][argv[0]]["mode"] + " " + str(d["profiles"][argv[0]].get("vram_provenance"))' "${lookup}" 2>/dev/null)" || mp=""
  mode="${mp%% *}"; prov="${mp#* }"
  if [[ ! "${fp}" =~ ^[0-9]+$ || ! "${total}" =~ ^[0-9]+$ ]]; then
    warn "no per-profile memory cap written for ${profile} (footprint or total RAM unknown); the template backstop applies"
    return 0
  fi
  # an engine change must not leave the other engines' drop-in behind (only llmctl's own 05-memory.conf is ever removed)
  local other
  for other in llama colibri onnx; do
    [[ "${other}" == "${engine}" ]] || _svc_rm_mem_dropin "${instance}" "${other}"
  done
  caps="$(_svc_profile_caps "${fp}" "${total}" "${mode}" "${prov}")"
  dir="$(svc_unit_dir)/llmctl-${engine}@${instance}.service.d"
  _svc_rm_stale_layout "${dir}"
  # Everything below runs under umask 077: the env record holds key-file paths and LLMCTL_REG_TOKEN (never wider than
  # 0600, also for the temp file of the rewrite - no `sed -i`), and the drop-in follows the same rule.
  (
    umask 077
    ensure_dir "${dir}"
    # the start gate (svc_hook.sh gate) needs the footprint at restart time: record it in the env record
    local envf="${LLMCTL_SERVICES_DIR}/${instance}.env" tmp
    if [[ -f "${envf}" ]]; then
      if ! tmp="$(mktemp "${envf}.XXXXXX")"; then
        warn "cannot record the footprint for ${profile} (mktemp failed in $(dirname "${envf}")): the start gate falls back to the 4 GiB reserve only"
      else
      { grep -v '^LLMCTL_FOOTPRINT_MB=' "${envf}" || true; printf 'LLMCTL_FOOTPRINT_MB=%s\n' "${fp}"; } > "${tmp}"
      chmod 600 "${tmp}"; mv -f "${tmp}" "${envf}"
      fi
    fi
    printf '# written by llmctl (profile %s): plan footprint %s MiB, mode %s, provenance %s -> High 1.25x, Max 1.5x (floors High 1024 / Max 1280 MiB; gpu mode not measured: High >= 5120 / Max >= 6144; always < 90%% of RAM)\n[Service]\nMemoryHigh=%sM\nMemoryMax=%sM\n' \
      "${profile}" "${fp}" "${mode}" "${prov}" "${caps%% *}" "${caps##* }" > "${dir}/05-memory.conf"
  )
}

# _svc_portcheck_cmd <instance-specifier> -> the ExecCondition= command line. systemd treats ExecCondition exit codes 1-254 as
# "skip the unit quietly", so a crashing or missing hook (exit 1 / 127) would silently skip every start. The wrapper maps:
# hook exit 0 -> run, 98 (port busy) -> skip, anything else -> 255 (the unit FAILS, loudly).
_svc_portcheck_cmd() {
  printf "/bin/bash -c 'bash \"\$\$0\" portcheck \"\$\$1\"; rc=\$\$?; case \$\$rc in 0|98) exit \$\$rc;; *) exit 255;; esac' %s %s" "$(_svc_qx "${_svl_dir}/svc_hook.sh")" "$1"
}

# _svc_engine_unit_body <description> <basic|strict> <memhigh-MiB> <memmax-MiB>
_svc_engine_unit_body() {
  local desc="$1" level="$2" memhigh="$3" memmax="$4"
  cat <<EOF
[Unit]
Description=${desc}
After=network-online.target
Wants=network-online.target
# Restart bounds belong in [Unit]: systemd ignores StartLimitIntervalSec= in
# [Service] ("Unknown key ... ignoring", reproduced with systemd-analyze
# --user verify on systemd 259), which silently left the interval at its
# default. Restart=on-failure never fires again once the burst is exhausted
# (until reset-failed) - the crash-loop signal FR-044 surfaces in status. 3 starts / 900 s: a real cycle (model load +
# stop) exceeds the old 60 s window, so 5/60 could never trip and OOM kills were retried forever.
StartLimitBurst=3
StartLimitIntervalSec=900

[Service]
Type=simple
# The hooks below find the state/registry/log locations through these (the
# manager's own environment would silently differ from the installing shell's
# when LLMCTL_STATE_DIR & co. are overridden - registry and units must agree).
$(_svc_env LLMCTL_ROOT "${LLMCTL_ROOT}")
$(_svc_env LLMCTL_STATE_DIR "${LLMCTL_STATE_DIR}")
$(_svc_env LLMCTL_LOG_DIR "${LLMCTL_LOG_DIR}")
$(_svc_env LLMCTL_SERVICES_DIR "${LLMCTL_SERVICES_DIR}")
$(_svc_decide_bin_env_line)
EnvironmentFile=$(_svc_pct "${LLMCTL_SERVICES_DIR}")/%i.env
# Root-caused 2026-09-17 (real repro on this host's systemd 259, not
# guessed): systemd's \$VAR/\${VAR} expansion in ExecStart= applies ONLY to
# the argument list, NEVER to the executable path itself (word 0) - a bare
# "ExecStart=\${LLMCTL_EXEC} \${LLMCTL_ARGS}" therefore made systemd try to
# literally exec a program named "\${LLMCTL_EXEC}", which always fails with
# status=203/EXEC. The fix: exec through a shell, whose OWN path is a fixed,
# parse-time-resolvable literal, and let that shell resolve the dynamic
# executable from its inherited environment at RUN time.
#
# \`set -f\` (independent review, 2026-09-17): systemd's own expansion
# word-splits but never globs; bash's \$LLMCTL_ARGS expansion DOES glob, so a
# literal "a*b" argument was silently expanded into pathname matches. \`set -f\`
# restores systemd's no-globbing behaviour exactly.
#
# Hooks (lib/svc_hook.sh): ExecStartPre rotates the engine's internal key
# file on EVERY start (G-028: a true per-start key, not create-if-absent; a
# no-op for services without a key file); ExecStartPost detaches a waiter that
# publishes the service in the registry once it answers its health endpoint;
# ExecStopPost removes the row (the port hold stays so a restart reuses the
# port, FR-088). Registration failures never fail the unit (the "-" prefix).
ExecCondition=$(_svc_portcheck_cmd %i)
ExecStartPre=$(_svc_hook_cmd gate %i)
ExecStartPre=$(_svc_hook_cmd prestart %i)
ExecStart=/bin/bash -c 'set -f; exec "\$LLMCTL_EXEC" \$LLMCTL_ARGS'
ExecStartPost=-$(_svc_hook_cmd register %i)
ExecStopPost=-$(_svc_hook_cmd unregister %i)
Restart=on-failure
RestartSec=5
RestartSteps=4
RestartMaxDelaySec=120
# No restart after an OOM kill (SIGKILL), a deliberate stop (SIGTERM) or 98 = "port already in use" (EADDRINUSE; the
# ExecCondition portcheck skips such a start cleanly - systemd only tests RestartPreventExitStatus against the MAIN process): each only repeats itself. Real cycles are > 60 s (model load), so the window is 900 s / 3 starts.
RestartPreventExitStatus=SIGKILL SIGTERM 98
MemoryHigh=${memhigh}M
MemoryMax=${memmax}M
$(_svc_resource_directives)
$(_svc_hardening "${level}")
StandardOutput=append:$(_svc_pct "${LLMCTL_LOG_DIR}")/%i.log
StandardError=append:$(_svc_pct "${LLMCTL_LOG_DIR}")/%i.log

[Install]
WantedBy=default.target
EOF
}

# _svc_unit_directives - reads a unit body on stdin and prints one "<[Section]>/<Key>" line per directive (an
# Environment= line is keyed by its variable: "Environment:LLMCTL_ROOT"), sorted, unique; comments ignored. Only
# directive NAMES are compared - values (memory limits, paths, descriptions) legitimately differ per install.
_svc_unit_directives() {
  awk '/^[[:space:]]*#/ {next}
       /^\[/ {sec=$0; next}
       /^[A-Za-z]+=/ {
         k=$0; sub(/=.*/, "", k)
         if (k == "Environment") { v=$0; sub(/^Environment="?/, "", v); sub(/=.*/, "", v); k="Environment:" v }
         print sec "/" k
       }' | LC_ALL=C sort -u
}

# svc_stale_units - prints one line per INSTALLED llmctl unit whose body predates a fix the current generator has.
# Two checks, both measured against the CURRENT generator (C2-11), not against one remembered defect:
#   1. G-067: StartLimitIntervalSec=/StartLimitBurst= inside [Service] (systemd ignores them there);
#   2. every directive NAME the current generator writes for that unit class (rendered fresh from the same
#      functions svc_install uses) must be present in the installed file: a unit from before the registry hooks,
#      the state-dir environment, a hardening directive, ... is stale. Extra directives and different values are
#      not stale. Environment:LLMCTL_DECIDE_BIN is exempt from the engine units' set (the generator writes a
#      comment instead when the binary was not built at install time).
# Nothing is printed for a clean install.
svc_stale_units() {
  local f base expected got missing
  for f in "$(svc_unit_dir)"/llmctl-*.service; do
    [[ -f "${f}" ]] || continue
    base="$(basename "${f}")"
    if awk '/^\[/{sec=$0} sec=="[Service]" && /^[[:space:]]*StartLimit(Interval(Sec)?|Burst)=/{found=1} END{exit !found}' "${f}"; then
      printf '%s: StartLimit*= inside [Service] is ignored by systemd (restart bound not applied); regenerate with: llmctl install\n' "${base}"
    fi
    if awk '/^\[/{sec=$0}
            sec=="[Unit]" && /^StartLimitBurst=/ {split($0,a,"="); b=a[2]+0; hb=1}
            sec=="[Unit]" && /^StartLimitIntervalSec=/ {split($0,a,"="); i=a[2]+0; hi=1}
            END{exit (hb && hi && i >= 600 && b <= 3 && b >= 1)}' "${f}"; then
      printf '%s: restart bound too weak to ever trip (need [Unit] StartLimitIntervalSec>=600 and StartLimitBurst<=3; Restart=always with 5/60 retried OOM kills forever); regenerate with: llmctl install\n' "${base}"
    fi
    case "${base}" in
      llmctl-llama@.service|llmctl-colibri@.service) expected="$(_svc_engine_unit_body x basic 1 1 | _svc_unit_directives)" ;;
      llmctl-onnx@.service)                          expected="$(_svc_engine_unit_body x strict 1 1 | _svc_unit_directives)" ;;
      "${DECIDE_GATEWAY_UNIT}")                      expected="$(_decide_gateway_unit_body /x 1 1 | _svc_unit_directives)" ;;
      *) continue ;;
    esac
    expected="$(printf '%s\n' "${expected}" | grep -v -x '\[Service\]/Environment:LLMCTL_DECIDE_BIN' || true)"
    got="$(_svc_unit_directives < "${f}")"
    missing="$(comm -23 <(printf '%s\n' "${expected}") <(printf '%s\n' "${got}") | sed 's#^\[[A-Za-z]*\]/##' | paste -sd, - | sed 's/,/, /g')"
    if [[ -n "${missing}" ]]; then
      printf '%s: lacks directive(s) the current generator writes (%s); regenerate with: llmctl install\n' "${base}" "${missing}"
    fi
  done
  # Enabled engine instances with no per-profile cap file run on the template backstop only.
  local w inst
  for w in "$(svc_unit_dir)"/default.target.wants/llmctl-*@*.service; do
    [[ -L "${w}" ]] || continue
    inst="$(basename "${w}")"
    [[ -f "$(svc_unit_dir)/${inst%.service}.service.d/05-memory.conf" ]] && continue
    compgen -G "$(svc_unit_dir)/${inst%.service}.service.d/*.conf" >/dev/null && grep -qs '^MemoryMax=' "$(svc_unit_dir)/${inst%.service}.service.d/"*.conf && continue
    printf '%s: no per-profile memory cap (only the template backstop applies); regenerate with: llmctl install\n' "${inst}"
  done
  return 0
}

# --- unit installation -------------------------------------------------------
svc_install() {
  local unit_dir; unit_dir="$(svc_unit_dir)"
  ensure_dir "${unit_dir}"
  ensure_state_dirs

  # Memory limits from a live probe (fixtures allowed for tests). The 2026-09-15 "no ceiling below physical RAM"
  # decision is SUPERSEDED (root cause 2, docs/host-safety.md): the TEMPLATE carries a backstop below total RAM
  # (_svc_template_caps); the per-profile limit is a drop-in sized from the plan footprint (_svc_write_mem_dropin).
  local total memmax memhigh
  total="$(hw_probe_json | json_stdin 'd["memory"]["total_mb"]')" \
    || die "cannot probe memory for service limits"
  read -r memhigh memmax <<<"$(_svc_template_caps "${total}")"

  # The three engine templates share one body (_svc_engine_unit_body); they
  # differ only in description and hardening level.
  _svc_engine_unit_body "llmctl llama.cpp inference server (profile %i)" basic \
    "${memhigh}" "${memmax}" > "${unit_dir}/llmctl-llama@.service"
  _svc_engine_unit_body "llmctl onnx encoder decision server (profile %i)" strict \
    "${memhigh}" "${memmax}" > "${unit_dir}/llmctl-onnx@.service"
  _svc_engine_unit_body "llmctl colibri inference server (profile %i)" basic \
    "${memhigh}" "${memmax}" > "${unit_dir}/llmctl-colibri@.service"
  info "installed systemd user units into ${unit_dir} (MemoryHigh=${memhigh}M MemoryMax=${memmax}M)"
  # The decision gateway's boot service is regenerated too when it is installed: units written by an
  # earlier llmctl keep their old body (G-067: StartLimitIntervalSec in [Service]) until this runs.
  if [[ -f "${unit_dir}/${DECIDE_GATEWAY_UNIT}" ]]; then
    if portreg_bin >/dev/null 2>&1; then
      _decide_gateway_write_unit >/dev/null
      info "regenerated ${DECIDE_GATEWAY_UNIT}"
    else
      warn "${DECIDE_GATEWAY_UNIT} is installed but the llmctl-decide binary is missing: it was NOT regenerated (llmctl build decide, then llmctl install)"
    fi
  fi

  # Per-profile caps for profiles that already have a service record (enabled/started before this version): without
  # this their units would keep only the template backstop and `install` would claim success.
  local _envf _p _e
  for _envf in "${LLMCTL_SERVICES_DIR}"/*.env; do
    [[ -f "${_envf}" ]] || continue
    _p="$(sed -n 's/^LLMCTL_PROFILE=//p' "${_envf}" | head -1 | tr -d "'")"
    _e="$(sed -n 's/^LLMCTL_ENGINE=//p' "${_envf}" | head -1 | tr -d "'")"
    [[ -n "${_p}" && -n "${_e}" ]] && _svc_write_mem_dropin "${_p}" "${_e}"
  done

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
  ( umask 077; : > "${env_file}" )   # created 0600 before any content is written
  {
    printf 'LLMCTL_PROFILE=%q\n' "${profile}"
    printf 'LLMCTL_ENGINE=%q\n' "${engine}"
    printf 'LLMCTL_EXEC=%q\n' "${exec_bin}"
    if [[ "${engine}" == "llama" ]]; then
      # Non-fatal directory resolution (independent review, 2026-09-17): the
      # original `exec_dir="$(cd ... && pwd)"` form aborts this ENTIRE
      # function under `set -e` when exec_bin's directory does not yet
      # exist (e.g. `llmctl build llama` has not run yet) - reproduced live:
      # `make test` regressed test_services.sh/test_tenant_service_
      # isolation.sh, both failing with "No such file or directory" from
      # this exact line, AND the abort happened mid-write inside the `{ }`
      # redirect block, leaving a TRUNCATED .env file (LLMCTL_EXEC written,
      # LLMCTL_ARGS never reached) that would launch a real service with no
      # arguments at all. `if ... ; then ...; fi` makes the failure a no-op
      # (no LD_LIBRARY_PATH line - the smoke-test/download path still works
      # standalone) instead of aborting the whole write.
      #
      # Never inherits the CALLING shell's own LD_LIBRARY_PATH (independent
      # review, 2026-09-17): the prior form appended
      # "${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}", which bakes whatever
      # ambient value the invoking shell happened to have into a
      # PERSISTENT systemd unit at `enable`/`start` time - non-reproducible
      # (the same `llmctl enable small` from two different shells writes
      # two different unit environments) and, measured live on this host,
      # the inherited suffix was literally "/usr/lib/x86_64-linux-gnu" -
      # the EXACT stale-library directory this whole fix exists to rank
      # BEHIND the correct sibling directory, now instead explicitly
      # listed on the unit's own LD_LIBRARY_PATH ahead of the normal loader
      # search order for every library the process loads, not only ggml.
      local exec_dir
      if exec_dir="$(cd "$(dirname "${exec_bin}")" 2>/dev/null && pwd)"; then
        printf 'LD_LIBRARY_PATH=%q\n' "${exec_dir}"
      fi
    fi
    printf 'LLMCTL_ARGS='
    printf '%q ' "$@"
    printf '\n'
    # Registration metadata for lib/svc_hook.sh (port, process token, kind,
    # health path, key-file PATH) - see portreg_env_lines.
    portreg_env_lines "${profile}" "${engine}" "${exec_bin}" "$@"
  } > "${env_file}"
  _svc_write_mem_dropin "${profile}" "${engine}"
  # Owner-only (D-03): the record names key-file paths and is read by the
  # service manager as the same user; nothing else has a business reading it.
  chmod 600 "${env_file}"
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

# _svc_restart_bound_ok <unit> - refuses (non-zero, message on stderr) to start an INSTALLED template unit whose
# restart bound systemd does not apply. Live run 2026-10-08 (decide-kev-9b, CUDA OOM at start): the host's installed
# llmctl-llama@.service predated the [Unit] fix - StartLimitBurst/StartLimitIntervalSec sat inside [Service], systemd
# logged "Unknown key 'StartLimitIntervalSec' in section [Service], ignoring" and applied its default interval
# (`systemctl --user show`: StartLimitIntervalUSec=10s, StartLimitBurst=5). With RestartSec=5 five starts never land
# inside 10 s, so Restart=always looped forever. Both StartLimitBurst= and StartLimitIntervalSec= must therefore be in
# [Unit] (a unit without them gets the same never-tripping default). A template that is not installed is left to
# systemctl's own "not found" error (unchanged behaviour).
_svc_restart_bound_ok() {
  local tmpl="${1%%@*}@.service" f
  f="$(svc_unit_dir)/${tmpl}"
  [[ -f "${f}" ]] || return 0
  if awk '/^\[/{sec=$0}
          sec=="[Unit]" && /^StartLimitBurst=/ {split($0,a,"="); b=a[2]+0; hb=1}
          sec=="[Unit]" && /^StartLimitIntervalSec=/ {split($0,a,"="); i=a[2]+0; hi=1}
          END{exit !(hb && hi && i >= 600 && b <= 3 && b >= 1)}' "${f}"; then
    return 0
  fi
  err "refusing to start ${1}: ${f} has no restart bound systemd applies (StartLimitBurst<=3 and StartLimitIntervalSec>=600 must be in [Unit]; inside [Service], absent or weaker, systemd's 10 s default never trips at RestartSec=5, so an engine that fails at start would restart forever). Regenerate the units with: llmctl install"
  return 1
}

# --- lifecycle ---------------------------------------------------------------
# One profile = one engine unit. The env record is keyed by PROFILE, so two engine templates
# (llmctl-llama@P / llmctl-onnx@P) can both be enabled for P; one wins the port, the other loads GBs, dies with
# EADDRINUSE and loops. _svc_disable_siblings <profile> <keep-unit> disables (and stops) every OTHER engine's unit
# for the profile. "Enabled" = the default.target.wants symlink systemd itself writes in the user unit dir.
_svc_disable_siblings() {
  local instance eng sib keep="$2"
  instance="$(_svc_instance_key "$1")"
  for eng in llama colibri onnx; do
    sib="llmctl-${eng}@${instance}.service"
    [[ "${sib}" == "${keep}" ]] && continue
    if [[ -L "$(svc_unit_dir)/default.target.wants/${sib}" ]]; then
      warn "profile ${1} has a second enabled engine unit ${sib}; disabling it (one engine per profile)"
      _svc_sys disable "${sib}" || true
      _svc_sys stop "${sib}" || true
    fi
  done
}

# _svc_start_bounded <unit> - `systemctl --user start` with a bound (LLMCTL_START_WAIT s, default 20). The scheduler holds its
# flock across this call, and the unit's ExecStartPre pressure gate can wait up to 120 s, so a blocking start would stall
# every other llmctl invocation for that long. On timeout (rc 124) the unit is "still starting" (the systemd job continues):
# return 0 and let the readiness poll that follows decide - it fails closed (and stops the unit) if the model never answers.
_svc_start_bounded() {
  if [[ "${LLMCTL_DRY_RUN}" == "1" ]]; then _svc_sys start "$1"; return; fi
  local rc=0
  timeout "${LLMCTL_START_WAIT:-20}" systemctl --user start "$1" || rc=$?
  if [[ "${rc}" -eq 124 ]]; then
    warn "$1 is still starting after ${LLMCTL_START_WAIT:-20}s (pressure gate waiting or model loading); not holding the scheduler lock for it"
    return 0
  fi
  return "${rc}"
}

# svc_started_ok <profile> - after a successful start: is the unit active or activating? An ExecCondition skip (port already
# taken) makes `systemctl start` return 0 with the unit inactive; a foreign listener on the port must not be mistaken for it.
# Dry-run: a <runtime>/<profile>.skipped marker stands for "skipped".
svc_started_ok() {
  if [[ "${LLMCTL_DRY_RUN:-0}" == "1" ]]; then [[ ! -f "${LLMCTL_RUNTIME_DIR}/$1.skipped" ]]; return; fi
  local st rc=0
  st="$(systemctl --user is-active "$(_svc_unit_for "$1")" 2>/dev/null)" || rc=$?
  [[ "${rc}" -eq 0 || "${st}" == activating || "${st}" == reloading ]]
}

svc_enable() {
  local unit; unit="$(_svc_unit_for "$1")"
  _svc_restart_bound_ok "${unit}" || return 1
  _svc_ensure_tenant_slice_dropin "${unit}"
  _svc_disable_siblings "$1" "${unit}"
  _svc_sys enable "${unit}"
  _svc_start_bounded "${unit}"
}

svc_disable() {
  local unit; unit="$(_svc_unit_for "$1")"
  _svc_disable_siblings "$1" ""
  local _e _inst; _inst="$(_svc_instance_key "$1")"
  for _e in llama colibri onnx; do _svc_rm_mem_dropin "${_inst}" "${_e}"; done
  _svc_sys stop "${unit}" || true
  _svc_sys disable "${unit}" || true
  [[ "${LLMCTL_DRY_RUN}" == "1" ]] || rm -f "${LLMCTL_SERVICES_DIR}/$(_svc_instance_key "$1").env"
}

svc_start()   { local unit; unit="$(_svc_unit_for "$1")"; _svc_restart_bound_ok "${unit}" || return 1; _svc_ensure_tenant_slice_dropin "${unit}"; _svc_start_bounded "${unit}"; }
# LLMCTL_TEST_FORCE_STOP_FAIL: test-only hook (round-3 independent review,
# 2026-10-03). Under LLMCTL_DRY_RUN=1, _svc_sys unconditionally returns 0,
# so the hermetic test suite has no existing way to exercise a FAILED stop
# (e.g. to prove _sched_auto_impl's eviction credit is correctly withheld
# when svc_stop genuinely fails). Checked only when both this var and
# LLMCTL_DRY_RUN are set, matching exactly the named profile -- inert in
# every real, non-test invocation.
svc_stop() {
  if [[ "${LLMCTL_DRY_RUN:-}" == "1" && -n "${LLMCTL_TEST_FORCE_STOP_FAIL:-}" && "${LLMCTL_TEST_FORCE_STOP_FAIL}" == "$1" ]]; then
    printf '[dry-run] systemctl --user stop %s (TEST: forced failure)\n' "$(_svc_unit_for "$1")"
    return 1
  fi
  _svc_sys stop  "$(_svc_unit_for "$1")"
}
svc_restart() { local unit; unit="$(_svc_unit_for "$1")"; _svc_restart_bound_ok "${unit}" || return 1; _svc_ensure_tenant_slice_dropin "${unit}"; _svc_sys restart "${unit}"; }

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
# systemd has given up restarting it (Restart=on-failure never fires again until
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

# svc_enabled_down - one "<unit>\t<state>" line per ENABLED engine unit (default.target.wants symlink) that is not
# active. After a SIGKILL (oomd, MemoryMax) a unit is deliberately not restarted (RestartPreventExitStatus=SIGKILL), so
# without this nothing shows that an enabled model is down. Dry-run: <profile>.run = active, <profile>.failed = failed.
svc_enabled_down() {
  local w unit inst state
  for w in "$(svc_unit_dir)"/default.target.wants/llmctl-*@*.service; do
    [[ -L "${w}" ]] || continue
    unit="$(basename "${w}")"; inst="${unit#*@}"; inst="${inst%.service}"
    if [[ "${LLMCTL_DRY_RUN:-0}" == "1" ]]; then
      if [[ -f "${LLMCTL_RUNTIME_DIR}/${inst}.failed" ]]; then state=failed
      elif [[ -f "${LLMCTL_RUNTIME_DIR}/${inst}.run" ]]; then state=active
      else state=inactive; fi
    else
      state="$(systemctl --user is-active "${unit}" 2>/dev/null || true)"; state="${state:-inactive}"
    fi
    [[ "${state}" == active || "${state}" == activating || "${state}" == reloading ]] || printf '%s\t%s\n' "${unit}" "${state}"
  done
  return 0
}

# Profiles with an env file (i.e. known to llmctl). The env files are named by the INSTANCE key
# (<tenant>--<profile> under LLMCTL_TENANT_ID); this returns PROFILE names - every other function
# (svc_is_active, svc_main_pid, _svc_unit_for ...) re-applies the tenant prefix itself, so
# returning instance keys doubled it (`acme--acme--small`) and made the doctor's live set empty.
# Under a tenant only that tenant's files are listed (another tenant's services are not ours).
svc_known_profiles() {
  local f b tid="${LLMCTL_TENANT_ID:-}"
  for f in "${LLMCTL_SERVICES_DIR}"/*.env; do
    [[ -e "${f}" ]] || continue
    b="$(basename "${f}" .env)"
    if [[ -n "${tid}" ]]; then
      [[ "${b}" == "${tid}--"* ]] || continue
      b="${b#"${tid}--"}"
    fi
    printf '%s\n' "${b}"
  done
}

# svc_main_pid <profile> -> the main process id of the running unit (empty
# when not running / unknown). Used to register the service with its REAL
# process identity (the registry re-checks argv, never trusts the row).
svc_main_pid() {
  local pid=""
  if [[ "${LLMCTL_DRY_RUN:-0}" == "1" ]]; then return 0; fi
  pid="$(systemctl --user show -p MainPID --value "$(_svc_unit_for "$1")" 2>/dev/null || true)"
  [[ "${pid}" =~ ^[0-9]+$ && "${pid}" -gt 1 ]] && printf '%s\n' "${pid}"
  return 0
}

# svc_peak_rss_kb <pid> -> high-water resident set (VmHWM) in KiB, for the
# FR-083 "record the measured peak memory of every decision component"
# evidence. Reads the real /proc record; prints nothing when unreadable.
svc_peak_rss_kb() {
  sed -n 's/^VmHWM:[[:space:]]*\([0-9]*\) kB.*/\1/p' "/proc/${1}/status" 2>/dev/null | head -1
}

# --- decision gateway as a boot-time user service (spec 009 FR-031, G-041) ---
DECIDE_GATEWAY_UNIT="llmctl-decide-gateway.service"

# _decide_gateway_unit_body <bin> <memhigh-MiB> <memmax-MiB>
# Memory policy: the gateway is a small Go process, so its caps are small
# fractions of RAM (_svc_gateway_caps: MemoryHigh 20%, MemoryMax 25%, capped at
# 3/4 GiB), not the full probed total. Every other llmctl unit also stays below
# 90% of RAM (per-profile caps). The measured peak is recorded in the QA
# evidence regardless of policy (FR-083).
_decide_gateway_unit_body() {
  local bin="$1" memhigh="$2" memmax="$3"
  cat <<EOF
[Unit]
Description=llmctl decision gateway (HTTPS, key-protected; engines stay loopback-only)
After=network-online.target
Wants=network-online.target
# Restart bounds in [Unit] - the only section systemd honours them in.
StartLimitBurst=3
StartLimitIntervalSec=900

[Service]
Type=simple
$(_svc_env LLMCTL_ROOT "${LLMCTL_ROOT}")
$(_svc_env LLMCTL_STATE_DIR "${LLMCTL_STATE_DIR}")
$(_svc_env LLMCTL_LOG_DIR "${LLMCTL_LOG_DIR}")
$(_svc_env LLMCTL_SERVICES_DIR "${LLMCTL_SERVICES_DIR}")
$(_svc_env LLMCTL_CONFIG_DIR "${LLMCTL_CONFIG_DIR}")
$(_svc_env LLMCTL_DATA_DIR "${LLMCTL_DATA_DIR}")
$(_svc_env LLMCTL_RUNTIME_DIR "${LLMCTL_RUNTIME_DIR}")
$(_svc_env LLMCTL_DECIDE_BIN "${bin}")
# Operator overrides (LLMCTL_DECIDE_PORT, LLMCTL_DECIDE_BIND,
# LLMCTL_PORT_STRATEGY=dynamic, LLMCTL_PORT_GATEWAY=auto, LLMCTL_DECIDE_MODE,
# ...) go in this optional file; no secret belongs in it (the access key lives
# in the installation .env, which the gateway reads itself, mode 0600).
EnvironmentFile=-$(_svc_pct "${LLMCTL_STATE_DIR}")/decide/gateway.conf
# The wrapper allocates the port (fixed 8095 by default, dynamic on request),
# resolves decision backends from the registry, publishes the gateway
# (kind=gateway) and finally EXECs: llmctl-decide serve --foreground
ExecStart=$(_svc_hook_cmd run-gateway)
ExecStopPost=-$(_svc_hook_cmd unregister gateway)
Restart=on-failure
RestartSec=5
RestartSteps=4
RestartMaxDelaySec=120
# No restart after an OOM kill (SIGKILL), a deliberate stop (SIGTERM) or 98 = "port already in use" (EADDRINUSE; the
# ExecCondition portcheck skips such a start cleanly - systemd only tests RestartPreventExitStatus against the MAIN process): each only repeats itself. Real cycles are > 60 s (model load), so the window is 900 s / 3 starts.
RestartPreventExitStatus=SIGKILL SIGTERM 98
MemoryHigh=${memhigh}M
MemoryMax=${memmax}M
$(_svc_resource_directives)
$(_svc_hardening strict)
StandardOutput=append:$(_svc_pct "${LLMCTL_LOG_DIR}")/decide-gateway.log
StandardError=append:$(_svc_pct "${LLMCTL_LOG_DIR}")/decide-gateway.log

[Install]
WantedBy=default.target
EOF
}

# _decide_gateway_write_unit - writes the unit file (plain file I/O: also in
# dry-run, like svc_install) and prints its path.
_decide_gateway_write_unit() {
  local bin total unit_dir
  bin="$(portreg_bin)" || die "llmctl-decide binary not found - build it first: llmctl build decide"
  total="$(hw_probe_json | json_stdin 'd["memory"]["total_mb"]')" \
    || die "cannot probe memory for service limits"
  unit_dir="$(svc_unit_dir)"
  ensure_dir "${unit_dir}"
  ensure_state_dirs
  ensure_dir "${LLMCTL_STATE_DIR}/decide"
  local gh gm; read -r gh gm <<<"$(_svc_gateway_caps "${total}")"
  _decide_gateway_unit_body "${bin}" "${gh}" "${gm}" > "${unit_dir}/${DECIDE_GATEWAY_UNIT}"
  printf '%s\n' "${unit_dir}/${DECIDE_GATEWAY_UNIT}"
}

# decide_service_enable - install + enable + start the gateway user service
# (called by `llmctl decide serve --enable`).
decide_service_enable() {
  local upath old="" changed=0
  upath="$(svc_unit_dir)/${DECIDE_GATEWAY_UNIT}"
  if [[ "${LLMCTL_DRY_RUN}" == "1" ]]; then
    printf '[dry-run] write %s\n' "${upath}"     # a dry run writes no unit file
  else
    [[ -f "${upath}" ]] && old="$(cat "${upath}")"
    _decide_gateway_write_unit >/dev/null
    info "installed ${DECIDE_GATEWAY_UNIT} into $(svc_unit_dir)"
    [[ -n "${old}" && "${old}" != "$(cat "${upath}")" ]] && changed=1
  fi
  _svc_sys daemon-reload
  if [[ "${LLMCTL_DRY_RUN}" == "1" ]]; then
    printf '[dry-run] loginctl enable-linger %s\n' "${USER:-$(id -un)}"
  elif have_cmd loginctl; then
    loginctl enable-linger "${USER:-$(id -un)}" 2>/dev/null \
      || warn "loginctl enable-linger failed; retry with: sudo loginctl enable-linger ${USER:-$(id -un)}"
  fi
  _svc_sys enable "${DECIDE_GATEWAY_UNIT}"
  if (( changed )); then
    # `start` on a running unit is a no-op, so a re-enable over a CHANGED unit file would leave the old
    # definition in force: `restart` applies the new definition to a running unit AND starts a stopped
    # one (a start followed by a try-restart would start a stopped gateway twice).
    info "unit definition changed: restarting ${DECIDE_GATEWAY_UNIT} to apply it"
    _svc_sys restart "${DECIDE_GATEWAY_UNIT}"
  else
    _svc_sys start "${DECIDE_GATEWAY_UNIT}"
  fi
}

# decide_service_disable - stop + disable + remove the unit and the gateway's
# registry row / port hold (called by `llmctl decide serve --disable`).
decide_service_disable() {
  _svc_sys stop "${DECIDE_GATEWAY_UNIT}" || true
  _svc_sys disable "${DECIDE_GATEWAY_UNIT}" || true
  # a dry run must leave the real unit alone (C-12): the service keeps running, so deleting its
  # unit file would orphan it from systemd's management
  if [[ "${LLMCTL_DRY_RUN}" == "1" ]]; then
    printf '[dry-run] rm -f %s\n' "$(svc_unit_dir)/${DECIDE_GATEWAY_UNIT}"
  else
    rm -f "$(svc_unit_dir)/${DECIDE_GATEWAY_UNIT}"
  fi
  _svc_sys daemon-reload
  portreg_unregister decide-gateway
  portreg_release gateway
  info "removed ${DECIDE_GATEWAY_UNIT}"
}

# decide_service_main_pid -> main pid of the running gateway unit (empty if none).
decide_service_main_pid() {
  local pid=""
  [[ "${LLMCTL_DRY_RUN:-0}" == "1" ]] && return 0
  pid="$(systemctl --user show -p MainPID --value "${DECIDE_GATEWAY_UNIT}" 2>/dev/null || true)"
  [[ "${pid}" =~ ^[0-9]+$ && "${pid}" -gt 1 ]] && printf '%s\n' "${pid}"
  return 0
}

# decide_service_status - the unit's own state (the gateway process/cert/key
# state is `llmctl decide serve --status`, which verifies the real process).
decide_service_status() {
  if [[ "${LLMCTL_DRY_RUN}" == "1" ]]; then
    printf '[dry-run] systemctl --user status %s\n' "${DECIDE_GATEWAY_UNIT}"
    return 0
  fi
  systemctl --user --no-pager status "${DECIDE_GATEWAY_UNIT}" || true
}
