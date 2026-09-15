# Plan — llmctl Project Build

Goal: Deliver a complete, ready-to-run `llmctl` project (Linux + macOS) as `.zip` and `.tar.gz` archives: a full git repo with commit history, llama.cpp + Colibri as git submodules (built from source, hardware-optimized), dynamic hardware-aware model selection, multi-model co-residency with automatic switching, verified model downloads, deterministic validation/verification per the provided V&V research, and integration docs for CLI agents (opencode, pi, crush, claude code, aider, continue, cline).

## Stage 0 — Source Verification (anti-slop gate)
Deploy parallel `explore` agents:
- 0a: Verify existence + correct URLs of engine repos (ggml-org/llama.cpp; Colibri repo — validate the exact upstream), current build flags (GGML_CUDA, Metal for macOS), llama-server CLI flags used in the design.
- 0b: Verify every HuggingFace model repo + filename in the catalog actually exists (HF API), plus checksums availability; replace any hallucinated entries with real, verified equivalents.
Output: verified facts sheet (URLs, flags, model repo IDs, filenames, sizes). FAIL → fix catalog before build.

## Stage 1 — Implementation (coder, foreground, single repo)
Workdir: /mnt/agents/output/llmctl (git init; commits per milestone).
Deliverables:
- `.gitmodules` + submodules `submodules/llama.cpp`, `submodules/colibri` (shallow), `git submodule update --init --recursive` works offline from archive. **[Corrected 2026-09-15]**: this plan originally named the path `vendor/llama.cpp`/`vendor/colibri`; the project ultimately placed the real, pinned git submodules under `submodules/` instead (matching `.gitmodules`), and `lib/engine.sh`/`lib/doctor.sh`/`lib/download.sh`/`lib/scheduler.sh` are wired to that path. An earlier, un-pinned, directly-committed copy that had accumulated at `vendor/llama.cpp`/`vendor/colibri` (not a submodule - no `.git` link, different content/version) was removed from git tracking as part of this correction (Phase 3, US1, T017).
- `lib/`: os_detect.sh (Linux/macOS), hardware.sh (CPU cores/model/flags, RAM, GPU incl. NVIDIA CUDA/AMD ROCm/Apple Metal, VRAM, storage type NVMe/SATA/HDD), catalog.sh, scheduler.sh (VRAM/RAM budget → co-residency set or fallback switching), download.sh (resume + checksum verify + post-download smoke test), systemd.sh (Linux) / launchd.sh (macOS), doctor.sh.
- `bin/llmctl`: init/setup/build/models/list/plan/start/stop/restart/status/switch/enable/disable/logs/test/doctor.
- `models/catalog.json`: verified models only, tiered by hardware class (baseline: Ryzen 7 2700X/32GB/RTX3060-12GB; workstation: Threadripper 64-core/32GB VRAM).
- `tests/`: deterministic shell test harness (exact commands, exit codes, raw output) + `tests/run_tests.sh`.
- `Makefile`, `README.md`, `docs/integrations.md` (agent configs from research), `docs/validation.md` (V&V methodology applied), `LICENSE`, `.gitignore`.

## Stage 2 — Deterministic V&V (verifier, foreground)
Run: `shellcheck` on every script, `bash -n`, JSON validation, full test suite, `make test`. Capture exact commands + exit codes + raw output into `VALIDATION_REPORT.md` (committed). Zero failures allowed; else return to Stage 1 fixer.

## Stage 3 — Review rounds (2 reviewers, parallel)
- R1: correctness/safety review (shell pitfalls, portability Linux+macOS, systemd/launchd unit correctness, no bluff claims in docs).
- R2: requirements-compliance review (every user MUST mapped to implemented evidence).
Fix subagent applies fixes with new commits; Stage 2 re-run after fixes (minimum 2 review-polish rounds).

## Stage 4 — Packaging & Delivery (orchestrator)
- Final `make test` gate; `git log` sanity check.
- Produce `/mnt/agents/output/llmctl.zip` and `/mnt/agents/output/llmctl.tar.gz` containing working tree incl. `.git` + `.git/modules/*` (submodule objects) so archives are fully offline-runnable and push-ready.
- Verify archives by extracting to clean dir and re-running `make test`.
