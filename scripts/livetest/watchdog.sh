#!/usr/bin/env bash
# watchdog.sh - host-safety watchdog for a live llmctl model test.
#
# Usage: watchdog.sh <profile> <evidence-dir> <parent-pid>
#
# Samples every 2 s: MemAvailable, memory PSI (some avg10), GPU memory used.
# On the FIRST breach of any abort condition it records the trigger and runs
# `llmctl stop <profile>` (its ONLY remedy), then exits 0.
#   MemAvailable < 5000 MiB | PSI some avg10 > 20 | GPU used > 11500 MiB
#   | wall clock > 600 s | parent gone | 3 consecutive unreadable sensors
# It NEVER signals any process, never touches process groups, never reboots.
# Thresholds are fixed; they are only overridable when LT_HERMETIC=1 (tests).
#
# Env overrides (always honoured, they only redirect sensors/commands):
#   LT_MEMINFO  LT_PSI  NVIDIA_SMI_BIN  LLMCTL_BIN
set -uo pipefail

PROFILE="${1:?profile}"; EV="${2:?evidence dir}"; PARENT="${3:?parent pid}"
LLMCTL="${LLMCTL_BIN:-llmctl}"
NVSMI="${NVIDIA_SMI_BIN:-nvidia-smi}"
MEMINFO="${LT_MEMINFO:-/proc/meminfo}"
PSI="${LT_PSI:-/proc/pressure/memory}"

MIN_MEM_MB=5000; MAX_PSI=20; MAX_GPU_MB=11500; MAX_WALL=600; INTERVAL=2
if [ "${LT_HERMETIC:-0}" = "1" ]; then
  MAX_WALL="${LT_WD_MAX_WALL:-$MAX_WALL}"; INTERVAL="${LT_WD_INTERVAL:-$INTERVAL}"
fi

mkdir -p "$EV"
LOG="$EV/watchdog.log"; CSV="$EV/samples.csv"; TRIG="$EV/trigger"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"; }
[ -s "$CSV" ] || echo "utc,elapsed_s,memavail_mb,psi_some_avg10,psi_full_avg10,gpu_used_mb" >"$CSV"

GPU_PID=""; GPU_OUT="$EV/.gpu.$$"
# nvidia-smi can hang under a driver stall: run it detached, wait <= 4 s, never signal it.
read_gpu() {
  GPU_VAL=""
  if [ -n "$GPU_PID" ] && [ -d "/proc/$GPU_PID" ]; then return 1; fi   # previous call still hung
  : >"$GPU_OUT"
  "$NVSMI" --query-gpu=memory.used --format=csv,noheader,nounits >"$GPU_OUT" 2>/dev/null &
  GPU_PID=$!
  for _ in 1 2 3 4 5 6 7 8; do
    [ -d "/proc/$GPU_PID" ] || break
    sleep 0.5
  done
  [ -d "/proc/$GPU_PID" ] && return 1
  GPU_VAL="$(awk 'BEGIN{m=-1} /^[ \t]*[0-9]+[ \t]*$/{if($1+0>m)m=$1+0} END{if(m>=0)print m}' "$GPU_OUT")"
  [ -n "$GPU_VAL" ]
}

fire() {   # fire <reason>
  local reason="$1"
  echo "$reason" >"$TRIG"
  log "TRIGGER: $reason -> llmctl stop $PROFILE"
  "$LLMCTL" stop "$PROFILE" >>"$EV/watchdog.stop.out" 2>&1
  log "llmctl stop $PROFILE rc=$?"
  rm -f "$GPU_OUT"
  exit 0
}

trap 'log "watchdog terminated by parent (clean exit, no action)"; rm -f "$GPU_OUT"; exit 0' TERM INT HUP

T0=$(date +%s); BAD=0
log "watchdog start profile=$PROFILE parent=$PARENT interval=${INTERVAL}s limits: mem<${MIN_MEM_MB}MiB psi>${MAX_PSI} gpu>${MAX_GPU_MB}MiB wall>${MAX_WALL}s"
while :; do
  now=$(date +%s); el=$((now - T0))
  mem=$(awk '/^MemAvailable:/{printf "%d",$2/1024}' "$MEMINFO" 2>/dev/null)
  ps_some=$(awk '$1=="some"{for(i=2;i<=NF;i++)if($i~/^avg10=/){sub("avg10=","",$i);print $i}}' "$PSI" 2>/dev/null)
  ps_full=$(awk '$1=="full"{for(i=2;i<=NF;i++)if($i~/^avg10=/){sub("avg10=","",$i);print $i}}' "$PSI" 2>/dev/null)
  read_gpu; gpu="$GPU_VAL"
  echo "$(date -u +%FT%TZ),$el,${mem:-NA},${ps_some:-NA},${ps_full:-NA},${gpu:-NA}" >>"$CSV"

  if [ -z "$mem" ] || [ -z "$ps_some" ] || [ -z "$gpu" ]; then BAD=$((BAD + 1)); else BAD=0; fi
  [ "$BAD" -ge 3 ] && fire "sensor_unreadable x3 (mem='${mem}' psi='${ps_some}' gpu='${gpu}')"
  [ -n "$mem" ] && [ "$mem" -lt "$MIN_MEM_MB" ] && fire "MemAvailable ${mem} MiB < ${MIN_MEM_MB}"
  [ -n "$ps_some" ] && awk -v p="$ps_some" -v m="$MAX_PSI" 'BEGIN{exit !(p>m)}' && fire "memory PSI some avg10 ${ps_some} > ${MAX_PSI}"
  [ -n "$gpu" ] && [ "$gpu" -gt "$MAX_GPU_MB" ] && fire "GPU used ${gpu} MiB > ${MAX_GPU_MB}"
  [ "$el" -gt "$MAX_WALL" ] && fire "wall clock ${el}s > ${MAX_WALL}"
  [ -d "/proc/$PARENT" ] || fire "parent pid $PARENT vanished"
  sleep "$INTERVAL"
done
