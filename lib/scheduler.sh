#!/usr/bin/env bash
# scheduler.sh - multi-model co-residency and switching for llmctl.
#
# State model (all under $LLMCTL_STATE_DIR / $LLMCTL_RUNTIME_DIR):
#   services/<profile>.env       launch parameters (written on start/enable)
#   services/<profile>.enabled   marker: profile is enabled (autostart);
#                                "llmctl auto" never evicts enabled services
#   run/<profile>.run            reservation record of a RUNNING profile:
#                                mode, port, ram_mb, vram_mb, started_epoch
#
# Policy (documented in README):
#   * llmctl start <p...>  - start only if the COMBINED footprint fits the
#                            live budgets minus current reservations
#   * llmctl auto <cap...> - pick the best-ranked fitting profile per
#                            capability; when nothing fits alongside what is
#                            running, evict non-enabled services in LRU order
#                            (oldest started first) until it fits
#   * llmctl switch <p>    - stop everything, start exactly one profile
set -euo pipefail

_sch_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_sch_dir}/common.sh"
# shellcheck source=os_detect.sh
source "${_sch_dir}/os_detect.sh"
# shellcheck source=hardware.sh
source "${_sch_dir}/hardware.sh"
# shellcheck source=catalog.sh
source "${_sch_dir}/catalog.sh"

# Load the service backend for this OS.
sched_load_backend() {
  case "$(llmctl_os)" in
    linux)  # shellcheck source=service_linux.sh
            source "${_sch_dir}/service_linux.sh" ;;
    macos)  # shellcheck source=service_macos.sh
            source "${_sch_dir}/service_macos.sh" ;;
    *)      die "unsupported OS: $(uname -s)" ;;
  esac
}

# Quality ranking per capability (best first). Fixed and documented.
sched_rank_for_capability() {
  case "$1" in
    chat)   echo "colibri-glm ws-dense-32b ws-moe-30b coder moe-fast fast vision-pro vision colibri-qwen36 small" ;;
    coder)  echo "colibri-glm coder ws-moe-30b ws-dense-32b colibri-qwen36" ;;
    vision) echo "vision-pro vision" ;;
    *)      return 1 ;;
  esac
}

# --- concurrency ---------------------------------------------------------------
# scheduler::with_lock <command> [args...]
# Runs <command> under an exclusive advisory lock on the scheduler state
# directory, so two concurrent llmctl invocations (e.g. a cron job and an
# interactive user) never interleave their read-budgets-then-write-reservation
# sequence. A second invocation BLOCKS until the first releases the lock,
# then runs against fresh state - it never proceeds on a stale read (FR-043).
scheduler::with_lock() {
  ensure_dir "${LLMCTL_RUNTIME_DIR}"
  local lock_file="${LLMCTL_RUNTIME_DIR}/.scheduler.lock"
  local lock_fd
  exec {lock_fd}>"${lock_file}"
  flock -x "${lock_fd}"
  local rc=0
  "$@" || rc=$?
  flock -u "${lock_fd}"
  exec {lock_fd}>&-
  return "${rc}"
}

# --- reservation records ------------------------------------------------------
_sched_run_file() { echo "${LLMCTL_RUNTIME_DIR}/$1.run"; }

sched_running() {
  local f
  ensure_dir "${LLMCTL_RUNTIME_DIR}"
  for f in "${LLMCTL_RUNTIME_DIR}"/*.run; do
    [[ -e "${f}" ]] || continue
    basename "${f}" .run
  done
}

sched_is_running() { [[ -f "$(_sched_run_file "$1")" ]]; }

sched_is_enabled() { [[ -f "${LLMCTL_SERVICES_DIR}/$1.enabled" ]]; }

sched_reserved_field() {
  # sched_reserved_field <ram_mb|vram_mb> -> sum over running reservations
  local field="$1" f total=0 v
  for f in "${LLMCTL_RUNTIME_DIR}"/*.run; do
    [[ -e "${f}" ]] || continue
    v="$(sed -n "s/^${field}=//p" "${f}" | head -1)"
    total=$(( total + ${v:-0} ))
  done
  echo "${total}"
}

_sched_write_reservation() {
  local profile="$1" mode="$2" port="$3" ram="$4" vram="$5"
  ensure_dir "${LLMCTL_RUNTIME_DIR}"
  cat > "$(_sched_run_file "${profile}")" <<EOF
profile=${profile}
mode=${mode}
port=${port}
ram_mb=${ram}
vram_mb=${vram}
started_epoch=$(date +%s)
EOF
}

# --- launch argument construction --------------------------------------------
# Prints exec path on stdout; arguments are left in the global array
# SCHED_ARGS (bash has no array returns).
sched_build_launch() {
  local profile="$1" mode="$2" port="$3" ctx="$4" ngl="$5" parallel="$6" fa="$7"
  local engine; engine="$(catalog_engine "${profile}")"
  SCHED_ARGS=()
  case "${engine}" in
    llama)
      local bin model="" mmproj="" name role
      bin="${LLMCTL_LLAMA_SERVER:-${LLMCTL_ROOT}/submodules/llama.cpp/build/bin/llama-server}"
      while IFS='|' read -r name _ _ role; do
        case "${role}" in
          mmproj) mmproj="${LLMCTL_MODELS_DIR}/${profile}/${name}" ;;
          *)      [[ -z "${model}" ]] && model="${LLMCTL_MODELS_DIR}/${profile}/${name}" ;;
        esac
      done < <(catalog_files "${profile}")
      [[ -n "${model}" ]] || die "profile ${profile} has no model file in catalog"
      if [[ "${LLMCTL_DRY_RUN}" != "1" && ! -f "${model}" ]]; then
        die "model not downloaded: ${model}. Run: llmctl models download ${profile}"
      fi
      SCHED_ARGS=(--model "${model}" --host 127.0.0.1 --port "${port}"
                  --ctx-size "${ctx}" --n-gpu-layers "${ngl}"
                  --flash-attn "${fa}" --parallel "${parallel}" --jinja)
      [[ -n "${mmproj}" && -f "${mmproj}" ]] && SCHED_ARGS+=(--mmproj "${mmproj}")
      # Deterministic live-challenge mode (spec.md FR-012/SC-008): opt-in via
      # LLMCTL_SEED, not baked into every default launch - an always-on fixed
      # seed would make every interactive coding-assistant session
      # identically non-creative, which FR-012 does not ask for (it scopes
      # determinism to "live challenges", the release-gating procedure in
      # docs/quickstart.md, not everyday interactive use).
      [[ -n "${LLMCTL_SEED:-}" ]] && SCHED_ARGS+=(--seed "${LLMCTL_SEED}" --temp 0)
      SCHED_EXEC="${bin}"
      ;;
    colibri)
      local dir="${LLMCTL_MODELS_DIR}/${profile}"
      if [[ "${LLMCTL_DRY_RUN}" != "1" && ! -d "${dir}" ]]; then
        die "model not downloaded: ${dir}. Run: llmctl models download ${profile}"
      fi
      SCHED_EXEC="${LLMCTL_COLI_BIN:-coli}"
      SCHED_ARGS=(serve --model "${dir}" --host 127.0.0.1 --port "${port}")
      ;;
    *) die "unknown engine for profile ${profile}: ${engine}" ;;
  esac
}

# --- core operations ----------------------------------------------------------
# Public entry points acquire the scheduler lock exactly once each and
# delegate to an unlocked _impl. sched_auto's _impl calls _sched_start_impl
# directly (never the public, locking sched_start) so its eviction-then-start
# sequence runs as ONE atomic locked unit instead of two separate acquisitions
# with a gap between them - and so nested acquisition (which would deadlock
# flock against itself) never happens.
sched_start() { scheduler::with_lock _sched_start_impl "$@"; }
sched_stop()  { scheduler::with_lock _sched_stop_impl "$@"; }
sched_auto()  { scheduler::with_lock _sched_auto_impl "$@"; }

# _sched_start_impl <profile...> - returns non-zero (with a clear message)
# when the combined footprint does not fit. Call sched_start (above) from
# outside this file; this unlocked form exists so sched_auto can compose it
# under a single lock acquisition.
_sched_start_impl() {
  [[ "$#" -ge 1 ]] || die "usage: llmctl start <profile> [more...]"
  sched_load_backend
  ensure_state_dirs

  local plan_file; plan_file="$(mktemp)"
  hw_probe_json | catalog_plan_json > "${plan_file}"

  local ram_budget vram_budget
  ram_budget="$(json_query "${plan_file}" 'd["budgets"]["ram_mb"]')"
  vram_budget="$(json_query "${plan_file}" 'd["budgets"]["vram_mb"]')"

  local used_ram used_vram
  used_ram="$(sched_reserved_field ram_mb)"
  used_vram="$(sched_reserved_field vram_mb)"

  local p mode port ram vram ctx ngl parallel fa fits
  local -a selected=()
  for p in "$@"; do
    catalog_exists "${p}" || { rm -f "${plan_file}"; die "unknown profile: ${p} (see: llmctl models list)"; }
    sched_is_running "${p}" && { log "${p} is already running"; continue; }
    fits="$(json_query "${plan_file}" "d[\"profiles\"][\"${p}\"][\"fits\"]")"
    ram="$(json_query "${plan_file}" "d[\"profiles\"][\"${p}\"][\"ram_mb\"]")"
    vram="$(json_query "${plan_file}" "d[\"profiles\"][\"${p}\"][\"vram_mb\"]")"
    if [[ "${fits}" != "True" ]] || \
       (( used_ram + ram > ram_budget )) || \
       (( used_vram + vram > vram_budget )); then
      local suggestion=""
      local alt
      for alt in $(json_query "${plan_file}" 'd["recommended"]'); do
        sched_is_running "${alt}" && continue
        local a_ram a_vram
        a_ram="$(json_query "${plan_file}" "d[\"profiles\"][\"${alt}\"][\"ram_mb\"]")"
        a_vram="$(json_query "${plan_file}" "d[\"profiles\"][\"${alt}\"][\"vram_mb\"]")"
        if (( used_ram + a_ram <= ram_budget && used_vram + a_vram <= vram_budget )); then
          suggestion="${alt}"; break
        fi
      done
      rm -f "${plan_file}"
      err "cannot start '${p}': needs ${ram} MiB RAM + ${vram} MiB VRAM, but only $(( ram_budget - used_ram )) MiB RAM + $(( vram_budget - used_vram )) MiB VRAM remain"
      [[ -n "${suggestion}" ]] && err "suggested alternative that fits now: llmctl start ${suggestion}"
      err "or free everything with: llmctl switch ${p}"
      return 1
    fi
    selected+=("${p}")
    used_ram=$(( used_ram + ram ))
    used_vram=$(( used_vram + vram ))
  done

  for p in ${selected[@]+"${selected[@]}"}; do
    mode="$(json_query "${plan_file}" "d[\"profiles\"][\"${p}\"][\"mode\"]")"
    port="$(json_query "${plan_file}" "d[\"profiles\"][\"${p}\"][\"port\"]")"
    ram="$(json_query "${plan_file}" "d[\"profiles\"][\"${p}\"][\"ram_mb\"]")"
    vram="$(json_query "${plan_file}" "d[\"profiles\"][\"${p}\"][\"vram_mb\"]")"
    ctx="$(json_query "${plan_file}" "d[\"profiles\"][\"${p}\"][\"ctx\"]")"
    ngl="$(json_query "${plan_file}" "d[\"profiles\"][\"${p}\"][\"ngl\"]")"
    parallel="$(json_query "${plan_file}" "d[\"profiles\"][\"${p}\"][\"parallel\"]")"
    fa="$(json_query "${plan_file}" "d[\"profiles\"][\"${p}\"][\"flash_attn\"]")"
    sched_build_launch "${p}" "${mode}" "${port}" "${ctx}" "${ngl}" "${parallel}" "${fa}"
    svc_write_env "${p}" "$(catalog_engine "${p}")" "${SCHED_EXEC}" "${SCHED_ARGS[@]}"
    svc_start "${p}"
    _sched_write_reservation "${p}" "${mode}" "${port}" "${ram}" "${vram}"
    info "started ${p} (mode=${mode}, port=${port}, reserved ${ram} MiB RAM + ${vram} MiB VRAM)"
  done
  rm -f "${plan_file}"
}

_sched_stop_impl() {
  sched_load_backend
  local -a targets=()
  if [[ "${1:-}" == "all" || "$#" -eq 0 ]]; then
    local r
    while IFS= read -r r; do targets+=("${r}"); done < <(sched_running)
  else
    targets=("$@")
  fi
  local p
  for p in ${targets[@]+"${targets[@]}"}; do
    svc_stop "${p}" || true
    rm -f "$(_sched_run_file "${p}")"
    info "stopped ${p}"
  done
}

sched_switch() {
  local profile="$1"
  sched_stop all >/dev/null
  sched_start "${profile}"
}

# _sched_auto_impl <capability...> - call sched_auto (above) from outside
# this file; this unlocked form exists so the eviction loop and the final
# start happen under one lock acquisition instead of two.
_sched_auto_impl() {
  [[ "$#" -ge 1 ]] || die "usage: llmctl auto <chat|coder|vision> [...]"
  sched_load_backend
  ensure_state_dirs

  local plan_file; plan_file="$(mktemp)"
  hw_probe_json | catalog_plan_json > "${plan_file}"

  local ram_budget vram_budget
  ram_budget="$(json_query "${plan_file}" 'd["budgets"]["ram_mb"]')"
  vram_budget="$(json_query "${plan_file}" 'd["budgets"]["vram_mb"]')"

  # Resolve the desired set: best-ranked recommended profile per capability.
  local -a want=()
  local cap p ranked found
  for cap in "$@"; do
    ranked="$(sched_rank_for_capability "${cap}")" \
      || { rm -f "${plan_file}"; die "unknown capability: ${cap} (chat|coder|vision)"; }
    found=""
    for p in ${ranked}; do
      catalog_exists "${p}" || continue
      [[ " $(catalog_capability "${p}") " == *" ${cap} "* ]] || continue
      [[ "$(json_query "${plan_file}" "d[\"profiles\"][\"${p}\"][\"recommended\"]")" == "True" ]] || continue
      found="${p}"; break
    done
    [[ -n "${found}" ]] || { rm -f "${plan_file}"; die "no catalog profile for capability '${cap}' fits this host (see: llmctl plan)"; }
    want+=("${found}")
    log "capability '${cap}' -> profile '${found}'"
  done

  # Eviction loop: try to fit; if not, evict the LRU non-enabled service.
  local attempt
  for (( attempt=0; attempt<16; attempt++ )); do
    local used_ram used_vram ok=1
    used_ram="$(sched_reserved_field ram_mb)"
    used_vram="$(sched_reserved_field vram_mb)"
    for p in "${want[@]}"; do
      sched_is_running "${p}" && continue
      local need_ram need_vram
      need_ram="$(json_query "${plan_file}" "d[\"profiles\"][\"${p}\"][\"ram_mb\"]")"
      need_vram="$(json_query "${plan_file}" "d[\"profiles\"][\"${p}\"][\"vram_mb\"]")"
      (( used_ram + need_ram <= ram_budget )) || { ok=0; break; }
      (( used_vram + need_vram <= vram_budget )) || { ok=0; break; }
      used_ram=$(( used_ram + need_ram ))
      used_vram=$(( used_vram + need_vram ))
    done
    [[ "${ok}" == "1" ]] && break

    # Find LRU non-enabled running service.
    local lru="" lru_epoch=99999999999 f epoch prof
    for f in "${LLMCTL_RUNTIME_DIR}"/*.run; do
      [[ -e "${f}" ]] || continue
      prof="$(basename "${f}" .run)"
      # Never evict something we are trying to start, or enabled services.
      [[ " ${want[*]} " == *" ${prof} "* ]] && continue
      sched_is_enabled "${prof}" && continue
      epoch="$(sed -n 's/^started_epoch=//p' "${f}" | head -1)"
      if (( ${epoch:-99999999999} < lru_epoch )); then
        lru_epoch="${epoch:-99999999999}"; lru="${prof}"
      fi
    done
    if [[ -z "${lru}" ]]; then
      rm -f "${plan_file}"
      err "cannot satisfy 'auto $*': remaining services are enabled (protected)"
      err "disable one first (llmctl disable <profile>) or use: llmctl switch ${want[0]}"
      return 1
    fi
    warn "auto: evicting '${lru}' (LRU, not enabled) to make room"
    svc_stop "${lru}" || true
    rm -f "$(_sched_run_file "${lru}")"
  done

  rm -f "${plan_file}"
  _sched_start_impl "${want[@]}"
}

# Human-readable status of running services. Surfaces a crash-looped
# profile (restart limit exceeded, systemd/launchd gave up) as
# "failed (crash-loop)" with its last log line, rather than silently
# showing it as just another row (FR-044, Clarification 14).
sched_status() {
  sched_load_backend
  local running; running="$(sched_running)"
  if [[ -z "${running}" ]]; then
    echo "no llmctl services running"
    return 0
  fi
  printf '%-16s %-6s %-8s %-10s %-10s %-8s %s\n' "profile" "port" "mode" "RAM MiB" "VRAM MiB" "enabled" "state"
  local f p port mode ram vram en state
  for f in "${LLMCTL_RUNTIME_DIR}"/*.run; do
    [[ -e "${f}" ]] || continue
    p="$(basename "${f}" .run)"
    port="$(sed -n 's/^port=//p' "${f}")"
    mode="$(sed -n 's/^mode=//p' "${f}")"
    ram="$(sed -n 's/^ram_mb=//p' "${f}")"
    vram="$(sed -n 's/^vram_mb=//p' "${f}")"
    sched_is_enabled "${p}" && en="yes" || en="no"
    if svc_is_failed "${p}" 2>/dev/null; then
      state="failed (crash-loop)"
    else
      state="running"
    fi
    printf '%-16s %-6s %-8s %-10s %-10s %-8s %s\n' "${p}" "${port}" "${mode}" "${ram}" "${vram}" "${en}" "${state}"
    if [[ "${state}" == "failed (crash-loop)" ]]; then
      printf '  last log line: %s\n' "$(tail -n 1 "${LLMCTL_LOG_DIR}/${p}.log" 2>/dev/null || echo "(no log)")"
    fi
  done
}
