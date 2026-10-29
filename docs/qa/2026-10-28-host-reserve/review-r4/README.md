# Review round 4 evidence (host reserve, llmctl 3.4.0)

What is in this directory, what ran live, and on which commit. Plain statement of scope; nothing here is claimed beyond
what the files show.

## Hermetic (tests, no real model)

| File                    | What it is                                                                            |
|-------------------------|---------------------------------------------------------------------------------------|
| `red-on-ea50536.log`    | `tests/test_host_reserve_review4.sh` run on commit ea50536 (before the round-4 fix): fails. |
| `green-review4.log`     | The same test on the round-4 fix (5376ee6): passes.                                    |
| `mutants.json`, `.log`  | The mutant sweep of `scripts/qa/host_reserve_mutants.py` on 5376ee6.                    |
| `suites/`               | Every test suite run serially on 5376ee6, one log per suite, `summary.txt` totals.      |

## Live (real llama-server, real cgroup, this host)

Harness: `scripts/qa/host_reserve_live.sh`, profile `decide-tiny`, 3 runs per label.

| Path                            | Artifact the run used                                                                  |
|---------------------------------|----------------------------------------------------------------------------------------|
| `live-fixed/`, `live-fixed.log` | Tree at commit 7e713df (tree fe073fd); recorded `dirty=yes`. The only dirty path is `live-fixed.log` itself, written into the tree by the wrapper while the run was going, so the code under test was 7e713df. 7e713df adds evidence only on top of the round-4 fix 5376ee6. `all_checks_true=true` in 3 of 3 runs. |
| `live-prefix-3.3.2/`, `live-prefix.log` | The llmctl 3.3.2 tree (no host reserve), not a git checkout (`head=none`). It is the negative control: `all_checks_true=false` is the expected result there. |
| `live-capacity-json-after-profile.*` | One `llmctl capacity --json` run on the live host after those runs (rc 0, measurement ok, `decide-tiny` fits, 0 units running: every unit was stopped). |

Each `summary.json` records the llama-server path and its sha256
(`09a14c52c9d29f814e57cbcf7e4454412ee44cc94956b365250a57d830b0fa74`), and every run records the PID's executable
path and sha256 read from `/proc/<pid>/exe`.

The earlier live evidence in `../fixed/` (round 1) was taken on artifact 11a9154, not on the round-4 fix.

## What was NOT exercised live

- The live unit is a `systemd-run --user` transient unit started with the same properties and argv llmctl writes
  (`llmctl-qa-reserve-<label>-r<i>.service`). It approximates the engine unit; the operator's installed
  `llmctl-llama@` template unit was never started live by this harness.
- The second start (checking that the start gate refuses when the model budget is full) ran with `LLMCTL_DRY_RUN=1`,
  so a gate that wrongly admitted could not start a real model. The refusal (exit 75) is real; a real second engine
  was never started.
- Unreadable or missing inputs (cgroup tree, `/proc`, PSI) are covered by hermetic tests only.
