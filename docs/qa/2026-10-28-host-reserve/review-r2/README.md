# Host reserve 3.4.0: review round 2 evidence

| Field | Value |
|---|---|
| Revision | 1 |
| Created | 2026-10-29 |
| Reviewed commit | be0707d (independent review: NO-GO, round 2) |
| Host | 16 CPUs (SMT pairs i, i+8), about 31 GiB; load1 2.4-3.0 during the live runs, 2.4-8.6 during the suites |

## What was fixed

- **F1 (HIGH).** A profile's verdict is `running` only when the exact unit instance being started is up: tenant key plus primary name, `${LLMCTL_TENANT_ID}--<profile>` with a tenant. Other instances (`decide-tiny.2`) and other tenants (`t1--decide-tiny`) count as consumption, never as "already running". A restart or scale of a named profile is always judged as a new start. That includes restarting instance 2 while the primary runs. `docs/capacity.md` now describes this rule; the old line 131 is rewritten.
- **F2 (MEDIUM).** Every hardware or plan probe has a time limit: `LLMCTL_CAPACITY_PROBE_TIMEOUT`, default 3 s, clamped to 1..30 and never above the whole bound. The whole measurement also has one: `LLMCTL_CAPACITY_TIMEOUT`, default 5 s, clamped to 2..30. When a limit runs out, the probe's process tree is stopped and killed. Only processes whose start time still matches are signalled. A timeout or a failed measurement gives the verdict `undetermined`, exit 75, and `llmctl-fallback: cloud|none`. It never gives `local`.
- **F3 (tests).** The reviewer's surviving mutants M03, M04/M16, M05, M06/M07, M20 and M21 now have tests that drive the real code paths.
- **F4 (vocabulary).**
  - `undetermined` is a new verdict.
  - Two new fields are added: `verdict_class` (`fits|fits_reduced|does_not_fit|undetermined`) and the fallback `route` (`local|hosted|none`).
  - `measurement` and `running` are added as well.
  - The schema stays `llmctl.capacity/1`; every change is additive.
  - The mapping table is in `docs/capacity.md` and in the CHANGELOG.
- **F5.** `_sched_base_profile` uses the same mapping as `reserve_base_profile` and the Python `base_profile`. It checks the full name first and strips the tenant prefix.
- **F6.** A plan or probe failure no longer says "not a catalog profile". The CHANGELOG states plainly that a host with less than about 4.6 GiB of RAM refuses every local start.

## Evidence

| File | What it shows | Class |
|---|---|---|
| `red-on-be0707d.log` | `tests/test_host_reserve_review2.sh` run on `git archive be0707d`: 31 assertion failures, plus Python errors where the F4 fields do not exist (the RED baseline) | unit (hermetic fixtures) |
| `green-review.log`, `green-review2.log` | the round-1 and round-2 review suites on the final tree: 66 and 75 `ok`, `RESULT: PASS` | unit |
| `suites/summary.txt`, `suites/*.log` | 66 suites, run one at a time on 2 CPUs (`taskset -c 0,1`, nice 10, 900 s limit). 64 pass. `test_livetest_watchdog` and `test_validation_mutants` hit the 900 s limit (rc 124) with 0 failed assertions logged, the same as on 3.3.2 and in round 1 | unit / integration |
| `../mutants.json`, `../mutants.log` | 53 paired mutants. The control is GREEN, and every mutant is killed by a named failing assertion | unit |
| `live-fixed/`, `live-fixed.log` | the final tree, with the real `llama-server`, the real `decide-tiny` model and real transient user units. Values were read back from `/sys/fs/cgroup` and `/proc`, over 3 runs | **live** |
| `live-prefix-3.3.2/`, `live-prefix.log` | the 3.3.2 tree (`git archive 11a9154`), as the negative control, over 3 runs | **live** |

## Mutants added in this round

There are 23 `R2-*` mutants:

- **Reviewer's survivors (F3):** M03, M04, M05, M06, M07, M10, M16, M20, M21, M22.
- **F1:** running decided by the base profile; tenant key ignored.
- **F2:** no probe bound; no whole bound; process tree not killed; probe ceiling loosened; `undetermined` admitted; exit code ignores the measurement; CLI prints no fallback line.
- **F4:** the `verdict_class` map; a route of `cloud` instead of `hosted`.
- **F5:** no tenant strip; instance suffix checked before the full name.
- **F6:** a plan failure reported as `unknown`.

One round-1 mutant, `R-restart-same-profile-treated-running`, survived the first sweep of this round. The restart of the primary drops the replaced unit from the unit set, so for that case the guard was redundant. The guard matters only when the restarted instance is not the primary. A new test now covers that case:

- the test restarts `decide-tiny.2` while `decide-tiny` and another unit hold the budget, and expects 75;
- a negative control does the same restart with room left and expects it to be admitted.

The test fails on the mutant and passes on the real tree. In the final sweep the mutant is killed.

## Live readback (decide-tiny, 3 runs each)

| Reading | 3.4.0 final tree (all 3 runs) | 3.3.2 control (all 3 runs) |
|---|---|---|
| `cpu.max` | `300000 100000` (3 CPUs) | `max 100000` |
| `Cpus_allowed_list`, every thread | `2-7,10-15` | `0-15` |
| `--threads` in argv | `--threads 3` (+ `OMP_NUM_THREADS=3`) | none (31 threads) |
| nice / `oom_score_adj` | 15 / 800 | 10 / 500 |
| `cpu.weight` / `memory.swap.max` | 20 / 0 | 50 / 0 |
| stress, 4 parallel loops, about 28 s | 293.1-294.2 % CPU, `nr_throttled` +62..71, never on CPUs 0, 1, 8, 9 | not loaded (an unlimited engine would take the host) |
| second start, over budget | rc **75**, `llmctl-fallback: cloud`, no new unit, engine process or env record | rc **0**, admitted, env record written |
| leftovers after both runs | no `llmctl-qa*` unit and no `decide-tiny` engine process | same |

- **Final tree:** `deterministic_limits=True`, `deterministic_verdicts=True` and `all_checks_true=True` held in all 3 runs.
- **Control:** `all_checks_true=False` in all 3 runs. That is the expected RED.

## Honest notes (§11.4.6)

- The CPU-pressure case was skipped in all 3 runs with an honest SKIP. The harness runs it only when the live CPU PSI `some avg10` is at least 4, and the measured values were 1.26, 0.51 and 0.05. Pressure refusal is covered by unit-class tests only in this round.
- The live harness starts transient `llmctl-qa-reserve-*` units. Several paths are covered by unit-class tests only:
  - the F1 instance and tenant cases;
  - the F2 time bounds (a sleeping fake probe and a FIFO that never answers);
  - the `restart` and `decide scale` admission paths.

  No operator unit was restarted or scaled live, and no real `nvidia-smi` was hung.
- The F2 budgets (5 s whole, 3 s per probe) are defaults chosen to be well above a normal measurement on this host. They are not measured on other hosts.
