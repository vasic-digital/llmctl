## Overview

`tests/test_scheduler_lock.sh` proves that `scheduler::with_lock` (in
`lib/scheduler.sh`) genuinely serializes concurrent access to scheduler
state via an advisory `flock`, so that two racing `llmctl` invocations
never lose an update to shared state (Constitution FR-043,
Clarification 13: "a second concurrent invocation waits for the lock,
then re-reads state, then proceeds"). It is the mutual-exclusion
correctness proof that `docs/architecture.md`'s scheduler-state section
cites directly ("proven by `tests/test_scheduler_lock.sh`: 200
concurrent increments lose zero updates").

## Prerequisites

* Sources `tests/helpers.sh` for assertion helpers and
  `test_setup_env`/`test_finish`.
* Sources `lib/scheduler.sh` directly to get `scheduler::with_lock` into
  the test's own shell.
* Relies on `test_setup_env`'s isolated `LLMCTL_RUNTIME_DIR` (under a
  fresh `mktemp -d`) as the location for its scratch state files
  (`counter.txt`, `order.log`) — never touches real scheduler state.
* Requires real background-process support from the shell
  (`&`/`wait`/`$!`) since the test's whole point is racing two actual
  concurrent subshells against the same file.
* Requires `flock` semantics to be available to `scheduler::with_lock`
  (the function under test), and `sleep` (used to force a deterministic
  hold-then-wait ordering in the second assertion).

## Usage examples

```bash
bash tests/test_scheduler_lock.sh
```

Also runs as part of the full suite via `tests/run_tests.sh` or
`make test`.

## Edge cases

* **No lost updates under real concurrency**: two background functions
  (`increment_n_times`, run once as `pid_a` and once as `pid_b`) each
  perform 100 read-increment-write cycles against the *same* shared
  counter file, each cycle wrapped in `scheduler::with_lock _do_increment`.
  Without correct mutual exclusion this is a classic check-then-act race
  that loses updates and lands below `200`; the test asserts the final
  counter value is exactly `200` — zero lost updates across 200 truly
  concurrent, lock-serialized increments.
* **Second acquirer genuinely waits, not just "happens to end up
  correct"**: a first `scheduler::with_lock` call holds the lock for
  ~0.5s (writing `"A-start"` then, after a `sleep 0.5`, `"A-end"` to an
  order-log file) while running in the background; after a short
  `sleep 0.1` (to let A actually acquire the lock first), a second,
  foreground `scheduler::with_lock` call writes `"B-start"` to the same
  log. The test asserts the log's exact recorded order is
  `A-start,A-end,B-start,` — proving the second acquirer was made to
  *wait* for the first to fully release the lock before proceeding,
  rather than merely producing a coincidentally-correct final count (the
  first assertion alone would not distinguish "genuinely serialized" from
  "got lucky on scheduling").

## Internal behaviour

1. `set -euo pipefail`; source `tests/helpers.sh`; `test_setup_env`.
2. Source `lib/scheduler.sh` to get `scheduler::with_lock`.
3. Initialize `counter_file="${LLMCTL_RUNTIME_DIR}/counter.txt"` to `0`.
4. Define `_do_increment()`: read the counter, add 1, write it back
   (deliberately non-atomic on its own — the read-modify-write race this
   test exists to close).
5. Define `increment_n_times()`: loop 100 times calling
   `scheduler::with_lock _do_increment`.
6. Launch `increment_n_times` twice in the background (`pid_a`, `pid_b`),
   `wait` for both.
7. Read the final counter value and assert it equals `200`.
8. Set up `lock_marker="${LLMCTL_RUNTIME_DIR}/order.log"` (truncated).
   Launch a `scheduler::with_lock bash -c '...'` in the background that
   writes `"A-start"`, sleeps 0.5s, then writes `"A-end"`; capture its
   PID as `holder_pid`.
9. `sleep 0.1` to let A acquire the lock first, then run a second,
   foreground `scheduler::with_lock bash -c 'echo "B-start" >> ...'`.
10. `wait "${holder_pid}"`, read back the log file (newline-joined into a
    comma-separated string), and assert it equals
    `"A-start,A-end,B-start,"`.
11. `test_finish` tears down the temp environment and exits non-zero iff
    any assertion failed.

## Related scripts

* Sources `tests/helpers.sh` (sibling, documented separately).
* Exercises `lib/scheduler.sh`'s `scheduler::with_lock` function — the
  same locking primitive underlying `sched_start`, `sched_stop`,
  `sched_auto`, and `sched_enable` (each defined as
  `scheduler::with_lock _*_impl` in `lib/scheduler.sh`), which are in
  turn exercised at a higher, CLI-facing level by
  `tests/test_scheduler.sh`.
* Cited directly by `docs/architecture.md`'s "Scheduler state" section as
  the proof of the project's concurrent-invocation safety claim.
* Discovered and run automatically by `tests/run_tests.sh`; syntax and
  shebang/strict-mode covered by `tests/test_syntax.sh`.

## Last verified date

2026-09-17
