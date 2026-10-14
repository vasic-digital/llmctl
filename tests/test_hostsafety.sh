#!/usr/bin/env bash
# test_hostsafety.sh - tests for scripts/hostsafety (docs/host-safety.md).
# Fixture-driven (fake /proc, fake podman/gsettings, temp install dirs) plus ONE live
# containment section that runs only inside its own tiny systemd --user scope
# (bounded-run --tiny -t 100 -m 256M) - it never touches the host's real limits.
# Every fixture pid/pgid is above kernel pid_max (4194304) so a signal can never
# reach a real process even if a code path misfires (constitution 11.4.263).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

HS="${LLMCTL_ROOT}/scripts/hostsafety"
GUARD="${HS}/guard.py"
export HOSTSAFETY_NO_SYSTEMCTL=1

# --- 0. static: shellcheck + python compile ------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  assert_rc 0 "shellcheck -x clean on every hostsafety shell script" \
    shellcheck -S warning -x -P SCRIPTDIR "${HS}"/lib.sh "${HS}"/bounded-run "${HS}"/agent-run "${HS}"/install.sh "${HS}"/podman-audit.sh \
      "${HS}"/tracker-exclude.sh "${HS}"/root-steps.sh "${HS}"/persistence-check.sh "${LLMCTL_ROOT}/tests/test_hostsafety.sh"
else
  assert_skip "shellcheck not installed" "shellcheck on hostsafety scripts"
fi
assert_rc 0 "guard.py parses" python3 -I -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "${GUARD}"
FIX="${LLMCTL_ROOT}/tests/hostsafety_guard_fixtures.py"
assert_rc 0 "assert_skip with the (reason, name) pair works under set -u" bash -c "set -u; source '${LLMCTL_ROOT}/tests/helpers.sh'; assert_skip 'r' 'n'"

# --- 1. limits are sized from detected MemTotal --------------------------------------------
printf 'MemTotal:       16777216 kB\nSwapTotal:       8388608 kB\n' >"${TEST_TMP}/meminfo16"
lim() { HOSTSAFETY_MEMINFO="${TEST_TMP}/meminfo16" HOSTSAFETY_NPROC="$2" bash -c "source '${HS}/lib.sh'; hs_limits $1"; }
a16="$(lim app 8 | paste -sd' ')"
# app.slice swap cap = SwapTotal * HOSTSAFETY_APP_SWAP_PCT / 100 (default 50): shmem and anon must be swappable under MemoryHigh
# (2026-10-14: a 1 GiB cap kept 8.1 G of tmpfs shmem in RAM while swap stayed 75% free)
assert_eq "MemoryHigh=12025908428 MemoryMax=13743895347 MemorySwapMax=4294967296 TasksMax=8192" "${a16}" "app limits for 16 GiB / 8 CPUs (High 70%, Max 80%, swap cap SwapTotal/2)"
assert_eq "TasksMax=4096" "$(lim app 1 | grep Tasks)" "TasksMax floor"
assert_eq "TasksMax=32768" "$(lim app 128 | grep Tasks)" "TasksMax ceiling"
assert_eq "MemorySwapMax=536870912" "$(lim background 8 | grep Swap)" "background swap cap"
printf 'MemTotal:       16777216 kB\nSwapTotal:       1048576 kB\n' >"${TEST_TMP}/meminfo_smallswap"
assert_eq "MemorySwapMax=268435456" \
  "$(HOSTSAFETY_MEMINFO="${TEST_TMP}/meminfo_smallswap" bash -c "source '${HS}/lib.sh'; hs_limits background" | grep Swap)" "background/user swap cap never exceeds 1/4 of the swap device"
assert_eq "MemorySwapMax=536870912" \
  "$(HOSTSAFETY_MEMINFO="${TEST_TMP}/meminfo_smallswap" bash -c "source '${HS}/lib.sh'; hs_limits app" | grep Swap)" "app swap cap is half of a small swap device too (no fixed 1 GiB cap)"
assert_eq "MemorySwapMax=2147483648" "$(HOSTSAFETY_APP_SWAP_PCT=25 lim app 8 | grep Swap)" "HOSTSAFETY_APP_SWAP_PCT=25 sizes the app swap cap at a quarter of swap"
for bad in 0 101 abc -5 ""; do
  if [[ -z "${bad}" ]]; then continue; fi
  assert_rc 1 "HOSTSAFETY_APP_SWAP_PCT=${bad} is refused (1..100)" env HOSTSAFETY_APP_SWAP_PCT="${bad}" HOSTSAFETY_MEMINFO="${TEST_TMP}/meminfo16" bash -c "source '${HS}/lib.sh'; hs_limits app"
done
printf 'MemTotal:       16777216 kB\nSwapTotal:       0 kB\n' >"${TEST_TMP}/meminfo_noswap"
assert_eq "MemorySwapMax=0" "$(HOSTSAFETY_MEMINFO="${TEST_TMP}/meminfo_noswap" bash -c "source '${HS}/lib.sh'; hs_limits app" | grep Swap)" "no swap device: app swap cap 0"
# mutation proof for the formula: the old cap (min(1 GiB, SwapTotal/4)) in a scratch copy of lib.sh must break the expected value
mlib="${TEST_TMP}/mut_lib.sh"
sed 's|^  \[\[ "${slice}" == app \]\] \&\& swap_cap=.*$|  :|' "${HS}/lib.sh" >"${mlib}"
assert_eq "yes" "$(cmp -s "${mlib}" "${HS}/lib.sh" && echo no || echo yes)" "mutation [m22 app swap cap reverted to the 1/4 rule]: the mutation is real"
assert_eq "yes" "$([[ "$(HOSTSAFETY_MEMINFO="${TEST_TMP}/meminfo16" HOSTSAFETY_NPROC=8 bash -c "source '${mlib}'; hs_limits app" | grep Swap)" != "MemorySwapMax=4294967296" ]] && echo yes || echo no)" "mutation [m22 app swap cap reverted to the 1/4 rule] is CAUGHT by the app sizing assertion"
assert_rc 1 "unknown slice (session) refused" bash -c "source '${HS}/lib.sh'; hs_limits session"

# --- 2. installer: dry-run / idempotent / backup / uninstall -------------------------------
assert_rc 1 "install refuses a bad HOSTSAFETY_APP_SWAP_PCT before writing anything" env HOSTSAFETY_APP_SWAP_PCT=abc HOSTSAFETY_CONFIG_HOME="${TEST_TMP}/cbad" \
  HOSTSAFETY_DATA_HOME="${TEST_TMP}/dbad" HOSTSAFETY_BIN_DIR="${TEST_TMP}/bbad" HOSTSAFETY_BACKUP_DIR="${TEST_TMP}/bkbad" HOSTSAFETY_NO_TRACKER=1 \
  HOSTSAFETY_MEMINFO="${TEST_TMP}/meminfo16" HOSTSAFETY_NPROC=8 "${HS}/install.sh"
assert_eq "0" "$(find "${TEST_TMP}/cbad" "${TEST_TMP}/dbad" "${TEST_TMP}/bbad" -type f 2>/dev/null | wc -l)" "refused install wrote no file (no header-only drop-in)"
inst_env() { HOSTSAFETY_CONFIG_HOME="${TEST_TMP}/c" HOSTSAFETY_DATA_HOME="${TEST_TMP}/d" HOSTSAFETY_BIN_DIR="${TEST_TMP}/b" \
  HOSTSAFETY_BACKUP_DIR="${TEST_TMP}/bk" HOSTSAFETY_NO_TRACKER=1 HOSTSAFETY_MEMINFO="${INST_MEMINFO:-${TEST_TMP}/meminfo16}" HOSTSAFETY_NPROC=8 "$@"; }
out="$(inst_env "${HS}/install.sh" --dry-run)"
assert_contains "${out}" "WOULD write ${TEST_TMP}/c/systemd/user/app.slice.d/10-hostsafety.conf" "dry-run lists the app drop-in"
assert_eq "0" "$(find "${TEST_TMP}/c" "${TEST_TMP}/d" "${TEST_TMP}/b" -type f 2>/dev/null | wc -l)" "dry-run writes nothing"
inst_env "${HS}/install.sh" >"${TEST_TMP}/inst1.out"
assert_file_exists "${TEST_TMP}/c/systemd/user/app.slice.d/10-hostsafety.conf" "app drop-in installed"
assert_file_exists "${TEST_TMP}/c/systemd/user/background.slice.d/10-hostsafety.conf" "background drop-in installed"
assert_file_exists "${TEST_TMP}/c/systemd/user/user.slice.d/10-hostsafety.conf" "podman user.slice drop-in installed"
assert_eq "no" "$([[ -e ${TEST_TMP}/c/systemd/user/session.slice.d ]] && echo yes || echo no)" "session.slice is never touched"
assert_file_contains "${TEST_TMP}/c/systemd/user/app.slice.d/10-hostsafety.conf" "MemoryMax=13743895347" "drop-in sized from fixture MemTotal"
assert_eq "755" "$(stat -c %a "${TEST_TMP}/b/bounded-run")" "bounded-run installed executable"
assert_eq "600" "$(stat -c %a "${TEST_TMP}/c/hostsafety/guard.env")" "guard.env is 0600"
assert_file_contains "${TEST_TMP}/c/hostsafety/guard.env" "HOSTSAFETY_GUARD_ARM=0" "guard ships DISARMED (dry-run)"
# guard service unit: the guard must be a LOW-cost citizen (incident 2026-10-13: ~8-10% of a core under a 6,950-process storm)
GUNIT="${TEST_TMP}/c/systemd/user/hostsafety-guard.service"
for kv in "Nice=19" "IOSchedulingClass=idle" "CPUWeight=10" "MemoryMax=256M" "TimeoutStartSec=15" "Type=oneshot"; do
  assert_file_contains "${GUNIT}" "${kv}" "guard service unit carries ${kv}"
done
assert_eq "1" "$(grep -c '^ExecStart=' "${GUNIT}")" "guard service unit has exactly one ExecStart"
assert_eq "0" "$(grep -c '^RuntimeMaxSec=' "${GUNIT}" || true)" "no RuntimeMaxSec (ignored for Type=oneshot; TimeoutStartSec is the only real wall-clock cap)"
assert_eq "0" "$(grep -c '^TimeoutStartSec=20' "${GUNIT}" || true)" "TimeoutStartSec is 15, not the old 20"
sed -i 's/ARM=0/ARM=1/' "${TEST_TMP}/c/hostsafety/guard.env"
inst2="$(inst_env "${HS}/install.sh")"
assert_eq "0" "$(printf '%s\n' "${inst2}" | grep -c 'wrote ' || true)" "second install changes nothing (idempotent)"
assert_file_contains "${TEST_TMP}/c/hostsafety/guard.env" "HOSTSAFETY_GUARD_ARM=1" "operator's guard.env edit survives re-install"
# pre-existing differing file => backed up, then replaced
echo "# operator edit" >"${TEST_TMP}/c/systemd/user/app.slice.d/10-hostsafety.conf"
inst3="$(inst_env "${HS}/install.sh")"
assert_contains "${inst3}" "backed up  ${TEST_TMP}/c/systemd/user/app.slice.d/10-hostsafety.conf" "overwritten file is backed up first"
assert_eq "1" "$(find "${TEST_TMP}/bk" -name 10-hostsafety.conf | wc -l)" "backup copy exists under the backup root"
assert_file_contains "$(find "${TEST_TMP}/bk" -name 10-hostsafety.conf)" "# operator edit" "backup holds the operator's original content"
assert_eq "0" "$(grep -c 'guard.env' "${TEST_TMP}/d/hostsafety/manifest" || true)" "guard.env is never listed in the manifest (it is operator config)"
inst_env "${HS}/install.sh" uninstall >/dev/null
# our own (edited / earlier generated) copy was NOT there before the first install => uninstall must NOT resurrect it from a backup
assert_eq "no" "$([[ -e ${TEST_TMP}/c/systemd/user/app.slice.d/10-hostsafety.conf ]] && echo yes || echo no)" "uninstall does not restore hostsafety's own previous (edited) generated file"
assert_eq "1" "$(find "${TEST_TMP}/c" "${TEST_TMP}/b" "${TEST_TMP}/d" -type f 2>/dev/null | wc -l)" "uninstall removes every managed file; only the operator's guard.env stays"
assert_file_exists "${TEST_TMP}/c/hostsafety/guard.env" "guard.env is kept in place on uninstall (as the final message says)"
assert_file_contains "${TEST_TMP}/c/hostsafety/guard.env" "HOSTSAFETY_GUARD_ARM=1" "kept guard.env holds the operator's edit"
# a file that existed BEFORE the first install IS restored; re-installs with different content never become 'the original'
rm -rf "${TEST_TMP}/c" "${TEST_TMP}/d" "${TEST_TMP}/b" "${TEST_TMP}/bk"
mkdir -p "${TEST_TMP}/c/systemd/user/app.slice.d"; echo "# pre-existing operator file" >"${TEST_TMP}/c/systemd/user/app.slice.d/10-hostsafety.conf"
inst_env "${HS}/install.sh" >/dev/null
assert_contains "$(cat "${TEST_TMP}/c/systemd/user/app.slice.d/10-hostsafety.conf")" "MemoryMax=13743895347" "first install replaced the pre-existing file"
gen1="$(cat "${TEST_TMP}/c/systemd/user/app.slice.d/10-hostsafety.conf")"
printf 'MemTotal:       8388608 kB\nSwapTotal:       1048576 kB\n' >"${TEST_TMP}/meminfo8"
INST_MEMINFO="${TEST_TMP}/meminfo8" inst_env "${HS}/install.sh" >/dev/null   # re-size: a second generated version
assert_eq "yes" "$([[ "$(cat "${TEST_TMP}/c/systemd/user/app.slice.d/10-hostsafety.conf")" != "${gen1}" ]] && echo yes || echo no)" "re-install re-sized the drop-in (a second generated version exists)"
inst_env "${HS}/install.sh" uninstall >/dev/null
assert_file_contains "${TEST_TMP}/c/systemd/user/app.slice.d/10-hostsafety.conf" "# pre-existing operator file" "uninstall restores the file that existed BEFORE the first install, not hostsafety's earlier generation"

# --- 2c. persistence: does every setting survive a reboot? (persistence-check.sh / install.sh verify-persistence) ---
# Everything is re-rooted: a fixture install, a fixture root tree, fake systemctl/loginctl answering from the fixture files.
pc="${TEST_TMP}/pc"; pcs="${pc}/shim"; mkdir -p "${pcs}" "${pc}/state/hostsafety"
env HOSTSAFETY_CONFIG_HOME="${pc}/c" HOSTSAFETY_DATA_HOME="${pc}/d" HOSTSAFETY_BIN_DIR="${pc}/b" HOSTSAFETY_BACKUP_DIR="${pc}/bk" \
  HOSTSAFETY_NO_TRACKER=1 HOSTSAFETY_NO_SYSTEMCTL=1 HOSTSAFETY_MEMINFO="${TEST_TMP}/meminfo16" HOSTSAFETY_NPROC=8 "${HS}/install.sh" >"${pc}/inst.out" 2>&1
assert_file_exists "${pc}/c/systemd/user/hostsafety-selfcheck.service" "install writes the boot self-check unit"
assert_file_contains "${pc}/c/systemd/user/hostsafety-selfcheck.service" "WantedBy=default.target" "self-check unit is wanted by default.target (runs at every boot with linger)"
for kv in "Nice=19" "TimeoutStartSec=30" "Type=oneshot" "persistence-check.sh --boot-check"; do
  assert_file_contains "${pc}/c/systemd/user/hostsafety-selfcheck.service" "${kv}" "self-check unit carries ${kv}"
done
assert_eq "0" "$(grep -vE '^[[:space:]]*#' "${HS}/persistence-check.sh" | grep -cE '(^|[^a-z_-])(kill|pkill|killall)([^a-z_]|$)|uctl (stop|kill|restart|start)|systemctl[^|]*(stop|kill|restart)' || true)" "persistence-check.sh never stops, restarts or signals anything (no kill/stop/restart call)"
assert_file_contains "${pc}/d/hostsafety/source-dir" "${HS}" "install records the source tree its copies came from"
# fixture root tree in which every root row passes
RP="${pc}/root"; mkdir -p "${RP}/usr/lib/systemd/system" "${RP}/proc/sys/vm" "${RP}/etc/default"
printf '[Mount]\nOptions=mode=1777,strictatime,nosuid,nodev,size=50%%%%,nr_inodes=1m,x-systemd.graceful-option=usrquota\n' >"${RP}/usr/lib/systemd/system/tmp.mount"
echo 20 >"${RP}/proc/sys/vm/swappiness"; printf 'EARLYOOM_ARGS="-r 3600"\n' >"${RP}/etc/default/earlyoom"
HOSTSAFETY_ROOT_PREFIX="${RP}" HOSTSAFETY_TMP_USED_BYTES=0 bash "${HS}/root-steps.sh" --apply >/dev/null 2>&1
PC_EO="/usr/bin/earlyoom $(sed -n 's/^EARLYOOM_ARGS="\(.*\)"$/\1/p' "${RP}/etc/default/earlyoom")"; export PC_EO
cat >"${pcs}/systemctl" <<'S'
#!/usr/bin/env bash
# fake: show answers from the installed drop-in unless PC_OVERRIDE=<unit>:<Key>:<value>; is-enabled from PC_DISABLED
[[ "$1" == "--user" ]] && shift
case "$1" in
  show) unit="$2"; key="$4"
        if [[ "${PC_OVERRIDE:-}" == "${unit}:${key}:"* ]]; then echo "${PC_OVERRIDE##*:}"; exit 0; fi
        sed -n "s/^${key}=//p" "${PC_CFG}/systemd/user/${unit}.d/10-hostsafety.conf" 2>/dev/null | head -1 ;;
  is-enabled) if [[ " ${PC_DISABLED:-} " == *" $2 "* ]]; then echo disabled; exit 1; fi; echo enabled ;;
  is-active) echo active ;;
  *) exit 0 ;;
esac
S
printf '#!/usr/bin/env bash\necho "${PC_LINGER:-yes}"\n' >"${pcs}/loginctl"
chmod +x "${pcs}/systemctl" "${pcs}/loginctl"
printf '{"schema": "hostsafety.pressure/1", "ts_epoch": 1000.5}\n' >"${pc}/state/hostsafety/pressure.json"
PCSCRIPT="${HS}/persistence-check.sh"
pcrun() { env PATH="${pcs}:${PATH}" PC_CFG="${pc}/c" HOSTSAFETY_CONFIG_HOME="${pc}/c" HOSTSAFETY_DATA_HOME="${pc}/d" HOSTSAFETY_BIN_DIR="${pc}/b" \
  HOSTSAFETY_STATE_HOME="${pc}/state" HOSTSAFETY_SOURCE_DIR="${HS}" HOSTSAFETY_ROOT_PREFIX="${RP}" HOSTSAFETY_MEMINFO="${TEST_TMP}/meminfo16" \
  LIVE_TMP_OPTIONS='rw,nosuid,nodev,size=4194304k,nr_inodes=1048576,inode64,usrquota' LIVE_EARLYOOM="${PC_EO}" LIVE_EARLYOOM_ENABLED=enabled \
  LIVE_USER_SLICE="MemoryHigh=$((16777216 * 1024 * 90 / 100)) MemoryMax=infinity TasksMax=40000" \
  HOSTSAFETY_NOW="${PC_NOW:-1010}" HOSTSAFETY_BOOT_EPOCH="${PC_BOOT:-900}" HOSTSAFETY_BOOT_ID=fixture-boot-1 HOSTSAFETY_BOOTCHECK_WAIT_S=0 \
  bash "${PCSCRIPT}" "$@" 2>&1; }
pcv() { local out; out="$(pcrun "$@"; echo "rc=$?")"; printf '%s' "${out}"; }
ok_out="$(pcv --json "${pc}/pc.json")"
assert_contains "${ok_out}" "persistence: 29 PASS 0 FAIL 0 UNDETERMINED" "every setting persistent and in effect: 29 rows PASS (23 user + 6 root)"
assert_contains "${ok_out}" "rc=0" "verify-persistence rc 0 when everything persists"
for want in "app.slice MemorySwapMax" "hostsafety-guard.timer" "hostsafety-selfcheck.service" "linger" "guard.env" "installed guard.py" "installed bounded-run" "pressure advisory" "root: tmp.mount size" "root: earlyoom enabled" "root: vm.swappiness"; do
  assert_contains "${ok_out}" "$(printf 'ROW\t%s\tPASS' "${want}")" "persistence row present and PASS: ${want}"
done
assert_eq "29" "$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["rows"]) if d["schema"]=="hostsafety.bootcheck/1" and d["boot_id"]=="fixture-boot-1" else -1)' "${pc}/pc.json")" "--json writes every row with schema and boot id"
# named negatives: each one must turn its own row FAIL (rc 1)
case_fail() { # <label> <row> <env...>
  local label="$1" rowname="$2"; shift 2
  local out; out="$(env "$@" bash -c "$(declare -f pcrun pcv); PCSCRIPT='${PCSCRIPT}'; pc='${pc}'; pcs='${pcs}'; RP='${RP}'; HS='${HS}'; TEST_TMP='${TEST_TMP}'; PC_EO='${PC_EO}'; pcv")"
  assert_contains "${out}" "$(printf 'ROW\t%s\tFAIL' "${rowname}")" "${label}: row '${rowname}' FAILs"
  assert_contains "${out}" "rc=1" "${label}: verify-persistence rc 1"
}
case_fail "guard timer not enabled (would not start at boot)" "hostsafety-guard.timer" PC_DISABLED=hostsafety-guard.timer
case_fail "self-check unit not enabled" "hostsafety-selfcheck.service" PC_DISABLED=hostsafety-selfcheck.service
case_fail "runtime-only value drifted from the persistent one (systemctl set-property --runtime)" "app.slice MemorySwapMax" PC_OVERRIDE=app.slice:MemorySwapMax:1073741824
case_fail "linger off: user units wait for a login" "linger" PC_LINGER=no
case_fail "pressure advisory stale (guard dead or timing out)" "pressure advisory" PC_NOW=2000
mv "${pc}/c/systemd/user/app.slice.d/10-hostsafety.conf" "${pc}/app.bak"
assert_contains "$(pcv)" "$(printf 'ROW\tapp.slice MemoryHigh\tFAIL')" "drop-in removed: the app.slice rows FAIL (no persistent definition)"
mv "${pc}/app.bak" "${pc}/c/systemd/user/app.slice.d/10-hostsafety.conf"
printf '\n# drift\n' >>"${pc}/d/hostsafety/guard.py"
assert_contains "$(pcv)" "$(printf 'ROW\tinstalled guard.py\tFAIL')" "installed guard.py differs from the source tree: FAIL"
cp "${HS}/guard.py" "${pc}/d/hostsafety/guard.py"
rm -f "${RP}/etc/systemd/system/tmp.mount.d/50-hostsafety.conf"
assert_contains "$(pcv)" "$(printf 'ROW\troot: tmp.mount size\tFAIL')" "root drop-in removed: the root tmp.mount row FAILs"
HOSTSAFETY_ROOT_PREFIX="${RP}" HOSTSAFETY_TMP_USED_BYTES=0 bash "${HS}/root-steps.sh" --apply >/dev/null 2>&1
assert_contains "$(PC_BOOT=1001 pcv)" "$(printf 'ROW\tpressure advisory\tUNDETERMINED')" "pressure.json from a previous boot: UNDETERMINED, never PASS"
bc="$(pcv --boot-check)"
assert_contains "${bc}" "hostsafety: boot-check 29 PASS 0 FAIL 0 UNDETERMINED" "--boot-check logs the one-line journal summary"
assert_file_exists "${pc}/state/hostsafety/boot-check.json" "--boot-check writes boot-check.json"
# mutation proofs: a neutered check in a scratch copy must flip its named case
mutate_pc() { # <label> <old> <new> <env for the case> <row>
  local mp="${TEST_TMP}/pcm.sh" out
  OLD="$2" python3 -I -c 'import os,sys; print(open(sys.argv[1]).read().count(os.environ["OLD"]))' "${HS}/persistence-check.sh" | grep -qx 1 \
    || { echo "  FAIL: mutation [$1]: text not found exactly once" >&2; TEST_FAILS=$((TEST_FAILS+1)); return; }
  OLD="$2" NEW="$3" python3 -I -c 'import os,sys; s=open(sys.argv[1]).read(); open(sys.argv[2],"w").write(s.replace(os.environ["OLD"], os.environ["NEW"]))' "${HS}/persistence-check.sh" "${mp}"
  out="$(env $4 bash -c "$(declare -f pcrun pcv); PCSCRIPT='${mp}'; pc='${pc}'; pcs='${pcs}'; RP='${RP}'; HS='${HS}'; TEST_TMP='${TEST_TMP}'; PC_EO='${PC_EO}'; pcv")"
  assert_eq "no" "$(grep -qF "$(printf 'ROW\t%s\tFAIL' "$5")" <<<"${out}" && echo yes || echo no)" "mutation [$1] is CAUGHT: the named case no longer FAILs '$5' on the mutant"
}
mutate_pc "m25 is-enabled check neutered" 'elif [[ "${en}" != enabled ]]; then row "${u}" FAIL' 'elif false; then row "${u}" FAIL' PC_DISABLED=hostsafety-guard.timer hostsafety-guard.timer
mutate_pc "m26 runtime-vs-boot drift check removed" 'elif [[ "${lv}" != "${bv}" ]]; then' 'elif false; then' PC_OVERRIDE=app.slice:MemorySwapMax:1073741824 "app.slice MemorySwapMax"
printf '\n# drift\n' >>"${pc}/d/hostsafety/guard.py"
mutate_pc "m27 installed-copy sha256 compare removed" 'elif [[ "${is}" != "${ss}" ]]; then' 'elif false; then' PC_UNUSED=1 "installed guard.py"
cp "${HS}/guard.py" "${pc}/d/hostsafety/guard.py"
mutate_pc "m28 linger check neutered" 'if [[ "${lg}" == yes ]]; then' 'if true; then' PC_LINGER=no "linger"

# --- 3. guard: victim selection on synthetic /proc ----------------------------------------
UID_ME=1000
P0=4200000   # all fixture pids/pgids > kernel pid_max
mkproc() { # root pid name uid ppid pgrp rss_kb swap_kb cgrel cmdline...
  local r="$1" pid="$2" name="$3" uid="$4" ppid="$5" pg="$6" rss="$7" swap="$8" cg="$9"; shift 9
  mkdir -p "${r}/${pid}"
  printf 'Name:\t%s\nUid:\t%s\t%s\t%s\t%s\nPPid:\t%s\nVmRSS:\t%s kB\nVmSwap:\t%s kB\n' "${name}" "${uid}" "${uid}" "${uid}" "${uid}" "${ppid}" "${rss}" "${swap}" >"${r}/${pid}/status"
  printf '%s (%s) S %s %s %s 0 0\n' "${pid}" "${name}" "${ppid}" "${pg}" "${pg}" >"${r}/${pid}/stat"
  printf '0::/user.slice/user-1000.slice/user@1000.service/%s\n' "${cg}" >"${r}/${pid}/cgroup"
  local c; : >"${r}/${pid}/cmdline"; for c in "$@"; do printf '%s\0' "${c}" >>"${r}/${pid}/cmdline"; done
}
select_json() { python3 -I "${GUARD}" --select-only --proc-root "$1" --uid "${UID_ME}" --self-pid "$((P0 + 900))"; }
jq_() { python3 -I -c 'import json,sys; d=json.load(sys.stdin); v=d["victim"]; print(eval(sys.argv[1]))' "$1"; }
mk_guard_ancestry() { # root
  mkproc "$1" $((P0+800)) bash "${UID_ME}" 1 $((P0+800)) 3000 0 "app.slice/tmx-x.scope" bash
  mkproc "$1" $((P0+900)) python3 "${UID_ME}" $((P0+800)) $((P0+800)) 20000 0 "app.slice/tmx-x.scope" python3 guard.py
}
mk_decoys() { # root: things bigger than any victim that must NEVER be chosen
  mkproc "$1" $((P0+100)) gnome-shell "${UID_ME}" 1 $((P0+100)) 9000000 0 "session.slice/org.gnome.Shell@ubuntu.service" /usr/bin/gnome-shell
  mkproc "$1" $((P0+101)) conmon "${UID_ME}" 1 $((P0+101)) 800000 0 "user.slice/libpod-abc.scope" conmon
  mkproc "$1" $((P0+102)) java "${UID_ME}" $((P0+101)) $((P0+101)) 9000000 0 "user.slice/libpod-abc.scope" java -jar big.jar
  mkproc "$1" $((P0+103)) memhog 4242 1 $((P0+103)) 9000000 0 "app.slice/foreign.scope" memhog
  mkproc "$1" $((P0+104)) "tmux: server" "${UID_ME}" 1 $((P0+104)) 9000000 0 "app.slice/tmx-llmctl.scope" tmux -L x
  mkproc "$1" $((P0+105)) claude "${UID_ME}" $((P0+104)) $((P0+104)) 9000000 0 "app.slice/tmx-llmctl.scope" claude --resume
  mkproc "$1" $((P0+106)) Xwayland "${UID_ME}" 1 $((P0+106)) 9000000 0 "app.slice/app-gnome-x.scope" Xwayland
  mkproc "$1" $((P0+107)) sshd-session "${UID_ME}" 1 $((P0+107)) 9000000 0 "app.slice/session-3.scope" sshd-session
  mkproc "$1" $((P0+108)) mystery "${UID_ME}" 1 $((P0+108)) 9000000 0 "init.scope" mystery
}

R="${TEST_TMP}/proc1"
mk_guard_ancestry "${R}"; mk_decoys "${R}"
# the runaway: recursive hook storm = 30 small processes in ONE group inside a test-runner scope
for i in $(seq 1 30); do mkproc "${R}" $((P0+5000+i)) git "${UID_ME}" $((P0+5000)) $((P0+5000)) 90000 0 "app.slice/bounded-run-x.scope" git commit; done
mkproc "${R}" $((P0+5000)) sh "${UID_ME}" 1 $((P0+5000)) 20000 0 "app.slice/bounded-run-x.scope" sh -c post-commit
sel="$(select_json "${R}")"
assert_eq "$((P0+5000))" "$(printf '%s' "${sel}" | jq_ 'v["pgrp"]')" "selects the runaway process group, not the bigger protected/foreign/infrastructure processes"
assert_eq "31" "$(printf '%s' "${sel}" | jq_ 'len(v["pids"])')" "victim group has all 31 members"
assert_eq "app.slice/bounded-run-x.scope" "$(printf '%s' "${sel}" | jq_ 'v["cgroup"]')" "victim cgroup reported as evidence"
assert_contains "${sel}" '"group-has-protected-process"' "evidence records why the tmux/claude group was skipped"
assert_contains "${sel}" '"not-owned"' "evidence records foreign-uid skips"
assert_contains "${sel}" '"cgroup-protected"' "evidence records protected-cgroup skips"

# a huge process whose pgid is 1 may only ever be a single-pid victim, never a group signal
R5="${TEST_TMP}/proc5"
mk_guard_ancestry "${R5}"; mk_decoys "${R5}"
mkproc "${R5}" $((P0+109)) hog "${UID_ME}" 1 1 9000000 0 "app.slice/pgid1.scope" hog
sel2="$(select_json "${R5}")"
assert_eq "process" "$(printf '%s' "${sel2}" | jq_ 'v["kind"]')" "pgid<=1 process can only be a single-pid victim"
assert_eq "None" "$(printf '%s' "${sel2}" | jq_ 'v["pgrp"]')" "pgid<=1 never becomes a group signal target"

# golden-FALSE carrier: a test runner whose ARGUMENTS merely mention protected names stays killable
R2="${TEST_TMP}/proc2"
mkproc "${R2}" $((P0+900)) python3 "${UID_ME}" 1 $((P0+900)) 20000 0 "app.slice/hostsafety-ctl.scope" python3 guard.py
mkproc "${R2}" $((P0+6000)) bash "${UID_ME}" 1 $((P0+6000)) 400000 0 "app.slice/run-u1.scope" bash -c "echo tmux gnome-shell claude podman conmon"
assert_eq "$((P0+6000))" "$(select_json "${R2}" | jq_ 'v["pgrp"]')" "carrier (argv mentions tmux/gnome-shell/claude) is NOT mistaken for the real thing"
# golden-TRUE counterpart: same shape but the process really is claude => protected
R3="${TEST_TMP}/proc3"
mkproc "${R3}" $((P0+900)) python3 "${UID_ME}" 1 $((P0+900)) 20000 0 "app.slice/hostsafety-ctl.scope" python3 guard.py
mkproc "${R3}" $((P0+6000)) claude "${UID_ME}" 1 $((P0+6000)) 400000 0 "app.slice/run-u1.scope" claude
assert_eq "None" "$(select_json "${R3}" | jq_ 'v')" "real claude process: nothing killable (fail-safe, no victim)"
# guard's own group / ancestors are never selected
R4="${TEST_TMP}/proc4"
mkproc "${R4}" $((P0+900)) python3 "${UID_ME}" 1 $((P0+900)) 900000 0 "app.slice/hostsafety-ctl.scope" python3 guard.py
assert_eq "None" "$(select_json "${R4}" | jq_ 'v')" "the guard never selects itself"
# test-only cgroup restriction knob only narrows
assert_eq "None" "$(HOSTSAFETY_ONLY_CGROUP_RE='nomatch$' select_json "${R2}" | jq_ 'v')" "HOSTSAFETY_ONLY_CGROUP_RE narrows (no match => no victim)"

# --- 4. guard: thresholds, sustained-pressure streak, dry-run default ----------------------
printf 'some avg10=5.00 avg60=1.00 avg300=0.50 total=1\nfull avg10=1.00 avg60=1.00 avg300=0.50 total=1\n' >"${TEST_TMP}/psi_ok"
printf 'some avg10=90.00 avg60=80.00 avg300=50.00 total=1\nfull avg10=98.00 avg60=70.00 avg300=50.00 total=1\n' >"${TEST_TMP}/psi_bad"
printf 'MemTotal: 32000000 kB\nSwapTotal: 8000000 kB\nSwapFree: 8000000 kB\n' >"${TEST_TMP}/mi_ok"
printf 'MemTotal: 32000000 kB\nSwapTotal: 8000000 kB\nSwapFree: 100000 kB\n' >"${TEST_TMP}/mi_swapfull"
run_guard() { # psi meminfo proc [arm]
  XDG_RUNTIME_DIR="${TEST_TMP}/xdg" HOSTSAFETY_GUARD_ARM="${4:-0}" python3 -I "${GUARD}" --psi-file "$1" --meminfo "$2" --proc-root "$3" \
    --uid "${UID_ME}" --self-pid "$((P0 + 900))" --log-file "${TEST_TMP}/glog/guard.log" --state-file "${TEST_TMP}/guard.state" >/dev/null
}
mkdir -p "${TEST_TMP}/xdg" "${TEST_TMP}/glog"; : >"${TEST_TMP}/glog/guard.log"
run_guard "${TEST_TMP}/psi_ok" "${TEST_TMP}/mi_ok" "${R2}"
assert_eq "0" "$(wc -l <"${TEST_TMP}/glog/guard.log")" "healthy host: no decision logged, nothing selected"
assert_file_contains "${TEST_TMP}/glog/guard.status" '"triggered": false' "heartbeat status written on a healthy run (a silent guard must be distinguishable from a dead one)"
# tmpfs_used_pct: heartbeat metric + report-only event above 60% (no kill, once per crossing)
printf 'MemTotal: 16777216 kB\nSwapTotal: 8388608 kB\nSwapFree: 8388608 kB\n' >"${TEST_TMP}/mi_t"
printf 'some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' >"${TEST_TMP}/psi_t"
gt() { XDG_RUNTIME_DIR="${TEST_TMP}/xdg_t" python3 -I "${GUARD}" --psi-file "${TEST_TMP}/psi_t" --meminfo "${TEST_TMP}/mi_t" --log-file "${TEST_TMP}/tlog/guard.log" --state-file "${TEST_TMP}/t.state" --tmp-dir "${TEST_TMP}/tmpdir_t" --tmpfs-used-pct-fixture "$1"; }
mkdir -p "${TEST_TMP}/xdg_t" "${TEST_TMP}/tlog" "${TEST_TMP}/tmpdir_t"
gt 10 >/dev/null
assert_file_contains "${TEST_TMP}/tlog/guard.status" '"tmpfs_used_pct": 10.0' "heartbeat carries tmpfs_used_pct"
assert_file_contains "${TEST_TMP}/tlog/pressure.json" '"schema": "hostsafety.pressure/1"' "pressure advisory written beside the log on every pass (agent admission control reads it)"
assert_eq "0" "$(cat "${TEST_TMP}/tlog/guard.log" 2>/dev/null | grep -c tmpfs-high || true)" "no tmpfs-high event at 10% /tmp"
gt 75 >/dev/null; gt 80 >/dev/null
assert_eq "1" "$(grep -c tmpfs-high "${TEST_TMP}/tlog/guard.log")" "tmpfs-high logged once per crossing (75% then 80% = one event)"
assert_contains "$(grep tmpfs-high "${TEST_TMP}/tlog/guard.log")" 'report only' "tmpfs-high is report-only (no kill)"
gt 20 >/dev/null; gt 90 >/dev/null
assert_eq "2" "$(grep -c tmpfs-high "${TEST_TMP}/tlog/guard.log")" "a new crossing after recovery logs again"
assert_eq "0" "$(grep -c '"event": "kill"' "${TEST_TMP}/tlog/guard.log" || true)" "tmpfs pressure never kills anything"
assert_rc 0 "real /tmp statvfs path runs (no fixture)" env XDG_RUNTIME_DIR="${TEST_TMP}/xdg_t" python3 -I "${GUARD}" --psi-file "${TEST_TMP}/psi_t" --meminfo "${TEST_TMP}/mi_t" --log-file "${TEST_TMP}/tlog2/guard.log" --state-file "${TEST_TMP}/t2.state"
assert_file_contains "${TEST_TMP}/tlog2/guard.status" '"tmpfs_used_pct"' "real statvfs value present in heartbeat"
run_guard "${TEST_TMP}/psi_bad" "${TEST_TMP}/mi_ok" "${R2}"
assert_contains "$(tail -1 "${TEST_TMP}/glog/guard.log")" '"event": "pressure-building"' "first high-PSI run only builds the streak"
run_guard "${TEST_TMP}/psi_bad" "${TEST_TMP}/mi_ok" "${R2}"
last="$(tail -1 "${TEST_TMP}/glog/guard.log")"
assert_contains "${last}" '"event": "would-kill"' "second consecutive run decides (DRY-RUN by default)"
assert_contains "${last}" '"armed": false' "dry-run flag recorded"
assert_contains "${last}" "$((P0+6000))" "decision names the victim with evidence"
assert_contains "${last}" 'psi_full_avg10=98.00' "decision records the trigger reason"
# swap exhaustion alone is not an emergency (golden-FALSE); swap exhaustion + memory stalls is
printf 'some avg10=1.00 avg60=1.00 avg300=0.50 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=1\n' >"${TEST_TMP}/psi_calm"
rm -f "${TEST_TMP}/guard.state"; : >"${TEST_TMP}/glog/guard.log"
run_guard "${TEST_TMP}/psi_calm" "${TEST_TMP}/mi_swapfull" "${R2}"; run_guard "${TEST_TMP}/psi_calm" "${TEST_TMP}/mi_swapfull" "${R2}"
assert_eq "0" "$(wc -l <"${TEST_TMP}/glog/guard.log")" "swap nearly full but no memory stall: no action (golden-FALSE)"
printf 'some avg10=40.00 avg60=1.00 avg300=0.50 total=1\nfull avg10=2.00 avg60=0.00 avg300=0.00 total=1\n' >"${TEST_TMP}/psi_swap"
run_guard "${TEST_TMP}/psi_swap" "${TEST_TMP}/mi_swapfull" "${R2}"; run_guard "${TEST_TMP}/psi_swap" "${TEST_TMP}/mi_swapfull" "${R2}"
assert_contains "$(tail -1 "${TEST_TMP}/glog/guard.log")" 'swap_free=' "swap exhausted + memory stalls triggers"
# armed against a fixture victim: re-validation against the REAL /proc finds nothing => no signal sent
rm -f "${TEST_TMP}/guard.state"; : >"${TEST_TMP}/glog/guard.log"
run_guard "${TEST_TMP}/psi_bad" "${TEST_TMP}/mi_ok" "${R2}" 1; run_guard "${TEST_TMP}/psi_bad" "${TEST_TMP}/mi_ok" "${R2}" 1
assert_contains "$(tail -1 "${TEST_TMP}/glog/guard.log")" 'refused-fixture-proc-root' "armed guard with a fixture --proc-root refuses to signal (a fixture pid is never a real pid)"
rm -f "${TEST_TMP}/guard.state"; : >"${TEST_TMP}/glog/guard.log"
export HOSTSAFETY_TEST_ALLOW_FIXTURE_PROC=1
run_guard "${TEST_TMP}/psi_bad" "${TEST_TMP}/mi_ok" "${R2}" 1; run_guard "${TEST_TMP}/psi_bad" "${TEST_TMP}/mi_ok" "${R2}" 1
unset HOSTSAFETY_TEST_ALLOW_FIXTURE_PROC
assert_contains "$(tail -1 "${TEST_TMP}/glog/guard.log")" 'revalidation-failed' "with the explicit test hook the armed kill path re-validates against the fixture proc root (fixture has no starttimes: signal withheld; pids above pid_max anyway)"

# --- 4b. guard: fixture suite (T1 storm-in-claude's-group, kill-path re-validation, pgid reuse) + mutation proof ----
fx_out="$(python3 -I "${FIX}" "${GUARD}" 2>&1)" && fx_rc=0 || fx_rc=$?
assert_eq "0" "${fx_rc}" "guard fixture suite passes on the real guard.py ($(printf '%s\n' "${fx_out}" | grep -c '^ok:') fixtures)"
[[ "${fx_rc}" -eq 0 ]] || printf '%s\n' "${fx_out}" | grep '^FAIL' >&2
assert_contains "${fx_out}" "ok: T1 a storm sharing claude's group never loses to an idle 5 MB group" "T1: 40x200MB git in claude's pgid + idle 5 MB pane shell => the 5 MB group is NOT selected"
# mutation proof: each mutation of guard.py (applied to a scratch copy) must make a NAMED fixture fail.
# mutate <label> <expected failing fixture prefix> <old text> <new text>
# The fixture suite runs once per mutant; mutants run 4 at a time (each in its own scratch files) and are judged in
# mutate_collect, so the suite stays inside its bounded-run timeout.
MUT_N=0; MUT_LABELS=(); MUT_WANTS=()
mutate() {
  local label="$1" want="$2" old="$3" new="$4" cnt mg
  MUT_N=$((MUT_N + 1)); mg="${TEST_TMP}/mut_guard_${MUT_N}.py"
  cnt="$(OLD="${old}" python3 -I -c 'import os,sys; print(open(sys.argv[1]).read().count(os.environ["OLD"]))' "${GUARD}")"
  assert_eq "1" "${cnt}" "mutation [${label}]: the text to mutate occurs exactly once in guard.py (the mutation is real)"
  OLD="${old}" NEW="${new}" python3 -I -c 'import os,sys; s=open(sys.argv[1]).read(); open(sys.argv[2],"w").write(s.replace(os.environ["OLD"], os.environ["NEW"]))' "${GUARD}" "${mg}"
  MUT_LABELS+=("${label}"); MUT_WANTS+=("${want}")
  while (( $(jobs -rp | wc -l) >= 4 )); do wait -n || true; done
  ( rc=0; python3 -I "${FIX}" "${mg}" >"${mg}.out" 2>&1 || rc=$?; echo "${rc}" >"${mg}.rc" ) &
}
mutate_collect() {
  local i out rc
  wait || true
  for (( i = 1; i <= MUT_N; i++ )); do
    out="$(cat "${TEST_TMP}/mut_guard_${i}.py.out" 2>/dev/null)"; rc="$(cat "${TEST_TMP}/mut_guard_${i}.py.rc" 2>/dev/null || echo 0)"
    assert_eq "yes" "$([[ ${rc} -ne 0 && "${out}" == *"FAIL: ${MUT_WANTS[i-1]}"* ]] && echo yes || echo no)" "mutation [${MUT_LABELS[i-1]}] is CAUGHT by fixture ${MUT_WANTS[i-1]}"
  done
}
mutate "A pgid<=1 check removed" "A " 'if pgrp is None or pgrp <= 1:' 'if False:'
mutate "B cgroup-protected check removed (group spans a protected cgroup)" "B2" 'if PROTECTED_CG.search(cg):
        return "cgroup-protected"' 'if False:
        return "cgroup-protected"'
mutate "C own-process-group check removed" "C " 'elif pgrp == own_pgrp:' 'elif False:'
mutate "D foreign-owner check removed" "D " 'if p["uid"] != my_uid:
        return "not-owned"' 'if False:
        return "not-owned"'
mutate "E re-validation removed from the kill path" "E " 'why = ineligible_reason(p, my_uid, protect)' 'why = None'
mutate "F pid-set identity check removed (pgid reuse by a new group)" "F " 'p["pid"] not in want or want[p["pid"]] is None or p.get("start") != want[p["pid"]]' 'p.get("start") != want.get(p["pid"], p.get("start"))'
mutate "F2 start-time identity check removed (restarted member)" "F2" 'p.get("start") != want[p["pid"]]' 'False'
mutate "I cgroup allowlist removed" "I " 'if not cg.startswith(KILLABLE_PREFIX):' 'if False:'
mutate "J self/ancestor check removed (single and group)" "J " 'if p["pid"] <= 1 or p["pid"] in protect_pids:' 'if p["pid"] <= 1:'
mutate "protected-name check removed" "S3" 'return bool(PROTECTED_COMM.match(p["name"]))' 'return False'
mutate "argv[0] basename protection reintroduced (spoof)" "S2" 'return bool(PROTECTED_COMM.match(p["name"]))' 'return bool(PROTECTED_COMM.match(p["name"]) or (p["cmd"] and PROTECTED_COMM.match(os.path.basename(p["cmd"][0]))))'
mutate "dominance rule removed (T1b)" "T1b" 'if dom and dom["storm_kb"] > DOMINANCE * best_cost and' 'if False and'
mutate "protected cgroup regex made imprecise again ([^/]*gnome[^/]*)" "S4" 'app-gnome-shell[^/]*|gnome-shell[^/]*' '[^/]*gnome[^/]*|gnome-shell[^/]*'
mutate "m10 storm victim accepted without the cost-fraction check" "TS8" 'if pv is None or sv["cost_kb"] >= frac * pv["cost_kb"]:' 'if True:'
mutate "m11 rotation shifts/deletes archives before the new one is written" "R7" '    tmp = "%s.1.gz.%d.tmp" % (path, os.getpid())
    try:' '    tmp = "%s.1.gz.%d.tmp" % (path, os.getpid())
    for i in range(keep, 0, -1):
        _s = "%s.%d.gz" % (path, i)
        if os.path.exists(_s):
            os.unlink(_s)
    try:'
mutate "m12 storm loop stops at the first rejected scope" "TS11" '                rejected.append({"cgroup": sg["cg"], "storm_cost_kb": sv["cost_kb"], "psi_cost_kb": pv["cost_kb"], "min_cost_frac": frac})' '                rejected.append({"cgroup": sg["cg"], "storm_cost_kb": sv["cost_kb"], "psi_cost_kb": pv["cost_kb"], "min_cost_frac": frac}); break'
mutate "m13 archive verified by length only" "R9" '        if not _same_content(tmp, path):' '        if os.path.getsize(path) > 0 and False:'
mutate "m15 pressure advisory never written" "PA1" '    write_json_atomic(pressure_path, adv)' '    (lambda *x: None)(pressure_path, adv)'
mutate "m16 app.slice ratio counts reclaimable page cache (current/high instead of pinned)" "PA4b" '    ratio = pinned_ratio if basis == "pinned" else cur_ratio' '    ratio = cur_ratio'
mutate "m17 critical tmpfs threshold never reached (warn only)" "PA2" '    elif tmpp >= th["crit_tmpfs_pct"]:' '    elif tmpp >= th["crit_tmpfs_pct"] * 10:'
mutate "m18 du scan not skipped when PSI is already critical" "TW2" '            if psi_ok and full10 >= cfg("ADV_CRIT_PSI_FULL", env):' '            if False:'
mutate "m19 du scan has no time cap" "TW3" '            txt, _ = p.communicate(timeout=max(0.0, deadline - time.monotonic()))' '            txt, _ = p.communicate(timeout=60)'
mutate "m20 /proc walk deadline ignored" "SD1" '        if deadline is not None and i % 32 == 0 and time.monotonic() > deadline:' '        if False:'
mutate "m21 advisory not written before the decision walk (ordering)" "PA7" '    write_json_atomic(pressure_path, adv)' '    write_json_atomic(pressure_path, adv) if not why else None'
mutate "m23 counter delta allowed to go negative (recreated cgroup)" "PA8c" '    if prev is None or cur is None or cur < prev:' '    if prev is None or cur is None:'
mutate "m24 time series never appended" "PA9" '    append_series(os.path.join(' '    (lambda *x: None)(os.path.join('
mutate "m14 no rotation flock" "R10" '            fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:' '            pass
        except OSError:'
mutate_collect

# --- 5. podman audit (fake podman) ---------------------------------------------------------
cat >"${TEST_TMP}/fakepodman" <<'FP'
#!/usr/bin/env bash
case "$1" in
  ps) printf 'id1\nid2\nid3\n' ;;
  inspect) printf 'web|running|1073741824\ndb|running|0\ncache|running|2147483648\n' ;;
esac
FP
chmod +x "${TEST_TMP}/fakepodman"
aud="$(HOSTSAFETY_PODMAN="${TEST_TMP}/fakepodman" HOSTSAFETY_MEMINFO="${TEST_TMP}/meminfo16" "${HS}/podman-audit.sh")"
assert_contains "${aud}" "db" "audit lists containers"
assert_contains "${aud}" "UNLIMITED" "audit flags the container without a memory limit"
assert_contains "${aud}" "without memory limit: 1" "audit counts unlimited containers"
assert_contains "${aud}" "sum of memory limits: 3.0G vs MemTotal 16G" "audit sums limits vs MemTotal"
assert_eq "no" "$(grep -qE 'podman (update|stop|kill|rm|run)|PODMAN.* (update|stop|kill|rm|run) ' "${HS}/podman-audit.sh" && echo yes || echo no)" "audit is report-only (no mutating podman verb)"

# --- 6. tracker exclusion (fake gsettings) -------------------------------------------------
cat >"${TEST_TMP}/fakegs" <<'FG'
#!/usr/bin/env bash
f="${FAKEGS_STATE}"
case "$1" in
  list-keys) [[ "${FAKEGS_NOKEY:-0}" == 1 ]] || echo ignored-directories ;;
  get) cat "${f}" ;;
  set) printf '%s\n' "$4" >"${f}" ;;
esac
FG
chmod +x "${TEST_TMP}/fakegs"
export FAKEGS_STATE="${TEST_TMP}/gs.state"; echo "['po', 'CVS']" >"${FAKEGS_STATE}"
mkdir -p "${TEST_TMP}/gomod"
tr_env() { HOSTSAFETY_GSETTINGS="${TEST_TMP}/fakegs" HOSTSAFETY_DATA_HOME="${TEST_TMP}/trd" HOSTSAFETY_GOMOD="${TEST_TMP}/gomod" "$@"; }
tr_env "${HS}/tracker-exclude.sh" --dry-run >/dev/null
assert_eq "['po', 'CVS']" "$(cat "${FAKEGS_STATE}")" "tracker dry-run changes nothing"
out="$(tr_env "${HS}/tracker-exclude.sh")"
assert_contains "${out}" "before ignored-directories = ['po', 'CVS']" "tracker shows the before value"
assert_contains "${out}" "'node_modules'" "tracker shows the after value"
assert_file_exists "${TEST_TMP}/gomod/.trackerignore" "go module cache excluded via .trackerignore marker"
assert_contains "$(tr_env "${HS}/tracker-exclude.sh")" "unchanged" "tracker apply is idempotent"
tr_env "${HS}/tracker-exclude.sh" --revert >/dev/null
assert_eq "['po', 'CVS']" "$(cat "${FAKEGS_STATE}")" "revert removes only the entries we added"
assert_eq "no" "$([[ -e ${TEST_TMP}/gomod/.trackerignore ]] && echo yes || echo no)" "revert removes the .trackerignore WE created"
# a .trackerignore that existed before (operator's own) must survive --revert
echo "['po', 'CVS']" >"${FAKEGS_STATE}"; mkdir -p "${TEST_TMP}/gomod2"; echo "# operator rule" >"${TEST_TMP}/gomod2/.trackerignore"
tr2() { HOSTSAFETY_GSETTINGS="${TEST_TMP}/fakegs" HOSTSAFETY_DATA_HOME="${TEST_TMP}/trd2" HOSTSAFETY_GOMOD="${TEST_TMP}/gomod2" "$@"; }
tr2 "${HS}/tracker-exclude.sh" >/dev/null; tr2 "${HS}/tracker-exclude.sh" --revert >/dev/null
assert_file_contains "${TEST_TMP}/gomod2/.trackerignore" "# operator rule" "revert keeps a pre-existing non-empty .trackerignore"
: >"${TEST_TMP}/gomod2/.trackerignore"; echo "['po', 'CVS']" >"${FAKEGS_STATE}"; rm -rf "${TEST_TMP}/trd2"
tr2 "${HS}/tracker-exclude.sh" >/dev/null; tr2 "${HS}/tracker-exclude.sh" --revert >/dev/null
assert_file_exists "${TEST_TMP}/gomod2/.trackerignore" "revert keeps a pre-existing EMPTY .trackerignore too (not created by us)"
echo "['po', 'CVS']" >"${FAKEGS_STATE}"
assert_contains "$(FAKEGS_NOKEY=1 tr_env "${HS}/tracker-exclude.sh")" "skipping" "absent gsettings key => skip, no change"

# --- 7. root-steps: plan is inert and shows the LIVE earlyoom; apply/revert on a re-rooted tree; earlyoom list proven ---
rs="$(LIVE_EARLYOOM='/usr/bin/earlyoom -r 3600' bash "${HS}/root-steps.sh")"
assert_contains "${rs}" "RateLimitBurst=2000" "root steps carry the journald rate-limit drop-in"
assert_contains "${rs}" "/etc/sysctl.d/90-hostsafety.conf" "root steps carry the swappiness sysctl"
assert_contains "${rs}" "running earlyoom command line RIGHT NOW" "plan mode reports what earlyoom is running right now"
assert_contains "${rs}" "/usr/bin/earlyoom -r 3600" "plan mode prints the live earlyoom command line"
if [[ "$(id -u)" -ne 0 ]]; then
  assert_rc 1 "root-steps --apply refuses to run as non-root" bash "${HS}/root-steps.sh" --apply
fi
RR="${TEST_TMP}/rootfs"; mkdir -p "${RR}/etc/default"
printf '# package default\nEARLYOOM_ARGS="-r 3600"\n' >"${RR}/etc/default/earlyoom"; cp -p "${RR}/etc/default/earlyoom" "${TEST_TMP}/earlyoom.orig"
rsr() { HOSTSAFETY_ROOT_PREFIX="${RR}" bash "${HS}/root-steps.sh" "$@"; }
rsr --apply >/dev/null
UF="${RR}/etc/systemd/system/user-1000.slice.d/50-hostsafety.conf"
assert_file_contains "${UF}" "MemoryHigh=90%" "user-1000.slice keeps the MemoryHigh throttle"
assert_file_contains "${UF}" "TasksMax=40000" "user-1000.slice keeps the task cap"
assert_eq "0" "$(grep -c '^MemoryMax' "${UF}" || true)" "user-1000.slice has NO MemoryMax (a parent-level hard limit could OOM-kill gnome-shell)"
EF="${RR}/etc/default/earlyoom"
assert_file_contains "${EF}" "--ignore " "earlyoom config uses --ignore (hard exclusion)"
assert_eq "0" "$(grep -c -- '--avoid' "${EF}" || true)" "earlyoom config does not rely on the soft --avoid"
assert_eq "0" "$(grep -c "never pick the desktop" "${HS}/root-steps.sh" || true)" "the false 'never pick the desktop' comment is gone"
assert_file_exists "${RR}/var/backups/hostsafety/orig/etc/default/earlyoom" "the pre-hostsafety earlyoom file was kept as THE original"
rsr --apply >/dev/null                                           # second apply: our own file must not become 'the original'
rsr --revert >/dev/null
assert_eq "yes" "$(cmp -s "${EF}" "${TEST_TMP}/earlyoom.orig" && echo yes || echo no)" "--revert restores the backed-up /etc/default/earlyoom (does not delete it)"
assert_eq "no" "$([[ -e ${UF} ]] && echo yes || echo no)" "--revert removes files that had no original"
# --- 7a. root-steps: /tmp tmpfs size (tmp.mount drop-in), earlyoom thresholds, legacy files, --verify (2026-10-14) ---
RT="${TEST_TMP}/rootfs_tmp"; mkdir -p "${RT}/usr/lib/systemd/system" "${RT}/etc/default" "${RT}/proc/sys/vm"
# the vendor unit exactly as shipped on anton (systemd 259, /usr/lib/systemd/system/tmp.mount)
cat >"${RT}/usr/lib/systemd/system/tmp.mount" <<'U'
[Unit]
Description=Temporary Directory /tmp
ConditionPathIsSymbolicLink=!/tmp
[Mount]
What=tmpfs
Where=/tmp
Type=tmpfs
Options=mode=1777,strictatime,nosuid,nodev,size=50%%,nr_inodes=1m,x-systemd.graceful-option=usrquota
U
printf '# package default\nEARLYOOM_ARGS="-r 3600"\n' >"${RT}/etc/default/earlyoom"
echo 60 >"${RT}/proc/sys/vm/swappiness"
printf 'MemTotal:       31717516 kB\nSwapTotal:       8388604 kB\n' >"${TEST_TMP}/meminfo_anton"
# legacy (2026-10-09, pre-marker) hostsafety files exactly as found on anton
mkdir -p "${RT}/etc/sysctl.d" "${RT}/etc/systemd/system/user-1000.slice.d"
printf '# hostsafety: prefer reclaiming page cache over swapping anonymous memory.\nvm.swappiness = 20\n' >"${RT}/etc/sysctl.d/90-hostsafety.conf"
printf '# hostsafety: last-resort ceiling for everything user 1000 runs (31 GB host).\n[Slice]\nMemoryHigh=90%%\nMemoryMax=95%%\nTasksMax=40000\n' >"${RT}/etc/systemd/system/user-1000.slice.d/50-hostsafety.conf"
LIVE_ANTON='rw,nosuid,nodev,size=15858760k,nr_inodes=1048576,inode64,usrquota'
rst() { HOSTSAFETY_ROOT_PREFIX="${RT}" HOSTSAFETY_MEMINFO="${TEST_TMP}/meminfo_anton" LIVE_TMP_OPTIONS="${LIVE_TMP_OPTIONS:-${LIVE_ANTON}}" \
  LIVE_EARLYOOM="${LIVE_EARLYOOM:-/usr/bin/earlyoom -r 3600}" LIVE_EARLYOOM_ENABLED="${LIVE_EARLYOOM_ENABLED:-enabled}" \
  LIVE_USER_SLICE="${LIVE_USER_SLICE:-MemoryHigh=29230862336 MemoryMax=30854799360 TasksMax=40000}" bash "${HS}/root-steps.sh" "$@"; }
pl="$(rst 2>&1)"
TD=/etc/systemd/system/tmp.mount.d/50-hostsafety.conf
assert_contains "${pl}" "=== would write ${TD} ===" "plan writes the PERSISTENT tmp.mount drop-in"
assert_contains "${pl}" "Options=mode=1777,strictatime,nosuid,nodev,size=4G,nr_inodes=1m,x-systemd.graceful-option=usrquota" "drop-in keeps every vendor option and changes only size= (4G)"
assert_contains "${pl}" "tmp.mount boot-effective size=50% (16239368192 bytes); live size=15858760k (16239370240 bytes)" "plan shows the BOOT-effective value next to the LIVE value"
assert_contains "${pl}" "-m 10,5 -s 100,100" "earlyoom thresholds: SIGTERM at 10% / SIGKILL at 5% available, swap condition always true (100,100)"
# the remount decision (live part only; the persistent drop-in is written regardless)
assert_contains "$(HOSTSAFETY_TMP_USED_BYTES=1073741824 rst 2>&1)" "live: would remount /tmp to size=4G (used 1073741824 < 3221225472 bytes)" "plan: small /tmp => live remount planned"
big="$(HOSTSAFETY_TMP_USED_BYTES=3500000000 rst 2>&1)"
assert_contains "${big}" "REFUSED live remount: /tmp holds 3500000000 bytes >= 3221225472" "plan: big /tmp => live remount refused with a clear message"
assert_contains "${big}" "nothing is truncated or deleted" "refusal says nothing is deleted"
assert_rc 2 "HOSTSAFETY_TMP_SIZE garbage is refused" env HOSTSAFETY_TMP_SIZE='4G,mode=0777' HOSTSAFETY_ROOT_PREFIX="${RT}" bash "${HS}/root-steps.sh"
assert_rc 2 "HOSTSAFETY_EARLYOOM_THRESHOLDS with anything but -m/-s/-M/-S numbers is refused" env HOSTSAFETY_EARLYOOM_THRESHOLDS='-m 5 --ignore x' HOSTSAFETY_ROOT_PREFIX="${RT}" bash "${HS}/root-steps.sh"
assert_contains "$(HOSTSAFETY_EARLYOOM_THRESHOLDS='-m 5 -s 10' rst 2>&1)" 'EARLYOOM_ARGS="-r 60 -m 5 -s 10 ' "HOSTSAFETY_EARLYOOM_THRESHOLDS selects the previous design (-m 5 -s 10)"
# --verify BEFORE apply: the drop-in is missing, the legacy user-1000 file still has MemoryMax => FAIL rows, rc 1
vb="$(rst --verify 2>&1; echo "rc=$?")"
assert_contains "${vb}" "rc=1" "--verify before apply fails (rc 1)"
assert_contains "${vb}" "$(printf 'ROW\ttmp.mount size\tFAIL')" "--verify: tmp.mount size row FAILs without the persistent drop-in"
assert_contains "${vb}" "$(printf 'ROW\tearlyoom args\tFAIL')" "--verify: earlyoom args row FAILs with the package default"
assert_contains "${vb}" "$(printf 'ROW\tuser-1000.slice\tFAIL')" "--verify: user-1000.slice row FAILs while the legacy MemoryMax=95% is in place"
assert_contains "${vb}" "$(printf 'ROW\tvm.swappiness\tFAIL')" "--verify: swappiness row FAILs when live (60) differs from the boot value (20)"
HOSTSAFETY_TMP_USED_BYTES=1073741824 rst --apply >"${TEST_TMP}/rst_apply.out" 2>&1
assert_file_contains "${RT}${TD}" "# hostsafety-managed" "apply wrote the tmp.mount drop-in with the marker"
assert_contains "$(cat "${TEST_TMP}/rst_apply.out")" "live: remount /tmp size=4G skipped (test root)" "apply: live remount is decided (and only simulated under a test root)"
assert_eq "no" "$([[ -e ${RT}/var/backups/hostsafety/orig/etc/sysctl.d/90-hostsafety.conf ]] && echo yes || echo no)" "a legacy (2026-10-09, unmarked) hostsafety file is recognised as ours, never saved as 'the original'"
assert_file_exists "${RT}/var/backups/hostsafety/orig/etc/default/earlyoom" "the package-default earlyoom file IS saved as the original"
assert_file_exists "$(find "${RT}/var/backups/hostsafety" -path '*2*/etc/sysctl.d/90-hostsafety.conf' | head -1)" "the legacy file still gets a timestamped backup copy"
# --verify AFTER apply with live == boot (simulated): every row PASS, rc 0
echo 20 >"${RT}/proc/sys/vm/swappiness"
EO_NOW="/usr/bin/earlyoom $(sed -n 's/^EARLYOOM_ARGS="\(.*\)"$/\1/p' "${RT}/etc/default/earlyoom")"
va="$(LIVE_TMP_OPTIONS='rw,nosuid,nodev,size=4194304k,nr_inodes=1048576,inode64,usrquota' LIVE_EARLYOOM="${EO_NOW}" \
      LIVE_USER_SLICE='MemoryHigh=29230862336 MemoryMax=infinity TasksMax=40000' rst --verify 2>&1; echo "rc=$?")"
assert_contains "${va}" "rc=0" "--verify after apply with matching live values passes (rc 0)"
assert_eq "0" "$(grep -c "$(printf '\t')FAIL$(printf '\t')" <<<"${va}" || true)" "--verify after apply: no FAIL row"
# drift: persistent says 4G, the live mount is still 16 GB (remount refused / not done) => FAIL naming the drift
vd="$(LIVE_EARLYOOM="${EO_NOW}" LIVE_USER_SLICE='MemoryHigh=29230862336 MemoryMax=infinity TasksMax=40000' rst --verify 2>&1; echo "rc=$?")"
assert_contains "${vd}" "DRIFT live size=15858760k" "--verify flags runtime-vs-boot DRIFT on /tmp (a boot would apply 4G, the live mount is 16 GB)"
assert_contains "${vd}" "rc=1" "--verify with drift fails"
# runtime-only earlyoom (file says new args, process still runs the old ones) => FAIL
vr="$(LIVE_TMP_OPTIONS='rw,nosuid,nodev,size=4194304k,nr_inodes=1048576,inode64,usrquota' LIVE_USER_SLICE='MemoryHigh=29230862336 MemoryMax=infinity TasksMax=40000' rst --verify 2>&1; echo "rc=$?")"
assert_contains "${vr}" "$(printf 'ROW\tearlyoom args\tFAIL')" "--verify: running earlyoom args differ from the persistent file => FAIL (restart needed)"
# earlyoom not enabled => it would not start at boot => FAIL
ve="$(LIVE_EARLYOOM_ENABLED=disabled LIVE_TMP_OPTIONS='rw,nosuid,nodev,size=4194304k,nr_inodes=1048576,inode64,usrquota' LIVE_EARLYOOM="${EO_NOW}" LIVE_USER_SLICE='MemoryHigh=29230862336 MemoryMax=infinity TasksMax=40000' rst --verify 2>&1; echo "rc=$?")"
assert_contains "${ve}" "$(printf 'ROW\tearlyoom enabled\tFAIL')" "--verify: earlyoom not enabled => FAIL (would not start at the next boot)"
# a later drop-in overriding ours changes the BOOT value: the parser must see it (precedence = lexical basename order)
printf '[Mount]\nOptions=mode=1777,size=12G\n' >"${RT}/etc/systemd/system/tmp.mount.d/90-operator.conf"
vo="$(LIVE_TMP_OPTIONS='rw,nosuid,nodev,size=4194304k,nr_inodes=1048576,inode64,usrquota' LIVE_EARLYOOM="${EO_NOW}" LIVE_USER_SLICE='MemoryHigh=29230862336 MemoryMax=infinity TasksMax=40000' rst --verify 2>&1; echo "rc=$?")"
assert_contains "${vo}" "boot size=12G" "--verify: a later drop-in (90-operator.conf) wins at boot and is reported"
assert_contains "${vo}" "$(printf 'ROW\ttmp.mount size\tFAIL')" "--verify: boot value differs from the hostsafety size => FAIL"
rm -f "${RT}/etc/systemd/system/tmp.mount.d/90-operator.conf"
assert_rc 2 "--verify with an unreadable live /tmp option string is UNDETERMINED (rc 2), never a pass" env HOSTSAFETY_ROOT_PREFIX="${RT}" HOSTSAFETY_MEMINFO="${TEST_TMP}/meminfo_anton" \
  LIVE_TMP_OPTIONS='garbage' LIVE_EARLYOOM="${EO_NOW}" LIVE_EARLYOOM_ENABLED=enabled LIVE_USER_SLICE='MemoryHigh=29230862336 MemoryMax=infinity TasksMax=40000' bash "${HS}/root-steps.sh" --verify
# LIVE_* fakes are honoured ONLY under a test root: in production they must not be able to make --verify pass
assert_contains "$(LIVE_TMP_OPTIONS='rw,size=4194304k' bash "${HS}/root-steps.sh" --verify 2>&1)" "tmp.mount size" "--verify runs without root (production paths) and prints the tmp.mount row"
assert_eq "0" "$(LIVE_TMP_OPTIONS='rw,size=4194304k' bash "${HS}/root-steps.sh" --verify 2>&1 | grep -c 'live size=4194304k' || true)" "production --verify ignores LIVE_TMP_OPTIONS (a gate cannot be faked by env)"
rst --revert >"${TEST_TMP}/rst_revert.out" 2>&1
assert_eq "no" "$([[ -e ${RT}${TD} ]] && echo yes || echo no)" "--revert removes the tmp.mount drop-in"
assert_contains "$(cat "${TEST_TMP}/rst_revert.out")" "live: remount /tmp size=50% skipped (test root)" "--revert restores the live size from the boot definition that remains (vendor 50%)"
assert_eq "no" "$([[ -e ${RT}/etc/sysctl.d/90-hostsafety.conf ]] && echo yes || echo no)" "--revert removes the legacy hostsafety file too (there was no pre-hostsafety original)"
assert_eq "yes" "$(grep -q 'EARLYOOM_ARGS="-r 3600"' "${RT}/etc/default/earlyoom" && echo yes || echo no)" "--revert restores the package-default earlyoom file"

# earlyoom proven against the real binary + systemd's own EnvironmentFile/$EARLYOOM_ARGS expansion
if command -v earlyoom >/dev/null 2>&1 && command -v systemd-run >/dev/null 2>&1 && systemctl --user show -p Version >/dev/null 2>&1; then
  rsr --apply >/dev/null; cp "${EF}" "${TEST_TMP}/eo.env"
  cat >"${TEST_TMP}/decoy.py" <<'PY'
import ctypes, sys, time
name, adj, pidfile = sys.argv[1], sys.argv[2], sys.argv[3]
ctypes.CDLL(None).prctl(15, name.encode(), 0, 0, 0)           # PR_SET_NAME: the kernel comm earlyoom matches on
open("/proc/self/oom_score_adj", "w").write(adj)               # raising is unprivileged: make it the top candidate unless ignored
ballast = b"\x01" * (int(sys.argv[4]) << 20) if len(sys.argv) > 4 else b""   # touched pages = real RSS (not calloc zero pages)
open(pidfile, "a").write("%s\t%d\n" % (name, __import__("os").getpid()))
time.sleep(14)
PY
  # Decoy RSS ladder, all at oom_score_adj 1000 (earlyoom breaks an oom_score tie by RSS):
  #   protected comms 40 MiB  >  bash 20 MiB  >  needle + git 0 MiB.
  # So a protected decoy is the biggest candidate and is skipped ONLY because of --ignore; bash beats git ONLY until the
  # --prefer +300 bonus is applied.  Each property has a paired mutation run below (regex stripped => verdict flips).
  # eo_run.sh <envfile> <out> <pidfile>
  cat >"${TEST_TMP}/eo_run.sh" <<EOS
T="${TEST_TMP}"; ENVF="\$1"; OUT="\$2"; PIDS="\$3"
: >"\${PIDS}"
python3 -I "\${T}/decoy.py" gnome-terminal- 1000 "\${PIDS}" & sleep 0.3        # control needle: NOT protected, must be a candidate
for n in "tmux: server" sshd-session gnome-shell gnome-session-c claude conmon Xwayland systemd "(sd-pam)" dbus-daemon pipewire; do
  python3 -I "\${T}/decoy.py" "\$n" 1000 "\${PIDS}" 40 &
done
python3 -I "\${T}/decoy.py" bash 1000 "\${PIDS}" 20 &
python3 -I "\${T}/decoy.py" git 1000 "\${PIDS}" &
sleep 1.5
systemd-run --user --pipe --wait -q -p EnvironmentFile="\${ENVF}" -p TasksMax=50 -p MemoryMax=512M \
  timeout 3 /usr/bin/earlyoom '\$EARLYOOM_ARGS' --dryrun -d -r 0 -m 99 -s 99 >"\${OUT}" 2>&1
wait
EOS
  eo_run() { timeout 60 systemd-run --user --scope -q -p TasksMax=100 -p MemoryMax=1G bash "${TEST_TMP}/eo_run.sh" "$@" >/dev/null 2>&1 || true; }
  # earlyoom's VERDICT is its "sending <sig> to process <pid>" line, printed once per COMPLETED scan.  The "<--- new victim"
  # lines are only the running maximum DURING a scan (ascending pid order); `timeout 3` kills earlyoom mid-scan, so the
  # LAST of them can belong to a truncated scan that never reached the high-pid decoys (the 2026-10-09 make-validate
  # flake: "actual" was an unrelated adj-200 host process).  Victims are therefore read only from verdict lines.
  verdicts() { awk '/^sending .* to process [0-9]+ /{for(i=1;i<=NF;i++) if($i=="process"){print $(i+1); break}}' "$1" | sort -u; }
  pid_of() { awk -F'\t' -v n="$1" '$1==n {print $2}' "${2:-${TEST_TMP}/decoy.pids}"; }
  # earlyoom sees EVERY host process.  The verdict is only about the decoys if every non-decoy process scored below the
  # weakest decoy (the needle) in earlyoom's own table of a COMPLETED scan; otherwise the run cannot tell prefer/ignore
  # apart from host load, and the dependent assertions SKIP with the intruding rows as evidence (never a false PASS/FAIL).
  intruders() { # <eo.out> <pidfile>: table rows of the last completed scan from NON-decoy pids scoring >= the needle
    awk -v needle="$(pid_of gnome-terminal- "$2")" 'FNR==NR {split($0, a, "\t"); mine[a[2]] = 1; next}
      /^ *PID +OOM_SCORE/ {n = 0; next}
      /^selecting victim took/ {m = n; for (i = 1; i <= n; i++) keep[i] = buf[i]; next}
      /^ *[0-9]+ +-?[0-9]+ / {buf[++n] = $0}
      END {for (i = 1; i <= m; i++) {split(keep[i], f, " "); if (f[1] == needle) floor = f[2] + 0}
           if (floor == "") {print "NO-NEEDLE-ROW (needle not scored in a completed scan)"; exit}
           for (i = 1; i <= m; i++) {split(keep[i], f, " "); if (!(f[1] in mine) && f[2] + 0 >= floor) print keep[i]}}' "$2" "$1"; }
  eo_case() { # <label> <envfile> <out> <pidfile>: run; rc 0 = decoys dominate the host (assertions apply), rc 1 = SKIP logged
    eo_run "$2" "$3" "$4"
    local intr; intr="$(intruders "$3" "$4")"
    if [[ -n "${intr}" ]]; then assert_skip "host process(es) outrank the decoys: $(head -3 <<<"${intr}" | tr -s ' ' | tr '\n' ';')" "$1"; return 1; fi
    assert_eq "yes" "$([[ -n "$(verdicts "$3")" ]] && echo yes || echo no)" "$1: earlyoom completed a scan and printed a verdict (the verdict instrument can see)"
  }
  eo_case "earlyoom real config" "${TEST_TMP}/eo.env" "${TEST_TMP}/eo.out" "${TEST_TMP}/decoy.pids" && dominated=1 || dominated=0
  assert_eq "yes" "$([[ -n "$(pid_of git)" && -n "$(pid_of gnome-terminal-)" ]] && echo yes || echo no)" "earlyoom test: decoys started"
  assert_contains "$(cat "${TEST_TMP}/eo.out")" "Will ignore process names that match regex '^(systemd" "earlyoom parsed the --ignore regex through systemd's EnvironmentFile"
  assert_contains "$(cat "${TEST_TMP}/eo.out")" "Preferring to kill process names that match regex '^(git" "earlyoom parsed the --prefer regex"
  # thresholds through systemd's own EnvironmentFile/$EARLYOOM_ARGS expansion (earlyoom prints its parsed limits at start)
  eo_limits() { timeout 30 systemd-run --user --pipe --wait -q -p EnvironmentFile="$1" -p TasksMax=20 -p MemoryMax=256M \
    timeout 2 /usr/bin/earlyoom '$EARLYOOM_ARGS' --dryrun 2>&1 | grep -E 'when mem avail' || true; }
  lim_out="$(eo_limits "${TEST_TMP}/eo.env")"
  assert_contains "${lim_out}" "sending SIGTERM when mem avail <= 10.00% and swap free <= 100.00%" "earlyoom (real binary, systemd expansion): SIGTERM at 10% available, swap condition always true"
  assert_contains "${lim_out}" "SIGKILL when mem avail <=  5.00% and swap free <= 100.00%" "earlyoom: SIGKILL at 5% available, swap condition always true (needs -s 100,100)"
  # paired mutation: '-s 100' without the kill value => earlyoom halves it for SIGKILL (50%), so SIGKILL would need swap <= 50% free
  sed 's/-s 100,100/-s 100/' "${TEST_TMP}/eo.env" >"${TEST_TMP}/eo_s100.env"
  assert_contains "$(eo_limits "${TEST_TMP}/eo_s100.env")" "SIGKILL when mem avail <=  5.00% and swap free <= 50.00%" "mutation [-s 100 without ,100] is CAUGHT: the SIGKILL swap condition becomes 50%, not always true"
  if [[ ${dominated} -eq 1 ]]; then
    vict="$(awk '/<--- new victim/ {print $1}' "${TEST_TMP}/eo.out" | sort -u)"
    leaked=""
    for n in "tmux: server" sshd-session gnome-shell gnome-session-c claude conmon Xwayland systemd "(sd-pam)" dbus-daemon pipewire; do
      pp="$(pid_of "${n}")"; [[ -n "${pp}" ]] && grep -qx "${pp}" <<<"${vict}" && leaked="${leaked} ${n}"
    done
    assert_eq "" "${leaked}" "no protected comm (tmux: server, sshd-session, gnome-shell, gnome-session-c, claude, conmon, Xwayland, systemd, (sd-pam), dbus, pipewire) is ever an earlyoom victim, even at oom_score_adj 1000 and the largest RSS"
    assert_eq "yes" "$(grep -qx "$(pid_of gnome-terminal-)" <<<"${vict}" && echo yes || echo no)" "control needle: an UNPROTECTED comm (gnome-terminal-) with the same score IS a candidate (the instrument can see)"
    assert_eq "$(pid_of git)" "$(verdicts "${TEST_TMP}/eo.out")" "--prefer: git beats a BIGGER bash at equal oom_score_adj (verdict of every completed scan)"
  fi
  # paired mutation 1: --prefer stripped => bash (bigger RSS) must be the verdict, not git
  sed 's/ --prefer [^"]*//' "${TEST_TMP}/eo.env" >"${TEST_TMP}/eo_noprefer.env"
  assert_eq "0" "$(grep -c -- '--prefer' "${TEST_TMP}/eo_noprefer.env" || true)" "mutation [no --prefer]: the env file really lost its --prefer regex"
  if eo_case "mutation [no --prefer]" "${TEST_TMP}/eo_noprefer.env" "${TEST_TMP}/eo_np.out" "${TEST_TMP}/decoy_np.pids"; then
    assert_eq "$(pid_of bash "${TEST_TMP}/decoy_np.pids")" "$(verdicts "${TEST_TMP}/eo_np.out")" "mutation [no --prefer] is CAUGHT: without the regex the bigger bash decoy is the verdict, not git"
  fi
  # paired mutation 2: --ignore AND --prefer stripped => a protected decoy (largest RSS) must be the verdict and must show
  # up as a "new victim" - proves the protected comms above lose ONLY because of --ignore (and the leak check can see).
  sed -e 's/ --ignore ^[^ "]*//' -e 's/ --prefer [^"]*//' "${TEST_TMP}/eo.env" >"${TEST_TMP}/eo_noignore.env"
  assert_eq "0" "$(grep -c -e '--ignore ^' -e '--prefer' "${TEST_TMP}/eo_noignore.env" || true)" "mutation [no --ignore]: the env file really lost its --ignore (and --prefer) regex"
  if eo_case "mutation [no --ignore]" "${TEST_TMP}/eo_noignore.env" "${TEST_TMP}/eo_ni.out" "${TEST_TMP}/decoy_ni.pids"; then
    vni="$(verdicts "${TEST_TMP}/eo_ni.out")"
    prot="$(awk -F'\t' '$1!="gnome-terminal-" && $1!="bash" && $1!="git" {print $2}' "${TEST_TMP}/decoy_ni.pids")"
    assert_eq "yes" "$([[ -n "${vni}" ]] && ! grep -vxF -f <(printf '%s\n' "${prot}") <<<"${vni}" >/dev/null && echo yes || echo no)" "mutation [no --ignore] is CAUGHT: without the regex a protected decoy is the verdict (verdict=${vni//$'\n'/,})"
    vni_new="$(awk '/<--- new victim/ {print $1}' "${TEST_TMP}/eo_ni.out")"
    assert_eq "yes" "$(grep -qxF -f <(printf '%s\n' "${prot}") <<<"${vni_new}" && echo yes || echo no)" "mutation [no --ignore]: the leak instrument (new-victim lines) sees a protected decoy"
  fi
else
  assert_skip "earlyoom or a systemd --user manager is not available" "earlyoom ignore/prefer list against the real binary"
fi

# --- 8. LIVE containment: bounded-run vs a fork-bomb-like fixture, inside a tiny scope -----
if ! command -v systemd-run >/dev/null 2>&1 || ! systemctl --user show -p Version >/dev/null 2>&1; then
  assert_skip "no usable systemd --user manager" "live containment tests"
else
  BR="${HS}/bounded-run"
  export HOSTSAFETY_LIB="${HS}/lib.sh"
  mark="hs$$x${RANDOM}"
  count_procs() { # count live processes whose cmdline matches an ERE (fixed marker, no pgrep self-match: we read /proc directly)
    local n=0 p c
    for p in /proc/[0-9]*; do
      c="$({ tr '\0' ' ' <"${p}/cmdline"; } 2>/dev/null || true)"
      [[ "${c}" =~ $1 ]] && [[ "${c}" != *"count_procs"* ]] && n=$((n + 1))
    done
    echo "${n}"
  }
  # fixture: try to spawn 400 sleeping children (capped!); count successes; report peak pids of its own cgroup
  cat >"${TEST_TMP}/bomb.py" <<'PY'
import subprocess, sys, time
mark = sys.argv[1]; kids = []; fails = 0; peak = 0
cg = open("/proc/self/cgroup").read().split("::")[1].strip()
pidsf = "/sys/fs/cgroup" + cg + "/pids.current"
for i in range(400):
    try:
        kids.append(subprocess.Popen(["hsmark-" + mark, "300"], executable="/usr/bin/sleep"))
    except OSError:
        fails += 1
    try:
        peak = max(peak, int(open(pidsf).read()))
    except OSError:
        pass
print("spawned=%d failed=%d peak=%d" % (len(kids), fails, peak), flush=True)
time.sleep(1)   # leave the children running: bounded-run must reap them
PY
  start=$SECONDS
  res="$("${BR}" -q --tiny -m 256M -t 100 -T 60 -n "hsbomb$$" -- python3 -I "${TEST_TMP}/bomb.py" "${mark}" 2>&1)"
  took=$((SECONDS - start))
  printf '  evidence: %s (wall %ss)\n' "${res}" "${took}"
  spawned="$(printf '%s' "${res}" | sed -n 's/.*spawned=\([0-9]*\).*/\1/p')"
  failed="$(printf '%s' "${res}" | sed -n 's/.*failed=\([0-9]*\).*/\1/p')"
  peak="$(printf '%s' "${res}" | sed -n 's/.*peak=\([0-9]*\).*/\1/p')"
  assert_eq "yes" "$([[ ${spawned:-0} -gt 0 && ${spawned:-0} -lt 400 ]] && echo yes || echo no)" "fork-bomb fixture was stopped short of 400 children (spawned=${spawned:-?})"
  assert_eq "yes" "$([[ ${failed:-0} -gt 0 ]] && echo yes || echo no)" "kernel refused forks (EAGAIN) once TasksMax=100 was hit (failed=${failed:-?})"
  assert_eq "yes" "$([[ ${peak:-999} -le 100 ]] && echo yes || echo no)" "scope pids.current never exceeded TasksMax=100 (peak=${peak:-?})"
  sleep 1
  assert_eq "0" "$(count_procs "^hsmark-${mark} 300")" "no fixture child survives the run (scope reaped)"
  st="$(systemctl --user is-active "bounded-run-hsbomb$$.scope" 2>&1 | head -1 || true)"
  assert_eq "yes" "$([[ "${st}" != active ]] && echo yes || echo no)" "scope is not active after the run (${st})"

  # wall-clock timeout => rc 124, scope terminated, fast (-T 2 vs a 6 s sleep: a broken watchdog shows as rc 0 after 6 s)
  start=$SECONDS; rc=0
  "${BR}" -q -T 2 -n "hsto$$" -- sleep 6 >/dev/null 2>&1 || rc=$?
  took=$((SECONDS - start))
  assert_eq "124" "${rc}" "timeout returns 124 (-T 2 -- sleep 6)"
  assert_eq "yes" "$([[ ${took} -le 4 ]] && echo yes || echo no)" "timeout enforced in ~2 s, long before the 6 s sleep ends (took ${took}s)"
  start=$SECONDS; rc=0
  "${BR}" -q -T 2 -n "hsto2$$" -- bash -c "(exec -a hsmarkb-${mark} sleep 300) & wait" >/dev/null 2>&1 || rc=$?
  took=$((SECONDS - start))
  assert_eq "124" "${rc}" "timeout returns 124 for a command tree"
  assert_eq "yes" "$([[ ${took} -le 5 ]] && echo yes || echo no)" "tree timeout enforced within seconds (took ${took}s)"
  sleep 1
  assert_eq "0" "$(count_procs "^hsmarkb-${mark} 300")" "timed-out command tree is gone"

  # name collision: a second run with the SAME -n must neither start nor touch the first run's scope
  cn="hscol$$"
  "${BR}" -q -T 15 -n "${cn}" -- bash -c "(exec -a hsmarkd-${mark} sleep 200) & wait" >/dev/null 2>&1 &
  colpid=$!
  for _ in $(seq 1 50); do systemctl --user is-active "bounded-run-${cn}.scope" >/dev/null 2>&1 && break; sleep 0.1; done
  rc=0; "${BR}" -q -n "${cn}" -- true >"${TEST_TMP}/col.out" 2>&1 || rc=$?
  assert_eq "125" "${rc}" "second run with an existing scope name is refused (rc 125)"
  assert_contains "$(cat "${TEST_TMP}/col.out")" "already exists" "the refusal says why"
  assert_eq "active" "$(systemctl --user is-active "bounded-run-${cn}.scope" 2>&1 | head -1)" "the first run's scope is still ACTIVE after the colliding run"
  assert_eq "1" "$(count_procs "^hsmarkd-${mark} 200")" "the first run's process is still alive after the colliding run"
  # the race path (precheck passes, systemd-run then loses): a systemctl shim hides the existing scope from the pre-check only
  mkdir -p "${TEST_TMP}/shim"
  cat >"${TEST_TMP}/shim/systemctl" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"show"*"LoadState"* ]]; then echo not-found; exit 0; fi
exec /usr/bin/systemctl "$@"
SH
  chmod +x "${TEST_TMP}/shim/systemctl"
  rc=0; PATH="${TEST_TMP}/shim:${PATH}" "${BR}" -q -T 1 -n "${cn}" -- sleep 3 >/dev/null 2>&1 || rc=$?
  assert_eq "yes" "$([[ ${rc} -ne 0 ]] && echo yes || echo no)" "a lost start race fails the loser (rc ${rc})"
  sleep 1.5   # past the loser's own -T 1 watchdog
  assert_eq "active" "$(systemctl --user is-active "bounded-run-${cn}.scope" 2>&1 | head -1)" "the loser's cleanup and timeout watchdog did NOT kill the winner's scope"
  assert_eq "1" "$(count_procs "^hsmarkd-${mark} 200")" "the winner's process survived the losing run"
  systemctl --user kill --signal=SIGKILL "bounded-run-${cn}.scope" 2>/dev/null; wait "${colpid}" 2>/dev/null || true

  # exit status passthrough + banner shows the computed limits
  rc=0; "${BR}" -q -- bash -c 'exit 7' >/dev/null 2>&1 || rc=$?
  assert_eq "7" "${rc}" "command exit status passes through"
  assert_contains "$("${BR}" --tiny -m 128M -t 33 -- true 2>&1)" "TasksMax=33" "banner reports effective limits"
  assert_rc 125 "no command => usage error 125" "${BR}"
  assert_rc 125 "bad memory size refused" "${BR}" -m banana -- true

  # --- 8b. GNOME "Application Stopped" root cause (docs/host-safety.md): tmpfs-backed /tmp inside a cgroup, tiny caps, no headroom
  # tiny caps are refused unless explicitly requested (ad-hoc 2G build caps are what OOM-killed git/zip)
  rc=0; out="$("${BR}" -q -m 512M -- true 2>&1)" || rc=$?
  assert_eq "125" "${rc}" "MemoryMax < 1 GiB without --tiny is refused (exit 125)"
  assert_contains "${out}" "--tiny" "the refusal tells the operator about --tiny"
  assert_rc 0 "MemoryMax < 1 GiB with --tiny is accepted" "${BR}" -q --tiny -m 512M -- true
  assert_rc 0 "MemoryMax = 1G is accepted without --tiny" "${BR}" -q -m 1G -- true
  # MemoryHigh sits meaningfully below MemoryMax (75%): pressure throttles/reclaims before any kill
  bn="$("${BR}" -m 4G -n "hshigh$$" -- true 2>&1)"
  assert_contains "${bn}" "MemoryMax=4G MemoryHigh=3221225472" "banner: MemoryHigh is 75% of MemoryMax (4G -> 3221225472)"
  # small cgroups may still swap a little (tmpfs/shmem is only reclaimable via swap): default SwapMax is not 0
  swp="$(printf '%s' "${bn}" | sed -n 's/.*SwapMax=\([0-9]*\).*/\1/p')"
  assert_eq "yes" "$([[ ${swp:-0} -gt 0 ]] && echo yes || echo no)" "default MemorySwapMax is non-zero (got ${swp:-?})"
  assert_eq "yes" "$([[ ${swp:-0} -le 2147483648 ]] && echo yes || echo no)" "default MemorySwapMax is capped at 2 GiB (1/4 of the swap device)"
  # TMPDIR: disk-backed per-run dir, 0700, exported (TMPDIR/TEMP/TMP/GOTMPDIR), removed on exit, opt-out available
  export BOUNDED_RUN_TMP_ROOT="${TEST_TMP}/brtmp"
  tout="$("${BR}" -q -m 1G -n "hstmp$$" -- bash -c 'echo "$TMPDIR|$TEMP|$TMP|$GOTMPDIR"; stat -c %a "$TMPDIR"; echo x >"$TMPDIR/probe"' 2>&1)"
  td="$(printf '%s\n' "${tout}" | sed -n 1p | cut -d'|' -f1)"
  assert_contains "${td}" "${TEST_TMP}/brtmp/" "TMPDIR defaults to a per-run dir under the disk-backed root (${td})"
  assert_eq "${td}|${td}|${td}|${td}" "$(printf '%s\n' "${tout}" | sed -n 1p)" "TMPDIR, TEMP, TMP and GOTMPDIR all point at the per-run dir"
  assert_eq "700" "$(printf '%s\n' "${tout}" | sed -n 2p)" "per-run TMPDIR is mode 0700"
  assert_eq "no" "$([[ -e ${td} ]] && echo yes || echo no)" "per-run TMPDIR (and its files) removed after a successful run"
  rc=0; tout="$("${BR}" -q -m 1G -n "hstmp2$$" -- bash -c 'echo "$TMPDIR"; echo x >"$TMPDIR/probe"; exit 3' 2>&1)" || rc=$?
  assert_eq "3" "${rc}" "exit status still passes through with TMPDIR handling"
  assert_eq "no" "$([[ -e $(printf '%s\n' "${tout}" | sed -n 1p) ]] && echo yes || echo no)" "per-run TMPDIR removed after a failing run"
  tout="$("${BR}" -q -m 1G --no-disk-tmp -n "hstmp3$$" -- bash -c 'echo "${TMPDIR:-unset}"' 2>&1)"
  assert_eq "yes" "$([[ ${tout} != *"${TEST_TMP}/brtmp"* ]] && echo yes || echo no)" "--no-disk-tmp leaves TMPDIR alone"
  # /tmp is RAM (and capped small by root-steps.sh): a tmpfs temp dir is announced with size and fullness, even with -q
  if [[ "$(stat -f -c %T /tmp)" == tmpfs ]]; then
    wout="$(TMPDIR=/tmp "${BR}" -q -m 1G --no-disk-tmp -n "hstmp4$$" -- true 2>&1)"
    assert_contains "${wout}" "WARNING: the command's temp dir /tmp is tmpfs (RAM): size " "--no-disk-tmp with TMPDIR on tmpfs warns with size and fullness (even with -q)"
    wout="$("${BR}" -q -m 1G -n "hstmp5$$" -- true 2>&1)"
    assert_eq "0" "$(grep -c 'is tmpfs (RAM)' <<<"${wout}" || true)" "the default disk-backed TMPDIR prints no tmpfs warning (golden-FALSE)"
  else
    assert_skip "/tmp is not tmpfs on this host" "bounded-run tmpfs temp-dir warning"
  fi
  unset BOUNDED_RUN_TMP_ROOT
  # the default root is on a real disk filesystem, NOT tmpfs (the whole point)
  dtout="$("${BR}" -q -m 1G -n "hstmp4$$" -- bash -c 'df --output=fstype "$TMPDIR" | tail -1' 2>&1)"
  assert_eq "yes" "$([[ -n ${dtout} && ${dtout} != tmpfs ]] && echo yes || echo no)" "default per-run TMPDIR is on a disk-backed filesystem (fstype=${dtout})"
  # the same 200 MB write that OOM-killed a 96M scope on tmpfs does NOT kill it on disk-backed TMPDIR (page cache is reclaimable)
  wout="$("${BR}" -q --tiny -m 96M -n "hsdisk$$" -- bash -c 'dd if=/dev/zero of="$TMPDIR/big" bs=1M count=200 status=none; echo wrote=$(stat -c %s "$TMPDIR/big")' 2>&1)"
  assert_contains "${wout}" "wrote=209715200" "200 MB written under a 96M cap with disk TMPDIR: no OOM kill"

  # armed guard end-to-end: real kill of a runaway group, restricted to ITS OWN test scope
  runm="hsrun$$"
  setsid "${BR}" -q --tiny -m 256M -t 100 -T 120 -n "${runm}" -- bash -c "(exec -a hsmarkc1-${mark} sleep 300) & (exec -a hsmarkc2-${mark} sleep 300) & wait" >/dev/null 2>&1 &
  for _ in $(seq 1 50); do
    systemctl --user is-active "bounded-run-${runm}.scope" >/dev/null 2>&1 && break; sleep 0.1
  done
  sleep 0.5
  assert_eq "2" "$(count_procs "^hsmarkc[12]-${mark} 300")" "runaway fixture is alive before the guard acts"
  g="$(XDG_RUNTIME_DIR="${TEST_TMP}/xdg" HOSTSAFETY_GUARD_ARM=1 HOSTSAFETY_CONSECUTIVE=1 HOSTSAFETY_ONLY_CGROUP_RE="bounded-run-${runm}\\.scope\$" \
    python3 -I "${GUARD}" --force-trigger --log-file "${TEST_TMP}/live/guard.log" --state-file "${TEST_TMP}/live.state")"
  assert_contains "${g}" '"event": "kill"' "armed guard kills the runaway test scope's group"
  assert_contains "${g}" "app.slice/bounded-run-${runm}.scope" "kill decision names the victim cgroup (evidence)"
  sleep 1
  assert_eq "0" "$(count_procs "^hsmarkc[12]-${mark} 300")" "victim processes are gone after the armed kill"
  wait 2>/dev/null || true
fi

# --- 8b. verify compares EFFECTIVE vs INSTALLED, tolerating MemTotal drift (fixture, real captured values) ---
# Root cause of the former live failure: the drop-ins were sized at install time from MemTotal=32478728192, and
# verify re-derived "wanted" from the CURRENT /proc/meminfo (kernel-reserved memory drifts a few kB between
# boots/hours) then demanded byte equality. systemd applied the installed values exactly (effective == drop-in);
# only the re-derivation moved. Values below are captured from the live host (2026-10-13).
vf="${TEST_TMP}/verify"; mkdir -p "${vf}/cfg/systemd/user" "${vf}/shim"
printf 'MemTotal:       31717516 kB\nSwapTotal:       8388608 kB\n' >"${vf}/meminfo_now"       # 32478736384 B (live, later)
for s_ in app background user; do mkdir -p "${vf}/cfg/systemd/user/${s_}.slice.d"; done
cat >"${vf}/cfg/systemd/user/app.slice.d/10-hostsafety.conf" <<'D'
[Slice]
MemoryHigh=22735109734
MemoryMax=25982982553
MemorySwapMax=4294967296
TasksMax=16384
D
# (app MemorySwapMax: SwapTotal/2 since 2026-10-14; the 2026-10-13 capture carried the old 1 GiB cap - see the stale check below)
cat >"${vf}/cfg/systemd/user/background.slice.d/10-hostsafety.conf" <<'D'
[Slice]
MemoryHigh=12991491276
MemoryMax=16239364096
MemorySwapMax=536870912
TasksMax=4096
D
cat >"${vf}/cfg/systemd/user/user.slice.d/10-hostsafety.conf" <<'D'
[Slice]
MemoryHigh=19487236915
MemoryMax=24359046144
MemorySwapMax=2147482624
TasksMax=8192
D
# fake systemctl: `show <unit> -p <Key> --value` answers from the drop-in (i.e. systemd applied exactly what was
# installed), unless VF_OVERRIDE="<unit>:<Key>:<value>" says otherwise; is-active/is-enabled answer fixed words.
cat >"${vf}/shim/systemctl" <<'S'
#!/usr/bin/env bash
[[ "$1" == "--user" ]] && shift
case "$1" in
  show) unit="$2"; key="$4"
        if [[ "${VF_OVERRIDE:-}" == "${unit}:${key}:"* ]]; then echo "${VF_OVERRIDE##*:}"; exit 0; fi
        sed -n "s/^${key}=//p" "${VF_CFG}/systemd/user/${unit}.d/10-hostsafety.conf" | head -1 ;;
  is-active) echo active ;;  is-enabled) echo enabled ;;  *) exit 0 ;;
esac
S
chmod +x "${vf}/shim/systemctl"
vrun() { ( unset HOSTSAFETY_NO_SYSTEMCTL; PATH="${vf}/shim:${PATH}" VF_CFG="${vf}/cfg" HOSTSAFETY_CONFIG_HOME="${vf}/cfg" \
  HOSTSAFETY_NPROC="${VF_NPROC:-16}" HOSTSAFETY_MEMINFO="${1}" VF_OVERRIDE="${2:-}" "${HS}/install.sh" verify ) 2>&1; }
vout="$(vrun "${vf}/meminfo_now"; echo "rc=$?")" || true
assert_contains "${vout}" "rc=0" "verify passes when effective == installed and MemTotal drifted by 8 kB since install"
assert_contains "${vout}" "verified   user.slice MemoryMax=24359046144" "verify reports the installed value as verified"
sed -i 's/^MemorySwapMax=4294967296$/MemorySwapMax=1073741824/' "${vf}/cfg/systemd/user/app.slice.d/10-hostsafety.conf"
vout="$(vrun "${vf}/meminfo_now"; echo "rc=$?")" || true
assert_contains "${vout}" "rc=1" "NEGATIVE: an install still carrying the pre-2026-10-14 1 GiB app swap cap is reported (verify fails)"
assert_contains "${vout}" "app.slice MemorySwapMax: installed 1073741824 is stale" "NEGATIVE: the old app swap cap is named stale, not silently accepted"
sed -i 's/^MemorySwapMax=1073741824$/MemorySwapMax=4294967296/' "${vf}/cfg/systemd/user/app.slice.d/10-hostsafety.conf"
vout="$(vrun "${vf}/meminfo_now" "user.slice:MemoryMax:24000000000"; echo "rc=$?")" || true
assert_contains "${vout}" "rc=1" "NEGATIVE: verify still fails when the effective limit differs from the installed one"
assert_contains "${vout}" "MISMATCH   user.slice MemoryMax" "NEGATIVE: the mismatch names the slice and key"
printf 'MemTotal:       16777216 kB\nSwapTotal:       8388608 kB\n' >"${vf}/meminfo_small"
vout="$(vrun "${vf}/meminfo_small"; echo "rc=$?")" || true
assert_contains "${vout}" "rc=1" "NEGATIVE: verify fails when the host was re-sized materially (stale drop-ins, 32 GiB -> 16 GiB)"
assert_contains "${vout}" "MemoryMax: installed 25982982553 is stale" "NEGATIVE: the stale-sizing failure names the key and says stale"
# hs_limits failing (unreadable / garbage MemTotal) used to leave the loop with zero lines: rc=0, nothing verified.
vout="$(vrun "${vf}/no_such_meminfo"; echo "rc=$?")" || true
assert_contains "${vout}" "rc=1" "NEGATIVE: unreadable meminfo => verify fails (nothing verified is not a pass)"
assert_contains "${vout}" "cannot derive expected limits" "NEGATIVE: unreadable meminfo names the cause"
[[ "${vout}" != *"verified   "* ]] && echo "  ok: nothing is reported verified when expected limits cannot be derived" || { echo "  FAIL: 'verified' printed without a comparison" >&2; TEST_FAILS=$((TEST_FAILS+1)); }
printf 'MemTotal:       garbage kB\nSwapTotal:       8388608 kB\n' >"${vf}/meminfo_garbage"
vout="$(vrun "${vf}/meminfo_garbage"; echo "rc=$?")" || true
assert_contains "${vout}" "rc=1" "NEGATIVE: garbage meminfo => verify fails"
assert_contains "${vout}" "cannot derive expected limits" "NEGATIVE: garbage meminfo names the cause"
# TasksMax-only staleness (CPU count changed 16 -> 32; memory unchanged)
vout="$(VF_NPROC=32 vrun "${vf}/meminfo_now"; echo "rc=$?")" || true
assert_contains "${vout}" "rc=1" "NEGATIVE: CPU count changed => verify fails on TasksMax alone"
assert_contains "${vout}" "app.slice TasksMax: installed 16384 is stale" "NEGATIVE: the TasksMax stale message names slice and key"
# non-numeric installed/effective value must be a clean MISMATCH, not an unbound-variable abort
cp "${vf}/cfg/systemd/user/background.slice.d/10-hostsafety.conf" "${vf}/bg.bak"
sed -i 's/^MemoryMax=.*/MemoryMax=infinity/' "${vf}/cfg/systemd/user/background.slice.d/10-hostsafety.conf"
vout="$(vrun "${vf}/meminfo_now"; echo "rc=$?")" || true
assert_contains "${vout}" "rc=1" "NEGATIVE: non-numeric limit (infinity) => verify fails"
assert_contains "${vout}" "background.slice MemoryMax: not a number (installed infinity, effective infinity)" "NEGATIVE: non-numeric limit is a clean MISMATCH"
[[ "${vout}" != *"unbound variable"* ]] && echo "  ok: no shell abort on a non-numeric limit" || { echo "  FAIL: unbound variable abort" >&2; TEST_FAILS=$((TEST_FAILS+1)); }
cp "${vf}/bg.bak" "${vf}/cfg/systemd/user/background.slice.d/10-hostsafety.conf"
rm -f "${vf}/cfg/systemd/user/app.slice.d/10-hostsafety.conf"
vout="$(vrun "${vf}/meminfo_now"; echo "rc=$?")" || true
assert_contains "${vout}" "rc=1" "NEGATIVE: verify fails when a drop-in is not installed"

# --- 9. live: installed limits actually applied (only when installed on this host) ---------
if [[ -f "${HOME}/.config/systemd/user/app.slice.d/10-hostsafety.conf" ]] && systemctl --user show app.slice -p MemoryMax >/dev/null 2>&1; then
  unset HOSTSAFETY_NO_SYSTEMCTL
  assert_rc 0 "installed slice limits are effective (install.sh verify)" "${HS}/install.sh" verify
fi

test_finish
