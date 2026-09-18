# Phase 0 Research: CUDA GPU-Accelerated Inference Enablement

**Feature**: [spec.md](./spec.md) | **Date**: 2026-09-18

## R1: How is the CUDA toolkit installed on this host's OS?

**Decision**: Install via the distro package `nvidia-cuda-toolkit` (Ubuntu multiverse), not NVIDIA's own `.run` installer or apt repo.

**Evidence gathered this phase**:
- Host is `ubuntu 26.04` (confirmed via `/etc/os-release`).
- `apt-cache policy nvidia-cuda-toolkit` shows candidate `12.4.131~12.4.1-8` available from the standard multiverse repo — no extra repo needed.
- `nvidia-smi` reports driver `595.84`, which advertises CUDA capability up to `13.2` — driver-side compatibility with toolkit `12.4` is guaranteed (a driver always supports toolkit versions at or below its own max advertised CUDA version).
- GPU compute capability is `8.6` (Ampere/RTX 3060), fully supported by CUDA 12.4's default `nvcc` architecture tables (no extra `-arch` flag needed for a functional build; llama.cpp's own CMake CUDA logic already auto-selects architectures via `CMAKE_CUDA_ARCHITECTURES=native` upstream when unset by us).

**Alternatives considered**:
- NVIDIA's own apt repo (`developer.download.nvidia.com/compute/cuda/repos/...`) for a newer/pinned CUDA version: rejected for this feature — it adds a third-party apt source and key, which is a larger footprint change than this feature's scope (enabling GPU inference on THIS host) justifies. The distro package satisfies every functional requirement (FR-001..FR-003) without it. Left as a documented, non-blocking alternative if the distro package is ever pulled from the repo.
- The `.run` installer (silent/toolkit-only mode): rejected — bypasses the package manager, harder to uninstall/track, no clear advantage here since the distro package already resolves to a compatible version.

## R2: Will `nvcc` accept this host's default compiler?

**Decision**: Expect `nvcc` to reject `gcc 15.2` (the host's current default `gcc`) as an unsupported host compiler, and resolve it via `nvcc`'s own `--allow-unsupported-compiler` flag rather than installing a second, older `gcc` toolchain.

**Evidence gathered this phase**:
- Host `gcc --version` reports `15.2.0`.
- CUDA 12.4's published host-compiler support matrix tops out at `gcc 13.x` — this is a well-documented, version-specific `nvcc` restriction (a hard compile-time check `nvcc` performs against `__GNUC__`), not a real ABI incompatibility on most simple `.cu` files, and NVIDIA ships the `--allow-unsupported-compiler` escape hatch specifically for this class of "newer distro, older-pinned CUDA release" situation.
- llama.cpp's own CUDA `.cu` sources are simple, template-heavy C++17 without exotic new-compiler-only language features, making the unsupported-compiler bypass a low-risk choice for this specific build (this is a hypothesis to be CONFIRMED by the actual build attempt in Phase 4, not asserted as fact ahead of time — if the flag alone is insufficient, install `gcc-13`/`g++-13` via apt and set `CMAKE_CUDA_HOST_COMPILER` as the documented fallback).

**Alternatives considered**:
- Installing `gcc-13`/`g++-13` alongside the system default and pointing `CMAKE_CUDA_HOST_COMPILER` at it: kept as the documented FALLBACK (not the first attempt) — it works unconditionally but adds a second compiler toolchain to the host, which is unnecessary if the unsupported-compiler flag alone succeeds.
- Downgrading the host's default `gcc`: rejected outright — far too invasive for an unrelated project's toolchain, violates this project's own host-safety discipline (no destructive host-wide changes for a narrow build need).

## R3: Where does the CUDA flag actually need to be threaded through in `lib/engine.sh`?

**Decision**: `engine_build_llama()`'s existing `cuda)` case (lib/engine.sh:64-67) already sets `-DGGML_CUDA=ON` — no new detection code is needed for the CUDA-vs-CPU branch itself (this is a real, already-existing capability, confirmed by direct code reading this session). The ONLY engine.sh change needed is passing the R2 compiler-compatibility flag(s) into the `cmake_args` array, conditionally, only in the `cuda)` branch.

**Evidence gathered this phase**:
- `lib/engine.sh` lines 46-52 (`engine_detect_backend`): already returns `cuda` when `have_cmd nvcc || [[ -x /usr/local/cuda/bin/nvcc ]]` — this fires automatically the moment `nvcc` is on `PATH`, requiring zero changes once the toolkit is installed.
- `lib/engine.sh` lines 64-67: already appends `-DGGML_CUDA=ON` to `cmake_args` in the `cuda)` case — this is the actual llama.cpp CMake flag that compiles the CUDA backend in.
- The gap is narrowly: if `nvcc --allow-unsupported-compiler` (R2) is required, that flag must reach `nvcc` via CMake's `CMAKE_CUDA_FLAGS`, appended in the same `cuda)` branch, gated behind a runtime probe (attempt a trivial `nvcc` invocation, or simply always pass it — passing an unnecessary flag to a `nvcc` that doesn't need it is a no-op, not a regression risk) — the plan therefore keeps this to a single, always-safe additive line rather than a new detection branch.

**Alternatives considered**:
- A full separate "detect nvcc version vs gcc version and only add the flag when needed" probe: rejected as unnecessary complexity — `--allow-unsupported-compiler` is a documented no-op when the compiler IS supported (NVIDIA's own docs: the flag only changes behavior when the check would otherwise fail), so unconditional inclusion in the `cuda)` branch is simpler and equally safe.

## R4: How is GPU offload measured/verified per FR-002/FR-003/SC-001/SC-002?

**Decision**: Reuse the existing hardware-probe + catalog-planning pipeline for the VRAM-delta observation (no new measurement code needed), and add a new, dedicated timing/throughput comparison test for the tok/s-improvement observation (this is genuinely new test code, not existing).

**Evidence gathered this phase**:
- `lib/hardware.sh` (lines 116-122) already parses `nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits` for total VRAM — this is the BEFORE/AFTER-load `nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits` delta the spec's SC-001 (≥500 MiB VRAM delta) needs; no code change required to CAPTURE this observation, only a new TEST that samples it around a model-load event.
- `lib/catalog.sh` (lines 236-249) already computes `"ngl": int(dfl.get("ngl", 99))` (full offload) vs `"ngl": 0` (CPU-only) per profile based on whether the model+KV fits the detected VRAM budget — meaning once the CUDA build exists and VRAM is correctly detected, profiles will AUTOMATICALLY be planned for GPU offload with no scheduler/catalog code changes; this confirms FR-004 (planner unaffected on non-GPU hosts) is already true by construction (a host reporting 0 total VRAM already always plans `ngl: 0`, i.e. CPU mode, per the existing `catalog_plan_json` python logic).
- The throughput-improvement observation (SC-002, ≥2x) has NO existing test — this is genuinely new: a test that runs the same profile/prompt once forced to `ngl=0` and once at the catalog-planned `ngl` value, measures tokens/sec via the smoke-test's existing `.choices[0].message.content`-based real-completion mechanism (the same pattern already used by `_dl_smoke_test_gguf()` in `lib/download.sh`, extended to record elapsed-time-to-completion and derive tok/s from token count).

**Alternatives considered**:
- A synthetic/mocked "did GPU offload happen" check reading only `llama-server`'s startup log line claiming CUDA init: rejected as insufficient per this project's own anti-bluff discipline (Constitution §11.4/§11.4.1) — a log line claiming GPU init is not evidence of real inference-time GPU utilization or real throughput improvement; the chosen approach measures the actual `nvidia-smi` memory delta and the actual wall-clock throughput delta, both real runtime observations.

## R5: Does this feature require an OS-conditional (macOS/ROCm) code path change?

**Decision**: No. Out of scope by the spec's own Assumptions section (this feature targets this host's confirmed NVIDIA GPU; macOS/Metal and ROCm/AMD paths in `lib/engine.sh` are pre-existing, untouched, and not exercised by this feature's tests).

**Evidence gathered this phase**: `engine_detect_backend()`'s `metal)` and `rocm)` branches (lib/engine.sh lines 60-63, 68-70) are independent `case` arms from the `cuda)` arm this feature touches — editing the `cuda)` arm cannot affect the other two by construction (they are mutually exclusive branches of the same `case` statement, selected once per build based on `engine_detect_backend`'s single return value).
