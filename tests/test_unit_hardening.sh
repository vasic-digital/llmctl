#!/usr/bin/env bash
# test_unit_hardening.sh - proves, against the LIVE systemd --user manager, that
# every hardening directive llmctl writes into a unit takes effect (FR-083), and
# records which directives it deliberately does NOT write this manager honours. A parse of the unit file proves nothing about enforcement, so
# each directive is exercised through a transient service started with exactly
# that property and an in-service check that OBSERVES the effect (hard assertions). Directives llmctl
# does not write are probed too, but only as INFORMATIONAL host facts (systemd-version dependent):
#
#   NoNewPrivileges        /proc/self/status NoNewPrivs: 1
#   ProtectSystem=full     writing under /usr is refused
#   UMask=0077             the unit process umask
#   RestrictAddressFamilies  AF_NETLINK -> EAFNOSUPPORT, AF_INET still works
#   RestrictSUIDSGID, LockPersonality, RestrictRealtime, SystemCallArchitectures
#                          a seccomp filter is installed (Seccomp: 2) where a
#                          control service without the property shows Seccomp: 0
#
# Skips honestly (never passes) when no systemd --user manager is reachable.
# Transient units are removed by systemd when they exit; the only files this test
# touches are two marker files it creates by exact name and removes.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
MARK_TMP="/tmp/llmctl_hardening_probe_marker.$$"
MARK_HOME="${HOME}/.llmctl_hardening_probe_marker.$$"
# G-088: every transient unit this test starts has an EXACT name recorded here; the EXIT trap stops and
# reset-fails exactly those (units that fail to start - the "refused" probes - would otherwise stay in the
# user manager as failed run-p*-i*.service). --collect below makes systemd drop them itself as well.
PROBE_UNITS=()
cleanup() {
  local u
  for u in ${PROBE_UNITS[@]+"${PROBE_UNITS[@]}"}; do
    systemctl --user stop "${u}.service" >/dev/null 2>&1 || true
    systemctl --user reset-failed "${u}.service" >/dev/null 2>&1 || true
  done
  rm -f "${MARK_TMP}" "${MARK_HOME}"; test_teardown_env
}
trap cleanup EXIT

if ! command -v systemd-run >/dev/null 2>&1 || ! systemd-run --user --wait --pipe --quiet --collect /bin/true >/dev/null 2>&1; then
  echo "SKIP-SUITE: no reachable systemd --user manager: cannot observe directive effects"
  exit 0
fi

PROBE_OUT=""; PROBE_RC=0; PROBE_SEQ=0
probe() { # probe <check-script> [Property=Value ...] -> PROBE_OUT (stdout+stderr) and PROBE_RC
  local chk="$1"; shift
  local -a a=() p
  for p in "$@"; do a+=(-p "$p"); done
  PROBE_SEQ=$((PROBE_SEQ+1))
  local unit="llmctl-hardening-probe-$$-${PROBE_SEQ}"
  PROBE_UNITS+=("${unit}")
  PROBE_RC=0
  PROBE_OUT="$(systemd-run --user --wait --pipe --quiet --collect --unit="${unit}" ${a[@]+"${a[@]}"} /bin/bash -c "${chk}" 2>&1)" || PROBE_RC=$?
}

# ---- what llmctl emits (read from the REAL generator, not copied here) ----
export LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
EMITTED="$(
  source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/os_detect.sh"
  source "${LLMCTL_ROOT}/lib/hardware.sh"; source "${LLMCTL_ROOT}/lib/service_linux.sh"
  { _svc_hardening basic; _svc_hardening strict; } | sort -u
)"
echo "directives emitted by lib/service_linux.sh (_svc_hardening):"
sed 's/^/    /' <<<"${EMITTED}"

have() { grep -qxF -- "$1" <<<"${EMITTED}"; }

# ---- control: with no property, none of the observations fire -------------
probe 'grep -E "^(NoNewPrivs|Seccomp):" /proc/self/status | tr "\n" " "; umask'
assert_contains "${PROBE_OUT}" "NoNewPrivs:	0" "control: NoNewPrivs is 0 without the property"
assert_contains "${PROBE_OUT}" "Seccomp:	0" "control: no seccomp filter without a seccomp-backed property"

check_directive() { # <Property=Value> <script that prints OK when the effect is observed>
  local prop="$1" chk="$2"
  if ! have "${prop}"; then
    printf '  FAIL: %s is not emitted by the generator (this test and the units disagree)\n' "${prop}" >&2; TEST_FAILS=$((TEST_FAILS+1)); return
  fi
  probe "${chk}" "${prop}"
  assert_eq "OK" "$(tail -1 <<<"${PROBE_OUT}")" "${prop} takes effect in the user manager (observed in a live service, rc=${PROBE_RC})"
}

check_directive "NoNewPrivileges=yes" 'grep -q "^NoNewPrivs:[[:space:]]*1" /proc/self/status && echo OK'
check_directive "ProtectSystem=full" 'if touch /usr/.llmctl_probe 2>/dev/null; then rm -f /usr/.llmctl_probe; echo WRITABLE; else echo OK; fi'
check_directive "UMask=0077" '[ "$(umask)" = 0077 ] && echo OK'
check_directive "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6" 'python3 - <<"PY"
import errno, socket
try:
    socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, 0)
    print("NETLINK-ALLOWED")
except OSError as e:
    ok = e.errno == errno.EAFNOSUPPORT
    socket.socket(socket.AF_INET, socket.SOCK_STREAM).close()
    print("OK" if ok else "errno=%s" % e.errno)
PY'
for d in "RestrictSUIDSGID=yes" "LockPersonality=yes" "RestrictRealtime=yes" "SystemCallArchitectures=native"; do
  check_directive "${d}" 'grep -q "^Seccomp:[[:space:]]*2" /proc/self/status && echo OK'
done

# ---- directives NOT written: INFORMATIONAL host facts (G-083) ----
# Whether the user manager honours these depends on the systemd version / kernel / privileges of THIS
# host, so a "not honoured" result is recorded, never asserted. The hard guarantee above stays: every
# directive llmctl WRITES takes effect. The table is the evidence for which directives could be added.
echo "== directives deliberately not written: which ones this systemd honours (host facts, informational) =="
: > "${MARK_TMP}"; : > "${MARK_HOME}"
HOST_FACTS=()
fact() { # fact <directive> <honoured|not-honoured|refused> <detail>
  HOST_FACTS+=("$1|$2|$3"); printf '  fact: %-28s %-13s %s\n' "$1" "$2" "$3"
}
for d in PrivateDevices=yes ProtectClock=yes "CapabilityBoundingSet="; do
  probe 'echo started' "${d}"
  if [[ "${PROBE_RC}" != 0 ]]; then fact "${d}" refused "unit failed to start (rc=${PROBE_RC})"
  else fact "${d}" honoured "unit started (property accepted)"; fi
done
probe "[ -e '${MARK_TMP}' ] && echo VISIBLE || echo HIDDEN" PrivateTmp=yes
if [[ "$(tail -1 <<<"${PROBE_OUT}")" == HIDDEN ]]; then fact PrivateTmp=yes honoured "host /tmp marker hidden"; else fact PrivateTmp=yes not-honoured "host /tmp marker visible"; fi
probe "if (echo x >> '${MARK_HOME}') 2>/dev/null; then echo WRITABLE; else echo RO; fi" ProtectHome=read-only
if [[ "$(tail -1 <<<"${PROBE_OUT}")" == RO ]]; then fact ProtectHome=read-only honoured "home read-only"; else fact ProtectHome=read-only not-honoured "home writable"; fi
probe 'ls /proc | grep -c "^[0-9]"' ProtectProc=invisible
if [[ "$(tail -1 <<<"${PROBE_OUT}")" -gt 3 ]]; then fact ProtectProc=invisible not-honoured "other processes visible"; else fact ProtectProc=invisible honoured "other processes hidden"; fi
probe 'mount | grep " /sys/fs/cgroup " | grep -c "(rw"' ProtectControlGroups=yes
if [[ "$(tail -1 <<<"${PROBE_OUT}")" == 1 ]]; then fact ProtectControlGroups=yes not-honoured "cgroup fs read-write"; else fact ProtectControlGroups=yes honoured "cgroup fs read-only"; fi
echo "host: $(systemctl --version | head -n1) / kernel $(uname -r) (facts above are properties of this host, not pass/fail)"
# the table itself is a hard check only in shape: every probed directive produced exactly one fact
assert_eq 7 "${#HOST_FACTS[@]}" "every probed not-written directive produced a recorded host fact"
if [[ -n "${LLMCTL_HOST_FACTS_FILE:-}" ]]; then printf '%s\n' "${HOST_FACTS[@]}" >"${LLMCTL_HOST_FACTS_FILE}"; fi

test_finish
