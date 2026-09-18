# Tasks: CUDA GPU-Accelerated Inference Enablement

**Input**: Design documents from `/specs/005-cuda-gpu-inference/`
**Prerequisites**: plan.md, research.md, quickstart.md

**Tests are explicitly requested** — this feature's own Success Criteria are
entirely evidence-based (VRAM delta, throughput ratio, Superpowers-TUI PASS),
so every user story includes its proving test(s).

## Phase 1: Setup

- [ ] T001 Confirm host prerequisites are still as documented in research.md: run `nvidia-smi --query-gpu=name,driver_version,memory.total,compute_cap --format=csv,noheader` and record the output as the baseline evidence file `docs/qa/005-cuda-gpu-inference/host_baseline.txt`

- [ ] T002 Install the CUDA toolkit: `sudo apt-get update && sudo apt-get install -y nvidia-cuda-toolkit`, then confirm with `nvcc --version` — record the exact output in `docs/qa/005-cuda-gpu-inference/nvcc_version.txt`

## Phase 2: Foundational

- [ ] T003 Attempt an unmodified `engine_build_llama` rebuild (`bash -c 'source lib/engine.sh; engine_build_llama'`) to establish whether research.md R2's host-compiler-compatibility flag is actually needed on THIS toolkit/gcc pairing — capture the raw build log to `docs/qa/005-cuda-gpu-inference/build_attempt_1_unmodified.log`. If it succeeds, T004-T005 are skipped (documented, not silently dropped) and the plan proceeds to T006 with the unmodified `lib/engine.sh`. If it fails with an unsupported-host-compiler error, proceed to T004.

## Phase 3: User Story 1 - GPU offload genuinely measurable via VRAM delta (Priority: P1) 🎯 MVP

**Goal**: Prove a cataloged profile's model load produces a real, measured VRAM delta on this host, not merely a claimed one.

**Independent Test**: Load a GPU-eligible cataloged profile and confirm `nvidia-smi`'s reported memory.used increases by at least the model's expected footprint.

- [ ] T004 [US1] (only if T003 failed) Write the failing test first: `tests/test_engine_cuda_build.sh` asserting, under `LLMCTL_DRY_RUN=1`, that `engine_build_llama`'s emitted `cmake` command line for the `cuda` backend contains BOTH `-DGGML_CUDA=ON` and a `CMAKE_CUDA_FLAGS=-allow-unsupported-compiler` entry. Run it — it MUST fail (the flag does not exist in `lib/engine.sh` yet).

- [ ] T005 [US1] (only if T003 failed) Add the compiler-compatibility flag to `lib/engine.sh`'s `engine_build_llama()`, inside the existing `cuda)` case (around line 65), as an additive `cmake_args+=(-DCMAKE_CUDA_FLAGS=-allow-unsupported-compiler)` line immediately after the existing `cmake_args+=(-DGGML_CUDA=ON)` line. Re-run T004's test — it MUST now pass. Re-run T003's real (non-dry-run) build — it MUST now succeed; capture the log to `docs/qa/005-cuda-gpu-inference/build_attempt_2_with_flag.log`. If it STILL fails, apply research.md R2's documented fallback (install `gcc-13`/`g++-13`, set `CMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-13` as an additional `cmake_args` entry gated the same way) and repeat until a real build succeeds.

- [ ] T006 [US1] Confirm the built binary actually links a CUDA backend: `./submodules/llama.cpp/build/bin/llama-server --list-devices` MUST list at least one `CUDA` device. Capture output to `docs/qa/005-cuda-gpu-inference/list_devices.txt`.

- [ ] T007 [US1] Write the failing test first: `tests/test_gpu_vram_delta.sh` that (a) captures `nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits` as `before`, (b) starts a real, GPU-eligible cataloged profile (e.g. `fast`) via the existing `llmctl enable <profile>` / `sched_enable` path, (c) waits for the profile's health endpoint to respond, (d) captures `memory.used` again as `after`, (e) asserts `after - before >= 500`. Run it against the PRE-CUDA-build binary (or with `nvcc` temporarily removed from `PATH`) first — it MUST fail (no CUDA backend means no meaningful VRAM delta from model load, since the model loads into system RAM instead).

- [ ] T008 [US1] Run T007's test against the real CUDA-enabled build from T005/T006. It MUST now pass. Capture the before/after numbers and the delta to `docs/qa/005-cuda-gpu-inference/vram_delta.txt` as this story's positive evidence.

**Checkpoint**: User Story 1 is independently complete and testable at this point — a GPU-eligible profile's load is proven to genuinely allocate GPU memory.

## Phase 4: User Story 2 - Superpowers-TUI challenge passes on a GPU-capable profile (Priority: P1)

**Goal**: Reverse the previously-recorded FAIL verdict (docs/CONTINUATION.md §10m) for at least one profile.

**Independent Test**: A real, multi-turn Claude Code + Superpowers session against the CUDA-enabled `moe-fast` (or another GPU-eligible) profile completes within Claude Code's own per-request timeout.

- [ ] T009 [US2] Write the failing test first: `tests/test_gpu_throughput_ratio.sh` that (a) runs the same profile+prompt once with `--n-gpu-layers 0` forced (CPU-only) and once at the catalog-planned `ngl` value, (b) measures wall-clock time to the completion response and derives tokens/sec from the response's token count (reusing the `_dl_smoke_test_gguf()` real-completion pattern from `lib/download.sh`), (c) asserts the GPU run's tok/s is at least 2x the CPU run's tok/s. Run it against the pre-CUDA build (or `nvcc` removed from `PATH`) — it MUST fail (both runs are CPU-only, ratio ~1x).

- [ ] T010 [US2] Run T009's test against the CUDA-enabled build. It MUST now pass. Capture both tok/s numbers and the ratio to `docs/qa/005-cuda-gpu-inference/throughput_ratio.txt`.

- [ ] T011 [US2] Re-run the exact Superpowers-TUI live-session procedure documented in `docs/CONTINUATION.md` §10m against the CUDA-enabled `moe-fast` profile (or the same profile the original FAIL was recorded against). Capture the full session transcript to `docs/qa/005-cuda-gpu-inference/superpowers_tui_session.log`.

- [ ] T012 [US2] Update `docs/CONTINUATION.md` §10m (never silently delete the prior FAIL entry — per this project's own demotion-evidence discipline) with a new, dated PASS entry citing T011's transcript, explicitly stating it supersedes the prior FAIL under the now-CUDA-enabled build.

**Checkpoint**: User Stories 1 AND 2 are both independently complete — GPU offload is proven real (US1) and proven EFFECTIVE for the originally-blocking use case (US2).

## Phase 5: User Story 3 - CPU-only hosts unaffected (Priority: P2)

**Goal**: Prove the CUDA branch is unreachable, and behavior unchanged, on a host without `nvcc`.

**Independent Test**: With `nvcc` absent from `PATH`, `engine_detect_backend` still returns `cpu` and the CPU build path is unaffected.

- [ ] T013 [P] [US3] Write the failing test first (though it should currently PASS, since T005 is additive-only — this task's job is to LOCK that guarantee in as a permanent regression test, not discover a new defect): `tests/test_engine_cpu_regression.sh` asserting that with a `PATH` excluding any `nvcc`/`cuda` directory (`PATH="$(echo "$PATH" | tr ':' '\n' | grep -v cuda | paste -sd:)"`), `engine_detect_backend` returns exactly `cpu`, and `LLMCTL_DRY_RUN=1 engine_build_llama`'s emitted cmake command contains `-DGGML_NATIVE=ON` and does NOT contain `-DGGML_CUDA=ON` or the T005 compiler-compatibility flag. Run it — confirm it PASSES against the current (post-T005) `lib/engine.sh` (proving T005's change was genuinely additive, never touching the `cpu)`/`metal)`/`rocm)` branches).

- [ ] T014 [P] [US3] Author the meta-test paired mutation (Constitution §1.1): a mutation that moves the T005 compiler-compatibility flag OUTSIDE the `cuda)` case (e.g., unconditionally into the shared `cmake_args` base array) MUST make T013 fail. Confirm this mutation-and-revert cycle in `docs/qa/005-cuda-gpu-inference/meta_test_evidence.txt`.

**Checkpoint**: All three user stories complete. The feature is fully proven: GPU offload is real (US1), effective for its originally-blocking use case (US2), and provably inert on CPU-only hosts (US3).

## Phase 6: Polish & Cross-Cutting

- [ ] T015 Update `docs/scripts/engine.sh.md` (the existing §11.4.18 companion doc) with a short addendum describing the new `CMAKE_CUDA_FLAGS` behavior added in T005, per this project's own doc-sync discipline.

- [ ] T016 Run the full existing bash test suite (`bash tests/test_all.sh` or the project's established full-suite entry point) to confirm zero regressions from every change in this feature. Capture the full pass/fail summary to `docs/qa/005-cuda-gpu-inference/full_suite_regression.txt`.

## Dependencies

- Phase 1 (Setup) blocks Phase 2 (Foundational).
- Phase 2 (Foundational) blocks all user story phases (the build must exist before any of them can run their real, live tests).
- User Story 1 (Phase 3) and User Story 3 (Phase 5) are independent of each other and MAY run in parallel once Phase 2 completes.
- User Story 2 (Phase 4) depends on User Story 1's CUDA-enabled build (Phase 3) being real and verified (T006/T008) — it reuses the same built binary, not a separate build.
- Phase 6 (Polish) depends on all prior phases.

## Parallel Example

```
# After Phase 2 completes, User Story 1 and User Story 3 can be worked in parallel:
Task: "T007 [US1] write tests/test_gpu_vram_delta.sh"
Task: "T013 [P] [US3] write tests/test_engine_cpu_regression.sh"
```

## Implementation Strategy

**MVP**: Phase 1 + Phase 2 + Phase 3 (User Story 1) delivers a working,
independently-verifiable proof that GPU offload is real on this host —
the minimum slice that is genuinely useful on its own. User Story 2
(the actual originally-blocking Superpowers-TUI problem) and User Story 3
(regression-proofing) each add independently before the feature is
considered fully done.
