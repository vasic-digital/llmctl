#!/usr/bin/env bash
# persistence-check.sh - does every hostsafety setting SURVIVE A REBOOT?  Report only: it never changes, stops or signals
# anything.  One row per setting:
#   ROW <TAB> setting <TAB> PASS|FAIL|UNDETERMINED <TAB> persistent definition <TAB> boot-effective <TAB> live <TAB> enabled <TAB> note
# then "persistence: N PASS M FAIL K UNDETERMINED".  rc 0 all PASS, 1 any FAIL, 2 any UNDETERMINED (and no FAIL).
# A setting that is only live (runtime) and has no persistent twin, or whose live value differs from what a boot applies
# (DRIFT), is a FAIL.  Root-level rows come from root-steps.sh --verify (no root needed) and are prefixed "root: ".
#
#   persistence-check.sh [--json FILE] [--boot-check]
#     --json FILE    also write the rows as JSON (schema hostsafety.bootcheck/1), atomically
#     --boot-check   the boot self-check (hostsafety-selfcheck.service): waits up to HOSTSAFETY_BOOTCHECK_WAIT_S (45) for the
#                    guard's first pressure.json of this boot, writes $STATE/boot-check.json and logs one summary line
#
# Env (tests): HOSTSAFETY_CONFIG_HOME HOSTSAFETY_DATA_HOME HOSTSAFETY_BIN_DIR HOSTSAFETY_STATE_HOME HOSTSAFETY_SOURCE_DIR
# HOSTSAFETY_ROOT_PREFIX (passed to root-steps.sh) HOSTSAFETY_BOOT_EPOCH HOSTSAFETY_BOOT_ID HOSTSAFETY_NOW
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_HOME="${HOSTSAFETY_CONFIG_HOME:-${XDG_CONFIG_HOME:-${HOME}/.config}}"
DATA_HOME="${HOSTSAFETY_DATA_HOME:-${XDG_DATA_HOME:-${HOME}/.local/share}}"
BIN_DIR="${HOSTSAFETY_BIN_DIR:-${HOME}/.local/bin}"
STATE="${HOSTSAFETY_STATE_HOME:-${XDG_STATE_HOME:-${HOME}/.local/state}}/hostsafety"
SHARE="${DATA_HOME}/hostsafety"
UNIT_DIR="${CONFIG_HOME}/systemd/user"
SRC="${HOSTSAFETY_SOURCE_DIR:-$(cat "${SHARE}/source-dir" 2>/dev/null || true)}"
json="" boot=0
while (( $# )); do
  case "$1" in
    --json) json="${2:?--json needs a file}"; shift ;;
    --boot-check) boot=1 ;;
    *) echo "usage: $0 [--json FILE] [--boot-check]" >&2; exit 2 ;;
  esac
  shift
done
(( boot )) && [[ -z "${json}" ]] && json="${STATE}/boot-check.json"

ROWS=() NFAIL=0 NUND=0 NPASS=0
row() { # setting verdict persistent boot live enabled note
  ROWS+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5" "$6" "$7")")
  case "$2" in PASS) NPASS=$((NPASS + 1)) ;; FAIL) NFAIL=$((NFAIL + 1)) ;; *) NUND=$((NUND + 1)) ;; esac
  printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}
uctl() { systemctl --user "$@" 2>/dev/null; }

# boot value of <key> for user unit <unit>: drop-ins in file-name order over the user search path (~/.config wins a name)
user_boot_value() {
  local u="$1" k="$2" d f v=""
  declare -A seen=()
  for d in /usr/lib/systemd/user /etc/systemd/user "${UNIT_DIR}"; do
    for f in "${d}/${u}.d"/*.conf; do [[ -f "${f}" ]] && seen["$(basename "${f}")"]="${f}"; done
  done
  for f in $(printf '%s\n' "${!seen[@]}" | sort); do
    [[ -n "${f}" ]] || continue
    v="$(awk -v k="${k}" -v cur="${v}" 'BEGIN{val=cur} $0 ~ "^"k"=" {val=substr($0, length(k)+2)} END{print val}' "${seen[${f}]}")"
  done
  printf '%s' "${v}"
}

# 1. slice limits: persistent drop-in == boot value == live value
for s in app background user; do
  f="${UNIT_DIR}/${s}.slice.d/10-hostsafety.conf"
  for k in MemoryHigh MemoryMax MemorySwapMax TasksMax; do
    per="$(sed -n "s/^${k}=//p" "${f}" 2>/dev/null | tail -1)"
    bv="$(user_boot_value "${s}.slice" "${k}")"
    lv="$(uctl show "${s}.slice" -p "${k}" --value)"
    if [[ -z "${per}" ]]; then row "${s}.slice ${k}" FAIL "${f} missing/unset" "${bv:-unset}" "${lv:-?}" - "no persistent definition"
    elif [[ "${bv}" != "${per}" ]]; then row "${s}.slice ${k}" FAIL "10-hostsafety.conf ${k}=${per}" "${bv}" "${lv:-?}" - "a boot would apply another drop-in's value"
    elif [[ -z "${lv}" ]]; then row "${s}.slice ${k}" UNDETERMINED "10-hostsafety.conf ${k}=${per}" "${bv}" "?" - "systemctl --user show unreadable"
    elif [[ "${lv}" != "${bv}" ]]; then row "${s}.slice ${k}" FAIL "10-hostsafety.conf ${k}=${per}" "${bv}" "DRIFT ${lv}" - "runtime differs from what a boot applies"
    else row "${s}.slice ${k}" PASS "10-hostsafety.conf ${k}=${per}" "${bv}" "${lv}" - ""; fi
  done
done

# 2. units that must start at every boot
for u in hostsafety-guard.timer hostsafety-selfcheck.service; do
  en="$(uctl is-enabled "${u}")"; ac="$(uctl is-active "${u}")"
  if [[ ! -f "${UNIT_DIR}/${u}" ]]; then row "${u}" FAIL "${UNIT_DIR}/${u} missing" "-" "${ac:-?}" "${en:-?}" "unit file not installed"
  elif [[ -z "${en}" ]]; then row "${u}" UNDETERMINED "${u}" "?" "${ac:-?}" "?" "is-enabled unreadable"
  elif [[ "${en}" != enabled ]]; then row "${u}" FAIL "${u}" "does NOT start at boot" "${ac:-?}" "${en}" "systemctl --user enable ${u}"
  else row "${u}" PASS "${u}" "starts at boot" "${ac:-?}" "${en}" ""; fi
done

# 3. linger: without it the user manager (and every timer above) does not run until someone logs in
lg="$(loginctl show-user "${USER:-$(id -un)}" -p Linger --value 2>/dev/null || true)"
if [[ "${lg}" == yes ]]; then row "linger" PASS "loginctl Linger=yes" "user manager starts at boot" "yes" - ""
elif [[ -z "${lg}" ]]; then row "linger" UNDETERMINED "loginctl" "?" "?" - "loginctl unreadable"
else row "linger" FAIL "loginctl Linger=${lg}" "user units wait for a login" "${lg}" - "loginctl enable-linger (operator)"; fi

# 4. guard.env (operator config; the arming switch)
ge="${CONFIG_HOME}/hostsafety/guard.env"
if [[ -f "${ge}" ]]; then
  arm="$(sed -n 's/^HOSTSAFETY_GUARD_ARM=//p' "${ge}" | tail -1)"; mode="$(stat -c %a "${ge}")"
  if [[ "${mode}" != 600 ]]; then row "guard.env" FAIL "${ge} mode ${mode}" "ARM=${arm:-unset}" "-" - "must be 0600"
  else row "guard.env" PASS "${ge} (0600)" "ARM=${arm:-unset}" "$([[ ${arm} == 1 ]] && echo armed || echo dry-run)" - ""; fi
else row "guard.env" FAIL "${ge} missing" "-" "-" - "the guard unit reads it at every pass"; fi

# 5. installed copies == the source tree they were installed from (sha256)
for pair in "bounded-run:${BIN_DIR}/bounded-run" "agent-run:${BIN_DIR}/agent-run" "guard.py:${SHARE}/guard.py" "lib.sh:${SHARE}/lib.sh" \
            "root-steps.sh:${SHARE}/root-steps.sh" "persistence-check.sh:${SHARE}/persistence-check.sh"; do
  n="${pair%%:*}"; inst="${pair#*:}"
  is="$(sha256sum "${inst}" 2>/dev/null | cut -c1-12)"; ss="$(sha256sum "${SRC}/${n}" 2>/dev/null | cut -c1-12)"
  if [[ -z "${is}" ]]; then row "installed ${n}" FAIL "${inst} missing" "-" "-" - "re-run install.sh"
  elif [[ -z "${SRC}" || -z "${ss}" ]]; then row "installed ${n}" UNDETERMINED "${inst} ${is}" "-" "source ${SRC:-unknown}/${n} unreadable" - "cannot compare"
  elif [[ "${is}" != "${ss}" ]]; then row "installed ${n}" FAIL "${inst} ${is}" "-" "source ${ss}" - "installed copy differs from ${SRC}: re-run install.sh"
  else row "installed ${n}" PASS "${inst} ${is}" "-" "source ${ss}" - ""; fi
done

# 6. the pressure-advisory writer is alive (agent admission control reads pressure.json; older than 60 s = guard dead/timing out)
pj="${STATE}/pressure.json"
now="${HOSTSAFETY_NOW:-$(date +%s)}"
bt="${HOSTSAFETY_BOOT_EPOCH:-$(awk '/^btime/ {print $2}' /proc/stat 2>/dev/null)}"
pts() { python3 -I -c 'import json,sys
try:
    d=json.load(open(sys.argv[1])); print("%s %s" % (d.get("schema"), int(d.get("ts_epoch") or 0)))
except Exception:
    print("? 0")' "${pj}"; }
if (( boot )); then   # at boot the guard's first pass (timer OnBootSec=30s) may still be due: wait for one from THIS boot
  waited=0
  while (( waited < ${HOSTSAFETY_BOOTCHECK_WAIT_S:-45} )); do
    read -r _sch _ts <<<"$(pts)"; (( _ts >= ${bt:-0} )) && break
    sleep 1; waited=$((waited + 1)); now="$(date +%s)"
  done
fi
read -r sch ts <<<"$(pts)"
age=$(( now - ts ))
if [[ ! -f "${pj}" ]]; then row "pressure advisory" FAIL "${pj} missing" "written by every guard pass" "-" - "the guard has not run"
elif [[ "${sch}" != hostsafety.pressure/1 ]]; then row "pressure advisory" FAIL "${pj}" "-" "schema ${sch}" - "unreadable or wrong schema"
elif [[ -n "${bt}" ]] && (( ts < bt )); then row "pressure advisory" UNDETERMINED "${pj}" "guard timer" "from a previous boot" - "no guard pass yet in this boot"
elif (( age > 30 )); then row "pressure advisory" FAIL "${pj}" "guard timer" "stale ${age}s" - "older than 30 s: the guard is dead or timing out"
else row "pressure advisory" PASS "${pj}" "guard timer" "age ${age}s" - ""; fi

# 7. root-level settings (no root needed to read them)
rs="${here}/root-steps.sh"; [[ -f "${rs}" ]] || rs="${SHARE}/root-steps.sh"
if [[ -f "${rs}" ]]; then
  # rc must be 0/1/2 and exactly 6 rows must come back; an abort that drops rows is UNDETERMINED, never a silent pass.
  # Empty fields become "-" first: `IFS=$'\t' read` would collapse two adjacent tabs and shift the columns.
  rout="$(bash "${rs}" --verify 2>/dev/null)"; rrc=$?
  nrows=0
  while IFS=$'\t' read -r tag a b c d e f g; do
    [[ "${tag}" == ROW ]] || continue
    nrows=$((nrows + 1)); row "root: ${a}" "${b}" "${c}" "${d}" "${e}" "${f}" "${g}"
  done < <(awk -F'\t' -v OFS='\t' '{for (i = 1; i <= NF; i++) if ($i == "") $i = "-"; print}' <<<"${rout}")
  if (( rrc > 2 || nrows != 6 )); then
    row "root: root-steps.sh --verify" UNDETERMINED "${rs}" "-" "rc ${rrc}, ${nrows} of 6 rows" - "the root check aborted; its rows are incomplete"
  fi
else row "root: root-steps.sh" UNDETERMINED "root-steps.sh not found" "-" "-" - "cannot check root-level settings"; fi

summary="${NPASS} PASS ${NFAIL} FAIL ${NUND} UNDETERMINED"
echo "persistence: ${summary}"
if [[ -n "${json}" ]]; then
  bid="${HOSTSAFETY_BOOT_ID:-$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)}"
  mkdir -p "$(dirname "${json}")"
  printf '%s\n' "${ROWS[@]}" | python3 -I -c '
import json, os, sys, time
out, bid, npass, nfail, nund = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
keys = ("setting", "verdict", "persistent", "boot", "live", "enabled", "note")
rows = [dict(zip(keys, l.rstrip("\n").split("\t"))) for l in sys.stdin if l.strip()]
doc = {"schema": "hostsafety.bootcheck/1", "boot_id": bid, "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "ts_epoch": round(time.time(), 3),
       "pass": npass, "fail": nfail, "undetermined": nund, "rows": rows}
tmp = "%s.%d.tmp" % (out, os.getpid())
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(doc, f, indent=1, sort_keys=True); f.write("\n"); f.flush(); os.fsync(f.fileno())
os.replace(tmp, out)' "${json}" "${bid}" "${NPASS}" "${NFAIL}" "${NUND}"
fi
(( boot )) && echo "hostsafety: boot-check ${summary}"
(( NFAIL )) && exit 1
(( NUND )) && exit 2
exit 0
