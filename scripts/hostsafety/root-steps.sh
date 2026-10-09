#!/usr/bin/env bash
# root-steps.sh - the ROOT-LEVEL half of the 2026-10-08 hang remediation.
# NOT applied by the user-level installer.  Read it, then run as root:
#     sudo bash root-steps.sh            # prints what it would do + what is running NOW (default; no root needed)
#     sudo bash root-steps.sh --apply    # applies it, then prints the running earlyoom command line as a post-check
#     sudo bash root-steps.sh --revert   # removes what --apply created and restores the pre-hostsafety originals
# Every file is written atomically.  The FIRST pre-existing copy of each file is kept under
# /var/backups/hostsafety/orig/ (never overwritten by later runs) and --revert restores it; later runs also keep a
# timestamped copy under /var/backups/hostsafety/<timestamp>/.  Files we wrote carry the marker line below.
set -euo pipefail
mode=plan
case "${1:-}" in --apply) mode=apply ;; --revert) mode=revert ;; "") ;; *) echo "usage: $0 [--apply|--revert]" >&2; exit 2 ;; esac
ROOT_PREFIX="${HOSTSAFETY_ROOT_PREFIX:-}"   # test hook: re-roots every /etc and /var path, skips apt/systemctl (never set in production)
if [[ "${mode}" != plan && -z "${ROOT_PREFIX}" && "$(id -u)" -ne 0 ]]; then echo "root-steps.sh: --apply/--revert must run as root" >&2; exit 1; fi
BK="${ROOT_PREFIX}/var/backups/hostsafety/$(date +%Y%m%dT%H%M%S)"
ORIG="${ROOT_PREFIX}/var/backups/hostsafety/orig"
MARK='# hostsafety-managed'

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
# 4. earlyoom: kills the largest process BEFORE the kernel thrashes; --ignore is the hard protection list.
FILES[/etc/default/earlyoom]="${MARK}
# act at 5% available memory AND 10% swap free (earlyoom needs both below the limit).  Regexes: see root-steps.sh.
EARLYOOM_ARGS=\"-r 60 -m 5 -s 10 --ignore-root-user --ignore ${EOOM_IGNORE} --prefer ${EOOM_PREFER}\"
"

running_earlyoom() { ps -o args= -C earlyoom 2>/dev/null | head -1 || true; }
path_of() { printf '%s%s' "${ROOT_PREFIX}" "$1"; }

case "${mode}" in
  plan)
    for f in "${!FILES[@]}"; do printf '=== would write %s ===\n%s\n' "${f}" "${FILES[${f}]}"; done
    echo "=== would run: apt-get install -y earlyoom (if absent; our config is written AFTER the install); sysctl --system; systemctl daemon-reload; systemctl restart systemd-journald; systemctl enable --now earlyoom; systemctl restart earlyoom ==="
    echo "NOTE: systemd-oomd ManagedOOMMemoryPressure= is deliberately NOT set: oomd kills a whole cgroup, and the agent fleet (claude, tmux, tests) shares one scope."
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
        if [[ ! -e "${ORIG}${f}" ]] && ! grep -qxF "${MARK}" "${t}"; then mkdir -p "${ORIG}$(dirname "${f}")"; cp -p "${t}" "${ORIG}${f}"; fi
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
    echo "backups (if any) in ${BK}; originals in ${ORIG}"
    ;;
  revert)
    for f in "${!FILES[@]}"; do
      t="$(path_of "${f}")"
      if [[ -e "${ORIG}${f}" ]]; then cp -p "${ORIG}${f}" "${t}" && echo "restored ${f} from ${ORIG}${f}"
      elif [[ -e "${t}" ]] && grep -qxF "${MARK}" "${t}"; then rm -f "${t}"; echo "removed ${f}"
      else echo "left ${f} untouched (not ours, no original recorded)"; fi
    done
    if [[ -z "${ROOT_PREFIX}" ]]; then
      systemctl daemon-reload; systemctl restart systemd-journald
      systemctl restart earlyoom 2>/dev/null || true   # picks the restored package default back up; earlyoom itself stays installed
    fi
    ;;
esac
