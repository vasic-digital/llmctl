#!/usr/bin/env bash
# test_no_lock_fd_leak.sh - class guard: a test that runs under a host lock (`flock <lockfile> cmd`) must not leave orphans
# that inherited the lock's open file description, and the scheduler lock wait must be bounded.
#
# Real incident (2026-10-22): the shared heavy lock stayed held for hours because (1) background `flock -x N` waiters of
# scheduler::with_lock blocked forever on a lock file in a deleted state dir, and (2) orphaned python http.server fixtures,
# all carrying an fd to the host lock inherited from the wrapper. This test drives the REAL helpers (tests/helpers.sh,
# lib/scheduler.sh) in a child that runs under a throw-away lock and asserts, after that child is gone:
#   A. no process holds an fd to the throw-away lock (scan of /proc/*/fd), and the lock is acquirable at once;
#   B. a scheduler::with_lock waiter on a held scheduler lock gave up on its own (LLMCTL_SCHED_LOCK_WAIT) instead of blocking forever.
# Override LLMCTL_FDLEAK_TREE=<dir with lib/ and tests/helpers.sh> to run the same drive against another tree (RED proof).
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${TESTS_DIR}/helpers.sh"

TREE="${LLMCTL_FDLEAK_TREE:-${LLMCTL_ROOT}}"
# canonical path: the /proc scan matches fd symlink targets by `find -lname`, which compares the literal path (a TMPDIR with `..` or a symlink would make the scan blind)
BASE="$(realpath "${LLMCTL_FDLEAK_TMPBASE:-${TMPDIR:-/tmp}}")"
W="$(mktemp -d "${BASE}/fdleak.XXXXXX")"
PIDF="${W}/pids"; : > "${PIDF}"
LOCK="${W}/host.lock"; : > "${LOCK}"
# kill ONLY the pids this test recorded (never a pattern match)
_cleanup() { local p; while read -r p; do [[ -n "${p}" ]] && kill "${p}" 2>/dev/null || true; done < "${PIDF}"; rm -rf "${W}"; }
trap _cleanup EXIT

# the inner "test": what a real suite does - source helpers, start a fixture server, hold the scheduler lock in the background,
# start a scheduler waiter - then exits WITHOUT cleaning up (an orphan-producing test).
cat > "${W}/inner.sh" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
TREE="$1"; W="$2"
source "${TREE}/tests/helpers.sh"
export LLMCTL_ROOT="${TREE}"
export LLMCTL_RUNTIME_DIR="${W}/run" LLMCTL_STATE_DIR="${W}/state" LLMCTL_CONFIG_DIR="${W}/cfg" LLMCTL_DATA_DIR="${W}/data" LLMCTL_LOG_DIR="${W}/log"
mkdir -p "${LLMCTL_RUNTIME_DIR}"
python3 -c 'import sys, http.server; http.server.HTTPServer(("127.0.0.1", 0), http.server.BaseHTTPRequestHandler).serve_forever()' >/dev/null 2>&1 &
echo $! >> "${W}/pids"
# hold the lock on fd 9 and exec into the sleep, so the recorded pid IS the lock holder (`flock file sleep 60 &` records
# the flock pid; killing it orphans its child sleep, which kept the scheduler lock for the rest of the minute)
( exec 9>>"${LLMCTL_RUNTIME_DIR}/.scheduler.lock"; flock -x 9; exec sleep 60 ) >/dev/null 2>&1 &
echo $! >> "${W}/pids"
sleep 0.5
LLMCTL_SCHED_LOCK_WAIT=2 bash -c 'source "$1/lib/common.sh"; source "$1/lib/scheduler.sh"; scheduler::with_lock true' _ "${TREE}" >/dev/null 2>&1 &
echo $! >> "${W}/pids"; echo $! > "${W}/waiter.pid"
exit 0
INNER

# run the inner test under the throw-away lock, exactly as the host wrapper does (fd inherited by every child)
timeout 60 flock "${LOCK}" bash "${W}/inner.sh" "${TREE}" "${W}"
echo "  ok: inner test finished under the throw-away lock"

# --- A: nobody holds the throw-away lock -----------------------------------------------------------------------------------
sleep 1
_holders() { # pid(cmdline) of every process with an fd to $1 - one find process, not thousands of readlink forks
  local l pid out=""
  while IFS= read -r l; do pid="${l#/proc/}"; pid="${pid%%/*}"; out+="${pid}($(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | cut -c1-60)) "; done < <(find /proc/[0-9]*/fd -maxdepth 1 -lname "$1" 2>/dev/null || true)
  printf '%s' "${out}"
}
holders="$(_holders "${LOCK}")"
assert_eq "" "${holders}" "A: no process holds an fd to the throw-away lock after the test exited"
if flock -n "${LOCK}" true; then echo "  ok: A: the throw-away lock is acquirable immediately"; else printf '  FAIL: A: the throw-away lock is still held\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi

# --- B: the scheduler waiter gave up by itself (2 s budget; 1 s already elapsed + inner sleeps) -------------------------------
sleep 3
wp="$(cat "${W}/waiter.pid")"
if kill -0 "${wp}" 2>/dev/null; then printf '  FAIL: B: scheduler::with_lock waiter %s is still blocked after its wait budget (unbounded flock)\n' "${wp}" >&2; TEST_FAILS=$((TEST_FAILS+1)); else echo "  ok: B: the scheduler waiter exited on its own within LLMCTL_SCHED_LOCK_WAIT"; fi

# control needle: the instrument CAN see a holder (a known holder is found, a fabricated path is not)
( exec 7>>"${LOCK}"; exec sleep 3 ) & echo $! >> "${PIDF}"; sleep 0.5
seen="$(_holders "${LOCK}")"
if [[ -n "${seen}" ]]; then echo "  ok: control needle: the /proc scan finds a known holder of the lock"; else printf '  FAIL: control needle: scan blind\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
ghost="$(_holders "${W}/no-such-lock")"
assert_eq "" "${ghost}" "control needle: the /proc scan does not find a fabricated path"

test_finish
