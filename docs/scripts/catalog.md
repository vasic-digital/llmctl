## Overview

`lib/catalog.sh` is llmctl's query layer over `models/catalog.json` (the
checked-in, host-independent model catalog) and its planner: given a
hardware JSON document (from `lib/hardware.sh`), it classifies the host into
a tier (`below-minimum`/`baseline`/`workstation`/`datacenter`), computes a
conservative RAM/VRAM/storage budget, decides per-profile whether each
catalog profile fits (and in what mode: `gpu`/`cpu`/`colibri`/`none`), and
greedily bin-packs the profiles that fit into co-residency groups that could
all run at the same time. It exists so `bin/llmctl plan`, `models list`, and
every scheduler decision in `lib/scheduler.sh` share one arithmetic source of
truth for "does this profile fit this host" instead of duplicating budget
math in multiple places.

## Prerequisites

* Sources `lib/common.sh` from its own directory (`_cat_dir`).
* `python3` — used both directly (`json_query`, `catalog_classify_tier`,
  `catalog_plan_json`, `catalog_plan_human` all shell out to it) and it is
  the language the planner itself is implemented in (`catalog_plan_json`
  embeds a full Python script via heredoc).
* `${LLMCTL_CATALOG}` (from `common.sh`, default
  `${LLMCTL_ROOT}/models/catalog.json`) must exist and be readable/valid
  JSON — every public function calls `catalog_check` first, which `die`s
  otherwise.
* `catalog_plan_json` expects a hardware JSON document (the exact shape
  `hw_probe_json` from `lib/hardware.sh` produces) on stdin.
* Per-profile host-local port overrides are read from environment variables
  named `LLMCTL_PORT_<PROFILE>` (profile name upper-cased, `-` -> `_`, see
  `catalog_port_override_env_name`) — entirely opt-in, never required.
* Engine bind address resolution reads `${LLMCTL_BIND_HOST}` (from
  `common.sh`, default `0.0.0.0` — LAN-accessible per operator mandate) and
  an optional per-profile override `LLMCTL_BIND_HOST_<PROFILE>` (same
  upper-cased, `-` -> `_` naming rule as the port override, see
  `catalog_bind_host_override_env_name`).

## Usage examples

```sh
source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/catalog.sh"

catalog_check                       # dies if the catalog file is missing/invalid
catalog_profiles                    # one profile name per line, sorted
catalog_exists fast                 # boolean via exit code
catalog_field fast engine           # -> "llama"
catalog_engine fast                 # -> "llama"
catalog_port fast                   # -> the catalog's port, or an override
catalog_bind_host fast               # -> "0.0.0.0" by default, or an override
catalog_min_tier fast               # -> "baseline" (or the catalog's/default)
catalog_desc fast
catalog_hf_repo fast
catalog_capability fast              # -> space-joined capability list
catalog_default fast ctx 8192        # -> defaults.ctx, or 8192 if unset
catalog_files fast                   # -> "name|size|sha256|role" lines
catalog_total_size_mb fast

# host-local port rebind for exactly one profile (never edit the catalog file)
LLMCTL_PORT_FAST=18080 catalog_port fast

# lock exactly one profile back to localhost-only (global default is 0.0.0.0)
LLMCTL_BIND_HOST_FAST=127.0.0.1 catalog_bind_host fast
# or revert every profile at once
LLMCTL_BIND_HOST=127.0.0.1 catalog_bind_host fast

# tier classification (hardware JSON on stdin)
hw_probe_json | catalog_classify_tier   # -> baseline|workstation|datacenter|below-minimum
catalog_tier_rank workstation            # -> 2 (numeric, for comparisons)

# full plan (hardware JSON on stdin -> plan JSON on stdout)
hw_probe_json | catalog_plan_json
hw_probe_json | catalog_plan_json | catalog_plan_human

# reading one field back out of an already-computed plan document
echo "${plan_json}" | catalog_plan_get fast mode
```

## Edge cases

* **Every public getter validates the profile first**: `catalog_field`
  (and everything built on it: `catalog_engine`, `catalog_port`,
  `catalog_min_tier`, `catalog_desc`, `catalog_hf_repo`, `catalog_files`,
  `catalog_total_size_mb`) calls `catalog_exists` and `die`s with
  `"unknown profile: $p (see: llmctl models list)"` before ever touching the
  requested field — an unknown profile never silently returns an empty
  value.
* **`catalog_field`'s default-value fallback is two-layered**: if the
  `json_query` call itself fails (the field key doesn't exist at all), it
  falls back to `$3` if given, else `die`s naming the missing field; but if
  the query *succeeds* and returns an empty string (the field exists but is
  JSON `null`/empty), it *also* substitutes the default when one was given
  — so `catalog_min_tier` (default `baseline`) and `catalog_desc` (default
  `""`) both rely on this second branch, not just the first.
* **`catalog_port` override resolution still validates the profile even
  when an override is present**: setting `LLMCTL_PORT_<PROFILE>` for a
  profile name that doesn't exist in the catalog still `die`s with the same
  "unknown profile" message (via an explicit `catalog_check` +
  `catalog_exists` call inside the `if [[ -n "${override}" ]]` branch) —
  the override path was deliberately built to not silently accept a port for
  a nonexistent profile.
* **The port-override env-var name derivation relies on `tr`'s
  positional-mapping guarantee**: `catalog_port_override_env_name` maps
  `[:lower:]-` to `[:upper:]_` via `tr`, which only works correctly because
  both character classes expand to exactly 27 characters (26 letters + one
  separator) in the same relative order — documented explicitly in the
  function's comment as the reason this single `tr` call is safe rather
  than needing a more complex substitution.
* **`catalog_classify_tier` must be invoked as `python3 -c '<script>'`, not
  a heredoc** — the file's own comment explains why: a heredoc attached to
  `python3 -` would feed the *script itself* to Python via stdin, which
  collides with the script's own `json.load(sys.stdin)` call trying to read
  the actual hardware JSON on that same stdin (stdin would already be
  exhausted). This function was previously broken this exact way (an
  unwired dead-code path discovered via a `SyntaxError`/eval-mismatch
  investigation) and the working `-c` form is preserved deliberately.
* **Tier thresholds are a single source of truth used by both the bash
  layer and the Python planner**: `catalog_classify_tier` is called once
  from bash inside `catalog_plan_json` and its result is threaded into the
  embedded Python script via the `LLMCTL_TIER` environment variable — the
  Python script does not recompute the thresholds itself, precisely to avoid
  the thresholds drifting out of sync between two implementations.
* **Colibri and GGUF (llama) profiles use entirely different footprint
  formulas** inside `catalog_plan_json`'s embedded `footprint()` function:
  colibri profiles memory-map weights from NVMe, so their RAM need is a
  fixed conservative reservation (24576 MiB if the model is >= 100 GiB,
  else 8192 MiB) independent of model size, and their fit check only
  compares against the RAM budget plus 110% of the model's storage size
  against free storage — VRAM is always 0 for colibri. GGUF (llama)
  profiles instead try GPU mode first (model size + KV cache fits the VRAM
  budget and 2048 MiB RAM headroom fits), then fall back to CPU mode (model
  size + KV cache fits the RAM budget), and only report `mode: "none"` /
  `fits: false` if neither fits.
* **KV cache is a documented conservative upper-bound estimate**
  (`kv_mb(ctx, parallel) = ceil(ctx * parallel / 8)` MiB), explicitly
  labeled in the file header comment as an f16 KV estimate cross-referenced
  in `docs/architecture.md` — not a measured value.
* **Co-residency grouping is a greedy bin-pack, not an optimal one**:
  profiles are walked in ascending port order and added to the "current"
  group as long as RAM+VRAM+storage all still fit the budgets; the first
  profile that doesn't fit starts a brand-new group rather than backtracking
  to try a different combination — this is a simple, deterministic
  algorithm, not a bin-packing optimizer.
* **`resolve_port` inside the embedded Python planner duplicates the same
  override-naming rule as bash's `catalog_port_override_env_name`**, but
  independently (`name.upper().replace("-", "_")`) — the file's own comment
  calls out that this is the function every *actual launch* (start/enable/
  switch/auto via `sched_build_launch`'s `--port`) resolves its port
  through, so overriding only the display-only `catalog_port()` getter would
  not change what the scheduler actually binds to; an invalid (non-integer)
  override value causes the planner to print an error to stderr and
  `sys.exit(1)` rather than silently ignoring it.
* **`catalog_bind_host` has a single resolution point, unlike `catalog_port`**
  — bind address is not a `catalog_plan_json` planner field (it is a
  deployment/network concern, not a portability/footprint fact), so there
  is no second, independently-duplicated resolution inside the embedded
  Python planner the way `resolve_port` duplicates `catalog_port`'s naming
  rule. `lib/scheduler.sh`'s `sched_build_launch` is the ONLY caller (both
  the `llama` and `colibri` engine branches), calling `catalog_bind_host`
  directly at `--host` construction time — there is no display-only getter
  to keep in sync with a separate functional path.
* **`catalog_bind_host` override resolution is profile-validated exactly
  like `catalog_port`'s**: setting `LLMCTL_BIND_HOST_<PROFILE>` for a
  profile that doesn't exist in the catalog still `die`s with the same
  "unknown profile" message, via the identical `catalog_check` +
  `catalog_exists` pattern.

## Internal behaviour

1. **`catalog_check`**: validates `${LLMCTL_CATALOG}` is readable and valid
   JSON; called at the top of every other public function in this file.
2. **Simple getters** (`catalog_profiles`, `catalog_exists`, `catalog_field`,
   `catalog_engine`, `catalog_min_tier`, `catalog_desc`, `catalog_hf_repo`,
   `catalog_capability`, `catalog_default`, `catalog_files`,
   `catalog_total_size_mb`): each is a thin wrapper calling `json_query`
   (from `common.sh`) with a Python expression over the parsed catalog
   document `d`.
3. **`catalog_port` / `catalog_port_override_env_name`**: layered on top of
   `catalog_field`, checking for an `LLMCTL_PORT_<PROFILE>` override first.
3b. **`catalog_bind_host` / `catalog_bind_host_override_env_name`**: not
    layered on `catalog_field` (no catalog "host" field exists to fall back
    to) — validates the profile directly via `catalog_check` +
    `catalog_exists`, then returns `LLMCTL_BIND_HOST_<PROFILE>` if set, else
    the global `${LLMCTL_BIND_HOST}` (from `common.sh`, default `0.0.0.0`).
4. **`catalog_classify_tier`**: reads a hardware JSON document from stdin and
   applies a fixed threshold ladder (datacenter: >=32 cores AND >=96 GiB RAM
   AND >=400 GiB free storage; workstation: >=24 cores OR >=64 GiB RAM OR
   >=20 GiB VRAM; baseline: >=8 cores AND >=32 GiB RAM; else
   below-minimum) via an inline Python `-c` script.
5. **`catalog_tier_rank`**: maps the four tier strings to integers 0-3 for
   numeric comparison; returns non-zero on an unrecognized tier string.
6. **`catalog_plan_json`**: reads a hardware doc from stdin, calls
   `catalog_classify_tier` on it, then runs a large embedded Python script
   (via `LLMCTL_HW_DOC`/`LLMCTL_TIER` env vars + a heredoc, with the catalog
   path as `sys.argv[1]`) that: computes RAM/VRAM budgets with headroom,
   defines `kv_mb`/`resolve_port`/`footprint` helper functions, computes a
   per-profile footprint+fit+recommendation dict for every catalog profile,
   greedily bin-packs the recommended profiles (sorted by port) into
   co-residency groups, and prints the whole result (`tier`, `budgets`,
   `profiles`, `recommended`, `coresidency_groups`) as JSON.
7. **`catalog_plan_human`**: reads a plan JSON document from stdin (produced
   by `catalog_plan_json`) and renders it as a fixed-width table (one row
   per profile with verdict `FITS`/`GATED`/`NO-FIT` and a reason) plus a
   co-residency group summary, via a second inline Python script.
8. **`catalog_plan_get`**: a small convenience wrapper around `json_stdin`
   (from `common.sh`) for pulling one field out of a plan document that's
   already been computed and piped in.

## Related scripts

* Sources `lib/common.sh`.
* Consumed by `bin/llmctl` (`models list` via `cmd_models_list`, `plan` via
  `catalog_plan_json`/`catalog_plan_human`) and by `lib/scheduler.sh` (which
  reads plan output to check RAM/VRAM budgets before starting profiles) and
  `lib/download.sh` (uses `catalog_hf_repo`, `catalog_field`, `catalog_files`,
  `catalog_exists`, `catalog_engine` to know what to download and validate).
* Reads `models/catalog.json`, the project's checked-in model catalog.
* Depends on `lib/hardware.sh`'s `hw_probe_json` output shape for its
  planner input, though it does not `source` `hardware.sh` itself (the
  hardware document is always piped in by the caller, e.g. `bin/llmctl`'s
  `plan` command).
* Exercised by `tests/test_catalog_json.sh` (catalog getters),
  `tests/test_planner.sh` (tier classification + planning logic),
  `tests/test_port_override.sh` (the `LLMCTL_PORT_<PROFILE>` mechanism),
  `tests/test_scheduler_bind_host.sh` (the `LLMCTL_BIND_HOST`/
  `LLMCTL_BIND_HOST_<PROFILE>` mechanism, both engine paths), and
  end-to-end via `tests/test_cli.sh`'s `plan`/`models list` assertions.

## Last verified date

2026-09-22
