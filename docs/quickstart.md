# Quickstart

**Revision:** 2
**Last modified:** 2026-09-15T00:00:00Z

This guide gets you from a fresh clone to a running, verified model server.
It is expanded with co-residency, CLI-agent integration, and deterministic
challenge sections as those features are documented (see `README.md`'s
Tracked-Items table for the full doc set).

## 1. Fresh clone → setup

```bash
git clone --recursive <this-repository-url> llmctl
cd llmctl
./bin/llmctl setup        # doctor -> build engines -> hardware plan
```

`setup` runs three phases in order, and each is independently inspectable:

1. **`llmctl doctor`** — environment self-diagnosis (required tools, the
   real pinned `submodules/llama.cpp` + `submodules/colibri` git submodules,
   model catalog validity, writable state directory). Every line is
   `PASS`/`WARN`/`FAIL` with the actual evidence inline (e.g.
   `PASS submodule submodules/llama.cpp initialized (3f152073d)`), never a
   bare claim.
2. **Engine build** — `llama.cpp` via `cmake`/`ctest` (backend
   auto-detected: CUDA / ROCm / Metal / CPU), `colibri` via `make`.
3. **Hardware plan** — a live probe (CPU/SIMD, RAM, GPU/VRAM, storage type)
   classified into a tier, then matched against `models/catalog.json` to
   show which profiles fit *this* host right now.

This entire sequence is covered by an automated end-to-end test
(`tests/test_setup_e2e.sh`) that runs the real `bin/llmctl setup` entrypoint
against a fresh-clone-structured temp directory with a deterministic
hardware fixture — it is part of `make test`, runs in well under a second,
and needs no network access or real compile (engine builds run in
`LLMCTL_DRY_RUN` mode for that automated path). It is a genuine
characterization of the orchestration, not a substitute for the real,
GPU-and-network-requiring verification below.

## 2. Manual release-gating verification: real model, real API

**This step requires real network access, a real multi-GB download, and (for
the GPU-accelerated path) real GPU hardware.** It is deliberately **not**
part of the automated `make test` suite — per the project's hybrid testing
approach (fixtures for CI determinism, real models for release gating), this
is the human-in-the-loop check that proves the fixture-based automated tests
correspond to genuinely working behavior for an end user, and it MUST be run
before every release (Constitution §11.4.185).

### 2.1 Download and start the `fast` profile

```bash
./bin/llmctl models download fast   # Llama 3.1 8B Instruct Q4_K_M, ~4.9 GB
                                     # resumable, sha256-verified, smoke-tested
./bin/llmctl start fast             # serves on 127.0.0.1:8080
```

Expected output from `start`: `started fast (mode=<cpu|gpu>, port=8080, reserved <N> MiB RAM + <N> MiB VRAM)`.
`mode` depends on your host's detected GPU (see `llmctl hw`).

### 2.2 Verify the server is live

```bash
curl -fsS http://127.0.0.1:8080/health
```

Expected: an HTTP 200 response (llama.cpp's built-in health endpoint).

### 2.3 Verify the OpenAI-compatible completion API with a real prompt

```bash
curl -fsS http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "messages": [{"role": "user", "content": "Reply with exactly: OK"}],
    "max_tokens": 8,
    "temperature": 0
  }'
```

Expected: a JSON response whose `choices[0].message.content` contains `OK`
(the same deterministic prompt the automated post-download smoke test uses
internally — see `lib/download.sh`'s `_dl_smoke_test_gguf`). This is the
positive, captured evidence required by Constitution §11.4/§11.4.5: a
metadata-only or config-only "it started" claim is not sufficient — the
model must actually answer.

### 2.4 Verify the model listing endpoint

```bash
curl -fsS http://127.0.0.1:8080/v1/models
```

Expected: a JSON object listing the loaded model, confirming the
OpenAI-compatible `/v1/models` surface is live (used by CLI agents that
enumerate available models before connecting — see `docs/integrations.md`).

### 2.5 Clean up

```bash
./bin/llmctl stop fast
```

### 2.6 Recording the result

Per Constitution §11.4.185 (manual QA as the mandatory final confirmation
before any release), capture the raw output of steps 2.2–2.4 (command, exit
code, response body) as the release's positive evidence — this is what
turns "the automated suite is green" into "a real user can use this
feature," which is the actual bar for shipping.

## 3. Next steps

- Multi-model co-residency (`llmctl auto <capability>...`, eviction/LRU
  behavior): see `README.md`'s "Co-residency and switching" section.
- CLI agent integration (opencode, aider, Claude Code, etc.): see
  `docs/integrations.md`.
- Persistent services (systemd --user / launchd, crash-loop bounding): see
  `README.md`'s "Safety guarantees" section.

## 4. Release-gating live-challenge procedure (all 7 CLI agents)

Per spec.md User Story 4 (FR-010/FR-011/FR-012/FR-047/FR-048, SC-007/SC-008),
every release MUST prove all 7 supported CLI agents (opencode, pi, crush,
Claude Code, aider, continue.dev, Cline) can complete a real coding task
against a real llmctl-served model, deterministically. **This entire section
requires real network access, a real multi-GB model download, and (for the
GPU-accelerated path) real GPU hardware — it is deliberately NOT part of the
automated `make test` suite**, per the same hybrid approach as §2 above:
fixtures give CI/CD determinism (Constitution §11.4.3); this procedure gives
the human-in-the-loop proof that real end users can actually use the
feature (Constitution §11.4.185).

### 4.1 Which steps are CI-fixture-based vs. real-model-required

| Step | Basis |
|---|---|
| Install-verify scripts exist, are syntactically valid, print real PASS/FAIL | **CI-fixture-capable** — `tests/test_syntax.sh` (`make test`) |
| `LLMCTL_SEED` appends `--seed`/`--temp 0` to a llama launch | **CI-fixture-capable** — `tests/test_scheduler.sh` §8 (`make test`) |
| Normalization filters strip timestamps/temp-paths/UUIDs/durations correctly | **CI-fixture-capable** — `tests/test_normalize_agents.sh` (`make test`), against synthetic fixtures |
| An agent is actually installed on this specific host | **Real-model-required** — `docs/integrations/install_<agent>.sh`, run manually, never by `make test` |
| An agent actually completes a real coding task against a real llmctl-served model | **Real-model-required** — §4.2 below |
| Two real runs of the same prompt through the same real agent produce byte-identical output after normalization | **Real-model-required** — §4.3 below |

### 4.2 Per-agent live challenge

For each of the 7 agents, repeat:

```bash
# 1. Install/verify the agent is present (see docs/integrations.md for the
#    exact command per agent; this is the one manual, deliberate step —
#    nothing in llmctl installs global tooling on your behalf).
bash docs/integrations/install_<agent>.sh

# 2. Start the target profile with a fixed seed for this challenge run
#    (US4 Acceptance Scenario 1/2/3 name specific profiles per agent -
#    e.g. `coder` for aider, `colibri-qwen36` for Claude Code, `fast` for
#    opencode's default coding task).
LLMCTL_SEED=42 ./bin/llmctl start <profile>

# 3. Configure the agent per its docs/integrations.md section, then drive
#    it through ONE fixed, deterministic coding prompt (e.g. "add a
#    one-line docstring to function foo in bar.py") and capture its FULL
#    output artifact (transcript, diff, or edited files) - not just the
#    raw model response (Clarification 17).

# 4. Clean up.
./bin/llmctl stop <profile>
```

Record, per agent: the exact prompt used, the profile/port, the captured
output artifact's location, and PASS/FAIL against "the agent completed the
coding task" (US4's actual acceptance bar — not merely "the agent
started").

### 4.3 Determinism proof (FR-047/FR-048/SC-008)

Repeat §4.2 steps 2–3 a SECOND time for the same agent with the exact same
prompt, then normalize and diff both captured artifacts:

```bash
bash docs/integrations/normalize_<agent>.sh < run1_raw_output.txt > run1_normalized.txt
bash docs/integrations/normalize_<agent>.sh < run2_raw_output.txt > run2_normalized.txt
diff run1_normalized.txt run2_normalized.txt   # empty diff = determinism proven for this agent
```

An empty diff is the positive evidence required by SC-008 at the full
CLI-agent-output layer (Clarification 17) — not merely that the raw model
API returned the same tokens. See `docs/integrations.md`'s "Live-challenge
determinism" section for what each filter strips and why, and its stated
honest boundary: the filters are proven correct against synthetic fixtures
in `make test`, but the live two-real-runs proof above is what this section
exists to require before a release ships.

### 4.4 Recording the result

Per Constitution §11.4.185, capture: per-agent PASS/FAIL from §4.2, the
empty-diff evidence from §4.3 (or the non-empty diff plus root-cause
analysis if determinism did not hold — Constitution §11.4.102 systematic
debugging applies before any filter is patched), and the exact commit/tag
this procedure was run against. This record is what SC-007 ("all 7 CLI
agents successfully configured and tested against running llmctl services")
and SC-008 cite as their evidence.
