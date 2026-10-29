# Host reserve 3.4.0: review round 1 evidence

| Field | Value |
|---|---|
| Revision | 1 |
| Created | 2026-10-29 |
| Reviewed commit | cb6adb8 (independent review: NO-GO, round 1) |
| Host | 16 CPUs (SMT pairs i, i+8), about 31 GiB; load1 6.8-8.2 during the live runs |

## What was fixed

The review raised these findings, and each is fixed:

- Source: S1 to S7.
- Tests: M01, M02, M03/M09, M06, M10/M11, M18, M21, M22, and M15-M17/S8 (the Go code was removed).
- Docs: D1 to D4.

The CHANGELOG entry for 3.4.0 and `docs/capacity.md` (revision 2) describe the new behaviour.

## Evidence

| File | What it shows | Class |
|---|---|---|
| `red-on-cb6adb8.log` | `tests/test_host_reserve_review.sh` run on `git archive cb6adb8`: 33 assertion failures (the RED baseline) | unit (hermetic fixtures) |
| `suites/summary.txt`, `suites/summary2.txt`, `suites/*.log` | 64 suites, run one at a time on 2 CPUs (`taskset -c 0,1`, nice 10). 62 pass. `test_livetest_watchdog` and `test_validation_mutants` hit the 900 s timeout (rc 124) with 0 failures logged, the same as on 3.3.2 (see `../README.md`) | unit / integration |
| `../mutants.json`, `../mutants.log` | 29 paired mutants: M1-M13 without M11 (12), plus 17 R-* mutants. Control is GREEN and all 29 are killed; each one is killed by a named failing assertion | unit |
| `live-fixed/`, `live-fixed.log` | 3.4.0 with the fixes. Real `llama-server`, the real `decide-tiny` model and real transient user units. Values were read back from `/sys/fs/cgroup` and `/proc`, over 3 runs | **live** |
| `live-prefix-3.3.2/`, `live-prefix.log` | the 3.3.2 tree (`git archive 11a9154`), as the negative control, over 3 runs | **live** |

## Live readback (decide-tiny, 3 runs each)

| Reading | 3.4.0 fixed (all 3 runs) | 3.3.2 control (all 3 runs) |
|---|---|---|
| `cpu.max` | `300000 100000` (3 CPUs) | `max 100000` |
| `Cpus_allowed_list`, every thread | `2-7,10-15` | `0-15` |
| `--threads` in argv | `--threads 3` (+ `OMP_NUM_THREADS=3`) | none (31 threads) |
| nice | 15 | 10 |
| `oom_score_adj` | 800 | 500 |
| `cpu.weight` / `memory.swap.max` | 20 / 0 | - / 0 |
| stress, 4 parallel loops, about 33 s | 284-287% CPU, `nr_throttled` +35..40, never on CPUs 0, 1, 8, 9 | not loaded (an unlimited engine would take the host) |
| second start, over budget | rc **75**, `llmctl-fallback: cloud`, no new unit, engine process or env record | rc **0**, admitted, env record written |
| leftovers | none | none |

In the fixed tree, `deterministic_limits=True` and `all_checks_true=True` held in all 3 runs. In the control, `all_checks_true=False` in all 3 runs. That is the expected RED.

## Honest notes (§11.4.6)

- **The fixed run's verdict sets differ between runs, which is why its summary says `deterministic_verdicts=False`.**
  - Why: the harness runs its CPU-pressure case only when the live CPU PSI `some avg10` is at least 4, because it uses a quarter of the live value as the threshold. The live value was 4.64 in run 2, and 2.73 and 2.10 in runs 1 and 3.
  - Run 2 ran the case. Capacity reported the pressure, the QA unit was `degraded` with the suggestion `llmctl stop ...`, the profile verdict was `does_not_fit`, the fallback was `cloud`, and the exit code was 75.
  - Runs 1 and 3 recorded an honest SKIP.
  - Every check that ran was true in every run. The difference comes from the host's load, not from llmctl.
- The live harness starts the engine as transient `llmctl-qa-reserve-*` units. The `restart` and `decide scale` admission paths are covered by unit-class tests only (`tests/test_host_reserve_review.sh`); no operator unit was restarted or scaled live.
