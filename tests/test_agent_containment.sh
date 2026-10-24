#!/usr/bin/env bash
# test_agent_containment.sh - containment of agent / test jobs (docs/host-safety.md "Containing agent and test jobs").
# Incident 2026-10-13: a PATH shim named `tr` whose body called `tr` by bare name re-executed itself, ~6,000 processes in an
# UNCAPPED session scope.  Here the same shape runs inside a TasksMax=40 scope and the cap must hold, the scope must be gone
# afterwards and nothing may survive.  Only HERMETIC signals gate (the scope's own cgroup, /proc/*/cgroup membership, a bystander scope);
# the host-wide fork rate is noisy (containers alone fork 60-500/s) and is shown ONLY as a negative control that it must not gate.  Live section: needs systemd --user.
# Every fork-capable command runs inside a bounded scope with a wall-clock timeout; nothing signals a pid or a pgid.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT

HS="${LLMCTL_ROOT}/scripts/hostsafety"
BR="${HS}/bounded-run"
AR="${HS}/agent-run"
export HOSTSAFETY_LIB="${HS}/lib.sh"

if ! command -v systemd-run >/dev/null 2>&1 || ! systemctl --user show -p Version >/dev/null 2>&1; then
  skip_suite "no usable systemd --user manager"
fi

mark="ac$$x${RANDOM}"
forks_now() { awk '/^processes /{print $2}' /proc/stat; }
# forks in 1 s, three samples: "max" (baseline: a busy host varies) or "min" (after: a lingering runaway cannot hide in the minimum)
fork_rate() { local a b best="" v; for _ in 1 2 3; do a=$(forks_now); sleep 1; b=$(forks_now); v=$((b - a))
  if [[ -z "${best}" ]] || { [[ $1 == max ]] && (( v > best )); } || { [[ $1 == min ]] && (( v < best )); }; then best=${v}; fi; done; echo "${best}"; }
procs_in_scope() { # <name> : processes whose cgroup is that bounded-run scope (read from /proc/*/cgroup, no patterns, no signals)
  local n=0 p
  for p in /proc/[0-9]*; do grep -qs "bounded-run-$1\.scope" "${p}/cgroup" 2>/dev/null && n=$((n + 1)); done
  echo "${n}"
}
count_procs() { # live processes whose cmdline contains a fixed string (reads /proc directly: no pgrep self-match)
  local n=0 p c
  for p in /proc/[0-9]*; do
    c="$({ /usr/bin/tr '\0' ' ' <"${p}/cmdline"; } 2>/dev/null || true)"
    [[ "${c}" == *"$1"* && "${c}" != *"count_procs"* ]] && n=$((n + 1))
  done
  echo "${n}"
}
scope_gone_wait() { # <name> : scope_gone, polled for up to 15 s. The scope is stopped ASYNCHRONOUSLY after bounded-run returns
  # (systemd kills the cgroup, then drops the unit; TimeoutStopSec=5 is its own bound), so one check after a fixed `sleep 1` is a race.
  # Measured 2026-10-24: idle host, gone at 0.04 s; under CPU load one run still showed it active at 0.08 s and gone at 0.27 s. The cause
  # of the two FAILs seen once in an isolated-HOME run is UNCONFIRMED (not reproduced in 3 later runs). A scope that never goes still FAILs.
  for _ in $(seq 1 75); do [[ "$(scope_gone "$1")" == yes ]] && { echo yes; return 0; }; sleep 0.2; done
  scope_gone "$1"
}
scope_gone() { # <name> : the transient scope no longer exists
  local ls st
  st="$(systemctl --user is-active "bounded-run-$1.scope" 2>&1 | head -1 || true)"
  ls="$(systemctl --user show "bounded-run-$1.scope" -p LoadState --value 2>/dev/null || true)"
  [[ "${st}" != active && ( -z "${ls}" || "${ls}" == not-found ) ]] && echo yes || echo no
}

# --- 1. flag surface + agent defaults -------------------------------------------------------
assert_file_exists "${AR}" "scripts/hostsafety/agent-run exists"
assert_eq "yes" "$([[ -x "${AR}" ]] && echo yes || echo no)" "agent-run is executable"
out="$("${AR}" -n "acdef$$" -- true 2>&1 || true)"
assert_contains "${out}" "TasksMax=200" "agent defaults: TasksMax=200 (banner)"
assert_contains "${out}" "MemoryMax=1G" "agent defaults: MemoryMax=1G (banner)"
assert_contains "${out}" "timeout=300s" "agent defaults: timeout 300 s (banner)"
live="$("${AR}" -q -n "aclive$$" -- bash -c 'systemctl --user show bounded-run-aclive'"$$"'.scope -p TasksMax -p MemoryMax -p ManagedOOMPreference' 2>&1 || true)"
assert_contains "${live}" "TasksMax=200" "the live scope really carries TasksMax=200"
assert_contains "${live}" "MemoryMax=1073741824" "the live scope really carries MemoryMax=1G"
case "${live}" in *"ManagedOOMPreference=avoid"*) assert_eq "not-avoid" "avoid" "scope must not be ManagedOOMPreference=avoid" ;;
  *"ManagedOOMPreference="*) assert_eq 0 0 "scope is NOT ManagedOOMPreference=avoid (oomd may pick it): $(printf '%s' "${live}" | grep ManagedOOM)" ;;
  *) assert_eq "ManagedOOMPreference line" "missing" "could not read ManagedOOMPreference" ;; esac
out="$("${BR}" --tasks 77 --mem 1500M --timeout 9 -n "aclong$$" -- true 2>&1 || true)"
assert_contains "${out}" "TasksMax=77" "bounded-run --tasks N"
assert_contains "${out}" "MemoryMax=1500M" "bounded-run --mem SIZE"
assert_contains "${out}" "timeout=9s" "bounded-run --timeout S"
out="$("${BR}" --tasks=78 --mem=1G --timeout=8 -n "aceq$$" -- true 2>&1 || true)"
assert_contains "${out}" "TasksMax=78" "bounded-run --tasks=N form"

# --- 1b. NEGATIVE CONTROL: the host-wide fork rate is not a valid gate -------------------------
# Under synthetic background load (a harmless fork loop, TasksMax=20, 9 s) the OLD predicate "fork rate <= 2x idle + 200" FAILS
# although nothing is wrong with the code under test: that is the flake, reproduced on purpose.  It therefore does not gate below.
idle=$(fork_rate min)
"${BR}" -q --tasks 20 --mem 1G --timeout 15 -n "acload$$" -- bash -c 'for i in 1 2 3 4; do ( e=$((SECONDS+9)); while ((SECONDS<e)); do /usr/bin/true; done ) & done; wait' >/dev/null 2>&1 &
loadp=$!
sleep 1; loaded=$(fork_rate max); wait "${loadp}" 2>/dev/null || true
old_verdict=$([[ ${loaded} -le $((idle * 2 + 200)) ]] && echo pass || echo FAIL)
printf '  evidence: old predicate under synthetic load: %s/s vs threshold %s/s (idle %s/s) -> %s\n' "${loaded}" "$((idle * 2 + 200))" "${idle}" "${old_verdict}"
# INFORMATIONAL only (no assertion): whether unrelated load moves the host-wide fork rate itself depends on host load.
printf '  info: host-wide fork rate under unrelated load: loaded max %s/s, idle min %s/s (old predicate would %s); not asserted, not a gate\n' "${loaded}" "${idle}" "${old_verdict}"

# bystander scope started BEFORE the bomb: must still be active after it (hermetic isolation signal)
"${BR}" -q --tasks 40 --mem 1G --timeout 200 -n "acbefore$$" -- /usr/bin/sleep 150 >/dev/null 2>&1 &
beforep=$!
for _ in $(seq 1 50); do systemctl --user is-active "bounded-run-acbefore$$.scope" >/dev/null 2>&1 && break; sleep 0.1; done

# --- 2. fork-bomb-shaped fixture under TasksMax=40 -----------------------------------------
cat >"${TEST_TMP}/bomb.py" <<'PY'
import subprocess, sys, time
mark = sys.argv[1]; kids = []; fails = 0
cg = "/sys/fs/cgroup" + open("/proc/self/cgroup").read().split("::")[1].strip()
for i in range(300):
    try:
        kids.append(subprocess.Popen(["acmark-" + mark, "300"], executable="/usr/bin/sleep"))
    except OSError:
        fails += 1
ev = dict(l.split() for l in open(cg + "/pids.events"))
print("spawned=%d failed=%d max_events=%s peak=%s" % (len(kids), fails, ev.get("max"), open(cg + "/pids.peak").read().strip()), flush=True)
time.sleep(1)
PY
res="$("${BR}" -q --tasks 40 --mem 1G --timeout 30 -n "acbomb$$" -- python3 -I "${TEST_TMP}/bomb.py" "${mark}" 2>&1 || true)"
printf '  evidence: %s\n' "${res}"
ev_max="$(printf '%s' "${res}" | sed -n 's/.*max_events=\([0-9]*\).*/\1/p')"
peak="$(printf '%s' "${res}" | sed -n 's/.*peak=\([0-9]*\).*/\1/p')"
assert_eq "yes" "$([[ ${ev_max:-0} -gt 0 ]] && echo yes || echo no)" "bomb: pids.events max > 0 (the cap was hit: ${ev_max:-?})"
assert_eq "yes" "$([[ -n ${peak} && ${peak} -le 40 ]] && echo yes || echo no)" "bomb: pids.peak <= 40 (peak=${peak:-?})"
sleep 1
assert_eq "yes" "$(scope_gone_wait "acbomb$$")" "bomb: the scope is gone afterwards"
assert_eq "0" "$(count_procs "acmark-${mark} 300")" "bomb: leftover processes = 0"
assert_eq "0" "$(procs_in_scope "acbomb$$")" "bomb: zero processes left in the bomb's cgroup (read from /proc/*/cgroup)"
assert_eq "active" "$(systemctl --user is-active "bounded-run-acbefore$$.scope" 2>&1 | head -1)" "bomb: a bystander scope started before it is still active"

# --- 3. the p1.sh failure: a PATH shim `tr` that calls `tr` by bare name --------------------
SH="${TEST_TMP}/recshim-${mark}"; mkdir -p "${SH}"
# SHIM-LINT-OK: deliberate self-recursive fixture reproducing the 2026-10-13 incident; only ever run inside a TasksMax=40 scope
printf '#!/bin/bash\ntr a b </dev/null\n' >"${SH}/tr"; chmod +x "${SH}/tr"
cat >"${TEST_TMP}/rec.sh" <<'EOS'
#!/bin/bash
# $1 = shim dir. Runs the recursive shim, then reports this scope's pids accounting.
cg="/sys/fs/cgroup$(sed 's/^0:://' /proc/self/cgroup)"
PATH="$1:$PATH" tr x y </dev/null >/dev/null 2>&1 || true
ev="$(awk '$1=="max"{print $2}' "${cg}/pids.events")"
echo "max_events=${ev} peak=$(cat "${cg}/pids.peak")"
EOS
res="$("${BR}" -q --tasks 40 --mem 1G --timeout 30 -n "acrec$$" -- bash "${TEST_TMP}/rec.sh" "${SH}" 2>&1 || true)"
printf '  evidence: %s\n' "${res}"
ev_max="$(printf '%s' "${res}" | sed -n 's/.*max_events=\([0-9]*\).*/\1/p')"
peak="$(printf '%s' "${res}" | sed -n 's/.*peak=\([0-9]*\).*/\1/p')"
assert_eq "yes" "$([[ ${ev_max:-0} -gt 0 ]] && echo yes || echo no)" "recursive shim: pids.events max > 0 (${ev_max:-?})"
assert_eq "yes" "$([[ -n ${peak} && ${peak} -le 40 ]] && echo yes || echo no)" "recursive shim: pids.peak <= 40 (peak=${peak:-?})"
sleep 1
assert_eq "yes" "$(scope_gone_wait "acrec$$")" "recursive shim: the scope is gone afterwards"
assert_eq "0" "$(count_procs "${SH}/tr")" "recursive shim: leftover processes = 0"
assert_eq "0" "$(procs_in_scope "acrec$$")" "recursive shim: zero processes left in its cgroup (read from /proc/*/cgroup)"
assert_eq "active" "$(systemctl --user is-active "bounded-run-acbefore$$.scope" 2>&1 | head -1)" "recursive shim: the bystander scope is still active"
systemctl --user kill --kill-whom=all --signal=SIGKILL "bounded-run-acbefore$$.scope" 2>/dev/null || true
wait "${beforep}" 2>/dev/null || true

# --- 4. timeout tears down ITS OWN scope only (guarded: a regression FAILS, it never hangs) ----
# the fixture lives 30 s (not 300) and the run is wrapped in an outer hard limit, so a broken watchdog shows as rc!=124 / slow
"${BR}" -q --tasks 40 --mem 1G --timeout 120 -n "acbystander$$" -- sleep 20 >/dev/null 2>&1 &
byp=$!
"${BR}" -q --tasks 40 --mem 1G --timeout 120 -n "acbystander2$$" -- bash -c 'exec -a acbyloop-'"${mark}"' bash -c "while :; do /usr/bin/sleep 1; done"' >/dev/null 2>&1 &
byp2=$!
(exec -a "acbyplain-${mark}" /usr/bin/sleep 40) &   # a plain process of a different name, outside any scope of ours
byp3=$!
for _ in $(seq 1 50); do systemctl --user is-active "bounded-run-acbystander$$.scope" >/dev/null 2>&1 \
  && systemctl --user is-active "bounded-run-acbystander2$$.scope" >/dev/null 2>&1 && break; sleep 0.1; done
start=$SECONDS; rc=0
/usr/bin/timeout -k 2 45 "${BR}" -q --tasks 40 --mem 1G --timeout 2 -n "acto$$" -- bash -c "(exec -a acmarkb-${mark} sleep 30) & wait" >/dev/null 2>&1 || rc=$?
took=$((SECONDS - start))
assert_eq "124" "${rc}" "--timeout 2 returns 124"
assert_eq "yes" "$([[ ${took} -le 6 ]] && echo yes || echo no)" "--timeout enforced within seconds (took ${took}s)"
sleep 1
assert_eq "yes" "$(scope_gone_wait "acto$$")" "timeout: its scope is stopped and gone"
assert_eq "0" "$(count_procs "acmarkb-${mark}")" "timeout: leftover processes = 0"
assert_eq "active" "$(systemctl --user is-active "bounded-run-acbystander$$.scope" 2>&1 | head -1)" "timeout did NOT touch a bystander scope (command 'sleep 20')"
assert_eq "active" "$(systemctl --user is-active "bounded-run-acbystander2$$.scope" 2>&1 | head -1)" "timeout did NOT touch a bystander scope running a command that does not match 'sleep 20'"
assert_eq "yes" "$([[ "$(count_procs "acbyloop-${mark}")" -ge 1 ]] && echo yes || echo no)" "the second bystander's process is alive"
assert_eq "1" "$(count_procs "acbyplain-${mark}")" "a plain bystander process of another name (outside any scope) survived"
systemctl --user kill --kill-whom=all --signal=SIGKILL "bounded-run-acbystander$$.scope" "bounded-run-acbystander2$$.scope" 2>/dev/null || true
kill "${byp3}" 2>/dev/null || true
wait "${byp}" "${byp2}" "${byp3}" 2>/dev/null || true

# --- 5. input validation + honest failure codes ------------------------------------------------
rc=0; out="$("${BR}" -q --bogus -- true 2>&1)" || rc=$?
assert_eq "125" "${rc}" "an unknown long option exits 125"
assert_contains "${out}" "--bogus" "...and names the actual unknown option"
rc=0; out="$("${BR}" -q -s notasize -n "acsw$$" -- true 2>&1)" || rc=$?
assert_eq "125" "${rc}" "-s with a non-size exits 125 (validated, not passed to systemd)"
assert_contains "${out}" "-s" "...and says which option"
rc=0; out="$("${BR}" -q -s 64M -n "acsw2$$" -- true 2>&1)" || rc=$?
assert_eq "0" "${rc}" "-s 64M (a valid size) is accepted"
mkdir -p "${TEST_TMP}/xdg"; chmod 700 "${TEST_TMP}/xdg"
rc=0; out="$(XDG_RUNTIME_DIR="${TEST_TMP}/xdg" DBUS_SESSION_BUS_ADDRESS='' "${BR}" -q -n "acfail$$" -- true 2>&1)" || rc=$?
assert_eq "125" "${rc}" "systemd-run failing to start the scope exits 125, not systemd-run's own status (${rc})"
# short options are parsed AFTER long ones and win; BOUNDED_RUN_* env beats the --agent profile
out="$("${BR}" --tasks 77 -t 66 -n "acord$$" -- true 2>&1 || true)"
assert_contains "${out}" "TasksMax=66" "short -t is parsed after long --tasks and wins (documented)"
out="$(BOUNDED_RUN_TASKS=55 "${AR}" -n "acenv$$" -- true 2>&1 || true)"
assert_contains "${out}" "TasksMax=55" "BOUNDED_RUN_TASKS overrides the --agent profile (documented)"

# --- 6. independent hard timeout: RuntimeMaxSec on the scope (second line of defence) --------
rms="$("${BR}" -q -T 2 -n "acrms$$" -- bash -c "systemctl --user show bounded-run-acrms$$.scope -p RuntimeMaxUSec" 2>&1 || true)"
assert_contains "${rms}" "RuntimeMaxUSec=12s" "the scope carries RuntimeMaxSec = timeout + 10 (12 s for -T 2)"
rms="$("${BR}" -q -n "acrms0$$" -- bash -c "systemctl --user show bounded-run-acrms0$$.scope -p RuntimeMaxUSec" 2>&1 || true)"
assert_contains "${rms}" "RuntimeMaxUSec=infinity" "no timeout => no RuntimeMaxSec"
# kill the wrapper AND its watchdog (both ours, found by cmdline): only the scope's own RuntimeMaxSec can still end the command
"${BR}" -q -T 2 -n "acwd$$" -- /usr/bin/sleep 60 >/dev/null 2>&1 &
wp=$!
for _ in $(seq 1 50); do systemctl --user is-active "bounded-run-acwd$$.scope" >/dev/null 2>&1 && break; sleep 0.1; done
wcmd="$(/usr/bin/tr '\0' ' ' <"/proc/${wp}/cmdline")"
for c in $(cat "/proc/${wp}/task/${wp}/children" 2>/dev/null); do
  [[ "$(/usr/bin/tr '\0' ' ' <"/proc/${c}/cmdline" 2>/dev/null)" == "${wcmd}" ]] && kill -KILL "${c}" 2>/dev/null   # our own watchdog subshell
done
kill -KILL "${wp}" 2>/dev/null || true
wait "${wp}" 2>/dev/null || true
start=$SECONDS
for _ in $(seq 1 30); do [[ "$(scope_gone "acwd$$")" == yes ]] && break; sleep 1; done
took=$((SECONDS - start))
assert_eq "yes" "$(scope_gone "acwd$$")" "wrapper and watchdog killed: the scope still ends by itself via RuntimeMaxSec (after ${took}s more)"
systemctl --user kill --kill-whom=all --signal=SIGKILL "bounded-run-acwd$$.scope" 2>/dev/null || true
test_finish
