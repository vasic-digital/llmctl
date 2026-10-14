#!/usr/bin/env bash
# shellcheck disable=SC2034  # RC/EVD/... are results read by the sourcing test files
# livetest_fake_lib.sh - shared hermetic harness of tests/test_livetest_*.sh (sourced; NOT a test itself -
# run_tests.sh only runs test_*.sh). set -euo pipefail is the callers' business; this file only defines functions
# and starts the fake /health server.
#
# Everything external is faked: /proc/meminfo, /proc/pressure/* (LT_MEMINFO/LT_PSI/LT_IOPSI), nvidia-smi, systemctl,
# llmctl (start/stop/status/plan/models verify/validate), pkill/killall, llama-server and the model health endpoint.
# No real model, container, unit or llmctl is ever started. Requires from the caller: ROOT, MAIN (driver), WD
# (watchdog), $T (scratch dir), ok/bad/check/has/hasnt.

# ---- health server (fake llama-server /health) ----
cat >"$T/srv.py" <<'PY'
import glob, http.server, sys
T = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        up = bool(glob.glob(T + "/env.*/fake/running") or glob.glob(T + "/env.*/fake/serving") or glob.glob(T + "/env.*/fake/restored"))
        open(T + "/health_paths", "a").write(self.path + "\n")
        import os
        body = open(T + "/health_body", "rb").read() if os.path.exists(T + "/health_body") else b'{"status":"ok"}'
        self.send_response(200 if up else 503); self.end_headers(); self.wfile.write(body if up else b"down")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
PORT="$(python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
python3 -I "$T/srv.py" "$PORT" "$T" >/dev/null 2>&1 &
HS_PID=$!
sleep 1
BYSTANDER_PID=""
(sleep 7200) & BYSTANDER_PID=$!
cleanup_t() { kill "$HS_PID" "$BYSTANDER_PID" 2>/dev/null; rm -rf "$T"; }   # test's own children only
trap cleanup_t EXIT

# ---- build one fake environment: $E/{bin,fake,ev,...}; echo its path ----
mkenv() {
  local PROF="${1:-vision}"
  rm -f "$T"/env.*/fake/running "$T"/env.*/fake/serving "$T"/env.*/fake/restored   # previous scenarios must not keep the shared fake health server "up"
  local E; E="$(mktemp -d "$T/env.XXXXXX")"
  mkdir -p "$E/bin" "$E/fake" "$E/ev" "$E/models" "$E/run"
  printf 'MemTotal: 32000000 kB\nMemAvailable:   %d kB\n' $((20000*1024)) >"$E/meminfo"
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' >"$E/psi"
  echo 1200 >"$E/fake/gpu"; echo 1200 >"$E/fake/gpu_base"
  echo '[]' >"$E/fake/others.json"; : >"$E/fake/calls"
  echo "$PORT" >"$E/fake/port"
  echo 0 >"$E/fake/validate_rc"; echo 0 >"$E/fake/start_rc"
  echo "$PROF" >"$E/fake/profile"
  mkdir -p "$E/services" "$E/suites"
  # one unit env file per profile the tests may run: the unit loads $E/models/m.gguf (+ p.gguf for the vision profiles)
  local sp
  for sp in vision vision-pro fast coder embed-x small; do
    case "$sp" in
      vision|vision-pro) printf "LLMCTL_ENGINE='llama'\nLLMCTL_ARGS=-m %s --mmproj %s --port 8082\n" "$E/models/m.gguf" "$E/models/p.gguf" >"$E/services/$sp.env" ;;
      *) printf "LLMCTL_ENGINE='llama'\nLLMCTL_ARGS=-m %s --port 8082\n" "$E/models/m.gguf" >"$E/services/$sp.env" ;;
    esac
  done
  # suites: the REAL suite files (vision = the fixture copy of the golden expectations, as before); $E/suite is the legacy alias
  mkdir -p "$E/suites/vision-golden-v1"
  cp "$ROOT/tests/fixtures/livetest/vision-golden-v1/expectations.json" "$E/suites/vision-golden-v1/expectations.json"
  for sp in chat-v1 coder-v1 embedding-v1; do mkdir -p "$E/suites/$sp"; cp "$ROOT/validation/suites/$sp/suite.json" "$E/suites/$sp/suite.json"; done
  ln -s "$E/suites/vision-golden-v1" "$E/suite"
  # catalog = the real catalog + one embedding profile (the real catalog has none); plan = every profile fits, sized from its files
  python3 -I - "$ROOT/models/catalog.json" "$E/catalog.json" "$E/fake/plan.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
c["profiles"]["embed-x"]={"capability":["embedding"],"min_tier":"baseline","port":8099,"defaults":{"ctx":2048,"ngl":99,"parallel":1,"flash_attn":"auto"},
  "desc":"hermetic embedding fixture profile","engine":"llama","hf_repo":"x/y","hf_revision":"main",
  "files":[{"name":"embed-x.gguf","size":314572800,"sha256":"0"*64,"role":"model"}],"validation":{"suites":["embedding-v1"]}}
json.dump(c,open(sys.argv[2],"w"))
plan={"tier":"workstation","budgets":{"ram_mb":60000,"vram_mb":20000,"vram_live":True,"storage_free_mb":1000000},"profiles":{}}
for n,p in c["profiles"].items():
    mb=(sum(f.get("size") or 0 for f in p["files"])+1048575)//1048576
    plan["profiles"][n]={"mode":"gpu","ram_mb":mb+500,"vram_mb":mb,"fits":True,"engine":p["engine"],"min_tier":p["min_tier"],"tier_ok":True,"port":p["port"]}
json.dump(plan,open(sys.argv[3],"w"))
PY
  cp "$ROOT/tests/fixtures/livetest/real_judge_pass.json" "$E/fake/validate_file"
  printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' >"$E/iopsi"
  echo fake-model >"$E/models/m.gguf"; echo fake-mmproj >"$E/models/p.gguf"
  cat >"$E/bin/nvidia-smi" <<'X'
#!/usr/bin/env bash
[ -f "$FAKE/gpu_hang" ] && sleep "$(cat "$FAKE/gpu_hang")"
case "$*" in
  *memory.total*) [ -f "$FAKE/gpu_total_fail" ] && { echo "N/A"; exit 0; }; cat "$FAKE/gpu_total" 2>/dev/null || echo 24000 ;;
  *memory.free*)  [ -f "$FAKE/gpu_total_fail" ] && { echo "N/A"; exit 0; }; echo $(( $(cat "$FAKE/gpu_total" 2>/dev/null || echo 24000) - $(cat "$FAKE/gpu") )) ;;
  *) cat "$FAKE/gpu" ;;
esac
X
  cat >"$E/bin/systemctl" <<'X'
#!/usr/bin/env bash
# fake systemctl: list-units reads $FAKE/units; stop/is-active act on the fake running state
case "$*" in
  *"--user stop "*) echo "systemctl stop ${*: -1}" >>"$FAKE/calls"; rm -f "$FAKE/running"
     [ -f "$FAKE/sysstop_fail" ] && exit 1
     [ -f "$FAKE/leak" ] || cp "$FAKE/gpu_base" "$FAKE/gpu"; exit 0 ;;
  *"--user is-active"*) if [ -f "$FAKE/unit_state" ]; then cat "$FAKE/unit_state"; [ "$(cat "$FAKE/unit_state")" = active ] && exit 0; exit 3; fi
     if [ -f "$FAKE/running" ] || [ -f "$FAKE/unit_stuck_active" ]; then echo active; exit 0; else echo inactive; exit 3; fi ;;
  *"--user show"*) [ -f "$FAKE/cgshow" ] && cat "$FAKE/cgshow"; echo "show ${*: -1}" >>"$FAKE/calls"; exit 0 ;;
  *"list-units"*) [ -f "$FAKE/units" ] || exit 0
     for a in "$@"; do case "$a" in *@*) pat="@${a##*@}"; pat="${pat%%.service}"; pat="${pat%\*}";; esac; done
     grep -F -- "${pat:-}" "$FAKE/units"; exit 0 ;;
  *) exit 0 ;;
esac
X
  for n in pkill killall; do printf '#!/usr/bin/env bash\necho "%s $*" >>"$FAKE/forbidden"\n' "$n" >"$E/bin/$n"; done
  printf '#!/usr/bin/env bash\necho "fake journal line for $*"\n' >"$E/bin/journalctl"
  printf '#!/usr/bin/env bash\necho "llama-server fake version: 1 (testbuild)"\n' >"$E/bin/llama-server"
  cat >"$E/bin/llmctl" <<'X'
#!/usr/bin/env bash
# fake llmctl: never starts anything real
echo "$*" >>"$FAKE/calls.args"
case "$1 ${2:-}" in
  "status --json")
    [ -f "$FAKE/status_hang" ] && sleep "$(cat "$FAKE/status_hang")"
    python3 -I - "$FAKE" <<'PY'
import json,os,sys
f=sys.argv[1]; rows=json.load(open(f+"/others.json"))
if os.path.exists(f+"/running"):
    rows.append({"profile":open(f+"/profile").read().strip(),"port":int(open(f+"/port").read()),"mode":"x","ram_mb":3000,"vram_mb":1500,"enabled":False,"state":"running","last_log_line":None})
print(json.dumps(rows))
PY
    ;;
  "start "*|"switch "*)
    # a start of a profile that a previous `switch` stopped (the prior set) is a RESTORE: never the profile under test
    if [ "$1" = start ] && python3 -I -c 'import json,os,sys
f=sys.argv[1]+"/others.stopped.json"
sys.exit(0 if os.path.exists(f) and any(r.get("profile")==sys.argv[2] for r in json.load(open(f))) else 1)' "$FAKE" "$2"; then
      echo "restore $2" >>"$FAKE/calls"
      [ -f "$FAKE/running" ] && echo "restore $2 while $(cat "$FAKE/profile") is running" >>"$FAKE/overlap"
      [ -f "$FAKE/restore_fail.$2" ] && { echo "cannot start $2" >&2; exit 1; }
      [ -f "$FAKE/restore_slow" ] && sleep "$(cat "$FAKE/restore_slow")"
      python3 -I - "$FAKE" "$2" <<'PY'
import json,sys
f,n=sys.argv[1],sys.argv[2]
rows=json.load(open(f+"/others.json")); st=[r for r in json.load(open(f+"/others.stopped.json")) if r["profile"]==n]
if not any(r["profile"]==n for r in rows): rows+=st
import os
if os.path.exists(f+"/rollback_instances"):   # llmctl's own rollback brought the scaled instances back too
    for r in json.load(open(f+"/others.stopped.json")):
        if "." in r["profile"] and not any(x["profile"]==r["profile"] for x in rows): rows.append(r)
json.dump(rows,open(f+"/others.json","w"))
PY
      [ -f "$FAKE/restore_unhealthy.$2" ] || touch "$FAKE/restored"
      exit 0
    fi
    if [ "$1" = switch ]; then   # llmctl switch: stops EVERY running profile, then starts the target (fake: park the prior set)
      echo "switch $2" >>"$FAKE/calls"
      python3 -I - "$FAKE" <<'PY'
import json,sys
f=sys.argv[1]; rows=json.load(open(f+"/others.json"))
if rows:
    try: old=json.load(open(f+"/others.stopped.json"))
    except Exception: old=[]
    have={r["profile"] for r in old}
    json.dump(old+[r for r in rows if r["profile"] not in have],open(f+"/others.stopped.json","w")); json.dump([],open(f+"/others.json","w"))
PY
      rm -f "$FAKE/restored"
      [ -f "$FAKE/switch_fail" ] && { echo "switch failed" >&2; exit 1; }
    fi
    [ -f "$FAKE/running" ] && echo "start $2 while $(cat "$FAKE/profile") is running" >>"$FAKE/overlap"
    echo "$2" >"$FAKE/profile"
    echo "start env=${LLMCTL_VALIDATE_ON_START:-unset} ready_timeout=${LLMCTL_READY_TIMEOUT:-unset} nice=$(awk '{print $19}' /proc/$$/stat) ionice=$(ionice -p $$ 2>&1)" >>"$FAKE/calls"
    [ -f "$FAKE/start_delay" ] && sleep "$(cat "$FAKE/start_delay")"   # before svc_start: nothing exists yet
    rc=$(cat "$FAKE/start_rc"); [ "$rc" = 0 ] && touch "$FAKE/running"
    [ -f "$FAKE/gpu_after_start" ] && cp "$FAKE/gpu_after_start" "$FAKE/gpu"
    [ -f "$FAKE/start_mutate.sh" ] && bash "$FAKE/start_mutate.sh"
    if [ -f "$FAKE/start_sleep" ]; then   # simulates holding the scheduler flock across svc_start + readiness
      touch "$FAKE/lock_held"; sleep "$(cat "$FAKE/start_sleep")"; rm -f "$FAKE/lock_held"; echo "start returned" >>"$FAKE/calls"
    fi
    exit "$rc" ;;
  "stop "*)
    echo "$2" >"$FAKE/stop_last_profile"
    n=0; while [ -f "$FAKE/lock_held" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n+1)); done   # blocked on the lock
    echo "stop $2" >>"$FAKE/calls"
    [ -f "$FAKE/stop_slow" ] && sleep "$(cat "$FAKE/stop_slow")"
    [ -f "$FAKE/stop_rc1" ] && { rm -f "$FAKE/running_keep"; rm -f "$FAKE/running"; echo "stop failed" >&2; exit 1; }
    rm -f "$FAKE/running"
    [ -f "$FAKE/leak" ] || cp "$FAKE/gpu_base" "$FAKE/gpu"
    [ -f "$FAKE/hang_after_stop" ] && { echo 25 >"$FAKE/gpu_hang"; echo 25 >"$FAKE/status_hang"; }
    [ -f "$FAKE/stop_leaves_port" ] && touch "$FAKE/serving"
    exit 0 ;;
  "plan --json") echo "plan --json" >>"$FAKE/calls"; [ -f "$FAKE/plan_hang" ] && sleep "$(cat "$FAKE/plan_hang")"; cat "$FAKE/plan.json"; exit "$(cat "$FAKE/plan_rc" 2>/dev/null || echo 0)" ;;
  "models verify")
    echo "verify $3 nice=$(awk '{print $19}' /proc/$$/stat) ionice=$(ionice -p $$ 2>&1)" >>"$FAKE/calls"
    [ -f "$FAKE/verify_hang" ] && sleep "$(cat "$FAKE/verify_hang")"
    if [ -f "$FAKE/verify_rc.$3" ]; then exit "$(cat "$FAKE/verify_rc.$3")"; fi
    exit "$(cat "$FAKE/verify_rc" 2>/dev/null || echo 0)" ;;
  "help "|"help"|"--help ") echo "help" >>"$FAKE/calls"; if [ -f "$FAKE/help_nohost" ]; then echo "  validate <profile> [--json] [--keep]"; else echo "  validate <profile> [--host URL] [--json] [--keep]"; fi; exit 0 ;;
  "vision help") echo "vision help" >>"$FAKE/calls"; if [ -f "$FAKE/help_nohost" ]; then echo "llmctl vision validate [--profile vision|vision-pro] [--json] [--keep]"; else echo "llmctl vision validate [--profile vision|vision-pro] [--host URL] [--json] [--keep]"; fi; exit 0 ;;
  "logs "*) echo "fake log line"; exit 0 ;;
  "version "*|"version") echo "llmctl fake-1.0"; exit 0 ;;
  "vision validate"|"validate "*)
    echo "validate $*" >>"$FAKE/calls"
    echo "validate_nice=$(awk '{print $19}' /proc/$$/stat) $(ionice -p $$ 2>&1)" >>"$FAKE/calls"
    [ -f "$FAKE/mutate.sh" ] && bash "$FAKE/mutate.sh"
    n=0; while [ -f "$FAKE/running" ] && [ -f "$FAKE/validate_wait" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n+1)); done
    if [ ! -f "$FAKE/running" ]; then
      case " $* " in
        *" --host "*) echo "connection refused" >&2; exit 2 ;;
        *) echo "validate RESTARTED profile (no --host, no .run)" >>"$FAKE/calls"; touch "$FAKE/running"; echo "restarted" >&2; exit 2 ;;
      esac
    fi
    cat "$FAKE/validate_file.$(cat "$FAKE/profile")" 2>/dev/null || cat "$FAKE/validate_file"   # per-profile output for sequences, else the single file
    exit "$(cat "$FAKE/validate_rc")" ;;
  *) echo "fake llmctl: unexpected: $*" >>"$FAKE/calls"; exit 64 ;;
esac
X
  chmod +x "$E"/bin/*
  echo "$E"
}

# mainenv <env>: fills MENV with the hermetic environment of one driver run (used by run_main and start_main)
mainenv() {
  local E="$1"
  MENV=(FAKE="$E/fake" PATH="$E/bin:$PATH" LT_HERMETIC=1 LT_WD_INTERVAL=0.2 LT_WD_MAX_WALL="${WALL:-600}"
    LT_READY_INTERVAL=0.2 LT_READY_MAX="${READY_MAX:-4}" LT_VRAM_SETTLE_MAX=2 LT_VALIDATE_GRACE=3
    LT_MEMINFO="$E/meminfo" LT_PSI="$E/psi" LT_IOPSI="$E/iopsi" LT_EVIDENCE_ROOT="$E/ev" HOME="$E/home"
    LLMCTL_SERVICES_DIR="$E/services" LLMCTL_RUNTIME_DIR="$E/run" LT_SUITE_DIR="$E/suite" LT_SUITES_ROOT="$E/suites" LT_CATALOG="$E/catalog.json"
    LT_VERIFY_BOUND=5 LT_PLAN_BOUND=5 LT_RESTORE_READY_MAX=3 LT_RESTORE_BOUND="${RESTORE_BOUND_T:-5}" LT_STOP_BOUND=2 LT_BOUND=2
    LT_START_MAX="${START_MAX:-20}" LT_START_WAIT="${LT_START_WAIT_T:-15}" LT_POST_SAMPLE=2)
}
# run_main <env> [args...]: hermetic run, returns exit code in $RC, evidence dir in $EVD
run_main() {
  local E="$1"; shift
  RC=0; mainenv "$E"
  env "${MENV[@]}" timeout 60 bash "$MAIN" "$@" >"$E/out.txt" 2>"$E/err.txt" || RC=$?
  EVD="$(find "$E/ev" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
}
# start_main <env> [args...]: the same run in the BACKGROUND without `timeout` (so a signal reaches the driver itself); pid in MAINPID
start_main() {
  local E="$1"; shift
  mainenv "$E"
  env "${MENV[@]}" bash "$MAIN" "$@" >"$E/out.txt" 2>"$E/err.txt" &
  MAINPID=$!
}
setmem() { printf 'MemAvailable:   %d kB\n' $(( $2 * 1024 )) >"$1/meminfo"; }
setpsi() { printf 'some avg10=%s avg60=0 avg300=0 total=1\nfull avg10=%s avg60=0 avg300=0 total=1\n' "$2" "$3" >"$1/psi"; }
calls_has_start() { grep -q '^start ' "$1/fake/calls"; }

# real_judge <suite-name> <out-file> [answers-file]: the REAL lib/validate_judge.py `run --json` against the
# deterministic fixture server tests/fixtures/validation/fake_openai.py (an answer table, not a model). Used to
# get the exact JSON shape the real judge emits for chat/coder/embedding suites. Result cached per suite.
real_judge() {
  local suite="$1" out="$2" ans="${3:-$ROOT/tests/fixtures/validation/answers_good.json}"
  local pf="$T/rj.$suite.$RANDOM.port" pid
  python3 -I "$ROOT/tests/fixtures/validation/fake_openai.py" --suite "$ROOT/validation/suites/$suite" --answers "$ans" \
    --port-file "$pf" --model-id /m/x/model.gguf --max-seconds 120 >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -s "$pf" ] && break; sleep 0.1; done
  LLMCTL_VALIDATE_TIMEOUT=30 python3 -I "$ROOT/lib/validate_judge.py" run --suite "$ROOT/validation/suites/$suite" \
    --endpoint "http://127.0.0.1:$(cat "$pf")" --expect-model model.gguf --json >"$out" 2>/dev/null || true
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
}
