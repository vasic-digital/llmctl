#!/usr/bin/env bash
# vision_live_test.sh - guarded live known-answer test of the llmctl `vision` profile.
#
# Usage: vision_live_test.sh [vision]        (anything else, incl. vision-pro, is refused)
#
# Exit: 0 PASS | 1 wrong answer (FAIL) | 2 undetermined | 3 pre-gate refusal | 4 aborted by watchdog | 5 watchdog died (model stopped)
#
# Safety contract (see docs/live-test-protocol.md):
#  * pre-gate refuses unless MemAvailable>=12000 MiB, PSI some<5 & full<1, GPU used<6000 MiB,
#    nothing else large running, no failed/restarting llmctl unit for the profile;
#  * watchdog.sh is started BEFORE the model and stops the profile on any breach;
#  * the model is started ONLY via `LLMCTL_VALIDATE_ON_START=0 nice -n 19 ionice -c 3 llmctl start vision`;
#  * the only signal this script ever sends is to the watchdog PID it started (safe_kill);
#  * trap on EXIT/INT/TERM/HUP always runs `llmctl stop vision`;
#  * no retries, thresholds are constants (overridable only with LT_HERMETIC=1, used by tests).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${1:-vision}"
# Sensor/binary redirections exist for the hermetic tests ONLY: honoured exclusively when LT_HERMETIC=1.
LLMCTL=llmctl; NVSMI=nvidia-smi; SYSCTL=systemctl; MEMINFO=/proc/meminfo; PSI=/proc/pressure/memory
OVERRIDE_NAMES="LT_MEMINFO LT_PSI LT_IOPSI NVIDIA_SMI_BIN LLMCTL_BIN SYSTEMCTL_BIN LT_SUITE_DIR"
if [ "${LT_HERMETIC:-0}" = "1" ]; then
  LLMCTL="${LLMCTL_BIN:-llmctl}"; NVSMI="${NVIDIA_SMI_BIN:-nvidia-smi}"; SYSCTL="${SYSTEMCTL_BIN:-systemctl}"
  MEMINFO="${LT_MEMINFO:-/proc/meminfo}"; PSI="${LT_PSI:-/proc/pressure/memory}"
fi

GATE_MIN_MEM_MB=12000; GATE_MAX_PSI_SOME=5; GATE_MAX_PSI_FULL=1; GATE_MAX_GPU_MB=6000
LARGE_RAM_MB=4000; LARGE_VRAM_MB=2000          # another running profile at/above either = "large model"
READY_INTERVAL=3; READY_MAX=180; PORT_DEFAULT=8082; VRAM_SLACK_MB=500; VRAM_SETTLE_MAX=30
VALIDATE_GRACE=30; START_MAX=120
if [ "${LT_HERMETIC:-0}" = "1" ]; then
  READY_INTERVAL="${LT_READY_INTERVAL:-$READY_INTERVAL}"; READY_MAX="${LT_READY_MAX:-$READY_MAX}"
  PORT_DEFAULT="${LT_PORT_DEFAULT:-$PORT_DEFAULT}"; VRAM_SETTLE_MAX="${LT_VRAM_SETTLE_MAX:-$VRAM_SETTLE_MAX}"
  VALIDATE_GRACE="${LT_VALIDATE_GRACE:-$VALIDATE_GRACE}"; START_MAX="${LT_START_MAX:-$START_MAX}"
fi

# ---- profile allow-list: vision-pro (and anything not exactly `vision`) is refused unconditionally ----
if [ "$PROFILE" != "vision" ]; then
  echo "REFUSED: profile '$PROFILE' is not allowed (only 'vision'; vision-pro is refused unconditionally)" >&2
  exit 3
fi

umask 077   # evidence (status, logs, outputs) is private: dirs 0700, files 0600
TS="$(date -u +%Y%m%dT%H%M%SZ)"
EV="${LT_EVIDENCE_ROOT:-$HOME/.cache/llmctl-livetest}/$TS"
mkdir -p "$EV" || { echo "cannot create evidence dir $EV" >&2; exit 2; }
for _n in $OVERRIDE_NAMES; do
  if [ -n "${!_n:-}" ]; then
    if [ "${LT_HERMETIC:-0}" = 1 ]; then echo "HONOURED $_n=${!_n} (LT_HERMETIC=1: TEST RUN, NOT LIVE EVIDENCE)" >>"$EV/overrides.log"
    else echo "IGNORED $_n=${!_n} (LT_HERMETIC!=1)" >>"$EV/overrides.log"; fi
  fi
done
[ "${LT_HERMETIC:-0}" = 1 ] && echo "HONOURED LT_HERMETIC=1: thresholds/timeouts may be overridden; this is NOT a live run" >>"$EV/overrides.log"
CMDLOG="$EV/commands.log"; SIGLOG="$EV/signals.log"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$EV/run.log" >&2; }

WD_PID=""; STOP_NEEDED=0; CLEANED=0; RESULT=2; VERDICT_REASON="not finished"
GATE_RES="NOT RUN"; READY=0; FINAL_STOP_RC="NA"; GPU_BASE=""; GPU_FINAL=""; VALIDATE_RC="NA"; CLEAN_OK="NO"; MH="UNKNOWN"; PH="UNKNOWN"; LSV="UNKNOWN"

print_table() {
  printf '\n%-28s %s\n' "CHECK" "RESULT"
  printf '%-28s %s\n' "pre-gate" "$GATE_RES"
  printf '%-28s %s\n' "watchdog trigger" "$([ -s "$EV/trigger" ] && cat "$EV/trigger" || echo none)"
  local READY_TXT=no; [ "$READY" = 1 ] && READY_TXT=up
  printf '%-28s %s\n' "readiness" "$READY_TXT"
  printf '%-28s %s\n' "validate rc" "$VALIDATE_RC"
  printf '%-28s %s\n' "vram base/final MiB" "$GPU_BASE/$GPU_FINAL"
  printf '%-28s %s\n' "profile stopped+vram ok" "$CLEAN_OK"
  printf '%-28s %s\n' "model sha256" "$MH"
  printf '%-28s %s\n' "mmproj sha256" "$PH"
  printf '%-28s %s\n' "llama-server" "$LSV"
  printf '%-28s %s\n' "evidence" "$EV"
  local word=UNDETERMINED
  case "$RESULT" in 0) word=PASS ;; 1) word=FAIL ;; 3) word=REFUSED ;; 4) word=ABORTED ;; 5) word=ABORTED-WATCHDOG-DEAD ;; *) ;; esac
  printf '%-28s %s (exit %s) - %s\n' "VERDICT" "$word" "$RESULT" "$VERDICT_REASON"
}

# The ONLY place a signal is sent: to the watchdog PID this script started. Logged first.
safe_kill() {
  [ -n "$WD_PID" ] || return 0
  # identity check: only ever signal a live process whose cmdline is our watchdog (PID-reuse safe)
  if [ -r "/proc/$WD_PID/cmdline" ] && tr '\0' ' ' <"/proc/$WD_PID/cmdline" | grep -q 'livetest/watchdog\.sh\|watchdog\.sh .*'"$PROFILE"; then
    echo "$(date -u +%FT%TZ) SIGTERM -> watchdog pid $WD_PID" >>"$SIGLOG"
    kill -TERM "$WD_PID" 2>/dev/null
  else
    echo "$(date -u +%FT%TZ) NOT signalling pid $WD_PID: not (or no longer) our watchdog" >>"$SIGLOG"
  fi
}

wd_alive() {   # alive = exists, is our watchdog, and is not a zombie
  local st
  [ -n "$WD_PID" ] && [ -r "/proc/$WD_PID/cmdline" ] || return 1
  tr '\0' ' ' <"/proc/$WD_PID/cmdline" | grep -q 'watchdog\.sh' || return 1
  st="$(sed 's/^.*) //' "/proc/$WD_PID/stat" 2>/dev/null | cut -c1)"
  [ -n "$st" ] && [ "$st" != Z ] && [ "$st" != X ]
}

run_logged() { echo "$(date -u +%FT%TZ) \$ $*" >>"$CMDLOG"; "$@"; }

# shellcheck disable=SC2329  # invoked via trap
cleanup() {   # always: stop our profile via llmctl, then reap our own watchdog
  [ "$CLEANED" = 1 ] && return; CLEANED=1
  if [ "$STOP_NEEDED" = 1 ]; then
    log "cleanup: llmctl stop $PROFILE"
    "$HERE/watchdog.sh" --stop "$PROFILE" "$EV" >>"$EV/stop.out" 2>&1
    echo "cleanup stop rc=$? (0 llmctl ok | 10 systemd fallback | 11 failed)" >>"$EV/stop.out"
  fi
  safe_kill
  [ -n "$WD_PID" ] && wait "$WD_PID" 2>/dev/null
  return 0
}
# shellcheck disable=SC2329
on_exit() { local rc=$?; cleanup; RESULT="$rc"; print_table | tee "$EV/verdict.txt"; exit "$rc"; }
# shellcheck disable=SC2329
on_sig()  { log "interrupted by signal"; RESULT=2; VERDICT_REASON="interrupted"; exit 2; }
trap on_exit EXIT
trap on_sig INT TERM HUP

refuse() { GATE_RES="REFUSED"; log "REFUSED (gate): $*"; echo "gate REFUSED: $*" >>"$EV/gate.log"; RESULT=3; VERDICT_REASON="gate: $*"; exit 3; }

need() { command -v "$1" >/dev/null 2>&1 || { log "missing tool: $1"; RESULT=2; VERDICT_REASON="missing tool $1"; exit 2; }; }
need python3; need curl; need awk; need "$LLMCTL"; need "$NVSMI"; need nice; need ionice

gpu_used() { "$NVSMI" --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null \
  | awk 'BEGIN{m=-1} /^[ \t]*[0-9]+[ \t]*$/{if($1+0>m)m=$1+0} END{if(m>=0)print m}'; }

status_json() { "$LLMCTL" status --json 2>/dev/null; }


# --- identity of what the unit ACTUALLY loaded: its env file's LLMCTL_ARGS (-m / --mmproj), never a default filename
services_env_file() {
  local inst="$PROFILE"
  [ -n "${LLMCTL_TENANT_ID:-}" ] && inst="${LLMCTL_TENANT_ID}--${PROFILE}"
  echo "${LLMCTL_SERVICES_DIR:-${LLMCTL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/llmctl}/services}/${inst}.env"
}
loaded_files() {   # prints two lines: model path, mmproj path (empty when unknown)
  python3 -I -c '
import shlex,sys
model=mm=""
try:
    for line in open(sys.argv[1]):
        if line.startswith("LLMCTL_ARGS="):
            t=shlex.split(line.split("=",1)[1].strip())
            for i,a in enumerate(t[:-1]):
                if a in ("-m","--model"): model=t[i+1]
                if a=="--mmproj": mm=t[i+1]
except Exception: pass
print(model); print(mm)' "$(services_env_file)"
}

# PASS evidence: parsed JSON, verdict PASS, every probe PASS, probe count == the golden suite's probe count
check_validate_json() {   # check_validate_json <validate.out> <suite-dir> -> prints OK or the reason
  python3 -I - "$1" "$2" <<'PY'
import json,sys
raw=open(sys.argv[1],errors="replace").read()
try:
    i=raw.index("{"); rep,_=json.JSONDecoder().raw_decode(raw[i:])
except Exception as e:
    print("validate output is not parseable JSON (%s)"%e); sys.exit(0)
try:
    suite=json.load(open(sys.argv[2]+"/expectations.json"))
    expected=sum(len(f.get("probes",[])) for f in suite["fixtures"])
except Exception as e:
    print("validate output cannot be checked: golden suite unreadable (%s)"%e); sys.exit(0)
res=rep.get("results"); c=rep.get("counts") or {}
if not isinstance(res,list) or not res: print("validate output has no probe results"); sys.exit(0)
if rep.get("verdict")!="PASS" or rep.get("exit_code")!=0: print("validate output verdict=%r exit_code=%r"%(rep.get("verdict"),rep.get("exit_code"))); sys.exit(0)
if c.get("fail") or c.get("undetermined"): print("validate output counts fail/undetermined non-zero: %r"%c); sys.exit(0)
bad=[r.get("key") for r in res if r.get("verdict")!="PASS"]
if bad: print("validate output has non-PASS probes: %s"%bad); sys.exit(0)
if len(res)!=expected or c.get("pass")!=len(res): print("validate output probe count %d (counts.pass=%r) != golden suite %d"%(len(res),c.get("pass"),expected)); sys.exit(0)
ctl=[x for x in rep.get("controls",[]) if x.get("verdict")!="PASS"]
if ctl: print("validate output has non-PASS controls: %s"%[x.get("key") for x in ctl]); sys.exit(0)
print("OK")
PY
}
SUITE_DIR="$HERE/../../validation/suites/vision-golden-v1"
[ "${LT_HERMETIC:-0}" = 1 ] && SUITE_DIR="${LT_SUITE_DIR:-$SUITE_DIR}"

# ------------------------------------------------------------------ (a) pre-gate
gate() {
  local mem psi_s psi_f gpu st
  mem=$(awk '/^MemAvailable:/{printf "%d",$2/1024}' "$MEMINFO" 2>/dev/null)
  psi_s=$(awk '$1=="some"{for(i=2;i<=NF;i++)if($i~/^avg10=/){sub("avg10=","",$i);print $i}}' "$PSI" 2>/dev/null)
  psi_f=$(awk '$1=="full"{for(i=2;i<=NF;i++)if($i~/^avg10=/){sub("avg10=","",$i);print $i}}' "$PSI" 2>/dev/null)
  gpu=$(gpu_used)
  { echo "MemAvailable_MiB=${mem:-UNREADABLE} psi_some=${psi_s:-UNREADABLE} psi_full=${psi_f:-UNREADABLE} gpu_used_MiB=${gpu:-UNREADABLE}"; } | tee "$EV/gate.log" >&2
  [ -n "$mem" ]   || refuse "cannot read MemAvailable"
  [ -n "$psi_s" ] && [ -n "$psi_f" ] || refuse "cannot read memory PSI"
  [ -n "$gpu" ]   || refuse "cannot read GPU memory (nvidia-smi)"
  [ "$mem" -ge "$GATE_MIN_MEM_MB" ] || refuse "MemAvailable ${mem} MiB < ${GATE_MIN_MEM_MB}"
  awk -v p="$psi_s" -v m="$GATE_MAX_PSI_SOME" 'BEGIN{exit !(p<m)}' || refuse "PSI some avg10 ${psi_s} not < ${GATE_MAX_PSI_SOME}"
  awk -v p="$psi_f" -v m="$GATE_MAX_PSI_FULL" 'BEGIN{exit !(p<m)}' || refuse "PSI full avg10 ${psi_f} not < ${GATE_MAX_PSI_FULL}"
  [ "$gpu" -lt "$GATE_MAX_GPU_MB" ] || refuse "GPU used ${gpu} MiB not < ${GATE_MAX_GPU_MB}"
  GPU_BASE="$gpu"

  st="$(status_json)" || refuse "llmctl status --json failed"
  printf '%s\n' "$st" >"$EV/status_before.json"
  local verdict
  verdict="$(printf '%s' "$st" | python3 -I -c '
import json,sys
prof,ram,vram=sys.argv[1],int(sys.argv[2]),int(sys.argv[3])
try: rows=json.load(sys.stdin)
except Exception as e: print("BAD status json: %s"%e); sys.exit(0)
for r in rows:
    if r.get("profile","").split(".")[0]==prof: print("profile %s already running/reserved"%prof); sys.exit(0)
    if r.get("state")!="running": print("profile %s state=%s"%(r.get("profile"),r.get("state"))); sys.exit(0)
    if int(r.get("ram_mb") or 0)>=ram or int(r.get("vram_mb") or 0)>=vram:
        print("other large model running: %s (ram_mb=%s vram_mb=%s)"%(r.get("profile"),r.get("ram_mb"),r.get("vram_mb"))); sys.exit(0)
print("OK")' "$PROFILE" "$LARGE_RAM_MB" "$LARGE_VRAM_MB")"
  echo "status check: $verdict" >>"$EV/gate.log"
  [ "$verdict" = "OK" ] || refuse "$verdict"

  command -v "$SYSCTL" >/dev/null 2>&1 || refuse "systemctl unavailable: cannot verify unit state"
  local units
  units="$("$SYSCTL" --user list-units --all --plain --no-legend "llmctl-*@${PROFILE}*.service" 2>&1)" || refuse "systemctl list-units failed"
  printf '%s\n' "$units" >"$EV/units_before.txt"
  if printf '%s\n' "$units" | grep -Eiq '(failed|activating|auto-restart)'; then
    refuse "llmctl unit for $PROFILE is failed/restarting: $(printf '%s' "$units" | grep -Ei '(failed|activating|auto-restart)' | head -1)"
  fi
  GATE_RES="PASS"; echo "gate: PASS" >>"$EV/gate.log"; log "gate PASS (mem=${mem}MiB psi=${psi_s}/${psi_f} gpu=${gpu}MiB)"
}
gate

# ------------------------------------------------------------------ (b) watchdog BEFORE the model
"$HERE/watchdog.sh" "$PROFILE" "$EV" "$$" >>"$EV/watchdog.out" 2>&1 &
WD_PID=$!
echo "$(date -u +%FT%TZ) started watchdog pid $WD_PID" >>"$SIGLOG"
for _ in $(seq 1 20); do [ "$(wc -l <"$EV/samples.csv" 2>/dev/null || echo 0)" -ge 2 ] && break; sleep 0.5; done
[ "$(wc -l <"$EV/samples.csv" 2>/dev/null || echo 0)" -ge 2 ] || { log "watchdog produced no sample; not starting the model"; RESULT=2; VERDICT_REASON="watchdog not sampling"; exit 2; }
log "watchdog running (pid $WD_PID)"

triggered() { [ -s "$EV/trigger" ]; }
guard() {   # watchdog fired -> 4; watchdog dead without a trigger -> 5 (model must never run unguarded)
  abort_if_triggered
  if ! wd_alive; then
    sleep 0.5; abort_if_triggered   # it may have just fired and exited
    RESULT=5; VERDICT_REASON="watchdog died/is not alive: model would run unguarded -> aborted and stopped"
    log "$VERDICT_REASON"; exit 5
  fi
}
abort_if_triggered() {
  if triggered; then RESULT=4; VERDICT_REASON="watchdog: $(cat "$EV/trigger")"; log "ABORTED by watchdog: $(cat "$EV/trigger")"; exit 4; fi
}

# ------------------------------------------------------------------ (c) start + readiness
STOP_NEEDED=1
log "starting: LLMCTL_VALIDATE_ON_START=0 nice -n 19 ionice -c 3 $LLMCTL start $PROFILE"
echo "$(date -u +%FT%TZ) \$ LLMCTL_VALIDATE_ON_START=0 LLMCTL_READY_TIMEOUT=0 nice -n 19 ionice -c 3 $LLMCTL start $PROFILE (background)" >>"$CMDLOG"
# `llmctl start` holds the scheduler flock across svc_start (+ its own readiness wait). LLMCTL_READY_TIMEOUT=0
# (verified in lib/scheduler.sh _sched_wait_ready: <=0 disables the wait) makes it return right after svc_start,
# releasing the lock so a watchdog stop is never queued behind the model load; WE poll readiness below, with
# watchdog checks, under our own deadline. The start runs in the background so a breach during it is seen at once.
rm -f "$EV/start.rc"
( LLMCTL_VALIDATE_ON_START=0 LLMCTL_READY_TIMEOUT=0 nice -n 19 ionice -c 3 "$LLMCTL" start "$PROFILE" >"$EV/start.out" 2>&1; echo $? >"$EV/start.rc" ) &
t0=$(date +%s)
while [ ! -s "$EV/start.rc" ]; do
  guard
  [ $(( $(date +%s) - t0 )) -lt "$START_MAX" ] || { RESULT=2; VERDICT_REASON="llmctl start did not return within ${START_MAX}s"; exit 2; }
  sleep 0.3
done
START_RC="$(cat "$EV/start.rc")"
echo "start rc=$START_RC" >>"$EV/start.out"
abort_if_triggered
[ "$START_RC" = 0 ] || { RESULT=2; VERDICT_REASON="llmctl start rc=$START_RC"; exit 2; }

PORT="$(status_json | python3 -I -c '
import json,sys
try:
    for r in json.load(sys.stdin):
        if r.get("profile")==sys.argv[1] and r.get("port"): print(int(r["port"])); break
except Exception: pass' "$PROFILE" 2>/dev/null)"
[ -n "$PORT" ] || PORT="$PORT_DEFAULT"
URL="http://127.0.0.1:${PORT}"
log "waiting for $URL/health (every ${READY_INTERVAL}s, max ${READY_MAX}s)"
READY=0; t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt "$READY_MAX" ]; do
  guard
  if curl -fsS --max-time 3 "$URL/health" >"$EV/health.out" 2>>"$EV/health.err"; then READY=1; break; fi
  sleep "$READY_INTERVAL"
done
abort_if_triggered
[ "$READY" = 1 ] || { RESULT=2; VERDICT_REASON="not ready within ${READY_MAX}s"; exit 2; }
log "ready: $(head -c 200 "$EV/health.out")"
{ read -r LOADED_MODEL; read -r LOADED_MMPROJ; } < <(loaded_files)
echo "unit_env=$(services_env_file) model=${LOADED_MODEL:-UNKNOWN} mmproj=${LOADED_MMPROJ:-UNKNOWN}" >"$EV/loaded_files.txt"

# ------------------------------------------------------------------ (d) known-answer probes
HAVE_VV=0
if "$LLMCTL" vision help 2>/dev/null | grep -q 'vision validate'; then HAVE_VV=1; fi
[ "$HAVE_VV" = 1 ] || { RESULT=2; VERDICT_REASON="installed llmctl has no 'vision validate' (UNKNOWN: scratch harness not used live)"; exit 2; }
# Immediately before validate: the profile must be up (health answers). validate gets --host so it validates an
# explicit endpoint and can NEVER start the profile itself (without --host, lib/validate.sh calls sched_start when
# there is no .run file, which a stop removes - an un-niced, un-gated restart). --host also means the verdict is
# evidence only and is not recorded as local validation state (fine: our evidence is the captured output).
guard
curl -fsS --max-time 3 "$URL/health" >/dev/null 2>&1 || { RESULT=2; VERDICT_REASON="profile not up immediately before validate"; exit 2; }
VCMD=("$LLMCTL" vision validate --profile "$PROFILE" --host "$URL" --json --keep)
echo "$(date -u +%FT%TZ) \$ ${VCMD[*]}" >>"$CMDLOG"
"${VCMD[@]}" >"$EV/validate.out" 2>"$EV/validate.err" &
VPID=$!
while [ -d "/proc/$VPID" ]; do
  if triggered || ! wd_alive; then
    log "watchdog fired/died during validation; giving the client ${VALIDATE_GRACE}s to fail by itself (never signalled)"
    g=0; while [ -d "/proc/$VPID" ] && [ "$g" -lt "$VALIDATE_GRACE" ]; do sleep 1; g=$((g+1)); done
    break
  fi
  sleep 1
done
if [ -d "/proc/$VPID" ]; then VALIDATE_RC="HUNG"; else wait "$VPID"; VALIDATE_RC=$?; fi
echo "$VALIDATE_RC" >"$EV/validate.rc"
guard

# ------------------------------------------------------------------ (e) finalize: stop, confirm, identity
log "final: llmctl stop $PROFILE"
"$HERE/watchdog.sh" --stop "$PROFILE" "$EV" >>"$EV/stop.out" 2>&1; FINAL_STOP_RC=$?; echo "final stop rc=$FINAL_STOP_RC (0 llmctl ok | 10 systemd fallback | 11 failed)" >>"$EV/stop.out"
STOP_NEEDED=0
safe_kill; wait "$WD_PID" 2>/dev/null; WD_PID=""
abort_if_triggered   # a trigger recorded just before we reaped the watchdog still counts

g=0
while :; do
  GPU_FINAL="$(gpu_used)"
  [ -n "$GPU_FINAL" ] && [ -n "$GPU_BASE" ] && [ "$GPU_FINAL" -le $((GPU_BASE + VRAM_SLACK_MB)) ] && break
  [ "$g" -ge "$VRAM_SETTLE_MAX" ] && break
  sleep 1; g=$((g+1))
done
status_json >"$EV/status_after.json" 2>&1
STILL="$(python3 -I -c '
import json,sys
try: print("yes" if any(r.get("profile","").split(".")[0]==sys.argv[1] for r in json.load(open(sys.argv[2]))) else "no")
except Exception: print("unknown")' "$PROFILE" "$EV/status_after.json")"
if [ "$STILL" = "no" ] && [ -n "$GPU_FINAL" ] && [ "$GPU_FINAL" -le $((GPU_BASE + VRAM_SLACK_MB)) ]; then CLEAN_OK="YES"; fi

hash_of() { if [ -n "$1" ] && [ -f "$1" ]; then nice -n 19 ionice -c 3 sha256sum "$1" | awk '{print $1}'; else echo "MISSING"; fi; }
MH="$(hash_of "${LOADED_MODEL:-}")"
PH="$(hash_of "${LOADED_MMPROJ:-}")"
JSON_VERDICT="$(check_validate_json "$EV/validate.out" "$SUITE_DIR")"; echo "$JSON_VERDICT" >"$EV/validate_check.txt"
LSV="$("${LLAMA_SERVER_BIN:-llama-server}" --version 2>&1 | tr '\n' ' ' | cut -c1-300)"; [ -n "$LSV" ] || LSV="UNKNOWN"
{ echo "model_sha256=$MH"; echo "mmproj_sha256=$PH"; echo "llama_server_version=$LSV"; echo "gpu_baseline_mb=$GPU_BASE gpu_final_mb=$GPU_FINAL"; } >"$EV/identity.txt"

if [ "$VALIDATE_RC" = 1 ]; then RESULT=1; VERDICT_REASON="wrong answer(s): validate rc=1"
elif [ "$VALIDATE_RC" != 0 ]; then RESULT=2; VERDICT_REASON="validate rc=$VALIDATE_RC (could not determine)"
elif [ "$JSON_VERDICT" != OK ]; then RESULT=2; VERDICT_REASON="$JSON_VERDICT"
elif [ "$MH" = MISSING ] || [ "$PH" = MISSING ]; then RESULT=2; VERDICT_REASON="hash of the model/mmproj the unit loaded not capturable"
elif [ "$CLEAN_OK" != YES ]; then RESULT=2; VERDICT_REASON="cleanup not confirmed (vram base=$GPU_BASE final=$GPU_FINAL still_running=$STILL)"
else RESULT=0; VERDICT_REASON="all known-answer probes matched; evidence captured; VRAM back to baseline"; fi

exit "$RESULT"
