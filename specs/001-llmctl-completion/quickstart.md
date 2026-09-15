# Quickstart Validation Guide: llmctl Full Production Completion

**Feature**: 001-llmctl-completion
**Date**: 2025-09-15
**Status**: Complete

---

## Prerequisites

- Linux (systemd --user) or macOS (launchd)
- Bash 4.4+, Python 3.8+
- Git with submodule support
- Network access to Hugging Face API
- Minimum hardware: 8 cores, 32GB RAM, 12GB VRAM (baseline tier)

---

## Validation Scenario 1: Fresh Clone → Full Setup

**Objective**: Verify complete setup flow from clone to running model.

```bash
# 1. Clone with submodules
git clone --recursive <repo-url> llmctl
cd llmctl

# 2. Run setup (doctor → build engines → hardware plan)
./bin/llmctl setup

# Expected: 
# - Engines build (llama.cpp v0.4.0, colibri v1.11.0)
# - Hardware probe succeeds (tier classification)
# - Model catalog validated

# 3. Download a model profile
./bin/llmctl models download fast

# Expected:
# - Downloads with resumable curl
# - SHA256 verified against catalog
# - Smoke test passes (llama-server responds "OK")

# 4. Start the model
./bin/llmctl start fast

# Expected:
# - llama-server starts on port 8080
# - Health endpoint responds
# - Service managed by systemd/launchd

# 5. Verify API
curl -s http://127.0.0.1:8080/v1/models | jq .
curl -s -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"local","messages":[{"role":"user","content":"Reply with: OK"}],"temperature":0}' \
  | jq -r '.choices[0].message.content'
# Expected output: OK
```

**Success Criteria**: All commands exit 0, API returns expected response.

---

## Validation Scenario 2: Multi-Model Co-Residency

**Objective**: Verify scheduler computes co-residency and manages budgets.

```bash
# 1. Check hardware tier and budgets
./bin/llmctl hw --json
./bin/llmctl plan --json

# Expected: Shows tier, RAM/VRAM budgets, recommended profiles

# 2. Download multiple profiles
./bin/llmctl models download fast coder vision

# 3. Start multiple models (co-residency)
./bin/llmctl start fast coder vision

# Expected:
# - Scheduler computes combined footprint
# - All three start if budgets allow
# - Ports: 8080 (fast), 8081 (coder), 8082 (vision)

# 4. Test co-residency eviction
./bin/llmctl auto coder vision

# Expected:
# - LRU eviction of non-enabled services if needed
# - Enabled services never evicted

# 5. Test switch (always works)
./bin/llmctl switch coder

# Expected:
# - All services stopped
# - Only coder starts on port 8081
```

**Success Criteria**: Scheduler correctly computes footprints, respects budgets, evicts LRU non-enabled.

---

## Validation Scenario 3: Service Management

```bash
# 1. Check status
./bin/llmctl status

# Expected: Table with profile, status, port, PID, RAM/VRAM

# 2. View logs
./bin/llmctl logs fast

# Expected: llama-server output, health checks

# 3. Stop service
./bin/llmctl stop fast

# Expected: Service stopped, reservation released

# 4. Restart
./bin/llmctl restart fast

# Expected: Service restarts, same port

# 5. Enable autostart
./bin/llmctl enable fast
./bin/llmctl disable fast

# Expected: systemd/launchd enabled/disabled
```

---

## Validation Scenario 4: Deterministic Test Suite

```bash
# 1. Run full test suite
make test

# Expected: All tests pass, deterministic output

# 2. Run with hardware fixture
LLMCTL_FAKE_HW=tests/fixtures/hw-baseline.json ./bin/llmctl hw --json
# Expected: Output matches fixture exactly

# 3. Dry-run service actions
LLMCTL_DRY_RUN=1 ./bin/llmctl start fast

# Expected: Unit/plist generated but not executed

# 4. Local HTTP test (download)
LLMCTL_HF_BASE=http://localhost:8000 ./bin/llmctl models download fast
# Expected: Uses local server, sha256 verified
```

**Expected**: All tests pass, deterministic output, exit codes captured.

---

## Validation Scenario 5: Constitution Verification

```bash
# 1. Run Constitution verification harness
bash constitution/scripts/validation/run_verification.sh

# Expected: 17/17 submodules verified, required submodules check passes

# 2. Run meta-test mutations
bash constitution/scripts/validation/meta_test_verification.sh

# Expected: Both mutations caught (missing submodule + corrupted logic)

# 3. Inheritance verification
bash tests/test_constitution_inheritance.sh

# Expected: 10/10 invariants pass
```

---

## Validation Scenario 6: CLI Agent Integration

```bash
# 1. Start a model (e.g., coder on port 8081)
./bin/llmctl start coder

# 2. Test each agent (configure first per docs/integrations.md)

# opencode
opencode run "Reply with: OK" --model llmctl/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf

# aider
aider --model openai/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf --message "Reply with: OK" --yes

# crush
crush run "Reply with: OK" --model llmctl/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf

# pi
pi run "Reply with: OK" --model llmctl/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf

# aider
aider --model openai/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf --message "Reply with: OK" --yes

# continue.dev - configure in VS Code, test via chat

# Cline - configure in VS Code, test via chat

# Claude Code (requires colibri)
./bin/llmctl start colibri-qwen36
export ANTHROPIC_BASE_URL="http://127.0.0.1:8090"
export ANTHROPIC_AUTH_TOKEN="local"
claude -p "Reply with: OK"
```

**Expected**: Each agent completes the coding task using the local model.

---

## Validation Scenario 7: Deterministic Live Challenges

```bash
# 1. Start model with deterministic parameters
llama-server \
  --model <model.gguf> \
  --ctx-size 512 \
  --n-gpu-layers 0 \
  --seed 42 \
  --temp 0 \
  --top-k 1 \
  --threads 8 \
  --port 8080

# 2. Run deterministic challenge 3x
for i in 1 2 3; do
  curl -s -X POST http://127.0.0.1:8080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"local","messages":[{"role":"user","content":"Reply with exactly: OK"}],"temperature":0,"seed":42,"max_tokens":10}' \
    | jq -r '.choices[0].message.content'
done

# Expected: All 3 runs output exactly "OK"
```

---

## Validation Scenario 8: Release Artifact Verification

```bash
# 1. Build archives
make archive

# 2. Verify archive contents
tar -tzf ../llmctl.tar.gz | head -20
# Expected: .git/, bin/, lib/, models/, tests/, docs/, constitution/, submodules/

# 3. Full verification
bash verify-archive.sh ../llmctl.tar.gz

# Expected: All submodules present (including constitution's 17 nested)
```

---

## Validation Scenario 9: Release Automation

```bash
# 1. Create release (dry-run first)
./release.sh v1.0.0-rc.1 --dry-run

# 2. Actual release
./release.sh v1.0.0

# Expected:
# - GitHub release created with assets
# - GitLab release created with assets
# - Changelog generated (git-cliff)
# - Tags pushed to all upstreams
```

---

## Validation Scenario 10: Constitution Compliance

```bash
# 1. Full Constitution audit
bash constitution/scripts/validation/run_verification.sh
# 17/17 submodules verified

bash constitution/scripts/validation/meta_test_verification.sh
# Both mutations caught

bash tests/test_constitution_inheritance.sh
# 10/10 invariants pass

# 2. Documentation completeness
# Check: quickstart, tutorial, FAQ, user manual, API ref all exist
# Check: Mermaid diagrams in architecture.md, hardware-tiers.md

# 3. Live test with real models
# (Requires GPU hardware - run on baseline/workstation/datacenter tier)
```

---

## Troubleshooting

| Issue | Resolution |
|-------|------------|
| `llmctl setup` fails building engines | Check build dependencies (cmake, cuda/rocm/metal) |
| Model download fails sha256 | Clear cache: `rm -rf ~/.local/state/llmctl/models/<profile>` |
| Service won't start | Check logs: `llmctl logs <profile>`; check budgets with `llmctl plan` |
| Scheduler refuses start | Run `llmctl plan` to see budgets; try `llmctl switch <profile>` |
| CLI agent can't connect | Verify `baseURL` and port; check service status with `llmctl status` |
| Deterministic challenge fails | Ensure `--seed` and `--temp 0`; use CPU-only mode |

---

## Next Steps

After all validations pass:
1. Run `make validate` (json-check + lint + test)
2. Run Constitution verification harness
3. Run meta-test mutations
4. Create release with `./release.sh v1.0.0`
5. Verify release on GitHub and GitLab

---

*End of Quickstart Guide*
