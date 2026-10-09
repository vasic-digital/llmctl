# Proposal, NOT APPLIED: wiring the nezha CPU memory-summary evidence into the planner

Status: analysis only. Nothing below is in models/catalog.json. The nezha-* evidence tree
(specs/009-jev-decision-models/evidence/live-models/nezha-<profile>-2026-10-08/memory-summary.json) is an
uncommitted snapshot, commit UNCONFIRMED. decide-max has no memory-summary.json.

## What was tried
Declare `memory.ram` (format memory-summary-json, host nezha) for decide, decide-2b, decide-pro, decide-kev-4b,
decide-kev-9b and derive via `scripts/overhead_from_memory.py --write` (overhead_mb = ceil(1.10 x (peak HWM - weights))).

| profile | peak HWM MiB | weights MiB | derived overhead_mb |
|---|---|---|---|
| decide | 12799.4 | 2583.3 | 11238 |
| decide-2b | 8194.3 | 1918.8 | 6904 |
| decide-pro | 7738.5 | 4172.3 | 3923 |
| decide-kev-4b | 12952.2 | 2893.0 | 11066 |
| decide-kev-9b | 17208.7 | 6064.3 | 12259 |

## Why it was not applied
`gpu_booking()` (lib/catalog.sh) books an unmeasured-GPU profile as weights + KV + overhead_mb, so a CPU-only RAM peak
becomes an estimated GPU VRAM booking. Planner effect (booked footprint, MiB / instances):

| item | before | after |
|---|---|---|
| decide footprint | 3671 | 14909 |
| decide-2b footprint | 3006 | 9910 |
| decide-pro footprint | 5260 | 9183 |
| decide-kev-9b cpu RAM | 7088 | 19347 |
| baseline decide gpu/cpu/slots | 2 / 7 / 14 | 0 / 1 / 2 |
| baseline decide-2b gpu/cpu/slots | 3 / 8 / 16 | 1 / 2 / 4 |
| workstation decide gpu/cpu | 7 / 64 | 1 / 15 |
| workstation decide-pro gpu/cpu | 5 / 44 | 3 / 25 |

decide and decide-2b also flip from gpu to cpu mode on an 8692 MiB-VRAM host; docs/hardware-tiers.md rows
(cpu-heavy, ram-contended-auto-eviction) would change. 23 planner assertions changed.

## Open design decision
Separate RAM-overhead from VRAM-overhead for the estimated GPU path (e.g. do not add overhead_mb to the GPU estimate,
or require a GPU-host measurement), then wire the evidence. Needs a tracked item.
