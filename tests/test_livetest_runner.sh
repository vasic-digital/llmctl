#!/usr/bin/env bash
# shellcheck disable=SC2034  # MAIN/WD are read by the sourced lib
# test_livetest_runner.sh - hermetic tests of scripts/livetest/run_profiles.sh (the sequential runner over the guarded driver).
# The REAL runner drives the REAL driver and watchdog against the fake environment of tests/livetest_fake_lib.sh (fake llmctl,
# systemctl, nvidia-smi, health server); no model, unit or container is started. Each behaviour has a NEGATIVE CONTROL:
#   strictly sequential (never overlapping, never parallel), explicit ordered list or --fitting (derived from catalog + plan +
#   downloads), pre-gate re-checked between runs, stop at the FIRST non-zero exit (a watchdog abort is never continued past),
#   one summary table, refusal of an invalid/large-without-flag profile anywhere in the list before anything starts,
#   a second concurrent runner refused, a profile of the sequence already running refused.
# STRICT-EXEMPT: the suite runs failing commands on purpose and counts failures itself (ok/bad), so no -e
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN="$ROOT/scripts/livetest/vision_live_test.sh"
WD="$ROOT/scripts/livetest/watchdog.sh"
RUN="$ROOT/scripts/livetest/run_profiles.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/livetest.XXXXXX")"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL  %s  -- %s\n' "$1" "${2:-}"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3' got '$2'"; fi; }
has()  { if grep -qE -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1" "no /$3/ in $2"; fi; }
hasnt(){ if grep -qE -- "$3" "$2" 2>/dev/null; then bad "$1" "unexpected /$3/ in $2"; else ok "$1"; fi; }
export LT_POSTFIRE=2
want() { [ -z "${ONLY:-}" ] || [[ ",$ONLY," == *",$1,"* ]]; }
# shellcheck source=tests/livetest_fake_lib.sh
source "$ROOT/tests/livetest_fake_lib.sh"

# the judge's real JSON per suite
JD="$T/judge"; mkdir -p "$JD"
real_judge chat-v1 "$JD/chat-v1.json"
cp "$ROOT/tests/fixtures/livetest/real_judge_pass.json" "$JD/vision-golden-v1.json"

# run_seq <env> <runner args...>: hermetic runner run; RC = its exit code; SEQD = its sequence evidence dir
run_seq() {
  local E="$1"; shift
  RC=0
  cp "$JD/chat-v1.json" "$E/fake/validate_file.fast"; cp "$JD/chat-v1.json" "$E/fake/validate_file.small"
  FAKE="$E/fake" PATH="$E/bin:$PATH" LT_HERMETIC=1 LT_WD_INTERVAL=0.2 LT_WD_MAX_WALL="${WALL:-600}" LT_SETTLE=1 \
    LT_READY_INTERVAL=0.2 LT_READY_MAX=4 LT_VRAM_SETTLE_MAX=2 LT_VALIDATE_GRACE=3 \
    LT_MEMINFO="$E/meminfo" LT_PSI="$E/psi" LT_IOPSI="$E/iopsi" LT_EVIDENCE_ROOT="$E/ev" HOME="$E/home" \
    LLMCTL_SERVICES_DIR="$E/services" LLMCTL_RUNTIME_DIR="$E/run" LLMCTL_MODELS_DIR="$E/modelsdir" \
    LT_SUITE_DIR="$E/suite" LT_SUITES_ROOT="$E/suites" LT_CATALOG="$E/catalog.json" LT_VERIFY_BOUND=5 LT_PLAN_BOUND=5 \
    LT_STOP_BOUND=2 LT_BOUND=2 LT_START_MAX=20 LT_START_WAIT=15 LT_POST_SAMPLE=2 \
    timeout 240 bash "$RUN" "$@" >"$E/out.txt" 2>"$E/err.txt" || RC=$?
  SEQD="$(find "$E/ev" -mindepth 1 -maxdepth 1 -type d -name '*-sequence' 2>/dev/null | head -1)"
}
# the order of the fake llmctl's start/stop calls, e.g. "start:fast stop:fast start:vision stop:vision"
order() { awk '/^start /{print "start"} /^stop [a-z]/{print "stop:" $2}' "$1/fake/calls" | tr '\n' ' ' | sed 's/ $//'; }
starts() { grep -c '^start ' "$1/fake/calls"; }

if want seq; then
echo "== R1. explicit ordered list: strictly sequential, one summary table =="
E="$(mkenv fast)"; run_seq "$E" fast vision
check "fast then vision both PASS: runner exit 0" "$RC" "0"
check "exactly two starts (one per profile)" "$(starts "$E")" "2"
l_sf=$(grep -n '^stop fast$' "$E/fake/calls" | head -1 | cut -d: -f1); l_vs=$(awk '/^start /{n++; if(n==2){print NR; exit}}' "$E/fake/calls")
[ -n "$l_sf" ] && [ -n "$l_vs" ] && [ "$l_sf" -lt "$l_vs" ] && ok "stop of fast (call #$l_sf) precedes the start of the second profile (#$l_vs): never overlapping" || bad "overlap/order" "stop fast=$l_sf second start=$l_vs"
[ ! -e "$E/fake/overlap" ] && ok "the fake never saw a start while a profile was running" || bad "OVERLAP" "$(cat "$E/fake/overlap")"
has "summary table lists fast with exit 0" "$E/out.txt" '^1 +fast +0 +PASS'
has "summary table lists vision with exit 0" "$E/out.txt" '^2 +vision +0 +PASS'
has "summary says SEQUENCE: PASS" "$E/out.txt" 'SEQUENCE: PASS \(2 of 2'
check "evidence: one dir for the fast run" "$(find "$E/ev" -mindepth 1 -maxdepth 1 -type d -name '*-fast' | wc -l)" "1"
check "evidence: two dirs for vision (the gate-only re-check + the run)" "$(find "$E/ev" -mindepth 1 -maxdepth 1 -type d -name '*-vision' | wc -l)" "2"
has "between the runs the pre-gate was re-checked without starting anything (gate-only)" "$E/err.txt" 're-checking the pre-gate for .vision.'
[ -s "$SEQD/summary.txt" ] && ok "summary.txt kept in the sequence evidence dir" || bad "summary.txt missing"
# the runner never backgrounds the driver and sends no signal
hasnt "runner source: the driver is never backgrounded" <(grep -vE '^\s*#' "$RUN") '"\$DRIVER".*&\s*$'
hasnt "runner source: no kill/pkill/killall at all" <(grep -vE '^\s*#' "$RUN") '\b(kill|pkill|killall)\b'
hasnt "runner source: no process-group or reboot verbs" <(grep -vE '^\s*#' "$RUN") 'pgid|kill +-[0-9]|reboot|poweroff|suspend'
fi

if want stop; then
echo "== R2. stops at the first non-zero exit =="
E="$(mkenv vision)"; cp "$JD/vision-golden-v1.json" "$E/fake/validate_file.vision"; echo 1 >"$E/fake/validate_rc"; cp "$JD/vision-golden-v1.json" "$E/fake/validate_file"
run_seq "$E" vision fast
check "first profile FAILs (validate rc 1): runner exits 1" "$RC" "1"
check "only one start: the second profile was never started" "$(starts "$E")" "1"
has "summary: fast is NOT RUN" "$E/out.txt" '^2 +fast +- +NOT RUN'
has "summary: SEQUENCE STOPPED at vision (exit 1)" "$E/out.txt" "STOPPED at 'vision' \(exit 1\)"
E="$(mkenv vision)"; run_seq "$E" vision fast
check "NEG-CONTROL: with a passing first profile the second one runs (exit 0)" "$RC" "0"

echo "== R3. a watchdog abort is never continued past =="
E="$(mkenv vision)"; touch "$E/fake/validate_wait"; printf 'echo 11501 >"$FAKE/gpu"\n' >"$E/fake/mutate.sh"
run_seq "$E" vision fast
check "watchdog abort (GPU 11501) in the first profile: runner exit 4" "$RC" "4"
check "the second profile was never started" "$(starts "$E")" "1"
has "summary shows the abort" "$E/out.txt" '^1 +vision +4 +ABORTED'
has "summary: fast NOT RUN" "$E/out.txt" '^2 +fast +- +NOT RUN'
has "the first profile was stopped" "$E/fake/calls" '^stop vision$'
E="$(mkenv fast)"; touch "$E/fake/validate_wait"; printf 'echo 11501 >"$FAKE/gpu"\n' >"$E/fake/mutate.sh"
run_seq "$E" fast vision; check "abort in the FIRST of [fast vision]: runner exit 4, vision not started" "$RC$(starts "$E")" "41"
# a refusal (exit 3) stops the sequence as well
E="$(mkenv vision)"; setmem "$E" 11999; run_seq "$E" vision fast
check "first profile refused by the pre-gate (exit 3): runner exit 3, nothing started" "$RC$(starts "$E")" "30"

echo "== R4. the pre-gate is re-checked between runs =="
E="$(mkenv vision)"; printf 'printf "MemAvailable: %%d kB\\n" %d >"${FAKE%%/fake}/meminfo"\n' $((8000*1024)) >"$E/fake/mutate.sh"
run_seq "$E" vision fast
check "host got stressed during the first run (8000 MiB, above the watchdog floor): first PASSed, runner exit 3" "$RC" "3"
check "the second profile was NOT started: its gate-only re-check refused" "$(starts "$E")" "1"
has "summary: first profile PASS exit 0" "$E/out.txt" '^1 +vision +0 +PASS'
has "summary: second GATE-REFUSED before start" "$E/out.txt" '^2 +fast +3 +GATE-REFUSED'
has "the refusal says why (MemAvailable)" "$SEQD/fast.gate.out" 'MemAvailable'
fi

if want pre; then
echo "== R5. preflight of the whole list + profile-of-the-sequence-running + concurrent runner =="
E="$(mkenv)"; run_seq "$E" fast nosuch
check "unknown profile anywhere in the list: refused before ANYTHING starts (exit 3)" "$RC$(starts "$E")" "30"
E="$(mkenv)"; run_seq "$E" fast vision-pro
check "large profile in the list without --allow-large: whole sequence refused, fast never started" "$RC$(starts "$E")" "30"
has "  reason names --allow-large" "$E/err.txt" 'allow-large'
E="$(mkenv)"; cp "$JD/vision-golden-v1.json" "$E/fake/validate_file.vision-pro"; run_seq "$E" --allow-large vision-pro
check "NEG-CONTROL: the same large profile with --allow-large runs (exit 0)" "$RC" "0"
E="$(mkenv)"; run_seq "$E" fast fast; check "duplicate profile refused" "$RC" "3"
E="$(mkenv)"; run_seq "$E"; check "no profile and no --fitting refused" "$RC" "3"
E="$(mkenv)"; run_seq "$E" --fitting fast; check "--fitting together with an explicit list refused" "$RC" "3"
E="$(mkenv)"; run_seq "$E" --bogus fast; check "unknown option refused" "$RC" "3"
[ ! -s "$E/fake/calls.args" ] && ok "  usage refusals made no llmctl call" || bad "llmctl called on a usage error"
E="$(mkenv)"; echo '[{"profile":"fast","port":8080,"mode":"x","ram_mb":10,"vram_mb":0,"enabled":false,"state":"running","last_log_line":null}]' >"$E/fake/others.json"
run_seq "$E" vision fast
check "a profile OF THE SEQUENCE (fast) is already running: nothing started (exit 3)" "$RC$(starts "$E")" "30"
has "  reason: never a second profile while one is running" "$E/err.txt" 'never a second profile'
E="$(mkenv)"; echo '[{"profile":"small","port":'"$PORT"',"mode":"x","ram_mb":10,"vram_mb":0,"enabled":false,"state":"running","last_log_line":null}]' >"$E/fake/others.json"
run_seq "$E" vision; check "NEG-CONTROL: an unrelated small profile running does not stop the sequence" "$RC" "0"
# a second concurrent runner is refused (the flock is held by someone else)
E="$(mkenv)"; mkdir -p "$E/ev"; flock "$E/ev/.runner.lock" sleep 20 & LK=$!
sleep 0.5; run_seq "$E" vision
check "a second runner while the lock is held: refused (exit 3), nothing started" "$RC$(starts "$E")" "30"
has "  reason names the lock" "$E/err.txt" 'runner.lock'
kill "$LK" 2>/dev/null; wait "$LK" 2>/dev/null
E="$(mkenv)"; mkdir -p "$E/ev"; run_seq "$E" vision; check "NEG-CONTROL: with the lock free the runner runs" "$RC" "0"
fi

if want fitting; then
echo "== R6. --fitting derives the list from catalog + plan + downloads, smallest first =="
mkdl() { local e="$1"; shift; mkdir -p "$e/modelsdir"; local d; for d in "$@"; do mkdir -p "$e/modelsdir/$d"; done; }
E="$(mkenv)"; mkdl "$E" fast vision embed-x vision-pro coder small colibri-glm decide
python3 -I -c 'import json,sys;p=json.load(open(sys.argv[1]));p["profiles"]["small"]["fits"]=False;json.dump(p,open(sys.argv[1],"w"))' "$E/fake/plan.json"
cp "$JD/chat-v1.json" "$E/fake/validate_file.embed-x"   # placeholder: embed-x is judged below
real_judge embedding-v1 "$E/fake/validate_file.embed-x"
run_seq "$E" --fitting
check "--fitting run: exit 0" "$RC" "0"
check "derived list = smallest footprint first, large/not-fitting/no-suite/not-llama profiles left out" "$(tr '\n' ' ' <"$SEQD/profiles.txt" | sed 's/ $//')" "embed-x vision fast"
check "three starts (one per derived profile), strictly one at a time" "$(starts "$E")" "3"
[ ! -e "$E/fake/overlap" ] && ok "never overlapping" || bad "overlap"
E="$(mkenv)"; mkdl "$E" fast vision-pro coder; cp "$JD/vision-golden-v1.json" "$E/fake/validate_file.vision-pro"; cp "$JD/vision-golden-v1.json" "$E/fake/validate_file.coder"
run_seq "$E" --fitting
check "NEG-CONTROL: only large profiles downloaded, no flag -> list is just fast" "$(tr '\n' ' ' <"$SEQD/profiles.txt" | sed 's/ $//')" "fast"
E="$(mkenv)"; mkdl "$E" vision-pro; run_seq "$E" --allow-large --fitting
check "--allow-large --fitting includes the large downloaded profile" "$(tr '\n' ' ' <"$SEQD/profiles.txt" | sed 's/ $//')" "vision-pro"
E="$(mkenv)"; mkdl "$E"; run_seq "$E" --fitting; check "nothing downloaded: refused (exit 3), nothing started" "$RC$(starts "$E")" "30"
E="$(mkenv)"; mkdl "$E" fast; echo 1 >"$E/fake/plan_rc"; run_seq "$E" --fitting; check "plan failure: --fitting refused (exit 3)" "$RC$(starts "$E")" "30"
fi

if want extras; then
echo "== R7. extras switched off by a later driver run are restored by the runner =="
E="$(mkenv fast)"; cp "$JD/chat-v1.json" "$E/fake/validate_file.fast"; cp "$JD/chat-v1.json" "$E/fake/validate_file.small"
echo "[{\"profile\":\"decide\",\"port\":$PORT,\"ram_mb\":800,\"vram_mb\":0,\"enabled\":true,\"state\":\"running\"}]" >"$E/fake/others.json"
printf '[ -f "$FAKE/mutated" ] && exit 0; touch "$FAKE/mutated"\npython3 -I -c '"'"'import json,sys;f=sys.argv[1];r=json.load(open(f+"/others.json"));r.append({"profile":"extra","port":%d,"ram_mb":500,"vram_mb":0,"enabled":True,"state":"running"});json.dump(r,open(f+"/others.json","w"))'"'"' "$FAKE"\n' "$PORT" >"$E/fake/mutate.sh"
run_seq "$E" fast small
check "sequence exit 0" "$RC" "0"
has "the initial member is restored" "$E/fake/calls" '^restore decide$'
has "the extra profile (switched off by run 2) is restored too" "$E/fake/calls" '^restore extra$'
has "summary names it" "$E/out.txt" 'additionally restored: extra'

echo "== R8. profile names carry no dot (the scaled-instance parsing relies on it) =="
python3 -I - "$ROOT/models/catalog.json" "$E/catalog.json" <<'PY' && ok "no catalog profile name contains a '.'" || bad "a catalog profile name contains '.': the base-name parsing would break"
import json, sys
bad = [n for f in sys.argv[1:] for n in json.load(open(f))["profiles"] if "." in n]
print("dotted names:", bad) if bad else None
sys.exit(1 if bad else 0)
PY
fi

printf '\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -ne 0 ] || printf '  ok: all %d livetest runner assertions passed\n' "$PASS"
[ "$FAIL" = 0 ]
