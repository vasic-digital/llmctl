#!/usr/bin/env bash
# shellcheck disable=SC2034  # MAIN/WD are read by the sourced lib
# test_livetest_switch.sh - hermetic tests of the DYNAMIC-SWITCHING contract of the live-test driver and runner:
#   * the running llmctl set is RECORDED before a run (status json + llmctl units) and the profile under test is loaded with
#     llmctl's own `llmctl switch <profile>` (stops the others, starts exactly that profile; no model is killed by us);
#   * afterwards - also after a watchdog abort, a failed start, a failed stop - the recorded set is RESTORED through
#     `llmctl start`, pressure-gated, one profile at a time, each verified healthy; a skipped (pressure) or failed restore is
#     reported loudly with the exact manual command and a distinct exit code (6 skipped, 7 failed); restore is idempotent;
#   * only llmctl-owned units are touched, nothing is ever signalled, a foreign process is never touched;
#   * `--plan` prints what would be stopped/started/restored and does nothing.
# Everything is faked (tests/livetest_fake_lib.sh): no model, unit, container or real llmctl.
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

JD="$T/judge"; mkdir -p "$JD"
real_judge chat-v1 "$JD/chat-v1.json"
cp "$ROOT/tests/fixtures/livetest/real_judge_pass.json" "$JD/vision-golden-v1.json"
setchat() { cp "$JD/chat-v1.json" "$1/fake/validate_file"; }
# a resident (prior) set: rows like `llmctl status --json`
row() { printf '{"profile":"%s","port":%d,"mode":"gpu","ram_mb":%d,"vram_mb":%d,"enabled":true,"state":"running","last_log_line":null}' "$1" "$PORT" "${2:-800}" "${3:-0}"; }
setprior() { # setprior <env> name[:ram:vram]...
  local e="$1"; shift; local out="[" first=1 a n r v
  for a in "$@"; do IFS=: read -r n r v <<<"$a"; [ "$first" = 1 ] || out+=","; first=0; out+="$(row "$n" "${r:-800}" "${v:-0}")"; done
  echo "$out]" >"$e/fake/others.json"
}
run_run() { # run_run <env> <runner args...> (runner, same hermetic knobs as the driver)
  local E="$1"; shift; RC=0
  FAKE="$E/fake" PATH="$E/bin:$PATH" LT_HERMETIC=1 LT_WD_INTERVAL=0.2 LT_SETTLE=1 LT_READY_INTERVAL=0.2 LT_READY_MAX=4 LT_VALIDATE_GRACE=3 \
    LT_MEMINFO="$E/meminfo" LT_PSI="$E/psi" LT_IOPSI="$E/iopsi" LT_EVIDENCE_ROOT="$E/ev" HOME="$E/home" LLMCTL_SERVICES_DIR="$E/services" \
    LLMCTL_RUNTIME_DIR="$E/run" LLMCTL_MODELS_DIR="$E/modelsdir" LT_SUITE_DIR="$E/suite" LT_SUITES_ROOT="$E/suites" LT_CATALOG="$E/catalog.json" \
    LT_VERIFY_BOUND=5 LT_PLAN_BOUND=5 LT_STOP_BOUND=2 LT_BOUND=2 LT_START_MAX=20 LT_START_WAIT=15 LT_POST_SAMPLE=2 LT_RESTORE_READY_MAX=3 LT_RESTORE_BOUND=5 \
    timeout 240 bash "$RUN" "$@" >"$E/out.txt" 2>"$E/err.txt" || RC=$?
  SEQD="$(find "$E/ev" -mindepth 1 -maxdepth 1 -type d -name '*-sequence' 2>/dev/null | head -1)"
}
nstart() { grep -c "^$2 " "$1/fake/calls"; }   # number of fake-llmctl call lines starting with <verb>

if want flow; then
echo "== S1. prior set recorded, profile loaded with llmctl switch, prior set restored and verified =="
E="$(mkenv fast)"; setchat "$E"; setprior "$E" decide-nli:800:0 small:2000:1500
run_main "$E" fast
check "run with two resident profiles (decide-nli enabled service + small): exit 0 PASS" "$RC" "0"
has "the profile under test was loaded through llmctl's own switch" "$E/fake/calls" '^switch fast$'
hasnt "no plain start of the target (the scheduler path is switch)" "$E/fake/calls" '^start fast$'
has "the switch ran with the same safe env (no validate-on-start, no ready wait, nice 19, ionice idle)" "$E/fake/calls" '^start env=0 ready_timeout=0 nice=19 ionice=idle'
has "evidence: prior status json holds the enabled service" "$EVD/prior_status.json" 'decide-nli'
check "evidence: prior set file = the running profiles" "$(tr '\n' ' ' <"$EVD/prior_set.txt" | sed 's/ $//')" "decide-nli small"
[ -f "$EVD/prior_units.txt" ] && ok "evidence: prior llmctl units recorded" || bad "prior_units.txt missing"
has "evidence: switch command recorded" "$EVD/commands.log" 'llmctl switch fast|switch fast'
has "evidence: restore commands recorded" "$EVD/commands.log" 'start decide-nli'
has "restore: decide-nli started again by llmctl" "$E/fake/calls" '^restore decide-nli$'
has "restore: small started again by llmctl" "$E/fake/calls" '^restore small$'
has "restore.txt: decide-nli restored and healthy" "$EVD/restore.txt" '^decide-nli +RESTORED \(healthy\)'
has "restore.txt: small restored and healthy" "$EVD/restore.txt" '^small +RESTORED \(healthy\)'
has "after-set recorded" "$EVD/after_status.json" 'decide-nli'
has "verdict table has a restore row" "$EVD/verdict.txt" 'prior set restored +YES'
l_stop=$(grep -n '^stop fast$' "$E/fake/calls" | tail -1 | cut -d: -f1); l_rest=$(grep -n '^restore ' "$E/fake/calls" | head -1 | cut -d: -f1)
[ -n "$l_stop" ] && [ -n "$l_rest" ] && [ "$l_stop" -lt "$l_rest" ] && ok "restore only AFTER the model under test was stopped (#$l_stop < #$l_rest)" || bad "restore order" "stop=$l_stop restore=$l_rest"
[ ! -e "$E/fake/overlap" ] && ok "the model under test and a prior profile were never resident together" || bad "overlap" "$(cat "$E/fake/overlap")"
# NEG-CONTROL: nothing resident -> nothing to restore, no restore calls
E="$(mkenv fast)"; setchat "$E"; run_main "$E" fast
check "NEG-CONTROL: nothing resident: exit 0" "$RC" "0"
hasnt "  no restore call" "$E/fake/calls" '^restore '
has "  restore.txt says nothing to restore" "$EVD/restore.txt" 'nothing to restore'
has "  table: prior set restored n/a" "$EVD/verdict.txt" 'prior set restored +NONE'

echo "== S2. restore on every exit path =="
E="$(mkenv fast)"; setchat "$E"; setprior "$E" decide-nli; touch "$E/fake/validate_wait"; printf 'echo 11501 >"$FAKE/gpu"\n' >"$E/fake/mutate.sh"
run_main "$E" fast
check "watchdog abort during the run: exit 4" "$RC" "4"
has "  the prior set is still restored (pressure is fine in the fake)" "$E/fake/calls" '^restore decide-nli$'
has "  restore.txt: restored" "$EVD/restore.txt" '^decide-nli +RESTORED'
E="$(mkenv fast)"; setchat "$E"; setprior "$E" decide-nli; echo 1 >"$E/fake/switch_fail"
run_main "$E" fast
check "switch fails after stopping the resident set (worst case): exit 2" "$RC" "2"
has "  belt and braces: our restore brings the set back" "$E/fake/calls" '^restore decide-nli$'
E="$(mkenv fast)"; setchat "$E"; setprior "$E" decide-nli; echo 1 >"$E/fake/validate_rc"; echo x >"$E/fake/validate_file"
run_main "$E" fast
check "validate rc 1 (wrong answer): exit 1 FAIL, prior set still restored" "$RC$(grep -c '^restore decide-nli$' "$E/fake/calls")" "11"
E="$(mkenv fast)"; setchat "$E"; setprior "$E" decide-nli; touch "$E/fake/stop_rc1"; echo 1 >"$E/fake/sysstop_fail"
run_main "$E" fast
check "the final stop of the model under test cannot be confirmed: exit 2" "$RC" "2"
hasnt "  restore is NOT attempted while the test model may still be running" "$E/fake/calls" '^restore '
has "  restore.txt says why it was skipped" "$EVD/restore.txt" 'SKIPPED.*(stop|still)'
has "  the manual command is printed" "$E/err.txt" 'llmctl start decide-nli'

echo "== S3. restore skipped under pressure, failed, unhealthy, idempotent =="
E="$(mkenv fast)"; setchat "$E"; setprior "$E" decide-nli small
printf 'printf "some avg10=8.00 avg60=0 avg300=0 total=1\\nfull avg10=0.00 avg60=0 avg300=0 total=1\\n" >"${FAKE%%/fake}/psi"\n' >"$E/fake/mutate.sh"
run_main "$E" fast
check "run itself PASSes but memory PSI rose to 8 (< watchdog 20, >= gate 5): restore skipped -> exit 6" "$RC" "6"
hasnt "  no restore start was issued under pressure" "$E/fake/calls" '^restore '
has "  restore.txt: SKIPPED with the pressure reason" "$EVD/restore.txt" 'SKIPPED.*PSI'
has "  the exact manual command is printed for BOTH profiles" "$E/err.txt" 'llmctl start decide-nli small'
[ -s "$EVD/RESTORE_MANUAL.txt" ] && ok "  RESTORE_MANUAL.txt written" || bad "RESTORE_MANUAL.txt missing"
has "  verdict says the run PASSed but the restore did not happen" "$EVD/verdict.txt" 'prior set restored +NO \(SKIPPED'
# NEG-CONTROL: PSI just under the gate -> restored, exit 0
E="$(mkenv fast)"; setchat "$E"; setprior "$E" decide-nli
printf 'printf "some avg10=4.99 avg60=0 avg300=0 total=1\\nfull avg10=0.00 avg60=0 avg300=0 total=1\\n" >"${FAKE%%/fake}/psi"\n' >"$E/fake/mutate.sh"
run_main "$E" fast; check "NEG-CONTROL PSI 4.99: restore runs, exit 0" "$RC" "0"
# watchdog abort + pressure: own code 4 stays, restore reported skipped
E="$(mkenv fast)"; setchat "$E"; setprior "$E" decide-nli; touch "$E/fake/validate_wait"
printf 'printf "some avg10=25.00 avg60=0 avg300=0 total=1\\nfull avg10=0.00 avg60=0 avg300=0 total=1\\n" >"${FAKE%%/fake}/psi"\n' >"$E/fake/mutate.sh"
run_main "$E" fast
check "watchdog abort under pressure: exit stays 4 (the abort is not masked)" "$RC" "4"
has "  restore skipped, reported" "$EVD/restore.txt" 'SKIPPED'
# one restore fails, the other is still attempted; reported loudly; exit 7
E="$(mkenv fast)"; setchat "$E"; setprior "$E" decide-nli small; touch "$E/fake/restore_fail.decide-nli"
run_main "$E" fast
check "a profile cannot be restored: exit 7" "$RC" "7"
has "  decide-nli FAILED in restore.txt" "$EVD/restore.txt" '^decide-nli +FAILED'
has "  the other profile (small) was still restored" "$EVD/restore.txt" '^small +RESTORED \(healthy\)'
has "  loud message on stderr names the failed profile" "$E/err.txt" 'RESTORE FAILED.*decide-nli'
has "  manual command for the failed one" "$E/err.txt" 'llmctl start decide-nli'
E="$(mkenv fast)"; setchat "$E"; setprior "$E" decide-nli; touch "$E/fake/restore_unhealthy.decide-nli"
run_main "$E" fast
check "restored but never healthy: exit 7" "$RC" "7"
has "  restore.txt says not healthy" "$EVD/restore.txt" '^decide-nli +FAILED.*not healthy'
# idempotent --restore-only: everything already running -> no start calls, exit 0
E="$(mkenv fast)"; setprior "$E" decide-nli small; : >"$E/fake/restored"; touch "$E/fake/running"; rm -f "$E/fake/running"
printf 'decide-nli\nsmall\n' >"$E/set.txt"; touch "$E/fake/restored"
run_main "$E" --restore-only "$E/set.txt"
check "--restore-only with everything already running: exit 0" "$RC" "0"
hasnt "  idempotent: no restore start issued" "$E/fake/calls" '^restore '
has "  reports ALREADY RUNNING" "$EVD/restore.txt" 'ALREADY RUNNING'
E="$(mkenv fast)"; echo '[]' >"$E/fake/others.json"; setprior "$E" decide-nli; mv "$E/fake/others.json" "$E/fake/others.stopped.json"; echo '[]' >"$E/fake/others.json"
printf 'decide-nli\n' >"$E/set.txt"; run_main "$E" --restore-only "$E/set.txt"
check "--restore-only of a stopped profile: exit 0, restored" "$RC" "0"; has "  restore issued once" "$E/fake/calls" '^restore decide-nli$'
run_main "$E" --restore-only "$E/set.txt"
check "  second --restore-only (now running): still exit 0, no second start" "$RC$(grep -c '^restore decide-nli$' "$E/fake/calls")" "01"
fi

if want own; then
echo "== S4. only llmctl-owned things are touched; nothing is signalled =="
E="$(mkenv fast)"; setchat "$E"; setprior "$E" decide-nli
printf 'docker-foreign.service loaded active running a foreign unit\nllmctl-llama@decide-nli.service loaded active running decide\n' >"$E/fake/units"
run_main "$E" fast
check "run with a foreign unit listed: exit 0" "$RC" "0"
hasnt "no systemctl stop/start/restart at all in the normal path (llmctl does the stopping)" "$E/fake/calls" '^systemctl (stop|start|restart|kill)'
[ ! -e "$E/fake/forbidden" ] && ok "pkill/killall never called" || bad "forbidden" "$(cat "$E/fake/forbidden")"
[ -d "/proc/$BYSTANDER_PID" ] && ok "bystander (foreign process) alive" || bad "bystander dead"
has "the foreign unit is not in the recorded prior SET" "$EVD/prior_set.txt" '^decide-nli$'
hasnt "  foreign unit never becomes a restore target" "$EVD/prior_set.txt" 'foreign'
# watchdog abort: systemd fallback may stop ONLY the profile's own llmctl unit
E="$(mkenv fast)"; setchat "$E"; setprior "$E" decide-nli; touch "$E/fake/validate_wait" "$E/fake/stop_rc1"; printf 'echo 11501 >"$FAKE/gpu"\n' >"$E/fake/mutate.sh"
run_main "$E" fast
hasnt "even on the abort path no non-llmctl unit is stopped" <(grep '^systemctl stop' "$E/fake/calls" | grep -v 'llmctl-'; echo) '.'
has "  the fallback (if used) targets the llmctl unit of the test profile" "$E/fake/calls" '^systemctl stop llmctl-llama@fast\.service'
nk=$(grep -vE '^\s*#' "$MAIN" "$WD" "$RUN" | grep -cE '\b(kill|pkill|killall)\b'); check "still exactly one kill call site in driver+watchdog+runner" "$nk" "1"
hasnt "no stop of anything but the profile under test by us (resident ones are stopped by llmctl switch)" "$E/fake/calls" '^stop (decide-nli|small)$'

echo "== S5. resident models do not block a switch, but pressure and the adjusted budget still do =="
E="$(mkenv fast)"; setchat "$E"; setprior "$E" big:9000:7000; setmem "$E" 8000
printf 'printf "MemAvailable: %%d kB\\n" %d >"${FAKE%%/fake}/meminfo"\n' $((20000*1024)) >"$E/fake/mutate.sh"   # the switch freed the big model's RAM
run_main "$E" fast
check "9000 MiB resident + 8000 available -> 17000 effective >= 12000: accepted, exit 0" "$RC" "0"
has "  the resident big model is restored afterwards" "$E/fake/calls" '^restore big$'
E="$(mkenv fast)"; setchat "$E"; setprior "$E" small:3000:1500; setmem "$E" 8000
run_main "$E" fast
check "NEG-CONTROL 3000 resident + 8000 available = 11000 < 12000: refused (exit 3)" "$RC" "3"
hasnt "  nothing was switched, nothing restored" "$E/fake/calls" '^(switch|restore)'
E="$(mkenv fast)"; setchat "$E"; setprior "$E" small; setpsi "$E" 5.00 0
run_main "$E" fast; check "pressure refuses even with a small resident set (exit 3), nothing switched" "$RC$(grep -c '^switch' "$E/fake/calls")" "30"
E="$(mkenv fast)"; echo '[{"profile":"small","port":8083,"mode":"x","ram_mb":10,"vram_mb":0,"enabled":false,"state":"failed (crash-loop)","last_log_line":"x"}]' >"$E/fake/others.json"
run_main "$E" fast; check "a resident profile in a failed state is still a refusal (exit 3)" "$RC" "3"
fi

if want plan; then
echo "== S6. --plan: dry run =="
E="$(mkenv fast)"; setchat "$E"; setprior "$E" decide-nli small
run_main "$E" --plan fast
check "--plan: exit 0" "$RC" "0"
has "  says what would be stopped" "$E/out.txt" 'would stop.*decide-nli.*small'
has "  says what would be started" "$E/out.txt" 'would start.*fast'
has "  says what would be restored" "$E/out.txt" 'would restore.*decide-nli.*small'
has "  states the enabled-service interruption" "$E/out.txt" 'interrupt'
hasnt "  verdict is PLAN, not PASS" "$E/out.txt" 'VERDICT +PASS'
hasnt "  nothing was switched, started, stopped or restored" "$E/fake/calls" '^(switch|start|stop|restore|verify|validate)'
E="$(mkenv fast)"; run_main "$E" --plan vision-pro; check "--plan still applies the static refusals (vision-pro w/o --allow-large: exit 3)" "$RC" "3"
E="$(mkenv fast)"; setprior "$E" decide-nli; run_run "$E" --plan fast vision
check "runner --plan: exit 0" "$RC" "0"
has "  runner --plan lists the sequence" "$E/err.txt" 'sequence \(strictly one at a time\): fast vision'
has "  runner --plan says it switches profile to profile and restores at the end" "$E/out.txt" 'restore.*decide-nli'
hasnt "  runner --plan did nothing" "$E/fake/calls" '^(switch|start|stop|restore)'
fi

if want runner; then
echo "== S7. runner: switch profile to profile, ONE restore at the end, also after an abort =="
E="$(mkenv fast)"; cp "$JD/chat-v1.json" "$E/fake/validate_file.fast"; cp "$JD/vision-golden-v1.json" "$E/fake/validate_file.vision"; setprior "$E" decide-nli
run_run "$E" fast vision
check "fast then vision with decide-nli resident: exit 0" "$RC" "0"
check "decide-nli restored exactly once, not between the runs" "$(grep -c '^restore decide-nli$' "$E/fake/calls")" "1"
l_rest=$(grep -n '^restore decide-nli$' "$E/fake/calls" | cut -d: -f1); l_sv=$(grep -n '^stop vision$' "$E/fake/calls" | tail -1 | cut -d: -f1)
[ -n "$l_rest" ] && [ -n "$l_sv" ] && [ "$l_rest" -gt "$l_sv" ] && ok "the restore comes after the LAST test model was stopped" || bad "restore position" "restore=$l_rest stop vision=$l_sv"
[ ! -e "$E/fake/overlap" ] && ok "no two test models (or test model + prior profile) resident together" || bad "overlap" "$(cat "$E/fake/overlap")"
has "runner summary has a restore line" "$E/out.txt" 'prior set restored: YES'
has "the sequence evidence records the prior set once" "$SEQD/prior_set.txt" '^decide-nli$'
E="$(mkenv fast)"; setprior "$E" decide-nli; touch "$E/fake/validate_wait"; printf 'echo 11501 >"$FAKE/gpu"\n' >"$E/fake/mutate.sh"
run_run "$E" fast vision
check "abort in the first profile: runner exit 4, vision never started" "$RC$(grep -c '^switch' "$E/fake/calls")" "41"
has "  the prior set is restored after the abort" "$E/fake/calls" '^restore decide-nli$'
E="$(mkenv fast)"; setprior "$E" decide-nli; cp "$JD/chat-v1.json" "$E/fake/validate_file.fast"
printf 'printf "some avg10=8.00 avg60=0 avg300=0 total=1\\nfull avg10=0.00 avg60=0 avg300=0 total=1\\n" >"${FAKE%%/fake}/psi"\n' >"$E/fake/mutate.sh"
run_run "$E" fast
check "sequence passed but pressure at the end: restore skipped, runner exit 6" "$RC" "6"
has "  manual restore command printed" "$E/err.txt" 'llmctl start decide-nli'
has "  summary says NOT restored" "$E/out.txt" 'prior set restored: NO'
E="$(mkenv fast)"; setprior "$E" decide-nli; cp "$JD/chat-v1.json" "$E/fake/validate_file.fast"; touch "$E/fake/restore_fail.decide-nli"
run_run "$E" fast; check "failed restore at the end of a passing sequence: runner exit 7" "$RC" "7"
E="$(mkenv fast)"; setmem "$E" 11000; setprior "$E" decide-nli; run_run "$E" fast
check "first profile refused by the gate: nothing was switched off, so no restore needed, exit stays 3" "$RC$(grep -c '^restore' "$E/fake/calls")" "30"
fi

if want review; then
echo "== S8 (F1). a scaled instance is never silently dropped, also through the runner =="
E="$(mkenv fast)"; setchat "$E"; setprior "$E" decide:800:0 decide.2:800:0
run_main "$E" fast
check "direct driver: resident decide + decide.2 -> restore exit 7" "$RC" "7"
has "  restore.txt names the scaled instance" "$EVD/restore.txt" '^decide\.2 +FAILED \(scaled instance'
E="$(mkenv fast)"; cp "$JD/chat-v1.json" "$E/fake/validate_file.fast"; setprior "$E" decide:800:0 decide.2:800:0
run_run "$E" fast
check "RUNNER with decide + decide.2 resident: exit 7 (not 0)" "$RC" "7"
has "  summary says the prior set is NOT restored" "$E/out.txt" 'prior set restored: NO'
has "  summary names the scaled instance" "$E/out.txt" 'decide\.2'
has "  the sequence RESTORE_MANUAL.txt names the scaled instance" "$SEQD/RESTORE_MANUAL.txt" 'decide\.2'
has "  the base profile was still restored" "$E/fake/calls" '^restore decide$'
has "  machine-readable state in the summary" "$E/out.txt" '^RESTORE_STATE=failed$'
E="$(mkenv fast)"; cp "$JD/chat-v1.json" "$E/fake/validate_file.fast"; setprior "$E" decide:800:0
run_run "$E" fast; check "NEG-CONTROL: only the base profile resident -> runner exit 0" "$RC" "0"
has "  RESTORE_STATE=ok" "$E/out.txt" '^RESTORE_STATE=ok$'

echo "== S9 (F2). the reservation credit never lowers the watchdog's RAW memory floor =="
E="$(mkenv fast)"; setchat "$E"; setprior "$E" big:10000:0; setmem "$E" 4000
run_main "$E" fast
check "raw MemAvailable 4000 (+10000 credited): refused by the gate (exit 3), not aborted by the watchdog" "$RC" "3"
hasnt "  the resident set was NOT switched off for nothing" "$E/fake/calls" '^(switch|restore)'
has "  reason names the raw floor" "$E/err.txt" 'RAW MemAvailable'
E="$(mkenv fast)"; setchat "$E"; setprior "$E" big:10000:0; setmem "$E" 6023
run_main "$E" fast; check "raw 6023 < floor 5000 + 1024: refused (exit 3)" "$RC" "3"
E="$(mkenv fast)"; setchat "$E"; setprior "$E" big:10000:0; setmem "$E" 6024
run_main "$E" fast; has "NEG-CONTROL raw 6024 passes the gate (switch issued)" "$E/fake/calls" '^switch fast$'
g=$(grep -n '^guard[[:space:]]' "$MAIN" | head -1 | cut -d: -f1); sw=$(grep -n '^STOP_NEEDED=1; TARGET_STOP_OK=0' "$MAIN" | cut -d: -f1)
[ -n "$g" ] && [ -n "$sw" ] && [ "$g" -lt "$sw" ] && ok "a watchdog guard check runs before the switch is launched (line $g < $sw)" || bad "no guard before the switch" "guard=$g switch=$sw"

echo "== S10 (F3). unknown reserved RAM gets a conservative restore floor =="
E="$(mkenv fast)"; setchat "$E"; setprior "$E" decide-nli:0:0
printf 'printf "MemAvailable: %%d kB\\n" %d >"${FAKE%%/fake}/meminfo"\n' $((5500*1024)) >"$E/fake/mutate.sh"
run_main "$E" fast
check "ram_mb 0 and MemAvailable 5500 < 6144 floor: restore skipped (exit 6)" "$RC" "6"
has "  the reason says the RAM figure is unknown and the default floor was used" "$EVD/restore.txt" 'SKIPPED.*6144.*(unknown|default)'
E="$(mkenv fast)"; setchat "$E"; setprior "$E" decide-nli:0:0
printf 'printf "MemAvailable: %%d kB\\n" %d >"${FAKE%%/fake}/meminfo"\n' $((6200*1024)) >"$E/fake/mutate.sh"
run_main "$E" fast; check "NEG-CONTROL MemAvailable 6200 >= 6144: restored (exit 0)" "$RC" "0"
E="$(mkenv fast)"; setchat "$E"; echo "[{\"profile\":\"decide-nli\",\"port\":$PORT,\"enabled\":true,\"state\":\"running\"},{\"profile\":\"small\",\"port\":$PORT,\"ram_mb\":\"abc\",\"enabled\":true,\"state\":\"running\"}]" >"$E/fake/others.json"
printf 'printf "MemAvailable: %%d kB\\n" %d >"${FAKE%%/fake}/meminfo"\n' $((5500*1024)) >"$E/fake/mutate.sh"
run_main "$E" fast; check "missing / non-numeric ram_mb are both treated as unknown (exit 6)" "$RC" "6"
has "  both skipped" "$EVD/restore.txt" '^small +SKIPPED'

echo "== S11 (F4). a first INT/TERM finishes the current restore start, then stops and leaves the manual commands =="
E="$(mkenv fast)"; echo '[]' >"$E/fake/others.json"; setprior "$E" aaa:100:0 bbb:100:0 ccc:100:0; mv "$E/fake/others.json" "$E/fake/others.stopped.json"; echo '[]' >"$E/fake/others.json"
echo 3 >"$E/fake/restore_slow"; printf 'aaa\nbbb\nccc\n' >"$E/set.txt"
start_main "$E" --restore-only "$E/set.txt"; MP=$MAINPID
for _ in $(seq 1 50); do grep -q '^restore aaa$' "$E/fake/calls" 2>/dev/null && break; sleep 0.1; done
kill -TERM "$MP" 2>/dev/null; wait "$MP"; RC=$?; EVD="$(find "$E/ev" -mindepth 1 -maxdepth 1 -type d | head -1)"
check "TERM during the first profile's start: exit 6" "$RC" "6"
has "  the profile being started finished its start attempt" "$E/fake/calls" '^restore aaa$'
hasnt "  no further profile was started" "$E/fake/calls" '^restore (bbb|ccc)$'
has "  restore.txt: aaa has an outcome, bbb and ccc are SKIPPED (interrupted)" "$EVD/restore.txt" '^bbb +SKIPPED \(interrupted'
has "  manual commands for the remaining profiles" "$EVD/RESTORE_MANUAL.txt" 'llmctl start bbb ccc'
has "  the exit state is machine-readable" "$EVD/restore_state" '^manual$'
E="$(mkenv fast)"; setprior "$E" aaa:100:0 bbb:100:0; mv "$E/fake/others.json" "$E/fake/others.stopped.json"; echo '[]' >"$E/fake/others.json"
echo 3 >"$E/fake/restore_slow"; printf 'aaa\nbbb\n' >"$E/set.txt"
start_main "$E" --restore-only "$E/set.txt"; MP=$MAINPID
for _ in $(seq 1 50); do grep -q '^restore aaa$' "$E/fake/calls" 2>/dev/null && break; sleep 0.1; done
kill -TERM "$MP" 2>/dev/null; sleep 0.3; kill -TERM "$MP" 2>/dev/null; wait "$MP"; RC=$?; EVD="$(find "$E/ev" -mindepth 1 -maxdepth 1 -type d | head -1)"
check "a SECOND signal does not abort the start in flight: exit 6, aaa tracked" "$RC" "6"
has "  aaa's outcome is recorded (not lost)" "$EVD/restore.txt" '^aaa '
E="$(mkenv fast)"; setprior "$E" aaa:100:0 bbb:100:0; mv "$E/fake/others.json" "$E/fake/others.stopped.json"; echo '[]' >"$E/fake/others.json"; printf 'aaa\nbbb\n' >"$E/set.txt"
run_main "$E" --restore-only "$E/set.txt"; check "NEG-CONTROL without a signal both are restored (exit 0)" "$RC$(grep -c '^restore ' "$E/fake/calls")" "02"

echo "== S12 (F6). restore health path from the unit env file for ANY engine =="
E="$(mkenv fast)"; setchat "$E"; setprior "$E" colibri-x:100:0
printf "LLMCTL_ENGINE='colibri'\nLLMCTL_PORT=%s\nLLMCTL_REG_HEALTH=/v1/ready\n" "$PORT" >"$E/services/colibri-x.env"
: >"$T/health_paths"; run_main "$E" fast
check "colibri-style prior profile restored (exit 0)" "$RC" "0"
has "  its health was probed on the env file's LLMCTL_REG_HEALTH path" "$T/health_paths" '^/v1/ready$'
E="$(mkenv fast)"; setchat "$E"; setprior "$E" onnx-x:100:0; printf "LLMCTL_ENGINE='onnx'\n" >"$E/services/onnx-x.env"
: >"$T/health_paths"; run_main "$E" fast
has "onnx without REG_HEALTH falls back to /healthz" "$T/health_paths" '^/healthz$'
E="$(mkenv fast)"; setchat "$E"; setprior "$E" llama-x:100:0; printf "LLMCTL_ENGINE='llama'\n" >"$E/services/llama-x.env"
: >"$T/health_paths"; run_main "$E" fast
has "NEG-CONTROL llama without REG_HEALTH uses /health" "$T/health_paths" '^/health$'
E="$(mkenv fast)"; setchat "$E"; setprior "$E" colibri-y:100:0; printf "LLMCTL_ENGINE='colibri'\nLLMCTL_REG_HEALTH=/v1/ready\n" >"$E/services/colibri-y.env"
# the row's port wins over the env file's port; no row port and no env port -> unit active
: >"$T/health_paths"; run_main "$E" fast; has "row port + env health path" "$T/health_paths" '^/v1/ready$'

echo "== S13. machine-readable RESTORE_STATE (verdict, evidence file) also when the run's own code wins =="
E="$(mkenv fast)"; setchat "$E"; setprior "$E" decide-nli; run_main "$E" fast
has "ok: verdict line" "$EVD/verdict.txt" '^RESTORE_STATE=ok$'; has "ok: evidence file" "$EVD/restore_state" '^ok$'
E="$(mkenv fast)"; setchat "$E"; run_main "$E" fast; has "none: nothing resident" "$EVD/verdict.txt" '^RESTORE_STATE=none$'
E="$(mkenv fast)"; setchat "$E"; setprior "$E" decide-nli; touch "$E/fake/restore_fail.decide-nli"; run_main "$E" fast
has "failed" "$EVD/verdict.txt" '^RESTORE_STATE=failed$'
E="$(mkenv fast)"; setchat "$E"; setprior "$E" decide-nli; echo 1 >"$E/fake/validate_rc"; echo x >"$E/fake/validate_file"; touch "$E/fake/restore_fail.decide-nli"
run_main "$E" fast
check "the run's own code (1 FAIL) wins over a failed restore" "$RC" "1"
has "  but RESTORE_STATE=failed tells the host-service state" "$EVD/verdict.txt" '^RESTORE_STATE=failed$'
E="$(mkenv fast)"; setchat "$E"; setprior "$E" decide-nli; printf 'printf "some avg10=8.00 avg60=0 avg300=0 total=1\\nfull avg10=0.00 avg60=0 avg300=0 total=1\\n" >"${FAKE%%/fake}/psi"\n' >"$E/fake/mutate.sh"
run_main "$E" fast; has "manual (pressure)" "$EVD/verdict.txt" '^RESTORE_STATE=manual$'
fi

if want rev2; then
echo "== S14 (F-N1). a group-delivered TERM/HUP does not kill the in-flight restore start =="
E="$(mkenv fast)"; setprior "$E" aaa:100:0 bbb:100:0; mv "$E/fake/others.json" "$E/fake/others.stopped.json"; echo '[]' >"$E/fake/others.json"
echo 3 >"$E/fake/restore_slow"; printf 'aaa\nbbb\n' >"$E/set.txt"
start_main "$E" --restore-only "$E/set.txt"; MP=$MAINPID
for _ in $(seq 1 60); do grep -q '^restore aaa$' "$E/fake/calls" 2>/dev/null && break; sleep 0.1; done
for c in $(pgrep -f "$E/bin/llmctl start aaa"); do kill -TERM "$c" 2>/dev/null; kill -HUP "$c" 2>/dev/null; done
kill -TERM "$MP" 2>/dev/null; wait "$MP"; RC=$?; EVD="$(find "$E/ev" -mindepth 1 -maxdepth 1 -type d | head -1)"
check "TERM to the driver AND the llmctl start child: exit 6" "$RC" "6"
has "  the in-flight start finished: aaa RESTORED" "$EVD/restore.txt" '^aaa +RESTORED'
hasnt "  aaa is not reported FAILED (rc 143)" "$EVD/restore.txt" '^aaa +FAILED'
has "  bbb left for the manual command" "$EVD/RESTORE_MANUAL.txt" 'llmctl start bbb'

echo "== S15 (F-N2). --no-restore run directly is loud =="
E="$(mkenv fast)"; setchat "$E"; setprior "$E" decide:800:0
run_main "$E" --no-restore fast
check "direct --no-restore: exit code stays 0" "$RC" "0"
has "  stderr warns loudly at the start" "$E/err.txt" 'WARNING: --no-restore.*decide'
has "  stderr names RESTORE_MANUAL.txt and the exact command" "$E/err.txt" 'RESTORE_MANUAL\.txt.*llmctl start decide|llmctl start decide.*RESTORE_MANUAL\.txt'
has "  final line NOT RESTORED" "$E/out.txt" '^NOT RESTORED: .*decide'
E="$(mkenv fast)"; setchat "$E"; run_main "$E" --no-restore fast
hasnt "NEG-CONTROL nothing resident: no warning" "$E/err.txt" 'WARNING: --no-restore'
hasnt "  no NOT RESTORED line" "$E/out.txt" '^NOT RESTORED'
E="$(mkenv fast)"; cp "$JD/chat-v1.json" "$E/fake/validate_file.fast"; setprior "$E" decide:800:0
run_run "$E" fast
check "via the runner: exit 0, set restored" "$RC" "0"
hasnt "  the runner-invoked driver does not print NOT RESTORED" "$SEQD/fast.out" 'NOT RESTORED|WARNING: --no-restore'

echo "== S16 (F-N3). a scaled instance that llmctl's rollback brought back is not a failure =="
E="$(mkenv fast)"; setchat "$E"; setprior "$E" decide:800:0 decide.2:800:0; touch "$E/fake/rollback_instances"
run_main "$E" fast
check "instance running again after the restore: exit 0" "$RC" "0"
has "  decide.2 ALREADY RUNNING" "$EVD/restore.txt" '^decide\.2 +ALREADY RUNNING'
E="$(mkenv fast)"; setchat "$E"; setprior "$E" decide:800:0 decide.2:800:0
run_main "$E" fast
check "NEG-CONTROL instance still missing: exit 7" "$RC" "7"
has "  FAILED with an actual command" "$EVD/restore.txt" '^decide\.2 +FAILED.*llmctl decide scale decide 2'
has "  RESTORE_MANUAL has the scale command" "$EVD/RESTORE_MANUAL.txt" 'llmctl decide scale decide 2'

echo "== S17 (F-N4). the runner restores what a driver switched off beyond the initial set =="
E="$(mkenv fast)"; cp "$JD/chat-v1.json" "$E/fake/validate_file.fast"; cp "$JD/chat-v1.json" "$E/fake/validate_file.small"; setprior "$E" decide:800:0
printf '[ -f "$FAKE/mutated" ] && exit 0; touch "$FAKE/mutated"\npython3 -I -c '"'"'import json,sys;f=sys.argv[1];r=json.load(open(f+"/others.json"));r.append({"profile":"extra","port":%d,"ram_mb":500,"vram_mb":0,"enabled":True,"state":"running"});json.dump(r,open(f+"/others.json","w"))'"'"' "$FAKE"\n' "$PORT" >"$E/fake/mutate.sh"
run_run "$E" fast small
check "something started during run 1 and switched off by run 2: sequence exit 0" "$RC" "0"
has "  extra restored too" "$E/fake/calls" '^restore extra$'
has "  the initial member restored" "$E/fake/calls" '^restore decide$'
has "  summary names the additional profile" "$E/out.txt" 'extra'
has "  RESTORE_STATE=ok" "$E/out.txt" '^RESTORE_STATE=ok$'

echo "== S18 (F-N5). docs state the 1024 margin is estimate-based =="
has "protocol doc says the margin is an estimate-based choice that can only cost an abort+restore" "$ROOT/docs/live-test-protocol.md" 'margin.*estimate'
fi

if want rev3; then
echo "== S19 (F1). the restore deadline is a WAIT deadline: the message and RESTORE_MANUAL.txt give the operator abort path =="
E="$(mkenv fast)"; setprior "$E" aaa:100:0; mv "$E/fake/others.json" "$E/fake/others.stopped.json"; echo '[]' >"$E/fake/others.json"
echo 4 >"$E/fake/restore_slow"; printf 'aaa\n' >"$E/set.txt"
RESTORE_BOUND_T=1 run_main "$E" --restore-only "$E/set.txt"
check "restore start exceeds its deadline: exit 7" "$RC" "7"
has "  restore.txt says the start is NOT killed and gives the systemctl stop hint" "$EVD/restore.txt" '^aaa +FAILED.*still running.*systemctl --user stop llmctl-llama@aaa\.service'
has "  RESTORE_MANUAL.txt carries the abort path (systemctl stop or SIGKILL of the recorded pid)" "$EVD/RESTORE_MANUAL.txt" 'systemctl --user stop llmctl-llama@aaa\.service'
has "  the stderr message carries it too" "$E/err.txt" 'systemctl --user stop llmctl-llama@aaa\.service'
has "  the docs state the real bounds (LLMCTL_START_WAIT, LLMCTL_READY_TIMEOUT)" "$ROOT/docs/live-test-protocol.md" 'LLMCTL_START_WAIT.*LLMCTL_READY_TIMEOUT|LLMCTL_READY_TIMEOUT.*LLMCTL_START_WAIT'
has "  the docs say llmctl's own TERM/INT traps are disabled inside the restore tree" "$ROOT/docs/live-test-protocol.md" 'ignored at entry|cannot be trapped'
has "  the docs name the operator abort path" "$ROOT/docs/live-test-protocol.md" 'operator abort path'

sleep 4   # let the deliberately orphaned fake start (restore_slow 4) finish before the next scenario (it touches a shared health flag)
echo "== S20 (F2). a scaled instance is only OK when it is healthy =="
E="$(mkenv fast)"; setchat "$E"; touch "$E/fake/rollback_instances"
echo "[$(row decide 800 0),$(row decide.2 800 0)]" >"$E/fake/others.json"
run_main "$E" fast
check "instance back and healthy: exit 0" "$RC" "0"
has "  ALREADY RUNNING (healthy)" "$EVD/restore.txt" '^decide\.2 +ALREADY RUNNING \(healthy\)'
E="$(mkenv fast)"; setchat "$E"; touch "$E/fake/rollback_instances"
echo "[$(row decide 800 0),$(row decide.2 800 0 | sed 's/"port":[0-9]*/"port":1/')]" >"$E/fake/others.json"
run_main "$E" fast
check "instance reserved but NOT healthy (dead port): not ok, exit 6" "$RC" "6"
has "  reservation present, health not verified" "$EVD/restore.txt" '^decide\.2 +.*reservation present, health not verified'
has "  RESTORE_STATE=manual" "$EVD/verdict.txt" '^RESTORE_STATE=manual$'
has "  RESTORE_MANUAL.txt names the unverified instance (F5)" "$EVD/RESTORE_MANUAL.txt" '^instance decide\.2 has a reservation but its health was NOT verified'

echo "== S21 (F3a). the runner takes the evidence path from a file the driver writes, not from scraped stdout =="
E="$(mkenv fast)"; cp "$JD/chat-v1.json" "$E/fake/validate_file.fast"
printf '{"status":"ok"}\nevidence /tmp/lt-spoofed-evidence\n' >"$T/health_body"
run_run "$E" fast
rm -f "$T/health_body"
check "driver output contains a spoofed 'evidence' line: runner still exit 0" "$RC" "0"
hasnt "  the summary table does not show the spoofed path" "$SEQD/summary.txt" 'lt-spoofed-evidence'
[ -s "$SEQD/fast.evpath" ] && ok "  the driver wrote its evidence path to $SEQD/fast.evpath" || bad "  no evpath file"
hasnt "  run_profiles.sh no longer scrapes the driver's stdout for the path" <(grep -vE '^\s*#' "$RUN") "awk '\\\$1==\"evidence\"'"
fi

printf '\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -ne 0 ] || printf '  ok: all %d livetest switch assertions passed\n' "$PASS"
[ "$FAIL" = 0 ]
