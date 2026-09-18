# Implementation Plan: CUDA GPU-Accelerated Inference Enablement

**Branch**: `005-cuda-gpu-inference` | **Date**: 2026-09-18 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/005-cuda-gpu-inference/spec.md`

## Summary

This host has a real, confirmed NVIDIA GPU (RTX 3060, 12GB VRAM, driver 595.84, compute capability 8.6) but its `llama-server` build has no CUDA backend compiled in, forcing all inference onto CPU-only paths too slow to pass the Superpowers-TUI live-coding challenge (previously observed at ~2.9-6.6 tok/s across two model sizes). Direct code investigation this session (see [research.md](./research.md) R3) confirms `lib/engine.sh`'s CUDA auto-detection and CMake-flag wiring, and `lib/hardware.sh`/`lib/catalog.sh`'s VRAM-aware offload planning, ALREADY EXIST and require no new detection logic — the actual gap is (a) the CUDA toolkit is not installed on the host, (b) the host's `gcc 15.2` is newer than CUDA 12.4's supported host-compiler ceiling and needs a one-line compatibility flag, and (c) there is no test proving the resulting GPU offload is real (VRAM delta) and effective (throughput improvement, Superpowers-TUI pass). The approach is: install the toolkit, add the one-line compiler-compatibility flag to the existing `cuda)` branch in `lib/engine.sh`, rebuild, and add the missing verification tests.

## Technical Context

**Language/Version**: Bash (POSIX-ish, existing project convention), CMake (llama.cpp's build system, unmodified)

**Primary Dependencies**: `nvidia-cuda-toolkit` (distro package, provides `nvcc`), the existing `submodules/llama.cpp` pinned checkout (unmodified upstream source — only the CMake invocation flags change, in `lib/engine.sh`)

**Storage**: N/A — no new persistent data, no schema, no database

**Testing**: Bash test harness (`tests/*.sh`, existing project convention — `LLMCTL_DRY_RUN=1` pattern for build-invocation assertions, real subprocess execution for the live GPU-utilization and throughput tests)

**Target Platform**: This Linux host specifically (Ubuntu 26.04, NVIDIA RTX 3060) for the live-verification tests; the CMake flag change itself is host-conditional and inert on any host without `nvcc` (falls through to the pre-existing `cpu)` branch)

**Project Type**: Single bash CLI project with a vendored C++ build dependency (llama.cpp) — no frontend/backend split, no mobile target

**Performance Goals**: ≥2x tokens/sec throughput vs. the CPU-only baseline for the same profile+prompt (SC-002); a real, passing Superpowers-TUI multi-turn session on at least one GPU-capable profile (SC-004)

**Constraints**: Zero code changes to llama.cpp's own vendored source (only the CMake invocation in `lib/engine.sh` changes); zero regression for CPU-only hosts (FR-004, SC-005 — the `cuda)` CMake-flag branch must not be reachable when `nvcc` is absent, which is already true by construction of the existing `case` statement in `engine_detect_backend`); no destructive or invasive host-wide toolchain changes (R2 — no downgrading the host's default `gcc`)

**Scale/Scope**: One host, up to a handful of GGUF profiles already defined in the existing catalog (`fast`, `moe-fast`, and any others already present) — no new profile format, no new model downloads required beyond what is already cataloged

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **Principle I (Deterministic V&V)**: SATISFIED BY DESIGN — every acceptance scenario in the spec (VRAM delta, throughput ratio, Superpowers-TUI PASS) is a captured-command-output observation, never a "should work now" assertion. The plan's new tests (Phase 1) are the mechanism.
- **Principle III (Test-First + Anti-Bluff, four-layer)**: This feature's four layers are: (1) pre-build — a `bash -n`/shellcheck-clean `lib/engine.sh` diff, asserting the new CMake flag is present only in the `cuda)` branch; (2) post-build — the built `llama-server` binary reports a CUDA backend in its own `--list-devices` or startup-log output; (3) runtime — the real VRAM-delta and throughput-ratio tests against a live loaded model; (4) meta-test paired mutation — a mutation removing the new compiler-compatibility flag (or reverting `-DGGML_CUDA=ON` to absent) MUST make the post-build/runtime layer FAIL, proving the gate is not a bluff.
- **Principle IV (Real Environment Execution)**: SATISFIED — this feature is inherently host-real; there is no meaningful mocked-CUDA test that would prove anything (mocking `nvidia-smi` output would only prove the bash parsing logic, which R4 confirms already exists and is untouched by this feature).
- No violations requiring a Complexity Tracking justification.

## Project Structure

### Documentation (this feature)

```text
specs/005-cuda-gpu-inference/
├── plan.md              # This file
├── research.md          # Phase 0 output (complete)
├── quickstart.md        # Phase 1 output
└── tasks.md             # Phase 2 output (/speckit-tasks, not created by this command)
```

(No `data-model.md` or `contracts/` — this feature introduces no data entities and no external interface; it is a build-flag change plus new tests, per the plan-template's own guidance to omit these artifacts when a feature is purely internal.)

### Source Code (repository root)

```text
lib/
└── engine.sh              # MODIFY: engine_build_llama()'s existing cuda) branch
                            # gains one additive CMAKE_CUDA_FLAGS entry for the
                            # R2 compiler-compatibility flag; engine_detect_backend()
                            # is NOT modified (already correct per research.md R3)

docs/scripts/
└── engine.sh.md           # MODIFY: existing companion doc (per this project's
                            # own §11.4.18 mandate) gets a short addendum describing
                            # the new CMAKE_CUDA_FLAGS behavior

tests/
├── test_engine_cuda_build.sh        # NEW: LLMCTL_DRY_RUN=1 assertion that the
│                                    # cuda) branch's cmake invocation contains
│                                    # both -DGGML_CUDA=ON and the compatibility flag
├── test_gpu_vram_delta.sh           # NEW: loads a real cataloged GPU-planned
│                                    # profile, captures nvidia-smi memory.used
│                                    # before/after, asserts delta >= 500 MiB
└── test_gpu_throughput_ratio.sh     # NEW: runs the same profile+prompt at
                                     # ngl=0 (forced CPU) and at the catalog-
                                     # planned ngl, measures real tok/s via the
                                     # existing chat-completion smoke-test
                                     # pattern, asserts ratio >= 2x

docs/qa/
└── <run-id>/                        # NEW: captured evidence directory for this
                                     # feature's live runs (VRAM delta log,
                                     # throughput numbers, Superpowers-TUI
                                     # transcript) per this project's own
                                     # docs/qa/ evidence convention
```

**Structure Decision**: Single-project bash CLI layout (already established by this repository) — no new top-level directories, no new project type. The change surface is deliberately narrow: one modified function in one existing file, three new test files following the existing `tests/test_*.sh` naming and harness convention, and one new evidence directory following the existing `docs/qa/<run-id>/` convention already used elsewhere in this project (see `docs/qa/superpowers-tui-2026-09-*` referenced in `docs/CONTINUATION.md` §10m).

## Complexity Tracking

*No Constitution Check violations — table intentionally omitted.*
