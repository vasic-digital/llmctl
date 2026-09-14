# llmctl

Local LLM orchestration for Linux and macOS. llmctl probes your hardware,
plans which models fit, downloads them with cryptographic verification, builds
the inference engines from pinned source, and runs multiple models
concurrently with strict memory budgets — as systemd user services (Linux) or
launchd agents (macOS).

Engines (vendored as git submodules, pinned to stable tags):

* [llama.cpp](https://github.com/ggml-org/llama.cpp) `v0.4.0` — GGUF models,
  OpenAI-compatible `llama-server` (CUDA / ROCm / Metal / CPU backends).
* [colibri](https://github.com/JustVugg/colibri) `v1.11.0` — pure-C engines
  for very large MoE models memory-mapped from NVMe (no GPU required);
  OpenAI- and Anthropic-compatible API.

## Quickstart

```bash
git clone --recursive <this-repository-url> llmctl
cd llmctl
./bin/llmctl setup        # doctor -> build engines -> hardware plan
./bin/llmctl models download fast
./bin/llmctl start fast   # serves an OpenAI-compatible API on 127.0.0.1:8080
```

Forgot `--recursive`? `git submodule update --init` or just run
`llmctl build`, which initializes the submodules itself.

## Command reference

| Command | What it does |
|---|---|
| `llmctl setup` | doctor checks, engine build, hardware plan |
| `llmctl doctor` | environment self-diagnosis (PASS/WARN/FAIL + evidence) |
| `llmctl hw [--json]` | dynamic hardware probe (CPU/SIMD, RAM, GPUs, storage type) |
| `llmctl plan [--json]` | which profiles fit, launch flags, co-residency groups |
| `llmctl models list` | catalog overview (port, engine, size, min-tier) |
| `llmctl models download <p>` | resumable download + sha256 verify + smoke test |
| `llmctl models verify <p>` | re-verify checksums of a downloaded profile |
| `llmctl build [llama\|colibri\|all]` | build engines (backend auto-detected) |
| `llmctl start <p> [more...]` | start profiles iff the combined footprint fits |
| `llmctl stop <p\|all>` | stop services |
| `llmctl switch <p>` | stop everything, start exactly one profile |
| `llmctl auto <chat\|coder\|vision>...` | best set that fits *now*, LRU-evicting non-enabled services |
| `llmctl status` / `logs <p>` | running services / log tail |
| `llmctl install` | install service templates (systemd units / launchd dir) |
| `llmctl enable/disable <p>` | autostart at login (linger enabled on Linux) |
| `llmctl restart <p>` | restart a service |

## Co-residency and switching

Every profile has a computed footprint (see `docs/architecture.md` for the
memory model). Reservations are tracked in `$XDG_STATE_HOME/llmctl/run/`.

* `llmctl start fast small coder` starts all three **only if** their combined
  RAM+VRAM reservations fit the live budgets (probed free memory minus 4 GiB
  RAM / 15% VRAM headroom, minus what already runs). Otherwise it refuses,
  names the alternative that *does* fit, and reminds you about `switch`.
* `llmctl auto coder vision` picks the best-ranked fitting profile per
  capability. If they don't fit alongside what is running, llmctl evicts
  **non-enabled** services in LRU order (oldest first) until they do. Enabled
  services are never evicted by `auto`.
* `llmctl switch <p>` is the always-works escape hatch: stop all, start one.

Ports are fixed per profile: fast 8080, coder 8081, vision 8082,
vision-pro 8083, moe-fast 8084, small 8085, ws-dense-32b 8086, ws-moe-30b
8087, colibri-glm 8090, colibri-qwen36 8091. All bind to `127.0.0.1`.

## Hardware tiers

The planner classifies the host from the live probe (no hardcoded
assumptions): `below-minimum`, `baseline`, `workstation`, `datacenter`.
See `docs/hardware-tiers.md`. The baseline reference machine (Ryzen 7 2700X,
32 GB RAM, RTX 3060 12 GB, NVMe) runs `fast`, `coder`, `vision`, `moe-fast`,
`small` — including co-resident combinations. Workstations (64-core
Threadripper, 32 GB VRAM) unlock the `ws-*` profiles and full co-residency;
`colibri-glm` (a 744B MoE that streams weights from ~380 GB of NVMe) is gated
to `datacenter`.

## Safety guarantees

* **Verified downloads**: every file is checksummed against sha256 values
  captured from the Hugging Face API at catalog-generation time (or fetched
  live when a catalog entry is `null`). Mismatched content never lands at the
  final path — verification happens before the atomic rename. Evidence
  (command, exit code, output) is appended to
  `~/.local/state/llmctl/verify/<profile>.log`.
* **Smoke tests**: GGUF profiles are booted in a real `llama-server`
  (ctx 512, CPU layers only) and must answer the deterministic prompt
  "Reply with exactly: OK" before the download is accepted.
* **Budget refusals**: the scheduler never overcommits; it refuses with exact
  numbers and a suggested alternative.
* **OS-level protection**: systemd units carry `MemoryHigh`/`MemoryMax`
  computed from probed RAM, `Restart=always`, and unbounded restart attempts
  (`StartLimitIntervalSec=0`); launchd agents use `KeepAlive` +
  `ThrottleInterval`.
* **Local-only**: all servers bind to `127.0.0.1`.

## Development

```bash
make test       # deterministic test harness (fixtures, dry-run, local HTTP)
make lint       # shellcheck (skipped with a message when not installed)
make validate   # json-check + lint + test
make archive    # ../llmctl.tar.gz + ../llmctl.zip
```

See `docs/validation.md` for the V&V contract, `docs/integrations.md` for
wiring coding agents (opencode, pi, crush, Claude Code, aider, continue.dev,
Cline) to the local endpoints, and `docs/architecture.md` for the internals.

## License

MIT (see `LICENSE`).
