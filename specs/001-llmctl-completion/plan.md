# Implementation Plan: llmctl Full Production Completion

**Branch**: `001-llmctl-completion` | **Date**: 2025-09-15 | **Spec**: specs/001-llmctl-completion/spec.md

**Input**: Feature specification from specs/001-llmctl-completion/spec.md

**Note**: This template is filled in by the `/speckit.plan` command; its definition describes the execution workflow.

## Summary

Bring llmctl to full production completion by implementing all pending features, establishing deterministic test suite with rock-solid evidence, creating exhaustive documentation suite, enabling live testing with real models across all 7 CLI agents, automating release process with GitHub/GitLab CLIs, and verifying full Constitution compliance. All work must follow Helix Universal Constitution with deterministic validation, anti-bluff gates, and zero AI slop/bluff.

## Technical Context

**Language/Version**: Bash 4.4+ / Python 3.8+ (for test harness and helpers)

**Primary Dependencies**: 
- llama.cpp v0.4.0 (git submodule, pinned)
- colibri v1.11.0 (git submodule, pinned)
- systemd (Linux) / launchd (macOS)
- Hugging Face Hub API (model downloads)
- shellcheck (linting)
- Python 3.8+ (test harness helpers, JSON processing)

**Storage**: Local filesystem (XDG dirs: ~/.local/state/llmctl/, ~/.config/systemd/user/, ~/Library/LaunchAgents/)

**Testing**: Bash test harness (tests/run_tests.sh), shellcheck, json-check, deterministic fixtures (LLMCTL_FAKE_HW), meta-test mutations

**Target Platform**: Linux (systemd --user) and macOS (launchd); Windows out of scope

**Project Type**: CLI tool / Local LLM orchestration system

**Performance Goals**: 
- Hardware probe < 2s
- Model download resumable with sha256 verification
- Scheduler budget computation < 100ms
- Service start < 5s (excluding model load)

**Constraints**: 
- Constitution §12.6: 60% RAM ceiling maximum
- Constitution §9: Hardlinked git backup before destructive ops
- Constitution §11.4: Anti-bluff covenant - every PASS needs positive evidence
- Constitution §1.1: Every gate paired with mutation proving it catches regressions
- Constitution §11.4.6: No guessing language (likely, probably, maybe forbidden)
- Constitution §11.4.3: Per-environment-topology test dispatch
- Constitution §11.4.4: Test-interrupt-on-discovery + retest from clean baseline
- Must support Linux (systemd --user) and macOS (launchd)

**Scale/Scope**: 
- 10 model profiles (fast, coder, vision, vision-pro, moe-fast, small, ws-dense-32b, ws-moe-30b, colibri-glm, colibri-qwen36)
- 7 CLI agent integrations (opencode, pi, crush, Claude Code, aider, continue.dev, Cline)
- 4 hardware tiers (below-minimum, baseline, workstation, datacenter)
- 17 validation/verification submodules in constitution/submodules/
- 4 hardware fixtures for deterministic testing

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Constitution Section | Requirement | Status | Notes |
|---------------------|-------------|--------|-------|
| §1 | Test coverage mandatory for every change | ✅ Pass | FR-002, SC-001 |
| §1.1 | Mutation-paired gates | ✅ Pass | FR-006, SC-005, meta_test_verification.sh |
| §2.1 | Multi-upstream push | ✅ Pass | 6 remotes for main, 6 for constitution |
| §3 | Submodule commits first | ✅ Pass | commit-fully processes submodules first |
| §4 | Tag mirroring | ✅ Pass | Tags pushed to all upstreams |
| §5 | Changelog discipline | ✅ Pass | CHANGELOG.md with conventional commits |
| §6 | Documentation nano-details | ⚠️ Partial | FR-008, SC-011, SC-012 - needs completion |
| §7.1 | No-bluff (positive evidence only) | ✅ Pass | FR-002, FR-006, SC-001 |
| §9 | Data safety (zero risk) | ✅ Pass | Hardlinked backups, no force-push |
| §11.4 | Anti-bluff covenant | ✅ Pass | FR-005, FR-006, FR-007 |
| §11.4.1 | FAIL-bluffs forbidden | ✅ Pass | Test harness design |
| §11.4.2 | Recorded evidence | ✅ Pass | Exit codes + raw output captured |
| §11.4.3 | Per-environment topology | ✅ Pass | Fixtures for CI, real models for release |
| §11.4.4 | Test-interrupt-on-discovery | ✅ Pass | Test harness stops on failure |
| §11.4.6 | No guessing | ✅ Pass | Evidence-based only |
| §11.4.7 | Demotion evidence | ✅ Pass | Test harness design |
| §12 | Host safety (60% RAM) | ✅ Pass | Budget enforcement in scheduler |
| §12.6 | 60% RAM ceiling | ✅ Pass | FR-015 |
| §12.10 | CONTINUATION.md sync | ✅ Pass | FR-017 |

**Gate Status**: ✅ PASS - All Constitution checks pass. Proceed to Phase 0.

## Project Structure

### Documentation (this feature)

```text
specs/001-llmctl-completion/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
└── tasks.md             # Phase 2 output (NOT created by /speckit.plan)
```

### Source Code (repository root)

```text
# Existing llmctl structure (to be completed/verified)
bin/
├── llmctl                    # Main CLI entrypoint
lib/
├── common.sh                 # Logging, colors, XDG paths, JSON helpers
├── os_detect.sh              # Linux/macOS detection
├── hardware.sh               # Hardware probe (CPU, RAM, GPU, VRAM, storage)
├── catalog.sh                # Catalog queries + hardware planner
├── download.sh               # Resumable downloads + sha256 verify + smoke test
├── engine.sh                 # llama.cpp / colibri builds
├── scheduler.sh              # Co-residency, switching, LRU eviction
├── service_linux.sh          # systemd --user template units
├── service_macos.sh          # launchd LaunchAgents
├── doctor.sh                 # Environment self-diagnosis
models/
├── catalog.json              # Model profiles with sha256, tiers, ports
tests/
├── run_tests.sh              # Test harness runner
├── test_syntax.sh            # bash -n + shebang + strict mode
├── test_catalog_json.sh      # Catalog JSON validity
├── test_hardware_probe.sh    # Hardware probe + fixtures
├── test_planner.sh           # Planner tiers, footprints, co-residency
├── test_download.sh          # Download + verify + smoke test
├── test_scheduler.sh         # Scheduler start/refuse/evict/protect/switch
├── test_services.sh          # systemd/launchd unit contents
├── test_cli.sh               # CLI help/version/exit codes
├── fixtures/
│   ├── hw-baseline.json
│   ├── hw-workstation.json
│   ├── hw-apple.json
│   └── hw-constrained.json
Makefile
README.md
docs/
├── architecture.md
├── hardware-tiers.md
├── integrations.md
├── validation.md
├── validation_and_verification.md
constitution/                 # Helix Universal Constitution submodule
├── Constitution.md
├── CLAUDE.md
├── AGENTS.md
├── scripts/validation/
│   ├── run_verification.sh
│   └── meta_test_verification.sh
├── submodules/               # 17 validation/verification submodules
submodules/
├── superspec/                # SuperSpec submodule
├── llama.cpp/                # llama.cpp engine (pinned v0.4.0)
├── colibri/                  # colibri engine (pinned v1.11.0)
```

**Structure Decision**: Existing llmctl structure (Option 1: Single project). All paths are relative to repository root.

## Complexity Tracking

> No Constitution violations - all gates pass. No violations to track.

---

## Phase 0: Research Tasks

*All research tasks derived from spec requirements and Constitution constraints.*

### Research Task 0.1: Test Fixture Enhancement
**Question**: What additional hardware fixtures are needed beyond the 4 existing (baseline, workstation, Apple Silicon, constrained)?
**Research**: Review planner test coverage gaps, identify missing hardware profiles (e.g., AMD GPU, Intel GPU, mixed CPU/GPU, low-memory, high-core-count).
**Deliverable**: Document required fixtures in research.md with JSON schemas.

### Research Task 0.2: Test Determinism Deep Dive
**Question**: What are all sources of non-determinism in llama.cpp and colibri beyond temperature/seed?
**Research**: Investigate llama.cpp threading, quantized model variance, hardware-specific optimizations, colibri memory-mapping behavior across kernels.
**Deliverable**: Document all determinism parameters per engine in research.md.

### Research Task 0.3: CLI Agent Integration Matrix
**Question**: What are the exact curl install commands, config formats, and verification steps for all 7 CLI agents?
**Research**: For each agent (opencode, pi, crush, Claude Code, aider, continue.dev, Cline), document: install command, config schema, verification command, troubleshooting.
**Deliverable**: Integration matrix table in research.md.

### Research Task 0.4: Documentation Completeness Audit
**Question**: What documentation files exist vs. required (quickstart, tutorial, FAQ, user manual, API reference, architecture diagrams)?
**Research**: Audit docs/ directory against FR-008 requirements. Identify gaps.
**Deliverable**: Documentation gap analysis in research.md.

### Research Task 0.5: Release Automation Patterns
**Question**: Best practices for gh/glab release automation with changelog generation from conventional commits?
**Research**: gh release create options, glab release create options, changelog generation tools (git-cliff, conventional-changelog), asset upload patterns.
**Deliverable**: Release automation design in research.md.

### Research Task 0.6: Constitution Compliance Audit
**Question**: Are there any subtle Constitution violations in current implementation?
**Research**: Audit each Constitution section against current codebase. Focus on §6 (documentation), §11.4.2 (evidence), §11.4.6 (no guessing), §12.10 (CONTINUATION.md).
**Deliverable**: Compliance audit report in research.md.

### Research Task 0.7: Documentation Diagram Standards
**Question**: What Mermaid diagram types and conventions for architecture docs?
**Research**: Mermaid diagram types (flowchart, sequence, class, state, gantt), styling conventions, rendering in GitHub/GitLab, accessibility.
**Deliverable**: Diagram standards guide in research.md.

### Research Task 0.8: CLI Agent Installation Automation
**Question**: curl install commands and verification for all 7 agents?
**Research**: For each agent, find official install method, config file location, verification command, health check.
**Deliverable**: Installation automation scripts design in research.md.

### Research Task 0.9: Deterministic Live Challenge Design
**Question**: Exact llama.cpp/colibri parameters for deterministic output?
**Research**: llama.cpp --seed, --temp, --mirostat, --repeat-penalty; colibri determinism parameters; cross-engine consistency.
**Deliverable**: Determinism parameter matrix in research.md.

### Research Task 0.10: Release Artifact Validation
**Question**: How to verify llmctl.tar.gz/zip contains working tree + .git + all submodules recursively?
**Research**: git archive options, submodule inclusion verification, archive testing procedures, checksum validation.
**Deliverable**: Release artifact validation procedure in research.md.

---

## Phase 1: Design & Contracts

### Data Model (data-model.md)

Entities from spec:
1. **ModelProfile**: engine (llama.cpp/colibri), size_bytes, min_tier, port, sha256, engine_flags, repo_id, filename
2. **HardwareProfile**: cpu_cores, simd_flags, ram_bytes, gpu_vram_bytes, storage_type, tier
3. **ServiceUnit**: profile_id, pid, ram_reserved_mib, vram_reserved_mib, port, start_epoch, engine
4. **SchedulerState**: co_residency_groups, eviction_order, lru_timestamps, budget_enforcement
5. **CLIAgentConfig**: agent_name, base_url, api_key, model_id, install_method, config_path

Relationships: HardwareProfile → tier → ModelProfile.min_tier; SchedulerState → ServiceUnit reservations; ModelProfile → ServiceUnit instance.

### Contracts (contracts/)

**CLI Command Contract** (bin/llmctl):
- Commands: setup, doctor, hw, plan, models, build, start, stop, switch, auto, status, logs, install, enable, disable, restart
- JSON output via --json flag
- Exit codes: 0=success, 1=error, 2=invalid args, 3=budget exceeded

**Model Catalog Contract** (models/catalog.json):
- Array of ModelProfile objects
- Required fields: id, engine, size, min_tier, port, sha256, repo_id, filename
- Optional: engine_flags, description

**Hardware Probe Contract** (lib/hardware.sh):
- Input: LLMCTL_FAKE_HW (optional fixture path)
- Output: JSON with cpu, ram, gpu, storage, tier

**Scheduler Contract** (lib/scheduler.sh):
- Input: requested profiles, current reservations
- Output: start/refuse decision, co-residency groups, budgets

**Service Unit Contract** (systemd/launchd):
- EnvironmentFile: profile.env
- MemoryHigh/MemoryMax from hardware probe
- Restart=always, StartLimitIntervalSec=0

**API Compatibility Contract**:
- llama.cpp: OpenAI-compatible /v1/chat/completions, /v1/models, /health
- colibri: OpenAI + Anthropic /v1/messages

### Quickstart Guide (quickstart.md)

Validation scenarios:
1. Fresh clone → setup → hardware probe → plan → download → start
2. Multi-model co-residency with auto
3. Service management (stop, switch, logs, restart)
4. CLI agent integration (opencode, aider, continue.dev examples)
5. Deterministic challenge verification

---

*End of Plan. Ready for Phase 0 Research.*
