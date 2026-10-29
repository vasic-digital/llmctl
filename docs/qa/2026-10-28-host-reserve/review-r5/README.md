# Review round 5 evidence (host reserve, llmctl 3.4.0)

What is in this directory, what ran live, and on which commit. Nothing here is claimed beyond what the files show.

Commits: bbca71d (R5-1, R5-2, R5-5, R5-6, process docs), e6e578f (F3: every owner's llmctl units count against the
host model budget) and d5accb1 (the live harness checks the host-wide census on every run). The hermetic evidence below
is taken on e6e578f; d5accb1 changes only `scripts/qa/host_reserve_live.sh`. The live evidence is taken on d5accb1.

## Hermetic (tests, no real model)

| File                       | What it is                                                                                 |
|----------------------------|--------------------------------------------------------------------------------------------|
| `red-on-5376ee6.log`       | `tests/test_host_reserve_review5.sh` on lib/ of 5376ee6 (git archive): fails (RED).        |
| `red-f3-on-bbca71d.log`    | `tests/test_host_reserve_f3.sh` on a git archive of bbca71d: 23 assertion failures (RED).  |
| `suites/`                  | Every suite in the run list, run serially (nice 15, 2 CPUs) on e6e578f; `summary.txt`.     |
| `mutants.json`, `.log`     | `scripts/qa/host_reserve_mutants.py` on a git archive of e6e578f (author, reviewer Y/Z, R5 and F3 mutants). |
| `class_inventory.sh/.log`  | Section 11.4.276(C) inventory: every "count units under a source" instrument, control needle first. |

Counts: `mutants.json` 156 mutants, 156 killed, control green (`control_green: true`, `all_killed: true`), including 11
R5 and 8 F3 mutants. `suites/`: 70 suites, 68 with rc 0 and `RESULT: PASS` (or the suite's own pass line); `suites/extra/`
4 more suites, all PASS. `class_inventory.log`: commit e6e578f, 0 changed code paths, M1-M7 and M10 fail closed, M8 and M9
are the two scoped-out fail-open instruments listed below.

`suites/summary.txt` lists two suites with rc 124: `test_livetest_watchdog` and `test_validation_mutants`. Both are
cut by the runner's 900 s per-suite timeout; neither prints a FAIL line before the cut, and both timed out the same
way in the round-4 run on 5376ee6 (`../review-r4/suites/summary.txt`). Neither reads the host reserve code.

## Live (real llama-server, real cgroups, this host)

Engine: `llama-server` sha256 `09a14c52c9d29f814e57cbcf7e4454412ee44cc94956b365250a57d830b0fa74`, profile
`decide-tiny`, model `Jev-Style-0.8B-Decision-v3-Q4_K_M.gguf`. Every run reads the exe of the process inside the unit
back from `/proc/<pid>/exe` and compares its sha256 with this value (`limits.txt` `exe_sha256`, check
`engine_exe_is_the_named_binary`).

| Directory                | Code under test        | Result                                                                    |
|--------------------------|------------------------|---------------------------------------------------------------------------|
| `live/`                  | d5accb1, `dirty=no`    | 3 runs, 25 checks each, all true; limits and verdicts identical (`live-fixed/summary.json`) |
| `live-red-bbca71d/`      | git archive of bbca71d | 1 run, `all_checks_true=False`: the 4 host-scope checks fail, the other 21 pass |
| `live-first-run-dirty/`  | e6e578f, `dirty=yes`   | superseded; kept because it showed the gap that d5accb1 closes (see below) |

What the green run shows (`live/live-fixed/run-<i>/scope.txt`, `scope_capacity.json`, `scope_reserve.json`), each
taken while the QA unit was running and with no threshold changed:

- `llmctl capacity --json`: `consumption_scope.scope` is `host`, `cgroup_root` is `/sys/fs/cgroup`; the only unit
  listed is `llmctl-qa-reserve-fixed-r<i>.service` with `owner: self` and the same cgroup directory the read-back
  found; verdict `fits`, exit 0. The system `ollama` workload on this host is not listed as an llmctl unit.
- `llmctl reserve --json`: `units_scope` `host`, `units_readable` true, the QA unit with `owner: self`.
- After the run: no `llmctl-qa*` unit (`units-after.txt` is empty), no engine process (`engines-after.txt`), and
  `capacity-after.json` reports scope `host` with 0 units.

The RED (`live-red-bbca71d/live-red/run-1/scope.txt`): the pre-F3 code scanned only this user's manager
(`cgroup_root` `/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service`) and its units carry no owner, so the
checks `scope_capacity_host_wide`, `scope_reserve_host_wide`, `scope_qa_unit_owner_self` and
`scope_qa_cgroup_is_readback` fail. The leg can therefore tell the fixed code from the old one.

Why d5accb1 exists: in the first live run on e6e578f (`live-first-run-dirty/`) the only live `capacity --json` capture
was the pressure leg, and it skipped itself because CPU PSI was low (0.97). The host-wide census therefore had no live
capture at all. That run was also `dirty=yes` (this README was untracked in the checkout). Both are fixed: the scope leg
runs on every fixed run, and the green run was taken with the evidence moved out of the checkout.

## What was NOT exercised live

- Other users' llmctl units and `system.slice` llmctl units (F3): this host has one user and the harness has no root,
  so the units of another owner are covered only by `tests/test_host_reserve_f3.sh` (a fixture cgroup v2 mount).
  Live, the host-wide scan of `/sys/fs/cgroup` was run and counted this user's unit with `owner: self`.
- A host that hides part of its cgroup tree from the user (fail closed): hermetic only. Measured here: no
  unreadable cgroup.
- cgroup v1 and hybrid hosts: hermetic only (the refusal message).
- Unreadable or missing inputs (cgroup tree, `/proc`, PSI): hermetic only.
- macOS and other platforms without `/proc`: not tested.
- The live unit is a `systemd-run --user` transient unit started with the properties and argv llmctl writes; the
  operator's installed `llmctl-llama@` template unit was never started live by this harness.
- The second start (refused because the model budget is full) runs with `LLMCTL_DRY_RUN=1`; the refusal (exit 75) is
  real, a real second engine was never started.
- The restart lock race is covered by hermetic tests only.
- The pressure leg (a live CPU PSI reading above a stricter threshold makes `capacity` report pressure and mark the
  unit degraded) did not run in this round: live CPU PSI was 0.52 to 1.25 in every run, below the harness's floor of 4,
  so it skipped itself (`pressure.txt`). The pressure code is not changed in round 5; the last live runs that exercised
  it are `../fixed/` and `../review-r1/live-fixed/` (`tool_saw_above_threshold=True`).
- Two instruments outside the host reserve still read an unreadable source as "nothing" (class inventory M8, M9:
  the planner's `systemctl list-units` memory list and the scheduler's reservation sum). They predate 3.4.0, are not
  changed here and are a tracked follow-up.
