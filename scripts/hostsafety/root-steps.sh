#!/usr/bin/env bash
# root-steps.sh - the ROOT-LEVEL half of the 2026-10-08 / 2026-10-14 hang remediation.
# NOT applied by the user-level installer.  Read it, then run as root:
#     sudo bash root-steps.sh            # prints what it would do + what is running NOW (default; no root needed)
#     sudo bash root-steps.sh --apply    # applies it, then prints the running earlyoom command line as a post-check
#     sudo bash root-steps.sh --revert   # removes what --apply created and restores the pre-hostsafety originals
#          bash root-steps.sh --verify   # no root needed: persistent / boot-effective / live / enabled per setting,
#                                        # one "ROW<TAB>setting<TAB>PASS|FAIL|UNDETERMINED<TAB>..." line each; rc 0/1/2
# PERSISTENT FIRST: every setting is a file a boot applies (drop-in, sysctl.d, /etc/default); the live application
# (daemon-reload, sysctl --system, restarts, the /tmp remount) only follows the file.  Every file is written atomically.
# The FIRST pre-existing copy of each file is kept under /var/backups/hostsafety/orig/ (never overwritten by later runs)
# and --revert restores it; later runs also keep a timestamped copy under /var/backups/hostsafety/<timestamp>/.  Files we
# wrote carry the marker line below; files written by the first (2026-10-09, pre-marker) version start with
# "# hostsafety: " and are recognised as ours too (never saved as "the original").
#
# Tunables (environment): HOSTSAFETY_TMP_SIZE (4G), HOSTSAFETY_TMP_REMOUNT_MAX_USED (3221225472 bytes: the live /tmp
# remount is refused at or above this usage - nothing is ever truncated or deleted), HOSTSAFETY_EARLYOOM_THRESHOLDS
# ("-m 10,5 -s 100,100"; see docs/host-safety.md "earlyoom, exactly").
set -euo pipefail
mode=plan
case "${1:-}" in --apply) mode=apply ;; --revert) mode=revert ;; --verify) mode=verify ;; "") ;; *) echo "usage: $0 [--apply|--revert|--verify]" >&2; exit 2 ;; esac
ROOT_PREFIX="${HOSTSAFETY_ROOT_PREFIX:-}"   # test hook: re-roots every /etc, /usr, /var and /proc path, skips apt/systemctl/mount (never set in production)
if [[ "${mode}" == apply || "${mode}" == revert ]] && [[ -z "${ROOT_PREFIX}" && "$(id -u)" -ne 0 ]]; then
  echo "root-steps.sh: --apply/--revert must run as root" >&2; exit 1
fi
BK="${ROOT_PREFIX}/var/backups/hostsafety/$(date +%Y%m%dT%H%M%S)"
ORIG="${ROOT_PREFIX}/var/backups/hostsafety/orig"
MARK='# hostsafety-managed'
MEMINFO="${HOSTSAFETY_MEMINFO:-/proc/meminfo}"

TMP_SIZE="${HOSTSAFETY_TMP_SIZE:-4G}"
[[ "${TMP_SIZE}" =~ ^[1-9][0-9]*[kKmMgG]?$ || "${TMP_SIZE}" =~ ^[1-9][0-9]?%$ ]] || { echo "root-steps.sh: HOSTSAFETY_TMP_SIZE='${TMP_SIZE}' must be N, Nk, NM, NG or N%" >&2; exit 2; }
TMP_MAX_USED="${HOSTSAFETY_TMP_REMOUNT_MAX_USED:-3221225472}"
[[ "${TMP_MAX_USED}" =~ ^[0-9]+$ ]] || { echo "root-steps.sh: HOSTSAFETY_TMP_REMOUNT_MAX_USED must be bytes" >&2; exit 2; }
# earlyoom 1.9.0 has NO pressure (PSI) trigger: it acts only when available memory AND free swap are BOTH at or below
# their minimums.  -s 100,100 makes the swap half always true (the slice swap caps keep global swap mostly free while a
# slice thrashes - 2026-10-14: swap 75% free), so it acts on available memory alone: SIGTERM at 10%, SIGKILL at 5%.
EOOM_THRESH="${HOSTSAFETY_EARLYOOM_THRESHOLDS:--m 10,5 -s 100,100}"
[[ "${EOOM_THRESH}" =~ ^-[msMS]\ [0-9]+(,[0-9]+)?(\ -[msMS]\ [0-9]+(,[0-9]+)?)*$ ]] || { echo "root-steps.sh: HOSTSAFETY_EARLYOOM_THRESHOLDS='${EOOM_THRESH}' may only hold -m/-s/-M/-S with numbers" >&2; exit 2; }

# earlyoom matches these regexes (POSIX extended, UNANCHORED unless anchored) against /proc/<pid>/comm - the kernel's
# 15-char process name, NOT argv[0]: so what must match is e.g. "tmux: server", "sshd-session", "gnome-session-c".
# systemd expands them (EnvironmentFile + ExecStart=/usr/bin/earlyoom $EARLYOOM_ARGS), splits on whitespace and does NOT
# strip quotes or process escapes: no whitespace and no backslash in a regex (use [(] for a literal parenthesis).
# --ignore is a HARD exclusion (never a victim).  --avoid only subtracts 300 from oom_score and cannot stop a large
# protected process from being picked, so it is NOT used for protection.
EOOM_IGNORE='^(systemd|systemd-.*|[(]sd-pam[)]|gnome-shell.*|gnome-session.*|gdm.*|Xwayland|Xorg|gjs|mutter.*|sshd.*|tmux.*|claude|conmon|dbus.*|pipewire.*|wireplumber|ibus.*|gsd-.*)$'
# --prefer adds 300 to oom_score (soft): runaway CLASSES by comm.  sh/bash are NOT listed (they are also every tmux pane
# and agent shell) and llama-server is NOT listed (a legitimate multi-GB service that comm cannot tell from a runaway).
# Honest limit: a runaway shell/python/node test runner is therefore chosen only by size, not by this list.
EOOM_PREFER='^(git|post-commit|make|go|cc1|cc1plus|rustc|cargo|ld|collect2|ninja)$'
EOOM_ARGS="-r 60 ${EOOM_THRESH} --ignore-root-user --ignore ${EOOM_IGNORE} --prefer ${EOOM_PREFER}"
# the vendor tmp.mount options (systemd 259) with ONLY size= changed; inode64 is the kernel default for tmpfs on 64-bit
# and usrquota comes from the graceful option, exactly as today (findmnt: ...,nr_inodes=1048576,inode64,usrquota)
TMP_OPTIONS="mode=1777,strictatime,nosuid,nodev,size=${TMP_SIZE},nr_inodes=1m,x-systemd.graceful-option=usrquota"
TMP_DROPIN=/etc/systemd/system/tmp.mount.d/50-hostsafety.conf

declare -A FILES
# 1. journald: the incident wrote 2.3M messages (localsearch-3) - bound the rate per service.
FILES[/etc/systemd/journald.conf.d/50-hostsafety.conf]="${MARK}"'
# a runaway logger must not become an I/O + CPU storm (2026-10-08: 2.3M messages).
[Journal]
RateLimitIntervalSec=30s
RateLimitBurst=2000
SystemMaxUse=2G
'
# 2. swap behaviour: 60 pushed anonymous pages out while the page cache was still large.
FILES[/etc/sysctl.d/90-hostsafety.conf]="${MARK}"'
# prefer reclaiming page cache over swapping anonymous memory.
vm.swappiness = 20
'
# 3. whole-user ceiling: user-1000.slice is the parent of user@1000.service AND all login sessions (session.slice too).
#    Throttle + task cap ONLY.  MemoryMax is deliberately NOT set: a memcg OOM at this level chooses its victim by
#    oom_score over the whole subtree (browser first, then gnome-shell ...) and a parent-level hard limit cannot exempt
#    session.slice, so it could kill the desktop.  Hard limits live on app/background/user slices and bounded-run scopes.
FILES[/etc/systemd/system/user-1000.slice.d/50-hostsafety.conf]="${MARK}"'
# last-resort THROTTLE for everything user 1000 runs (31 GB host); no MemoryMax on purpose (docs/host-safety.md).
[Slice]
MemoryHigh=90%
TasksMax=40000
'
# 4. earlyoom: kills the largest unprotected process BEFORE the kernel thrashes; --ignore is the hard protection list.
FILES[/etc/default/earlyoom]="${MARK}
# ${EOOM_THRESH}: earlyoom needs available memory AND free swap both below their minimums; see root-steps.sh.  Regexes: see root-steps.sh.
EARLYOOM_ARGS=\"${EOOM_ARGS}\"
"
# 5. /tmp is RAM (tmpfs): the vendor size=50% (16 GB here) let 8+ GB of files pin memory on 2026-10-14.  A drop-in on the
#    static tmp.mount is the persistent form; the live remount (apply) only follows it.
FILES[${TMP_DROPIN}]="${MARK}
# /tmp is RAM: cap it (2026-10-14 hang: 8.1 G of tmpfs shmem).  Vendor options, only size= changed.  docs/host-safety.md.
[Mount]
Options=${TMP_OPTIONS}
"

running_earlyoom() { ps -o args= -C earlyoom 2>/dev/null | head -1 || true; }
path_of() { printf '%s%s' "${ROOT_PREFIX}" "$1"; }
is_ours() { grep -qxF "${MARK}" "$1" 2>/dev/null || head -1 "$1" 2>/dev/null | grep -q '^# hostsafety: '; }
# a LIVE_* fixture value is honoured only under a test root: a production --verify can never be satisfied by the environment
fixture() { if [[ -n "${ROOT_PREFIX}" ]]; then printf '%s' "${!1:-}"; fi; }

memtotal_bytes() { awk '/^MemTotal:/ {print $2 * 1024; exit}' "${MEMINFO}" 2>/dev/null; }
# size_bytes <tmpfs size= value> -> bytes (N, Nk/m/g, N%); empty when unparseable
size_bytes() {
  local v="$1" n mt
  case "${v}" in
    *%) n="${v%\%}"; mt="$(memtotal_bytes)"; [[ "${n}" =~ ^[0-9]+$ && -n "${mt}" ]] && echo $(( mt * n / 100 )) ;;
    *[kK]) n="${v%?}"; [[ "${n}" =~ ^[0-9]+$ ]] && echo $(( n * 1024 )) ;;
    *[mM]) n="${v%?}"; [[ "${n}" =~ ^[0-9]+$ ]] && echo $(( n * 1048576 )) ;;
    *[gG]) n="${v%?}"; [[ "${n}" =~ ^[0-9]+$ ]] && echo $(( n * 1073741824 )) ;;
    *) [[ "${v}" =~ ^[0-9]+$ ]] && echo "${v}" ;;
  esac
  return 0
}
size_of_options() { tr ',' '\n' <<<"$1" | sed -n 's/^size=//p' | tail -1 | sed 's/%%/%/'; }
within_1pct() { local a="$1" b="$2"; [[ -n "${a}" && -n "${b}" ]] && (( (a > b ? a - b : b - a) * 100 <= b )); }

# unit_files <unit>: the fragment plus its drop-ins in the order systemd applies them (drop-ins sorted by file name;
# for the same name /etc beats /run beats /usr/lib)
unit_files() {
  local u="$1" d f frag=""
  for d in /etc/systemd/system /run/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
    if [[ -f "$(path_of "${d}/${u}")" ]]; then frag="$(path_of "${d}/${u}")"; break; fi
  done
  [[ -n "${frag}" ]] && echo "${frag}"
  declare -A seen=()
  for d in /usr/lib/systemd/system /lib/systemd/system /run/systemd/system /etc/systemd/system; do
    for f in "$(path_of "${d}/${u}.d")"/*.conf; do [[ -f "${f}" ]] && seen["$(basename "${f}")"]="${f}"; done
  done
  for f in $(printf '%s\n' "${!seen[@]}" | sort); do [[ -n "${f}" ]] && echo "${seen[${f}]}"; done
  return 0
}
# boot_value <unit> <key>: the value a boot (daemon-reload) applies: the last assignment wins, an empty one resets
boot_value() {
  local f v=""
  while IFS= read -r f; do
    v="$(awk -v k="$2" -v cur="${v}" 'BEGIN{val=cur} $0 ~ "^"k"=" {val=substr($0, length(k)+2)} END{print val}' "${f}")"
  done < <(unit_files "$1")
  printf '%s' "${v}"
}
# boot_sysctl <key>: sysctl --system order (files by name over /usr/lib, /run, /etc sysctl.d; /etc wins; /etc/sysctl.conf last)
boot_sysctl() {
  local k="$1" d f v=""
  declare -A seen=()
  for d in /usr/lib/sysctl.d /lib/sysctl.d /run/sysctl.d /etc/sysctl.d; do
    for f in "$(path_of "${d}")"/*.conf; do [[ -f "${f}" ]] && seen["$(basename "${f}")"]="${f}"; done
  done
  for f in $(printf '%s\n' "${!seen[@]}" | sort) /etc/sysctl.conf; do
    [[ -n "${f}" ]] || continue
    if [[ "${f}" == /etc/sysctl.conf ]]; then f="$(path_of /etc/sysctl.conf)"; else f="${seen[${f}]}"; fi
    [[ -f "${f}" ]] || continue
    v="$(awk -F= -v k="${k}" -v cur="${v}" 'BEGIN{val=cur} {gsub(/[ \t]/, "", $1)} $1==k {x=$2; gsub(/^[ \t]+|[ \t]+$/, "", x); val=x} END{print val}' "${f}")"
  done
  printf '%s' "${v}"
}
tmp_used_bytes() {
  if [[ -n "${HOSTSAFETY_TMP_USED_BYTES:-}" ]]; then echo "${HOSTSAFETY_TMP_USED_BYTES}"; return; fi
  df -B1 --output=used /tmp 2>/dev/null | tail -1 | tr -d ' '
}
live_tmp_options() { if [[ -n "${ROOT_PREFIX}" ]]; then fixture LIVE_TMP_OPTIONS; else findmnt -no OPTIONS /tmp 2>/dev/null || true; fi; }

# tmp_line: one human line, boot-effective next to live
tmp_line() {
  local bs ls_ bb lb
  bs="$(size_of_options "$(boot_value tmp.mount Options)")"; ls_="$(size_of_options "$(live_tmp_options)")"
  bb="$(size_bytes "${bs}")"; lb="$(size_bytes "${ls_}")"
  echo "tmp.mount boot-effective size=${bs:-?} (${bb:-?} bytes); live size=${ls_:-?} (${lb:-?} bytes)"
}
# remount_tmp <size> [grow]: the LIVE twin of the persistent definition; a shrink is refused at/above TMP_MAX_USED (a grow,
# as in --revert, never is); nothing is ever truncated or deleted
remount_tmp() {
  local want="$1" used; used="$(tmp_used_bytes)"
  if [[ "${2:-}" == grow ]]; then used=0; fi
  if ! [[ "${used}" =~ ^[0-9]+$ ]]; then echo "REFUSED live remount: cannot read /tmp usage; the boot value applies at the next boot"; return 0; fi
  if (( used >= TMP_MAX_USED )); then
    echo "REFUSED live remount: /tmp holds ${used} bytes >= ${TMP_MAX_USED}; nothing is truncated or deleted. The persistent size=${want} applies at the next boot; or free /tmp and re-run --apply."
    return 0
  fi
  case "${mode}" in
    plan) echo "live: would remount /tmp to size=${want} (used ${used} < ${TMP_MAX_USED} bytes)" ;;
    *) if [[ -n "${ROOT_PREFIX}" ]]; then echo "live: remount /tmp size=${want} skipped (test root)"
       else mount -o remount,size="${want}" /tmp && echo "live: remounted /tmp size=${want}"; fi ;;
  esac
}

# --- verify -------------------------------------------------------------------------------------------------------
VROWS=0; VFAIL=0; VUND=0
row() { # setting verdict persistent boot live enabled note
  VROWS=$((VROWS + 1)); [[ "$2" == FAIL ]] && VFAIL=$((VFAIL + 1)); [[ "$2" == UNDETERMINED ]] && VUND=$((VUND + 1))
  printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}
do_verify() {
  local f bs ls_ bb lb wb v boot live en args want mh mt tm
  # 1. /tmp size
  f="$(path_of "${TMP_DROPIN}")"
  bs="$(size_of_options "$(boot_value tmp.mount Options)")"; ls_="$(size_of_options "$(live_tmp_options)")"
  bb="$(size_bytes "${bs}")"; lb="$(size_bytes "${ls_}")"; wb="$(size_bytes "${TMP_SIZE}")"
  if [[ ! -f "${f}" ]] || ! is_ours "${f}"; then row "tmp.mount size" FAIL "${TMP_DROPIN} missing" "boot size=${bs:-?}" "live size=${ls_:-?}" static "persistent drop-in not installed"
  elif [[ -z "${lb}" ]]; then row "tmp.mount size" UNDETERMINED "${TMP_DROPIN} size=${TMP_SIZE}" "boot size=${bs:-?}" "live size=${ls_:-?}" static "live /tmp size unreadable"
  elif [[ "${bb}" != "${wb}" ]]; then row "tmp.mount size" FAIL "${TMP_DROPIN} size=${TMP_SIZE}" "boot size=${bs:-?}" "live size=${ls_}" static "a boot would NOT apply size=${TMP_SIZE} (another drop-in wins)"
  elif ! within_1pct "${lb}" "${bb}"; then row "tmp.mount size" FAIL "${TMP_DROPIN} size=${TMP_SIZE}" "boot size=${bs}" "DRIFT live size=${ls_}" static "runtime differs from what a boot applies"
  else row "tmp.mount size" PASS "${TMP_DROPIN} size=${TMP_SIZE}" "boot size=${bs}" "live size=${ls_}" static ""; fi
  # 2. vm.swappiness
  boot="$(boot_sysctl vm.swappiness)"; live="$(cat "$(path_of /proc/sys/vm/swappiness)" 2>/dev/null || true)"
  f="$(path_of /etc/sysctl.d/90-hostsafety.conf)"
  if [[ ! -f "${f}" ]]; then row "vm.swappiness" FAIL "/etc/sysctl.d/90-hostsafety.conf missing" "boot=${boot:-unset}" "live=${live:-?}" - ""
  elif [[ -z "${live}" ]]; then row "vm.swappiness" UNDETERMINED "90-hostsafety.conf" "boot=${boot}" "live=?" - "live value unreadable"
  elif [[ "${boot}" != 20 || "${live}" != "${boot}" ]]; then row "vm.swappiness" FAIL "90-hostsafety.conf" "boot=${boot}" "live=${live}" - "want 20 at boot and live"
  else row "vm.swappiness" PASS "90-hostsafety.conf vm.swappiness=20" "boot=${boot}" "live=${live}" - ""; fi
  # 3. journald (read at journald start: the file IS the boot value; no live query exists)
  f="$(path_of /etc/systemd/journald.conf.d/50-hostsafety.conf)"
  if [[ -f "${f}" ]] && grep -q '^RateLimitBurst=2000$' "${f}"; then row "journald rate limit" PASS "50-hostsafety.conf RateLimitBurst=2000" "same (file)" "n/a" - "journald reads it at start; no live query"
  else row "journald rate limit" FAIL "50-hostsafety.conf missing or different" "-" "n/a" - ""; fi
  # 4. user-1000.slice: throttle + task cap, NO MemoryMax
  f="$(path_of /etc/systemd/system/user-1000.slice.d/50-hostsafety.conf)"
  if [[ -n "${ROOT_PREFIX}" ]]; then live="$(fixture LIVE_USER_SLICE)"
  else live="$(systemctl show user-1000.slice -p MemoryHigh -p MemoryMax -p TasksMax 2>/dev/null | tr '\n' ' ')"; fi
  mh="$(sed -n 's/.*MemoryHigh=\([^ ]*\).*/\1/p' <<<"${live}")"; mt="$(sed -n 's/.*MemoryMax=\([^ ]*\).*/\1/p' <<<"${live}")"; tm="$(sed -n 's/.*TasksMax=\([^ ]*\).*/\1/p' <<<"${live}")"
  boot="MemoryHigh=$(boot_value user-1000.slice MemoryHigh) MemoryMax=$(boot_value user-1000.slice MemoryMax) TasksMax=$(boot_value user-1000.slice TasksMax)"
  want=$(( $(memtotal_bytes || echo 0) * 90 / 100 ))
  if [[ ! -f "${f}" ]]; then row "user-1000.slice" FAIL "50-hostsafety.conf missing" "${boot}" "${live:-?}" - ""
  elif [[ -z "${mh}" ]]; then row "user-1000.slice" UNDETERMINED "50-hostsafety.conf" "${boot}" "?" - "live values unreadable"
  elif [[ "${boot}" != "MemoryHigh=90% MemoryMax= TasksMax=40000" || "${mt}" != infinity || "${tm}" != 40000 ]] || ! within_1pct "${mh}" "${want}"; then
    row "user-1000.slice" FAIL "50-hostsafety.conf" "${boot}" "${live}" - "want MemoryHigh=90%, TasksMax=40000, no MemoryMax (boot and live)"
  else row "user-1000.slice" PASS "50-hostsafety.conf" "${boot}" "${live}" - ""; fi
  # 5. earlyoom enabled (else it does not start at the next boot)
  if [[ -n "${ROOT_PREFIX}" ]]; then en="$(fixture LIVE_EARLYOOM_ENABLED)"; else en="$(systemctl is-enabled earlyoom 2>/dev/null || true)"; fi
  if [[ "${en}" == enabled ]]; then row "earlyoom enabled" PASS "earlyoom.service" "starts at boot" "-" "${en}" ""
  elif [[ -z "${en}" ]]; then row "earlyoom enabled" UNDETERMINED "earlyoom.service" "?" "-" "?" "is-enabled unreadable"
  else row "earlyoom enabled" FAIL "earlyoom.service" "does NOT start at boot" "-" "${en}" ""; fi
  # 6. earlyoom args: the persistent file, and the running process must equal it (else a restart is due)
  f="$(path_of /etc/default/earlyoom)"
  args="$(sed -n 's/^EARLYOOM_ARGS="\(.*\)"$/\1/p' "${f}" 2>/dev/null | tail -1)"
  if [[ -n "${ROOT_PREFIX}" ]]; then live="$(fixture LIVE_EARLYOOM)"; else live="$(running_earlyoom)"; fi
  if [[ "${args}" != "${EOOM_ARGS}" ]]; then row "earlyoom args" FAIL "/etc/default/earlyoom: ${args:-?}" "${args:-?}" "${live:-not running}" "${en:-?}" "file differs from the hostsafety arguments"
  elif [[ -z "${live}" ]]; then row "earlyoom args" FAIL "/etc/default/earlyoom" "${args}" "not running" "${en:-?}" ""
  elif [[ "${live}" != "/usr/bin/earlyoom ${args}" ]]; then row "earlyoom args" FAIL "/etc/default/earlyoom" "${args}" "${live}" "${en:-?}" "running args differ: restart earlyoom"
  else row "earlyoom args" PASS "/etc/default/earlyoom" "${args}" "${live}" "${en:-?}" ""; fi
  echo "root-steps verify: $((VROWS - VFAIL - VUND)) PASS ${VFAIL} FAIL ${VUND} UNDETERMINED"
  (( VFAIL )) && return 1
  (( VUND )) && return 2
  return 0
}

case "${mode}" in
  plan)
    for f in "${!FILES[@]}"; do printf '=== would write %s ===\n%s\n' "${f}" "${FILES[${f}]}"; done
    echo "=== would run: apt-get install -y earlyoom (if absent; our config is written AFTER the install); sysctl --system; systemctl daemon-reload; systemctl restart systemd-journald; systemctl enable --now earlyoom; systemctl restart earlyoom; then the /tmp remount below ==="
    echo "NOTE: systemd-oomd ManagedOOMMemoryPressure= is deliberately NOT set: oomd kills a whole cgroup, and the agent fleet (claude, tmux, tests) shares one scope."
    echo "=== /tmp (tmpfs = RAM): now ==="
    tmp_line
    remount_tmp "${TMP_SIZE}"
    echo "=== running earlyoom command line RIGHT NOW (the package default '-r 3600' = no protection list, until --apply is run) ==="
    echo "${LIVE_EARLYOOM:-$(running_earlyoom)}"
    ;;
  apply)
    mkdir -p "${BK}" "${ORIG}"
    # Install FIRST and keep our file on a dpkg conffile prompt, then write the config AFTER: answering the prompt with
    # "install the maintainer's version" (2026-10-09 live run) replaced the protection list by the package default.
    [[ -n "${ROOT_PREFIX}" ]] || command -v earlyoom >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confold earlyoom
    for f in "${!FILES[@]}"; do
      t="$(path_of "${f}")"
      if [[ -e "${t}" ]]; then
        mkdir -p "${BK}$(dirname "${f}")"; cp -p "${t}" "${BK}${f}"
        # first-ever copy of a file that is NOT ours = the original that --revert restores
        if [[ ! -e "${ORIG}${f}" ]] && ! is_ours "${t}"; then mkdir -p "${ORIG}$(dirname "${f}")"; cp -p "${t}" "${ORIG}${f}"; fi
      fi
      mkdir -p "$(dirname "${t}")"; printf '%s' "${FILES[${f}]}" >"${t}.tmp" && mv "${t}.tmp" "${t}"; echo "wrote ${f}"
    done
    if [[ -z "${ROOT_PREFIX}" ]]; then
      sysctl --system >/dev/null; systemctl daemon-reload; systemctl restart systemd-journald
      systemctl enable --now earlyoom; systemctl restart earlyoom
      sleep 1
      echo "=== post-check: running earlyoom command line ==="
      live="$(running_earlyoom)"; echo "${live}"
      if [[ "${live}" != *"--ignore"* || "${live}" != *"gnome-shell"* ]]; then
        echo "POST-CHECK FAILED: earlyoom is not running with the hostsafety protection list" >&2; exit 1
      fi
      echo "post-check ok: earlyoom runs with the --ignore protection list"
    fi
    echo "=== /tmp: the persistent drop-in is written; live remount follows it ==="
    remount_tmp "${TMP_SIZE}"
    tmp_line
    echo "backups (if any) in ${BK}; originals in ${ORIG}"
    echo "=== verify (persistent / boot / live) ==="
    do_verify || true
    ;;
  revert)
    for f in "${!FILES[@]}"; do
      t="$(path_of "${f}")"
      if [[ -e "${ORIG}${f}" ]]; then cp -p "${ORIG}${f}" "${t}" && echo "restored ${f} from ${ORIG}${f}"
      elif [[ -e "${t}" ]] && is_ours "${t}"; then rm -f "${t}"; echo "removed ${f}"
      else echo "left ${f} untouched (not ours, no original recorded)"; fi
    done
    if [[ -z "${ROOT_PREFIX}" ]]; then
      sysctl --system >/dev/null; systemctl daemon-reload; systemctl restart systemd-journald
      systemctl restart earlyoom 2>/dev/null || true   # picks the restored package default back up; earlyoom itself stays installed
    fi
    # the live /tmp size follows whatever boot definition remains (the vendor 50% when ours was the only drop-in)
    bs="$(size_of_options "$(boot_value tmp.mount Options)")"
    if [[ -n "${bs}" ]]; then remount_tmp "${bs}" grow; fi
    ;;
  verify)
    do_verify; exit $?
    ;;
esac
