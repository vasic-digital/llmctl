# Host reserve 3.4.0: review round 3 evidence

| Field | Value |
|---|---|
| Revision | 1 |
| Created | 2026-10-29 |
| Reviewed commit | bbfd380 (independent review: GO-with-followups, 4 MID findings, round 3) |
| Fix commit | 9de0557 (tree `abfd597ff3c50c35416b916d574ec672dbff3dc6`) |
| Host | 16 CPUs (SMT pairs i, i+8), about 31 GiB; load1 about 1.3-2.2 during the live runs and the suites |

## What was fixed

1. **Tenant-scoped `decision_local`.** Only this tenant's own decide instances (`<tenant>--<profile>`, or names without `--`
   when no tenant is set) count as a running local decision model. With `LLMCTL_TENANT_ID=t2`, a healthy `t1--decide-tiny` and
   no decide profile that fits, the fallback is now `none` (or `cloud`/`hosted` with a real key), never `local`.
2. **Live evidence tied to the code.** `scripts/qa/host_reserve_live.sh` records `head`, `head_tree`, `dirty` (porcelain over
   `lib`, `bin`, `scripts`) and `dirty_diff_sha256` when dirty, plus the path and sha256 of the named `llama-server`. Each run
   records `exe` and `exe_sha256` of `/proc/<pid>/exe` and checks `engine_exe_is_the_named_binary`. The live run was repeated
   on the committed fix 9de0557, with `dirty=no`.
3. **Surviving reviewer mutants.** `tests/test_host_reserve_review3.sh` drives the real code for X03 (kill without a start-time
   match), X04 (no SIGSTOP freeze), X05 (the undetermined document's fallback is pinned as JSON), X07/X08 (the CPU boundaries at
   exactly 100 and exactly `cap*100`), X09 (the time bound: tolerances in ms, at most 4.5 s for a 3 s budget), X11 (the RAM-reserve
   pressure reason). The review2 timing checks now use ms with tighter bounds.
4. **§11.4.291 (B)/(C) inputs, additive, schema `llmctl.capacity/1`.**
   - `inputs`: one entry per input, with `source`, `readable` and `read_at`.
   - `profiles.<p>.headroom` gains `footprint_provenance` (`declared`), `footprint_source` (naming the planner's
     `profiles.<p>.ram_mb`) and `vram_provenance`.
   - Units gain `memory_current_provenance` (`measured`).
   - `host.nproc` reports the RLIMIT_NPROC soft and hard limits, the user's thread count and the headroom; a headroom below the
     thread cap adds a reason.
   - `host.cgroup.cpu_stat` and each unit's `cpu_stat` carry the `nr_periods`, `nr_throttled` and `throttled_usec` counters
     (§11.4.225).
   - FLAG for the coordinator: the throttle counters are cumulative. llmctl computes no delta over a window; a caller
     subtracts two documents. The nproc check uses the model's thread cap, so it is a floor, not a guarantee.
5. **Placeholder hosted keys.** A key read by variable NAME never routes to `hosted` when it is empty or a placeholder. A
   placeholder is a dummy word or `<...>`, fewer than 16 characters, one repeated character, or contains a control character
   (the constitution's `lib_keys.sh` rule). The value is never printed.
6. **Wall-clock bound.** `_cap_bounded` uses an elapsed ms deadline (`EPOCHREALTIME`), not a count of 0.1 s sleeps.
7. **STOP then recheck.** The probe tree is collected from one process-table snapshot per pass. Every pid is SIGSTOPped and
   its start time read again; on a mismatch it gets SIGCONT and is skipped. KILL is sent only when the start time still
   matches. Because there is no `pgrep` per pid any more, admission after a hung probe went from about 4.7 s to about 3.7 s
   (3 s budget).
9. **Docs.** `docs/capacity.md` now says that capacity RUNS the hardware probe and the planner (it reads more than `/proc`
   and the cgroup tree). It also states that a planner-only `does_not_fit` on a restart is admitted.

## Evidence

| File | What it shows | Class |
|---|---|---|
| `red-on-bbfd380.log` | `tests/test_host_reserve_review3.sh` on the reviewed tree bbfd380: rc 1, 54 assertion failures (the RED baseline) | unit (hermetic) |
| `green-review3.log` | the same suite on 9de0557: 82 `ok`, `RESULT: PASS` | unit |
| `suites/summary.txt`, `suites/*.log` | 67 suites, one at a time on 2 CPUs (`taskset -c 0,1`, nice 10, 900 s limit). 65 pass. `test_livetest_watchdog` and `test_validation_mutants` hit the 900 s limit (rc 124) with 0 `FAIL:` lines, as in rounds 1-2 and on 3.3.2 | unit / integration |
| `mutants_r3.json`, `mutants_r3.log` | `scripts/qa/host_reserve_mutants.py`: 79 paired mutants (53 author mutants from rounds 1-2, X01-X15 ported, 11 R3 author mutants). Control GREEN; 78 killed in the sweep. The one survivor, `R3-placeholder-list-dropped`, is covered below | unit |
| `rev3_on_fix.json`, `rev3_on_fix.log` | the reviewer's own harness (X00 control, X01-X15) on 9de0557: control green, all 15 killed. X09 and X15 are retargeted; see the mapping below | unit |
| `live-fixed/`, `live-fixed.log` | 9de0557 (clean), real `llama-server`, real `decide-tiny` model, real transient user units; values read back from `/sys/fs/cgroup` and `/proc`; 3 runs | **live** |
| `live-prefix-3.3.2/`, `live-prefix.log` | 3.3.2 (`git archive 11a9154`) negative control, same harness, 3 runs | **live** |
| `live-capacity.json`, `live-capacity.err` | `llmctl capacity --json decide-tiny` on 9de0557 against the real host, read-only | **live** |

### The one sweep survivor

`R3-placeholder-list-dropped` removes the dummy-word `case`. Every listed word is shorter than 16 characters, so the length
rule refused the same values, and the test had no long `<...>` value. The test now also uses
`<put-your-hosted-api-key-here>` (30 characters). Applied by hand to a copy, the mutant now fails 3 assertions on that value;
the real tree passes. The remaining words in the list are an equivalent mutant (covered by the 16-character rule) and are kept to
match the constitution rule exactly; this is recorded in the CHANGELOG.

### Reviewer mutant mapping (X01-X15)

The reviewed text of X09 (`if (( i >= n ))`) and X15 (the untenanted `decision_local` line) was replaced by the fixes, so both
are retargeted to the new text with the same intent:

- **X09:** `>= deadline` becomes `>= deadline + 3000`.
- **X15:** `any(own_unit(u) and u["base_profile"] ...)` becomes `any(u["base_profile"] ...)`.

X03 and X04 target the new kill and collect lines with the same intent. Every other mutant applies unchanged.

| Mutant | Killed by |
|---|---|
| X01, X02, X10 | review2 |
| X06, X12, X13, X14 | capacity / review / review2 / review3 |
| X03, X04, X05, X07, X08, X09, X11, X15 | review3 (round 3 tests) |

## Live readback (decide-tiny, 3 runs each)

| Reading | 9de0557 (all 3 runs) | 3.3.2 control (all 3 runs) |
|---|---|---|
| `head` / `head_tree` / `dirty` | `9de0557` / `abfd597f...` / `no` | `git archive 11a9154` |
| `/proc/<pid>/exe` | `.../llama.cpp/build/bin/llama-server` | same binary |
| `exe_sha256` (= `llama_server_sha256`) | `09a14c52c9d29f814e57cbcf7e4454412ee44cc94956b365250a57d830b0fa74` | the same |
| model argument | `.../models/decide-tiny/Jev-Style-0.8B-Decision-v3-Q4_K_M.gguf` | the same |
| `cpu.max` | `300000 100000` | `max 100000` |
| `Cpus_allowed_list`, every thread | `2-7,10-15` | `0-15` |
| `--threads` / `OMP_NUM_THREADS` | `3` / `3` | none |
| nice / `oom_score_adj` | 15 / 800 | 10 / 500 |
| `memory.max` / `memory.high` / `memory.swap.max` | 3 GiB / 2.5 GiB / 0 | as set by 3.3.2 |
| a second start with the budget full | exit 75, `llmctl-fallback: cloud`, no new unit or engine pid, no env record | admitted (exit 0) |
| summary | `deterministic_limits=True deterministic_verdicts=True all_checks_true=True` | 8 checks false in every run (expected) |

Under stress, run 1 measured 294.6% CPU, `nr_throttled` +46 over 29.5 s, and CPUs seen only in `2-7,10-15`. The fallback line
says `cloud` because a real-looking hosted key variable is set on this host. Only its NAME (`TYPESAFE_API_KEY`) appears; the
value appears nowhere in the evidence (searched).

`live-capacity.json` on the real host shows these fields:

- `host.nproc` (soft = hard = 123699, user threads 2328, headroom 121371);
- all 12 `inputs`, readable, with their sources;
- `host.cgroup.cpu_stat`, all zero: the user@1000 scope has no CPU quota;
- `footprint_provenance: declared` with its source;
- `vram_provenance: estimated`;
- `measurement.ok true`;
- the fallback `local`, since decide-tiny fits.

## NOT proven live

- **Tenant fix (R3-1).** Proven on hermetic fixtures only. No second tenant's decide unit was run on this host.
- **Placeholder keys.** Hermetic only. The live runs used the host's real key variable and did not use a placeholder value.
- **Per-unit `cpu_stat` in the capacity JSON and the nproc refusal reason.** Hermetic only. The live capture ran with no llmctl
  unit up, and the headroom was far above the cap. The live harness measured throttling directly (`nr_throttled` +46), not
  through the capacity JSON.
- **Non-zero scope throttle counters.** The live scope has no quota, so it reports zeros. A quota'd scope was not tested live.
- **The PSI/pressure start-gate leg.** Skipped live in all 3 runs: live CPU PSI was 0.14-0.36, below which no stricter
  threshold exists. It is hermetic only.
- **Probe hang/kill path (X03/X04/X09), the wall-clock bound and the undetermined document.** These used real processes
  (real `sleep` trees, real signals) inside the test sandbox. A real hung hardware probe on this host was not produced.
- **macOS/launchd and a delegated `cpuset` controller.** Not available on this host.
- **Real routing to the hosted endpoint.** The `cloud`/`hosted` route is a recommendation printed by llmctl; no hosted call
  was made.
- **Manual QA (§11.4.185).** Not performed.
