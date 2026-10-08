#!/usr/bin/env bash
# portreg.sh - thin bash adapter over the Go port allocator + service registry
# (`llmctl-decide port|registry|discover`, internal/registry). Spec 009
# FR-088..FR-091, SC-015, OD-18.
#
# Division of labour: ALL allocation / registry logic (bind test, sticky
# reuse, atomic state, process-identity liveness) lives in Go on top of the
# Containers submodule; bash only calls it. This file never re-implements
# any of it.
#
# Activation. The adapter is ACTIVE when the llmctl-decide binary can be
# found AND the scheduler is not in dry-run mode (a dry run must stay
# hermetic: it never binds, probes or records anything). With no binary the
# scheduler keeps its previous behaviour byte for byte (the catalog's
# documented port, no registry) - except that an explicit request for
# dynamic ports (LLMCTL_PORT_STRATEGY=dynamic or LLMCTL_PORT_<PROFILE>=auto)
# is refused loudly instead of being silently ignored.
#
#   LLMCTL_DECIDE_BIN   explicit binary path (wins over the search below)
#   LLMCTL_PORTREG      0 = adapter off (tests), 1 = on even in dry run,
#                       unset/auto = on when the binary exists and not dry-run
#
# Binary search order: $LLMCTL_DECIDE_BIN, <root>/build/llmctl-decide (where
# `llmctl build decide` puts it), then `llmctl-decide` on PATH.
set -euo pipefail

_prg_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_prg_dir}/common.sh"

# portreg_bin -> prints the llmctl-decide binary path; rc 1 when none.
portreg_bin() {
  local b
  if [[ -n "${LLMCTL_DECIDE_BIN:-}" ]]; then
    [[ -x "${LLMCTL_DECIDE_BIN}" ]] || return 1
    printf '%s\n' "${LLMCTL_DECIDE_BIN}"
    return 0
  fi
  for b in "${LLMCTL_ROOT}/build/llmctl-decide" "$(command -v llmctl-decide 2>/dev/null || true)"; do
    if [[ -n "${b}" && -x "${b}" ]]; then printf '%s\n' "${b}"; return 0; fi
  done
  return 1
}

# portreg_active -> rc 0 when allocation + registry calls should be made.
portreg_active() {
  case "${LLMCTL_PORTREG:-auto}" in
    0|off|no) return 1 ;;
    1|on|yes) portreg_bin >/dev/null ;;
    *)        [[ "${LLMCTL_DRY_RUN:-0}" != "1" ]] && portreg_bin >/dev/null ;;
  esac
}

# portreg_profile_var <name> -> LLMCTL_PORT_<NAME> (same rule as the Go side).
portreg_profile_var() {
  printf 'LLMCTL_PORT_%s' "$(printf '%s' "$1" | tr '[:lower:]-.' '[:upper:]__')"
}

# portreg_dynamic_requested <profile> -> rc 0 when the operator asked for a
# dynamic port for this profile (global strategy or per-profile =auto) and
# no explicit numeric port overrides it.
portreg_dynamic_requested() {
  local v; v="$(portreg_profile_var "$1")"
  case "${!v:-}" in
    auto) return 0 ;;
    "")   [[ "${LLMCTL_PORT_STRATEGY:-fixed}" == "dynamic" ]] ;;
    *)    return 1 ;;
  esac
}

# portreg_allocate <name> <profile> <documented-port> -> prints the port.
# Inactive adapter: prints <documented-port> unchanged (refusing a dynamic
# request it cannot honour). Active: `port allocate` (rc 1 + stderr naming
# the port and the override variable when the port is taken).
portreg_allocate() {
  local name="$1" profile="$2" documented="$3" bin
  if ! portreg_active; then
    if portreg_dynamic_requested "${profile}"; then
      err "dynamic port assignment was requested for '${profile}' but the registry binary is unavailable or this is a dry run (build it: llmctl build decide)"
      return 1
    fi
    printf '%s\n' "${documented}"
    return 0
  fi
  bin="$(portreg_bin)"
  "${bin}" port allocate "${name}" --profile "${profile}" --fixed "${documented}"
}

# portreg_release <name> - drop the port hold (idempotent, quiet).
portreg_release() {
  portreg_active || return 0
  "$(portreg_bin)" port release "$1" >/dev/null 2>&1 || true
}

# portreg_register <name> <port> <pid> <token> <protocol> <health-path> \
#                  <kind> <profile> <instance> <loopback 0|1> [key-file]
portreg_register() {
  portreg_active || return 0
  local name="$1" port="$2" pid="$3" token="$4" proto="$5" health="$6" kind="$7" profile="$8" inst="$9" loop="${10}" keyf="${11:-}"
  local -a a=(registry register "${name}" --port "${port}" --pid "${pid}" --token "${token}"
              --protocol "${proto}" --kind "${kind}" --profile "${profile}" --instance "${inst}")
  [[ -n "${health}" ]] && a+=(--health-path "${health}")
  [[ "${loop}" == "1" ]] && a+=(--loopback-only)
  [[ -n "${keyf}" ]] && a+=(--label "key_file=${keyf}")
  # C2-07: the registry refuses a pid that does not (yet) run the registered program (an early publish would pin a
  # launcher's fingerprint). The pid exec's into the engine within moments, so retry that one refusal for a bounded
  # time (LLMCTL_REGISTER_IDENTITY_WAIT seconds, default 10); every other failure is reported at once.
  local bin waited=0 limit="${LLMCTL_REGISTER_IDENTITY_WAIT:-10}" rerr rrc
  bin="$(portreg_bin)"
  while :; do
    rrc=0; rerr="$("${bin}" "${a[@]}" 2>&1 >/dev/null)" || rrc=$?
    [[ "${rrc}" -eq 0 ]] && return 0
    case "${rerr}" in
      *"is not (yet) running"*)
        if (( waited < limit )); then sleep 1; waited=$(( waited + 1 )); continue; fi ;;
    esac
    printf '%s\n' "${rerr}" >&2
    return "${rrc}"
  done
}

# portreg_unregister <name> - remove the registry row (idempotent, quiet).
portreg_unregister() {
  portreg_active || return 0
  "$(portreg_bin)" registry unregister "$1" >/dev/null 2>&1 || true
}

# portreg_env_lines <profile> <engine> <exec> <args...>
# Prints the registration metadata lines every backend appends to a service's
# env record (read by lib/svc_hook.sh for boot-time / restart registration and
# by the doctor). Values are plain tokens; nothing secret is written (only the
# PATH of a key file, never its content).
portreg_env_lines() {
  local profile="$1" engine="$2" exec_bin="$3"; shift 3
  local port="" keyf="" i token kind="${LLMCTL_SVC_KIND:-}" health loop="${LLMCTL_SVC_LOOPBACK:-}" host=""
  local -a argv=("$@")
  for (( i=0; i<${#argv[@]}; i++ )); do
    case "${argv[i]}" in
      --port)         port="${argv[i+1]:-}" ;;
      --api-key-file) keyf="${argv[i+1]:-}" ;;
      --host)         host="${argv[i+1]:-}" ;;
    esac
  done
  token="$(basename "${exec_bin}")"
  case "${token}" in
    python|python3|python3.*) token="$(basename "${argv[0]:-python}")" ;;
  esac
  case "${engine}" in
    colibri) health="/v1/models" ;;
    *)       health="/health" ;;
  esac
  [[ -n "${kind}" ]] || kind="chat"
  if [[ -z "${loop}" ]]; then
    case "${host}" in 127.*|localhost|::1) loop=1 ;; *) loop=0 ;; esac
  fi
  [[ -n "${port}" ]] || return 0
  printf 'LLMCTL_PORT=%s\n' "${port}"
  printf 'LLMCTL_REG_TOKEN=%q\n' "${token}"
  printf 'LLMCTL_REG_KIND=%q\n' "${kind}"
  printf 'LLMCTL_REG_PROTOCOL=http\n'
  printf 'LLMCTL_REG_HEALTH=%q\n' "${health}"
  printf 'LLMCTL_REG_PROFILE=%q\n' "${profile%%.*}"
  printf 'LLMCTL_REG_LOOPBACK=%s\n' "${loop}"
  [[ -n "${keyf}" ]] && printf 'LLMCTL_KEY_FILE=%q\n' "${keyf}"
  return 0
}

# --- registry == live set (FR-089, SC-015) ------------------------------------
# portreg_live_set -> "name=pid,name=pid,..." of every service the loaded
# backend reports ACTIVE (engines/runtimes by env record, plus the gateway when
# its boot service runs), each with its real main pid. Needs a loaded backend
# (sched_load_backend); prints nothing without one.
portreg_live_set() {
  local p pid name out=""
  if declare -F svc_known_profiles >/dev/null 2>&1; then
    # svc_known_profiles yields PROFILE names (this tenant's only); the registry row of a service is
    # named by its INSTANCE key (<tenant>--<profile> under LLMCTL_TENANT_ID), so the live set is
    # reported under that name - the same one svc_hook.sh registers (C-05).
    for p in $(svc_known_profiles); do
      svc_is_active "${p}" 2>/dev/null || continue
      pid="$(svc_main_pid "${p}" 2>/dev/null || true)"
      name="${p}"
      if declare -F _svc_instance_key >/dev/null 2>&1; then name="$(_svc_instance_key "${p}")"; fi
      [[ -n "${pid}" ]] && out+="${out:+,}${name}=${pid}"
    done
  fi
  if declare -F decide_service_main_pid >/dev/null 2>&1; then
    pid="$(decide_service_main_pid 2>/dev/null || true)"
    [[ -n "${pid}" ]] && out+="${out:+,}decide-gateway=${pid}"
  fi
  printf '%s\n' "${out}"
}

# portreg_diff_report - compare the registry with the live set. Prints the
# comparison (one line per discrepancy, or "registry == live set") and returns
# 1 when they differ: a registry row without a live service, or a live service
# without a row, is a defect (FR-089) that `llmctl doctor` reports.
portreg_diff_report() {
  portreg_active || { echo "service registry not active (no llmctl-decide binary or dry run)"; return 0; }
  # C2-03: the registry is shared by every tenant and by non-tenant services, but the live set lists only THIS
  # backend's: scope the comparison to the rows it owns (a tenant: its "<tenant>--" rows plus the shared gateway;
  # no tenant: every row that is not some tenant's), or another tenant's row is reported as a defect.
  # C3-08: unambiguous because row names are "<tenant>--<profile>" with NO other "--" and no dash touching it (tenant
  # ids / profile names are validated in service_linux.sh, the registry refuses other names, and an ambiguous legacy
  # row belongs to no tenant scope and stays visible to the non-tenant one).
  local -a scope=(--no-tenant-rows)
  [[ -z "${LLMCTL_TENANT_ID:-}" ]] || scope=(--prefix "${LLMCTL_TENANT_ID}--" --include decide-gateway)
  "$(portreg_bin)" registry diff --live "$(portreg_live_set)" "${scope[@]}"
}
