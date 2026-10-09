#!/usr/bin/env bash
# lib.sh - shared helpers for the hostsafety toolkit (sourced, never executed).
# Everything is parameterised by environment so tests run against temp dirs and
# fixture files without touching the live host:
#   HOSTSAFETY_MEMINFO   /proc/meminfo substitute
#   HOSTSAFETY_NPROC     CPU count override
# shellcheck shell=bash

hs_memtotal_bytes() {
  local f="${HOSTSAFETY_MEMINFO:-/proc/meminfo}" kb
  kb="$(awk '/^MemTotal:/ {print $2; exit}' "${f}")"
  [[ "${kb}" =~ ^[0-9]+$ && "${kb}" -gt 0 ]] || { echo "hostsafety: cannot read MemTotal from ${f}" >&2; return 1; }
  echo $((kb * 1024))
}

hs_swaptotal_bytes() {
  local f="${HOSTSAFETY_MEMINFO:-/proc/meminfo}" kb
  kb="$(awk '/^SwapTotal:/ {print $2; exit}' "${f}")"
  echo $(( ${kb:-0} * 1024 ))
}

hs_nproc() {
  # online CPUs of the HOST: plain `nproc` honours the caller's cgroup CPUQuota (coreutils >= 9.6),
  # which would make limits depend on whether we run inside a bounded scope
  if [[ -n "${HOSTSAFETY_NPROC:-}" ]]; then echo "${HOSTSAFETY_NPROC}"; else getconf _NPROCESSORS_ONLN; fi
}

hs_clamp() { # value min max
  local v="$1" lo="$2" hi="$3"
  (( v < lo )) && v="${lo}"
  (( v > hi )) && v="${hi}"
  echo "${v}"
}

# hs_min a b
hs_min() { if (( $1 < $2 )); then echo "$1"; else echo "$2"; fi; }

# hs_limits <slice>  -> prints KEY=VALUE lines (bytes / counts) sized from the host.
#   app        : the agent / test / service fleet (tmx-*.scope, app-*.scope, user services)
#   background : low-priority background jobs
#   user       : the user-manager's nested user.slice (rootless podman: conmon, libpod scopes)
# session.slice is deliberately NEVER limited (gnome-shell must stay safe).
hs_limits() {
  local slice="$1" mem swap cpus high_pct max_pct swap_cap tasks_per_cpu tmin tmax
  mem="$(hs_memtotal_bytes)" || return 1
  swap="$(hs_swaptotal_bytes)"
  cpus="$(hs_nproc)"
  case "${slice}" in
    app)        high_pct=70; max_pct=80; swap_cap=$((1024 * 1024 * 1024)); tasks_per_cpu=1024; tmin=4096; tmax=32768 ;;
    background) high_pct=40; max_pct=50; swap_cap=$((512 * 1024 * 1024));  tasks_per_cpu=256;  tmin=1024; tmax=8192 ;;
    user)       high_pct=60; max_pct=75; swap_cap=$((2048 * 1024 * 1024)); tasks_per_cpu=512;  tmin=2048; tmax=16384 ;;
    *) echo "hostsafety: unknown slice '${slice}'" >&2; return 1 ;;
  esac
  swap_cap="$(hs_min "${swap_cap}" $((swap / 4)))"   # never more than 1/4 of the swap device
  echo "MemoryHigh=$((mem * high_pct / 100))"
  echo "MemoryMax=$((mem * max_pct / 100))"
  echo "MemorySwapMax=${swap_cap}"
  echo "TasksMax=$(hs_clamp $((cpus * tasks_per_cpu)) "${tmin}" "${tmax}")"
}

# hs_slice_dropin <slice> -> full drop-in file text
hs_slice_dropin() {
  local slice="$1" mem
  mem="$(hs_memtotal_bytes)" || return 1
  printf '# Managed by hostsafety (llmctl scripts/hostsafety/install.sh) - do not edit by hand.\n'
  printf '# Sized from MemTotal=%s bytes, %s CPUs. Re-run install.sh to re-size; uninstall.sh to remove.\n' "${mem}" "$(hs_nproc)"
  printf '# Rationale: docs/host-safety.md (2026-10-08 swap/PSI hang incident).\n'
  printf '[Slice]\n'
  hs_limits "${slice}"
}

hs_log() { printf 'hostsafety: %s\n' "$*"; }
