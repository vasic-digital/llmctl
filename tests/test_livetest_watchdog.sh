#!/usr/bin/env bash
# test_livetest_watchdog.sh - hermetic tests for scripts/livetest/{vision_live_test,watchdog}.sh
#
# Everything external is faked: /proc/meminfo, /proc/pressure/memory (via LT_MEMINFO/LT_PSI), nvidia-smi,
# systemctl, llmctl, pkill/killall, llama-server and the model health endpoint (a local python http server).
# No real model, container, unit or llmctl is ever started. Each behaviour has a NEGATIVE CONTROL.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN="$ROOT/scripts/livetest/vision_live_test.sh"
WD="$ROOT/scripts/livetest/watchdog.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/livetest.XXXXXX")"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL  %s  -- %s\n' "$1" "${2:-}"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3' got '$2'"; fi; }
has()  { if grep -qE -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1" "no /$3/ in $2"; fi; }
hasnt(){ if grep -qE -- "$3" "$2" 2>/dev/null; then bad "$1" "unexpected /$3/ in $2"; else ok "$1"; fi; }

want() { [ -z "${ONLY:-}" ] || [ "$1" = always ] || [[ ",$ONLY," == *",$1,"* ]]; }

# ---- health server (fake llama-server /health) ----
mkdir -p "$T/www"; echo '{"status":"ok"}' >"$T/www/health"
PORT="$(python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
(cd "$T/www" && exec python3 -I -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
HS_PID=$!
sleep 1
BYSTANDER_PID=""
(sleep 600) & BYSTANDER_PID=$!
cleanup_t() { kill "$HS_PID" "$BYSTANDER_PID" 2>/dev/null; rm -rf "$T"; }   # test's own children only
trap cleanup_t EXIT

# ---- build one fake environment: $E/{bin,fake,ev,...}; echo its path ----
mkenv() {
  local E; E="$(mktemp -d "$T/env.XXXXXX")"
  mkdir -p "$E/bin" "$E/fake" "$E/ev" "$E/models"
  printf 'MemTotal: 32000000 kB\nMemAvailable:   %d kB\n' $((20000*1024)) >"$E/meminfo"
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' >"$E/psi"
  echo 1200 >"$E/fake/gpu"; echo 1200 >"$E/fake/gpu_base"
  echo '[]' >"$E/fake/others.json"; : >"$E/fake/calls"
  echo "$PORT" >"$E/fake/port"
  echo 0 >"$E/fake/validate_rc"; echo 0 >"$E/fake/start_rc"
  mkdir -p "$E/services" "$E/suite"
  printf "LLMCTL_ENGINE='llama'\nLLMCTL_ARGS=-m %s --mmproj %s --port 8082\n" "$E/models/m.gguf" "$E/models/p.gguf" >"$E/services/vision.env"
  printf '{"suite":"s","kind":"vision","fixtures":[{"id":"f1","probes":[{"id":"a"},{"id":"b"}]},{"id":"f2","probes":[{"id":"c"}]}]}\n' >"$E/suite/expectations.json"
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' >"$E/iopsi"
  echo fake-model >"$E/models/m.gguf"; echo fake-mmproj >"$E/models/p.gguf"
  cat >"$E/bin/nvidia-smi" <<'X'
#!/usr/bin/env bash
[ -f "$FAKE/gpu_hang" ] && sleep 8
cat "$FAKE/gpu"
X
  cat >"$E/bin/systemctl" <<'X'
#!/usr/bin/env bash
# fake systemctl: list-units reads $FAKE/units; stop/is-active act on the fake running state
case "$*" in
  *"--user stop "*) echo "systemctl stop ${*: -1}" >>"$FAKE/calls"; rm -f "$FAKE/running"
     [ -f "$FAKE/sysstop_fail" ] && exit 1
     [ -f "$FAKE/leak" ] || cp "$FAKE/gpu_base" "$FAKE/gpu"; exit 0 ;;
  *"--user is-active"*) if [ -f "$FAKE/running" ] || [ -f "$FAKE/unit_stuck_active" ]; then echo active; exit 0; else echo inactive; exit 3; fi ;;
  *"list-units"*) [ -f "$FAKE/units" ] || exit 0
     for a in "$@"; do case "$a" in *@*) pat="@${a##*@}"; pat="${pat%%.service}"; pat="${pat%\*}";; esac; done
     grep -F -- "${pat:-}" "$FAKE/units"; exit 0 ;;
  *) exit 0 ;;
esac
X
  for n in pkill killall; do printf '#!/usr/bin/env bash\necho "%s $*" >>"$FAKE/forbidden"\n' "$n" >"$E/bin/$n"; done
  printf '#!/usr/bin/env bash\necho "llama-server fake version: 1 (testbuild)"\n' >"$E/bin/llama-server"
  cat >"$E/bin/llmctl" <<'X'
#!/usr/bin/env bash
# fake llmctl: never starts anything real
echo "$*" >>"$FAKE/calls.args"
case "$1 ${2:-}" in
  "status --json")
    python3 -I - "$FAKE" <<'PY'
import json,os,sys
f=sys.argv[1]; rows=json.load(open(f+"/others.json"))
if os.path.exists(f+"/running"):
    rows.append({"profile":"vision","port":int(open(f+"/port").read()),"mode":"x","ram_mb":3000,"vram_mb":1500,"enabled":False,"state":"running","last_log_line":None})
print(json.dumps(rows))
PY
    ;;
  "start vision")
    echo "start env=${LLMCTL_VALIDATE_ON_START:-unset} ready_timeout=${LLMCTL_READY_TIMEOUT:-unset} nice=$(awk '{print $19}' /proc/$$/stat) ionice=$(ionice -p $$ 2>&1)" >>"$FAKE/calls"
    rc=$(cat "$FAKE/start_rc"); [ "$rc" = 0 ] && touch "$FAKE/running"
    [ -f "$FAKE/gpu_after_start" ] && cp "$FAKE/gpu_after_start" "$FAKE/gpu"
    [ -f "$FAKE/start_mutate.sh" ] && bash "$FAKE/start_mutate.sh"
    if [ -f "$FAKE/start_sleep" ]; then   # simulates holding the scheduler flock across svc_start + readiness
      touch "$FAKE/lock_held"; sleep "$(cat "$FAKE/start_sleep")"; rm -f "$FAKE/lock_held"
    fi
    exit "$rc" ;;
  "stop vision")
    n=0; while [ -f "$FAKE/lock_held" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n+1)); done   # blocked on the lock
    echo "stop vision" >>"$FAKE/calls"
    [ -f "$FAKE/stop_rc1" ] && { rm -f "$FAKE/running_keep"; rm -f "$FAKE/running"; echo "stop failed" >&2; exit 1; }
    rm -f "$FAKE/running"
    [ -f "$FAKE/leak" ] || cp "$FAKE/gpu_base" "$FAKE/gpu"
    [ -f "$FAKE/hang_after_stop" ] && touch "$FAKE/gpu_hang"
    exit 0 ;;
  "stop "*) echo "stop OTHER: $*" >>"$FAKE/calls"; exit 0 ;;
  "vision help") echo "llmctl vision validate [--profile vision|vision-pro] [--json] [--keep]"; exit 0 ;;
  "logs vision") echo "fake log line"; exit 0 ;;
  "version "*|"version") echo "llmctl fake-1.0"; exit 0 ;;
  "vision validate")
    echo "validate $*" >>"$FAKE/calls"
    [ -f "$FAKE/mutate.sh" ] && bash "$FAKE/mutate.sh"
    n=0; while [ -f "$FAKE/running" ] && [ -f "$FAKE/validate_wait" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n+1)); done
    if [ ! -f "$FAKE/running" ]; then
      case " $* " in
        *" --host "*) echo "connection refused" >&2; exit 2 ;;
        *) echo "validate RESTARTED profile (no --host, no .run)" >>"$FAKE/calls"; touch "$FAKE/running"; echo "restarted" >&2; exit 2 ;;
      esac
    fi
    mode=ok; [ -f "$FAKE/validate_mode" ] && mode=$(cat "$FAKE/validate_mode")
    case "$mode" in
      zero)    echo '{"suite":"s","verdict":"PASS","exit_code":0,"counts":{"pass":0,"fail":0,"undetermined":0},"results":[],"controls":[]}' ;;
      badjson) echo 'this is not json {{{' ;;
      partial) echo '{"verdict":"PASS","exit_code":0,"counts":{"pass":2,"fail":0,"undetermined":0},"results":[{"key":"a","verdict":"PASS"},{"key":"b","verdict":"PASS"}],"controls":[]}' ;;
      onefail) echo '{"verdict":"PASS","exit_code":0,"counts":{"pass":2,"fail":1,"undetermined":0},"results":[{"key":"a","verdict":"PASS"},{"key":"b","verdict":"PASS"},{"key":"c","verdict":"FAIL"}],"controls":[]}' ;;
      *)       echo 'suite header line'; echo '{"verdict":"PASS","exit_code":0,"counts":{"pass":3,"fail":0,"undetermined":0},"results":[{"key":"a","verdict":"PASS"},{"key":"b","verdict":"PASS"},{"key":"c","verdict":"PASS"}],"controls":[]}' ;;
    esac
    exit "$(cat "$FAKE/validate_rc")" ;;
  *) echo "fake llmctl: unexpected: $*" >>"$FAKE/calls"; exit 64 ;;
esac
X
  chmod +x "$E"/bin/*
  echo "$E"
}

# run_main <env> [args...]: hermetic run, returns exit code in $RC, evidence dir in $EVD
run_main() {
  local E="$1"; shift
  RC=0
  FAKE="$E/fake" PATH="$E/bin:$PATH" LT_HERMETIC=1 LT_WD_INTERVAL=0.2 LT_WD_MAX_WALL="${WALL:-600}" \
    LT_READY_INTERVAL=0.2 LT_READY_MAX="${READY_MAX:-4}" LT_VRAM_SETTLE_MAX=2 LT_VALIDATE_GRACE=3 \
    LT_MEMINFO="$E/meminfo" LT_PSI="$E/psi" LT_IOPSI="$E/iopsi" LT_EVIDENCE_ROOT="$E/ev" HOME="$E/home" \
    LLMCTL_SERVICES_DIR="$E/services" LT_SUITE_DIR="$E/suite" LT_STOP_BOUND=2 LT_BOUND=2 LT_START_MAX=20 LT_POST_SAMPLE=2 \
    timeout 60 bash "$MAIN" "$@" >"$E/out.txt" 2>"$E/err.txt" || RC=$?
  EVD="$(find "$E/ev" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
}
setmem() { printf 'MemAvailable:   %d kB\n' $(( $2 * 1024 )) >"$1/meminfo"; }
setpsi() { printf 'some avg10=%s avg60=0 avg300=0 total=1\nfull avg10=%s avg60=0 avg300=0 total=1\n' "$2" "$3" >"$1/psi"; }
calls_has_start() { grep -q '^start ' "$1/fake/calls"; }

if want base; then
echo "== 0. static: lint + signal discipline =="
bash -n "$MAIN" && bash -n "$WD" && ok "bash -n both scripts" || bad "bash -n"
if command -v shellcheck >/dev/null; then shellcheck -S warning "$MAIN" "$WD" "$0" >/dev/null 2>&1 && ok "shellcheck clean" || bad "shellcheck"; fi
nk=$(grep -vE '^\s*#' "$MAIN" "$WD" | grep -cE '\b(kill|pkill|killall)\b')
check "exactly one kill call site in scripts (safe_kill)" "$nk" "1"
grep -vE '^\s*#' "$MAIN" | grep -E '\bkill\b' | grep -q 'kill -TERM "\$WD_PID"' && ok "the one kill targets \$WD_PID only" || bad "kill target"
hasnt "no process-group/negative-pid signalling" <(grep -vE '^\s*#' "$MAIN" "$WD") 'kill +(-[A-Z0-9]+ +)?-[0-9]|setsid|pgid'
hasnt "no reboot/suspend/poweroff verbs" <(grep -vE '^\s*#' "$MAIN" "$WD") 'systemctl +(suspend|hibernate|poweroff|reboot|halt)|shutdown|reboot'
# negative control: the detector fires on a deliberately bad file
printf 'kill -9 -1\npkill foo\n' >"$T/badfile.sh"
[ "$(grep -vE '^\s*#' "$T/badfile.sh" | grep -cE '\b(kill|pkill|killall)\b')" = 2 ] && ok "NEG-CONTROL kill detector flags a bad file" || bad "kill detector blind"

echo "== 1. happy path (also: start path, nice/ionice, env) =="
E="$(mkenv)"; run_main "$E"
check "all-good run exits 0 (PASS)" "$RC" "0"
has "verdict table says PASS" "$E/out.txt" 'VERDICT +PASS \(exit 0\)'
has "start called with LLMCTL_VALIDATE_ON_START=0" "$E/fake/calls" '^start env=0 '
has "start ran at nice 19" "$E/fake/calls" 'nice=19 '
has "start ran at ionice idle" "$E/fake/calls" 'ionice=idle'
has "validate invoked with --profile vision --json" "$E/fake/calls" '^validate vision validate --profile vision --json'
has "final llmctl stop vision happened" "$E/fake/calls" '^stop vision'
hasnt "no watchdog trigger recorded" <(cat "$EVD/trigger" 2>/dev/null; echo) '.'
for f in gate.log samples.csv watchdog.log commands.log validate.out validate.rc identity.txt verdict.txt status_before.json status_after.json signals.log; do
  [ -s "$EVD/$f" ] && ok "evidence file $f" || bad "evidence file $f missing/empty"
done
has "identity has model sha256 (64 hex)" "$EVD/identity.txt" 'model_sha256=[0-9a-f]{64}'
has "identity has llama-server version" "$EVD/identity.txt" 'testbuild'
[ ! -e "$E/fake/forbidden" ] && ok "pkill/killall never called" || bad "pkill/killall called: $(cat "$E/fake/forbidden")"
wdp=$(sed -n 's/.*started watchdog pid \([0-9]*\)/\1/p' "$EVD/signals.log")
check "signals.log: exactly one signal line" "$(grep -c SIGTERM "$EVD/signals.log")" "1"
has "the only signal targets the watchdog pid ($wdp)" "$EVD/signals.log" "SIGTERM -> watchdog pid $wdp\$"
[ ! -d "/proc/$wdp" ] && ok "watchdog reaped after run" || bad "watchdog $wdp still alive"
[ -d "/proc/$BYSTANDER_PID" ] && ok "bystander process untouched" || bad "bystander killed"

echo "== 2. vision-pro / other profiles refused unconditionally =="
for pr in vision-pro vision-pro-x chat; do
  E="$(mkenv)"; run_main "$E" "$pr"
  check "profile '$pr' refused exit 3" "$RC" "3"
  [ ! -s "$E/fake/calls.args" ] && ok "  no llmctl call at all for '$pr'" || bad "  llmctl was called for '$pr'"
  [ -z "$EVD" ] && ok "  no evidence dir/side effects for '$pr'" || bad "  evidence created for '$pr'"
done
E="$(mkenv)"; run_main "$E" vision; check "NEG-CONTROL: 'vision' itself is accepted" "$RC" "0"

echo "== 3. pre-gate refusals (each metric) with boundary negative controls =="
gate_case() {  # gate_case <name> <setup-fn-body...>
  local name="$1"; shift
  E="$(mkenv)"; "$@" "$E"; run_main "$E"
  check "gate refuses: $name (exit 3)" "$RC" "3"
  calls_has_start "$E" && bad "  $name: model start was called!" || ok "  $name: start never called"
  has "  $name: gate.log records refusal" "$EVD/gate.log" 'REFUSED'
  hasnt "  $name: no stop called (nothing was started)" "$E/fake/calls" '^stop'
}
g_mem()   { setmem "$1" 11999; }
g_psis()  { setpsi "$1" 5.00 0.00; }
g_psif()  { setpsi "$1" 0.00 1.00; }
g_gpu()   { echo 6000 >"$1/fake/gpu"; }
g_gpuna() { echo "N/A" >"$1/fake/gpu"; }
g_other() { echo '[{"profile":"coder","port":8081,"mode":"x","ram_mb":9000,"vram_mb":7000,"enabled":true,"state":"running","last_log_line":null}]' >"$1/fake/others.json"; }
g_failedp(){ echo '[{"profile":"chat","port":8080,"mode":"x","ram_mb":10,"vram_mb":0,"enabled":true,"state":"failed (crash-loop)","last_log_line":"x"}]' >"$1/fake/others.json"; }
g_self()  { echo '[{"profile":"vision","port":8082,"mode":"x","ram_mb":10,"vram_mb":0,"enabled":false,"state":"running","last_log_line":null}]' >"$1/fake/others.json"; }
g_unit()  { echo 'llmctl-llama@vision.service loaded failed failed llama-server vision' >"$1/fake/units"; }
g_restart(){ echo 'llmctl-llama@vision.service loaded activating auto-restart llama-server vision' >"$1/fake/units"; }
g_nopsi() { rm -f "$1/psi"; }
gate_case "MemAvailable 11999 MiB < 12000" g_mem
gate_case "PSI some avg10 5.00 (not <5)" g_psis
gate_case "PSI full avg10 1.00 (not <1)" g_psif
gate_case "GPU used 6000 MiB (not <6000)" g_gpu
gate_case "GPU unreadable (nvidia-smi N/A)" g_gpuna
gate_case "other large model running" g_other
gate_case "other profile in failed state" g_failedp
gate_case "profile already running" g_self
gate_case "llmctl unit failed" g_unit
gate_case "llmctl unit restarting" g_restart
gate_case "PSI file missing" g_nopsi
# negative control: values one step inside every limit must pass the gate and the whole run
E="$(mkenv)"; setmem "$E" 12000; setpsi "$E" 4.99 0.99; echo 5999 >"$E/fake/gpu"; echo 5999 >"$E/fake/gpu_base"
echo '[{"profile":"chat","port":8080,"mode":"x","ram_mb":3999,"vram_mb":1999,"enabled":true,"state":"running","last_log_line":null}]' >"$E/fake/others.json"
echo 'llmctl-llama@chat.service loaded failed failed other' >"$E/fake/units"   # a failed unit of ANOTHER profile is not ours
run_main "$E"
check "NEG-CONTROL boundary-good values pass gate + run (exit 0)" "$RC" "0"

echo "== 4. watchdog abort conditions (each calls fake llmctl stop, exit 4) =="
wd_case() {  # wd_case <name> <mutation-line> [wall]
  local name="$1" mut="$2" wall="${3:-600}"
  E="$(mkenv)"; touch "$E/fake/validate_wait"
  printf '%s\n' "$mut" >"$E/fake/mutate.sh"
  WALL="$wall" run_main "$E"; unset WALL
  check "watchdog abort: $name -> exit 4" "$RC" "4"
  has "  $name: trigger recorded" "$EVD/trigger" '.'
  has "  $name: llmctl stop vision called" "$E/fake/calls" '^stop vision'
  has "  $name: verdict says watchdog" "$E/out.txt" 'watchdog:'
  [ ! -e "$E/fake/running" ] && ok "  $name: profile not running afterwards" || bad "  $name: still running"
  [ ! -e "$E/fake/forbidden" ] && ok "  $name: no pkill/killall" || bad "  $name: forbidden called"
  hasnt "  $name: no signal except to watchdog" <(grep SIGTERM "$EVD/signals.log" | grep -v 'watchdog pid'; echo) '.'
  [ -d "/proc/$BYSTANDER_PID" ] && ok "  $name: bystander alive" || bad "  $name: bystander dead"
}
wd_case "MemAvailable 4999 < 5000" "printf 'MemAvailable: %d kB\n' $((4999*1024)) >\"\${FAKE%/fake}/meminfo\""
wd_case "PSI some avg10 20.5 > 20" "printf 'some avg10=20.50 avg60=0 avg300=0 total=1\nfull avg10=0 avg60=0 avg300=0 total=1\n' >\"\${FAKE%/fake}/psi\""
wd_case "GPU 11501 > 11500" "echo 11501 >\"\$FAKE/gpu\""
wd_case "wall clock > limit (2 s)" ":" 2
wd_case "sensor unreadable x3" "echo N/A >\"\$FAKE/gpu\""
# negative controls: values AT the limit do not trigger; run completes PASS
nc_case() {
  local name="$1" mut="$2"
  E="$(mkenv)"; touch "$E/fake/validate_wait"; printf '%s\n' "$mut" >"$E/fake/mutate.sh"
  printf 'sleep 1\n' >>"$E/fake/mutate.sh"
  run_main "$E"
  check "NEG-CONTROL at-limit does not trigger: $name (exit 0)" "$RC" "0"
  [ ! -s "$EVD/trigger" ] && ok "  $name: no trigger file" || bad "  $name: trigger=$(cat "$EVD/trigger")"
}
# in these, validate_wait would hang (profile never stops), so release it by removing the wait flag in the mutator
nc_case "MemAvailable 5000" "printf 'MemAvailable: %d kB\n' $((5000*1024)) >\"\${FAKE%/fake}/meminfo\"; rm -f \"\$FAKE/validate_wait\""
nc_case "PSI 20.00" "printf 'some avg10=20.00 avg60=0 avg300=0 total=1\nfull avg10=0 avg60=0 avg300=0 total=1\n' >\"\${FAKE%/fake}/psi\"; rm -f \"\$FAKE/validate_wait\""
nc_case "GPU 11500" "echo 11500 >\"\$FAKE/gpu\"; rm -f \"\$FAKE/validate_wait\""
# trigger text content (one detailed check per condition on the first cases)
E="$(mkenv)"; touch "$E/fake/validate_wait"; echo "echo 11501 >\"\$FAKE/gpu\"" >"$E/fake/mutate.sh"; run_main "$E"
has "trigger text names the GPU condition" "$EVD/trigger" 'GPU used 11501'
E="$(mkenv)"; touch "$E/fake/validate_wait"; echo "printf 'MemAvailable: %d kB\n' $((4000*1024)) >\"\${FAKE%/fake}/meminfo\"" >"$E/fake/mutate.sh"; run_main "$E"
has "trigger text names the memory condition" "$EVD/trigger" 'MemAvailable 4000'
E="$(mkenv)"; touch "$E/fake/validate_wait"; WALL=2 run_main "$E"; unset WALL
has "trigger text names the wall-clock condition" "$EVD/trigger" 'wall clock'

echo "== 5. watchdog started BEFORE model, standalone behaviour =="
E="$(mkenv)"; run_main "$E"
w_first=$(grep -m1 -n 'watchdog start' "$EVD/watchdog.log" | cut -d: -f1)
st_ts=$(grep -m1 'start vision' "$EVD/commands.log" | cut -d' ' -f1); wd_ts=$(head -1 "$EVD/watchdog.log" | cut -d' ' -f1)
[ -n "$w_first" ] && [[ "$wd_ts" < "$st_ts" || "$wd_ts" = "$st_ts" ]] && ok "watchdog log begins no later than model start ($wd_ts <= $st_ts)" || bad "ordering" 
awk -F, 'NR>1{ if($3!~/^[0-9]+$/) b=1 } END{exit b}' "$EVD/samples.csv" && ok "samples.csv has numeric memory samples" || bad "samples.csv malformed"
check "NEG-CONTROL samples header present" "$(head -1 "$EVD/samples.csv" | cut -c1-8)" "utc,elap"
# standalone watchdog: parent vanishes => stops profile and exits by itself
E="$(mkenv)"; mkdir -p "$E/wdev"; (sleep 1) & P=$!
FAKE="$E/fake" PATH="$E/bin:$PATH" LT_HERMETIC=1 LT_WD_INTERVAL=0.2 LT_MEMINFO="$E/meminfo" LT_PSI="$E/psi" \
  timeout 20 bash "$WD" vision "$E/wdev" "$P" >/dev/null 2>&1; wrc=$?
check "watchdog exits 0 when parent vanishes" "$wrc" "0"
has "  ...and stopped the profile via llmctl" "$E/fake/calls" '^stop vision'
has "  ...trigger says parent vanished" "$E/wdev/trigger" 'vanished'
# negative control: parent alive & healthy => no trigger within its lifetime, TERM exits cleanly without stop
E="$(mkenv)"; mkdir -p "$E/wdev"
FAKE="$E/fake" PATH="$E/bin:$PATH" LT_HERMETIC=1 LT_WD_INTERVAL=0.2 LT_MEMINFO="$E/meminfo" LT_PSI="$E/psi" bash "$WD" vision "$E/wdev" $$ >/dev/null 2>&1 &
W=$!; sleep 1.5; kill -TERM "$W" 2>/dev/null; wait "$W" 2>/dev/null; wrc=$?
check "NEG-CONTROL healthy watchdog exits 0 on TERM" "$wrc" "0"
[ ! -s "$E/wdev/trigger" ] && ok "  no trigger while healthy" || bad "  spurious trigger"
hasnt "  no llmctl stop when healthy" "$E/fake/calls" '^stop'

echo "== 6. trap: stop on EXIT / failure / signal =="
E="$(mkenv)"; echo 1 >"$E/fake/start_rc"; run_main "$E"
check "start failure -> exit 2" "$RC" "2"
has "EXIT trap ran llmctl stop vision after failed start" "$E/fake/calls" '^stop vision'
E="$(mkenv)"; echo 2 >"$E/fake/validate_rc"; run_main "$E"
check "validate rc=2 -> exit 2 (undetermined)" "$RC" "2"
has "stop issued" "$E/fake/calls" '^stop vision'
E="$(mkenv)"; echo 1 >"$E/fake/validate_rc"; run_main "$E"
check "wrong answer (validate rc=1) -> exit 1, never retried" "$RC" "1"
check "validate called exactly once (no retry)" "$(grep -c '^validate ' "$E/fake/calls")" "1"
has "verdict FAIL" "$E/out.txt" 'VERDICT +FAIL'
E="$(mkenv)"; READY_MAX=1 run_main "$E"; unset READY_MAX
check "NEG-CONTROL healthy health endpoint -> not stuck waiting" "$RC" "0"
E="$(mkenv)"; echo 1 >"$E/fake/port"; READY_MAX=1 run_main "$E"; unset READY_MAX
check "health never ready -> exit 2" "$RC" "2"
has "stop issued after readiness timeout" "$E/fake/calls" '^stop vision'
E="$(mkenv)"; touch "$E/fake/leak"; echo 9999 >"$E/fake/gpu_after_start"; run_main "$E"
check "VRAM not back to baseline -> exit 2, not PASS" "$RC" "2"
has "verdict names cleanup" "$E/out.txt" 'cleanup not confirmed'

# signal: SIGTERM to the script while the model is "running"
E="$(mkenv)"; touch "$E/fake/validate_wait"
( FAKE="$E/fake" PATH="$E/bin:$PATH" LT_HERMETIC=1 LT_WD_INTERVAL=0.2 LT_READY_INTERVAL=0.2 LT_VRAM_SETTLE_MAX=1 \
  LT_MEMINFO="$E/meminfo" LT_PSI="$E/psi" LT_EVIDENCE_ROOT="$E/ev" HOME="$E/home" exec bash "$MAIN" >"$E/out.txt" 2>"$E/err.txt" ) &
M=$!
for _ in $(seq 1 40); do grep -q '^validate ' "$E/fake/calls" 2>/dev/null && break; sleep 0.2; done
EVD="$(find "$E/ev" -mindepth 1 -maxdepth 1 -type d | head -1)"
wdp=$(sed -n 's/.*started watchdog pid \([0-9]*\)/\1/p' "$EVD/signals.log")
kill -TERM "$M"; wait "$M"; RC=$?
check "SIGTERM -> exit 2 (interrupted)" "$RC" "2"
has "trap stopped the profile on SIGTERM" "$E/fake/calls" '^stop vision'
[ ! -d "/proc/$wdp" ] && ok "watchdog gone after SIGTERM" || bad "watchdog $wdp leaked"
[ -d "/proc/$BYSTANDER_PID" ] && ok "bystander alive after SIGTERM" || bad "bystander dead"
rm -f "$E/fake/validate_wait"

fi   # base

if want d6; then
echo "== D6. PASS needs parsed JSON, every probe PASS, probe count == suite, hash of the file the unit loaded =="
for m in zero badjson partial onefail; do
  E="$(mkenv)"; echo "$m" >"$E/fake/validate_mode"; run_main "$E"
  check "validate output mode '$m' (rc 0) must NOT pass" "$([ "$RC" = 0 ] && echo PASSED || echo "no($RC)")" "no($RC)"
  hasnt "  '$m': verdict is not PASS" "$E/out.txt" 'VERDICT +PASS'
  has "  '$m': reason names the validate output" "$E/out.txt" 'validate output'
done
E="$(mkenv)"; run_main "$E"; check "NEG-CONTROL full valid JSON (3/3 probes) passes" "$RC" "0"
E="$(mkenv)"; echo different-model-content >"$E/models/other.gguf"
printf "LLMCTL_ENGINE='llama'\nLLMCTL_ARGS=-m %s --mmproj %s\n" "$E/models/other.gguf" "$E/models/p.gguf" >"$E/services/vision.env"
run_main "$E"
want_sha=$(sha256sum "$E/models/other.gguf" | cut -d' ' -f1); default_sha=$(sha256sum "$E/models/m.gguf" | cut -d' ' -f1)
has "hashes the model the unit loaded (from its env file), not the default name" "$EVD/identity.txt" "model_sha256=$want_sha"
hasnt "  not the default-named file" "$EVD/identity.txt" "model_sha256=$default_sha"
E="$(mkenv)"; rm -f "$E/services/vision.env"; run_main "$E"
check "no unit env file -> loaded model unknown -> not PASS (exit 2)" "$RC" "2"
fi

if want d7; then
echo "== D7/L5. overrides only under LT_HERMETIC=1; evidence perms 0700/0600 =="
# non-hermetic run: stale exported LT_* / *_BIN must be ignored
E="$(mkenv)"; setpsi "$E" 50.00 50.00; setmem "$E" 1
echo '[{"profile":"coder","port":8081,"mode":"x","ram_mb":9000,"vram_mb":7000,"enabled":true,"state":"running","last_log_line":null}]' >"$E/fake/others.json"
RC=0; FAKE="$E/fake" PATH="$E/bin:$PATH" LT_PSI="$E/psi" LT_MEMINFO="$E/meminfo" LLMCTL_BIN=/nonexistent/llmctl NVIDIA_SMI_BIN=/nonexistent/nv SYSTEMCTL_BIN=/nonexistent/sc \
  LT_EVIDENCE_ROOT="$E/ev" HOME="$E/home" timeout 30 bash "$MAIN" >"$E/out.txt" 2>"$E/err.txt" || RC=$?
EVD="$(find "$E/ev" -mindepth 1 -maxdepth 1 -type d | head -1)"
check "non-hermetic: still exits 3 via the real gate path (llmctl from PATH, *_BIN ignored)" "$RC" "3"
hasnt "non-hermetic: exported LT_PSI/LT_MEMINFO not used (no psi_some=50.00)" "$EVD/gate.log" 'psi_some=50\.00'
hasnt "non-hermetic: exported LT_MEMINFO not used (no MemAvailable_MiB=1 )" "$EVD/gate.log" 'MemAvailable_MiB=1 '
has "non-hermetic: ignored overrides are logged in evidence" "$EVD/overrides.log" 'IGNORED.*LT_PSI'
# negative control: same env WITH LT_HERMETIC=1 honours them
RC=0; FAKE="$E/fake" PATH="$E/bin:$PATH" LT_HERMETIC=1 LT_PSI="$E/psi" LT_MEMINFO="$E/meminfo" LT_EVIDENCE_ROOT="$E/ev2" HOME="$E/home" timeout 30 bash "$MAIN" >"$E/out2.txt" 2>&1 || RC=$?
EVD2="$(find "$E/ev2" -mindepth 1 -maxdepth 1 -type d | head -1)"
has "NEG-CONTROL hermetic: LT_PSI honoured (psi_some=50.00)" "$EVD2/gate.log" 'psi_some=50\.00'
has "hermetic overrides are logged loudly in evidence" "$EVD2/overrides.log" 'HONOURED.*LT_PSI'
# watchdog standalone, non-hermetic: LT_MEMINFO ignored
E="$(mkenv)"; setmem "$E" 1; mkdir -p "$E/wdev"
FAKE="$E/fake" PATH="$E/bin:$PATH" LT_MEMINFO="$E/meminfo" LT_PSI="$E/psi" bash "$WD" vision "$E/wdev" $$ >/dev/null 2>&1 &
W=$!; sleep 3.5; kill -TERM "$W" 2>/dev/null; wait "$W" 2>/dev/null
[ ! -s "$E/wdev/trigger" ] && ok "watchdog non-hermetic ignores LT_MEMINFO=1MiB (no trigger)" || bad "watchdog honoured LT_MEMINFO outside hermetic: $(cat "$E/wdev/trigger")"
# permissions with a permissive outer umask
E="$(mkenv)"; ( umask 000; run_main "$E" ) ; EVD="$(find "$E/ev" -mindepth 1 -maxdepth 1 -type d | head -1)"
badd=$(find "$E/ev" -mindepth 1 -type d ! -perm 700 | wc -l); badf=$(find "$E/ev" -type f ! -perm 600 | wc -l)
check "evidence dirs all 0700" "$badd" "0"
check "evidence files all 0600" "$badf" "0"
[ "$(find "$E/ev" -type f | wc -l)" -gt 10 ] && ok "NEG-CONTROL: many files were checked" || bad "too few files"
fi

if want always; then
echo "== 7. whole-suite sanity: nothing real was touched =="
[ -z "$(pgrep -f 'llama-server.*--port' || true)" ] && ok "no real llama-server process spawned by tests" || bad "llama-server present (may be pre-existing)"

fi
printf '\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
