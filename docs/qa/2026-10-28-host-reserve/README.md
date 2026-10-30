# Host reserve and capacity gate (llmctl 3.4.0): live evidence

| Field | Value |
|---|---|
| Run date | 2026-10-28 (live runs 21:25-21:34 UTC) |
| Host | 16 CPUs (SMT siblings i and i+8), MemTotal 30974 MiB, cgroup v2 with cpu, memory and pids delegated (no cpuset) |
| Code | the 3.4.0 working tree on top of `11a9154` (3.3.2); the commit that carries this directory |
| Harness | `scripts/qa/host_reserve_live.sh`, `scripts/qa/host_reserve_mutants.py`, `scripts/qa/start_latency.sh` |

Point-in-time record of real runs on one host, not a promise about other hosts.

## What was run

`scripts/qa/host_reserve_live.sh <tree> <out> <label> 3` starts the real `decide-tiny` model with the real `llama-server`, as a transient
systemd user unit rendered by llmctl's own unit-rendering code, three times. Per run it:

1. reads the unit's limits back from `/sys/fs/cgroup/.../cpu.max`, `cpu.weight`, `memory.max`, `memory.high`, `memory.swap.max`, and the engine
   process from `/proc/<pid>` (`nice`, `oom_score_adj`, `Cpus_allowed_list` of every thread, argv, `OMP_NUM_THREADS`);
2. runs 4 parallel completion loops against the model for about 40 s and measures its CPU use (`cpu.stat` `usage_usec`) and the CPU every
   engine thread last ran on;
3. starts a CPU filler unit, then runs `llmctl start decide-tiny` again (dry run) with a hosted-key variable present. The harness records
   whether that start reached admission (`reached_admission`), its exit code and the `llmctl-fallback:` line, and checks that no unit,
   engine process or env record appeared;
4. runs `llmctl capacity --json` with the CPU PSI gate set just below the live CPU PSI reading (simulated pressure on real `/proc/pressure`
   values) and records the running unit's verdict;
5. stops everything and checks that nothing is left.

The harness isolates llmctl's state, runtime, unit and data directories under its own `mktemp -d` directory.

## Results (polarity)

| Label | Tree | Runs | all checks | deterministic | Key read-back |
|---|---|---|---|---|---|
| `fixed/` | 3.4.0 | 3 | **true** | limits and verdicts | `cpu.max 300000 100000`, CPUs `2-7,10-15` on every thread, `--threads 3`, nice 15, oom 800, stress 238-268% CPU never on CPUs 0,1,8,9; second start reached admission, **rc 75** + `llmctl-fallback: cloud`, no new unit/process/env record; pressure: unit `degraded`, rc 75 |
| `reserve-off/` | 3.4.0 with `LLMCTL_HOST_RESERVE=0` | 3 | false (RED, as expected) | limits and verdicts | `cpu.max max`, CPUs `0-15`, no `--threads` (31 threads), nice 10, oom 500; second start reached admission and was **admitted (rc 0)**, env record written |
| `prefix/` | 3.3.2 (`git archive 11a9154`) | 3 | false (RED, as expected) | limits and verdicts | same as `reserve-off` |

`summary.json` in each directory holds the per-run values and the named checks; `harness.log` the timeline; `run-N/` the raw files.

The negative controls skip the stress step by design: an unlimited engine would take the shared host. Their RED is the limits read-back
and the admitted second start.

`prefix-unit-red/`: the 3.3.2 tree with the 3.4.0 unit tests copied in. The tests fail with rc 127 (`command not found`), which shows only
that the code is absent; the behavioural RED of 3.3.2 is `prefix/`.

## Harness defects found and fixed during this work

- **Runtime directory not isolated.** The first harness version left `LLMCTL_RUNTIME_DIR` at its default `${XDG_RUNTIME_DIR}/llmctl`, the
  operator's real one. An admitted dry-run start (a negative control) wrote `decide-tiny.run` there, so every later start of `decide-tiny`
  answered "already running" and never reached admission; earlier negative-control and one positive run were invalid for that reason. The
  stray file was created by this harness (same content as a reproduced dry-run start, written 8 s after the `reserve-off` run 1 second
  start) and was removed. The harness now isolates the runtime directory, clears its own reservation and env record after each second
  start, and records `reached_admission` as a precondition check. All three labels were re-run after the fix; the runs above are those.
- A dry-run `llmctl start` that is admitted writes a reservation file. This is unchanged 3.3.x behaviour and is listed as a known limitation in
  the CHANGELOG.

## Mutation check (`mutants.json`, `mutants.log`)

13 paired mutants, each applied to a fresh copy of the tree. The unmutated copy passes first (control GREEN), and every mutant turns its suite
RED: **13/13 killed**. They cover: CPU quota, CPU reserve floor, combined CPU budget check, gate clamp, OOM score, admission bypass,
hosted-key value leak, no-CPU-left check, memory reserve floor, `--threads`, the Go decision cap, and the two memo keys (topology, catalog
content). The suites are unit-class (hermetic fixtures); the live counterpart is the polarity table above.

## Start latency (`start-latency.txt`)

`scripts/qa/start_latency.sh`: 5 alternating dry-run `llmctl start small` per tree, 2 CPUs, host load about 13. Mean 3396 ms on 3.4.0
against 2560 ms on 3.3.2 (+0.84 s for the reserve and capacity checks). An earlier draft measured 8.5 s, because the catalog was read per profile;
that was fixed with one catalog read and memoisation. The paths in the file are the clone (3.4.0) and the extracted 3.3.2 tree.

## Test-suite notes (`suite/`)

Every `tests/test_*.sh` suite was run on its own, 2 CPUs, 900 s limit each (`suite/full-run-3.4.0-draft.tsv`): 179 of 187 passed. The
8 others, each classified against an unmodified 3.3.2 checkout (`git clone --no-recurse-submodules` at `11a9154`, same host, same limits):

| Suite | 3.4.0 draft | 3.3.2 | Verdict |
|---|---|---|---|
| `test_syntax.sh` | FAIL: `lib/reserve.sh`, `lib/capacity.sh` lacked `set -euo pipefail` | n/a (new files) | fixed in 3.4.0, now PASS |
| `test_services.sh` | FAIL: template `MemoryMax=27852M` expected | PASS | test updated: with the host reserve on, the template MemoryMax is `min(85% of RAM, RAM - reserve)` = 26215M on the 32 GiB fixture; a reserve-off install still asserts 27852M; now PASS |
| `test_scheduler.sh` | FAIL: `auto coder vision` refused (24576 + 6553 > 30720 MiB) | PASS | the section's abundant 256 GiB fixture reached only the planner, not the live memory gate (hermetic 32 GiB meminfo); the section now writes the matching meminfo; the 20% reserve itself is intended; now PASS |
| `test_setup_e2e.sh` | FAIL: 2 (`submodules/llama.cpp`, `colibri` not initialised) | same 2 FAIL | environmental: the clone has no initialised submodules |
| `test_matrix_harness.sh` | FAIL: 4 Chromium cells, adapter exit 13 | same 4 cells | environmental (Chromium adapter on this host) |
| `test_livetest_watchdog.sh` | rc 124 at 900 s, 328 PASS / 0 FAIL | rc 124 at 900 s, 328 PASS / 0 FAIL | runtime limit, identical |
| `test_decide_security_mutation.sh` | rc 124 at 900 s, 18 killed / 0 survived | same | runtime limit, identical |
| `test_validation_mutants.sh` | 900 s run: rc 124; with a 1800 s limit: PASS, 68/68 mutants caught, 1207 s | PASS, 68/68 mutants caught, 1129 s (beyond the 900 s limit too) | runtime limit, identical result. In the 900 s run the test shell did not exit after `timeout`'s TERM: it spun at 100% CPU in its EXIT trap with an unreaped `rm` child and was stopped with SIGKILL after 1810 s (`test_validation_mutants.3.4.0-900s-killed.log`). Cause UNCONFIRMED (no ptrace allowed); it is in the test harness after an external TERM, not in llmctl code; seen once |

`*.3.4.0-draft.log` are the failing runs, `*.3.4.0-fixed.log` the runs after the fix, `*.3.3.2.log` the baseline. Paths in the logs
are normalised to `<home>`, `<tmp>`, `<scratch>`.

## Limits of this evidence

- One host and one model (`decide-tiny`). macOS/launchd and hosts with a delegated `cpuset` controller were not run.
- The engine ran as transient `llmctl-qa-reserve-*` units counted through `LLMCTL_RESERVE_EXTRA_UNIT_GLOB`, not as the installed
  `llmctl-llama@` template (same rendering code).
- The pressure case lowers the threshold to the live reading; it does not create real memory or CPU starvation.
- Manual QA has not been done.

## Review round 1

The evidence for the fixes made after the independent review of cb6adb8 (NO-GO) is in [`review-r1/`](review-r1/README.md).

## Later review rounds (index)

Each round's evidence, newest last. Rounds 2 to 5 are linked here so every record is reachable from the main README (§11.4.212).

- Round 2: [`review-r2/`](review-r2/README.md)
- Round 3: [`review-r3/`](review-r3/README.md)
- Round 4: [`review-r4/`](review-r4/README.md)
- Round 5: [`review-r5/`](review-r5/README.md)
- Round 7 (no `review-r6/` directory exists): [`review-r7/`](review-r7/README.md)
