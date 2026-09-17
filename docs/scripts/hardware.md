## Overview

`lib/hardware.sh` is llmctl's hardware probe: it reads real system interfaces
(`/proc`, `/sys`, `sysctl`, `nvidia-smi`, `rocm-smi`, `diskutil`) to build a
JSON document describing the host's CPU (model, core count, SIMD features,
Apple Silicon chip name), RAM (total/available MiB), every detected GPU
(vendor, name, VRAM, driver/stack info), and free storage + storage type at
the models directory. It exists because the entire planning/scheduling layer
(`lib/catalog.sh`'s planner, `lib/scheduler.sh`'s budget checks) needs an
accurate, dynamic picture of what a given host can actually run — llmctl
makes no hardcoded assumptions about the machine it is installed on.

## Prerequisites

* Sources `lib/common.sh` and `lib/os_detect.sh` from its own directory
  (`_hw_dir`), so both must exist alongside it.
* `python3` (via `json_query`, `hw_probe_json`'s own inline `python3 -`
  invocation, and `hw_probe_human`'s inline `python3 -`) — required, not
  optional; `hw_probe_json` assembles the final JSON document by piping a
  set of `LLMCTL_HW_*` environment variables into an inline Python script.
* Linux-specific data sources (best-effort, each individually optional):
  `/proc/cpuinfo`, `/proc/meminfo`, `nvidia-smi`, `rocm-smi`,
  `/sys/class/drm/card[0-9]*`, `lsblk`, `/sys/block/<dev>/queue/rotational`.
* macOS-specific data sources (best-effort): `sysctl`, `vm_stat`,
  `diskutil info`.
* `df -Pm` (portable disk-free query) on either OS, used by `_probe_storage`.
* `${LLMCTL_MODELS_DIR}` must be creatable (`ensure_dir` is called on it by
  `_probe_storage` before probing storage there).

## Usage examples

```sh
source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/os_detect.sh"
source "${LLMCTL_ROOT}/lib/hardware.sh"

hw_probe_json                      # full JSON hardware document on stdout
hw_probe_human                     # human-readable rendering (re-probes)
hw_probe_human "$(hw_probe_json)"  # human-readable rendering of a given doc

# deterministic testing: serve a fixture instead of probing the real host
LLMCTL_FAKE_HW=tests/fixtures/hw-baseline.json hw_probe_json

# via the CLI:
bin/llmctl hw --json
bin/llmctl hw
LLMCTL_FAKE_HW=tests/fixtures/hw-baseline.json bin/llmctl hw
```

## Edge cases

* **`LLMCTL_FAKE_HW` short-circuits the entire probe**: when set,
  `hw_probe_json` skips every real hardware read entirely — it only checks
  the file is readable (`die`s with the file path if not), validates it is
  parseable JSON via `json_query "${LLMCTL_FAKE_HW}" 'd' >/dev/null` (`die`s
  naming the fixture if invalid), and then `cat`s the fixture verbatim. This
  is what makes planner/scheduler tests deterministic on any machine.
* **CPU model detection has an ARM fallback on Linux**: it first tries
  `/proc/cpuinfo`'s `model name` field; if that's empty (common on some ARM
  kernels), it retries with `Model|Hardware` fields before giving up and
  returning failure (`return 1`).
* **SIMD feature detection is architecture-branched inside the same
  function**: on Linux it greps a fixed feature list
  (`sse4_2 avx avx2 avx512f avx512_vnni amx_tile amx_int8 amx_bf16 fma f16c
  neon asimd sve`) against `/proc/cpuinfo`'s flags; on macOS it branches
  again on `arm64` vs. other (checking `hw.optional.arm.FEAT_SVE` vs. a set
  of `hw.optional.*` sysctl keys) — an unmatched arch on macOS silently
  contributes an empty feature array rather than erroring.
* **Apple chip name extraction is regex-based and defensive**: it matches
  `M[1-9][A-Za-z ]*` against the CPU brand string and trims trailing
  whitespace; if the brand string doesn't match that pattern at all (an
  unexpected Apple Silicon naming), it falls back to the literal string
  `"Apple Silicon"` rather than an empty value.
* **Memory availability on Linux falls back twice**: prefers
  `MemAvailable:` from `/proc/meminfo`; if that field is absent (very old
  kernels), falls back to `MemFree:`; if even `MemFree:` is missing, falls
  back to using the total as the available figure (`|| echo "${total}"`).
* **GPU detection stacks independently, not mutually exclusive**: NVIDIA
  (`nvidia-smi`, any OS) and AMD/Intel (Linux only, via `rocm-smi` or the
  `/sys/class/drm` fallback) and Apple unified memory (macOS arm64 only) are
  each probed in sequence and all matching results are emitted — a host
  could in principle have both an NVIDIA and an on-die AMD/Intel GPU
  detected simultaneously.
* **AMD GPU detection has its own two-tier fallback on Linux**: prefers
  `rocm-smi` (per-card id/name/VRAM via `--showid`/`--showproductname`/
  `--showmeminfo vram`); if `rocm-smi` is absent, falls back to walking
  `/sys/class/drm/card[0-9]` and reading the driver symlink — only
  `amdgpu` (VRAM from `mem_info_vram_total`) and `i915`/`xe` (Intel
  integrated, reported with 0 VRAM) drivers are recognized; any other driver
  under that glob is silently skipped.
* **Apple unified-memory VRAM is an estimate, not a measurement**: computed
  as `0.7 * total_ram_mb`, explicitly documented in a comment as matching
  what macOS exposes to Metal via `recommendedMaxWorkingSetSize` — this is
  the one GPU entry that is a derived heuristic rather than a direct read.
* **Storage type classification differs between disk backends**: on Linux
  it prefers `lsblk`'s rotational flag (walking up to the whole-disk parent
  device) and falls back to a `/sys/block/<base>/queue/rotational` read if
  `lsblk` is unavailable or the device path isn't a block device; on both
  paths, an `nvme*` device name short-circuits straight to `type=nvme`
  before the rotational check even runs. On macOS it parses `diskutil info`
  output for "Solid State" + "Protocol" fields, with a fallback from the
  target directory's own volume to `/` if `diskutil info <dir>` fails.
* **`hw_probe_json` hard-fails on core probe failures**: unsupported OS
  (`llmctl_os` returning non-zero), non-numeric/zero core count, CPU model
  unresolvable, memory unresolvable, zero total memory, or storage
  unresolvable at the models directory each trigger a distinct `die`
  message naming exactly what failed — there is no silent zero/empty
  fallback at this top-level assembly layer, only inside the individual
  `_probe_*` helpers where documented above.
* **The final JSON assembly is itself a `python3` script reading
  environment variables**, not string concatenation — GPU lines are passed
  as a newline-separated `LLMCTL_HW_GPUS` variable and parsed with a
  `parts = line.split("|")` guard that skips any line with fewer than 5
  pipe-separated fields, so a malformed probe line is dropped rather than
  crashing the whole JSON build.

## Internal behaviour

1. **CPU probes** (`_probe_cpu_model`, `_probe_cpu_simd`, `_probe_apple_chip`):
   three independent, OS-branched functions each returning either a value on
   stdout or a non-zero exit for "could not determine."
2. **Memory probe** (`_probe_mem`): echoes `"<total_mb> <available_mb>"` as
   a single space-separated line, OS-branched (Linux: `/proc/meminfo`;
   macOS: `sysctl hw.memsize` + `vm_stat` page-count math).
3. **GPU probe** (`_probe_gpus`): sequentially probes NVIDIA (any OS), then
   AMD/Intel (Linux only), then Apple unified memory (macOS arm64 only);
   emits zero or more lines of the form `vendor|name|vram_mb|driver|extra`.
4. **Storage probe** (`_probe_storage`): `ensure_dir`s the target directory
   first, reads free space via `df -Pm`, then OS-branches to classify the
   underlying device as `nvme`/`ssd`/`hdd`/`unknown`; echoes
   `"<free_mb> <type> <dir>"`.
5. **`hw_probe_json()`** (public entry point): checks `LLMCTL_FAKE_HW` first
   (short-circuit, see Edge cases); otherwise calls every `_probe_*`
   function above, validates each result, assigns everything into
   `LLMCTL_HW_*` scalar/array-flattened environment variables, and pipes
   those into an inline `python3 -` heredoc that builds and prints the final
   JSON document (`os`, `arch`, `cpu.{cores,model,arch,simd,apple_silicon,
   apple_chip}`, `memory.{total_mb,available_mb}`, `gpus[]`,
   `gpu_total_vram_mb`, `storage.{path,free_mb,type}`).
6. **`hw_probe_human()`** (public entry point): accepts an optional JSON
   document as `$1` (re-probes via `hw_probe_json` if omitted), then pipes it
   into a second inline `python3 -` heredoc that prints a fixed-format,
   human-readable summary (OS/arch, CPU model/cores/SIMD/chip, RAM, one line
   per GPU with vendor-specific extras, storage free space + type).

## Related scripts

* Sources `lib/common.sh` and `lib/os_detect.sh`.
* Consumed by `lib/catalog.sh`'s `catalog_plan_json`/`catalog_classify_tier`
  (both take a hardware JSON document on stdin — exactly `hw_probe_json`'s
  output shape) and by `bin/llmctl`'s `hw`/`probe` and `plan` command
  branches.
* `lib/scheduler.sh` also depends on it transitively (through
  `catalog_plan_json`) for budget calculations.
* Exercised directly by `tests/test_hardware_probe.sh` (probe shape,
  fixture handling) and end-to-end via `tests/test_planner.sh`,
  `tests/test_cli.sh` (the `hw`/`plan` CLI paths), and
  `tests/test_port_override.sh`; `tests/fixtures/hw-*.json` are the fixture
  files `LLMCTL_FAKE_HW` points at across the test suite.

## Last verified date

2026-09-17
