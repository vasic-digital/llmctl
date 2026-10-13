#!/usr/bin/env bash
# install.sh - idempotent, reversible installer for the hostsafety user-level safeguards.
#
#   install.sh [install] [--dry-run] [--no-guard] [--no-tracker]
#   install.sh uninstall [--dry-run]
#   install.sh verify            # read back effective cgroup values / unit state
#
# What `install` changes (printed as it goes; nothing else is touched):
#   ~/.config/systemd/user/{app,background,user}.slice.d/10-hostsafety.conf   slice limits
#   ~/.local/bin/{bounded-run,agent-run,hostsafety-podman-audit,hostsafety-tracker-exclude}
#   ~/.local/share/hostsafety/{lib.sh,guard.py}                               installed copies
#   ~/.config/systemd/user/hostsafety-guard.{service,timer}                   guard (DRY-RUN by default)
#   ~/.config/hostsafety/guard.env                                            only if absent (arming switch)
#   gsettings org.freedesktop.Tracker3.Miner.Files ignored-directories (+ ~/go/pkg/mod/.trackerignore)
# Any pre-existing file that would be overwritten is first copied to
# ~/.local/share/hostsafety-backup/<timestamp>/ .  session.slice is never touched.
#
# Test/override env: HOSTSAFETY_CONFIG_HOME HOSTSAFETY_DATA_HOME HOSTSAFETY_BIN_DIR
# HOSTSAFETY_BACKUP_DIR HOSTSAFETY_STATE_HOME HOSTSAFETY_NO_SYSTEMCTL=1 HOSTSAFETY_NO_TRACKER=1
set -uo pipefail
src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${src}/lib.sh"

CONFIG_HOME="${HOSTSAFETY_CONFIG_HOME:-${XDG_CONFIG_HOME:-${HOME}/.config}}"
DATA_HOME="${HOSTSAFETY_DATA_HOME:-${XDG_DATA_HOME:-${HOME}/.local/share}}"
BIN_DIR="${HOSTSAFETY_BIN_DIR:-${HOME}/.local/bin}"
BACKUP_ROOT="${HOSTSAFETY_BACKUP_DIR:-${HOME}/.local/share/hostsafety-backup}"
UNIT_DIR="${CONFIG_HOME}/systemd/user"
SHARE="${DATA_HOME}/hostsafety"
MANIFEST="${SHARE}/manifest"
STAMP="$(date +%Y%m%dT%H%M%S)"
SLICES=(app background user)

cmd="install"; dry=0; do_guard=1; do_tracker=1
if [[ "${1:-}" =~ ^(install|uninstall|verify)$ ]]; then cmd="$1"; shift; fi
for a in "$@"; do
  case "${a}" in
    --dry-run) dry=1 ;; --no-guard) do_guard=0 ;; --no-tracker) do_tracker=0 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "install.sh: unknown argument ${a}" >&2; exit 2 ;;
  esac
done
[[ "${HOSTSAFETY_NO_TRACKER:-0}" == 1 ]] && do_tracker=0
sysctl_user() { [[ "${HOSTSAFETY_NO_SYSTEMCTL:-0}" == 1 ]] && return 0; systemctl --user "$@"; }

changed=0
# manifest lines: "<path>" (created by us) or "<path><TAB>orig=<backup>" (a file that existed BEFORE our first
# install; only those are restored on uninstall - never our own earlier generated copies).
TAB=$'\t'
manifest_has() { grep -qE "^$(printf '%s' "$1" | sed 's/[][\.*^$/]/\\&/g')(${TAB}|\$)" "${MANIFEST}" 2>/dev/null; }

# put_file <dest> <mode> <content-from-stdin> [keep]   (idempotent; backs up what it replaces; "keep" = operator
# config: written only when absent and NOT recorded in the manifest, so uninstall leaves it in place)
put_file() {
  local dest="$1" mode="$2" keep="${3:-}" new cur orig=""
  new="$(mktemp)"; cat >"${new}"
  if [[ -f "${dest}" ]] && cmp -s "${new}" "${dest}" && [[ "$(stat -c %a "${dest}")" == "${mode}" ]]; then
    hs_log "unchanged  ${dest}"; rm -f "${new}"; return 0
  fi
  changed=1
  if (( dry )); then hs_log "WOULD write ${dest} (mode ${mode})$([[ -e ${dest} ]] && echo ', backing up the existing file')"; rm -f "${new}"; return 0; fi
  if [[ -e "${dest}" ]]; then
    cur="${BACKUP_ROOT}/${STAMP}${dest}"
    while [[ -e "${cur}" ]]; do cur="${cur}.again"; done      # two runs in the same second must not overwrite a backup
    mkdir -p "$(dirname "${cur}")" && cp -p "${dest}" "${cur}"
    hs_log "backed up  ${dest} -> ${cur}"
    if ! manifest_has "${dest}"; then          # first-ever install over a file that was not ours: keep THE original
      orig="${SHARE}/orig${dest}"
      mkdir -p "$(dirname "${orig}")" && cp -p "${dest}" "${orig}"
    fi
  fi
  mkdir -p "$(dirname "${dest}")"
  install -m "${mode}" "${new}" "${dest}"; rm -f "${new}"
  hs_log "wrote      ${dest}"
  [[ -n "${keep}" ]] && return 0
  mkdir -p "${SHARE}"
  manifest_has "${dest}" || printf '%s%s\n' "${dest}" "${orig:+${TAB}orig=${orig}}" >>"${MANIFEST}"
}

guard_service() {
  cat <<UNIT
# Managed by hostsafety. Memory-pressure guard (one pass per activation).
[Unit]
Description=hostsafety memory-pressure guard (dry-run unless armed in guard.env)
Documentation=file://${src}/../../docs/host-safety.md

[Service]
Type=oneshot
# session.slice is never limited, so the guard cannot be throttled by the slices it protects
Slice=session.slice
EnvironmentFile=-%h/.config/hostsafety/guard.env
ExecStart=/usr/bin/python3 -I %h/.local/share/hostsafety/guard.py
# TimeoutStartSec is the ONLY wall-clock cap that works for Type=oneshot (RuntimeMaxSec is ignored for oneshot units:
# systemd.service(5); probed: RuntimeMaxSec=3 ignored, TimeoutStartSec=3 enforced)
TimeoutStartSec=15
# the guard must cost (almost) nothing and never become the load it watches (incident 2026-10-13): lowest CPU/IO
# priority and a small memory cap
Nice=19
IOSchedulingClass=idle
CPUWeight=10
MemoryMax=256M
StandardOutput=journal
StandardError=journal
UNIT
}
guard_timer() {
  cat <<'UNIT'
# Managed by hostsafety.
[Unit]
Description=hostsafety memory-pressure guard timer

[Timer]
OnBootSec=30s
OnUnitActiveSec=10s
AccuracySec=1s

[Install]
WantedBy=timers.target
UNIT
}
guard_env() {
  cat <<'ENV'
# hostsafety guard configuration (kept across re-installs; edit freely).
# The guard starts in DRY-RUN: it logs "would-kill" decisions to
# ~/.local/state/hostsafety/guard.log and the journal but signals nothing.
# Arm it only after reviewing those decisions:
HOSTSAFETY_GUARD_ARM=0
# Optional tuning (defaults shown):
#HOSTSAFETY_PSI_FULL=25
#HOSTSAFETY_PSI_SOME=10
#HOSTSAFETY_SWAP_FREE_PCT=10
#HOSTSAFETY_CONSECUTIVE=2
#HOSTSAFETY_COOLDOWN_S=20
ENV
}

do_install() {
  hs_log "host: MemTotal=$(hs_memtotal_bytes) bytes, $(hs_nproc) CPUs  (dry-run=${dry})"
  local s
  for s in "${SLICES[@]}"; do
    local unit="${s}.slice"
    put_file "${UNIT_DIR}/${unit}.d/10-hostsafety.conf" 644 < <(hs_slice_dropin "${s}")
  done
  put_file "${BIN_DIR}/bounded-run" 755 <"${src}/bounded-run"
  put_file "${BIN_DIR}/agent-run" 755 <"${src}/agent-run"
  put_file "${BIN_DIR}/hostsafety-podman-audit" 755 <"${src}/podman-audit.sh"
  put_file "${BIN_DIR}/hostsafety-tracker-exclude" 755 <"${src}/tracker-exclude.sh"
  put_file "${SHARE}/lib.sh" 644 <"${src}/lib.sh"
  put_file "${SHARE}/guard.py" 755 <"${src}/guard.py"
  if (( do_guard )); then
    put_file "${UNIT_DIR}/hostsafety-guard.service" 644 < <(guard_service)
    put_file "${UNIT_DIR}/hostsafety-guard.timer" 644 < <(guard_timer)
    if [[ ! -e "${CONFIG_HOME}/hostsafety/guard.env" ]]; then
      put_file "${CONFIG_HOME}/hostsafety/guard.env" 600 keep < <(guard_env)
    else hs_log "kept       ${CONFIG_HOME}/hostsafety/guard.env (never overwritten)"; fi
  fi
  if (( dry )); then
    (( do_tracker )) && "${src}/tracker-exclude.sh" --dry-run
    hs_log "dry-run: no systemctl actions taken"; return 0
  fi
  if (( changed )); then
    sysctl_user daemon-reload && hs_log "systemctl --user daemon-reload"
  fi
  if (( do_guard )); then
    sysctl_user enable --now hostsafety-guard.timer 2>&1 | sed 's/^/hostsafety: /' || true
  fi
  if (( do_tracker )); then "${src}/tracker-exclude.sh" || hs_log "tracker exclusion skipped/failed (non-fatal)"; fi
  do_verify || true
}

fmt_bytes() { if [[ "$1" =~ ^[0-9]+$ ]]; then echo "$1 ($(( $1 / 1048576 )) MiB)"; else echo "$1"; fi; }

# do_verify: are the INSTALLED limits the ones systemd actually applies?
#   effective (systemctl show) must equal the value in the installed drop-in, byte for byte - that is the
#   question "did the install take effect". The drop-in is sized once, at install time, from MemTotal; MemTotal
#   itself drifts by a few kB between boots (kernel-reserved memory), so re-deriving the target from the CURRENT
#   /proc/meminfo and demanding equality reported a false MISMATCH (live: 8 kB => ~5 KiB per limit). The fresh
#   sizing is only used to flag STALE drop-ins (host re-sized: RAM/swap change), with a 1% tolerance on the
#   byte limits; TasksMax is derived from the CPU count and must match exactly.
do_verify() {
  local s rc=0 line k v want inst f diff want_all n
  [[ "${HOSTSAFETY_NO_SYSTEMCTL:-0}" == 1 ]] && { hs_log "verify skipped (HOSTSAFETY_NO_SYSTEMCTL=1)"; return 0; }
  for s in "${SLICES[@]}"; do
    f="${UNIT_DIR}/${s}.slice.d/10-hostsafety.conf"
    if [[ ! -f "${f}" ]]; then hs_log "MISMATCH   ${s}.slice: drop-in ${f} is not installed"; rc=1; continue; fi
    # capture first: a failing hs_limits inside `done < <(...)` would yield zero lines and verify nothing
    if ! want_all="$(hs_limits "${s}" 2>&1)"; then
      hs_log "MISMATCH   ${s}.slice: cannot derive expected limits (${want_all}); nothing verified"; rc=1; continue
    fi
    n="$(printf '%s\n' "${want_all}" | grep -c '^[A-Za-z]*=[0-9]\+$' || true)"
    if (( n < 4 )); then hs_log "MISMATCH   ${s}.slice: cannot derive expected limits (got ${n} of 4 keys); nothing verified"; rc=1; continue; fi
    while IFS= read -r line; do
      k="${line%%=*}"; want="${line#*=}"
      inst="$(sed -n "s/^${k}=//p" "${f}" | tail -1)"
      v="$(systemctl --user show "${s}.slice" -p "${k}" --value)"
      if [[ -z "${inst}" ]]; then hs_log "MISMATCH   ${s}.slice ${k}: not set in ${f}"; rc=1; continue; fi
      if [[ "${v}" != "${inst}" ]]; then
        hs_log "MISMATCH   ${s}.slice ${k}: installed ${inst}, effective ${v}"; rc=1; continue
      fi
      if ! [[ "${inst}" =~ ^[0-9]+$ && "${v}" =~ ^[0-9]+$ && "${want}" =~ ^[0-9]+$ ]]; then
        hs_log "MISMATCH   ${s}.slice ${k}: not a number (installed ${inst}, effective ${v}); cannot verify"; rc=1; continue
      fi
      if [[ "${k}" == TasksMax ]]; then diff=$(( want == inst ? 0 : 1 ))
      else diff=$(( (want > inst ? want - inst : inst - want) * 100 > inst ? 1 : 0 )); fi
      if (( diff )); then hs_log "MISMATCH   ${s}.slice ${k}: installed ${inst} is stale, this host now sizes ${want}; re-run install.sh"; rc=1
      else hs_log "verified   ${s}.slice ${k}=$(fmt_bytes "${v}")"; fi
    done <<<"${want_all}"
  done
  hs_log "guard timer: $(systemctl --user is-active hostsafety-guard.timer 2>&1) / $(systemctl --user is-enabled hostsafety-guard.timer 2>&1)"
  return "${rc}"
}

do_uninstall() {
  [[ -f "${MANIFEST}" ]] || { hs_log "nothing to uninstall (no manifest at ${MANIFEST})"; return 0; }
  local f orig line
  sysctl_user disable --now hostsafety-guard.timer >/dev/null 2>&1 || true
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    f="${line%%"${TAB}"*}"; orig=""
    [[ "${line}" == *"${TAB}orig="* ]] && orig="${line#*"${TAB}orig="}"
    # guard.env is operator configuration: never removed (older manifests may list it)
    if [[ "${f}" == "${CONFIG_HOME}/hostsafety/guard.env" ]]; then hs_log "kept       ${f} (operator config)"; continue; fi
    if (( dry )); then hs_log "WOULD remove ${f}${orig:+ and restore ${orig}}"; continue; fi
    rm -f "${f}"; hs_log "removed    ${f}"
    if [[ -n "${orig}" && -e "${orig}" ]]; then cp -p "${orig}" "${f}" && hs_log "restored   ${f} <- ${orig} (it existed before the first install)"; fi
    rmdir "$(dirname "${f}")" 2>/dev/null || true
  done <"${MANIFEST}"
  (( dry )) && return 0
  rm -f "${MANIFEST}"; rm -rf "${SHARE}/orig"; rmdir "${SHARE}" 2>/dev/null || true
  [[ "${HOSTSAFETY_NO_TRACKER:-0}" == 1 ]] || "${src}/tracker-exclude.sh" --revert || true
  sysctl_user daemon-reload && hs_log "systemctl --user daemon-reload"
  hs_log "uninstalled (operator config ${CONFIG_HOME}/hostsafety/guard.env, logs and backups left in place)"
}

case "${cmd}" in
  install) do_install ;;
  uninstall) do_uninstall ;;
  verify) do_verify ;;
esac
