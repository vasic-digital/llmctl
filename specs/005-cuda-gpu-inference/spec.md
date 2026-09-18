# Feature Specification: CUDA GPU-Accelerated Inference Enablement

**Feature Branch**: `005-cuda-gpu-inference`

**Created**: 2026-09-18

**Status**: Draft

**Input**: User description: "GPU-backed inference enablement for llmctl: install the CUDA toolkit matching this host's existing NVIDIA driver (RTX 3060, driver 595.84, CUDA 13.2 capable, compute capability 8.6, 12GB VRAM), rebuild the llama.cpp engine via lib/engine.sh's existing auto-detection path (nvcc on PATH -> GGML_CUDA=ON, already implemented, currently never triggers because nvcc is absent), and re-verify every fitting catalog profile (small, vision, fast, moe-fast, vision-pro, colibri-qwen36) end-to-end on the resulting GPU-accelerated build: real smoke test, real chat completion, and the Claude Toolkit Superpowers-TUI layer-4 challenge (via claude-providers.sh verify <alias> --deep). This closes a previously-documented "structurally impossible" finding in docs/CONTINUATION.md (no GPU-backed inference path on this host) that independent hardware investigation has now shown is NOT structurally impossible - the GPU and driver are fully capable, only the CUDA compiler toolkit was missing. Success is measured per-profile: does real GPU offload measurably reduce inference latency (n-gpu-layers actually resident in VRAM, confirmed via nvidia-smi during inference, not just claimed by a --n-gpu-layers flag), and does at least one profile now genuinely pass the full multi-turn Superpowers-TUI challenge within its timeout where it previously did not. Must not silently regress the CPU-only fallback path for hosts without a GPU - the existing auto-detection and its own tests must continue to work unchanged when nvcc is absent."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A downloaded model actually runs on the GPU, not just claims to (Priority: P1)

An operator who has already downloaded and verified a catalog profile (e.g. `small`) rebuilds the llama.cpp engine on a host with a capable NVIDIA GPU whose driver is present but whose CUDA compiler toolkit was missing. After installing the toolkit and rebuilding, starting that profile genuinely offloads model layers to the GPU — verifiable independently of the tool's own reported success line, by observing real VRAM usage on the GPU while the model is loaded and serving.

**Why this priority**: Every other outcome in this feature depends on the engine build actually producing GPU-capable code. Without this, "GPU enabled" would be exactly the kind of unverified claim this project's own anti-bluff discipline forbids.

**Independent Test**: Build the engine on a host with the CUDA toolkit installed, start any one fitting profile, and confirm — via a GPU-utility query taken while the server is actively serving a request — that VRAM usage on the GPU rose to a level consistent with that profile's model size, not merely that the launch command included a GPU-layer flag.

**Acceptance Scenarios**:

1. **Given** the CUDA toolkit is installed and the engine is rebuilt, **When** an operator inspects the build's own capability report, **Then** it states GPU support is compiled in (never a bare "the flag was passed" assumption).
2. **Given** a profile is started on the GPU-capable build, **When** the operator queries real GPU memory usage while an inference request is in flight, **Then** VRAM usage is measurably higher than the idle baseline, confirming layers are actually resident on the GPU.
3. **Given** the same profile was previously measured on a CPU-only build, **When** it is re-measured on the GPU-capable build under an equivalent workload, **Then** its inference throughput is measurably faster.

---

### User Story 2 - At least one model now completes the full multi-turn assistant challenge it previously failed (Priority: P1)

The same host previously had every tested profile fail a real, multi-turn Claude Code + Superpowers-plugin conversation because CPU-only inference was too slow to finish within the client's own timeout. After GPU enablement, an operator re-runs that same real, unmodified challenge against at least one profile and it completes successfully within its normal timeout, with the same live model, same real multi-turn conversation, and same success criteria as the original (now-superseded) failing run.

**Why this priority**: This is the concrete, previously-blocked outcome that motivated this feature — closing it is what turns "GPU is technically enabled" into "an operator's actual problem is solved."

**Independent Test**: Re-run the exact same challenge invocation that previously failed on the same profile (or the smallest/fastest fitting profile if that one is chosen instead) against the GPU-capable build, with no change to the challenge's own timeout, and observe a genuine pass with the model's real answers captured as evidence.

**Acceptance Scenarios**:

1. **Given** a profile that previously failed the challenge with a timeout, **When** it is re-run unmodified on the GPU-capable build, **Then** the challenge reports success with captured evidence of the real multi-turn exchange.
2. **Given** the challenge still fails for a specific profile even after GPU enablement, **When** that result is reported, **Then** the reason is captured and disclosed honestly (e.g. that specific profile's model is still too large for this GPU's VRAM) rather than silently omitted.

---

### User Story 3 - A host without a capable GPU is completely unaffected (Priority: P2)

An operator running this same project on a different host that has no NVIDIA GPU, or a GPU driver without CUDA support, builds and runs the engine exactly as before. The build process detects the absence of the CUDA toolkit exactly as it already does today, falls back to the CPU-only build path with no behavior change, and every existing CPU-only test continues to pass unmodified.

**Why this priority**: This feature must not narrow the project's own portability — a regression here would break every other host and CI-shaped environment that has no GPU at all.

**Independent Test**: With `nvcc` absent from `PATH` (the existing, already-tested condition), rebuild the engine and confirm the build is identical in behavior to before this feature existed, and that the project's full existing test suite still passes unchanged.

**Acceptance Scenarios**:

1. **Given** a host with no CUDA toolkit installed, **When** the engine is built, **Then** it produces the same CPU-only build it always has, with no new failure mode introduced.
2. **Given** the full pre-existing automated test suite, **When** it is run on a GPU-less host after this feature lands, **Then** every test that passed before this feature still passes, with the same results.

---

### Edge Cases

- What happens when the CUDA toolkit is installed but its version is newer or older than what the installed NVIDIA driver actually supports (a driver/toolkit version mismatch)?
- What happens when a profile's model plus its KV cache genuinely does not fit in the GPU's available VRAM even after GPU offload is enabled — does it fail loudly, or silently fall back to partial/CPU-only layers?
- What happens when the GPU is shared with another already-running GPU workload on this host at the moment a profile is started — does the budget/placement logic account for real, currently-used VRAM, or only for the GPU's total nameplate capacity?
- What happens if the CUDA toolkit installation itself is interrupted or partially completes — does a subsequent engine build detect this honestly (e.g. `nvcc` present but non-functional) rather than silently reporting a CPU-only or broken build as a success?
- What happens to a profile that was already downloaded, verified, and previously smoke-tested only on the CPU-only build — does it need to be re-verified from scratch on the new build, or can prior verification be trusted to still apply?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST provide a documented, repeatable way to install a CUDA compiler toolkit version compatible with this host's already-installed NVIDIA driver, without requiring a driver change.
- **FR-002**: The engine build process MUST detect the installed CUDA toolkit and produce a GPU-capable build automatically, using its existing detection mechanism, without requiring any new manual flag from the operator.
- **FR-003**: The engine build process MUST continue to produce a working CPU-only build, with no behavior change, on any host where the CUDA toolkit is absent.
- **FR-004**: The system MUST provide a way to independently confirm — from outside the tool's own self-reported success messages — that a running model server is genuinely using the GPU, not merely that it was launched with a GPU-layer argument.
- **FR-005**: Every catalog profile that fits this host's hardware budget MUST be re-verified end-to-end on the GPU-capable build: real download-integrity check (already existing, unaffected), real smoke test, and a real chat completion.
- **FR-006**: At least one previously-failing profile MUST be re-run through the full, unmodified multi-turn assistant challenge it previously failed, and the result (pass or a specific, honestly-disclosed reason for continued failure) MUST be captured as evidence.
- **FR-007**: The full pre-existing automated test suite (all currently-passing tests, in both the bash CLI and the Go daemon) MUST continue to pass unchanged after this feature lands, on both a GPU-capable host and a GPU-less host.
- **FR-008**: Any profile whose GPU-offloaded memory requirement does not fit in currently-available VRAM MUST fail the placement/budget check with an exact, specific reason (not a generic or silent failure), matching this project's existing budget-refusal behavior for RAM.
- **FR-009**: The system MUST NOT claim GPU acceleration succeeded based solely on a build flag or a launch argument — every claim of "running on GPU" for a specific profile MUST be backed by a real, captured GPU-utilization measurement taken while that profile was serving a request.

### Key Entities

- **CUDA Toolkit Installation**: The host-level compiler/runtime package that must be present for the engine's existing GPU auto-detection to trigger; versioned, and must be compatible with the already-installed NVIDIA driver.
- **GPU-Capable Engine Build**: The compiled inference engine binary produced when the CUDA toolkit is detected at build time; distinct from, but must remain behaviorally compatible in its CPU-only fallback with, the existing CPU-only build.
- **GPU Utilization Evidence**: A captured, independently-verifiable measurement (taken from the GPU itself, not from the inference tool) proving a specific profile's process is genuinely resident in GPU memory while serving.
- **Superpowers-TUI Challenge Result**: The existing pass/fail/timeout outcome record for a profile's real multi-turn Claude Code + Superpowers-plugin conversation, now re-measured on the GPU-capable build.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can go from "CUDA toolkit not installed" to "engine rebuilt with GPU support automatically detected" using a single documented procedure, with no manual build-flag editing required.
- **SC-002**: For at least one catalog profile, real GPU memory usage measured during an active inference request is at least 500 MiB higher than the GPU's idle baseline, directly evidencing genuine GPU residency (not a claimed one).
- **SC-003**: For at least one catalog profile, measured inference throughput (tokens per second, under an equivalent prompt/response workload) on the GPU-capable build is at least 2x the throughput measured on the CPU-only build.
- **SC-004**: At least one catalog profile that previously failed the full multi-turn Superpowers-TUI challenge with a timeout now completes it successfully within the challenge's existing, unmodified timeout.
- **SC-005**: 100% of the project's pre-existing automated tests (bash CLI suite and Go daemon suite) pass unchanged both before and after this feature, on this host.
- **SC-006**: Zero profiles report "running on GPU" without a corresponding captured GPU-utilization measurement backing that claim.

## Assumptions

- The host's NVIDIA driver (595.84, reporting CUDA 13.2 capability) does not need to change; only the CUDA compiler toolkit itself is being added.
- Installing the CUDA toolkit is a host-level, sudo-requiring system change; the operator has already authorized this specific remediation path (distinct from earlier, more general system-level changes that were explicitly deferred pending an operator decision).
- The existing per-profile hardware-fit budget logic (RAM/VRAM accounting in `llmctl plan`) already has a VRAM concept; this feature makes that concept correspond to genuinely-used GPU memory rather than an estimate the host's software stack has no way to fulfill.
- Re-verifying "every fitting catalog profile" means every profile the planner already reports as fitting this host's RAM/VRAM budget today (`small`, `vision`, `fast`, `moe-fast`, `vision-pro`, `colibri-qwen36`) — profiles that already fail the hardware-fit check (`coder`, `colibri-glm`, `ws-dense-32b`, `ws-moe-30b`) remain out of scope for this feature unless the added GPU headroom changes their fit outcome, which is itself worth checking but is not assumed in advance.
- A single GPU (this host has exactly one) is shared across whichever profiles are started concurrently; this feature does not introduce multi-GPU support.
