# G-159 design: separating host-RAM overhead from GPU-VRAM overhead in the planner

Status: DESIGN ONLY. Nothing in `lib/`, `models/`, `scripts/`, `tests/` or `docs/` was changed. All numbers below were produced by
running the real planner (`catalog_plan_json` through `llmctl`'s own `hw_probe_json | catalog_plan_json` path, the same call
`tests/test_planner.sh` makes) against scratch copies of the catalog and of `lib/catalog.sh` kept in the session scratchpad
(`LLMCTL_CATALOG` and a copied `lib/` selected the variant). Reproduction recipe is in section 9.

Related: `memory-wiring-proposal.md` (the attempt that was not applied), gaps-register G-137, G-138, G-159.

## 0. Summary

1. The two overheads are already stored separately in the catalog: `memory.ram` derives `defaults.overhead_mb` (host RAM above the
   weights, measured on a CPU placement), `memory.vram` derives `defaults.overhead_vram_mb` (VRAM a CPU-placement engine still holds
   through op-offload), `memory.gpu` derives `defaults.gpu_vram_mb` / `gpu_ram_mb` / `gpu_compute_buffer_mb` (GPU placement).
   So the schema does NOT need new keys to separate them.
2. The defect is a single line of consumer logic. `footprint()` does `kv += ovh` BEFORE calling `gpu_booking(..., kv)`, and the
   decision-capacity block does `dkv = kv_mb(...) + overhead_mb` before `gpu_booking(...)`. Both feed the host-RAM overhead into the
   `"estimated"` branch `return {"vram": size_mb + kv_est, ...}`. That is the leak: a CPU RAM peak becomes an estimated GPU VRAM
   booking. It is also pinned by an existing test assertion (`tests/test_planner.sh` line ~412, "overhead_mb is added to an ESTIMATED
   GPU-mode VRAM footprint"), i.e. it was a deliberate "conservative" choice on 2026-10-08, not an accident. The design reverses it
   on purpose and says so.
3. Recommended rule (needs one operator decision, section 7): an estimated GPU booking is `weights + KV` (a FLOOR), flagged
   `vram_provenance: estimated`, never inflated by a RAM figure. The RAM overhead is consumed only by the CPU placement
   (`ram_mb = weights + KV + overhead_mb`). With that rule the five nezha RAM peaks can be wired with ZERO change to any GPU-placement
   number and a measured, evidence-backed change to every CPU-placement number.
4. A prototype of that rule (3 changed lines in a scratch `lib/catalog.sh`) makes `tests/test_planner.sh` fail 14 assertions, versus
   23 for the wiring as originally attempted (both reproduced here: 23 matches the proposal doc). All 14 are legitimate: they
   encode the old CPU-placement numbers or the old leak.
5. Evidence limits are large and are stated in section 8: one CPU-only host, an unpinned snapshot, par 1 measurements, zero GPU-host
   data for the five profiles. The RAM peaks are real for the CPU placement; they say nothing certain about GPU VRAM.

## 1. Where the leak is (code facts)

`lib/catalog.sh` (line numbers as of this tree):

* `overhead_field(name, dfl, key)` (477): validated integer 0..65536.
* `gpu_booking()` (486): `measured` -> `defaults.gpu_vram_mb`, RAM `max(2048, gpu_ram_mb)`; `lower-bound` -> `size + kv_mb + gpu_compute_buffer_mb`,
  RAM 2048; otherwise `size + kv_est`, RAM 2048, provenance `estimated`. A measurement is reused only at the measured ctx, `par == 1`
  and KV type.
* `cpu_offload_vram()` (512): CPU-placement VRAM on a GPU host: measured (`overhead_vram_mb`) > compute-buffer floor > gpu-peak ceiling > 0 `unmeasured`.
* `footprint()` (530): `kv = kv_mb(...)`; `ovh = overhead_field("overhead_mb")`; **`kv += ovh`** (line ~569); then `gpu_booking(.., kv)` receives the
  inflated `kv`, so for an estimated profile `vram = size + kv_mb + overhead_mb`. The CPU branch uses `size_mb + kv` (also with `ovh`), which is the
  correct place for the RAM overhead.
* decision capacity (702-703): `dkv = kv_mb(...) + overhead_mb`, `dg = gpu_booking(..., dkv)`, `cpu_ram_mb = size_mb + dkv`. Same leak in the report that
  `sched_decision_probe` and the instance registry read.

Why it never mattered before wiring: only profiles with `overhead_mb != 0` leak, and those four (`julia`, `laya`, `kev-08b`, `lev`) all
have a `measured` gpu block, which bypasses the estimated branch. `decide-kev-08b` was the live proof of the bug (booked 5583, held 2900;
documented in `docs/hardware-tiers.md` "GPU-mode booking"). The five unwired profiles (`decide`, `decide-2b`, `decide-pro`, `decide-kev-4b`,
`decide-kev-9b`) are the first to expose it: `kev-4b` and `kev-9b` have gpu blocks (measured / lower-bound), so only `decide`, `decide-2b`,
`decide-pro` are affected on the GPU side; all five change on the CPU side.

## 2. Evidence inventory (what each number is, and is not)

All measured values below are read from files in this repository; "unpinned" means the nezha snapshot of 2026-10-08 has no commit/tree
pin (`memory-wiring-proposal.md`: "uncommitted snapshot, commit UNCONFIRMED"). The 2026-10-09 pinned nezha runs
(`nezha-pinned-*`) carry PROVENANCE but contain NO `memory-summary.json` for the five profiles (only `nezha-pinned-decide-nli` has a
`memory.txt`), so there is no pinned RAM peak for any of them.

| quantity | value | source | what it is |
|---|---|---|---|
| nezha CPU peak VmHWM, `decide` | 12799.4 MiB | `live-models/nezha-decide-2026-10-08/memory-summary.json` | CPU placement (`--n-gpu-layers 0`), ctx 8192, `--parallel 1`, q8_0 KV, default ubatch. Jumps 4572 -> 12743 MiB between "idle-warm" and "after-golden" |
| `decide-2b` | 8194.3 MiB | `nezha-decide-2b-2026-10-08` | same configuration |
| `decide-pro` | 7738.5 MiB | `nezha-decide-pro-2026-10-08` | same configuration |
| `decide-kev-4b` | 12952.2 MiB | `nezha-decide-kev-4b-2026-10-08` | CPU, f16 KV, `--ubatch-size 4096`, `--batch-size 4096` |
| `decide-kev-9b` | 17208.7 MiB | `nezha-decide-kev-9b-2026-10-08` | CPU, f16 KV, ubatch 4096 |
| nezha idle RSS (persistent services) | nli 3.2, 2b 2.2, pro 4.5, max 9.7 GiB | `persistent-services/nezha-2026-10-09/README.md`, `nezha-decide-max-2026-10-08/memory.json` (9504 MiB at idle-warm) | IDLE resident size, NOT a peak. Must not be used as an overhead input: the real peak for `decide-pro` is 1.7x its idle (7738 vs 4500). `decide-max` has no peak at all |
| nezha pinned `decide-nli` | VmHWM 3485 MiB | `nezha-pinned-decide-nli-2026-10-09/memory.txt` | ONNX encoder; the planner's onnx rule books `1663*3//2 + 512 = 3006`, i.e. 479 MiB under this measured peak (incidental finding, out of scope here) |
| anton `kev-08b` persistent | 1.3 GB RAM + 2.9 GB VRAM | `persistent-services/anton-2026-10-09/README.md` | GPU placement; agrees with `memory.gpu` (2900 MiB VRAM, gpu_ram 2019) |
| anton `kev-4b` gpu-mode | VRAM 7286-7328 MiB, VmHWM start 3279 MiB, gpu_ram 4899 | `live-models/decide-kev-4b/memory.txt`, catalog `memory.gpu` | GPU placement, ubatch 4096 |
| anton `kev-4b` cpu-mode VRAM | 4460 MiB | `live/decide-kev-4b/cpu-mode-vram-live-2026-10-08.txt` | single `nvidia-smi` sample 20 s after start, no request sent: NOT a peak |
| anton `decide-pro` / `decide-2b` CPU VmHWM | 7.36 GB / 7.8 GB | gaps-register G-159 | independent CPU-placement agreement with nezha (7.74 / 8.19 GiB) on a different host; this is the only second-host corroboration |

Cross-mode pairs (the only data on how a CPU RAM peak relates to GPU VRAM), computed from the catalog `memory` blocks:

| profile | CPU peak VmHWM (MiB) | GPU peak VRAM (MiB) | ratio | weights+KV (planner floor) | GPU VRAM above floor |
|---|---|---|---|---|---|
| decide-julia | 1442.0 | 212 | 6.8 | 288 | -76 |
| decide-laya | 987.3 | 574 | 1.7 | 556 | +18 |
| decide-kev-08b | 4913.9 | 2900 | 1.7 | 1030 | +1870 |
| decide-lev | 5688.1 | 3926 | 1.45 | 3896 | +30 |
| decide-kev-4b | 12952.2 | 7328 | 1.77 | 3916 | +3412 |

Reading: in 5/5 pairs the CPU peak exceeds the GPU VRAM peak (ratio 1.45-6.8), so a CPU peak is a usable CEILING for VRAM, but it overbooks by
>= 45% and by up to 6.8x. The GPU VRAM above the weights+KV floor is anywhere from about 0 (lev, laya, julia) to 3.4 GiB (kev-4b, whose engine is
launched with ubatch 4096 and whose compute buffer dominates). Neither "RAM overhead" nor "zero" is a good predictor of the GPU extra. Hosts
differ (CPU runs on nezha and partly anton, GPU runs on anton); n = 5; no `decide`/`decide-2b`/`decide-pro` GPU datum exists.

## 3. The rule per placement mode

Definitions: `W` weights MiB, `KV = kv_mb(ctx, parallel, kv_type)`, `ovh_ram = defaults.overhead_mb`, `ovh_off = defaults.overhead_vram_mb`.

| placement | resource | measured | lower-bound | unmeasured |
|---|---|---|---|---|
| GPU (`ngl 99`) | VRAM | `gpu_vram_mb` (peak engine-pid VRAM, same ctx/par/KV only) | `W + KV + gpu_compute_buffer_mb` | **`W + KV` (floor)**, `vram_provenance: estimated`. `ovh_ram` is NOT added (CHANGE) |
| GPU | host RAM | `max(2048, gpu_ram_mb)` | 2048 | 2048 floor (unchanged, flagged by `estimated`) |
| CPU (`ngl 0`) | host RAM | `W + KV + ovh_ram` | n/a | `W + KV` (floor); profile reported `ram` UNKNOWN (unchanged) |
| CPU on a GPU host | VRAM | `ovh_off` (measured) | compute-buffer floor | existing order: gpu-peak-ceiling, else 0 `unmeasured` (unchanged) |
| CPU on a CPU-only host | VRAM | 0, provenance `n/a` (unchanged) | | |

Invariant (the property to pin with a test): *`defaults.overhead_mb` is read by exactly one consumer path, the CPU-placement host-RAM sum.* Equivalently,
changing `overhead_mb` of any profile changes `ram_mb` only when `mode == cpu`/`none` and never changes any `gpu_vram_mb`/`vram_mb` in gpu mode.

### 3.1 When only one half is measured

| situation | booking | flag | refuse? |
|---|---|---|---|
| RAM (cpu) measured, GPU unmeasured (the five nezha profiles) | GPU: floor `W+KV`. CPU: `W+KV+ovh_ram` | `vram_provenance: estimated`, human plan prints `VRAM estimated`; `memory_status` stays derived from ram/vram halves | No. A floor is not a measurement but it is also not invented, and it is today's behaviour for these profiles |
| GPU measured, RAM (cpu) unmeasured (e.g. kev-4b today) | GPU: measured. CPU: `W+KV` floor | `ram` in `unknown_overhead`, `partial` | No |
| neither | floors for both | `unmeasured`, both UNKNOWN | No (unchanged) |
| a lower bound already exceeds the budget | n/a | `fits: false` | Yes, as now (e.g. kev-9b 4016 MiB cbuf on a smaller VRAM budget) |

The tempting alternative, booking the CPU RAM peak as a VRAM ceiling when the GPU is unmeasured ("ram-peak-ceiling"), is analysed as option B in section 7. It is
the same idea as the existing `gpu-peak-ceiling` in `cpu_offload_vram()`, in the opposite direction, and is defensible on the 5/5 pair evidence, but it flips
`decide`/`decide-2b` off the GPU on the 12 GiB reference host on the strength of a CPU-only measurement, so it should be an explicit operator choice, not a side effect of wiring.

## 4. Schema and validator changes

Principle: keep every existing key (no rename), because the keys already separate the two overheads and renaming has a large blast radius (section 6).
Changes are additive and tighten what a half is allowed to be fed from.

### 4.1 Catalog schema (`models/catalog.json`, `profiles.<name>.memory`)

* `memory.ram` gains an optional, derived `measured_at` object `{ "ngl": 0, "parallel": 1, "kv_cache_type": "q8_0", "ubatch": null }` read from the
  `engine-cmdline.txt` sitting beside the evidence (the same trick `_cmdline_ctx` already uses for `memory.gpu.ctx`), plus a literal `placement: "cpu"`.
  `memory.vram` gets `placement: "cpu-offload"`, `memory.gpu` gets `placement: "gpu"`.
* Derived-key ownership table (new constant `KEY_OWNER` in `scripts/overhead_from_memory.py`, also the doc table):
  `overhead_mb -> memory.ram -> cpu host RAM`, `overhead_vram_mb -> memory.vram -> cpu-placement VRAM`, `gpu_vram_mb`/`gpu_ram_mb`/`gpu_compute_buffer_mb -> memory.gpu`.
* The five nezha profiles move `memory.ram` from `{"status":"unmeasured","reason":"... NOT wired ..."}` to
  `{"status":"measured","format":"memory-summary-json","evidence":"specs/009-jev-decision-models/evidence/live-models/nezha-<p>-2026-10-08/memory-summary.json","host":"nezha", ...derived}`.
  `scripts/overhead_from_memory.py --write` produces the numbers (reproduced here), never typed by hand.

### 4.2 `scripts/overhead_from_memory.py`

1. **Placement gate (new)**: when `engine-cmdline.txt` exists beside a `ram` or `vram` evidence file its `--n-gpu-layers` MUST be `0`; beside a `gpu` evidence file it
   MUST be `> 0`; a mismatch raises `ValueError` ("memory.ram evidence is a GPU-placement run"). Absent file = no check (legacy `ctx-peak-txt` evidence has none), reported as
   `NOTE:` so it is visible. This is what stops a GPU run being read as a RAM overhead or the reverse. All five nezha cmdlines show `--n-gpu-layers 0` (checked).
2. **Config recorded**: `derive()` writes `memory.ram.measured_at` from the cmdline (par, KV type, ubatch) next to the existing `peak_hwm_mib`/`weights_mib`.
3. **Optional D3 (separately decidable, section 5)**: KV double-count correction in `overhead_from_peak`.
4. `check()`: new `DIFF` when a derived key is present without its owning half measured (already partly covered by "unmeasured profile gains a number by hand"), and when
   `placement` disagrees with the half.

### 4.3 `tests/test_catalog_json.sh` (section 8) and `evidence_paths.py`

* Structural: for every measured half, `placement` equals the half's expected value; for `ram`/`vram`/`gpu` with a sibling `engine-cmdline.txt`, the `ngl` rule above.
* The existing "measured RAM needs overhead_mb and window_tokens" check stays.
* New mutations (each must be REJECTED, in the `mut8` style): `ram.evidence` pointed at a GPU-run `memory.txt`; `memory.ram.placement` flipped to `"gpu"`; `overhead_mb`
  hand-typed on a profile whose `ram` is unmeasured (exists); `memory.gpu` fed from a `memory-summary.json` of a `--n-gpu-layers 0` run.

### 4.4 Planner/CLI output

* `plan --json`: add `ram_provenance` (`measured` | `unmeasured`, from `memory.ram.status`) beside the existing `vram_provenance`/`cpu_vram_provenance`; no existing field changes meaning.
  `memory_status`/`unknown_overhead` keep their exact current semantics (ram/vram halves), so existing assertions on them are unaffected by the schema work.
* Human plan: a CPU recommendation of a profile with an unmeasured `ram` half keeps `overhead UNKNOWN`; an estimated GPU recommendation keeps `VRAM estimated`.

## 5. Optional D3: the KV double count (decide separately)

`overhead_mb = ceil(1.10 * (peak VmHWM - weights))` includes the KV the measured run allocated, and the planner then adds `kv_mb(ctx, par, kv_type)` again
(`ram = W + KV + ovh`). On the five nezha runs (par 1) that double counts 544 MiB (q8_0) or 1024 MiB (f16). Correcting it
(`ceil(1.10 * (peak - W - KV_measured))`, KV from the cmdline) changes the derived values and the resulting CPU RAM:

| profile | overhead_mb now-rule | KV-corrected | CPU RAM now-rule | CPU RAM corrected |
|---|---|---|---|---|
| decide | 11238 | 10640 | 14909 | 14311 |
| decide-2b | 6904 | 6305 | 9910 | 9311 |
| decide-pro | 3923 | 3325 | 9183 | 8585 |
| decide-kev-4b | 11066 | 9939 | 14982 | 13855 |
| decide-kev-9b | 12259 | 11133 | 19347 | 18221 |

It would also change the four already-wired profiles (`kev-08b`, `lev`, `julia`, `laya`), which are "measured" today, so it is a second, independent change to
shipped numbers. Recommendation: do NOT bundle it with G-159. Keep the documented rule (`peak - weights`, +10%) as is: the over-booking is bounded, conservative, and
already documented in `scripts/overhead_from_memory.py`. Track it as its own gap.

Related pre-existing mismatch (also not part of this change): the nezha runs are `--parallel 1` (deterministic mode launches one slot) while the catalog books
`parallel: 2` for `decide`/`decide-2b`/`decide-pro`, so KV is over-booked by 544 MiB in every figure below.

## 6. Migration of existing catalog entries (per profile)

Prototype = the proposed rule (GPU estimate excludes `overhead_mb`) + the five `memory.ram` blocks declared and `--write` derived. "Now" = current code, current catalog.
"Proposal" = current code, wired catalog (the original attempt). Values are `mode ram_mb / vram_mb`.

| profile | change to `memory` / `defaults` | GPU booking (baseline fixture) | CPU placement RAM |
|---|---|---|---|
| decide | `memory.ram` -> measured; `overhead_mb` 0 -> 11238; `window_tokens` 8192 | now 3671, proposal 14909 (mode cpu), **prototype 3671** | 3671 -> 14909 |
| decide-2b | `overhead_mb` 0 -> 6904 | now 3006, proposal 9910, **prototype 3006** | 3006 -> 9910 |
| decide-pro | `overhead_mb` 0 -> 3923 | now 5260 (tier-gated), proposal 9183, **prototype 5260** | 5260 -> 9183 |
| decide-kev-4b | `memory.ram` measured; `overhead_mb` 0 -> 11066; `memory_status` partial -> measured | measured 7328 (unchanged) | 3916 -> 14982 |
| decide-kev-9b | `overhead_mb` 0 -> 12259; ram measured, vram still unmeasured => `partial` | lower-bound 4016+W+KV = 11104 (unchanged) | 7088 -> 19347 |
| decide-max | none (no memory summary exists) | unchanged | unchanged (idle 9.7 GiB is not a peak; stays UNKNOWN) |
| decide-nli | none | n/a | unchanged (onnx rule; measured 3485 MiB peak vs 3006 booked is a separate finding) |
| decide-tiny | none | unchanged | unchanged |
| julia, laya, kev-08b, lev | none (already derived) | unchanged (measured gpu) | unchanged |

Prototype code change (scratch only, applied to a copy of `lib/catalog.sh`):

```
footprint():      g = gpu_booking(..., kv)    # called BEFORE the line  kv += ovh
decision cap.:    dkv0 = kv_mb(...); dkv = dkv0 + overhead_mb
                  dg = gpu_booking(..., dkv0)  # cpu_ram_mb = size_mb + dkv stays as it is
```

### 6.1 Planner results, all ten fixtures (prototype vs now vs proposal)

Per-fixture decide-profile outcome, `mode ram/vram rec(0|1) gpuInst/cpuInst`. Only fixtures/rows that move are shown in full; unchanged rows say so.

baseline (RAM budget 25904, VRAM 10444):

| profile | now | proposal (as attempted) | prototype (this design) |
|---|---|---|---|
| decide | gpu 2048/3671 rec1 g2/c7 | cpu 14909/0 rec1 g0/c1 | **gpu 2048/3671 rec1 g2/c1** |
| decide-2b | gpu 2048/3006 rec1 g3/c8 | gpu 2048/9910 rec1 g1/c2 | **gpu 2048/3006 rec1 g3/c2** |
| decide-pro | gpu 2048/5260 rec0 (tier) | gpu 2048/9183 rec0 | gpu 2048/5260 rec0 |
| decide-kev-4b | gpu 4899/7328 rec1 g1/c2 | same booking, g1/c1 | gpu 4899/7328 rec1 g1/c1 |
| decide-kev-9b | cpu 7088/4016 rec0 | cpu 19347/4016 rec0 | cpu 19347/4016 rec0 |

`decision_instances` totals on baseline: `decide` total slots 14 -> 4 (cpu instances 7 -> 1, best_placement cpu -> gpu); `decide-2b` 16 -> 6 (cpu 8 -> 2).
The reduction is the real finding: the 7 CPU instances of `decide` were never possible, one instance held 12.8 GiB on nezha.

workstation (RAM 235904, VRAM 27852): GPU instances unchanged for every profile (`decide` g7, `decide-2b` g9, `decide-pro` g5). Proposal collapsed them to g1/g2/g3.
CPU instances: `decide` 64 -> 15, `decide-2b` 78 -> 23, `decide-pro` 44 -> 25. `recommended` set unchanged; coresidency groups 7 -> 7 (proposal 8).

All other fixtures (recommended-set delta vs now; groups before -> after):

| fixture | prototype | proposal |
|---|---|---|
| apple | no recommended change; `decide` cpu inst 12 -> 3, `decide-2b` 15 -> 4, `decide-pro` 8 -> 4, `kev-4b` 7 -> 3, `kev-9b` 6 -> 2; GPU unchanged; groups 6 -> 6 | GPU instances collapse (`decide` 10 -> 2) |
| constrained | no recommended change; `decide`/`decide-2b` stay gpu; `kev-4b` cpu RAM 3916 -> 14982; groups 7 -> 7 | `decide`/`decide-2b` flip to cpu |
| cpu-heavy (RAM 15904, no GPU) | **`decide-kev-9b` leaves the recommended set** (cpu 19347 > 15904, mode none); `decide`/`2b`/`pro`/`kev-4b` stay recommended, 1 cpu instance each; groups 8 -> 11 | same |
| ram-contended-auto-eviction (RAM 9904, VRAM 85) | **`decide` and `decide-2b` leave the recommended set** (cpu 14909 / 9910 > 9904); groups 3 -> 2 | same |
| small-exact (RAM 4096) | no recommended change (they were already not recommended) | no recommended change |
| tiny | none | none |
| vram-contended-coresident (VRAM 5100) | no recommended change; `decide`/`decide-2b` stay gpu; groups 9 -> 9 | flip to cpu, groups 9 -> 7 |
| vram-contended (VRAM 2550) | no recommended change; `decide` cpu inst 7 -> 1, `decide-2b` 8 -> 2; groups 4 -> 5 | same as prototype |

Two rows change the published SC-012 table in `docs/hardware-tiers.md` ("Planner and `auto decide`"): `cpu-heavy` loses `decide-kev-9b`,
`ram-contended-auto-eviction` loses `decide` and `decide-2b`. The second also resolves the standing caveat in "How the planner estimates memory" ("unmeasured profiles can be
recommended on a RAM-constrained fixture ... that row is not evidence they fit"): with the CPU RAM peak wired they are refused there with numbers, which is the honest outcome.

### 6.2 Test suite impact (measured)

Scratch roots running the real test files with the wired catalog:

| test file | current tree | proposal as attempted | prototype |
|---|---|---|---|
| `tests/test_planner.sh` | 180 ok / 0 FAIL | 157 ok / **23 FAIL** | 166 ok / **14 FAIL** |
| `tests/test_decision_capacity.sh` | 35 / 0 | not run | 35 / 0 |
| `tests/test_decide_scale.sh` | 78 / 0 | not run | 78 / 0 |
| `tests/test_catalog_json.sh` | 64 / 0 | not run | 64 / 0 (wired catalog passes the existing evidence checks) |

The 14 prototype failures in `test_planner.sh`, all intentional and listed so they can be updated deliberately, not waved through:

1. Baseline/workstation/vram-contended `decision_instances` arithmetic: `decide` cpu instances (7 -> 1; workstation 64 -> 15; vram-contended 7 -> 1), `decide` total slots (14 -> 4),
   `decide-2b` cpu instances (8 -> 2) and total slots (16 -> 6), workstation `decide-pro` cpu instances (44 -> 25) and total slots (88 -> 50). (8 assertions)
2. SC-012 doc-row checks for `cpu-heavy` and `ram-contended-auto-eviction` (2 assertions; the doc rows must change, the test already fails if the table drifts).
3. The T139 leak test, "overhead_mb is added to an ESTIMATED GPU-mode VRAM footprint (decide-2b)": expected +500, becomes 0. Must be INVERTED to pin the new invariant (1 assertion).
4. "overhead_mb is added to the CPU-mode RAM footprint (decide-kev-4b, cpu-heavy)": the test injects an absolute 500, which no longer exceeds the wired 11066; rewrite
   it to inject on `decide-tiny` or to assert a delta against the wired value (1 assertion).
5. G-138 "kev-4b's VRAM half is now measured; only its RAM overhead stays UNKNOWN" becomes measured/empty once kev-4b RAM is wired (1 assertion).
6. G-138 kev-9b "cpu 4016 7088" becomes `cpu 4016 19347` (1 assertion).

## 7. Operator decision (needed for exactly one question)

Nothing in sections 3-6 changes a single GPU-placement number, so the schema work and the CPU-RAM wiring need no operator decision beyond approving the plan. The one
real policy choice is what an UNMEASURED GPU placement books:

| option | unmeasured GPU VRAM | `decide` / `decide-2b` / `decide-pro` on the 12 GiB reference host | risk | needs |
|---|---|---|---|---|
| **A. floor (recommended default)** | `W + KV` | unchanged: GPU, 3671 / 3006 / 5260 | may under-book: the pair table shows up to +3412 MiB (kev-4b) over the floor; start-time live free-VRAM admission and the engine's own `cudaMalloc` failure are the backstops (this is how G-138 surfaced) | nothing; this is current behaviour |
| B. RAM-peak ceiling (opt-in, `LLMCTL_PLAN_GPU_UNMEASURED=ceiling`, new provenance `ram-peak-ceiling`) | `max(W+KV, peak_hwm + KV_delta)`: decide 13344, 2b 8739, pro 8283 | `decide` flips to cpu (13344 > 10444), `decide-2b` stays gpu (8739) | overbooks by >= 45% (5/5 pairs) and strands GPU capacity on evidence from a CPU-only host; recreates the kev-08b 5583-vs-2900 mistake | operator choice; a new env knob and doc paragraph |
| C. refuse until measured | none | `decide`, `decide-2b`, `decide-pro` not recommended on any GPU host | removes the only working defaults on every GPU host | operator choice; breaks SC-012 rows |

Recommendation: A as the shipped default, with a tracked item to measure `decide`, `decide-2b`, `decide-pro` in GPU mode on anton (the same `gpu-memory-txt` procedure used for
the others; it turns their `estimated` into `measured` and removes the question). Offer B as an opt-in for operators who prefer refusing over the risk of a failed start. C is not
recommended. Also an operator decision, but independent: whether to rename `overhead_mb` -> `overhead_ram_mb` (see section 4 preface); recommended NO for this change.

## 8. Evidence limits and what this design does NOT claim

* The five RAM peaks are from ONE CPU-only host (nezha, i7-1165G7, no GPU), from an UNPINNED snapshot (commit UNCONFIRMED), at ctx 8192, `--parallel 1`, a short golden/probe
  workload plus gateway states at the window limit. They are peaks of that workload, not proven worst cases. The 2026-10-09 pinned nezha runs record no memory summaries for these profiles.
* Second-host corroboration exists only for `decide-pro` and `decide-2b` CPU VmHWM (anton, 7.36 / 7.8 GB, per G-159), not for `decide`, `decide-kev-4b`, `decide-kev-9b`.
* Nothing here measures any of the five profiles' GPU VRAM except `kev-4b` (7328, ubatch 4096) and the `kev-9b` lower bound (4016 cbuf, an OOM, not a peak). `decide`, `decide-2b`, `decide-pro`
  GPU VRAM is UNKNOWN; the floor is a floor, not an estimate of the truth, and nothing in this document says they fit a 12 GiB GPU.
* The cross-mode pair table has n = 5 and mixes hosts, builds and ubatch settings; it supports "a CPU peak was an upper bound in all five pairs", not a ratio or a forecast.
* The G-138 caveats still apply and are untouched: `kev-4b` cpu-mode VRAM is one post-load `nvidia-smi` sample, `lev` cpu-mode VRAM is a gpu-peak ceiling, `kev-9b` is a floor.
* Idle RSS figures (nli 3.2, 2b 2.2, pro 4.5, max 9.7 GiB) are not peaks and are deliberately not used. `decide-max` stays fully UNKNOWN.
* Numbers in section 6 come from fixtures (`tests/fixtures/hw-*.json`) and the scratch prototype; they are planner outputs, not host measurements. The prototype was not run through
  `bin/llmctl` end to end, only through `hw_probe_json | catalog_plan_json` and the repo's own test files in scratch copies of the tree.
* The full-suite (`make test`) was not run; only the four test files named in 6.2.

## 9. RED-first test list (to be written before any implementation)

Each item is written and observed to FAIL against the unmodified tree for the stated reason, then the change is made, then it goes GREEN; each has a paired mutation.

1. `tests/test_planner.sh`: **invariant, GPU path ignores RAM overhead.** Scratch catalog sets `decide-2b.defaults.overhead_mb = 500` (no gpu block): assert GPU `vram_mb` delta is 0 and
   `ram_mb` in cpu mode delta is +500. RED today: delta is +500 on VRAM (this is the inverted existing assertion). Mutation: restore `kv += ovh` before `gpu_booking`; test must FAIL.
2. Same invariant for the decision-capacity block: `decision_instances.decide-2b.placements.gpu.vram_mb` unchanged by `overhead_mb`, `placements.cpu.ram_mb` +500. RED today. Mutation: re-add `overhead_mb` to `dkv`.
3. Golden-false: a profile with a measured gpu block (`decide-kev-4b`, 7328) is not moved by any `overhead_mb` (exists; keep).
4. Golden-false: a profile with no `overhead_mb` (`decide-tiny`) keeps every number (exists; keep).
5. Wiring test: with the five `memory.ram` blocks declared, `baseline` GPU numbers for `decide`/`decide-2b`/`decide-pro` equal the pre-wiring numbers (3671/3006/5260) and cpu `ram_mb` equals
   `W + KV + overhead_mb` (14909/9910/9183). RED before wiring (overhead 0).
6. CPU-only host (`hw-nogpu`) books `decide` cpu 14909 RAM, 0 VRAM, `cpu_vram_provenance: n/a`; refuses it on a 9904 MiB RAM budget with the exact shortfall (the `ram-contended-auto-eviction` row).
7. `tests/test_catalog_json.sh` / `scripts/overhead_from_memory.py` + `tests/py/test_overhead_from_memory.py`: placement gate. RED: a `memory.ram` whose evidence sits beside a cmdline with `--n-gpu-layers 99` is accepted today;
   must be refused. Mutations: flip `placement`; point `ram.evidence` at a gpu run; strip `measured_at`.
8. `plan --json` exposes `ram_provenance` (`measured` for the wired five, `unmeasured` for `decide-max`/`decide-tiny`/`decide-nli`); `memory_status`/`unknown_overhead` unchanged for every non-wired profile (golden-false).
9. Update, deliberately and one by one, the 14 failing assertions in 6.2 plus the two `docs/hardware-tiers.md` SC-012 rows; the doc-row test is the guard that the docs follow the planner.
10. If option B is accepted: provenance `ram-peak-ceiling` appears only when the gpu half is unmeasured AND `memory.ram` is measured; a measured gpu block still wins (golden-false); mutation: ceiling applied to a measured profile.
11. Docs gate: `docs/hardware-tiers.md` "How the planner estimates memory" states the ownership table of section 4.2 (grep-checked by the existing docs audit), and no sentence says `overhead_mb` is added to VRAM.

Reproduction of this document's numbers (all under the session scratchpad, nothing in the repo):
`cat-wired.json` = `models/catalog.json` + the five `memory.ram` blocks, then `scripts/overhead_from_memory.py --catalog cat-wired.json --write` (prints the derived values 11238/6904/3923/11066/12259);
`proto/lib/catalog.sh` = the two-hunk patch above; `plan.sh LIBROOT CATALOG FIXTURE` runs `LLMCTL_FAKE_HW=tests/fixtures/hw-<fx>.json hw_probe_json | catalog_plan_json`; `root-{cur,prop,proto}/` are copies of the tree
(specs symlinked) in which `bash tests/test_planner.sh` etc. were run.

## 10. Risks

* **Reversing a deliberate, test-pinned choice.** The 2026-10-08 authors chose "RAM overhead into the estimated VRAM" as conservative. If the operator prefers conservative-by-default, option B is the explicit, flagged
  way to keep that stance; the unflagged leak is not.
* **Under-booking unmeasured GPU (option A).** Real risk, bounded by live free-VRAM admission and the engine's own allocation failure; it will produce a failed start, not a host hang. Mitigation is the anton GPU measurement.
* **Doc/test churn.** Two SC-012 rows and 14 assertions change; the SC-012 test fails if docs drift, so the change is self-checking but must be done in one commit.
* **KV over-booking** (section 5 and the `parallel: 2` note) makes every CPU figure about 0.5-1.1 GiB high. Conservative, documented, left alone.
* **`decide-kev-9b` leaves `cpu-heavy`'s recommended set** and `decide`/`decide-2b` leave `ram-contended-auto-eviction`'s. These are correct under the evidence but visible product-behaviour changes; call them out in CHANGELOG.
* **Placement gate may reject legacy evidence** that has no `engine-cmdline.txt`; handled as a visible `NOTE`, not a failure, so existing derivations are unaffected (checked: `test_catalog_json.sh` passes against the wired catalog).
* **Unpinned snapshot.** If the nezha snapshot is later found not to match a shipped llama.cpp pin (the pinned runs of 2026-10-09 use build commit 1537a0a), the numbers may shift; the derivation is scripted, so a re-measure is `--write` away.
* **Not a closure of G-159's measurement side.** After this lands, `decide`, `decide-2b`, `decide-pro` GPU VRAM and `decide-max` memory remain UNKNOWN and must stay tracked.
