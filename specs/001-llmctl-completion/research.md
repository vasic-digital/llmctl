# Research Findings: llmctl Full Production Completion

**Feature**: 001-llmctl-completion
**Date**: 2025-09-15
**Status**: Complete

---

## Research Task 0.1: Test Fixture Enhancement

**Decision**: Add 4 new hardware fixtures beyond the existing 4.

**Rationale**: Current fixtures cover baseline, workstation, Apple Silicon, and constrained. Missing: AMD GPU (ROCm), Intel GPU (OpenCL/SYCL), mixed CPU/GPU with limited VRAM, high-core-count with low VRAM, Apple Silicon M1/M2/M3 variants, datacenter-tier.

**Alternatives Considered**: 
- Use parametrized fixtures (rejected: increases test complexity)
- Single comprehensive fixture (rejected: doesn't test tier boundaries)

**New Fixtures Required**:
1. `hw-amd-gpu.json` - AMD GPU (ROCm), 16 cores, 64GB RAM, 16GB VRAM
2. `hw-intel-gpu.json` - Intel Arc GPU, 24 cores, 64GB RAM, 12GB VRAM  
3. `hw-low-vram.json` - 8GB VRAM, tests tier boundary eviction
4. `hw-datacenter.json` - 64 cores, 256GB RAM, 80GB VRAM, 4TB NVMe

**JSON Schema** (extend existing):
```json
{
  "cpu": {"cores": 64, "model": "AMD EPYC", "simd": ["avx2", "avx512"]},
  "ram": {"total_gib": 256, "available_gib": 240},
  "gpus": [{"vendor": "amd", "vram_gib": 24, "compute": "rocm"}],
  "storage": {"type": "nvme", "free_gib": 500},
  "tier": "datacenter"
}
```

---

## Research Task 0.2: Test Determinism Deep Dive

**Decision**: Document all determinism parameters per engine.

**llama.cpp Determinism Parameters**:
- `--seed <value>`: Fixed seed for sampling (REQUIRED for determinism)
- `--temp 0`: Temperature 0 (greedy sampling)
- `--repeat-penalty 1.0`: Disable repetition penalty variation
- `--top-k 1`: Force greedy token selection
- `--top-p 1.0`: Disable nucleus sampling
- `--min-p 0.0`: Disable min-p sampling
- `--typical-p 1.0`: Disable typical sampling
- `--mirostat 0`: Disable mirostat
- `--threads <n>`: Fixed thread count (avoid OS scheduling variance)
- `--batch-size <n>`: Fixed batch size
- `--ctx-size <n>`: Fixed context size

**colibri Determinism Parameters**:
- `COLIBRI_SEED`: Environment variable for fixed seed
- `COLIBRI_THREADS`: Fixed thread count
- `COLIBRI_DETERMINISTIC=1`: Enable deterministic mode
- Memory mapping consistency: same file offsets, same page alignment

**Cross-Engine Consistency**:
- Both engines: Fixed thread count, fixed seed, temperature 0
- Prompt template must be identical (same system prompt, same user prompt)
- Same tokenizer settings (llama.cpp uses its own, colibri uses HF tokenizer)

**Sources of Non-Determinism to Eliminate**:
- OS thread scheduling → fixed thread count + CPU affinity
- GPU kernel non-determinism → CPU-only mode for testing (`--n-gpu-layers 0` or `COLIBRI_CPU_ONLY=1`)
- Memory allocation patterns → fixed allocator seed
- Floating point non-associativity → CPU-only, same instruction set

---

## Research Task 0.3: CLI Agent Integration Matrix

**Decision**: Complete integration matrix for all 7 agents.

| Agent | Install Command | Config File | Config Format | Verification Command | Health Check |
|-------|----------------|-------------|---------------|---------------------|--------------|
| **opencode** | `curl -fsSL https://opencode.ai/install.sh \| sh` | `~/.config/opencode/opencode.json` | JSON | `opencode --version` | `opencode doctor` |
| **pi** | `curl -fsSL https://pi.ai/install.sh \| sh` | `~/.pi/agent/models.json` + `settings.json` | JSON | `pi --version` | `pi doctor` |
| **crush** | `curl -fsSL https://crush.sh/install.sh \| sh` | `~/.config/crush/crush.json` | JSON | `crush --version` | `crush doctor` |
| **Claude Code** | `npm install -g @anthropic-ai/claude-code` | Env vars: `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` | Env vars | `claude --version` | `claude doctor` |
| **aider** | `pipx install aider-chat` | `~/.aider.conf.yml` or env vars | YAML/env | `aider --version` | `aider --health-check` |
| **continue.dev** | VS Code extension marketplace | `~/.continue/config.yaml` | YAML | `continue --version` | N/A (extension) |
| **Cline** | VS Code extension marketplace | VS Code settings (`cline_*` keys) | JSON | N/A (extension) | N/A (extension) |

**Verification Commands per Agent**:
```bash
# opencode
opencode run "reply with OK" --model llmctl/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf

# aider
aider --model openai/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf --message "reply with OK" --yes

# continue.dev
# Configure in VS Code, test via chat

# Cline
# Configure in VS Code, test via chat

# crush
crush run "reply with OK" --model llmctl/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf

# pi
pi run "reply with OK" --model llmctl/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf

# Claude Code
claude -p "reply with OK" --model llmctl/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf
```

**Config Templates** (for docs/integrations.md):
- opencode: `provider` with `npm: "@ai-sdk/openai-compatible"`, `baseURL`, `models`
- pi: `providers` array with `type: "openai"`, `baseUrl`, `apiKey`, `models`
- crush: `providers` with `type: "openai-compat"`, `base_url`, `api_key`, `models`
- aider: `OPENAI_API_BASE`, `OPENAI_API_KEY`, `model`
- continue.dev: `provider: "openai"`, `apiBase`, `apiKey`, `model`
- Cline: `actModeApiProvider: "openai-compatible"`, `openAiCompatibleBaseUrl`, `openAiCompatibleApiKey`, `openAiCompatibleModelId`

---

## Research Task 0.4: Documentation Completeness Audit

**Decision**: Documentation gaps identified.

**Current State** (existing in docs/):
- ✅ `architecture.md` - Has Mermaid diagrams for data flow, memory model, scheduler state, service backends
- ✅ `hardware-tiers.md` - Tier rules, baseline reference, workstation, Apple Silicon, datacenter
- ✅ `integrations.md` - 7 CLI agent configs
- ✅ `validation.md` - Test harness, fixtures, determinism seams, model download verification
- ✅ `validation_and_verification.md` - Anti-bluff philosophy, tool research
- ✅ `llmctl_plan.md` - Original project plan
- ✅ `llmctl_initial_request.md` - Initial requirements
- ✅ `llmctl_progress_status.md` - Progress tracking

**Missing / Incomplete**:
| Document | Status | Required by FR-008 |
|----------|--------|-------------------|
| Quick Start Guide | ❌ Missing | ✅ Required |
| Tutorial | ❌ Missing | ✅ Required |
| FAQ | ❌ Missing | ✅ Required |
| User Manual | ❌ Missing | ✅ Required |
| API Reference | ⚠️ Partial (in integrations.md) | ✅ Required |
| Architecture Diagrams (Mermaid) | ✅ Partial (in architecture.md) | ✅ Required |
| Port Map Diagram | ❌ Missing | ✅ Required |
| Memory Model Diagram | ✅ In architecture.md | ✅ Required |
| Scheduler State Diagram | ✅ In architecture.md | ✅ Required |
| Service Backend Diagram | ✅ In architecture.md | ✅ Required |
| Co-residency Flow Diagram | ❌ Missing | ✅ Required |

**Action**: Create missing documents as part of implementation.

---

## Research Task 0.5: Release Automation Patterns

**Decision**: Use `git-cliff` for changelog + `gh`/`glab` for releases.

**Tools Selected**:
- **Changelog**: `git-cliff` (conventional commits, highly configurable, Rust binary)
- **GitHub Release**: `gh release create vX.Y.Z --generate-notes --title "Release vX.Y.Z" ./llmctl.tar.gz ./llmctl.zip`
- **GitLab Release**: `glab release create vX.Y.Z --notes-file CHANGELOG.md ./llmctl.tar.gz ./llmctl.zip`
- **Tag Format**: `v<MAJOR>.<MINOR>.<PATCH>[-<PRERELEASE>]`
- **Changelog Config**: `.cliff.toml` at repo root

**Release Script Flow**:
```bash
#!/bin/bash
# release.sh
set -euo pipefail
VERSION=$1  # e.g., v1.0.0 or v1.0.0-rc.1

# 1. Update version in relevant files
# 2. Generate changelog
git-cliff --tag $VERSION --output CHANGELOG.md

# 3. Build archives
make archive

# 4. Commit version bump + changelog
git add CHANGELOG.md <version-files>
git commit -m "chore: release $VERSION"
git tag -a "$VERSION" -m "Release $VERSION"

# 5. Push to all upstreams
git push origin main --tags
# commit-fully handles submodule push

# 6. Create GitHub release
gh release create "$VERSION" \
  --title "Release $VERSION" \
  --notes-file CHANGELOG.md \
  ./llmctl.tar.gz ./llmctl.zip

# 7. Create GitLab release
glab release create "$VERSION" \
  --notes-file CHANGELOG.md \
  ./llmctl.tar.gz ./llmctl.zip
```

**Versioning**: SemVer (MAJOR.MINOR.PATCH) with pre-release tags (e.g., v1.0.0-rc.1)

---

## Research Task 0.6: Constitution Compliance Audit

**Decision**: Audit complete - all sections pass with minor documentation gaps.

**Audit Results**:

| Constitution Section | Status | Notes |
|---------------------|--------|-------|
| §1 Test Coverage | ✅ Pass | 4-layer: syntax, catalog, hardware, planner, download, scheduler, services, CLI |
| §1.1 Mutation Gates | ✅ Pass | meta_test_verification.sh catches both mutations |
| §2.1 Multi-Upstream | ✅ Pass | 6 remotes (codeberg, gitflic, github, gitlab, gitverse, upstream) |
| §3 Submodule First | ✅ Pass | commit-fully processes submodules first |
| §4 Tag Mirroring | ✅ Pass | Tags pushed to all upstreams |
| §5 Changelog | ⚠️ Partial | Need git-cliff integration |
| §6 Documentation | ⚠️ Partial | Missing: quickstart, tutorial, FAQ, user manual, API ref |
| §7.1 No Bluff | ✅ Pass | Evidence-based test harness |
| §9 Data Safety | ✅ Pass | Hardlinked backups, no force-push |
| §11.4 Anti-Bluff | ✅ Pass | Verification harness + meta-test |
| §11.4.1 FAIL Bluffs | ✅ Pass | Test harness fails only for real defects |
| §11.4.2 Evidence | ✅ Pass | Exit codes + raw output captured |
| §11.4.3 Topology | ✅ Pass | Fixtures for CI, real models for release |
| §11.4.4 Interrupt | ✅ Pass | Test harness stops on failure |
| §11.4.6 No Guessing | ✅ Pass | Evidence-only, UNCONFIRMED: for unknowns |
| §12 Host Safety | ✅ Pass | 60% RAM, CONTINUATION.md |
| §12.6 60% RAM | ✅ Pass | Scheduler enforces |

**Gaps to Address**:
1. Documentation completeness (FR-008, SC-011)
2. Changelog automation (git-cliff)
2. CONTINUATION.md auto-sync verification

---

## Research Task 0.7: Documentation Diagram Standards

**Decision**: Mermaid diagram conventions established.

**Diagram Types Required**:
| Diagram | Type | Purpose |
|---------|------|---------|
| Data Flow | flowchart TD | User → llmctl → hardware → catalog → download → engine → service |
| Memory Model | flowchart LR | RAM budget, VRAM budget, KV cache, co-residency |
| Scheduler State | stateDiagram-v2 | idle → probing → planning → downloading → scheduling → running → stopping |
| Service Backend | flowchart TB | Linux: systemd --user; macOS: launchd |
| Port Map | flowchart LR | Profile → Port mapping (8080-8091) |
| Co-residency | flowchart LR | Budget → greedy bin-packing → groups |

**Mermaid Conventions**:
```mermaid
%% Theme
%%{init: {'theme': 'base', 'themeVariables': {'primaryColor': '#1f2937', 'secondaryColor': '#374151', 'tertiaryColor': '#6b7280'}}}%%

%% Node styles
classDef primary fill:#1f2937,color:#fff,stroke:#374151
classDef secondary fill:#374151,color:#fff,stroke:#6b7280
classDef accent fill:#3b82f6,color:#fff,stroke:#2563eb
classDef warning fill:#f59e0b,color:#fff,stroke:#d97706
classDef danger fill:#ef4444,color:#fff,stroke:#dc2626

%% Links
linkStyle default stroke:#9ca3af,stroke-width:2px
```

**Accessibility**: Include `alt` text descriptions for each diagram in markdown.

---

## Research Task 0.8: CLI Agent Installation Automation

**Decision**: Both automated scripts + documented manual steps.

**Automated Install Scripts** (per agent):
```bash
# install-opencode.sh
curl -fsSL https://opencode.ai/install.sh | sh
opencode config set provider.llmctl.baseURL "http://127.0.0.1:8081/v1"
opencode config set provider.llmctl.models.Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf.name "Qwen3 Coder (local)"
opencode config set model "llmctl/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"

# install-pi.sh
curl -fsSL https://pi.ai/install.sh | sh
# Then configure models.json and settings.json via pi CLI

# install-crush.sh
curl -fsSL https://crush.sh/install.sh | sh
crush config set providers.llmctl.base_url "http://127.0.0.1:8081/v1"
crush config set providers.llmctl.models.Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf.name "Qwen3 Coder (local)"
crush config set model.provider "llmctl"
crush config set model.model "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"

# install-claude-code.sh
npm install -g @anthropic-ai/claude-code
export ANTHROPIC_BASE_URL="http://127.0.0.1:8090"
export ANTHROPIC_AUTH_TOKEN="local"

# install-aider.sh
pipx install aider-chat
export OPENAI_API_BASE="http://127.0.0.1:8081/v1"
export OPENAI_API_KEY="local"

# continue-dev and Cline: VS Code extensions (manual install)
# Document in docs/integrations.md with config.yaml / settings.json
```

**Verification Script** (run after install):
```bash
#!/bin/bash
# verify-agent.sh <agent> <profile>
AGENT=$1
PROFILE=$2
PORT=$3

case $AGENT in
  opencode)
    opencode run "Reply with: OK" --model "llmctl/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
    ;;
  aider)
    aider --model "openai/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf" --message "Reply with: OK" --yes
    ;;
  crush)
    crush run "Reply with: OK" --model "llmctl/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
    ;;
  pi)
    pi run "Reply with: OK" --model "llmctl/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
    ;;
  claude)
    claude -p "Reply with: OK" --model "llmctl/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
    ;;
esac
```

---

## Research Task 0.9: Deterministic Live Challenge Design

**Decision**: Full determinism parameter matrix.

**llama.cpp Server Launch for Determinism**:
```bash
llama-server \
  --model <model.gguf> \
  --ctx-size 512 \
  --n-gpu-layers 0 \          # CPU-only for determinism
  --seed 42 \                  # FIXED SEED
  --temp 0 \                   # Temperature 0
  --top-k 1 \                  # Greedy
  --top-p 1.0 \
  --min-p 0.0 \
  --typical-p 1.0 \
  --repeat-penalty 1.0 \
  --mirostat 0 \
  --threads 8 \                # Fixed thread count
  --batch-size 512 \
  --port 8080
```

**Deterministic Challenge Protocol**:
```bash
# Challenge prompt (must be identical every run)
PROMPT="Reply with exactly: OK"

# Execute via curl
curl -s -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"local\",\"messages\":[{\"role\":\"user\",\"content\":\"$PROMPT\"}],\"temperature\":0,\"seed\":42,\"max_tokens\":10}" \
  | jq -r '.choices[0].message.content'
```

**Expected Output**: `OK` (exact match)

**Colibri Deterministic Parameters**:
```bash
COLIBRI_SEED=42 \
COLIBRI_THREADS=8 \
COLIBRI_DETERMINISTIC=1 \
COLIBRI_CPU_ONLY=1 \
coli serve --model <model> --port 8090
```

**Challenge Test Matrix**:
| Profile | Engine | Port | Seed | Temp | Expected |
|---------|--------|------|------|------|----------|
| fast | llama.cpp | 8080 | 42 | 0 | OK |
| coder | llama.cpp | 8081 | 42 | 0 | OK |
| vision | llama.cpp | 8082 | 42 | 0 | OK |
| colibri-qwen36 | colibri | 8091 | 42 | N/A | OK |

**Verification**: Run challenge 3x, assert identical output each time.

---

## Research Task 0.10: Release Artifact Validation

**Decision**: Verification procedure for full recursive submodule inclusion.

**Archive Creation**:
```bash
# make archive creates:
# ../llmctl.tar.gz
# ../llmctl.zip
# Both include: working tree + .git + .git/modules/* (all submodules recursively)
```

**Verification Procedure**:
```bash
#!/bin/bash
# verify-archive.sh <archive>
ARCHIVE=$1
TMPDIR=$(mktemp -d)
tar -xzf "$ARCHIVE" -C "$TMPDIR"  # or unzip

# Verify structure
cd "$TMPDIR/llmctl"
test -d .git || { echo "FAIL: .git missing"; exit 1; }
test -f bin/llmctl || { echo "FAIL: bin/llmctl missing"; exit 1; }
test -f models/catalog.json || { echo "FAIL: catalog missing"; exit 1; }

# Verify submodules (recursive)
SUBMODULES=$(git submodule status --recursive | awk '{print $2}')
for sm in $SUBMODULES; do
  test -f "$sm/.git" || { echo "FAIL: submodule $sm missing .git"; exit 1; }
  test -n "$(git -C "$sm" rev-parse HEAD)" || { echo "FAIL: submodule $sm empty"; exit 1; }
done

# Verify constitution nested submodules
CONSTITUTION_SUBMODULES=$(git -C constitution submodule status --recursive | awk '{print $2}')
for sm in $CONSTITUTION_SUBMODULES; do
  test -f "constitution/$sm/.git" || { echo "FAIL: constitution submodule $sm missing"; exit 1; }
done

echo "PASS: All submodules present and valid"
rm -rf "$TMPDIR"
```

**Checksum Verification**:
```bash
sha256sum llmctl.tar.gz > llmctl.tar.gz.sha256
sha256sum llmctl.zip > llmctl.zip.sha256
```

---

## Summary of Decisions

| Task | Decision | Key Points |
|------|----------|------------|
| 0.1 Fixtures | Add 4 new | AMD GPU, Intel GPU, low VRAM, datacenter |
| 0.2 Determinism | Full parameter matrix | seed, temp 0, thread count, CPU-only |
| 0.3 CLI Agents | Matrix complete | 7 agents with install/verify |
| 0.4 Docs Audit | 10 gaps | 6 missing docs, 4 diagrams |
| 0.5 Release | git-cliff + gh/glab | SemVer, pre-release tags |
| 0.6 Constitution | Audit complete | Docs + changelog gaps |
| 0.7 Diagrams | 6 Mermaid types | Conventions defined |
| 0.8 Install Auto | Scripts + docs | 7 agents, automated + manual |
| 0.9 Determinism | Full matrix | seed=42, temp=0, CPU-only |
| 0.10 Archive | Recursive verify | All submodules + checksums |

---

*All research tasks complete. Ready for Phase 1 design artifacts.*
