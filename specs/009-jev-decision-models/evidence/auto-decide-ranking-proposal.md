# Proposal: `llmctl auto decide` ranking (finding M9)

Status: PROPOSAL ONLY. Nothing in this document is implemented. Written 2026-10-09 from the evidence index
(`live-models/INDEX.md`), each run's `golden-stats.txt`, `latency.json`, `README.md`/`RESULT.txt`, `lib/scheduler.sh`,
the tests and docs named in section 3. Every number below was read from those files in this session.

## 0. The finding in one paragraph

`sched_rank_for_capability decide` (lib/scheduler.sh:76) is
`decide-nli decide-2b decide decide-pro decide-max decide-julia decide-laya decide-kev-08b decide-lev decide-kev-4b decide-kev-9b decide-tiny`
and `auto decide` takes the first RECOMMENDED entry (scheduler.sh:1370-1391). The list is documented as "smallest footprint
first, not highest accuracy" (docs/hardware-tiers.md:236-251, docs/decision-models.md:296-310). On every planner fixture that
admits any decision profile it therefore picks `decide-nli` (docs/hardware-tiers.md fixture table, tests/test_scheduler.sh:421).
`decide-nli` beats the baseline only on `choice`. It does not beat the majority baseline on `noul` (0.533 vs 0.667) or `score`
(0.226 vs 0.290). The user wants typed decisions of all three kinds, so the default fails two of three.

## 1. Per-profile capability table (from evidence)

"Beats" = lower bound of the 95% CI is above the stated baseline (the `lower>baseline` flag in `golden-stats.txt`). Baselines:
noul 0.667 (majority), choice 0.235 (chance), score 0.290 (majority). n = 60 / 41 / 31 (132 original golden items).
Latency = HTTP-200 golden-run median (p50) in ms, as recorded; the host and engine mode differ per row and are NOT comparable
across rows (see "Confounds" below). Memory = catalog footprint from docs/hardware-tiers.md:58-69 / test_planner.sh, plus the
engine peak where a run recorded one.

| Profile (catalog tier) | Run used (provenance) | Well-formed | noul (CI) | choice (CI) | score (CI) | Beats n/c/s | p50 latency (host, mode) | Memory |
|---|---|---|---|---|---|---|---|---|
| decide-nli (below-min, onnx) | nezha-pinned (pinned) and anton wiredfix (mid-dev) agree | 132/132 | 0.533 [0.409,0.654] | 0.829 [0.687,0.915] | 0.226 [0.114,0.398] | no / YES / no | 433 (nezha CPU); 1543 (anton CPU) | ~1.62 GiB; RSS 2.0 GB |
| decide-2b (baseline) | nezha-pinned = anton run2 (identical numbers) | 128/132 | 0.883 [0.778,0.942] | 0.732 [0.581,0.843] | 0.290 [0.161,0.466] | YES / YES / no | 2316 (nezha CPU); 2900 (anton CPU) | ~1.87 GiB; anton VmHWM 7.8 GB |
| decide (decider-4b, baseline) | nezha-pinned | 13/132 | 0.000 | 0.220 | 0.129 | no / no / no | n/a (151 x 422 readout_failed) | ~2.52 GiB |
| decide-pro (workstation) | nezha-pinned, timeout 300 s | 131/132 | 0.883 [0.778,0.942] | 0.951 [0.839,0.987] | 0.645 [0.469,0.789] | YES / YES / YES | 7615 (nezha CPU) | ~4.07 GiB; anton VmHWM 7.36 GB |
| decide-pro at product default 8 s | nezha-pinned control | 98/132 (45 x 502 deadline) | 0.833 | 0.634 | 0.387 [0.237,0.562] | YES / YES / no | n/a | same |
| decide-max (workstation) | nezha-pinned, timeout 300 s | 128/132 | 0.967 [0.886,0.991] | 0.878 [0.745,0.947] | 0.806 [0.637,0.908] | YES / YES / YES | 13252 (nezha CPU) | ~8.87 GiB |
| decide-kev-08b (below-min, native) | anton, unpinned | 132/132 | 0.817 [0.701,0.894] | 0.878 [0.745,0.947] | 0.290 [0.161,0.466] | YES / YES / no | 25 (anton, mode not re-verified) | ~775 MiB; peak 335 MB |
| decide-kev-4b (baseline, native) | anton unpinned AND nezha unpinned (identical numbers) | 132/132 | 0.950 [0.863,0.983] | 1.000 [0.914,1.000] | 0.613 [0.438,0.763] | YES / YES / YES | 49 (anton, -ngl 99 GPU); 2525 (nezha CPU, -ngl 0) | ~2.82 GiB; GPU booking 7328 MiB measured |
| decide-kev-9b (workstation, native) | nezha unpinned only (anton run NOT-STARTED) | 132/132 | 0.967 [0.886,0.991] | 1.000 [0.914,1.000] | 0.710 [0.534,0.839] | YES / YES / YES | 4602 (nezha CPU) | ~5.92 GiB; CUDA OOM at 12 GB-class GPU booking (test_scheduler.sh section 13) |
| decide-lev (baseline, native) | anton unpinned AND nezha unpinned (identical numbers) | 132/132 | 0.967 [0.886,0.991] | 0.976 [0.874,0.996] | 0.516 [0.348,0.680] | YES / YES / YES | 106 (anton GPU); 8238 (nezha CPU) | ~2.80 GiB; RAM measured, VRAM partial |
| decide-laya (below-min, native) | anton unpinned | 132/132 | 0.717 [0.592,0.815] | 0.805 [0.660,0.898] | 0.323 [0.186,0.499] | no / YES / no | 16 | ~429 MiB |
| decide-julia (below-min, native) | anton unpinned | 132/132 | 0.550 [0.425,0.669] | 0.341 [0.216,0.495] | 0.258 [0.137,0.432] | no / no / no | 12 | ~160 MiB |
| decide-tiny | none | not servable by the gateway (jev-verdict readout) | - | - | - | - | - | ~505 MiB |

Reading notes (all from the evidence README/INDEX caveats):

* decide-pro's 131/132 well-formed and 0.951 choice come from the 300 s timeout run. Under the product default 8 s deadline it
  loses 45 of 132 requests to `502 deadline_exceeded` (p50 7.6 s on this CPU) and its `score` stops beating baseline. The
  anton run (112/132 well-formed, malformed counted wrong) is the same story. decide-pro and decide-max are therefore
  accurate but not usable at the default deadline on a CPU-only host. They are also tier-gated to `workstation`.
* decide-2b `score` 0.290 equals the majority baseline exactly. decide-kev-08b `score` also equals it (0.290). Both are
  "answers noul and choice, guesses score".
* decide-nli: three independent runs (anton wiredfix, nezha-pinned, and the earlier wired run) report the same 0.533/0.829/0.226.
* `decide` (decider-4b): the pinned nezha run is a valid run with a bad model result (151 x 422 `readout_failed`). The anton
  re-smoke after the thinking fix was INCOMPLETE (1/3). It has no usable accuracy figure.
* The catalog already encodes this per type: `models/catalog.json` maturity labels (docs/hardware-tiers.md:205-221) show
  kev-4b and lev `measured` on all three types, kev-08b and laya `experimental` on at least one, julia `experimental` on all,
  and nli/2b/pro/max/decide/kev-9b `unmeasured` (copied before the live runs; see CHANGELOG.md:272-274, which flags exactly this).

### Evidence gaps and confounds (do not skip)

1. The native (kev/lev/laya/julia) runs are UNPINNED (INDEX.md "Tree provenance": engine commit 1537a0a recorded, the llmctl
   tree commit is not). The nli/2b/pro/max runs are on the pinned mid-development snapshot (HEAD c5301de + a recorded diff, equal
   to no commit). The two families were measured on DIFFERENT trees, on different dates' builds, mostly different hosts, with
   different timeouts. The accuracy comparison across families is therefore suggestive, not controlled. The golden set is the
   same 132 items in both.
2. kev-4b and lev have two independent runs (anton, nezha) with identical accuracy numbers, which is the strongest
   reproducibility evidence in the set. kev-9b has one run (nezha) only.
3. Latency is per host and per engine mode: anton ran kev-4b with `--n-gpu-layers 99` (p50 49 ms) while the nezha CPU run
   (`-ngl 0`) is 2525 ms. The 8 s product default deadline is satisfied by kev-4b on CPU (p95 4704 ms) but not by lev on CPU
   (p95 13562 ms) or by pro/max on CPU.
4. score has n = 31 and wide CIs. kev-9b [0.534,0.839], max [0.637,0.908], pro [0.469,0.789], kev-4b [0.438,0.763] and lev
   [0.348,0.680] all overlap. The evidence does NOT separate them on score; it separates them from {nli, 2b, kev-08b, laya,
   julia, decide}.
5. decide-nli was ranked first because it is the cheapest CPU option with no GPU/VRAM need and no engine gate (scheduler.sh
   comment, lines 66-76: "one forward pass per option"). That rationale was written before any live accuracy data existed
   (the catalog still carries `unmeasured` for it). It was never a quality finding.
6. The native profiles are served only when the gateway runs with `LLMCTL_DECIDE_NATIVE=1` (cmd_serve.go:382, "engine advance
   gate OD-1"); without it they answer `503 not_ready`. They also need llama.cpp >= b11379. The scheduler comment appends them last
   precisely so `auto decide` never picks an engine-gated profile. No code in `lib/` sets the variable; it is a gateway env
   var. Any quality-first ranking that puts a native profile first must therefore be conditional on that gate, or `auto decide`
   will start a service that answers 503 for every request.
7. decide-kev-9b: one run, unpinned, nezha CPU; on a 12 GB-class GPU it needs 11104 MiB and does not fit (test_planner.sh
   decision capacity), and an earlier gpu-mode start CUDA-OOMed (test_scheduler.sh section 13).

## 2. What "best" should mean for `auto decide`, and the recommended ranking

### 2.1 Definition

`auto decide` should pick the profile that a user who asked for "a decision model" can use for all three typed decisions without
a surprise. Proposed ordered criteria, applied as a lexicographic key over the profiles that are RECOMMENDED on the host:

1. Servable on this host as configured (not engine-gated off, not tier-gated, not "not servable", and completes within the
   default 8 s deadline on that host class). A profile that returns 422/502 for most of the golden set is not a candidate.
2. Number of typed decision kinds whose CI lower bound beats the baseline (3 > 2 > 1 > 0).
3. Among equals: a measured/reproduced result (two independent runs) before a single run.
4. Then lower latency, then smaller footprint (this keeps the current "smallest that works" spirit as a tie-breaker, not the lead).

A profile that fails `score` or `noul` is a poor default. It may remain a valid explicit choice (`llmctl start decide-nli`, or
`LLMCTL_DECIDE_PROFILE`), because nli is genuinely the best option when only `choice` is needed and it is by far the cheapest.

### 2.2 Result of applying the criteria to the evidence

Three-of-three: kev-4b, lev, kev-9b, decide-pro, decide-max. Two-of-three (noul + choice): decide-2b, decide-kev-08b.
One-of-three: decide-nli (choice), decide-laya (choice). Zero: decide-julia, `decide`.

Among the three-of-three set, the host class decides:

* kev-4b: baseline tier, ~2.8 GiB, passes 8 s on CPU (p95 4.7 s), 49 ms on GPU, reproduced on two hosts. Best default everywhere.
* lev: baseline tier, three-of-three and reproduced, but on CPU p50 8.2 s / p95 13.6 s misses the 8 s default. Good on a GPU
  (106 ms), second choice on CPU hosts only if the deadline is raised. `score` is weaker than kev-4b (0.516 vs 0.613; overlapping CIs).
* kev-9b / decide-max / decide-pro: `workstation` tier, heavier, slow on CPU; higher `score` point estimates but not separable
  from kev-4b statistically (finding 4 above).

### 2.3 Recommended single ranking (data, not per-host code)

The planner already filters by tier and fit (`recommended`), so one fixed list produces the right per-host-class behaviour
through the existing tier gates. Proposed list when the native gate is ON (`LLMCTL_DECIDE_NATIVE=1` and engine >= b11379):

```
decide-kev-4b decide-kev-9b decide-max decide-lev decide-pro decide-2b decide-nli decide-kev-08b decide-laya decide-julia decide decide-tiny
```

and when the native gate is OFF (the shipped default today), the three-of-three set is not servable except pro/max (tier
gated and slow), so:

```
decide-max decide-pro decide-2b decide-nli decide decide-tiny   # native profiles omitted entirely, not appended
```

Rationale per position: kev-4b first (3/3, reproduced, fast on both CPU and GPU, baseline tier so it is reachable on every
host class that can run any model). kev-9b next because it is the only profile with the best choice score and a better
score point estimate that still runs at 4.6 s on CPU, but it is workstation-tier, single unpinned run, and has a CUDA-OOM
history, so it sits below kev-4b by the "reproduced" criterion and above max because it is faster and smaller. max is
the only profile whose `score` lower bound (0.637) is clearly highest, but 13 s p50 on CPU fails the default deadline, so it
is a workstation-GPU choice. lev after those because it ties kev-4b on count but is slower on CPU and weaker on score. pro is
3/3 only at timeout 300; at the 8 s default it fails (INDEX.md control run), so it ranks below the native 3/3 profiles and
above the 2/3 ones only if the host raises the deadline (see 2.4). 2b is the best non-native profile on a CPU host (noul 0.883,
choice 0.732; score is unproven). nli follows (choice only). kev-08b, laya, julia, `decide`, tiny last; `decide` stays above
tiny only as a not-servable placeholder pending its readout fix.

### 2.4 Per host class

| Host class | Native gate ON (engine >= b11379) | Native gate OFF (today's default) |
|---|---|---|
| CPU-only 16-32 GB (tier baseline; pro/max/kev-9b gated off) | `decide-kev-4b` (3/3, p95 4.7 s on CPU), then lev (slow on CPU), then 2b, nli | `decide-2b` (noul+choice) before `decide-nli` (choice only). No profile covers `score` here: say so in the `why:` line. |
| GPU 12 GB (planner VRAM budget ~10444 MiB) | `decide-kev-4b` (7328 MiB measured gpu booking, 49 ms), then lev (106 ms). kev-9b does NOT fit (11104 MiB lower bound) | `decide-2b`, `decide-nli` (as above) |
| Workstation (tier `workstation`; 64 GB class, pro/max/kev-9b unlocked) | `decide-kev-4b` still first; kev-9b and `decide-max` are the next picks. Operators who want the highest `score` can start `decide-max`/`decide-kev-9b` explicitly. | `decide-max` > `decide-pro` need `LLMCTL_DECIDE_TIMEOUT` raised above 8 s to be usable; otherwise `decide-2b` |

An alternative the operator may prefer on workstations is `decide-max` first (highest score lower bound 0.637). The evidence
does not separate it from kev-4b on score, it is 270x slower on CPU, and it needs the timeout raised, so it is not the proposal.

### 2.5 Honest limits of this ranking

* It is built from one golden set (n = 60/41/31). The kev/lev numbers were measured on an unpinned tree. Before the ranking is
  made the shipped default, `decide-kev-4b` and `decide-lev` should be re-run on a pinned tree (one run each; they already
  reproduce across two hosts, so this is confirmation, not discovery).
* "Servable at the default deadline" is a property of host speed, not of the profile. The ranking uses CPU numbers measured on
  one i7-1165G7 (nezha) and one anton CPU run; a faster CPU moves lev and pro up.
* The catalog `maturity` data is stale (`unmeasured` for pro/nli/2b/max/9b). A durable fix would drive the ranking from catalog
  maturity labels, which first requires refreshing those labels from this evidence (CHANGELOG.md:272-274 already tracks it).

## 3. Exact code, test and doc changes required

All paths relative to repo root. Line numbers as of this working tree (which has uncommitted edits to lib/scheduler.sh).

### 3.1 Code

1. `lib/scheduler.sh:58-77` `sched_rank_for_capability`
   * Replace the `decide)` arm (line 76) with a function that echoes one of two lists chosen by the native gate
     (section 2.3). Gate predicate, new helper `_sched_decide_native_enabled`: true when `LLMCTL_DECIDE_NATIVE=1` in the
     environment OR in `${LLMCTL_STATE_DIR}/decide/gateway.conf` (the file `decide_service_enable` writes; see the nezha
     persistent-services README), AND the llama-server build is >= b11379 (reuse the engine-version probe already used by the
     native sched arm; if there is none, check `llama-server --version` build number). Resolve this by real value, not by
     substring (Constitution 11.4.201). If the predicate cannot be evaluated, treat the gate as OFF (the safe default).
   * Rewrite the comment block at lines 62-75, which currently justifies "smallest footprint first".
2. `lib/scheduler.sh:1385-1392` (the `why:` log line): change the wording "(smallest footprint first)" to the new rule, and when
   the picked profile does not beat the baseline on all three types, append a one-line caveat (for example
   "decide-2b: score not proven"). The data for that caveat can come from the catalog maturity labels.
3. Optional, same change set: make `LLMCTL_DECIDE_PROFILE` default selection (lib/decide.sh:446 region, documented at
   docs/user-manual.md:755) use the same ranking so a bare `llmctl decide` and `llmctl auto decide` agree. Today the
   documented default is "decide-nli, then decide-2b, decide, ...". Needs a separate read of decide.sh before editing; not
   verified in this analysis whether that default calls `sched_rank_for_capability`.

No change is needed in `catalog_plan_json` (recommended set), tier gating, or co-residency grouping. Those use the profile
set, not the rank list (test_planner.sh co-residency assertions at lines 49-51, 86-88 do not read the rank). Note that
test_planner.sh:328-329 passes the rank into the planner comparison (`RANK_DECIDE`); that comparison must still hold for both
gate states.

### 3.2 Tests (these pin the old order and will fail until updated)

* `tests/test_scheduler.sh:421-422`: `auto decide picks decide-nli` and the full-ranking `why:` string. Update for the new
  default (gate OFF in the hermetic harness, so the expected pick is `decide-2b` and the OFF list), and add a gate-ON case
  that expects `decide-kev-4b` on the baseline fixture. Keep the "decide-tiny is ranked last" assertion.
* `tests/test_scheduler.sh:430-434`: "auto chat never selects a decision profile" is unaffected; keep.
* `tests/test_planner.sh:586-591` (`sched_rank_for_capability decide` literal): update to both lists, plus the stale comment
  at 581-584. This is the order pin.
* `tests/test_decide_cli.sh`: no assertion on the decide rank was found (its "first" matches are option-position bias);
  no change expected, confirm when implementing.
* New tests: (a) gate OFF never ranks a native profile above a proven one (the original invariant the comment protected);
  (b) gate ON on `baseline` picks kev-4b, on a 12 GB GPU fixture picks kev-4b, and on `tiny` still fails with "no catalog
  profile ... fits"; (c) `LLMCTL_DECIDE_NATIVE` read from `gateway.conf`; (d) unresolvable gate evaluates OFF.
  Per the repo rules each new test needs a paired mutation (flip the order, drop the gate check) that makes it fail.

### 3.3 Docs

* `docs/hardware-tiers.md:236-256` (the `auto decide` ranking paragraph, including "A quality-first ordering ... is a
  different, undocumented-until-chosen policy"): rewrite; this is exactly the policy being chosen.
* `docs/hardware-tiers.md` fixture table (lines ~222-232, the `auto decide picks` column): recompute per fixture and per gate state
  (the SC-012 rows in the `make test` logs assert these rows exist).
* `docs/decision-models.md:296-310` (`auto decide` ranking section): new order and rationale, with this document cited.
* `docs/scripts/scheduler.md:308-316` (FR-030 explanation).
* `docs/user-manual.md:755` (the `LLMCTL_DECIDE_PROFILE` default text) if 3.1 item 3 is adopted.
* `README.md:138-146` mentions that nli's noul/score do not beat baseline but does not say it is the `auto decide` default; add
  one sentence.
* `CHANGELOG.md`: an entry under the next version marking the behaviour change.
* `docs/hardware-tiers.md:205-221` and `models/catalog.json` maturity labels for nli/2b/pro/max/9b/decide: refresh from the
  evidence (CHANGELOG.md:272-274 already records they are stale); the ranking is more defensible if driven by these.
* `specs/009-jev-decision-models/evidence/gaps-register.md`: add the gap and its closure, and a tasks.md entry.

### 3.4 Risk

* Behaviour change: the first service `auto decide` starts changes on every host class that has any decision profile. Existing
  users who relied on the 0.4 s CPU-only nli get a heavier default (kev-4b ~2.8 GiB, ~2.5 s p50 on CPU) when the gate is on.
* Gate coupling: ranking a native profile first without the gate on yields a service that answers 503. The conditional list in
  2.3 and test (a)/(d) are the guard. The default (gate OFF) keeps the cautious path and moves 2b ahead of nli, a smaller change.
* Memory: kev-4b reserves ~2.8 GiB RAM / 7328 MiB measured GPU (cpu-mode VRAM is booked per G-138); the
  `ram-contended-auto-eviction` fixture admits only `decide`, `nli`, `2b` and would still fall back to `decide-2b`/`nli` rather
  than evict others (the planner `recommended` filter already refuses kev-4b there).
* Evidence risk: the ranking rests on unpinned native runs and n = 31 for `score`. A wrong order is cheap to revert (one line),
  but the docs and tests would be rewritten twice; hence the verification plan below asks for a pinned re-run first.
* Not adopted here: ranking by catalog maturity dynamically. It is more principled but blocked on refreshing the stale labels.

## 4. Verification plan

1. Evidence closure before any code change: one pinned-tree golden run each for `decide-kev-4b` and `decide-lev`
   (CPU and, where available, GPU), and one for `decide-kev-9b` on a commit-pinned tree, all with the gateway default deadline
   and `LLMCTL_DECIDE_NATIVE=1`. Compare to the numbers in section 1; if kev-4b does not again beat all three baselines, this
   proposal falls back to "decide-2b before decide-nli only".
2. TDD: write the updated `test_scheduler.sh` / `test_planner.sh` assertions and the new gate-conditional tests first and
   observe them FAIL against the current ranking; then change `sched_rank_for_capability`.
3. Run `make test`, `make lint`, `make validate`, and the two constitution scripts the project requires
   (`bash constitution/scripts/validation/run_verification.sh`, `bash constitution/scripts/validation/meta_test_verification.sh`).
4. Paired mutations for the new tests (swap the lists, ignore the gate) must each make a test fail.
5. Live check on at least the nezha CPU host and one GPU host: `llmctl auto decide` with the gate on and off prints the expected
   `capability 'decide' -> profile '...'` and `why:` line, the started service answers a noul, a choice and a score request, and
   the stop path frees the port. Capture the output as evidence, as the existing live-model directories do.
6. Docs consistency: grep the repo for the old order string and for "smallest footprint first" and confirm zero stale hits
   outside historical evidence and `.claude/worktrees/*` copies (those contain old copies of these files and are not part of
   this change).
7. Independent code review of the diff before commit (project rule).

## 5. Does this need an operator decision?

Yes. This changes documented, tested, user-visible behaviour:

* `docs/hardware-tiers.md:246-248` states the current policy is intentionally "smallest footprint first, not highest
  accuracy" and that a quality-first order "is a different, undocumented-until-chosen policy". `auto decide` is a public
  command (`llmctl auto decide`, bin/llmctl:92). Moving to a quality-first, gate-conditional ranking is exactly that choice.
* It also reopens a prior decision recorded in the scheduler comment and the SC-012 / FR-030 test pins.
* Decisions the operator should make:
  1. Adopt quality-first (all-three-types-beat-baseline first) as the `auto decide` policy, or keep footprint-first and only
     reorder the nli/2b pair.
  2. Whether the native gate (`LLMCTL_DECIDE_NATIVE=1`) may be treated as ON by default so kev-4b can be the out-of-the-box
     pick (it is gated "engine advance OD-1" today), or stays opt-in.
  3. Whether to require the pinned re-run (verification step 1) before the change merges.
  4. Whether `LLMCTL_DECIDE_PROFILE` default selection (lib/decide.sh) should follow the same ranking.
* A smaller option the operator could take without the gate decision: swap only `decide-2b` ahead of `decide-nli` in the
  gate-OFF list (2b beats baseline on noul and choice, nli only on choice). That still changes a pinned test and the fixture
  table, so it also needs sign-off, but it avoids the OD-1 gate question.

## 6. Files read for this analysis

`lib/scheduler.sh` (58-77, 1355-1400), `docs/decision-models.md`, `docs/hardware-tiers.md`, `docs/scripts/scheduler.md`,
`docs/user-manual.md` (755), `README.md` (138-146), `tests/test_scheduler.sh`, `tests/test_planner.sh`, `tests/test_decide_cli.sh`
(grep only), `cmd/llmctl-decide/cmd_serve.go` (376-392), `specs/009-jev-decision-models/evidence/live-models/INDEX.md`,
the `golden-stats.txt` / `latency.json` / `memory.txt` / `README.md` / `RESULT.txt` of the runs listed in section 1, and
`evidence/persistent-services/nezha-2026-10-09/README.md`. Not verified: `lib/decide.sh` default-profile selection logic;
whether the scheduler has an engine-version probe reusable for the b11379 check; the exact fixture "auto decide picks" cell for
`apple` / `cpu-heavy` (truncated in the output read).
