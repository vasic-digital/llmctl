#!/usr/bin/env bash
# test_validation_lock_orphans.sh - RED-first. A validator that waits for the per-profile validation lock
# (lib/validate.sh: _val_with_profile_lock and validate_after_start) ran `flock -w 900 <fd>` as a FOREGROUND child. When
# the waiting llmctl process was killed (SIGKILL: no trap can run; SIGTERM: bash defers the trap until the foreground
# flock child returns, up to 900 s; or no trap at all in the manual path), the `flock -w 900` child was ORPHANED and
# lingered for the whole wait budget, holding nothing but still being a stray process of the suite (and, after the lock
# file is replaced, queuing on a dead inode). Contract: the waiter must not outlive its parent by more than ~2 s, and a
# TERM to the waiting llmctl must take effect promptly. This test drives the REAL entry points (bin/llmctl validate and
# validate-after-start) with the DEFAULT 900 s wait, kills the waiting llmctl, and asserts the flock child is gone.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source "$(dirname "${BASH_SOURCE[0]}")/gate_wiring_lib.sh"
test_setup_env
HOLDER_PID=""
cleanup() {
  # only processes THIS test started, each re-verified by its /proc cmdline before it is signalled
  local p c
  for p in ${HOLDER_PID:-} ${TRACK_PIDS[@]+"${TRACK_PIDS[@]}"}; do
    [[ "${p}" =~ ^[0-9]+$ && "${p}" -gt 1 ]] || continue
    c="$(tr '\0' ' ' 2>/dev/null < "/proc/${p}/cmdline" || true)"
    [[ "${c}" == *"${TEST_TMP}"* || "${c}" == *"flock -w 10 -x 9"* || "${c}" == "sleep "* || "${c}" == *"flock -w"* ]] && kill "${p}" 2>/dev/null || true
  done
  gw_cleanup_bg; test_teardown_env
}
TRACK_PIDS=()
trap cleanup EXIT
gw_init
L="${GW_LLMCTL}"
FAKEBIN="${TEST_TMP}/fakebin"; mkdir -p "${FAKEBIN}"
printf '#!/usr/bin/env bash\nexit 0\n' > "${FAKEBIN}/systemctl"; chmod +x "${FAKEBIN}/systemctl"
export PATH="${FAKEBIN}:${PATH}"
GW_HTTP_FIXED_PORT=0 gw_http_server "${TEST_TMP}/ready.req"; PORT="${GW_HTTP_PORT}"
gw_mark_running small "${PORT}"
export LLMCTL_ROOT="${GW_TREE}" GW_VALIDATE_SLEEP=0 GW_VALIDATE_RC=0
LOCKF="${LLMCTL_RUNTIME_DIR}/.validate-small.lock"
ensure_dir() { mkdir -p "$1"; }
mkdir -p "${LLMCTL_RUNTIME_DIR}"

# hold the lock from a process that is NOT a child of the waiter
hold_lock() {
  ( exec 9>"${LOCKF}"; flock -w 10 -x 9 || exit 1; exec sleep 120 ) &   # bounded: a failed hold can never queue forever
  HOLDER_PID=$!
  TRACK_PIDS+=("${HOLDER_PID}")
  local i; for (( i=0; i<50; i++ )); do
    [[ "$(tr '\0' ' ' 2>/dev/null < "/proc/${HOLDER_PID}/cmdline")" == "sleep 120 "* ]] && return 0; sleep 0.1
  done
  return 1
}
release_lock() { kill "${HOLDER_PID}" 2>/dev/null || true; wait "${HOLDER_PID}" 2>/dev/null || true; HOLDER_PID=""; }

# find_flock_child <parent pid> -> prints the pid of its `flock -w` child (waits up to 8 s)
find_flock_child() {
  local ppid_="$1" i k c
  for (( i=0; i<80; i++ )); do
    for k in $(ps -o pid= --ppid "${ppid_}" 2>/dev/null); do
      c="$(tr '\0' ' ' < "/proc/${k}/cmdline" 2>/dev/null || true)"
      [[ "${c}" == "flock -w "* ]] && { echo "${k}"; return 0; }
    done
    sleep 0.1
  done
  return 1
}
alive() { [[ -d "/proc/$1" ]] && [[ "$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)" != "Z" ]]; }
gone_within() { local p="$1" t="$2" i; for (( i=0; i<t*10; i++ )); do alive "${p}" || return 0; sleep 0.1; done; return 1; }

run_case() {   # <name> <signal> <llmctl args...>
  local name="$1" sig="$2" lp fp c ppid_after
  shift 2
  hold_lock || { echo "FAIL ${name}: could not take the validation lock"; release_lock; return 1; }
  "${L}" "$@" >"${TEST_TMP}/${name}.out" 2>&1 &
  lp=$!; TRACK_PIDS+=("${lp}")
  fp="$(find_flock_child "${lp}")" || { echo "FAIL ${name}: no flock child appeared"; kill -KILL "${lp}" 2>/dev/null || true; release_lock; return 1; }
  TRACK_PIDS+=("${fp}")
  c="$(tr '\0' ' ' < "/proc/${fp}/cmdline")"
  echo "${name}: waiter llmctl pid=${lp} flock pid=${fp} cmdline='${c}' lock=${LOCKF}"
  kill "-${sig}" "${lp}"
  if [[ "${sig}" == "KILL" ]]; then wait "${lp}" 2>/dev/null || true; else gone_within "${lp}" 5 || { echo "${name}: llmctl pid ${lp} still alive 5 s after SIG${sig}"; kill -KILL "${lp}" 2>/dev/null || true; release_lock; return 1; }; fi
  if gone_within "${fp}" 3; then echo "${name}: flock waiter ${fp} gone within 3 s of the kill: OK"; return 0; fi
  ppid_after="$(awk '{print $4}' "/proc/${fp}/stat" 2>/dev/null)"
  echo "${name}: ORPHAN flock pid=${fp} ppid_now=${ppid_after} cmdline='$(tr '\0' ' ' < "/proc/${fp}/cmdline")' lock_dir_exists=$([[ -d "${LLMCTL_RUNTIME_DIR}" ]] && echo yes || echo no)"
  kill "${fp}" 2>/dev/null || true    # our own, verified above by cmdline, never pgid<=1
  release_lock
  return 1
}

fails=0
for spec in "manual_kill:KILL:validate small" "manual_term:TERM:validate small" "after_start_kill:KILL:validate-after-start small" "after_start_term:TERM:validate-after-start small"; do
  IFS=: read -r nm sg args <<< "${spec}"
  # shellcheck disable=SC2086
  if run_case "${nm}" "${sg}" ${args}; then release_lock; else fails=$((fails+1)); HOLDER_PID=""; fi
done
assert_eq 0 "${fails}" "no flock waiter outlives its killed parent, and a TERMed llmctl exits within 5 s (${fails} case(s) failed)"

# --- lock_wait unit contract (lib/common.sh): rc 0 acquired, 1 timed out, >1 error / invalid budget, no arithmetic abort ---
LW="${TEST_TMP}/lw"; mkdir -p "${LW}"
lw_probe() {   # <budget> [hold 0|1] -> prints "rc=<n> secs=<n>"; runs in a child bash with the REAL lib/common.sh under set -euo pipefail
  local budget="$1" hold="${2:-1}" holder rcv t0 t1 out
  : > "${LW}/l"
  if [[ "${hold}" == 1 ]]; then ( exec 8>"${LW}/l"; flock -w 10 -x 8 || exit 1; exec sleep 12 ) & holder=$!; TRACK_PIDS+=("${holder}"); sleep 0.5; fi
  t0=${SECONDS}
  out="$(bash -c 'set -euo pipefail; source "$1"; exec 7>"$2"; lock_wait 7 "$3" -x; echo "after-rc=$?"' _ "${ROOT_DIR}/lib/common.sh" "${LW}/l" "${budget}" 2>&1)" && rcv=0 || rcv=$?
  t1=${SECONDS}
  [[ -n "${holder:-}" ]] && { kill "${holder}" 2>/dev/null || true; wait "${holder}" 2>/dev/null || true; }
  printf 'rc=%s secs=%s out=%s' "${rcv}" "$(( t1 - t0 ))" "${out//$'\n'/|}"
}
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
r="$(lw_probe 2 1)"; echo "lock_wait held, budget 2: ${r}"
assert_contains "${r}" "rc=1 " "lock_wait: a held lock times out with rc 1"
[[ "${r}" =~ secs=([0-9]+) ]] && { (( BASH_REMATCH[1] >= 2 && BASH_REMATCH[1] <= 5 )) && assert_eq ok ok "lock_wait waited the budget (${BASH_REMATCH[1]} s)" || assert_eq "2..5" "${BASH_REMATCH[1]}" "lock_wait waited about the budget"; }
r="$(lw_probe 5 0)"; echo "lock_wait free: ${r}"
assert_contains "${r}" "after-rc=0" "lock_wait: a free lock is acquired (rc 0)"
r="$(lw_probe 1.5 1)"; echo "lock_wait fractional: ${r}"
assert_contains "${r}" "rc=1 " "lock_wait: a fractional budget (1.5) is accepted and times out with rc 1, no arithmetic abort"
r="$(lw_probe abc 0)"; echo "lock_wait invalid: ${r}"
assert_contains "${r}" "invalid wait budget" "lock_wait: a non-numeric budget is refused with a clear message"
assert_contains "${r}" "rc=2 " "lock_wait: a non-numeric budget returns 2 (could not determine), not a shell abort"
r="$(bash -c 'set -euo pipefail; source "$1"; rc=0; lock_wait 99 5 -x || rc=$?; echo "bad-fd-rc=${rc}"' _ "${ROOT_DIR}/lib/common.sh" 2>&1)"; echo "lock_wait bad fd: ${r}"
[[ "${r}" =~ bad-fd-rc=([0-9]+) ]] && (( BASH_REMATCH[1] > 1 )) && assert_eq ok ok "lock_wait: a flock error (bad fd) is returned, not retried" || assert_eq ">1" "${r}" "lock_wait: a bad fd returns rc>1"

# --- class guard, PER INVOCATION: split every code line into simple-command segments (on ; || && |) and classify each segment that
# mentions flock. Allowed: lock_wait's own 1 s slice, and non-blocking/unlock forms (-n, -u). Anything else - including a blocking flock
# that shares a line with an allowed one (`flock -n 9 || flock 9`), or an indirectly named binary (`${FLOCK_BIN:-flock} 9`) - is stray.
flock_segments() { grep -rhE '(^|[^[:alnum:]_.])flock([^[:alnum:]_-]|$)' "$@" | grep -vE '^[[:space:]]*#' | sed -E 's/(\|\||&&|;|\||&)/\n/g' | sed -E 's/[[:space:]]#.*$//' | grep -E '(^|[^[:alnum:]_.])flock([^[:alnum:]_-]|$)' || true; }
flock_stray() { grep -vE '"\$@" -w "\$\{slice\}"|(^|[[:space:]])flock([[:space:]]+-[a-zA-Z]*)*[[:space:]]+-[a-zA-Z]*[nu][a-zA-Z]*([[:space:]]|$)' || true; }
all_seg="$(flock_segments "${ROOT_DIR}/lib" "${ROOT_DIR}/bin")"
assert_eq 1 "$(grep -c '"\$@" -w "\${slice}"' <<< "${all_seg}")" "control needle: the scan sees lock_wait's own flock slice segment"
assert_eq 1 "$(grep -c 'flock -u "\${lock_fd}"' <<< "${all_seg}")" "control needle: the scan sees a plain unlock segment"
assert_eq "" "$(flock_stray <<< "${all_seg}")" "no other flock invocation (blocking, mixed-line or indirect) remains in lib/ (each must go through lock_wait)"
mixed="$(printf '%s\n' '    flock -n 9 || flock 9 || exit 98' '    flock -u 9; flock -x 9 || exit 98' '    ${FLOCK_BIN:-flock} 9 || exit 98' '    flock -x 9   # cannot use flock -n here: must wait' '    flock -n 8 & flock -x 9 || exit 98' '    log_info "wait #1"; flock -x 9 || exit 98' > "${LW}/mixed.sh"; flock_segments "${LW}/mixed.sh" | flock_stray | wc -l)"
assert_eq 6 "${mixed}" "control needle: the classifier flags the blocking half of mixed lines, an indirect binary, a blocking flock hiding behind a comment that mentions -n, and an &-joined pair (6 stray segments; a # inside a quoted string earlier on the line must not hide a later flock)"
okf="$(printf '%s\n' '    flock -n 9 || exit 98' '    flock -x -n 9 || exit 98' '    flock -nx 9 || exit 98' '    flock -u 9' > "${LW}/ok.sh"; flock_segments "${LW}/ok.sh" | flock_stray | wc -l)"
assert_eq 0 "${okf}" "golden-false: non-blocking forms (-n, -x -n, -nx, -u) are NOT flagged"

# --- budget edge cases the unit contract promises ---
r="$(lw_probe 08 1)"; echo "lock_wait leading zero: ${r}"
assert_contains "${r}" "rc=1 " "lock_wait: a leading-zero budget (08) is decimal, times out with rc 1, no arithmetic abort"
[[ "${r}" =~ secs=([0-9]+) ]] && (( BASH_REMATCH[1] >= 8 )) && assert_eq ok ok "lock_wait: budget 08 waited 8 s (${BASH_REMATCH[1]} s)" || assert_eq ">=8" "${r}" "lock_wait: budget 08 waits 8 s"
r="$(lw_probe 1.5 1)"
[[ "${r}" =~ secs=([0-9]+) ]] && (( BASH_REMATCH[1] >= 2 )) && assert_eq ok ok "lock_wait: budget 1.5 is rounded UP (waited ${BASH_REMATCH[1]} s)" || assert_eq ">=2" "${r}" "lock_wait: budget 1.5 rounds up to 2 s"

test_finish
