# Hardware tiers

llmctl classifies the host from the live probe (`lib/hardware.sh`) — nothing
is hardcoded. Tier rules (`lib/catalog.sh`, `catalog_classify_tier`):

| tier | rule |
|---|---|
| `datacenter` | cores ≥ 32 **and** RAM ≥ 96 GiB **and** free storage ≥ 400 GiB |
| `workstation` | cores ≥ 24 **or** RAM ≥ 64 GiB **or** total VRAM ≥ 20 GiB |
| `baseline` | cores ≥ 8 **and** RAM ≥ 32 GiB |
| `below-minimum` | anything smaller |

Profiles declare a `min_tier` in `models/catalog.json`; the planner
recommends a profile only when `tier(host) >= min_tier(profile)` **and** its
footprint fits. Tier gating affects recommendations and `llmctl auto`; an
explicit `llmctl start <profile>` is allowed whenever the footprint fits.

## Baseline reference (the supported minimum)

Ryzen 7 2700X (8c) · 32 GB RAM · RTX 3060 12 GB · NVMe.

Budgets: RAM 25904 MiB (avail − 4 GiB) · VRAM 10444 MiB (12 GiB − 15%).

* Recommended: `fast`, `coder`, `vision`, `moe-fast`, `small`, plus nine
  decision profiles (`decide-tiny`, `decide`, `decide-nli`, `decide-2b` and
  the five native `/v1/systemone` profiles `decide-julia`, `decide-kev-08b`,
  `decide-kev-4b`, `decide-laya`, `decide-lev`;
  see "Planner and `auto decide`" below - these joined the recommended set
  with the decision-model feature, they are not chat models).
* `coder`, `moe-fast` run CPU-mode here (17.7/11.6 GiB models don't fit
  10444 MiB of VRAM budget); `fast`, `vision`, `small` run fully on GPU.
* Example co-residency (greedy, port order):
  `fast + coder + vision` together, or `moe-fast + small` together.
* `vision-pro`, `ws-*`, `colibri-*` (and the decision profiles `decide-pro`,
  `decide-max`, `decide-kev-9b`) are tier-gated off.

## Workstation

64-core Threadripper · 256 GB RAM · 32 GB VRAM · 2 TB NVMe qualifies as
`datacenter` by the rules above (a superset of workstation): every profile is
recommended, all GGUF models run fully GPU-offloaded, and co-residency groups
span e.g. `fast + coder`, `vision + vision-pro`, `ws-moe-30b + colibri-*`.

An Apple Silicon Mac (e.g. M4 Max, 64 GB unified) classifies as
`workstation`: VRAM is estimated as 0.7 × unified RAM (matching Metal's
recommended working-set limit), so everything except the datacenter-gated
`colibri-glm` is recommended.

## Decision profiles

The twelve decide-capable profiles (`docs/decision-models.md`) declare the values below. They are read from `models/catalog.json`
(sizes are the sum of the catalog's file sizes); the authoritative per-host answer is always `llmctl plan` (see "How the planner estimates memory").
Ports are the **fixed-strategy** defaults; under the dynamic strategy a running profile is given a free port and `llmctl plan`/`llmctl decide registry` show the assigned one
([ports](ports.md), [registry-discovery](registry-discovery.md)).

| profile | engine | min_tier | size | port |
|---|---|---|---|---|
| `decide-tiny` | `llama` | `below-minimum` (recommends only, never blocks) | ~505 MiB | 8092 |
| `decide` | `llama` | `baseline` | ~2.52 GiB | 8093 |
| `decide-pro` | `llama` | `workstation` | ~4.07 GiB | 8094 |
| `decide-nli` | `onnx` | `below-minimum` (recommends only, never blocks) | ~1.62 GiB | 8096 |
| `decide-2b` | `llama` | `baseline` | ~1.87 GiB | 8098 |
| `decide-max` | `llama` | `workstation` | ~8.87 GiB | 8097 |
| `decide-julia` | `llama` (native `/v1/systemone`) | `below-minimum` (recommends only, never blocks) | ~160 MiB | 8103 |
| `decide-kev-08b` | `llama` (native) | `below-minimum` (recommends only, never blocks) | ~775 MiB | 8104 |
| `decide-kev-4b` | `llama` (native) | `baseline` | ~2.82 GiB | 8105 |
| `decide-kev-9b` | `llama` (native) | `workstation` | ~5.92 GiB | 8106 |
| `decide-laya` | `llama` (native) | `below-minimum` (recommends only, never blocks) | ~429 MiB | 8107 |
| `decide-lev` | `llama` (native) | `baseline` | ~2.80 GiB | 8108 |

On the baseline reference machine, `decide-tiny`, `decide-nli`, `decide-2b`
and `decide` are recommended alongside the chat/coder/vision profiles;
`decide-pro`, `decide-max` and `decide-kev-9b` are tier-gated off (`workstation`). The
`onnx`-engine `decide-nli` reserves no VRAM at all (CPU-only inference;
RAM = model size × 1.5 + 512 MiB), so it fits hosts with no GPU budget to
spare.

### Multi-instance capacity (`decision_instances`)

`llmctl plan` (and `llmctl decide capacity`) reports a
`decision_instances` subtree: per decide-capable profile, the maximum
number of parallel llama-server instances that would fit in **GPU mode**
and in **CPU mode** under the same RAM/VRAM budgets the planner already
computed (4 GiB RAM headroom, 15% VRAM headroom) — no budget logic is
changed, it is only re-divided.

Semantics, honestly:

* `instances_gpu` and `instances_cpu` are **alternative placements, never
  additive** — a host runs instances on GPU *or* on CPU, not both counts
  at once. GPU placement uses the fixed 2048 MiB RAM reservation the
  planner's footprint already uses for gpu mode; CPU placement is
  weights+KV with `ngl 0`. `onnx`-engine profiles (`decide-nli`) are
  CPU-only encoder inference: `instances_gpu` is always 0 (GPU placement
  is not applicable), and the CPU per-instance footprint is the same
  `model size × 1.5 + 512 MiB` reservation the planner's onnx footprint
  branch computes.
* `total_decision_slots = max(instances_gpu, instances_cpu) × slots per
  instance` (the profile's `parallel` default: 4 for `decide-tiny`, 2 for
  `decide`/`decide-pro`/`decide-2b`/`decide-max`, 1 for `decide-nli` and for
  each of the six native profiles).
* **Each profile is computed alone** against the full current budgets:
  profiles are NOT additive with each other or with running chat profiles
  (asking for 6 `decide-tiny` instances and 2 `decide` instances at once
  would need both budgets). The figure is the capacity of the *best single
  placement* of that one profile (`best_placement`, GPU on a tie); a mixed
  GPU+CPU placement of one profile is not reported.
* **Additive fields** on top of the original shape (nothing was renamed):
  `protocol` (`letter-logit` / `systemone-native` / `nli-onnx`),
  `best_placement` (`gpu` / `cpu` / `null`), `placements` (the GPU and CPU
  per-instance footprints the admission check uses; `gpu` is `null` for the
  CPU-only encoder) and `tier_ok`. `per_instance` keeps reporting the GPU
  placement when it fits, else the CPU placement.
* **The report equals admission (SC-010).** Starting instances of one
  profile one at a time through the scheduler's admission predicate
  (`_sched_admission_fits`, the same function `llmctl start` and
  `llmctl enable` decide with; probe: `sched_decision_probe <profile>
  <gpu|cpu>`) on an otherwise idle budget succeeds exactly
  `instances_gpu` / `instances_cpu` times and the next attempt is refused
  with the exact numbers (`cannot start instance 3 of 'decide' (gpu
  placement): needs 2048 MiB RAM + 3671 MiB VRAM, but only 21808 MiB RAM +
  3102 MiB VRAM remain`). `tests/test_decision_capacity.sh` proves this for
  every decision profile on every hardware fixture. **The tier gate:** the
  report and the instance probe count a tier-gated profile as 0 instances
  (`reason: tier gate ...`), while a plain `llmctl start <profile>` of the
  single base instance stays allowed whenever the footprint fits (tier
  gating is advisory for explicit starts, see the top of this page); the
  multi-instance start path is expected to honour the tier gate the report
  states.
* It is a **read-only capacity report**: it reserves nothing and starts
  nothing. Runtime admission still goes through the scheduler's own
  budget check when a profile is actually started. v1 cannot launch N
  co-resident copies of one profile (ports are fixed per profile;
  `LLMCTL_PORT_<PROFILE>` gives one override) — see
  `docs/decision-models.md` "Honest limitations".
* Tier-gated or non-fitting profiles report 0/0 with a `reason` field
  (`tier gate: ...` or `footprint exceeds RAM and VRAM budgets`); `reason`
  is present only when no instance fits.

Example (the deterministic `tests/fixtures/hw-baseline.json` fixture —
Ryzen 7 2700X, 32 GB RAM, RTX 3060 12 GB; RAM budget 25904 MiB, VRAM
budget 10444 MiB — asserted exactly by `tests/test_decide.sh`):

| profile | tier-ok | gpu-instances | cpu-instances | slots/instance | total_decision_slots |
|---|---|---|---|---|---|
| `decide-tiny` | yes | 6 (min(10444//1592, 25904//2048)) | 16 (25904//1592) | 4 | 64 |
| `decide` | yes | 2 | 7 | 2 | 14 |
| `decide-pro` | no (tier gate) | 0 | 0 | 2 | 0 |

## How the planner estimates memory

`llmctl plan` computes, per profile, a footprint and compares it with the host budgets (RAM: available minus 4 GiB; VRAM: 85% of what is free now).
For a GGUF profile the estimate is **weights (the catalog's file sizes) + KV cache (derived from the profile's context, parallel slots and KV type) + the profile's declared
`defaults.overhead_mb`** (default 0). On GPU it reserves that much VRAM plus a fixed 2048 MiB of RAM; if it does not fit the GPU it tries CPU mode with the same sum in RAM;
otherwise the profile does not fit and `llmctl start` refuses with the exact numbers that were short. The `onnx` and `colibri` engines use their own rules (see the sections
above and below).

Known gap, stated plainly: that estimate **under-reserves the native `/v1/systemone` profiles** - their measured working set above weights and KV (compute buffers) is larger
than the flat rule sees, which is why `decide-julia`, `decide-laya`, `decide-kev-08b` and `decide-lev` carry a measured `overhead_mb` (derived from recorded evidence by `scripts/overhead_from_memory.py`) and the other decision profiles do not yet. For a profile without a measured half the planner books **0** for it, which is a floor and not a measurement: `llmctl plan --json` reports `memory_status` (`measured`, `partial` or `unmeasured`) and `unknown_overhead` (the unmeasured halves: `ram`, `vram`), and the human plan marks such a recommendation `overhead UNKNOWN`. In particular `decide-lev` is `partial` (its VRAM half was only measured on a CPU-only host) and the unmeasured profiles (e.g. `decide-2b`) can be recommended on a RAM-constrained fixture such as `ram-contended-auto-eviction` while a smaller, measured profile such as `decide-kev-08b` is refused - that row is **not** evidence they fit. **cpu-mode VRAM on a CUDA host (G-138):** a placement at `-ngl 0` still holds VRAM (llama.cpp op-offload; `decide-kev-4b` held 4460 MiB while 0 was booked - `specs/009-jev-decision-models/evidence/live/decide-kev-4b/cpu-mode-vram-live-2026-10-08.txt`). On a host WITH a GPU the planner therefore books, in this order of authority, a *measured* cpu-mode peak (x1.10; `plan --json` `cpu_vram_provenance: measured`), else a recorded compute-buffer *floor* (`floor`), else - when only the gpu-mode peak is measured (`decide-lev`) - that gpu peak as a *ceiling* (`gpu-peak-ceiling`; the cpu-mode offload was below the gpu-mode peak in all 4 profiles measured in both modes, but a ceiling is not a measurement and the profile stays `partial`), else 0 (`unmeasured`, still reported UNKNOWN). A CPU-only host books 0 (`n/a`). A profile whose booked VRAM exceeds the budget is refused, never silently admitted at 0. This page
deliberately does **not** list reserved-memory figures for the native profiles: run `llmctl plan` on the host you care about. On the development host the scheduler refused to start `decide-kev-4b`,
`decide-kev-9b` and `decide-lev` for lack of free RAM (it printed the numbers); refusing with numbers is the intended behaviour on a RAM-constrained host
(`specs/009-jev-decision-models/evidence/live/NATIVE-REPORT.md`).

**GPU-mode booking (live run 2026-10-08, 12 GiB GPU).** The weights + KV rule cannot see the engine's compute buffer, which a native
`/v1/systemone` engine sizes from `--ubatch-size 4096`: `decide-kev-9b` was admitted at 7088 MiB and failed `cudaMalloc` of a 4016 MiB
compute buffer, `decide-kev-4b` was booked 3916 MiB and held 7328 MiB, and `decide-kev-08b` was booked 5583 MiB (its cpu-mode RAM
`overhead_mb` was added to VRAM) and held 2900 MiB. A profile may therefore carry `memory.gpu`, derived by `scripts/overhead_from_memory.py`
from the evidence file it names: `measured` (format `gpu-memory-txt`) books the engine pid's highest recorded VRAM as the GPU need and
`max(2048, peak VmHWM)` as its RAM; `lower-bound` (format `oom-compute-buffer-jsonl`) books weights + KV + the compute buffer the engine
failed to allocate - a floor, the true peak stays UNKNOWN - and a cpu placement then books that buffer as offload VRAM instead of 0. A
measurement is reused only at the context, slot count and KV type it was taken at; any override falls back to the estimate. Every other
profile keeps the estimate and `llmctl plan --json` reports `vram_provenance` (`measured`, `lower-bound`, `estimated`), `vram_evidence`
and `gpu_vram_mb`; the human plan marks an estimated GPU booking of a recommended decision profile `VRAM estimated`. Current state
(`models/catalog.json`): `decide-julia`, `decide-laya`, `decide-kev-08b`, `decide-lev`, `decide-kev-4b` measured
(`specs/009-jev-decision-models/evidence/live-models/<profile>/memory.txt`), `decide-kev-9b` lower-bound
(`specs/009-jev-decision-models/evidence/live-models.jsonl`), all other decision profiles estimated. Effect on the table below: on
`small-exact` `decide-kev-08b` is now recommended (GPU need 2900 MiB fits the 4250 MiB VRAM budget; it was 5583).

## Planner and `auto decide`

SC-012 requires every change against the previous release (tag `v3.0.2`)
in recommended or automatically selected profiles to be documented with a
reason. The comparison is executed by `tests/test_planner.sh` on every
hardware fixture; the only changes are the **addition of decision
profiles** to the recommended set, and the test fails if the table below
drifts from the real planner output.

Why a decision profile appears in the recommended set: a profile is
recommended exactly when it **fits** the RAM/VRAM budgets **and** the host
tier satisfies its `min_tier` - the rule that has always applied to every
profile. The decision profiles are new catalog entries (capability
`decide`), so on the hosts below they are newly recommended; they are never
chat models, `auto chat|coder|vision` can never select one (their
capability excludes chat and the chat rankings do not list them), and the
recommended **chat** set and the `auto chat|coder|vision` picks are
unchanged on every fixture. `decide-pro` and `decide-max` (min_tier
`workstation`) appear only on workstation-class and larger hosts. In the
recommended list profiles are ordered by catalog port, so `decide-max`
(8097) precedes `decide-2b` (8098).

## Per-type maturity of the decision profiles (T138)

Each decision profile carries a `maturity` object per question type (`noul`, `choice`, `score`), derived from its golden-run output by `scripts/maturity_from_golden.py`:
`measured` means the Wilson lower bound clears the baseline; `experimental` means it does not; `unmeasured` means no live golden run yet. Anything but `measured` is
shown as experimental: `GET /v1/models` lists it in `experimental_types`, `llmctl plan` prints it, and answers of that type carry `maturity: "experimental"`.
A type missing from a profile's object counts as unmeasured. Values below are copied from `models/catalog.json` (lb = lower bound):

| profile | noul | choice | score |
|---|---|---|---|
| `decide-tiny` | unmeasured | unmeasured | unmeasured |
| `decide` | unmeasured | unmeasured | unmeasured |
| `decide-pro` | unmeasured | unmeasured | unmeasured |
| `decide-nli` | unmeasured | unmeasured | unmeasured |
| `decide-2b` | unmeasured | unmeasured | unmeasured |
| `decide-max` | unmeasured | unmeasured | unmeasured |
| `decide-julia` | experimental (lb 0.425 vs base 0.667, n=60) | experimental (lb 0.216 vs base 0.235, n=41) | experimental (lb 0.114 vs base 0.290, n=31) |
| `decide-kev-08b` | measured (lb 0.701 vs base 0.667, n=60) | measured (lb 0.745 vs base 0.235, n=41) | experimental (lb 0.161 vs base 0.290, n=31) |
| `decide-kev-4b` | measured (lb 0.863 vs base 0.667, n=60) | measured (lb 0.914 vs base 0.235, n=41) | measured (lb 0.438 vs base 0.290, n=31) |
| `decide-kev-9b` | unmeasured | unmeasured | unmeasured |
| `decide-laya` | experimental (lb 0.592 vs base 0.667, n=60) | measured (lb 0.660 vs base 0.235, n=41) | experimental (lb 0.186 vs base 0.290, n=31) |
| `decide-lev` | measured (lb 0.886 vs base 0.667, n=60) | measured (lb 0.874 vs base 0.235, n=41) | measured (lb 0.348 vs base 0.290, n=31) |

| fixture | decision profiles added to the recommended set | `auto decide` picks |
|---|---|---|
| `apple` | `decide-tiny`, `decide`, `decide-pro`, `decide-nli`, `decide-max`, `decide-2b`, `decide-julia`, `decide-kev-08b`, `decide-kev-4b`, `decide-kev-9b`, `decide-laya`, `decide-lev` | `decide-nli` |
| `baseline` | `decide-tiny`, `decide`, `decide-nli`, `decide-2b`, `decide-julia`, `decide-kev-08b`, `decide-kev-4b`, `decide-laya`, `decide-lev` | `decide-nli` |
| `constrained` | `decide-tiny`, `decide`, `decide-nli`, `decide-2b`, `decide-julia`, `decide-kev-08b`, `decide-kev-4b`, `decide-laya`, `decide-lev` | `decide-nli` |
| `cpu-heavy` | `decide-tiny`, `decide`, `decide-pro`, `decide-nli`, `decide-max`, `decide-2b`, `decide-julia`, `decide-kev-08b`, `decide-kev-4b`, `decide-kev-9b`, `decide-laya`, `decide-lev` | `decide-nli` |
| `ram-contended-auto-eviction` | `decide-tiny`, `decide`, `decide-nli`, `decide-2b` | `decide-nli` |
| `small-exact` | `decide-tiny`, `decide-nli`, `decide-julia`, `decide-kev-08b`, `decide-laya` | `decide-nli` |
| `tiny` | none | no fit |
| `vram-contended-coresident` | `decide-tiny`, `decide`, `decide-nli`, `decide-2b`, `decide-julia`, `decide-kev-08b`, `decide-kev-4b`, `decide-laya`, `decide-lev` | `decide-nli` |
| `vram-contended` | `decide-tiny`, `decide`, `decide-nli`, `decide-2b`, `decide-julia`, `decide-laya` | `decide-nli` |
| `workstation` | `decide-tiny`, `decide`, `decide-pro`, `decide-nli`, `decide-max`, `decide-2b`, `decide-julia`, `decide-kev-08b`, `decide-kev-4b`, `decide-kev-9b`, `decide-laya`, `decide-lev` | `decide-nli` |

**`auto decide` ranking** (`sched_rank_for_capability decide`, fixed): `decide-tiny`,
`decide-nli`, `decide-2b`, `decide`, `decide-pro`, `decide-max`, then the six native
profiles in ascending footprint order (`decide-julia`, `decide-laya`, `decide-kev-08b`,
`decide-lev`, `decide-kev-4b`, `decide-kev-9b`) - appended last so that `auto decide`
never prefers a profile that needs the native engine path (the gateway serves them only with
`LLMCTL_DECIDE_NATIVE=1`) over a proven one. The rule
is **the first recommended profile of that list wins** - i.e. an ascending
footprint/accuracy ladder, *smallest footprint first*, not "highest
accuracy" (`decide-tiny` is the profile calibrated for exactly this
workload; the rationale per rung is in the comment above
`sched_rank_for_capability`). A quality-first ordering would start from
`decide`/`decide-max`; that is a different, undocumented-until-chosen
policy, so an operator who wants a larger profile starts it explicitly
with `llmctl start <profile>`. `auto decide` prints its choice and why
(`capability 'decide' -> profile 'decide-nli'` followed by `why: first
recommended profile in the decide ranking [...]`, listing any higher-ranked
profile it skipped and the reason: tier gate or footprint). The encoder
profile `decide-nli` ranks first (`decide-tiny` is ranked last because the
gateway cannot serve it yet); it needs the onnx runtime dependencies
(`docs/decision-models.md`).

## Datacenter-only: colibri-glm

GLM-5.2 (744B MoE, int4-gs64 + int8 MTP) streams ~429 GB of weights from NVMe
through the colibri engine — no GPU required, but it needs ~16–24 GB RAM of
working set and ~380 GB of fast storage. The `datacenter` gate exists so
planners on ordinary machines never propose a 400 GB download.
