## Overview

`tests/test_planner.sh` is the deterministic regression suite for
`lib/catalog.sh`'s hardware planner (`catalog_plan_json`,
`catalog_plan_human`, and `catalog_classify_tier`) — the component that
turns a probed (or, here, fixture-faked) hardware document into a tier
classification, a per-profile fit/mode/footprint decision, a recommended
profile set, and co-residency groupings. It exists so the planner's
memory-model arithmetic (RAM budget = available − 4 GiB, VRAM budget =
total × 0.85, per-profile GPU/CPU/colibri mode selection, tier gating,
greedy bin-packed co-residency groups) can be pinned against known,
hand-derived expected numbers for several distinct hardware shapes,
without ever touching real hardware.

## Prerequisites

* Sources `tests/helpers.sh` for `test_setup_env`/assertion
  helpers/`test_finish`.
* Sources, directly (not as subprocesses), in order: `lib/common.sh`,
  `lib/os_detect.sh`, `lib/hardware.sh`, `lib/catalog.sh` — the real,
  unmodified library code under test.
* Uses `LLMCTL_FAKE_HW=<path-to-fixture.json>` to make `hw_probe_json`
  (from `lib/hardware.sh`) emit a fixed, fixture-driven hardware document
  instead of probing the real host — the mechanism every hardware-fixture
  test in this suite relies on.
* Reads the following fixture files from `tests/fixtures/`:
  `hw-baseline.json` (Ryzen 7 2700X / 32 GB RAM / RTX 3060 12 GB / NVMe),
  `hw-workstation.json` (64-core Threadripper / 256 GB RAM / 32 GB VRAM /
  2 TB free — despite the filename, this fixture actually classifies as
  the `datacenter` tier per the real threshold rules, not
  `workstation`), `hw-apple.json` (M4 Max, 64 GB unified RAM), and
  `hw-constrained.json` (8 cores / 32768 MiB RAM, sitting exactly at the
  baseline tier threshold).
* Depends on `models/catalog.json`'s real profile sizes/sha256/tier
  gates via `lib/catalog.sh` — the expected values asserted in this file
  are explicitly derived from the catalog + the documented memory model
  and must be updated deliberately if either changes (stated in the
  script's own header comment).
* `python3` is required transitively: `hw_probe_json`/`catalog_plan_json`
  and the `json_stdin` helper this test uses to pick fields out of the
  emitted JSON both rely on `python3` (per `lib/common.sh`'s JSON
  helpers, referenced in `docs/architecture.md`).

## Usage examples

```bash
bash tests/test_planner.sh
```

Also runs as part of the full suite via `tests/run_tests.sh` or
`make test`.

Internally, the test defines a small local helper used throughout the
file:

```bash
plan_for() {
  LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-$1.json" hw_probe_json | catalog_plan_json
}
```

so, e.g., `plan_for baseline` reproduces exactly what `llmctl plan --json`
would compute on that fixture.

## Edge cases

* **Baseline fixture**: asserts the computed tier is `baseline`; asserts
  the exact RAM budget (`25904` = `30000 − 4096`) and VRAM budget
  (`10444` = `12288 × 0.85`); asserts the recommended profile set is
  exactly `fast coder vision moe-fast small`; asserts `fast` selects
  `gpu` mode while `coder` selects `cpu` mode (because `coder`'s ~17.7 GiB
  footprint exceeds the 10444 MiB VRAM budget); asserts `fast`'s VRAM
  footprint (`5716` MiB = 4692 model + 1024 KV) and `coder`'s RAM
  footprint (`21793` MiB = 17697 + 4096 KV); asserts `ws-dense-32b` is
  gated `tier_ok: False` on this tier; asserts the exact greedy-bin-packed
  co-residency grouping (`fast coder vision|moe-fast small`).
* **Workstation fixture** (real tier: `datacenter`): asserts all 10
  catalog profiles are recommended; asserts `ws-dense-32b` fully offloads
  to `gpu` mode; asserts `colibri-glm` selects `colibri` mode; asserts
  the specific co-residency grouping on this abundant-hardware fixture.
* **Apple fixture** (M4 Max, unified memory): asserts the tier is
  `workstation` (64 GB unified RAM); asserts the recommended set excludes
  `colibri-glm` (gated to `datacenter`-only) while including everything
  else; asserts `colibri-glm`'s `tier_ok` is explicitly `False`; asserts
  `fast` still selects `gpu` mode on unified-memory hardware.
* **Human-readable rendering**: asserts `catalog_plan_human` (piped from
  the baseline plan) does not crash and contains both the `"Host tier:
  baseline"` header line and a `"Co-residency groups"` section — a smoke
  check on the human-facing renderer distinct from the machine-readable
  JSON assertions above.
* **`catalog_classify_tier` cross-check**: separately calls
  `catalog_classify_tier` directly (not through `catalog_plan_json`) for
  all four fixtures (`baseline`, `workstation`, `apple`, `constrained`)
  and asserts it returns the identical tier `catalog_plan_json` computed
  above — closing a real duplication/drift-risk gap where tier
  thresholds used to be hand-copied in two places (documented at length
  in the script's own inline comment, including the Constitution
  §11.4.124 investigate-before-remove note that git history offered no
  further trail beyond a single squashed "Init." commit). The
  `constrained` fixture is specifically chosen because its 8 cores / 32768
  MiB RAM sit *exactly* at the baseline-tier threshold boundary.

## Internal behaviour

1. `set -euo pipefail`; source `tests/helpers.sh`; `test_setup_env`.
2. Source the four library files (`common.sh`, `os_detect.sh`,
   `hardware.sh`, `catalog.sh`) directly into the test's own shell.
3. Define `plan_for()` as described above.
4. For each of the three named hardware fixtures (`baseline`,
   `workstation`, `apple`), call `plan_for <fixture>`, capture the JSON
   plan once, and run a block of `json_stdin`-based field assertions
   against it (tier, budgets, recommended set, per-profile mode/footprint/
   tier_ok, co-residency groups) — described per-fixture in "Edge cases"
   above.
5. Render the baseline plan through `catalog_plan_human` and assert its
   header/section text is present.
6. Independently invoke `catalog_classify_tier` (piped from
   `hw_probe_json` under each of the four `LLMCTL_FAKE_HW` fixtures,
   including `constrained` which was not exercised in the main loop) and
   assert each result matches the tier already established above.
7. `test_finish` tears down the isolated temp environment and exits
   non-zero iff any assertion failed.

## Related scripts

* Sources `tests/helpers.sh` (sibling, documented separately).
* Exercises `lib/catalog.sh` (`catalog_plan_json`, `catalog_plan_human`,
  `catalog_classify_tier`) together with its dependencies `lib/common.sh`,
  `lib/os_detect.sh`, and `lib/hardware.sh` (`hw_probe_json`).
* Reads `models/catalog.json` transitively through `lib/catalog.sh`.
* Reads fixture files `tests/fixtures/hw-baseline.json`,
  `hw-workstation.json`, `hw-apple.json`, `hw-constrained.json`.
* Sibling test `tests/test_port_override.sh` exercises the same
  `catalog_plan_json`/hardware-fixture machinery for the per-profile port
  override feature specifically.
* Sibling test `tests/test_scheduler.sh` builds on the same
  `LLMCTL_FAKE_HW` fixtures + planner output to exercise the scheduler
  layer above the planner.
* Discovered and run automatically by `tests/run_tests.sh`; syntax and
  shebang/strict-mode covered by `tests/test_syntax.sh`.

## Last verified date

2026-09-17
