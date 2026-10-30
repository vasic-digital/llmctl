# Review round 7 record (host reserve, llmctl 3.4.0)

This directory is the evidence for the round-7 review of `536d65e` (verdict CONDITIONAL GO) and for the follow-up fixes (F1, F3, F7) and
tests (mutants O2, O4, O10, O12). It is linked from [`../README.md`](../README.md). Every claim below is labelled with its evidence class
(§11.4.289): LIVE-class means the real `llama-server`, transient user units and a real cgroup read-back on a real host; UNIT-CLASS means a
fixture cgroup tree, stubs or a text scan.

There is no `review-r6/` directory. Round 6 was a review whose findings were fixed in commits that carry their own mutants and tests; no
separate evidence directory was committed for it. This record does not reconstruct it.

## What changed after the round-7 review

| Finding | Change | Test (UNIT-CLASS) |
|---|---|---|
| F1 | The model memory budget is bounded by the tightest numeric `memory.high` / `memory.max` on `app.slice`, the user manager and every ancestor up the cgroup chain (`_rsv_chain_mem_limit_mb` in `lib/reserve.sh`). `max` and limits above host RAM bound nothing. | `tests/test_host_reserve_review8.sh` (F1 block), `tests/test_host_reserve_review2.sh` (M03 fixture now writes the user manager `memory.max` before reading the reserve) |
| F3 | `LLMCTL_GATE_RESERVE_MB` can only raise the reserve above the computed one; a non-numeric value refuses with rc 75 and an `llmctl-fallback:` line; `LLMCTL_GATE_FULL_MAX` and `LLMCTL_GATE_SOME_MAX` can only tighten (`reserve_gate_limits`). The scheduler uses an internal knob instead of the public one. | `test_host_reserve_review8.sh` (F3 block) |
| F2, F4, F5, F6 | Documented as limits in `docs/capacity.md`. The reviewer's wording for F5 and F6 was not available to the author of this fix; the limits recorded are the ones that could be verified. This is a gap to close by re-reading the review. | none (docs) |
| O4, O10, O2, O12 | Tests that kill the four reviewer mutants that survived. | `test_host_reserve_review8.sh` |
| F7 | This record. | `tests/test_doc_reachability.sh` |

## Mutant results

- Round 7 run (`mutants-r7.json`, HEAD `536d65e`): control green, 179 of 179 mutants killed, `all_killed` true.
- Round 8 run (`mutants-r8.json`, log `mutants-r8.log`): see the section at the end of this file for the HEAD it ran on and the totals.
- The 14 new mutants (R8-O2, O4, O10, O12, F1 x3, F3 x6, plus the fallback-line mutant) were also run alone against
  `test_host_reserve_review8.sh` before the full run: 14 of 14 killed.
- The reviewer's own mutants: before this change O2, O4, O10 and O12 survived; all four are now killed.

## Full-suite comparison, base v3.3.2 against HEAD (UNIT-CLASS)

Files: `suite-summary.tsv` (194 test files, one run at an earlier HEAD), `long-summary.tsv` and the `long-*.log` files (the three suites that need
more than 900 s, run one at a time under `nice 15`), `base-test_setup_e2e.log`, `base-test_doc_reachability.log`.

| Suite | Base v3.3.2 | HEAD |
|---|---|---|
| `test_decide_security_mutation` | PASS (1446 s) | PASS (1427 s) |
| `test_validation_mutants` | PASS (1382 s) | PASS (1434 s) |
| `test_livetest_watchdog` | 346 passed, 1 failed (pre-existing) | 347 passed, 0 failed |
| `test_setup_e2e` | same 2 assertions fail | same 2 assertions fail (the llama.cpp and colibri submodules are empty in the scratch clone) |
| `test_doc_reachability` | see `base-test_doc_reachability.log` | 0 orphans once this directory is linked |

The three long suites were started at `d3c319d` and the tree moved on afterwards; the decide and validation code those suites cover was not
touched by the later commits. After the F1/F3 change the host-reserve, capacity, gate-wiring, start-gate, services and restart-policy suites were
re-run (`regression-chain-r8.log`): all PASS except `test_host_reserve_review2.sh`, which that run showed failing one assertion (M03 negative control); its fixture was corrected as described above and the suite then passed on a separate re-run (RESULT: PASS).

## Live evidence (LIVE-class, one run, one host)

Files: `live/summary.json`, `live/harness.log`, `live/artifact_commit.txt`, `live/run-1` to `live/run-3`, `live-r7.log`.

- Artifact: HEAD `536d65ea8030796d84531dcfa8c5b778d7698010`, tree clean (`dirty=no`), real `llama-server` sha256 `09a14c52...b0fa74`,
  profile `decide-tiny`, three runs, transient user units.
- Read back from the cgroup: `cpu.max 300000 100000`, `cpu.weight 20`, `memory.max 3221225472`, `memory.high 2684354560`, swap 0, `--threads 3`,
  `OMP_NUM_THREADS=3`, nice 15, oom_score_adj 800, CPU set 2-7,10-15.
- A second start while the first ran was refused with rc 75 and `llmctl-fallback: cloud`; no engine pid changed and no env record was written.
- `all_checks_true` is true and `deterministic_limits` is true. `deterministic_verdicts` is false: the pressure case did not run in every run.

## NOT proven live

- The live run is ONE host with 16 CPUs. Nothing was run on a 1-CPU or small-RAM host; that path is unit-class only.
- The pressure case was skipped in live run 3, so the refusal under pressure was seen live in fewer than three runs.
- The F1 chain bound (a parent cgroup `memory.max` or `memory.high` below host RAM) is unit-class only; the live host's chain was not tightened.
- cgroup v1, a system-level (root) manager, container scopes and deep or hostile cgroup trees are fixture-tree tests only.
- Manual QA has not been done.
- Fail-open follow-ups M8 and M9 stay documented limits, backstopped by the unit start gate; they are not fixed.
- The live harness ran at `536d65e`, before the F1/F3 change. It was not re-run at the final HEAD of this round.

## Round 8 mutant run (UNIT-CLASS)

`mutants-r8.json` and `mutants-r8.log`: tree HEAD `8bee2e2` (the F1/F3 code and the R8 suite; this record adds docs only), control green (18 control runs),
193 of 193 mutants killed, `all_killed` true. Run with `python3 -I scripts/qa/host_reserve_mutants.py <root> <out.json>`.
