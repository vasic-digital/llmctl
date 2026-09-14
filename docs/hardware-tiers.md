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

* Recommended: `fast`, `coder`, `vision`, `moe-fast`, `small`.
* `coder`, `moe-fast` run CPU-mode here (17.7/11.6 GiB models don't fit
  10444 MiB of VRAM budget); `fast`, `vision`, `small` run fully on GPU.
* Example co-residency (greedy, port order):
  `fast + coder + vision` together, or `moe-fast + small` together.
* `vision-pro`, `ws-*`, `colibri-*` are tier-gated off.

## Workstation

64-core Threadripper · 256 GB RAM · 32 GB VRAM · 2 TB NVMe qualifies as
`datacenter` by the rules above (a superset of workstation): every profile is
recommended, all GGUF models run fully GPU-offloaded, and co-residency groups
span e.g. `fast + coder`, `vision + vision-pro`, `ws-moe-30b + colibri-*`.

An Apple Silicon Mac (e.g. M4 Max, 64 GB unified) classifies as
`workstation`: VRAM is estimated as 0.7 × unified RAM (matching Metal's
recommended working-set limit), so everything except the datacenter-gated
`colibri-glm` is recommended.

## Datacenter-only: colibri-glm

GLM-5.2 (744B MoE, int4-gs64 + int8 MTP) streams ~429 GB of weights from NVMe
through the colibri engine — no GPU required, but it needs ~16–24 GB RAM of
working set and ~380 GB of fast storage. The `datacenter` gate exists so
planners on ordinary machines never propose a 400 GB download.
