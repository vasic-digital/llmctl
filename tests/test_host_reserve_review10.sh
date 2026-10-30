#!/usr/bin/env bash
# test_host_reserve_review10.sh - UNIT-CLASS (hermetic fixtures). Round-10 review (Opus, NO-GO on 4fedf0a) findings:
#   F1 a start/install with LLMCTL_HOST_RESERVE=0 must not persist reserve-OFF state anywhere: the complete unit state
#      (template, every drop-in, the env record incl. LLMCTL_ARGS) after a reserve-off start, a reserve-on start and a
#      restart-style rewrite is IDENTICAL. The override only skips the admission gates / reporting / direct launches.
#   F2 every numeric env knob is validated by ONE shared validator: a malformed value refuses (rc 75) naming the
#      variable, in the start gate, the capacity report and `llmctl install`.
#   F3 pins for reviewer mutants A1 (stale CPU_PCT_UNIT line), B (memo key needs >=3 computes), C2 (leading zeros),
#      D2 (CPU_MIN not validated), D5 (capacity report must be undetermined on a bad knob).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
export LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
# shellcheck disable=SC1090
for l in common os_detect hardware catalog reserve capacity svc_hook download service_linux scheduler; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
export LLMCTL_HOST_MEM_MB=32768 LLMCTL_HOST_CPUS=16 LLMCTL_GATE_WAIT=0 LLMCTL_GATE_POLL=1
MIB=1048576; U="$(id -u)"
newfs() { mkdir -p "$1/user.slice/user-${U}.slice/user@${U}.service/app.slice"; : > "$1/cgroup.controllers"; }

# snap <root> -> every file under the root with its content (stable order); nothing is excluded.
snap() { ( cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '== %s\n' "${f}"; cat -- "${f}"; done ); }

# scenario <name> <reserve-value|"-"> -> a fresh unit dir + services dir; install the units, build the launch and
# write the env record of profile $PROFILE the way `llmctl start` does (sched_build_launch + _sched_svc_write_env).
PROFILE=small
scenario() {
  local name="$1" rsv="$2" root="${TEST_TMP}/scen-$1"
  mkdir -p "${root}/units/default.target.wants" "${root}/services"
  (
    export LLMCTL_UNIT_DIR="${root}/units" LLMCTL_SERVICES_DIR="${root}/services" LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${root}/cg"
    newfs "${root}/cg"
    [[ "${rsv}" == - ]] || export LLMCTL_HOST_RESERVE="${rsv}"
    svc_install
    sched_build_launch "${PROFILE}" gpu 18099 8192 99 1 auto f16
    _sched_svc_write_env "${PROFILE}"
  ) >/dev/null 2>"${root}.err" || { echo "  note: scenario ${name} stderr: $(head -c 400 "${root}.err")" >&2; }
  echo "${root}"
}

echo "--- F1: complete unit state is identical for reserve-off start, reserve-on start and restart"
ON="$(scenario on -)"
OFF="$(scenario off 0)"
norm() { snap "$1" | sed -e "s#$1#@ROOT@#g" -e "s#${ON}#@ROOT@#g"; }   # the sandbox root differs in the paths inside the records
norm "${ON}" > "${TEST_TMP}/snap-on"; norm "${OFF}" > "${TEST_TMP}/snap-off"
files_on="$(grep -c '^== ' "${TEST_TMP}/snap-on")"
if (( files_on >= 4 )); then echo "  ok: F1: the reserve-on start produced ${files_on} files (template, drop-ins, env record)"
else echo "  FAIL: F1: the reserve-on scenario produced only ${files_on} files - the scenario does not exercise the start path" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
assert_contains "$(cat "${TEST_TMP}/snap-on")" "06-reserve.conf" "F1: the reserve-on state has the reserve drop-in"
assert_contains "$(cat "${TEST_TMP}/snap-on")" "--threads" "F1: the reserve-on launch carries --threads"
if diff -u "${TEST_TMP}/snap-on" "${TEST_TMP}/snap-off" > "${TEST_TMP}/snap.diff"; then
  echo "  ok: F1: reserve-off start state == reserve-on start state (every drop-in, the template, the env record)"
else
  echo "  FAIL: F1: a reserve-off start persisted different unit state:" >&2; head -40 "${TEST_TMP}/snap.diff" >&2; TEST_FAILS=$((TEST_FAILS+1))
fi
# restart-style: an already-running reserve-on unit re-written under the override (boot/restart never re-derive)
REST="${TEST_TMP}/scen-restart"; cp -a "${ON}" "${REST}"
( export LLMCTL_UNIT_DIR="${REST}/units" LLMCTL_SERVICES_DIR="${REST}/services" LLMCTL_HOST_RESERVE=0 LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${REST}/cg"
  sched_build_launch "${PROFILE}" gpu 18099 8192 99 1 auto f16; _sched_svc_write_env "${PROFILE}" ) >/dev/null 2>&1 || true
norm "${REST}" > "${TEST_TMP}/snap-rest"
if diff -u "${TEST_TMP}/snap-on" "${TEST_TMP}/snap-rest" > "${TEST_TMP}/snap2.diff"; then echo "  ok: F1: a reserve-off re-write of a reserve-on unit changes nothing"
else echo "  FAIL: F1: a reserve-off re-write changed the unit state:" >&2; head -40 "${TEST_TMP}/snap2.diff" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
# the memory drop-in is sized with the reserve-on limit also under the override (05-memory.conf)
assert_eq "$(grep -h '^MemoryMax=' "${ON}"/units/*/05-memory.conf 2>/dev/null | head -1)" "$(grep -h '^MemoryMax=' "${OFF}"/units/*/05-memory.conf 2>/dev/null | head -1)" "F1: 05-memory.conf MemoryMax is identical"

# ---------------------------------------------------------------------------------------------------------------------
echo "--- F2: one validator for every numeric knob (start gate, capacity report, install, unit-state write)"
# the EXPECTED list is written out here on purpose (not read from _RSV_KNOBS): dropping an entry from the validator
# must fail this test. <VARIABLE> <malformed value> <well-formed value>
KNOBS=(
  "LLMCTL_RESERVE_CPU_PCT 40% 30"        "LLMCTL_RESERVE_CPU_MIN 2.5 2"          "LLMCTL_RESERVE_MEM_PCT 2O 25"
  "LLMCTL_RESERVE_MEM_MIN_MB 8G 5000"    "LLMCTL_CHAT_CPU_PCT x50 40"            "LLMCTL_DECIDE_CPU_PCT 25% 20"
  "LLMCTL_GATE_CPU_SOME_MAX eighty 70"   "LLMCTL_GATE_LOAD_PER_CPU 3x 2"         "LLMCTL_GATE_RESERVE_MB 9G 6000"
  "LLMCTL_GATE_FULL_MAX .5 1.5"          "LLMCTL_GATE_SOME_MAX 5% 8.5"           "LLMCTL_GATE_WAIT 1m 0"
  "LLMCTL_GATE_POLL fast 1"              "LLMCTL_CAPACITY_TIMEOUT 5s 5"          "LLMCTL_CAPACITY_PROBE_TIMEOUT 3s 3"
  "LLMCTL_HOST_RESERVE_STRICT yes 0"
)
# control needle for the inventory below: the extractor must see a knob in a scratch file (positive) and not an invented one
printf 'x="${LLMCTL_NEEDLE_KNOB:-7}"\n' > "${TEST_TMP}/needle.sh"
got="$(grep -ohE '\$\{LLMCTL_[A-Z0-9_]+:-[0-9]' "${TEST_TMP}/needle.sh" | sed -E 's/^\$\{//; s/:-[0-9]$//')"
assert_eq "LLMCTL_NEEDLE_KNOB" "${got}" "F2: the inventory extractor sees a known numeric knob (control needle)"
assert_eq "0" "$(grep -c 'LLMCTL_NOT_A_KNOB_ZZ' "${TEST_TMP}/needle.sh" || true)" "F2: ... and does not invent one (negative control)"
# every numeric knob the reserve / gate / capacity code reads is validated or explicitly exempt (the legacy START-wait,
# registration and model-validation knobs of svc_hook.sh are outside the host-reserve surface and are not inventoried here)
EXEMPT=" LLMCTL_HOST_RESERVE LLMCTL_GATE_CPU_CHECKS "   # only-literal-0 switches; a malformed value keeps the safe side
inv="$(cd "${LLMCTL_ROOT}" && grep -ohE '\$\{LLMCTL_[A-Z0-9_]+:-[0-9]' lib/reserve.sh lib/hardware.sh lib/capacity.sh | sed -E 's/^\$\{//; s/:-[0-9]$//' | sort -u)"
(( $(wc -w <<<"${inv}") >= 10 )) || { echo "  FAIL: F2: the knob inventory found only $(wc -w <<<"${inv}") knobs (instrument blind?)" >&2; TEST_FAILS=$((TEST_FAILS+1)); }
missing=""
for k in ${inv}; do
  [[ "${EXEMPT}" == *" ${k} "* ]] && continue
  hit=0; for e in "${KNOBS[@]}"; do [[ "${e%% *}" == "${k}" ]] && hit=1; done
  (( hit )) || missing+=" ${k}"
done
[[ -z "${missing}" ]] && echo "  ok: F2: every numeric knob read by the reserve/gate/capacity/hook code is in the validated list ($(wc -w <<<"${inv}") found)" \
  || { echo "  FAIL: F2: numeric knobs read by the code but not validated:${missing}" >&2; TEST_FAILS=$((TEST_FAILS+1)); }

PSI="${TEST_TMP}/psi10"; MEMI="${TEST_TMP}/mem10"
printf 'some avg10=0.00 avg60=0 avg300=0 total=0\nfull avg10=0.00 avg60=0 avg300=0 total=0\n' > "${PSI}"
printf 'MemTotal: 33554432 kB\nMemAvailable: %s kB\n' $(( 30000 * 1024 )) > "${MEMI}"
FS10="${TEST_TMP}/cg10"; newfs "${FS10}"
for e in "${KNOBS[@]}"; do
  set -- ${e}; k="$1"; bad="$2"; good="$3"
  # (a) the shared validator
  rc=0; ( export "${k}=${bad}"; reserve_knobs_check ) || rc=$?; assert_eq 75 "${rc}" "F2: ${k}='${bad}' fails reserve_knobs_check"
  rc=0; ( export "${k}=${good}"; reserve_knobs_check ) || rc=$?; assert_eq 0 "${rc}" "F2: ${k}='${good}' passes reserve_knobs_check (control)"
  # (b) the start gate: rc 75, the variable named, the fallback line
  rc=0; ( export LLMCTL_PSI_FILE="${PSI}" LLMCTL_MEMINFO_FILE="${MEMI}" "${k}=${bad}"; hw_pressure_gate 0 decide-tiny ) >"${TEST_TMP}/g.out" 2>"${TEST_TMP}/g.err" || rc=$?
  assert_eq 75 "${rc}" "F2: the start gate refuses ${k}='${bad}'"
  assert_contains "$(cat "${TEST_TMP}/g.err")" "${k}=" "F2: ... naming ${k}"
  assert_contains "$(cat "${TEST_TMP}/g.err")" "llmctl-fallback:" "F2: ... with the fallback line (${k})"
  # (c) the capacity report is UNDETERMINED (never computed from a silently defaulted value) and names the variable
  doc="$( ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${FS10}" LLMCTL_HOST_CPUS=16 "${k}=${bad}"; capacity_json decide-tiny 2>/dev/null ) )"
  ok="$(python3 -c 'import json,sys; print((json.loads(sys.argv[1]).get("measurement") or {}).get("ok"))' "${doc}" 2>/dev/null || echo err)"
  why="$(python3 -c 'import json,sys; print((json.loads(sys.argv[1]).get("measurement") or {}).get("reason"))' "${doc}" 2>/dev/null || echo err)"
  assert_eq False "${ok}" "F2: llmctl capacity is undetermined for ${k}='${bad}'"
  assert_contains "${why}" "${k}" "F2: ... and the reason names ${k}"
  # (d) install and the unit-state write refuse before writing anything
  root="${TEST_TMP}/f2-${k}"; mkdir -p "${root}/units" "${root}/services"
  rc=0; ( export LLMCTL_UNIT_DIR="${root}/units" LLMCTL_SERVICES_DIR="${root}/services" "${k}=${bad}"; svc_install ) >/dev/null 2>"${root}/i.err" || rc=$?
  assert_eq 75 "${rc}" "F2: llmctl install refuses ${k}='${bad}'"
  assert_contains "$(cat "${root}/i.err")" "${k}=" "F2: ... naming ${k}"
  assert_eq 0 "$(find "${root}/units" -type f | wc -l)" "F2: ... and writes no unit file"
  rc=0; ( export LLMCTL_UNIT_DIR="${root}/units" LLMCTL_SERVICES_DIR="${root}/services" "${k}=${bad}"; svc_write_env small llama /bin/true --port 1 ) >/dev/null 2>"${root}/w.err" || rc=$?
  assert_eq 75 "${rc}" "F2: the unit-state write refuses ${k}='${bad}'"
  assert_eq 0 "$(find "${root}/services" -type f | wc -l)" "F2: ... and writes no env record"
done
# a value too long for 64-bit arithmetic is malformed, not a number (the regexes cap the length)
rc=0; ( export LLMCTL_RESERVE_MEM_MIN_MB=99999999999999999999; reserve_knobs_check ) || rc=$?; assert_eq 75 "${rc}" "F2: a 20-digit integer knob is refused"
rc=0; ( export LLMCTL_GATE_FULL_MAX=99999999999999999999.5; reserve_knobs_check ) || rc=$?; assert_eq 75 "${rc}" "F2: a 20-digit decimal knob is refused"
rc=0; ( export LLMCTL_GATE_FULL_MAX=1.5.2; reserve_knobs_check ) || rc=$?; assert_eq 75 "${rc}" "F2: a decimal knob with two points is refused"
# the scheduler's own PSI-only checks do not depend on the user's GATE_RESERVE_MB
rc=0; ( export LLMCTL_PSI_FILE="${PSI}" LLMCTL_MEMINFO_FILE="${MEMI}" LLMCTL_GATE_RESERVE_MB=9G _LLMCTL_GATE_INTERNAL_RESERVE_MB=0 LLMCTL_GATE_CPU_CHECKS=0; hw_pressure_gate 0 decide-tiny ) >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "F2: a malformed user LLMCTL_GATE_RESERVE_MB does not block the scheduler's internal PSI-only check"
rc=0; ( export LLMCTL_HOST_RESERVE=0 LLMCTL_PSI_FILE="${PSI}" LLMCTL_MEMINFO_FILE="${MEMI}" LLMCTL_RESERVE_MEM_MIN_MB=8G; hw_pressure_gate 0 decide-tiny ) >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "F2: with the reserve override on, a reserve knob is unused by the gate and not validated (legacy values apply)"

# ---------------------------------------------------------------------------------------------------------------------
echo "--- F3: pins for reviewer mutants A1, B, C2"
# A1: a stale LLMCTL_RESERVE_CPU_PCT_UNIT line (older record, or a hand edit) is replaced, never kept next to the new one
A1="${TEST_TMP}/a1"; mkdir -p "${A1}/units" "${A1}/services"
printf 'LLMCTL_PORT=1\nLLMCTL_RESERVE_CPU_PCT_UNIT=999\nLLMCTL_HOST_RESERVE=0\n' > "${A1}/services/i1.env"
( export LLMCTL_UNIT_DIR="${A1}/units" LLMCTL_SERVICES_DIR="${A1}/services" LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${TEST_TMP}/cg-a1"; newfs "${TEST_TMP}/cg-a1"
  _svc_write_reserve_dropin small llama i1 ) >/dev/null 2>&1 || true
assert_eq 1 "$(grep -c '^LLMCTL_RESERVE_CPU_PCT_UNIT=' "${A1}/services/i1.env")" "A1: exactly one LLMCTL_RESERVE_CPU_PCT_UNIT line after a rewrite"
assert_eq 0 "$(grep -c '^LLMCTL_HOST_RESERVE' "${A1}/services/i1.env")" "A1: the stale override line is gone"
q="$(sed -n 's/^LLMCTL_RESERVE_CPU_PCT_UNIT=//p' "${A1}/services/i1.env")"
if [[ "${q}" != 999 && "${q}" =~ ^[0-9]+$ ]]; then echo "  ok: A1: the line carries the freshly derived quota (${q}), not the stale 999"
else echo "  FAIL: A1: stale or missing quota line: '${q}'" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
assert_eq "${q}" "$(_hk_get "${A1}/services/i1.env" LLMCTL_RESERVE_CPU_PCT_UNIT)" "A1: the start gate (_hk_get) reads that same value"

# B: the memo key must follow the cgroup chain through MANY computes (a key built from the previous scan lags one compute
# behind: it only goes stale from the third compute on, after two computes at the same limit)
FS3="${TEST_TMP}/cg-b"; newfs "${FS3}"
export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${FS3}" LLMCTL_HOST_CPUS=16
printf '%s\n' $(( 20000 * MIB )) > "${FS3}/user.slice/memory.max"
reserve_compute; b1="${RSV_BM}"; reserve_compute; b2="${RSV_BM}"; reserve_compute; b3="${RSV_BM}"
printf '%s\n' $(( 9000 * MIB )) > "${FS3}/user.slice/memory.max"
reserve_compute; b4="${RSV_BM}"
if (( b1 == b2 && b2 == b3 && b4 < b3 && b4 <= 9000 )); then echo "  ok: B: after three computes at one limit, a tightened limit is seen at once (${b3} -> ${b4})"
else echo "  FAIL: B: stale memo after repeated computes (${b1} ${b2} ${b3} then ${b4})" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
printf '%s\n' $(( 30000 * MIB )) > "${FS3}/user.slice/memory.max"
reserve_compute; reserve_compute; printf '%s\n' $(( 7000 * MIB )) > "${FS3}/user.slice/memory.max"; reserve_compute
(( RSV_BM <= 7000 )) && echo "  ok: B: and again after a second round of computes (${RSV_BM})" || { echo "  FAIL: B: stale memo on the second round (${RSV_BM})" >&2; TEST_FAILS=$((TEST_FAILS+1)); }
unset LLMCTL_CGROUP_ROOT LLMCTL_CGROUP_FS LLMCTL_HOST_CPUS

# C2: a limit written with leading zeros longer than the overflow bound is a bounded number, not "unlimited"
FS4="${TEST_TMP}/cg-c2"; newfs "${FS4}"
bm10() { ( export LLMCTL_CGROUP_ROOT= LLMCTL_CGROUP_FS="${FS4}" LLMCTL_HOST_CPUS=16; capacity_json decide-tiny 2>/dev/null ) | python3 -c 'import json,sys; print(json.load(sys.stdin)["reserve"]["mem_model_budget_mb"])'; }
UNB="$(bm10)"
printf '%020d\n' $(( 12000 * MIB )) > "$(echo "${FS4}/user.slice/user-${U}.slice/user@${U}.service")/memory.max"
v="$(bm10)"
if (( v <= 12000 && v < UNB )); then echo "  ok: C2: a 20-digit zero-padded memory.max is read as 12000 MiB (budget ${v}, unlimited ${UNB})"
else echo "  FAIL: C2: zero-padded limit treated as unlimited (budget ${v}, unlimited ${UNB})" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
# C1: a 19-digit value above 2^63 would wrap negative in 64-bit arithmetic: it must count as unlimited, not as a 1 MiB limit
printf '9300000000000000000\n' > "$(echo "${FS4}/user.slice/user-${U}.slice/user@${U}.service")/memory.max"
v="$(bm10)"
(( v == UNB )) && echo "  ok: C1: a 19-digit value above 2^63 is unlimited (budget ${v}), not a wrapped 1 MiB limit" \
  || { echo "  FAIL: C1: value above 2^63 wrapped (budget ${v}, unlimited ${UNB})" >&2; TEST_FAILS=$((TEST_FAILS+1)); }
test_finish
