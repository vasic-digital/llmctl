# llmctl Constitution

## Core Principles

### I. Deterministic Validation & Verification (NON-NEGOTIABLE)
Every claim about behavior MUST be backed by a command, its exit code, and its raw output — captured either in the test harness output or in per-profile evidence logs. AI agents are probabilistic text generators; they can hallucinate success, skip edge cases, or misread output. Deterministic checks are objective: same code, same environment, same command → same result. This separates generation from verification, reduces self-preference bias, makes results reproducible and auditable, catches real failures early, enables safe autonomy, and makes failures actionable.

**Operative rule:** The bar for shipping is NOT "tests pass" but "users can use the feature." Every PASS MUST carry positive evidence captured during execution that the feature works for the end user. Metadata-only PASS, configuration-only PASS, "absence-of-error" PASS, and grep-based PASS without runtime evidence are critical defects.

### II. CLI-First Interface & Text I/O
Every library and subsystem exposes functionality via CLI. Text in/out protocol: stdin/args → stdout, errors → stderr. JSON output is supported via `--json` flags for machine parsing. Human-readable format is default. All diagnostic and evidence commands produce parseable output (exit codes, JSON, structured logs) that CI and review tooling can consume without LLM interpretation.

### III. Test-First with Anti-Bluff Gates (NON-NEGOTIABLE)
TDD is mandatory: Tests written → User approved → Tests fail → Then implement; Red-Green-Refactor cycle strictly enforced. Every gate (pre-build, post-build, runtime, meta-test) MUST be paired with a mutation proving the gate catches regressions (Constitution §1.1). A gate without a paired mutation is a bluff gate and is forbidden.

**Four-layer test coverage required for every change:**
1. Pre-build gate (syntax, static analysis, schema validation)
2. Post-build gate (binary verification, version checks)
3. Runtime test (real execution on target environment with captured evidence)
4. Meta-test paired mutation (mutate asserted condition → gate must FAIL)

### IV. Integration Testing & Real Environment Execution
Integration tests run on real hardware and OS targets (Linux + macOS). Fixtures provide deterministic hardware profiles (baseline, workstation, Apple Silicon, constrained). Service lifecycle tested via `LLMCTL_DRY_RUN=1` (unit/plist contents asserted exactly). No mocking at harness level — real subprocesses, real exit codes, real raw output.

Focus areas requiring integration tests:
- Hardware probe on live host + fixture override
- Planner tier classification + footprint computation + co-residency groups
- Download + verify + skip + mismatch rejection + evidence log
- Scheduler start/refuse/evict/protect/switch (dry-run)
- systemd unit + launchd plist contents + memory limits from probe

### V. Anti-Bluff Covenant — End-User Quality Guarantee
Forensic anchor — verbatim user mandate (2026-04-28):
> "We had been in position that all tests do execute with success and all Challenges as well, but in reality the most of the features does not work and can't be used! This MUST NOT be the case and execution of tests and Challenges MUST guarantee the quality, the completion and full usability by end users of the product!"

This is the historical origin of the project's anti-bluff covenant. Every test, every Challenge, every gate, every mutation pair exists to make the failure mode (PASS on broken-for-end-user feature) mechanically impossible.

**Canonical authority:** `constitution/Constitution.md` §11.4 and its sub-sections §11.4.1 through §11.4.16. Non-compliance is a release blocker regardless of context.

**Key anti-bluff mandates:**
- **§11.4.1 FAIL-bluffs equally forbidden:** Script-internal crashes producing FAIL are as misleading as PASS-bluffs. Every test MUST fail ONLY for genuine product defects.
- **§11.4.2 Recorded-evidence requirement:** PASS without captured visual/audio evidence of user-visible feature working is a §11.4 PASS-bluff.
- **§11.4.3 Per-environment-topology test dispatch:** Tests MUST detect topology at entry and dispatch appropriate variant. SKIP-with-reason is correct fallback; PASS-by-default forbidden.
- **§11.4.4 Test-interrupt-on-discovery + retest-from-clean-baseline:** Moment any defect is re-discovered, cycle MUST stop → systematic debugging → fix at root cause → four-layer test coverage → full rebuild → re-deploy on every target → full retest from beginning.
- **§11.4.6 No-guessing mandate:** `likely`, `probably`, `maybe`, `might`, `appears`, `seems` forbidden when reporting causes. Use captured evidence or mark `UNCONFIRMED:`.
- **§11.4.7 Demotion-evidence rule:** Downgrading a defect requires captured evidence it no longer reproduces.

### VI. Absolute Codebase & Data Safety — Zero Risk (Constitution §9)
- **Hardlinked backup before any destructive op:** `cp -al .git <backup>/repo.git.mirror` is near-instant and uses zero additional disk. Zero excuse.
- **Force-push requires explicit per-session human authorization** AND a green post-op gate (§9.2).
- **Commit-message audit trail for history rewrites** (§9.4).
- **Credentials NEVER tracked** (§11.4.10): `.env` patterns git-ignored; runtime-load only; per-service file separation. Pre-store leak audit (§11.4.10.A) — before storing operator-provided credentials, grep entire tracked tree AND git history for the literal value(s); surface any findings to operator before storing.

### VII. Host-Session Safety (Constitution §12)
- Abort if pre-flight check fails; wrap heavy work in bounded execution scopes.
- **Memory-Budget Ceiling — 60% MAXIMUM** (§12.6): Never exceed 60% of host RAM.
- **CONTINUATION.md kept in sync** (§12.10): Every non-trivial state change updates the continuation document in the same commit.
- Required safeguards for heavy scripts: timeout bounds, resource limits, no unbounded loops.

### VIII. Submodule Governance (Constitution §3, §4, §11.4.28)
- Submodules are equal codebases with decoupled dependencies (helix-deps.yaml).
- Submodule changes propagate through submodule commits FIRST.
- Every tag on main repo MUST be mirrored on every owned submodule.
- All submodules inherit from Helix Constitution (CLAUDE.md/AGENTS.md inheritance pointers mandatory).

### IX. Documentation Up to Nano-Details (Constitution §6, §11.4.11, §11.4.12)
- File-layout discipline: every file has a declared purpose.
- Auto-generated docs sync mandate: generated docs regenerated from source-of-truth in same commit.
- README.md is canonical entry point — all docs reachable/linked from main README (no orphan docs).

### X. Changelog Discipline & Multi-Format Export (Constitution §5)
- Every change reflected in CHANGELOG.md with conventional commit prefixes.
- Multi-format export (MD, HTML, PDF, DOCX) for governance visibility.

## Technology Stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| CLI Entrypoint | Bash (bin/llmctl) | Dispatcher for all subcommands |
| Common Library | Bash (lib/common.sh) | Logging, colors, XDG paths, JSON helpers (python3) |
| OS Detection | Bash (lib/os_detect.sh) | Linux/macOS, arch, nproc, package-manager hints |
| Hardware Probe | Bash (lib/hardware.sh) | Dynamic: CPU/SIMD, RAM, GPUs (CUDA/ROCm/Metal), VRAM, storage type |
| Model Catalog | Bash + JSON (lib/catalog.sh, models/catalog.json) | Catalog queries, hardware planner, real sha256 + byte sizes (HF API-sourced) |
| Download Engine | Bash (lib/download.sh) | Resumable, checksummed downloads + smoke tests + evidence |
| Engine Builder | Bash (lib/engine.sh) | llama.cpp / colibri builds from pinned submodules |
| Scheduler | Bash (lib/scheduler.sh) | Co-residency, switching, auto (LRU eviction), VRAM/RAM budgets |
| Service Linux | Bash (lib/service_linux.sh) | systemd --user template units + linger |
| Service macOS | Bash (lib/service_macos.sh) | launchd LaunchAgents |
| Doctor | Bash (lib/doctor.sh) | Environment self-diagnosis (PASS/WARN/FAIL + evidence) |
| Inference Engines | llama.cpp v0.4.0, colibri v1.11.0 | Git submodules (vendor/), pinned to stable tags |
| Test Harness | Bash (tests/run_tests.sh) | Deterministic: fixtures, dry-run, local HTTP, exact commands + exit codes + raw output |

## Development Workflow

This project follows **specification-driven development** using the superspec pipeline:

1. **Constitution** (`/speckit.constitution`): Establish and maintain these governance principles
2. **Specification** (`/speckit.specify`): Define feature requirements before any code is written
3. **Brainstorming** (`/speckit.superspec.brainstorm`): Challenge assumptions and discover edge cases
4. **Planning** (`/speckit.plan`): Design technical approach with constitution compliance check
5. **Task Decomposition** (`/speckit.superspec.tasks`): Break down into executable, trackable tasks
6. **Execution** (`/speckit.superspec.execute`): Implement with appropriate discipline (TDD, subagents)
7. **Review** (`/speckit.superspec.review`): Verify implementation against spec and constitution

### Workflow Rules
- No code is written before a spec is approved
- Every spec goes through at least one brainstorm session
- Implementation plans must pass a constitution compliance check
- Phase checkpoints require explicit human approval
- **Subagent-driven by default** (Constitution §11.4.20): Fresh implementer per task, brief files as single source of truth, two-stage review, capped fix loops.

### Hardware Tier Classification (Live Probe Only — No Hardcoded Assumptions)

| Tier | Rule |
|------|------|
| `datacenter` | cores ≥ 32 **and** RAM ≥ 96 GiB **and** free storage ≥ 400 GiB |
| `workstation` | cores ≥ 24 **or** RAM ≥ 64 GiB **or** total VRAM ≥ 20 GiB |
| `baseline` | cores ≥ 8 **and** RAM ≥ 32 GiB |
| `below-minimum` | anything smaller |

Profiles declare `min_tier` in `models/catalog.json`; planner recommends only when `tier(host) >= min_tier(profile)` AND footprint fits.

**Baseline reference (supported minimum):** Ryzen 7 2700X (8c) · 32 GB RAM · RTX 3060 12 GB · NVMe
- Budgets: RAM 25904 MiB (avail − 4 GiB) · VRAM 10444 MiB (12 GiB − 15%)
- Recommended: `fast`, `coder`, `vision`, `moe-fast`, `small`
- Co-residency: `fast + coder + vision` together, or `moe-fast + small` together

**Workstation:** 64-core Threadripper · 256 GB RAM · 32 GB VRAM · 2 TB NVMe (qualifies as `datacenter`)
- All GGUF models run fully GPU-offloaded
- Co-residency spans: `fast + coder`, `vision + vision-pro`, `ws-moe-30b + colibri-*`

**Apple Silicon (M4 Max, 64 GB unified):** Classifies as `workstation`
- VRAM estimated as 0.7 × unified RAM (matching Metal's working-set limit)
- Everything except `colibri-glm` recommended

**Datacenter-only:** `colibri-glm` (GLM-5.2, 744B MoE, ~429 GB weights from NVMe)
- Needs ~16–24 GB RAM working set + ~380 GB fast storage
- Gate exists so planners on ordinary machines never propose 400 GB download

### Memory Model (Planner — Deliberately Simple & Conservative)
- RAM budget = `MemAvailable − 4 GiB` headroom
- VRAM budget = `total VRAM × 0.85` (15% headroom)
- KV cache estimate = `ctx_tokens × parallel_slots / 8` MiB (conservative upper for f16 KV)
- GGUF profiles: two modes — `gpu` (full offload, ngl from catalog defaults, 2 GiB host RAM) when `model + KV ≤ VRAM budget`, else `cpu` (ngl 0) when `model + KV ≤ RAM budget`, else profile does not fit
- Colibri profiles: memory-map weights from NVMe — VRAM 0, RAM reservation 8 GiB (<100 GiB repos) or 24 GiB (larger), storage must fit repo +10%
- Co-residency groups: greedy bin-packing of recommended profiles (port order) against both budgets

## Quality Gates

### Testing Requirements
- [x] **Unit tests**: REQUIRED — bash -n on every shipped script, shebang + strict mode (`test_syntax.sh`)
- [x] **Integration tests**: REQUIRED — hardware probe, catalog validity, planner, download, scheduler, services (`test_*.sh`)
- [x] **Contract tests**: REQUIRED — catalog JSON validity, unique ports, required fields, real sha256s (`test_catalog_json.sh`)
- [x] **TDD discipline**: REQUIRED — all tasks marked `[TDD]` follow RED-GREEN-REFACTOR; meta-test paired mutation for every gate

### Review Requirements
- [x] **Code review**: REQUIRED — two reviewers (correctness/safety + requirements-compliance); fix subagent applies fixes with new commits; minimum 2 review-polish rounds
- [x] **Spec compliance**: REQUIRED — verify all acceptance scenarios pass (every user MUST mapped to implemented evidence)
- [x] **Security review**: REQUIRED — shell pitfalls, portability Linux+macOS, systemd/launchd unit correctness, no bluff claims in docs
- [x] **Performance review**: REQUIRED — footprint accuracy against fixtures, scheduler eviction correctness

### Deployment Gates
- [x] All tests pass (`make test`)
- [x] All review items resolved
- [x] Constitution compliance verified (`bash constitution/scripts/validation/run_verification.sh`)
- [x] Meta-test mutation passes (`bash constitution/scripts/validation/meta_test_verification.sh`)
- [x] Shellcheck clean (`make lint`)
- [x] JSON validation (`make validate`)
- [x] Architecture + hardware tiers + integrations docs in sync
- [x] All submodules have CLAUDE.md/AGENTS.md inheritance pointers

### Model Download Verification (Evidence-Backed)
`llmctl models download <profile>`:
1. Skips files that exist AND match catalog sha256
2. Downloads with `curl -L --continue-at -` (resumable) to `<file>.part`
3. Verifies size AND sha256 of `.part`; mismatch = hard failure, content never reaches final path
4. Atomically renames into place only after verification
5. GGUF profiles: boots real `llama-server` (`--ctx-size 512 --n-gpu-layers 0`), polls `/health`, sends deterministic prompt "Reply with exactly: OK" at temp 0, requires "OK" in response. Colibri: `coli doctor` or structural check.
6. Appends command + exit code + output evidence to `~/.local/state/llmctl/verify/<profile>.log`

Catalog checksums captured from HF API (`/api/models/<repo>?blobs=true`, `lfs.sha256`). Entries with null sha256 (non-LFS config) fetch live at download time; download fails hard if cannot be obtained.

## Safety Guarantees (Extend Constitution §9, §11.4.10)
- **Verified downloads**: Every file checksummed against sha256 from Hugging Face API
- **Smoke tests**: GGUF profiles booted in real `llama-server` and must answer deterministic prompt
- **Budget refusals**: Scheduler never overcommits; refuses with exact numbers + suggested alternative
- **OS-level protection**: systemd units carry `MemoryHigh`/`MemoryMax` from probed RAM, `Restart=always`, unbounded restarts (`StartLimitIntervalSec=0`); launchd agents use `KeepAlive` + `ThrottleInterval`
- **Local-only**: All servers bind to `127.0.0.1`

## Governance

This constitution extends the **Helix Universal Constitution** at `constitution/Constitution.md`. All clauses there apply unless explicitly overridden below with an explicit `Override §X.Y` section. The Helix Constitution is the source of truth for engineering discipline (test coverage, anti-bluff covenant, data safety, host safety, credentials handling, documentation discipline).

**Inheritance hierarchy:**
1. `constitution/Constitution.md` (Helix Universal Constitution) — highest authority
2. `constitution/CLAUDE.md` + `constitution/AGENTS.md` — agent-facing rule bindings
3. This file (llmctl Constitution) — project-specific extensions (never weaken universal clauses)
4. `AGENTS.md` + `CLAUDE.md` at project root — project-specific agent rules

**Amendment procedure:**
- Documented change rationale in commit message
- Updated related specs, plans, and docs in same commit
- Verification that core principles are not violated
- All gates pass (`make test`, `make lint`, `make validate`, constitution harness, meta-test)
- Submodule commits propagate first; tags mirrored

**Version**: 2.0.0 | **Ratified**: 2026-04-28 | **Last Amended**: 2026-09-14

---

## Appendix: Project-Specific Rules (from AGENTS.md / CLAUDE.md)

### Engines (vendored as git submodules, pinned to stable tags)
- [llama.cpp](https://github.com/ggml-org/llama.cpp) — GGUF models, OpenAI-compatible `llama-server` (CUDA / ROCm / Metal / CPU backends)
- [colibri](https://github.com/JustVugg/colibri) — pure-C engines for very large MoE models memory-mapped from NVMe (no GPU required); OpenAI- and Anthropic-compatible API

### Port Map (Fixed per profile — all bind to 127.0.0.1)
- 8080: fast
- 8081: coder
- 8082: vision
- 8083: vision-pro
- 8084: moe-fast
- 8085: small
- 8086: ws-dense-32b
- 8087: ws-moe-30b
- 8090: colibri-glm
- 8091: colibri-qwen36

### Development Commands
```bash
make test       # deterministic test harness (fixtures, dry-run, local HTTP)
make lint       # shellcheck static analysis
make validate   # json-check + lint + test
make archive    # ../llmctl.tar.gz + ../llmctl.zip
```

### Submodules (all inherit from Helix Constitution)
- `constitution/` — Helix Universal Constitution
- `submodules/superspec/` — SuperSpec
- `submodules/llama.cpp/` — llama.cpp engine
- `submodules/colibri/` — colibri engine

All submodules MUST have inheritance pointers in their CLAUDE.md/AGENTS.md files.

---

## Appendix: Validation & Verification Contract Summary (from docs/validation.md)

**Test Harness** (`tests/run_tests.sh` via `make test`):
1. Discovers `tests/test_*.sh`
2. For each: prints exact command (`bash <path>`), runs as real subprocess, captures exit code + full raw output, prints both
3. Builds summary table from actual exit codes; exits non-zero if any test failed

**Determinism seams:**
- `LLMCTL_FAKE_HW=<fixture.json>` — hardware probe returns fixture verbatim (fixtures: hw-baseline, hw-workstation, hw-apple, hw-constrained)
- `LLMCTL_DRY_RUN=1` — service actions printed instead of executed; state files still real
- `LLMCTL_HF_BASE=<url>` — download test serves fixture from local python HTTP server
- All state dirs relocatable (`LLMCTL_STATE_DIR` etc.) — tests run isolated in `mktemp` directory

**Covered by harness:**
- Syntax check (`test_syntax.sh`)
- Catalog JSON validity (`test_catalog_json.sh`)
- Hardware probe (`test_hardware_probe.sh`)
- Planner tiers/footprints/co-residency (`test_planner.sh`)
- Download + verify + mismatch rejection + evidence log (`test_download.sh`)
- Scheduler start/refuse/evict/protect/switch (`test_scheduler.sh`)
- systemd unit + launchd plist contents + memory limits (`test_services.sh`)
- CLI help/version/exit codes (`test_cli.sh`)

**NOT covered (honest boundaries):**
- No GPU in test sandbox (CUDA/ROCm/Metal build paths validated by code inspection + planner tests against fixtures)
- No systemd/launchd in sandbox (service lifecycle via `LLMCTL_DRY_RUN=1`; contents asserted exactly)
- Engine compilation not run in CI (no toolchain weight budget)
- Smoke test requires multi-GB model (exercised in harness only in disabled form `LLMCTL_SMOKE=0`)
- Model quality/perplexity out of scope (verification = integrity + "serves deterministic completion")
