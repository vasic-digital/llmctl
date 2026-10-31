#!/usr/bin/env bash
# test_host_reserve_start_race.sh - UNIT-CLASS (hermetic cgroup-tree fixture). Round-8 finding 10 ("start-time race"):
# hk_gate (ExecStartPre) admits a unit, then the unit's cgroup is EMPTY for a moment (the gate process has exited, the
# engine is not forked yet). A second gate that runs in that window censuses the first unit as "not populated" and
# admits too, so two units together exceed the model budget. Fix: an admitted unit leaves a short-lived admission
# record that the census counts while the unit's cgroup is not populated yet (lib/reserve.sh reserve_admit_record).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
export LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
# shellcheck disable=SC1090
for l in common os_detect hardware catalog reserve svc_hook; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
export LLMCTL_HOST_MEM_MB=32768 LLMCTL_HOST_CPUS=16 LLMCTL_GATE_WAIT=0 LLMCTL_GATE_POLL=1
export LLMCTL_ADMIT_DIR="${TEST_TMP}/admit"   # the BASE dir (stands for /dev/shm: root-owned, sticky, never created by llmctl)
U="$(id -u)"; rec() { echo "${LLMCTL_ADMIT_DIR}/llmctl-admit-${2:-${U}}/$1"; }
newbase() { rm -rf "${LLMCTL_ADMIT_DIR:?}"; mkdir -m 1777 "${LLMCTL_ADMIT_DIR}"; }
newbase
printf 'MemTotal:       33554432 kB\nMemFree:        31457280 kB\nMemAvailable:   31457280 kB\n' > "${LLMCTL_MEMINFO_FILE}"
printf 'some avg10=0.00 avg60=0 avg300=0 total=0\n' > "${LLMCTL_CPU_PSI_FILE}"
reserve_compute   # 16 CPUs: model budget 12 CPUs = 1200 %

mkunit() { # <name> <cpu.max> <memory.max MiB> <populated 0|1>
  local d="${LLMCTL_CGROUP_ROOT}/app.slice/$1"; mkdir -p "${d}"
  printf 'populated %s\nfrozen 0\n' "$4" > "${d}/cgroup.events"; printf '%s\n' "$2" > "${d}/cpu.max"
  printf '%s\n' $(( $3 * 1048576 )) > "${d}/memory.max"
}
setpop() { printf 'populated %s\nfrozen 0\n' "$2" > "${LLMCTL_CGROUP_ROOT}/app.slice/$1/cgroup.events"; }
gate_as() { # <unit> -> rc of hk_gate run "inside" that unit's cgroup
  ( export LLMCTL_SELF_CGROUP="${LLMCTL_CGROUP_ROOT}/app.slice/$1"; hk_gate "${1#llmctl-llama@}" ) >/dev/null 2>"${TEST_TMP}/gate.err"
}
A='llmctl-llama@a.service'; B='llmctl-llama@b.service'

echo "--- gate A admitted, then the empty-cgroup window, then gate B (A 600% + B 700% > 1200%)"
mkunit "${A}" '600000 100000' 4096 1
mkunit "${B}" '700000 100000' 4096 0     # B has not started yet
rc=0; gate_as "${A}" || rc=$?
assert_eq 0 "${rc}" "A is admitted on an empty host"
setpop "${A}" 0            # ExecStartPre process exited, ExecStart not forked yet: the cgroup is empty
rc=0; gate_as "${B}" || rc=$?
assert_eq 75 "${rc}" "B is REFUSED while A's cgroup is empty (admitted-but-not-yet-running units count)"

echo "--- once A is populated by its engine it is counted from the cgroup, not twice"
setpop "${A}" 1
mkunit "${B}" '600000 100000' 4096 1
rc=0; gate_as "${B}" || rc=$?
assert_eq 0 "${rc}" "A (populated, also recorded) + B = 1200% <= 1200%: admitted, A not double counted"

echo "--- an expired admission record stops counting (a start that never happened)"
setpop "${A}" 0
mkunit "${B}" '700000 100000' 4096 1
find "${LLMCTL_ADMIT_DIR}" -type f -exec touch -d '10 minutes ago' {} + 2>/dev/null || true
rc=0; gate_as "${B}" || rc=$?
assert_eq 0 "${rc}" "a record older than the TTL is ignored"
echo "--- a record whose unit cgroup no longer exists stops counting"
newbase
mkunit "${A}" '600000 100000' 4096 1; gate_as "${A}" || true
rm -rf "${LLMCTL_CGROUP_ROOT:?}/app.slice/${A}"
rc=0; gate_as "${B}" || rc=$?
assert_eq 0 "${rc}" "no cgroup, no reservation"

echo "--- a refused gate leaves no record"
newbase
mkunit "${A}" '600000 100000' 4096 1
mkunit "${B}" '700000 100000' 4096 1
rc=0; gate_as "${B}" || rc=$?
assert_eq 75 "${rc}" "B refused against populated A"
n="$(find "${LLMCTL_ADMIT_DIR}" -type f 2>/dev/null | wc -l || true)"
assert_eq 0 "${n}" "a refused gate writes no admission record"

echo "--- design: the base dir is system-provided (like /dev/shm) and llmctl NEVER creates it (F2)"
rm -rf "${LLMCTL_ADMIT_DIR:?}"
mkunit "${A}" '100000 100000' 1024 1
rc=0; gate_as "${A}" || rc=$?
assert_eq 75 "${rc}" "F2: a missing base dir refuses the start (no auto-created world-writable dir owned by the first user)"
[[ ! -e "${LLMCTL_ADMIT_DIR}" ]] && ex=no || ex=yes
assert_eq no "${ex}" "F2: llmctl did not create the base dir"

echo "--- F1/S2: records live in a per-uid directory; the dir is host-wide, independent of the runtime/state dir"
a1="$(LLMCTL_RUNTIME_DIR=/x/one LLMCTL_STATE_DIR=/x/s1 XDG_RUNTIME_DIR=/x/r1 LLMCTL_ADMIT_DIR= _rsv_admit_dir)"
a2="$(LLMCTL_RUNTIME_DIR=/y/two LLMCTL_STATE_DIR=/y/s2 XDG_RUNTIME_DIR=/y/r2 LLMCTL_ADMIT_DIR= _rsv_admit_dir)"
assert_eq "${a1}" "${a2}" "default admission base is independent of the per-user runtime/state dir"
newbase
mkunit "${A}" '600000 100000' 4096 1; mkunit "${B}" '700000 100000' 4096 0
( export LLMCTL_RUNTIME_DIR="${TEST_TMP}/user1"; gate_as "${A}" ) || true
[[ -f "$(rec "${A}")" ]] && ex=yes || ex=no
assert_eq yes "${ex}" "the record is <base>/llmctl-admit-<uid>/<unit>"
setpop "${A}" 0; setpop "${B}" 1
rc=0; ( export LLMCTL_RUNTIME_DIR="${TEST_TMP}/user2"; gate_as "${B}" ) || rc=$?
assert_eq 75 "${rc}" "S2: a gate of a different user (other runtime dir) still sees the record"

echo "--- F2: users and root coexist (stat shim stands in for uids; there is only one real uid here)"
# shim: anything under llmctl-admit-<N> is owned by uid N
shim='stat() { local a="$*" n; if [[ "$a" =~ llmctl-admit-([0-9]+) ]]; then n="${BASH_REMATCH[1]}"; case "$a" in *"%a %u"*) echo "755 ${n}";; *"%u"*) echo "${n}";; *) command stat "$@";; esac; else command stat "$@"; fi; }'
newbase
mkunit "${A}" '600000 100000' 4096 1; mkunit "${B}" '700000 100000' 4096 0
mkdir -p "${LLMCTL_ADMIT_DIR}/llmctl-admit-0"   # a root-started unit's dir (dir for uid 0 created by "root")
printf '600 4096 %s\n' "${LLMCTL_CGROUP_ROOT}/app.slice/${A}" > "${LLMCTL_ADMIT_DIR}/llmctl-admit-0/${A}"
setpop "${A}" 0; setpop "${B}" 1
rc=0; ( eval "${shim}"; gate_as "${B}" ) || rc=$?
assert_eq 75 "${rc}" "F2: a user's gate counts a root-created record (root dir present, user dir absent)"
rc=0; gate_as "${B}" || rc=$?
assert_eq 0 "${rc}" "F2 control: the same record is ignored when its dir is not owned by its uid (no shim)"
echo "--- F2: a user-created per-uid dir does not lock root out: root gate writes into its own dir"
newbase
mkunit "${A}" '100000 100000' 1024 1
mkdir -m 755 "${LLMCTL_ADMIT_DIR}/llmctl-admit-$((U+1))"     # another uid's dir (owned by us here: foreign by name)
rc=0; gate_as "${A}" || rc=$?
assert_eq 0 "${rc}" "F2: a foreign-named dir in the base does not block this user's gate"
echo "--- F2: a squatted per-uid dir (owner != uid in its name) makes that uid's gate refuse, never hides a unit"
newbase
mkdir -m 755 "${LLMCTL_ADMIT_DIR}/llmctl-admit-${U}"
rc=0; ( eval "stat() { if [[ \"\$*\" == *llmctl-admit-${U}* && \"\$*\" == *%a* ]]; then echo '755 4242'; else command stat \"\$@\"; fi; }"; gate_as "${A}" ) || rc=$?
assert_eq 75 "${rc}" "a per-uid dir squatted by another uid refuses the start (fail closed)"

echo "--- F1/F5: a misnamed record is ignored; a malformed number in a correctly named own record makes the census unmeasurable (round 5, A)"
newbase; mkdir -m 755 "${LLMCTL_ADMIT_DIR}/llmctl-admit-${U}"
printf '600 4096 %s\n' "${LLMCTL_CGROUP_ROOT}/app.slice/${A}" > "${LLMCTL_ADMIT_DIR}/llmctl-admit-${U}/llmctl-llama@zzz.service"
setpop "${A}" 0; setpop "${B}" 1
rc=0; gate_as "${B}" || rc=$?
assert_eq 0 "${rc}" "a misnamed record is ignored"
printf 'abc 4096 %s\n' "${LLMCTL_CGROUP_ROOT}/app.slice/${A}" > "${LLMCTL_ADMIT_DIR}/llmctl-admit-${U}/${A}"
rc=0; gate_as "${B}" || rc=$?
assert_eq 75 "${rc}" "a non-numeric record makes the census unmeasurable"

echo "--- F2/S1: a failing record write refuses (75) instead of failing open"
newbase; : > "${TEST_TMP}/afile"
mkunit "${A}" '600000 100000' 4096 1; setpop "${B}" 0
rc=0; ( export LLMCTL_ADMIT_DIR="${TEST_TMP}/afile/sub"; gate_as "${A}" ) || rc=$?
assert_eq 75 "${rc}" "S1: admission dir under a regular file: the gate refuses"
echo "--- F2: a non-directory admission path makes the census unmeasurable"
mkunit "${B}" '100000 100000' 1024 1
rc=0; ( export LLMCTL_ADMIT_DIR="${TEST_TMP}/afile"; gate_as "${B}" ) || rc=$?
assert_eq 75 "${rc}" "a non-directory admission path refuses the start"

echo "--- F3/S3: pending records are read BEFORE the running census (a 0->1 flip in between double counts, never zero)"
newbase
mkunit "${A}" '600000 100000' 4096 1; mkunit "${B}" '700000 100000' 4096 1; gate_as "${A}" || true
setpop "${A}" 0
_rsv_test_hook() { setpop "${A}" 1; }
rc=0; ( export LLMCTL_TEST_MODE=1; gate_as "${B}" ) || rc=$?
unset -f _rsv_test_hook
assert_eq 75 "${rc}" "S3: A flipping to populated between the two reads is counted (not zero times)"

echo "--- F4: LLMCTL_ADMIT_TTL=0 is refused, not a silent disable"
setpop "${A}" 1; mkunit "${B}" '100000 100000' 1024 1
rc=0; ( export LLMCTL_ADMIT_TTL=0; gate_as "${B}" ) || rc=$?
assert_eq 75 "${rc}" "TTL=0 refuses with 75"
echo "--- a world-writable NON-sticky base dir is refused; a sticky one is accepted"
rm -rf "${LLMCTL_ADMIT_DIR:?}"; mkdir "${LLMCTL_ADMIT_DIR}"; chmod 0777 "${LLMCTL_ADMIT_DIR}"
mkunit "${A}" '100000 100000' 1024 1; setpop "${B}" 0
rc=0; gate_as "${A}" || rc=$?
assert_eq 75 "${rc}" "mode 0777 without the sticky bit refuses"
chmod 1777 "${LLMCTL_ADMIT_DIR}"
rc=0; gate_as "${A}" || rc=$?
assert_eq 0 "${rc}" "mode 1777 is accepted"
echo "--- F2: census-only (no record write): a non-directory admission path is UNMEASURABLE, rc 75"
rc=0; ( export LLMCTL_ADMIT_DIR="${TEST_TMP}/afile" LLMCTL_SELF_CGROUP="${LLMCTL_CGROUP_ROOT}/app.slice/${A}"; reserve_combined_check 100 1024 t >/dev/null 2>&1 ) || rc=$?
assert_eq 75 "${rc}" "reserve_combined_check refuses on an unusable admission path"

echo "--- N3: the test hook is ignored unless LLMCTL_TEST_MODE is set"
newbase
mkunit "${A}" '600000 100000' 4096 1; mkunit "${B}" '700000 100000' 4096 0; gate_as "${A}" || true
setpop "${A}" 0; setpop "${B}" 1
_rsv_test_hook() { : > "${TEST_TMP}/hook_ran"; }
rm -f "${TEST_TMP}/hook_ran"
rc=0; gate_as "${B}" || rc=$?
unset -f _rsv_test_hook
assert_eq 75 "${rc}" "N3: B still refused (A pending)"
[[ ! -e "${TEST_TMP}/hook_ran" ]] && h=absent || h=ran
assert_eq absent "${h}" "N3: without LLMCTL_TEST_MODE an injected _rsv_test_hook does not run"

echo "--- N1: a freshly written record is world-readable (another uid's gate must read it)"
newbase
mkunit "${B}" '100000 100000' 1024 0; mkunit "${A}" '600000 100000' 4096 1; gate_as "${A}" || true
m="$(stat -c %a "$(rec "${A}")")"
assert_eq 644 "${m}" "N1: the admission record is mode 0644"
echo "--- N1: a correctly named record that cannot be read makes the census unmeasurable (75), not silently skipped"
setpop "${A}" 0; mkunit "${B}" '100000 100000' 1024 1
chmod 000 "$(rec "${A}")"
if [[ "${U}" != 0 ]]; then
  rc=0; gate_as "${B}" || rc=$?
  assert_eq 75 "${rc}" "N1: unreadable record refuses (simulated with chmod 000; no second uid available)"
fi
chmod 644 "$(rec "${A}")"

echo "--- N4/F3: a record whose cgroup path is outside the cgroup root (also via ..) is ignored"
newbase; mkdir -m 755 "${LLMCTL_ADMIT_DIR}/llmctl-admit-${U}"
mkdir -p "${TEST_TMP}/outside/${A}"; printf 'populated 0\n' > "${TEST_TMP}/outside/${A}/cgroup.events"
printf '1100 max %s\n' "${TEST_TMP}/outside/${A}" > "$(rec "${A}")"
mkunit "${B}" '700000 100000' 4096 1
rc=0; gate_as "${B}" || rc=$?
assert_eq 0 "${rc}" "N4: out-of-root cgroup path in a record is not counted"
mkdir -p "${LLMCTL_CGROUP_ROOT}/../outside_dd/${A}"; printf 'populated 0\n' > "${LLMCTL_CGROUP_ROOT}/../outside_dd/${A}/cgroup.events"
printf '1100 max %s\n' "${LLMCTL_CGROUP_ROOT}/../outside_dd/${A}" > "$(rec "${A}")"
rc=0; gate_as "${B}" || rc=$?
assert_eq 0 "${rc}" "F3: a '..' path that leaves the cgroup root is not counted"

echo "--- N2: a sticky base owned by a foreign uid is refused (stat shimmed: no second uid available)"
newbase
mkunit "${B}" '100000 100000' 1024 1
rc=0; ( stat() { if [[ "$*" == *"%a %u"* && "$*" != *llmctl-admit-* ]]; then echo "1777 4242"; else command stat "$@"; fi; }; gate_as "${B}" ) || rc=$?
assert_eq 75 "${rc}" "N2: sticky base owned by uid 4242 refuses"
rc=0; ( stat() { if [[ "$*" == *"%a %u"* && "$*" != *llmctl-admit-* ]]; then echo "1777 0"; else command stat "$@"; fi; }; gate_as "${B}" ) || rc=$?
assert_eq 0 "${rc}" "N2: sticky base owned by root is accepted"

echo "--- F1 (round 3): a planted DIRECTORY at the record name must not hide the record"
newbase; mkdir -m 755 "${LLMCTL_ADMIT_DIR}/llmctl-admit-${U}"
mkunit "${A}" '600000 100000' 4096 1; mkunit "${B}" '700000 100000' 4096 0
mkdir "$(rec "${A}")"
rc=0; gate_as "${A}" || rc=$?
assert_eq 75 "${rc}" "F1: planted directory at the record path: the admitting gate refuses (fail closed)"
echo "--- F1 (round 3): a planted SYMLINK to a directory at the record name must not hide the record"
newbase; mkdir -m 755 "${LLMCTL_ADMIT_DIR}/llmctl-admit-${U}"; mkdir "${TEST_TMP}/symtarget"
ln -s "${TEST_TMP}/symtarget" "$(rec "${A}")"
rc=0; gate_as "${A}" || rc=$?
if [[ "${rc}" == 0 ]]; then
  [[ -f "$(rec "${A}")" && ! -L "$(rec "${A}")" ]] && ok=yes || ok=no
  assert_eq yes "${ok}" "F1: gate admitted, so the record must be a regular file, not inside the symlinked dir"
else
  assert_eq 75 "${rc}" "F1: planted symlink refused"
fi
echo "--- F1 (round 3): mktemp succeeds but the rename fails -> refuse (kills 'mv ... || true')"
newbase; mkdir -m 755 "${LLMCTL_ADMIT_DIR}/llmctl-admit-${U}"; mkunit "${A}" '100000 100000' 1024 1
rc=0; ( mv() { return 1; }; gate_as "${A}" ) || rc=$?
assert_eq 75 "${rc}" "F1: failed rename refuses the start"

echo "--- F4 (round 3): a record with a far-future mtime does not outlive the TTL"
newbase
mkunit "${A}" '600000 100000' 4096 1; mkunit "${B}" '700000 100000' 4096 0; gate_as "${A}" || true
setpop "${A}" 0; setpop "${B}" 1
touch -d '+10 years' "$(rec "${A}")"
rc=0; gate_as "${B}" || rc=$?
assert_eq 0 "${rc}" "F4: a future-dated record is invalid, not immortal"

echo "--- F5 (round 3): a base dir without read/search permission is unmeasurable (kills 'drop -r/-x check')"
newbase
mkunit "${A}" '600000 100000' 4096 1; mkunit "${B}" '700000 100000' 4096 0; gate_as "${A}" || true
setpop "${A}" 0; setpop "${B}" 1
chmod 1000 "${LLMCTL_ADMIT_DIR}"
if [[ "${U}" != 0 ]]; then
  rc=0; gate_as "${B}" || rc=$?
  assert_eq 75 "${rc}" "F5: an unreadable base dir refuses instead of reading as empty"
  # census only (no record write), so the reader's own base check is what refuses
  rc=0; ( export LLMCTL_SELF_CGROUP="${LLMCTL_CGROUP_ROOT}/app.slice/${B}"; reserve_combined_check 100 1024 t >/dev/null 2>&1 ) || rc=$?
  assert_eq 75 "${rc}" "F5: census-only on an unreadable base refuses (reader check, not the writer's)"
fi
chmod 1777 "${LLMCTL_ADMIT_DIR}"
test_finish
