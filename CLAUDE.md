# llmctl — CLAUDE.md

## INHERITED FROM constitution/CLAUDE.md

All rules in `constitution/CLAUDE.md` (and the `constitution/Constitution.md`
it references) apply unconditionally. Project-specific rules below
extend them — they do NOT weaken any universal clause. When this file
disagrees with the constitution submodule, the constitution wins.

@constitution/CLAUDE.md

---

## Project-Specific Rules for llmctl

### Purpose
Local LLM orchestration for Linux and macOS. llmctl probes your hardware,
plans which models fit, downloads them with cryptographic verification, builds
the inference engines from pinned source, and runs multiple models
concurrently with strict memory budgets — as systemd user services (Linux) or
launchd agents (macOS).

### Engines (vendored as git submodules, pinned to stable tags)
- [llama.cpp](https://github.com/ggml-org/llama.cpp) — GGUF models, OpenAI-compatible `llama-server`
- [colibri](https://github.com/JustVugg/colibri) — pure-C engines for very large MoE models memory-mapped from NVMe

### Safety Guarantees (extend Constitution §9, §11.4.10)
- **Verified downloads**: every file checksummed against sha256 from Hugging Face API
- **Smoke tests**: GGUF profiles booted in real `llama-server` and must answer deterministic prompt
- **Budget refusals**: scheduler never overcommits; refuses with exact numbers
- **OS-level protection**: systemd units carry `MemoryHigh`/`MemoryMax`, `Restart=always`
- **Local-only**: all servers bind to `127.0.0.1`

### Development Commands
```bash
make test       # deterministic test harness (fixtures, dry-run, local HTTP)
make lint       # shellcheck
make validate   # json-check + lint + test
make archive    # ../llmctl.tar.gz + ../llmctl.zip
```

See `docs/validation.md` for the V&V contract, `docs/integrations.md` for
wiring coding agents, and `docs/architecture.md` for the internals.

### Validation & Verification (per Constitution §11.4)
All changes MUST pass:
1. `make test` — deterministic test suite
2. `make lint` — shellcheck static analysis
3. `make validate` — combined validation gate
4. Constitution verification harness: `bash constitution/scripts/validation/run_verification.sh`
5. Meta-test mutation: `bash constitution/scripts/validation/meta_test_verification.sh`

No commit is valid without ALL gates passing.
