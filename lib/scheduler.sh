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
  # sched_load_backend is idempotent (re-sourcing service_linux.sh/
  # service_macos.sh just redefines the same functions) - called
  # unconditionally here so _sched_reconcile_reservations's svc_is_active
  # call below is always defined, regardless of whether this PUBLIC
  # function is reached via a caller that already loaded the backend
  # (every current caller does) or a future one that has not.
  sched_load_backend
  _sched_reconcile_reservations
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

# _sched_reconcile_reservations - self-heal missing *.run reservation
# records for profiles that are ENABLED and genuinely ACTIVE per the real
# service backend, but have no reservation record on disk.
#
# Root-caused 2026-09-22 (real repro on a rebooted host, not guessed):
# LLMCTL_RUNTIME_DIR defaults to ${XDG_RUNTIME_DIR}/llmctl - a tmpfs
# systemd/PAM deliberately wipe on every reboot. A profile's *.run
# reservation file is ONLY ever (re)written by this file's own code paths
# (_enable_impl / _sched_start_impl, via _sched_write_reservation) - never
# by systemd itself. After a reboot, systemd correctly auto-restarts an
# already-`enabled` persistent service (WantedBy=default.target + user
# lingering) with NO llmctl invocation involved at all, so llmctl's own
# bookkeeping has ZERO record of it being started until `bin/llmctl` runs
# again for that exact profile - `sched_running()`/`llmctl status` then
# wrongly reported "no llmctl services running" for services genuinely
# serving real traffic (independently confirmed on the diagnosing host via
# `systemctl --user list-units`, `ss -tlnp`, and `nvidia-smi`).
#
# This is not merely cosmetic. sched_reserved_field() - which
# _enable_impl's own 2026-09-17 overcommit-safety check reads to compute
# currently-reserved RAM/VRAM before allowing a NEW profile to enable -
# iterates the SAME *.run glob, so immediately after a reboot it silently
# reported ZERO reserved for a profile that was in fact consuming real host
# RAM/VRAM: a later `llmctl enable <new-profile>` could pass that check and
# genuinely overcommit the host - the EXACT failure mode the 2026-09-17 fix
# exists to prevent, reintroduced via a different trigger (post-reboot
# state desync instead of the original unconditional-write bug that fix
# addressed).
#
# Reconstruction reuses the IDENTICAL hw_probe_json | catalog_plan_json +
# json_query derivation _enable_impl already uses for mode/port/ram/vram
# (see _enable_impl below) - never a second, divergent derivation.
#
# A profile that is enabled but NOT genuinely active (crash-looping,
# "activating (auto-restart)", "failed", ...) is deliberately left
# un-reconciled: it is not running and must not be reserved as if it were.
# Idempotent: a profile that already has a reservation record is skipped,
# so a second call touches nothing further.
_sched_reconcile_reservations() {
  [[ -d "${LLMCTL_SERVICES_DIR}" ]] || return 0
  local f profile plan_file=""
  for f in "${LLMCTL_SERVICES_DIR}"/*.enabled; do
    [[ -e "${f}" ]] || continue
    profile="$(basename "${f}" .enabled)"
    [[ -f "$(_sched_run_file "${profile}")" ]] && continue
    catalog_exists "${profile}" || continue
    svc_is_active "${profile}" 2>/dev/null || continue
    if [[ -z "${plan_file}" ]]; then
      plan_file="$(mktemp)"
      hw_probe_json | catalog_plan_json > "${plan_file}"
    fi
    local mode port ram vram
    mode="$(json_query "${plan_file}" "d[\"profiles\"][\"${profile}\"][\"mode\"]")"
    port="$(json_query "${plan_file}" "d[\"profiles\"][\"${profile}\"][\"port\"]")"
    ram="$(json_query "${plan_file}" "d[\"profiles\"][\"${profile}\"][\"ram_mb\"]")"
    vram="$(json_query "${plan_file}" "d[\"profiles\"][\"${profile}\"][\"vram_mb\"]")"
    _sched_write_reservation "${profile}" "${mode}" "${port}" "${ram}" "${vram}"
    # >&2: sched_running() is a data-producing function whose stdout callers
    # parse as a bare list of profile names (e.g. _sched_stop_impl's
    # `while read` loop below) - this progress message must never land on
    # that same stream, or a caller would treat it as a bogus profile name.
    log "reconciled missing reservation for '${profile}' (enabled + genuinely active, no .run marker - likely a post-reboot state desync)" >&2
  done
  # NOT `[[ -n "${plan_file}" ]] && rm -f "${plan_file}"`: as the LAST
  # statement of this function, a bare `cond && cmd` whose condition is
  # false (the common case - nothing needed reconciling) returns THAT
  # nonzero status as the function's own exit status, which aborts the
  # whole calling script under `set -e` the moment any caller invokes this
  # function as a bare statement (as sched_running() does). Reproduced
  # directly: `f() { [[ -f /nonexistent ]] && echo no; }; f; echo after`
  # under `set -euo pipefail` never reaches the `echo after` line. An `if`
  # always returns 0 when its condition is false and there is no `else`,
  # so it carries no such risk.
  if [[ -n "${plan_file}" ]]; then
    rm -f "${plan_file}"
  fi
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
      SCHED_ARGS=(--model "${model}" --host "$(catalog_bind_host "${profile}")" --port "${port}"
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
      # 003-kv-cache-replication T015 (spec.md FR-006/User Story 2): the
      # real llama-server --slot-save-path flag - confirmed present at
      # tools/server/server.cpp:285-286/server-context.cpp:5288-5320+
      # (T060's investigation) - enabling the engine's own real
      # /slots/:id_slot?action=save|restore HTTP endpoint. OPT-IN via
      # LLMCTL_SLOT_SAVE_PATH (matching LLMCTL_SEED's own opt-in-env-var
      # idiom exactly), never baked into every default launch: an
      # always-on engine cache write is an unbounded-disk-growth host-
      # safety concern (Constitution §11.4.133/§12) a deployment must
      # explicitly opt into, not something forced on every profile start.
      #
      # Path is a PER-PROFILE subdirectory of LLMCTL_SLOT_SAVE_PATH
      # (never the bare base directory) so two different profiles'
      # engine processes can never collide on the same slot-cache
      # filename underneath one shared directory - and the directory is
      # created (never assumed pre-existing) before the real engine
      # process, which would otherwise itself fail to start on a missing
      # directory, is ever launched. This is the SAME base directory
      # llmctld's own daemon-side LLMCTL_SLOT_SAVE_PATH env var
      # (cmd/llmctld/main.go's slotSaveDirResolver) resolves a received
      # cross-node engine-cache file into - both sides MUST agree on
      # this one env var for a real warm-restore to ever find the file
      # the engine itself wrote (or received).
      if [[ -n "${LLMCTL_SLOT_SAVE_PATH:-}" ]]; then
        local slot_save_dir="${LLMCTL_SLOT_SAVE_PATH}/${profile}"
        # Created unconditionally, even under LLMCTL_DRY_RUN=1 - unlike
        # the model-file-existence check above (which skips touching the
        # real, potentially-multi-gigabyte model download under dry-run),
        # creating this directory is a cheap, idempotent `mkdir -p` with
        # no meaningful host-safety cost, and doing it here means a
        # dry-run genuinely validates the real path this flag resolves
        # to, rather than only pretending to.
        ensure_dir "${slot_save_dir}"
        SCHED_ARGS+=(--slot-save-path "${slot_save_dir}")
      fi
      SCHED_EXEC="${bin}"
      ;;
    colibri)
      local dir="${LLMCTL_MODELS_DIR}/${profile}"
      if [[ "${LLMCTL_DRY_RUN}" != "1" && ! -d "${dir}" ]]; then
        die "model not downloaded: ${dir}. Run: llmctl models download ${profile}"
      fi
      # Root-caused 2026-09-17 (real repro, not guessed): the bare command
      # "coli" is only resolvable when its pip-installable launcher wrapper
      # has actually been installed onto PATH - `llmctl build colibri`
      # honestly warns "pip not found - skipping 'coli' launcher install"
      # and continues (the two REAL C engines it builds, colibri/qwen36,
      # are unaffected), but the scheduler still defaulted to the bare,
      # now-unresolvable "coli" command with no same-repo fallback - unlike
      # the llama engine, whose SCHED_EXEC already falls back to its own
      # submodule's absolute build path when no override is set. Under
      # systemd this fails LOUDLY (exit 127, "command not found",
      # Restart=always looping every few seconds) rather than silently -
      # but `llmctl start`/`switch`/`enable` still reported a clean
      # "started" because systemd's own start-transition succeeds
      # regardless of what the unit's Restart=always loop does next; only
      # checking `systemctl status`/the real port caught it. The `coli`
      # script itself is a plain, already-executable (shebang + +x) Python
      # file living in the SAME submodule tree python3 can run directly
      # with zero installation - confirmed empirically (`coli --help`
      # printed real usage from the in-repo path before this default was
      # wired in) - so it gets the identical same-repo-path fallback the
      # llama engine already has, never requiring the pip install step at
      # all for the common case.
      SCHED_EXEC="${LLMCTL_COLI_BIN:-${LLMCTL_ROOT}/submodules/colibri/c/coli}"
      SCHED_ARGS=(serve --model "${dir}" --host "$(catalog_bind_host "${profile}")" --port "${port}")
      # KNOWN INTERACTION, discovered + confirmed live 2026-09-22, deliberately
      # NOT silently worked around here: the colibri engine itself
      # (submodules/colibri/c/openai_server.py's serve()) carries its own,
      # independent fail-closed "#SEC-6" guard - it refuses to bind any host
      # outside 127.0.0.1/localhost/::1 unless an API key or
      # COLI_ALLOW_INSECURE_BIND=1 is set, exiting 1 with "refusing to bind
      # <host> beyond localhost without COLI_API_KEY set (set
      # COLI_ALLOW_INSECURE_BIND=1 to override)". So under this project's own
      # LAN-accessible default (LLMCTL_BIND_HOST=0.0.0.0), a colibri profile
      # (colibri-glm, colibri-qwen36) will fail to start (crash-loop, with
      # that exact message in `llmctl logs`/`status`) UNLESS the operator
      # explicitly sets COLI_ALLOW_INSECURE_BIND=1 in that service's
      # environment themselves, or reverts just that profile to loopback-only
      # via LLMCTL_BIND_HOST_<PROFILE> (see catalog_bind_host). llmctl
      # deliberately does NOT set COLI_ALLOW_INSECURE_BIND=1 automatically -
      # silently overriding a component's own explicit, independently-
      # designed security control on the operator's behalf is a materially
      # different (and more consequential) decision than choosing llmctl's
      # OWN default, and belongs to the operator, not to this scheduler.
      # See README.md "Safety guarantees" for the full disclosure.
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
sched_start()  { scheduler::with_lock _sched_start_impl "$@"; }
sched_stop()   { scheduler::with_lock _sched_stop_impl "$@"; }
sched_auto()   { scheduler::with_lock _sched_auto_impl "$@"; }
sched_enable() { scheduler::with_lock _enable_impl "$@"; }

# _sched_start_impl <profile...> - returns non-zero (with a clear message)
# when the combined footprint does not fit. Call sched_start (above) from
# outside this file; this unlocked form exists so sched_auto can compose it
# under a single lock acquisition.
_sched_start_impl() {
  [[ "$#" -ge 1 ]] || die "usage: llmctl start <profile> [more...]"
  sched_load_backend
  ensure_state_dirs
  # Reconcile any post-reboot state desync BEFORE the budget check below
  # reads sched_reserved_field - see _sched_reconcile_reservations.
  sched_running >/dev/null

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
      # Only suggest 'switch' when something else is ACTUALLY running to
      # free room from - a real, live-hit bug (2026-09-22) suggested
      # "llmctl switch ${p}" even when called FROM INSIDE llmctl switch
      # itself (which had already stopped everything before reaching this
      # check), telling the operator to run the EXACT command that had
      # just failed. When nothing else is running, the real, honest
      # constraint is the HOST's own available RAM/VRAM, which switching
      # cannot create more of.
      if [[ -n "$(sched_running)" ]]; then
        err "or free room by stopping another running profile: llmctl switch ${p}"
      else
        err "no other llmctl profile is running to free up - this host's own available RAM/VRAM is currently too low (see: llmctl hw). Free host memory (close other applications) and retry, or choose a smaller profile."
      fi
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
    # Root-caused 2026-09-17 (real repro, not guessed): this whole function
    # runs as the `command` operand of `scheduler::with_lock`'s
    # `"$@" || rc=$?`, and bash disables `set -e` propagation for the ENTIRE
    # nested call tree of a command tested by `||`/`&&`/`if` - so a bare
    # `svc_start "${p}"` here that fails (e.g. `systemctl --user start`
    # reporting "Unit ... not found" because `llmctl install` was never run)
    # was previously swallowed silently: execution fell through to
    # `_sched_write_reservation` + the "started" info line regardless,
    # so a profile with NO real running process/unit was reported as
    # started and the scheduler's budget accounting reserved RAM/VRAM for
    # nothing. Reproduced directly: `bash -c 'set -e; f(){ false; echo
    # ok; }; f || rc=$?; echo "rc=$rc"'` prints "ok" and "rc=0" - `false`
    # never halts `f`, and `f`'s own exit status is 0 because its LAST
    # command (the echo) succeeded. The fix is an EXPLICIT exit-code
    # check (which works correctly regardless of errexit context, because
    # testing the status directly IS the point): a failed start is
    # reported honestly and NEVER reserved as running.
    if ! svc_start "${p}"; then
      err "failed to start '${p}': the service backend refused to start it (see: llmctl logs ${p}; on Linux, check 'llmctl install' has been run and 'systemctl --user status llmctl-$(catalog_engine "${p}")@${p}.service')"
      rm -f "${plan_file}"
      return 1
    fi
    _sched_write_reservation "${p}" "${mode}" "${port}" "${ram}" "${vram}"
    info "started ${p} (mode=${mode}, port=${port}, reserved ${ram} MiB RAM + ${vram} MiB VRAM)"
  done
  rm -f "${plan_file}"
}

# _enable_impl <profile> - write env (from a fresh plan footprint) + enable +
# start a PERSISTENT (systemd/launchd) service. Call sched_enable (below) from
# outside this file; this unlocked form exists so the budget check below runs
# under the SAME scheduler lock `start` already holds for the identical
# read-budget-then-write-reservation sequence.
#
# Locking (independent review, 2026-09-17): the budget check this function
# performs used to run directly in `bin/llmctl`'s `enable)` case with NO lock
# held at all - a genuine TOCTOU: `scheduler::with_lock`'s own header comment
# states the lock exists precisely "so two concurrent llmctl invocations …
# never interleave their read-budgets-then-write-reservation sequence … it
# never proceeds on a stale read" - and an unlocked check-then-act is exactly
# that interleaving, unchanged by adding a check that itself races. Moving
# this into an `_impl` dispatched via `scheduler::with_lock` (mirroring
# `_sched_start_impl`) closes it the same way `start` is already closed.
_enable_impl() {
  local profile="$1"
  catalog_exists "${profile}" || die "unknown profile: ${profile} (see: llmctl models list)"
  sched_load_backend
  # Reconcile any post-reboot state desync BEFORE the overcommit check below
  # reads sched_reserved_field - otherwise a genuinely-running-but-
  # unreconciled enabled profile (see _sched_reconcile_reservations) would
  # read as zero RAM/VRAM reserved and this check could pass on stale
  # accounting, exactly the overcommit the 2026-09-17 fix below exists to
  # prevent.
  sched_running >/dev/null
  local plan_file; plan_file="$(mktemp)"
  hw_probe_json | catalog_plan_json > "${plan_file}"
  local mode port ctx ngl parallel fa ram vram
  mode="$(json_query "${plan_file}" "d[\"profiles\"][\"${profile}\"][\"mode\"]")"
  port="$(json_query "${plan_file}" "d[\"profiles\"][\"${profile}\"][\"port\"]")"
  ctx="$(json_query "${plan_file}" "d[\"profiles\"][\"${profile}\"][\"ctx\"]")"
  ngl="$(json_query "${plan_file}" "d[\"profiles\"][\"${profile}\"][\"ngl\"]")"
  parallel="$(json_query "${plan_file}" "d[\"profiles\"][\"${profile}\"][\"parallel\"]")"
  fa="$(json_query "${plan_file}" "d[\"profiles\"][\"${profile}\"][\"flash_attn\"]")"
  ram="$(json_query "${plan_file}" "d[\"profiles\"][\"${profile}\"][\"ram_mb\"]")"
  vram="$(json_query "${plan_file}" "d[\"profiles\"][\"${profile}\"][\"vram_mb\"]")"
  # Root-caused 2026-09-17 (real repro, not guessed): unlike `llmctl start`,
  # which checks the combined RAM/VRAM footprint of every currently-reserved
  # profile against the host's own computed budget (_sched_start_impl above)
  # before starting anything, `enable` computed and wrote a reservation for
  # the NEW profile completely unconditionally - it never looked at what was
  # already reserved. Reproduced directly on this host (30974 MiB total RAM,
  # plan's own stated safe budget 20897 MiB): sequentially `enable`-ing
  # small+vision+vision-pro+moe-fast reserved/ran ~24.9 GiB combined RSS -
  # already over the plan's own budget - and drove the host's 8 GiB swap to
  # fully exhausted while `llmctl status`/`enable` kept reporting each step
  # as a clean success. This check makes `enable` respect the SAME budget
  # `start` already enforces, refusing (with the actual numbers, and without
  # writing an env file, touching the systemd unit, or reserving anything)
  # rather than silently overcommitting host memory.
  if ! sched_is_running "${profile}"; then
    local ram_budget vram_budget used_ram used_vram
    ram_budget="$(json_query "${plan_file}" 'd["budgets"]["ram_mb"]')"
    vram_budget="$(json_query "${plan_file}" 'd["budgets"]["vram_mb"]')"
    used_ram="$(sched_reserved_field ram_mb)"
    used_vram="$(sched_reserved_field vram_mb)"
    if (( used_ram + ram > ram_budget )) || (( used_vram + vram > vram_budget )); then
      rm -f "${plan_file}"
      err "cannot enable '${profile}': needs ${ram} MiB RAM + ${vram} MiB VRAM, but only $(( ram_budget - used_ram )) MiB RAM + $(( vram_budget - used_vram )) MiB VRAM remain within the host budget (stop another enabled profile first, e.g. 'llmctl disable <profile>', or use 'llmctl start ${profile}' on demand instead of a persistent enable)"
      return 1
    fi
  fi
  rm -f "${plan_file}"
  sched_build_launch "${profile}" "${mode}" "${port}" "${ctx}" "${ngl}" "${parallel}" "${fa}"
  svc_write_env "${profile}" "$(catalog_engine "${profile}")" "${SCHED_EXEC}" "${SCHED_ARGS[@]}"
  touch "${LLMCTL_SERVICES_DIR}/${profile}.enabled"
  if ! svc_enable "${profile}"; then
    err "failed to enable '${profile}': the service backend refused to enable/start it (see: llmctl logs ${profile})"
    return 1
  fi
  # Record the reservation so the scheduler budgets correctly (enable
  # implies start).
  ensure_dir "${LLMCTL_RUNTIME_DIR}"
  _sched_write_reservation "${profile}" "${mode}" "${port}" "${ram}" "${vram}"
  info "enabled and started ${profile} (mode=${mode}, port=${port})"
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

# sched_switch <profile> - the public, locking entrypoint (mirrors
# sched_start/sched_stop/sched_auto above - see their shared header
# comment on why a switch-shaped operation must run as ONE atomic locked
# unit, never as two separate public sched_stop + sched_start calls).
sched_switch() { scheduler::with_lock _sched_switch_impl "$@"; }

# _sched_switch_impl <profile> - stops every currently-running profile and
# starts <profile> instead. SAFETY (fixed 2026-09-22, real live incident,
# not guessed): a failed switch MUST NEVER leave the host with fewer
# running services than before the switch was attempted. Reproduced live:
# `llmctl switch fast` on a RAM-constrained host stopped the
# then-healthy, then-serving small+vision, failed to start fast (real
# cause: this host's own free RAM was below llmctl's safety margin -
# stopping small+vision did not create enough headroom), and left the
# host with LITERALLY ZERO llmctl services running - `llmctl status`
# reported "no llmctl services running" and there was no automatic
# recovery; restoring service required a manual `llmctl start small`.
# The fix: snapshot the currently-running set BEFORE stopping anything;
# if starting the target profile fails for ANY reason (budget gate,
# systemd refusing the unit, anything _sched_start_impl can return
# nonzero for), automatically restore the snapshotted set (best-effort)
# before propagating the ORIGINAL failure - so a failed switch attempt
# is, at worst, a no-op from the operator's point of view, never a
# regression from "something is running" to "nothing is running".
# Also a no-op (skips the stop+restart entirely) when <profile> is
# ALREADY the sole running profile, avoiding a needless model-reload.
_sched_switch_impl() {
  [[ "$#" -eq 1 ]] || die "usage: llmctl switch <profile>"
  local target="$1"
  sched_load_backend
  catalog_exists "${target}" || die "unknown profile: ${target} (see: llmctl models list)"

  local -a previously_running=()
  local r
  while IFS= read -r r; do previously_running+=("${r}"); done < <(sched_running)

  if [[ "${#previously_running[@]}" -eq 1 && "${previously_running[0]}" == "${target}" ]]; then
    info "${target} is already the only running profile - nothing to switch"
    return 0
  fi

  _sched_stop_impl all

  local start_rc=0
  _sched_start_impl "${target}" || start_rc=$?
  [[ "${start_rc}" -eq 0 ]] && return 0

  err "switch to '${target}' failed - restoring the previously-running set: ${previously_running[*]:-<none>}"
  if [[ "${#previously_running[@]}" -gt 0 ]]; then
    local rollback_rc=0
    _sched_start_impl "${previously_running[@]}" || rollback_rc=$?
    if [[ "${rollback_rc}" -eq 0 ]]; then
      err "rollback succeeded - the previously-running profile(s) are running again"
    else
      err "ROLLBACK ALSO FAILED - the host may have fewer services running than before this switch attempt. Check: llmctl status"
    fi
  fi
  return "${start_rc}"
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
