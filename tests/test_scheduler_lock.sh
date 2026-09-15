#!/usr/bin/env bash
# test_scheduler_lock.sh - proves scheduler::with_lock serializes concurrent
# access to scheduler state: two racing writers must not lose updates.
# (Constitution FR-043, Clarification 13 - a second concurrent invocation
# waits for the lock, then re-reads state, then proceeds.)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

# shellcheck source=../lib/scheduler.sh
source "${LLMCTL_ROOT}/lib/scheduler.sh"

counter_file="${LLMCTL_RUNTIME_DIR}/counter.txt"
echo 0 > "${counter_file}"

_do_increment() {
  local n
  n="$(cat "${counter_file}")"
  n=$(( n + 1 ))
  echo "${n}" > "${counter_file}"
}

increment_n_times() {
  local i
  for (( i = 0; i < 100; i++ )); do
    scheduler::with_lock _do_increment
  done
}

# Two processes race 100 increments each. Without mutual exclusion around
# the read-modify-write, some increments are lost (classic check-then-act
# race) and the final count comes out below 200.
increment_n_times &
pid_a=$!
increment_n_times &
pid_b=$!
wait "${pid_a}"
wait "${pid_b}"

final="$(cat "${counter_file}")"
assert_eq 200 "${final}" "no lost updates across 200 concurrent flock-serialized increments"

# A second invocation trying to acquire an already-held lock must WAIT for
# release, not proceed immediately (proves mutual exclusion, not just a
# lucky race outcome above).
lock_marker="${LLMCTL_RUNTIME_DIR}/order.log"
: > "${lock_marker}"
scheduler::with_lock bash -c '
  echo "A-start" >> "'"${lock_marker}"'"
  sleep 0.5
  echo "A-end" >> "'"${lock_marker}"'"
' &
holder_pid=$!
sleep 0.1  # let A actually acquire the lock first
scheduler::with_lock bash -c 'echo "B-start" >> "'"${lock_marker}"'"'
wait "${holder_pid}"

order="$(cat "${lock_marker}" | tr '\n' ',' )"
assert_eq "A-start,A-end,B-start," "${order}" "second acquirer waits for the first to release before proceeding"

test_finish
