#!/usr/bin/env bash
# test_livetest_profiles.sh - hermetic tests of the PROFILE-GENERAL live-test driver (scripts/livetest/vision_live_test.sh,
# scripts/livetest/lt_profiles.py, scripts/livetest/watchdog.sh limits):
#   1. the allow-list is DERIVED at run time from the catalog + `llmctl plan --json` + `llmctl models verify` + the
#      validation suites + the running set (never a hard-coded name); refusals (exit 3) for everything else;
#   2. the PASS criterion is suite-aware: the expected pass count is read from the suite JSON and the judge's real
#      JSON shape, for vision / chat / coder / embedding suites;
#   3. per-profile evidence, GPU peak, thresholds scaled from the catalog footprint (never below the vision gates),
#      watchdog limits derived with the absolute floors, stop contract for any profile.
# Everything is faked (tests/livetest_fake_lib.sh); no model, unit, container or real llmctl is started. Every refusal
# and every mutation has a NEGATIVE CONTROL beside it. The judge JSON of chat/coder/embedding comes from the REAL
# lib/validate_judge.py run against tests/fixtures/validation/fake_openai.py (an answer table, not a model).
# STRICT-EXEMPT: the suite runs failing commands on purpose and counts failures itself (ok/bad), so no -e
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN="$ROOT/scripts/livetest/vision_live_test.sh"
WD="$ROOT/scripts/livetest/watchdog.sh"
LTP="$ROOT/scripts/livetest/lt_profiles.py"
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

# ---- the judge's real JSON per suite (generated once) ----
JD="$T/judge"; mkdir -p "$JD"
for s in chat-v1 coder-v1 embedding-v1; do real_judge "$s" "$JD/$s.json"; done
cp "$ROOT/tests/fixtures/livetest/real_judge_pass.json" "$JD/vision-golden-v1.json"
# validate output the fake llmctl prints for a profile: one JSON object per suite of that profile
setval() { # setval <env> <suite>...
  local e="$1"; shift; : >"$e/fake/validate_file"
  local s; for s in "$@"; do cat "$JD/$s.json" >>"$e/fake/validate_file"; echo >>"$e/fake/validate_file"; done
}
refused() { # refused <name> <env> : exit 3, nothing started, no stop
  check "$1: exit 3 (refused)" "$RC" "3"
  calls_has_start "$2" && bad "  $1: the model was started!" || ok "  $1: start never called"
  hasnt "  $1: no stop called" "$2/fake/calls" '^stop'
}
fp() { python3 -I -c 'import json,sys;c=json.load(open(sys.argv[1]));print((sum(f["size"] for f in c["profiles"][sys.argv[2]]["files"])+1048575)//1048576)' "$ROOT/models/catalog.json" "$1"; }
FP_VISION="$(fp vision)"; FP_FAST="$(fp fast)"; FP_CODER="$(fp coder)"   # catalog footprints in MiB (the helper derives the same numbers)
big() { setmem "$1" 40000; }   # enough MemAvailable for a large profile (gate scales with its footprint)

if want setup; then
echo "== 0. the helper and the real judge shapes the criteria are derived from =="
bash -n "$MAIN" && bash -n "$WD" && ok "bash -n driver + watchdog" || bad "bash -n"
python3 -I -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$LTP" && ok "lt_profiles.py compiles" || bad "compile"   # no .pyc written into the tree
for s in chat-v1 coder-v1 embedding-v1 vision-golden-v1; do
  sf="$ROOT/validation/suites/$s/suite.json"; [ "$s" = vision-golden-v1 ] && sf="$ROOT/validation/suites/$s/expectations.json"
  derived="$(python3 -I -B - "$LTP" "$sf" "$JD/$s.json" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("ltp", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
p, c, d = m.expected_counts(json.load(open(sys.argv[2])))
real = json.load(open(sys.argv[3]))["counts"]["pass"]
print("derived=%d real_judge_counts_pass=%d" % (p + c + d, real))
PY
)"
  d="${derived%% *}"; r="${derived##* real_judge_counts_pass=}"
  check "suite $s: expected pass count derived from the suite JSON equals the REAL judge's counts.pass ($derived)" "${d#derived=}" "$r"
done
fi

if want allow; then
echo "== 1. allow-list derived from catalog + plan + verify + suites (refusals exit 3, nothing started) =="
# 1a. fitting profiles of different kinds PASS: chat, embedding (no real catalog profile has one: fixture profile), vision
for pr in fast embed-x; do
  E="$(mkenv "$pr")"; case "$pr" in fast) setval "$E" chat-v1 ;; embed-x) setval "$E" embedding-v1 ;; esac
  run_main "$E" "$pr"
  check "profile '$pr' (catalog + plan fits + verified + suite): exit 0 PASS" "$RC" "0"
  has "  $pr: validate ran with the generic entry (--host, --json, --keep)" "$E/fake/calls" "^validate validate $pr --host http://127.0.0.1:[0-9]+ --json --keep"
  has "  $pr: stop $pr happened" "$E/fake/calls" "^stop $pr\$"
  has "  $pr: verdict PASS" "$E/out.txt" 'VERDICT +PASS \(exit 0\)'
done
E="$(mkenv vision)"; run_main "$E" vision
check "NEG-CONTROL: vision still PASSes through the same derived allow-list" "$RC" "0"
has "  vision keeps the vision entry point" "$E/fake/calls" '^validate vision validate --profile vision .*--json'
# the checks ran BEFORE the model start, in this order: plan, verify (niced), start
E="$(mkenv fast)"; setval "$E" chat-v1; run_main "$E" fast
lp=$(grep -n '^plan --json' "$E/fake/calls" | head -1 | cut -d: -f1); lv=$(grep -n '^verify fast' "$E/fake/calls" | head -1 | cut -d: -f1); ls_=$(grep -n '^start ' "$E/fake/calls" | head -1 | cut -d: -f1)
[ -n "$lp" ] && [ -n "$lv" ] && [ -n "$ls_" ] && [ "$lp" -lt "$ls_" ] && [ "$lv" -lt "$ls_" ] && ok "plan (#$lp) and verify (#$lv) both ran before start (#$ls_)" || bad "order plan=$lp verify=$lv start=$ls_"
has "  checksum verification ran niced + ionice idle (it hashes GBs)" "$E/fake/calls" '^verify fast nice=19 ionice=idle'

# 1a2. --gate-only: every refusal check + the pre-gate, nothing started, nothing hashed
E="$(mkenv fast)"; run_main "$E" --gate-only fast
check "--gate-only on a fitting profile: exit 0" "$RC" "0"
has "  verdict says GATE-OK, not PASS" "$E/out.txt" 'VERDICT +GATE-OK \(exit 0\)'
hasnt "  it is not reported as PASS" "$E/out.txt" 'VERDICT +PASS'
calls_has_start "$E" && bad "  gate-only started the model!" || ok "  gate-only never started anything"
hasnt "  gate-only did not run the (GB-hashing) checksum verification" "$E/fake/calls" '^verify '
has "  gate-only did consult the plan" "$E/fake/calls" '^plan --json'
E="$(mkenv fast)"; setmem "$E" 11999; run_main "$E" --gate-only fast
check "NEG-CONTROL: --gate-only refuses (exit 3) when the pre-gate would" "$RC" "3"
E="$(mkenv vision-pro)"; run_main "$E" --gate-only vision-pro; check "--gate-only still demands --allow-large for a large profile (exit 3)" "$RC" "3"
E="$(mkenv fast)"; python3 -I -c 'import json,sys;p=json.load(open(sys.argv[1]));p["profiles"]["fast"]["fits"]=False;json.dump(p,open(sys.argv[1],"w"))' "$E/fake/plan.json"
run_main "$E" --gate-only fast; check "--gate-only refuses a profile the plan says does not fit (exit 3)" "$RC" "3"

# 1b. unknown / unusable profiles: refused before ANY llmctl call
for pr in nosuch Vision 'fast;x' '../fast' decide colibri-glm; do
  E="$(mkenv)"; run_main "$E" "$pr"
  check "profile '$pr' refused (not in catalog / bad id / no suite / unsupported engine): exit 3" "$RC" "3"
  [ ! -s "$E/fake/calls.args" ] && ok "  '$pr': no llmctl call at all" || bad "  '$pr': llmctl was called: $(cat "$E/fake/calls.args")"
done
E="$(mkenv)"; run_main "$E" decide; has "  no-suite profile: the reason names the missing validation suite" "$E/err.txt" 'no validation suite'
E="$(mkenv)"; run_main "$E" colibri-glm; has "  colibri engine: the reason names the engine" "$E/err.txt" "engine 'colibri'"
E="$(mkenv)"; rm -f "$E/suites/chat-v1/suite.json"; run_main "$E" fast
check "profile whose suite file is missing: exit 3" "$RC" "3"; has "  reason names the suite" "$E/err.txt" "suite 'chat-v1'"
E="$(mkenv)"; run_main "$E" --bogus-flag fast; check "unknown option: exit 3" "$RC" "3"
E="$(mkenv)"; run_main "$E" fast vision; check "two profiles to one driver run: exit 3" "$RC" "3"

# 1c. the plan decides fit
E="$(mkenv fast)"; python3 -I -c 'import json,sys;p=json.load(open(sys.argv[1]));p["profiles"]["fast"]["fits"]=False;json.dump(p,open(sys.argv[1],"w"))' "$E/fake/plan.json"
run_main "$E" fast; refused "profile the plan says does NOT fit" "$E"; has "  reason says it does not fit" "$E/err.txt" 'does NOT fit'
E="$(mkenv fast)"; python3 -I -c 'import json,sys;p=json.load(open(sys.argv[1]));del p["profiles"]["fast"];json.dump(p,open(sys.argv[1],"w"))' "$E/fake/plan.json"
run_main "$E" fast; refused "profile missing from the plan" "$E"
E="$(mkenv fast)"; echo not-json >"$E/fake/plan.json"; run_main "$E" fast; refused "unparseable plan" "$E"
E="$(mkenv fast)"; echo 1 >"$E/fake/plan_rc"; run_main "$E" fast; refused "llmctl plan --json failed" "$E"
E="$(mkenv fast)"; echo 30 >"$E/fake/plan_hang"; run_main "$E" fast; refused "llmctl plan --json hangs (bounded)" "$E"
# NEG-CONTROL of the above: the same fast profile with fits=true passes (section 1a)

# 1d. checksum must be verified
E="$(mkenv fast)"; setval "$E" chat-v1; echo 1 >"$E/fake/verify_rc"
run_main "$E" fast; refused "unverified checksum (models verify rc 1)" "$E"; has "  reason names the checksum verification" "$E/err.txt" 'checksum|verif'
E="$(mkenv fast)"; setval "$E" chat-v1; echo 1 >"$E/fake/verify_rc.vision"
run_main "$E" fast; check "NEG-CONTROL: a failing verify of ANOTHER profile does not matter (exit 0)" "$RC" "0"
E="$(mkenv fast)"; echo 60 >"$E/fake/verify_hang"; run_main "$E" fast; refused "models verify hangs (bounded, never a pass)" "$E"

# 1e. already running -> refused (the gate's status check, profile-generic)
E="$(mkenv fast)"; echo '[{"profile":"fast","port":8080,"mode":"x","ram_mb":10,"vram_mb":0,"enabled":false,"state":"running","last_log_line":null}]' >"$E/fake/others.json"
run_main "$E" fast; refused "profile already running" "$E"; has "  reason says it is already running" "$E/err.txt" 'already running'
E="$(mkenv fast)"; echo '[{"profile":"fast.2","port":8080,"mode":"x","ram_mb":10,"vram_mb":0,"enabled":false,"state":"running","last_log_line":null}]' >"$E/fake/others.json"
run_main "$E" fast; check "a scaled instance fast.2 counts as fast running: exit 3" "$RC" "3"
E="$(mkenv fast)"; setval "$E" chat-v1; echo '[{"profile":"small","port":8083,"mode":"x","ram_mb":10,"vram_mb":0,"enabled":false,"state":"running","last_log_line":null}]' >"$E/fake/others.json"
run_main "$E" fast; check "NEG-CONTROL: another small profile running does not block (exit 0)" "$RC" "0"

# 1f. large profiles need the explicit flag AND a fitting plan
E="$(mkenv vision-pro)"; setval "$E" vision-golden-v1; run_main "$E" vision-pro
refused "vision-pro WITHOUT --allow-large (even though the plan says it fits)" "$E"; has "  reason names the flag" "$E/err.txt" 'allow-large'
E="$(mkenv vision-pro)"; setval "$E" vision-golden-v1; run_main "$E" --allow-large vision-pro
check "vision-pro WITH --allow-large and a fitting plan: exit 0" "$RC" "0"; has "  vision-pro uses the vision entry point with its own name" "$E/fake/calls" '^validate vision validate --profile vision-pro '
E="$(mkenv vision-pro)"; setval "$E" vision-golden-v1; LT_ALLOW_LARGE=1 run_main "$E" vision-pro
check "vision-pro with env LT_ALLOW_LARGE=1: exit 0" "$RC" "0"
E="$(mkenv vision-pro)"; setval "$E" vision-golden-v1; LT_ALLOW_LARGE=0 run_main "$E" vision-pro
refused "LT_ALLOW_LARGE=0 is not a flag" "$E"
E="$(mkenv vision-pro)"; python3 -I -c 'import json,sys;p=json.load(open(sys.argv[1]));p["profiles"]["vision-pro"]["fits"]=False;json.dump(p,open(sys.argv[1],"w"))' "$E/fake/plan.json"
run_main "$E" --allow-large vision-pro; refused "vision-pro WITH --allow-large but the plan says it does NOT fit (flag never overrides fit)" "$E"
E="$(mkenv fast)"; setval "$E" chat-v1; run_main "$E" --allow-large fast; check "NEG-CONTROL: --allow-large on a small profile changes nothing (exit 0)" "$RC" "0"
# 'large' is derived from the catalog (tier / footprint), not from a name: coder is a baseline-tier profile of 17 GiB
E="$(mkenv coder)"; setval "$E" coder-v1 chat-v1; big "$E"; run_main "$E" coder; refused "17 GiB coder without --allow-large" "$E"
E="$(mkenv coder)"; setval "$E" coder-v1 chat-v1; big "$E"; run_main "$E" --allow-large coder
check "coder with --allow-large: exit 0 (two suites: coder-v1 + chat-v1)" "$RC" "0"

# 1g. no hard-coded names: rename a profile in a private catalog and it is accepted exactly like the original
E="$(mkenv zeta)"; setval "$E" chat-v1
python3 -I - "$E/catalog.json" "$E/fake/plan.json" "$E/services" <<'PY'
import json, shutil, sys
c = json.load(open(sys.argv[1])); c["profiles"]["zeta"] = c["profiles"].pop("fast"); json.dump(c, open(sys.argv[1], "w"))
p = json.load(open(sys.argv[2])); p["profiles"]["zeta"] = p["profiles"].pop("fast"); json.dump(p, open(sys.argv[2], "w"))
shutil.copy(sys.argv[3] + "/fast.env", sys.argv[3] + "/zeta.env")
PY
run_main "$E" zeta; check "renamed profile 'zeta' (chat-v1) is accepted: nothing is hard-coded by name" "$RC" "0"
run_main "$E" fast; check "NEG-CONTROL: 'fast' no longer exists in that catalog -> refused" "$RC" "3"
fi

if want gate; then
echo "== 2. pre-gate thresholds scale with the catalog footprint, never below the vision gates =="
# vision footprint ~3.1 GiB -> the floor 12000 holds (boundary exactly as before)
E="$(mkenv vision)"; setval "$E" vision-golden-v1; setmem "$E" 11999; run_main "$E" vision; refused "vision MemAvailable 11999 (floor 12000)" "$E"
E="$(mkenv vision)"; setval "$E" vision-golden-v1; setmem "$E" 12000; run_main "$E" vision; check "NEG-CONTROL vision MemAvailable 12000 passes" "$RC" "0"
# coder: needs footprint + 4096 + 2048 (footprint from the catalog, here $FP_CODER MiB)
NEED=$((FP_CODER + 4096 + 2048))
E="$(mkenv coder)"; setval "$E" coder-v1 chat-v1; setmem "$E" $((NEED - 1)); run_main "$E" --allow-large coder; refused "coder MemAvailable $((NEED - 1)) < footprint+4GiB+2GiB" "$E"
has "  refusal names the scaled threshold $NEED" "$E/err.txt" "< $NEED "
E="$(mkenv coder)"; setval "$E" coder-v1 chat-v1; setmem "$E" "$NEED"; run_main "$E" --allow-large coder; check "NEG-CONTROL coder MemAvailable $NEED passes" "$RC" "0"
# free VRAM: need = plan vram_mb + 1024 margin
E="$(mkenv vision)"; setval "$E" vision-golden-v1; echo 5000 >"$E/fake/gpu_total"; run_main "$E" vision
refused "free VRAM 3800 < model $FP_VISION + 1024" "$E"; has "  reason names free VRAM" "$E/err.txt" 'free VRAM'
E="$(mkenv vision)"; setval "$E" vision-golden-v1; echo $((1200 + FP_VISION + 1024)) >"$E/fake/gpu_total"; run_main "$E" vision
check "NEG-CONTROL free VRAM exactly model $FP_VISION + 1024 passes" "$RC" "0"
E="$(mkenv vision)"; setval "$E" vision-golden-v1; touch "$E/fake/gpu_total_fail"; run_main "$E" vision
refused "GPU total unreadable while the model needs VRAM (fail closed)" "$E"
# the absolute gates of the original driver still hold for a large profile
E="$(mkenv coder)"; setval "$E" coder-v1 chat-v1; big "$E"; echo 6000 >"$E/fake/gpu"; run_main "$E" --allow-large coder; refused "GPU used 6000 MiB is still refused for a large profile" "$E"
E="$(mkenv coder)"; setval "$E" coder-v1 chat-v1; big "$E"; setpsi "$E" 5.00 0; run_main "$E" --allow-large coder; refused "PSI some 5.00 is still refused for a large profile" "$E"
fi

if want judge; then
echo "== 3. the PASS criterion is suite-aware (real judge JSON shape; derived counts) =="
negp() { # negp <name> <profile> <suites...> -- <python statements on reports list d>
  local name="$1" pr="$2"; shift 2; local -a su=(); while [ "$1" != "--" ]; do su+=("$1"); shift; done; shift
  E="$(mkenv "$pr")"; setval "$E" "${su[@]}"
  python3 -I - "$E/fake/validate_file" "$1" <<'PY'
import json, sys
raw = open(sys.argv[1]).read(); dec = json.JSONDecoder(); d = []; i = 0
while True:
    j = raw.find("{", i)
    if j < 0: break
    o, e = dec.raw_decode(raw[j:]); d.append(o); i = j + e
exec(sys.argv[2])
open(sys.argv[1], "w").write("\n".join(json.dumps(o, indent=1) for o in d) + "\n")
PY
  case "$pr" in coder) big "$E"; run_main "$E" --allow-large "$pr" ;; *) run_main "$E" "$pr" ;; esac
  check "mutated real $pr capture '$name' must NOT pass (exit 2)" "$RC" "2"
  hasnt "  '$name': verdict is not PASS" "$E/out.txt" 'VERDICT +PASS'
}
negp "chat: drop the determinism entry"      fast chat-v1 -- 'd[0]["determinism"]=[]; d[0]["counts"]["pass"]-=1'
negp "chat: flip determinism"                fast chat-v1 -- 'd[0]["determinism"][0]["identical"]=False'
negp "chat: one probe FAIL"                  fast chat-v1 -- 'd[0]["results"][0]["verdict"]="FAIL"'
negp "chat: a probe missing"                 fast chat-v1 -- 'd[0]["results"].pop(); d[0]["counts"]["pass"]-=1'
negp "chat: counts.pass off by one"          fast chat-v1 -- 'd[0]["counts"]["pass"]+=1'
negp "chat: undetermined > 0"                fast chat-v1 -- 'd[0]["counts"]["undetermined"]=1'
negp "chat: verdict FAIL but rc 0"           fast chat-v1 -- 'd[0]["verdict"]="FAIL"'
negp "chat: a vision-shaped extra control"   fast chat-v1 -- 'd[0]["controls"].append({"key":"x","verdict":"PASS"}); d[0]["counts"]["pass"]+=1'
negp "chat: report of the WRONG suite name"  fast chat-v1 -- 'd[0]["suite"]="coder-v1"'
negp "coder: second suite (chat-v1) report missing" coder coder-v1 chat-v1 -- 'd.pop()'
negp "coder: duplicate report instead of chat-v1"   coder coder-v1 chat-v1 -- 'd[1]=d[0]'
negp "coder: chat-v1 probe FAIL"             coder coder-v1 chat-v1 -- 'd[1]["results"][0]["verdict"]="FAIL"'
negp "embedding: invented determinism entry" embed-x embedding-v1 -- 'd[0]["determinism"].append({"key":"animals","identical":True}); d[0]["counts"]["pass"]+=1'
negp "embedding: a case dropped"             embed-x embedding-v1 -- 'd[0]["results"].pop(); d[0]["counts"]["pass"]-=1'
negp "embedding: one case FAIL"              embed-x embedding-v1 -- 'd[0]["results"][1]["verdict"]="FAIL"'
# a chat report fed to the vision profile, and the reverse
E="$(mkenv vision)"; setval "$E" chat-v1; run_main "$E" vision; check "chat-v1 JSON for a vision profile must NOT pass" "$RC" "2"
E="$(mkenv fast)"; setval "$E" vision-golden-v1; run_main "$E" fast; check "vision JSON for a chat profile must NOT pass" "$RC" "2"
# the expectation comes from the SUITE FILE, not from constants: add a case to the suite the driver reads
E="$(mkenv fast)"; setval "$E" chat-v1
python3 -I -c 'import json,sys;p=sys.argv[1];d=json.load(open(p));d["cases"].append({"id":"extra","prompt":"x","checks":{"contains_all":["X"]}});json.dump(d,open(p,"w"))' "$E/suites/chat-v1/suite.json"
run_main "$E" fast; check "suite file gained a case, the (old) real report no longer matches -> NOT pass (derived, not constant)" "$RC" "2"
has "  reason is the probe count against the suite" "$E/out.txt" 'probe count 5 != suite 6'
# rc semantics are unchanged: validate rc 1 = FAIL (wrong answer), 2 = undetermined; garbage never passes
E="$(mkenv fast)"; setval "$E" chat-v1; echo 1 >"$E/fake/validate_rc"; run_main "$E" fast; check "validate rc 1 on a chat profile -> exit 1 (FAIL)" "$RC" "1"
E="$(mkenv fast)"; echo 'not json {{' >"$E/fake/validate_file"; run_main "$E" fast; check "garbage output -> not PASS (2)" "$RC" "2"
fi

if want evidence; then
echo "== 4. per-profile evidence, GPU peak, derived watchdog limits, stop contract =="
E="$(mkenv fast)"; setval "$E" chat-v1; echo 4109 >"$E/fake/gpu_after_start"; run_main "$E" fast
check "fast run with GPU use passes" "$RC" "0"
case "$(basename "$EVD")" in *-fast) ok "evidence dir name carries the profile: $(basename "$EVD")" ;; *) bad "evidence dir name" "$(basename "$EVD")" ;; esac
has "verdict carries the GPU peak" "$EVD/verdict.txt" 'vram peak MiB +4109'
has "peaks.txt records the GPU peak" "$EVD/peaks.txt" '^gpu_peak_mb=4109$'
has "peaks.txt records the cgroup MemoryPeak (UNKNOWN here: no cgroup in the fake)" "$EVD/peaks.txt" '^unit_memory_peak_mb='
has "thresholds.txt names the profile" "$EVD/thresholds.txt" '^profile=fast$'
has "thresholds.txt records the footprint from the catalog ($FP_FAST MiB)" "$EVD/thresholds.txt" "^footprint_mb=$FP_FAST\$"
has "thresholds.txt records the gate memory floor" "$EVD/thresholds.txt" '^gate_min_mem_mb=12000$'
has "thresholds.txt records the watchdog limits" "$EVD/thresholds.txt" '^wd_max_gpu_mb=11500$'
has "mmproj is not applicable for a chat profile (not a failure)" "$EVD/verdict.txt" 'mmproj sha256 +N/A'
E="$(mkenv vision)"; setval "$E" vision-golden-v1; run_main "$E" vision
case "$(basename "$EVD")" in *-vision) ok "vision evidence dir name carries the profile: $(basename "$EVD")" ;; *) bad "vision evidence dir" "$(basename "$EVD")" ;; esac
has "NEG-CONTROL: a vision profile still hashes its mmproj" "$EVD/verdict.txt" 'mmproj sha256 +[0-9a-f]{64}'
# two runs in the same second never share a directory
E="$(mkenv fast)"; setval "$E" chat-v1; run_main "$E" fast; run_main "$E" fast
check "two runs of one profile -> two distinct evidence dirs" "$(find "$E/ev" -mindepth 1 -maxdepth 1 -type d | wc -l)" "2"

# watchdog limits: derived from the footprint, with the absolute floors (mem >= 5000, gpu ceiling >= 11500)
E="$(mkenv vision)"; setval "$E" vision-golden-v1; run_main "$E" vision
has "vision: watchdog limits are the original ones (mem<5000 gpu>11500)" "$EVD/watchdog.log" 'mem<5000MiB .*gpu>11500MiB'
E="$(mkenv coder)"; setval "$E" coder-v1 chat-v1; big "$E"; echo 24000 >"$E/fake/gpu_total"; run_main "$E" --allow-large coder
CEIL=$((1200 + FP_CODER + 1024))
has "coder: GPU ceiling derived = baseline 1200 + model $FP_CODER + 1024 = $CEIL (>= floor 11500)" "$EVD/watchdog.log" "gpu>${CEIL}MiB"
has "coder: memory floor stays 5000" "$EVD/watchdog.log" 'mem<5000MiB'
# behaviour: 15000 MiB would have tripped the vision ceiling; for the large profile it is fine, 19921 trips (exit 4)
E="$(mkenv coder)"; setval "$E" coder-v1 chat-v1; big "$E"; echo 15000 >"$E/fake/gpu_after_start"; run_main "$E" --allow-large coder
check "coder: GPU 15000 MiB (> 11500) does NOT abort a large profile" "$RC" "0"
E="$(mkenv coder)"; setval "$E" coder-v1 chat-v1; big "$E"; touch "$E/fake/validate_wait"; printf 'echo %d >"$FAKE/gpu"\n' $((CEIL + 1)) >"$E/fake/mutate.sh"
run_main "$E" --allow-large coder; check "coder: GPU $((CEIL + 1)) > derived ceiling -> exit 4" "$RC" "4"
has "  trigger names the GPU limit" "$EVD/trigger" "GPU used $((CEIL + 1)) MiB > $CEIL"
has "  stop of THIS profile (coder) was called" "$E/fake/calls" '^stop coder$'
hasnt "  no stop of another profile" "$E/fake/calls" '^stop (vision|fast)$'
# NEG-CONTROL: a small profile keeps the original ceiling -> 11501 trips
E="$(mkenv fast)"; setval "$E" chat-v1; touch "$E/fake/validate_wait"; printf 'echo 11501 >"$FAKE/gpu"\n' >"$E/fake/mutate.sh"
run_main "$E" fast; check "fast: GPU 11501 > 11500 -> exit 4" "$RC" "4"; has "  stop fast called" "$E/fake/calls" '^stop fast$'
# memory trigger and the always-stop trap work for any profile
E="$(mkenv fast)"; setval "$E" chat-v1; touch "$E/fake/validate_wait"; printf 'printf "MemAvailable: %%d kB\\n" %d >"${FAKE%%/fake}/meminfo"\n' $((4999*1024)) >"$E/fake/mutate.sh"
run_main "$E" fast; check "fast: MemAvailable 4999 -> exit 4" "$RC" "4"; has "  stop fast called" "$E/fake/calls" '^stop fast$'
[ ! -e "$E/fake/running" ] && ok "  profile not running afterwards" || bad "  still running"
E="$(mkenv fast)"; setval "$E" chat-v1; echo 1 >"$E/fake/validate_rc"; echo 'x' >"$E/fake/validate_file"; run_main "$E" fast
has "failure path of a non-vision profile still stops it" "$E/fake/calls" '^stop fast$'
[ ! -e "$E/fake/forbidden" ] && ok "pkill/killall never called" || bad "forbidden called"

# watchdog.sh itself: explicit limits are parsed, floors enforced
E="$(mkenv fast)"; mkdir -p "$E/wdev"
FAKE="$E/fake" PATH="$E/bin:$PATH" LT_HERMETIC=1 LT_WD_INTERVAL=0.2 LT_MEMINFO="$E/meminfo" LT_PSI="$E/psi" LT_IOPSI="$E/iopsi" timeout 5 bash "$WD" fast "$E/wdev" $$ --min-mem-mb 3000 --max-gpu-mb 19920 >/dev/null 2>&1
has "watchdog --min-mem-mb 3000 is raised to the 5000 floor, --max-gpu-mb 19920 honoured" "$E/wdev/watchdog.log" 'mem<5000MiB .*gpu>19920MiB'
E="$(mkenv fast)"; mkdir -p "$E/wdev"
FAKE="$E/fake" PATH="$E/bin:$PATH" LT_HERMETIC=1 LT_WD_INTERVAL=0.2 LT_MEMINFO="$E/meminfo" LT_PSI="$E/psi" LT_IOPSI="$E/iopsi" timeout 5 bash "$WD" fast "$E/wdev" $$ --min-mem-mb 9000 >/dev/null 2>&1
has "watchdog --min-mem-mb 9000 (stricter) honoured" "$E/wdev/watchdog.log" 'mem<9000MiB'
E="$(mkenv fast)"; mkdir -p "$E/wdev"; wrc=0
FAKE="$E/fake" PATH="$E/bin:$PATH" LT_HERMETIC=1 timeout 5 bash "$WD" fast "$E/wdev" $$ --max-gpu-mb abc >/dev/null 2>&1 || wrc=$?
check "watchdog refuses a non-numeric limit (exit 2), it never runs with a guessed one" "$wrc" "2"
E="$(mkenv fast)"; mkdir -p "$E/wdev"
FAKE="$E/fake" PATH="$E/bin:$PATH" LT_HERMETIC=1 LT_WD_INTERVAL=0.2 LT_MEMINFO="$E/meminfo" LT_PSI="$E/psi" LT_IOPSI="$E/iopsi" timeout 5 bash "$WD" fast "$E/wdev" $$ >/dev/null 2>&1
has "NEG-CONTROL: no limit args -> the original defaults" "$E/wdev/watchdog.log" 'mem<5000MiB .*gpu>11500MiB'
fi

printf '\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -ne 0 ] || printf '  ok: all %d livetest profile assertions passed\n' "$PASS"
[ "$FAIL" = 0 ]
