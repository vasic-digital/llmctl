#!/usr/bin/env bash
# test_host_reserve_review8.sh - UNIT-CLASS (hermetic: fixture meminfo, PSI, cgroup tree, plan; one stub llama-server).
# Round-8 (Opus review of 536d65e, CONDITIONAL GO) findings and the reviewer mutants O2, O4, O10, O12:
#   F1  the model memory budget is bounded by the tightest numeric memory.high / memory.max in the user manager's cgroup
#       chain (app.slice, the user manager and every ancestor up to the cgroup root), never only by the host RAM.
#   F3  LLMCTL_GATE_RESERVE_MB cannot lower the memory reserve below the computed one, a non-numeric value refuses
#       (rc 75 + llmctl-fallback line), LLMCTL_GATE_FULL_MAX / LLMCTL_GATE_SOME_MAX can only be stricter.
#   O2  the per-unit memory limit is clamped to the model budget      O4  an unlimited unit counts as the whole CPU budget
#   O10 the GGUF smoke test caps its threads                           O12 the planner-only defer needs ALL reasons to be the planner's
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
export LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
# shellcheck disable=SC1090
for l in common os_detect hardware catalog reserve capacity svc_hook download; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
export LLMCTL_HOST_MEM_MB=32768 LLMCTL_GATE_WAIT=0 LLMCTL_GATE_POLL=1
q() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$@"; }
MIB=1048576
U="$(id -u)"
newfs() { # <fs>: a cgroup tree with the caller's user manager and its app.slice
  mkdir -p "$1/user.slice/user-${U}.slice/user@${U}.service/app.slice"; : > "$1/cgroup.controllers"
}
UM() { echo "$1/user.slice/user-${U}.slice/user@${U}.service"; }
bm() { ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="$1" LLMCTL_HOST_CPUS=16 "${@:2}"; capacity_json decide-tiny 2>/dev/null ) | python3 -c 'import json,sys; print(json.load(sys.stdin)["reserve"]["mem_model_budget_mb"])'; }

echo "--- F1: the model budget is bounded by the cgroup chain"
FS1="${TEST_TMP}/cg1"; newfs "${FS1}"
UNB="$(bm "${FS1}")"
assert_eq 26215 "${UNB}" "F1: no limit anywhere in the chain: the budget is the host's (32768 - 20%)"
printf '%s\n' $(( 24779 * MIB )) > "$(UM "${FS1}")/app.slice/memory.max"; printf '%s\n' $(( 21682 * MIB )) > "$(UM "${FS1}")/app.slice/memory.high"
B1="$(bm "${FS1}")"
if (( B1 <= 21682 && B1 > 0 )); then echo "  ok: F1: app.slice memory.high 21682 / max 24779 bounds the budget (${B1} <= 21682)"
else echo "  FAIL: F1: app.slice limits did not bound the budget (got ${B1}, want 0 < b <= 21682)" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
FS2="${TEST_TMP}/cg2"; newfs "${FS2}"
printf '%s\n' $(( 16384 * MIB )) > "${FS2}/user.slice/memory.max"
B2="$(bm "${FS2}")"
if (( B2 <= 16384 && B2 > 0 )); then echo "  ok: F1: a tighter limit on an ANCESTOR (user.slice 16384) bounds the budget (${B2})"
else echo "  FAIL: F1: the ancestor limit did not bound the budget (got ${B2})" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
FS3="${TEST_TMP}/cg3"; newfs "${FS3}"
printf 'max\n' > "$(UM "${FS3}")/app.slice/memory.max"; printf 'max\n' > "$(UM "${FS3}")/app.slice/memory.high"; printf 'max\n' > "${FS3}/user.slice/memory.max"
assert_eq "${UNB}" "$(bm "${FS3}")" "F1: 'max' values bound nothing (negative control)"
FS4="${TEST_TMP}/cg4"; newfs "${FS4}"
printf '%s\n' $(( 90000 * MIB )) > "${FS4}/user.slice/memory.max"
assert_eq "${UNB}" "$(bm "${FS4}")" "F1: a limit LARGER than the host RAM bounds nothing (negative control)"
FS5="${TEST_TMP}/cg5"; newfs "${FS5}"
printf '%s\n' $(( 2048 * MIB )) > "$(UM "${FS5}")/app.slice/memory.high"
assert_eq "True" "$(q "$( ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${FS5}" LLMCTL_HOST_CPUS=16; capacity_json decide-tiny 2>/dev/null ) )" 'd["reserve"]["mem_short"] if "mem_short" in d["reserve"] else d["profiles"]["decide-tiny"]["verdict"]!="fits"')" "F1: a 2 GiB chain limit leaves no model budget: not admitted"

echo "--- F3: the gate thresholds cannot be loosened"
PSI="${TEST_TMP}/psi8"; MEMI="${TEST_TMP}/mem8"
printf 'some avg10=0.00 avg60=0 avg300=0 total=0\nfull avg10=0.00 avg60=0 avg300=0 total=0\n' > "${PSI}"
printf 'MemTotal: 33554432 kB\nMemAvailable: %s kB\n' $(( 3000 * 1024 )) > "${MEMI}"
g() { local rc=0; ( export LLMCTL_PSI_FILE="${PSI}" LLMCTL_MEMINFO_FILE="${MEMI}" "$@"; hw_pressure_gate 0 decide-tiny ) 2>"${TEST_TMP}/gerr" >/dev/null || rc=$?; echo "${rc}"; }
assert_eq 75 "$(g)" "F3: 3000 MiB available is below the 6553 MiB reserve: refused (control)"
assert_eq 75 "$(g LLMCTL_GATE_RESERVE_MB=0)" "F3: LLMCTL_GATE_RESERVE_MB=0 does not remove the reserve"
assert_eq 75 "$(g LLMCTL_GATE_RESERVE_MB=1)" "F3: LLMCTL_GATE_RESERVE_MB=1 does not lower the reserve"
assert_eq 75 "$(g LLMCTL_GATE_RESERVE_MB=abc)" "F3: a non-numeric LLMCTL_GATE_RESERVE_MB refuses"
assert_contains "$(cat "${TEST_TMP}/gerr")" "llmctl-fallback:" "F3: ... with the machine-readable fallback line"
printf 'MemTotal: 33554432 kB\nMemAvailable: %s kB\n' $(( 30000 * 1024 )) > "${MEMI}"
assert_eq 0 "$(g)" "F3: 30000 MiB available: admitted (control)"
assert_eq 0 "$(g LLMCTL_GATE_RESERVE_MB=9000)" "F3: a STRICTER reserve (9000) that still fits is honoured and admits"
assert_eq 75 "$(g LLMCTL_GATE_RESERVE_MB=31000)" "F3: a stricter reserve (31000 + footprint > available) refuses"
assert_eq 0 "$(g LLMCTL_HOST_RESERVE=0 LLMCTL_GATE_RESERVE_MB=0)" "F3: with the reserve switched off the legacy value still applies"
printf 'some avg10=0.00 avg60=0 avg300=0 total=0\nfull avg10=50.00 avg60=0 avg300=0 total=0\n' > "${PSI}"
assert_eq 75 "$(g)" "F3: PSI full 50 refused (control)"
assert_eq 75 "$(g LLMCTL_GATE_FULL_MAX=100)" "F3: LLMCTL_GATE_FULL_MAX=100 does not loosen the full threshold"
printf 'some avg10=50.00 avg60=0 avg300=0 total=0\nfull avg10=0.00 avg60=0 avg300=0 total=0\n' > "${PSI}"
assert_eq 75 "$(g LLMCTL_GATE_SOME_MAX=100)" "F3: LLMCTL_GATE_SOME_MAX=100 does not loosen the some threshold"
printf 'some avg10=5.00 avg60=0 avg300=0 total=0\nfull avg10=0.00 avg60=0 avg300=0 total=0\n' > "${PSI}"
assert_eq 0 "$(g)" "F3: PSI some 5 admitted (control)"
assert_eq 75 "$(g LLMCTL_GATE_SOME_MAX=3)" "F3: a STRICTER LLMCTL_GATE_SOME_MAX=3 is honoured"
printf 'some avg10=0.00 avg60=0 avg300=0 total=0\nfull avg10=0.00 avg60=0 avg300=0 total=0\n' > "${PSI}"
# the capacity doc must apply the same clamps
FSC="${TEST_TMP}/cgc"; newfs "${FSC}"
capd() { ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${FSC}" LLMCTL_HOST_CPUS=16 LLMCTL_PSI_FILE="${PSI}" LLMCTL_MEMINFO_FILE="${MEMI}" "$@"; capacity_json decide-tiny 2>/dev/null ); }
printf 'some avg10=0.00 avg60=0 avg300=0 total=0\nfull avg10=50.00 avg60=0 avg300=0 total=0\n' > "${PSI}"
assert_eq "False" "$(q "$(capd LLMCTL_GATE_FULL_MAX=100)" 'd["profiles"]["decide-tiny"]["verdict"]=="fits"')" "F3: capacity_json also clamps LLMCTL_GATE_FULL_MAX=100 (PSI full 50 is not a fit)"
printf 'some avg10=0.00 avg60=0 avg300=0 total=0\nfull avg10=0.00 avg60=0 avg300=0 total=0\n' > "${PSI}"

echo "--- O4: an unlimited unit (cpu.max 'max') counts as the whole CPU budget"
FSO="${TEST_TMP}/cgo"; newfs "${FSO}"
d="$(UM "${FSO}")/app.slice/llmctl-llama@big.service"; mkdir -p "${d}"
printf 'populated 1\n' > "${d}/cgroup.events"; printf 'max 100000\n' > "${d}/cpu.max"; printf '%s\n' $(( 512 * MIB )) > "${d}/memory.max"; printf '0\n' > "${d}/memory.current"
rc=0; ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${FSO}" LLMCTL_HOST_CPUS=16; reserve_combined_check 100 512 decide-tiny ) >/dev/null 2>&1 || rc=$?
assert_eq 75 "${rc}" "O4: one CPU-unlimited unit + a new 1-CPU start breaches the CPU budget (refused)"

echo "--- O10: the GGUF smoke test caps its threads"
STUBD="${TEST_TMP}/llstub"; mkdir -p "${STUBD}"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s/args"\nexit 1\n' "${STUBD}" > "${STUBD}/llama-server"; chmod 755 "${STUBD}/llama-server"
: > "${STUBD}/m.gguf"; _DL_EVIDENCE="${TEST_TMP}/smoke8-evidence.log"
set +e
( export LLMCTL_LLAMA_SERVER="${STUBD}/llama-server" LLMCTL_SMOKE=1 LLMCTL_SMOKE_TIMEOUT=3; _dl_smoke_test_gguf decide-tiny "${STUBD}/m.gguf" ) >/dev/null 2>&1
set -e
ARGS="$(cat "${STUBD}/args" 2>/dev/null || true)"
assert_contains "${ARGS}" "--threads " "O10: the smoke llama-server is started with --threads"
assert_contains "${ARGS}" "--threads-batch " "O10: ... and --threads-batch"

echo "--- O2 / O12: the memory limit is clamped to the budget; the planner-only defer needs all reasons"
FSM="${TEST_TMP}/cgm"; newfs "${FSM}"
doc8="$( ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${FSM}" LLMCTL_HOST_CPUS=16 LLMCTL_HOST_MEM_MB=8192; capacity_json 2>/dev/null ) )"
assert_eq "True" "$(q "${doc8}" 'all(v["headroom"]["mem_limit_need_mb"] <= d["reserve"]["mem_model_budget_mb"] for v in d["profiles"].values())')" "O2: no profile's memory limit exceeds the 4096 MiB model budget of an 8 GiB host"
assert_eq "True" "$(q "${doc8}" 'd["profiles"]["moe-fast"]["headroom"]["mem_limit_need_mb"] == d["reserve"]["mem_model_budget_mb"]')" "O2: a 15 GiB profile is clamped to exactly the budget"
mix=0; ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${FSM}" LLMCTL_HOST_CPUS=16; capacity_admit colibri-glm ) >/dev/null 2>&1 || mix=$?
assert_eq 75 "${mix}" "O12: a profile whose reasons are the planner's AND a MemAvailable shortfall is refused (not deferred)"
only=0; ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${FSM}" LLMCTL_HOST_CPUS=16; capacity_admit coder ) >/dev/null 2>&1 || only=$?
assert_eq 0 "${only}" "O12: a planner-only verdict is deferred to the planner path (negative control)"
test_finish
