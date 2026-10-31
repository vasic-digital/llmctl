#!/usr/bin/env bash
# test_host_reserve_round5.sh - UNIT-CLASS (hermetic cgroup-tree fixture). Review round 4 findings of the census-race fix:
#   A  record numbers are bounded and decimal (no wrap, no octal), every other file/cgroup number the gate sums likewise
#   B  a correctly owned per-uid dir the reader cannot list/use is unmeasurable (75), never silently skipped; writer needs o+rx
#   C  records are read again AFTER the census (union), also for units that turned populated since
#   D  mutants M5 (reader trusts any per-uid dir) and M6 (reader skips the record-owner check) are each killed ALONE
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
export LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
# shellcheck disable=SC1090
for l in common os_detect hardware catalog reserve svc_hook; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
export LLMCTL_HOST_MEM_MB=32768 LLMCTL_HOST_CPUS=16 LLMCTL_GATE_WAIT=0 LLMCTL_GATE_POLL=1
export LLMCTL_ADMIT_DIR="${TEST_TMP}/admit"
U="$(id -u)"; rec() { echo "${LLMCTL_ADMIT_DIR}/llmctl-admit-${2:-${U}}/$1"; }
newbase() { rm -rf "${LLMCTL_ADMIT_DIR:?}"; mkdir -m 1777 "${LLMCTL_ADMIT_DIR}"; mkdir -m 755 "${LLMCTL_ADMIT_DIR}/llmctl-admit-${U}"; }
printf 'MemTotal:       33554432 kB\nMemFree:        31457280 kB\nMemAvailable:   31457280 kB\n' > "${LLMCTL_MEMINFO_FILE}"
printf 'some avg10=0.00 avg60=0 avg300=0 total=0\n' > "${LLMCTL_CPU_PSI_FILE}"
reserve_compute
mkunit() { local d="${LLMCTL_CGROUP_ROOT}/app.slice/$1"; mkdir -p "${d}"
  printf 'populated %s\nfrozen 0\n' "$4" > "${d}/cgroup.events"; printf '%s\n' "$2" > "${d}/cpu.max"; printf '%s\n' $(( $3 * 1048576 )) > "${d}/memory.max"; }
setpop() { printf 'populated %s\nfrozen 0\n' "$2" > "${LLMCTL_CGROUP_ROOT}/app.slice/$1/cgroup.events"; }
gate_as() { ( export LLMCTL_SELF_CGROUP="${LLMCTL_CGROUP_ROOT}/app.slice/$1"; hk_gate "${1#llmctl-llama@}" ) >/dev/null 2>"${TEST_TMP}/gate.err"; }
A='llmctl-llama@a.service'; B='llmctl-llama@b.service'
forge() { printf '%s\n' "$1" > "$(rec "${A}")"; }   # forge "<cpu> <mem> <cgroup>"
cgA="${LLMCTL_CGROUP_ROOT}/app.slice/${A}"

echo "=== A: record numbers are bounded decimal; anything else is unmeasurable (75), never wrapped/aborted/octal"
mkunit "${A}" '100000 100000' 1024 0; mkunit "${B}" '100000 100000' 1024 1
for bad in "18446744073709551000 1024" "0099 1024" "0010 1024" "100 0010" "100 18446744073709551000" "-5 1024" "1e3 1024" "1000000000 1024" "00 1024"; do
  newbase; forge "${bad} ${cgA}"
  rc=0; gate_as "${B}" || rc=$?
  assert_eq 75 "${rc}" "A: record '${bad}' -> rc 75"
  assert_contains "$(cat "${TEST_TMP}/gate.err")" "cannot count" "A: '${bad}' is reported as unmeasurable, not as a budget breach"
done
echo "--- A control: boundary 9-digit and 0 / max are valid numbers (a budget verdict, not 'cannot count')"
newbase; forge "999999999 max ${cgA}"
rc=0; gate_as "${B}" || rc=$?
assert_eq 75 "${rc}" "A: 999999999 counts and breaches the budget"
assert_contains "$(cat "${TEST_TMP}/gate.err")" "would be breached" "A: valid number -> budget refusal"
newbase; forge "0 0 ${cgA}"
rc=0; gate_as "${B}" || rc=$?
assert_eq 0 "${rc}" "A: '0 0' is a valid record and fits"
newbase; forge "max max ${cgA}"
rc=0; gate_as "${B}" || rc=$?
assert_eq 75 "${rc}" "A: 'max max' counts as the whole budget"

echo "--- A: cgroup files: cpu.max / memory.max with leading zeros or overflow (no octal, no wrap)"
d="${TEST_TMP}/cg1"; mkdir -p "${d}"
printf '000100000 0100000\n' > "${d}/cpu.max"; assert_eq 100 "$(_rsv_cpu_pct "${d}")" "cpu.max with leading zeros is read as decimal (100%)"
printf '18446744073709551616 100000\n' > "${d}/cpu.max"; assert_eq "" "$(_rsv_cpu_pct "${d}")" "cpu.max overflow is not a limit (counts as unbounded)"
printf '0099 0100\n' > "${d}/cpu.max"; assert_eq 99 "$(_rsv_cpu_pct "${d}")" "cpu.max 0099/0100 is decimal"
printf '0000000001048576\n' > "${d}/memory.max"; assert_eq 1 "$(_rsv_mem_mb "${d}")" "memory.max with leading zeros is decimal"
printf '99999999999999999999999\n' > "${d}/memory.max"; assert_eq "" "$(_rsv_mem_mb "${d}")" "memory.max overflow is not a limit"
assert_eq 100 "$(_rsv_int 0000000000000000000000100 5 1 4096)" "_rsv_int: >18 digits with leading zeros is decimal"
assert_eq 4096 "$(_rsv_int 99999999999999999999999999 5 1 4096)" "_rsv_int: overflow clamps to the ceiling, no wrap"
echo "--- A: the gate arguments (cpu/mem of the new unit)"
rc=0; ( export LLMCTL_SELF_CGROUP="${cgA}"; newbase; reserve_combined_check 18446744073709551000 1024 t >/dev/null 2>&1 ) || rc=$?
assert_eq 75 "${rc}" "A: an overflowing new-unit CPU argument does not wrap (falls back to the whole budget -> 75 or fits only if budget fits)"

echo "=== B: a correctly owned per-uid dir the reader cannot use is unmeasurable (75)"
mkunit "${A}" '100000 100000' 1024 0; mkunit "${B}" '100000 100000' 1024 1
for m in 0311 0775 0300; do
  newbase; forge "100 1024 ${cgA}"; chmod "${m}" "${LLMCTL_ADMIT_DIR}/llmctl-admit-${U}"
  rc=0; ( export LLMCTL_SELF_CGROUP="${LLMCTL_CGROUP_ROOT}/app.slice/${B}"; reserve_combined_check 100 1024 t >/dev/null 2>&1 ) || rc=$?
  assert_eq 75 "${rc}" "B: census-only with per-uid dir mode ${m} -> 75"
  chmod 0755 "${LLMCTL_ADMIT_DIR}/llmctl-admit-${U}"
done
echo "--- B control: an owner mismatch is a squat and is ignored (stat shim)"
newbase; forge "1100 1024 ${cgA}"
rc=0; ( stat() { if [[ "$*" == *"%a %u"* && "$*" == *llmctl-admit-* ]]; then echo "755 4242"; else command stat "$@"; fi; }
        export LLMCTL_SELF_CGROUP="${LLMCTL_CGROUP_ROOT}/app.slice/${B}"; reserve_combined_check 100 1024 t >/dev/null 2>&1 ) || rc=$?
assert_eq 0 "${rc}" "B: a per-uid dir owned by someone else is ignored by the reader"
echo "--- B writer: the per-uid dir must be o+rx (0700 is refused: other uids could not list it)"
newbase; chmod 0700 "${LLMCTL_ADMIT_DIR}/llmctl-admit-${U}"; mkunit "${A}" '100000 100000' 1024 1
rc=0; gate_as "${A}" || rc=$?
assert_eq 75 "${rc}" "B: writer refuses a 0700 per-uid dir"
newbase; mkunit "${A}" '100000 100000' 1024 1
rc=0; gate_as "${A}" || rc=$?
assert_eq 0 "${rc}" "B control: 0755 per-uid dir is accepted"

echo "=== C: records are re-read AFTER the census (union), also for units that turned populated since"
mkunit "${A}" '600000 100000' 4096 1; mkunit "${B}" '700000 100000' 4096 0
newbase; gate_as "${A}" || true     # A admitted, record written, A populated (its own ExecStartPre)
mkunit "${B}" '700000 100000' 4096 1
_rsv_test_hook() { setpop "${A}" 0; }     # between the first read and the census A's gate process exits: cgroup empty
rc=0; ( export LLMCTL_TEST_MODE=1; gate_as "${B}" ) || rc=$?
unset -f _rsv_test_hook
assert_eq 75 "${rc}" "C1: populated at the first read, empty at the census -> still counted (second read)"
echo "--- C2: record appears after the first read, cgroup empty at the census, populated at the second read"
newbase; setpop "${A}" 0; mkunit "${B}" '700000 100000' 4096 1
_rsv_test_hook() { printf '600 4096 %s\n' "${cgA}" > "$(rec "${A}")"; }
_rsv_test_hook_post() { setpop "${A}" 1; }   # the engine forked right after the census
rc=0; ( export LLMCTL_TEST_MODE=1; gate_as "${B}" ) || rc=$?
unset -f _rsv_test_hook _rsv_test_hook_post
assert_eq 75 "${rc}" "C2: counted although empty at the census and populated at the second read"
echo "--- C control: a unit counted by the census is not counted twice by the records"
newbase; setpop "${A}" 1; forge "600 4096 ${cgA}"; mkunit "${B}" '600000 100000' 4096 1
rc=0; gate_as "${B}" || rc=$?
assert_eq 0 "${rc}" "C: A (populated + recorded) + B = 1200% fits: no double count"

echo "=== D: mutants M5 / M6 each killed alone"
mkunit "${A}" '600000 100000' 4096 0; mkunit "${B}" '700000 100000' 4096 1
# M5: per-uid dir owned by a foreign uid (4242) but the record claims owner 4242 too -> only the DIR check can reject it
newbase; mkdir -m 755 "${LLMCTL_ADMIT_DIR}/llmctl-admit-4242"; printf '600 4096 %s\n' "${cgA}" > "${LLMCTL_ADMIT_DIR}/llmctl-admit-4242/${A}"
rc=0; ( stat() { case "$*" in *"%a %u"*llmctl-admit-4242*) echo "755 ${U}";; *"%u"*llmctl-admit-4242/*) echo 4242;; *) command stat "$@";; esac; }
        gate_as "${B}" ) || rc=$?
assert_eq 0 "${rc}" "M5: a dir owned by another uid is ignored even if its records claim the dir's uid"
# M6: dir looks right (owner 4242 == name) but the record is owned by someone else -> only the RECORD owner check rejects it
newbase; mkdir -m 755 "${LLMCTL_ADMIT_DIR}/llmctl-admit-4242"; printf '600 4096 %s\n' "${cgA}" > "${LLMCTL_ADMIT_DIR}/llmctl-admit-4242/${A}"
rc=0; ( stat() { case "$*" in *"%a %u"*llmctl-admit-4242*) echo "755 4242";; *) command stat "$@";; esac; }
        gate_as "${B}" ) || rc=$?
assert_eq 0 "${rc}" "M6: a record not owned by the uid of its dir is ignored"
echo "--- D control: both shims with everything consistent DO count (so the two tests above can fail)"
newbase; mkdir -m 755 "${LLMCTL_ADMIT_DIR}/llmctl-admit-4242"; printf '600 4096 %s\n' "${cgA}" > "${LLMCTL_ADMIT_DIR}/llmctl-admit-4242/${A}"
rc=0; ( stat() { case "$*" in *"%a %u"*llmctl-admit-4242*) echo "755 4242";; *"%u"*llmctl-admit-4242/*) echo 4242;; *) command stat "$@";; esac; }
        gate_as "${B}" ) || rc=$?
assert_eq 75 "${rc}" "D control: consistent foreign-uid dir + record are counted"
test_finish
