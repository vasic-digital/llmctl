#!/usr/bin/env bash
# watchdog.sh - host-safety watchdog for a live llmctl model test.
#
# Usage: watchdog.sh <profile> <evidence-dir> <parent-pid>
#        watchdog.sh --stop <profile> <evidence-dir>     (one bounded stop, used by the driver's cleanup)
#
# Stop = `llmctl stop` bounded to 20 s (it queues behind the scheduler flock that `llmctl start`
# holds while loading), then, if that did not return rc 0, `systemctl --user stop <real unit>`
# (llmctl-<engine>@<instance>.service, engine from the unit env file; systemd does the killing,
# we signal nothing). Exit of --stop mode: 0 llmctl stop ok | 10 only the systemd fallback worked | 11 both failed.
#
# Samples every 2 s: MemAvailable, memory PSI (some+full avg10), IO PSI (some+full avg10), GPU memory used.
# On the FIRST breach of any abort condition it records the trigger and runs
# `llmctl stop <profile>` (its ONLY remedy), then exits 0.
#   MemAvailable < 5000 MiB | memory PSI some avg10 > 20 | memory PSI full avg10 > 10
#   | IO PSI some avg10 > 60 | IO PSI full avg10 > 30 | GPU used > 11500 MiB
#   | wall clock > 600 s | parent gone | 3 consecutive unreadable sensors
# It NEVER signals any process, never touches process groups, never reboots.
# Thresholds are fixed. Thresholds, timings AND every sensor/binary redirection
# (LT_MEMINFO LT_PSI LT_IOPSI NVIDIA_SMI_BIN LLMCTL_BIN SYSTEMCTL_BIN) are honoured ONLY when LT_HERMETIC=1
# (hermetic tests); otherwise they are ignored.
set -uo pipefail

MODE=watch
if [ "${1:-}" = "--stop" ]; then MODE=stop; shift; PARENT=0; fi
PROFILE="${1:?profile}"; EV="${2:?evidence dir}"; [ "$MODE" = stop ] || PARENT="${3:?parent pid}"
SYSTEMCTL=systemctl
LLMCTL=llmctl; NVSMI=nvidia-smi; MEMINFO=/proc/meminfo; PSI=/proc/pressure/memory; IOPSI=/proc/pressure/io
if [ "${LT_HERMETIC:-0}" = "1" ]; then
  LLMCTL="${LLMCTL_BIN:-llmctl}"; NVSMI="${NVIDIA_SMI_BIN:-nvidia-smi}"; SYSTEMCTL="${SYSTEMCTL_BIN:-systemctl}"
  MEMINFO="${LT_MEMINFO:-/proc/meminfo}"; PSI="${LT_PSI:-/proc/pressure/memory}"; IOPSI="${LT_IOPSI:-/proc/pressure/io}"
fi
umask 077

MIN_MEM_MB=5000; MAX_PSI=20; MAX_PSI_FULL=10; MAX_IO_SOME=60; MAX_IO_FULL=30; MAX_GPU_MB=11500; MAX_WALL=600; INTERVAL=2; STOP_BOUND=20; POSTFIRE=60
if [ "${LT_HERMETIC:-0}" = "1" ]; then
  STOP_BOUND="${LT_STOP_BOUND:-$STOP_BOUND}"; POSTFIRE="${LT_POSTFIRE:-$POSTFIRE}"; MAX_WALL="${LT_WD_MAX_WALL:-$MAX_WALL}"; INTERVAL="${LT_WD_INTERVAL:-$INTERVAL}"
fi

mkdir -p "$EV"
LOG="$EV/watchdog.log"; CSV="$EV/samples.csv"; TRIG="$EV/trigger"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"; }
[ -s "$CSV" ] || echo "utc,elapsed_s,memavail_mb,psi_some_avg10,psi_full_avg10,io_some_avg10,io_full_avg10,gpu_used_mb" >"$CSV"


# run a command detached with a deadline; never signals it. rc 124 = still running at the deadline.
run_bounded() {   # run_bounded <secs> <outfile> cmd...
  local secs="$1" out="$2" i=0; shift 2
  rm -f "$out.rc"
  ( "$@" >"$out" 2>&1; echo $? >"$out.rc" ) &
  while [ ! -s "$out.rc" ] && [ "$i" -lt $((secs * 10)) ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$out.rc" ] || return 124
  return "$(cat "$out.rc")"
}
unit_name() {   # mirrors lib/service_linux.sh _svc_unit_for: llmctl-<engine>@<instance>.service
  local inst="$PROFILE" envf engine
  [ -n "${LLMCTL_TENANT_ID:-}" ] && inst="${LLMCTL_TENANT_ID}--${PROFILE}"
  envf="${LLMCTL_SERVICES_DIR:-${LLMCTL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/llmctl}/services}/${inst}.env"
  engine="$(sed -n 's/^LLMCTL_ENGINE=//p' "$envf" 2>/dev/null | tr -d "'")"
  echo "llmctl-${engine:-llama}@${inst}.service"
}
bounded_stop() {
  local rc rc2 unit
  run_bounded "$STOP_BOUND" "$EV/stop.llmctl.$$.out" "$LLMCTL" stop "$PROFILE"; rc=$?
  log "llmctl stop $PROFILE rc=$rc (bound ${STOP_BOUND}s)"
  [ "$rc" = 0 ] && return 0
  unit="$(unit_name)"
  log "fallback: llmctl stop did not return rc 0 (likely queued behind the scheduler lock) -> systemctl --user stop $unit"
  run_bounded "$STOP_BOUND" "$EV/stop.systemd.$$.out" "$SYSTEMCTL" --user stop "$unit"; rc2=$?
  log "systemd stop rc=$rc2"
  [ "$rc2" = 0 ] && return 10
  return 11
}
if [ "$MODE" = stop ]; then bounded_stop; exit $?; fi

parent_gone() {   # missing, or a zombie (state Z): a killed-but-unreaped driver still has a /proc entry
  local st
  [ -r "/proc/$PARENT/stat" ] || return 0
  st="$(sed 's/^.*) //' "/proc/$PARENT/stat" 2>/dev/null | cut -c1)"
  [ -z "$st" ] || [ "$st" = Z ] || [ "$st" = X ]
}

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
  log "TRIGGER: $reason -> bounded stop of $PROFILE"
  bounded_stop
  # A background `llmctl start` may reach svc_start only AFTER this stop (the stop then hit a not-yet-started unit):
  # keep watching the unit for POSTFIRE seconds and stop it again if it comes up.
  local i st unit; unit="$(unit_name)"
  for i in $(seq 1 "$POSTFIRE"); do
    run_bounded 5 "$EV/postfire.$$.out" "$SYSTEMCTL" --user is-active "$unit"
    st="$(head -1 "$EV/postfire.$$.out" 2>/dev/null)"
    if [ "$st" = active ] || [ "$st" = activating ]; then log "post-fire: $unit is $st -> stopping again"; bounded_stop; fi
    sleep 1
  done
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
  io_some=$(awk '$1=="some"{for(i=2;i<=NF;i++)if($i~/^avg10=/){sub("avg10=","",$i);print $i}}' "$IOPSI" 2>/dev/null)
  io_full=$(awk '$1=="full"{for(i=2;i<=NF;i++)if($i~/^avg10=/){sub("avg10=","",$i);print $i}}' "$IOPSI" 2>/dev/null)
  read_gpu; gpu="$GPU_VAL"
  echo "$(date -u +%FT%TZ),$el,${mem:-NA},${ps_some:-NA},${ps_full:-NA},${io_some:-NA},${io_full:-NA},${gpu:-NA}" >>"$CSV"

  if [ -z "$mem" ] || [ -z "$ps_some" ] || [ -z "$ps_full" ] || [ -z "$io_some" ] || [ -z "$io_full" ] || [ -z "$gpu" ]; then BAD=$((BAD + 1)); else BAD=0; fi
  [ "$BAD" -ge 3 ] && fire "sensor_unreadable x3 (mem='${mem}' psi='${ps_some}/${ps_full}' io='${io_some}/${io_full}' gpu='${gpu}')"
  [ -n "$mem" ] && [ "$mem" -lt "$MIN_MEM_MB" ] && fire "MemAvailable ${mem} MiB < ${MIN_MEM_MB}"
  [ -n "$ps_some" ] && awk -v p="$ps_some" -v m="$MAX_PSI" 'BEGIN{exit !(p>m)}' && fire "memory PSI some avg10 ${ps_some} > ${MAX_PSI}"
  [ -n "$ps_full" ] && awk -v p="$ps_full" -v m="$MAX_PSI_FULL" 'BEGIN{exit !(p>m)}' && fire "memory PSI full avg10 ${ps_full} > ${MAX_PSI_FULL}"
  [ -n "$io_some" ] && awk -v p="$io_some" -v m="$MAX_IO_SOME" 'BEGIN{exit !(p>m)}' && fire "IO PSI some avg10 ${io_some} > ${MAX_IO_SOME}"
  [ -n "$io_full" ] && awk -v p="$io_full" -v m="$MAX_IO_FULL" 'BEGIN{exit !(p>m)}' && fire "IO PSI full avg10 ${io_full} > ${MAX_IO_FULL}"
  [ -n "$gpu" ] && [ "$gpu" -gt "$MAX_GPU_MB" ] && fire "GPU used ${gpu} MiB > ${MAX_GPU_MB}"
  [ "$el" -gt "$MAX_WALL" ] && fire "wall clock ${el}s > ${MAX_WALL}"
  parent_gone && fire "parent pid $PARENT vanished (missing or zombie)"
  sleep "$INTERVAL"
done
