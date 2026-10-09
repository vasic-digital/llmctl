# llmctl

Local LLM orchestration for Linux and macOS. llmctl probes your hardware,
plans which models fit, downloads them with cryptographic verification, builds
the inference engines from pinned source, and runs multiple models
concurrently with strict memory budgets — as systemd user services (Linux) or
launchd agents (macOS).

Engines (llama.cpp and colibri vendored as git submodules, pinned to stable
tags; the `onnx` runner ships in-tree):

* [llama.cpp](https://github.com/ggml-org/llama.cpp) tag `b11379` (3.1.0 pin; it was `b10969`) — GGUF models,
  OpenAI-compatible `llama-server` (CUDA / ROCm / Metal / CPU backends).
* [colibri](https://github.com/JustVugg/colibri) `v1.11.0` — pure-C engines
  for very large MoE models memory-mapped from NVMe (no GPU required);
  OpenAI- and Anthropic-compatible API.
* `onnx` — a pure-python3 runner (`lib/onnx_server.py`, no build step, no
  submodule) for encoder-class decision models (NLI/sequence-classification
  ONNX exports such as the `decide-nli` profile); CPU-only inference via
  guarded optional pip deps (`onnxruntime`, `numpy`, `sentencepiece`,
  `tokenizers`). See `docs/decision-models.md`.

## Quickstart

### Recommended: one-command persistent install

```bash
git clone --recursive <this-repository-url> llmctl
cd llmctl
./scripts/install.sh      # setup -> download 'small' -> install -> enable
                           # -> verify reboot/logout survival -> status
```

This builds the engines, downloads the default `small` profile, writes and
enables its persistent service (systemd `--user` on Linux, launchd on
macOS), confirms the host is actually configured to survive logout/reboot
(and tells you exactly what to run if it isn't — it never guesses), and
prints final status. Install a different profile, or several, with
`--profile`:

```bash
./scripts/install.sh --profile fast --profile vision
```

See `docs/scripts/install.md` for every flag, idempotency guarantees on an
already-partially-installed host, and troubleshooting.

### Or do it manually (on-demand, no persistence)

```bash
git clone --recursive <this-repository-url> llmctl
cd llmctl
./bin/llmctl setup        # doctor -> build engines -> hardware plan
./bin/llmctl models download fast
./bin/llmctl start fast   # serves an OpenAI-compatible API on 127.0.0.1:8080
```

`start` runs the profile only for this session — it stops at logout/reboot.
For a service that survives logout/reboot, follow up with
`./bin/llmctl install` (writes the persistent-service templates) then
`./bin/llmctl enable fast` (enable + start persistently) — or just use
`./scripts/install.sh` above, which chains all of this for you.

Forgot `--recursive`? `git submodule update --init` or just run
`llmctl build all` (a target is required), which initializes the submodules itself.

> **Release 3.1.0** adds typed local decisions (`noul` / `choice` / `score`) behind a secured HTTPS gateway.
> What changed and what you must do when upgrading: [`CHANGELOG.md`](CHANGELOG.md) (migration table).
> What it does not do, and what was not verified live: [`docs/limitations.md`](docs/limitations.md).
> Building the decision binary needs Go >= 1.25; everything else still needs only bash, python3 and curl.
> Manual QA was waived by the operator on 2026-10-08 (the constitution gate is operator-waived, not satisfied); see [`docs/validation.md`](docs/validation.md).

### Supported platforms

| Platform | Status in 3.1.0 |
|---|---|
| Linux (systemd `--user`) | **Live-verified**: the development host, plus a second Linux machine (ALT Linux, CPU only) for portability runs |
| macOS (launchd) | Shipped, **verified statically only** (code read and fixture-tested; never run on a Mac) |
| Windows | **Unsupported** (no code path) |

What the verification did and did not cover: [`docs/limitations.md`](docs/limitations.md).

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
| `llmctl build <llama\|colibri\|onnx\|decide\|all>` | build engines (a target is required: a bare `llmctl build` prints usage; backend auto-detected; `onnx` creates the hash-locked private venv, `decide` builds the Go decision binary, `all` = all four) |
| `llmctl start <p> [more...]` | start profiles iff the combined footprint fits |
| `llmctl stop <p\|all>` | stop services |
| `llmctl switch <p>` | on-demand model switch: stop everything, start exactly one profile — atomic and safe (a failed switch auto-restores whatever was running before, never leaves the host with nothing running) |
| `llmctl auto <chat\|coder\|vision\|decide>...` | best set that fits *now*, LRU-evicting non-enabled services (`auto decide` picks the smallest fitting decision profile) |
| `llmctl decide <ask\|batch\|models\|capacity\|status\|interactive\|serve\|key\|cert\|registry\|port\|discover\|schema>` | typed decisions (noul/choice/score) against the local decision profiles + the Jev-shaped **HTTPS** gateway (port 8095, mandatory access key). `smoke`, `mcp` and `vantage` are subcommands of the `llmctl-decide` binary ([limitations](docs/limitations.md)) |
| `llmctl admit <hf-repo>` | run the candidate-model admission gates G1-G10 |
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
8087, colibri-glm 8090, colibri-qwen36 8091, decide-tiny 8092, decide 8093,
decide-pro 8094, decide-nli 8096, decide-2b 8098, decide-max 8097 and further
decision profiles listed in `docs/decision-models.md` (the
decide gateway, `llmctl decide serve`, listens on 8095). By default every
profile binds
to `0.0.0.0` (LAN-accessible) — see "Safety guarantees" below for the
security trade-off and how to lock a profile (or the whole host) back to
`127.0.0.1`.

## Hardware tiers

The planner classifies the host from the live probe (no hardcoded
assumptions): `below-minimum`, `baseline`, `workstation`, `datacenter`.
See `docs/hardware-tiers.md`. The baseline reference machine (Ryzen 7 2700X,
32 GB RAM, RTX 3060 12 GB, NVMe) runs `fast`, `coder`, `vision`, `moe-fast`,
`small` — including co-resident combinations. Workstations (64-core
Threadripper, 32 GB VRAM) unlock the `ws-*` profiles and full co-residency;
`colibri-glm` (a 744B MoE that streams weights from ~380 GB of NVMe) is gated
to `datacenter`. The catalog also carries **decision profiles** (capability `decide`) for typed
noul/choice/score decisions, from `decide-kev-08b` and the other native profiles (`decide-kev-08b`, `decide-kev-4b` and `decide-lev` verified live; `decide-julia` ran live but clears no baseline (G-140); `decide-kev-9b` only on the unpinned nezha snapshot, not on a commit-pinned tree), `decide-nli` (encoder; use it for `choice` - its `noul` and `score` output does not beat the majority baselines), and the letter-logit profiles (**per-profile status, anton CPU, 2026-10-09, with the thinking-mode fix**: `decide-2b` 128/132 well-formed and good on `noul`/`choice`, `decide-pro` 112/132 with HTTP 502 deadline expiries on a slow CPU engine (G-156), `decide` **not usable at its current `mass_threshold`** (G-157), `decide-max` **not exercised**; the earlier nezha numbers 0/132, 0/132 and 68/132 are PRE-fix, from an unpinned snapshot; see `docs/decision-models.md`); `decide-tiny` is catalogued but not servable yet. `decide-nli` is a DeBERTa-v3-large zero-shot NLI encoder on the `onnx` engine (any tier). The catalogue runs up to workstation-tier
profiles. The authoritative, current profile table (tiers, sizes, ports, source-labelled
benchmarks) is `docs/decision-models.md`.

## Safety guarantees

* **Verified downloads**: every file is checksummed against sha256 values
  captured from the Hugging Face API at catalog-generation time (or fetched
  live when a catalog entry is `null`). Mismatched content never lands at the
  final path — verification happens before the atomic rename. Evidence
  (command, exit code, output) is appended to
  `~/.local/state/llmctl/verify/<profile>.log`.
* **Smoke tests**: GGUF profiles are booted in a real `llama-server`
  (ctx 512, CPU layers only) and must answer the deterministic prompt
  "Reply with exactly: OK" before the download is accepted. Decision GGUF
  profiles are then asked fixed typed questions through the production Go driver
  (`llmctl decide smoke`: the answer must be a valid typed choice with finite
  probabilities, and the invoice-routing probe must pick `billing`). `onnx`-engine
  decision profiles are booted in the real `lib/onnx_server.py` encoder runtime and
  must pass entail / contradict / batch probes against its `/v1/score`; when the
  optional inference deps are missing the smoke test SKIPs with a recorded reason
  and the download is NOT reported as fully verified.
* **Budget refusals**: the scheduler never overcommits; it refuses with exact
  numbers and a suggested alternative.
* **OS-level protection**: systemd units carry `MemoryHigh`/`MemoryMax`
  computed from probed RAM, `Restart=always`, and a bounded restart budget
  (`StartLimitBurst=5` within `StartLimitIntervalSec=60`) so a permanently
  broken model fails visibly instead of crash-looping forever — `llmctl
  status` reports it as `failed (crash-loop)` with its last log line;
  launchd agents use `KeepAlive` + a widened `ThrottleInterval=60` (launchd
  has no native give-up-after-N-restarts primitive, so this bounds the
  restart *rate*, not the total attempts).
* **LAN-accessible by default, with an explicit trade-off**: every engine
  server binds to `0.0.0.0` by default, so any device on the local network
  can reach it (not just the host itself). **This has no built-in
  authentication** — llama-server's and colibri's OpenAI-compatible APIs
  accept unauthenticated requests from anyone who can reach the bound
  address, so on an untrusted or shared network segment (a coworking
  space, a guest Wi-Fi, a corporate LAN with unknown peers) this means
  anyone on that network can consume your GPU/model resources or read chat
  completions with zero auth. This is an intentional, explicit choice —
  llmctl is designed to be reachable from other devices you own on your
  own trusted LAN (a phone, a laptop, a second workstation) without extra
  setup. If your network is not fully trusted, scope reachability at your
  firewall/router (block the port from outside your LAN, or put the host
  on its own VLAN) or lock llmctl itself back to localhost-only:
  * `LLMCTL_BIND_HOST=127.0.0.1` (env var, before `start`/`enable`) reverts
    **every** profile to localhost-only.
  * `LLMCTL_BIND_HOST_<PROFILE>=127.0.0.1` (e.g. `LLMCTL_BIND_HOST_FAST`)
    reverts **just that profile** — the rest of the fleet stays
    LAN-accessible. Profile names are upper-cased with `-` → `_`
    (`ws-dense-32b` → `LLMCTL_BIND_HOST_WS_DENSE_32B`).

  Both are read at `start`/`enable`/`switch`/`auto` time (`lib/catalog.sh`'s
  `catalog_bind_host()`), so they take effect the next time a profile is
  (re)started — restart an already-running profile after setting either
  variable for it to apply. `lib/download.sh`'s one-shot model-verification
  smoke test is unaffected either way: it always uses a throwaway,
  localhost-only port during the download step, never reachable from the
  LAN.

  **`colibri-glm`/`colibri-qwen36` need one extra step for the LAN-accessible
  default to actually work.** The colibri engine has its own, independent
  fail-closed bind guard: it refuses to start on any non-loopback host
  unless it is given an API key or `COLI_ALLOW_INSECURE_BIND=1` is set in
  its environment — confirmed live: with neither set, `coli serve --host
  0.0.0.0 ...` prints `refusing to bind 0.0.0.0 beyond localhost without
  COLI_API_KEY set (set COLI_ALLOW_INSECURE_BIND=1 to override)` and exits
  immediately, which under `enable`/`install` shows up as a crash-loop.
  llmctl does **not** set this for you automatically — silently
  overriding a component's own explicit security control is a bigger,
  separate decision from choosing llmctl's own bind-host default, and it
  is yours to make, not llmctl's. To actually get a LAN-accessible colibri
  profile, add `Environment=COLI_ALLOW_INSECURE_BIND=1` to that unit
  (`systemctl --user edit llmctl-colibri@colibri-qwen36.service` on Linux)
  or export it before a manual `coli serve` invocation — or just leave
  that one profile on `LLMCTL_BIND_HOST_<PROFILE>=127.0.0.1`, which needs
  no such change.

## Credentials

Copy `.env.example` to `.env`, fill in real values, and lock it down:

```bash
cp .env.example .env
chmod 600 .env
```

`.env` is gitignored and never printed or logged (Constitution §11.4.10).
Single-host usage needs no credentials by default; `HF_TOKEN` is only
required for gated/private Hugging Face model repos, and the
`LLMCTLD_*` variables are only read when the opt-in cluster daemon
(`llmctld`, see `docs/cluster-architecture.md`) is enabled.

## Development

```bash
make test       # deterministic test harness (fixtures, dry-run, local HTTP)
make lint       # shellcheck (skipped with a message when not installed)
make validate   # json-check + lint + test
make archive    # ../llmctl.tar.gz + ../llmctl.zip
```

## Documentation

Every doc in this project is reachable from this table (Constitution
§11.4.212 — no orphan docs; `scripts/check_doc_reachability.sh` and `tests/test_doc_reachability.sh` enforce it). Start with the Quickstart above for the
fastest path to a running model.

| Doc | What it covers |
|---|---|
| [`docs/quickstart.md`](docs/quickstart.md) | Fresh-clone → setup → real model verification; the full release-gating live-challenge procedure for all 7 CLI agents |
| [`docs/tutorial.md`](docs/tutorial.md) | A narrative first walkthrough: clone → setup → download → start → use with one real CLI agent (aider) |
| [`docs/user-manual.md`](docs/user-manual.md) | Complete command reference for every `bin/llmctl` subcommand, including the opt-in `cluster`/`tenant`/`apikey` client commands |
| [`docs/faq.md`](docs/faq.md) | Every edge case from the spec, each labelled with what is wired into the code, what is a tested library only and what is not built (with source/test citations) |
| [`docs/integrations.md`](docs/integrations.md) | Per-agent config + install-verify scripts + normalization filters for all 7 CLI agents (opencode, pi, crush, Claude Code, aider, continue.dev, Cline) |
| [`docs/architecture.md`](docs/architecture.md) | Internals: layout, memory model, scheduler state machine, service backends, port map — with Mermaid diagrams |
| [`docs/cluster-architecture.md`](docs/cluster-architecture.md) | `llmctld`'s Raft/mTLS/JWT/WAL design, with an explicit ✅ implemented / 📋 open boundary per diagram |
| [`docs/api-reference.md`](docs/api-reference.md) | The real llama.cpp/colibri HTTP API every profile serves, plus `llmctld`'s implemented HTTP/3 control-plane API |
| [`docs/release-process.md`](docs/release-process.md) | The full GitHub+GitLab release procedure: dry-run, submodule preflight, archive build, idempotent per-forge retry |
| [`docs/ports.md`](docs/ports.md) | Every port llmctl uses (generated from the catalog), the `LLMCTL_PORT_<PROFILE>` override named in the port-conflict message, fixed versus dynamic assignment, collisions seen on a real host |
| [`docs/hardware-tiers.md`](docs/hardware-tiers.md) | The `below-minimum`/`baseline`/`workstation`/`datacenter` tier classification rules, plus decision-profile tiers and multi-instance capacity semantics |
| [`docs/decision-models.md`](docs/decision-models.md) | Decision models: concept, profile table (source-labeled benchmarks), the prompt/logprob mechanism, calibration, sha256 pinning, honest limitations |
| [`docs/cloud-exposure.md`](docs/cloud-exposure.md) | Exposing the HTTPS gateway beyond the LAN: VPN, SSH tunnel, port-forward, reverse proxy, tunnel services, with the security consequences stated |
| [`docs/runbooks.md`](docs/runbooks.md) | Operations: key rotation (and its environment-key caveat), certificate renew/reload, stuck engines, port conflicts, registry reconcile, vantage image, release archive, stale units, LD_LIBRARY_PATH, backup/restore, upgrade/rollback |
| [`docs/limitations.md`](docs/limitations.md) | Honest limits: not a safety guardrail, no calibration claim, option-order sensitivity, determinism scope, what was and was not verified live |
| [`docs/calibration-tool-fields.md`](docs/calibration-tool-fields.md) | Response fields a calibration or evaluation tool may rely on, and the (limited) stability statement |
| [`docs/glossary.md`](docs/glossary.md) | Terms used across the decision documentation |
| [`docs/related-tools.md`](docs/related-tools.md) | Third-party tools with similar names, and how they relate (or do not) to llmctl |
| [`docs/golden-set.md`](docs/golden-set.md) | The golden question set and its statistics tooling (labels agent-authored, human review pending) |
| [`docs/agents/README.md`](docs/agents/README.md) | Coding-agent kit for decision calls: hooks, router, MCP, per-agent pages (opencode, pi, crush, Claude Code, aider, Continue, Cline) |
| [`docs/llmctld-cluster-tls.md`](docs/llmctld-cluster-tls.md) | TLS and client-certificate notes for the `llmctld` cluster CLI |
| [`docs/scripts/README.md`](docs/scripts/README.md) | Index of the per-script and per-test documentation pages |
| [`docs/qa/README.md`](docs/qa/README.md) | Index of the captured QA evidence directories |
| [`docs/decide-gateway.md`](docs/decide-gateway.md) | The `llmctl decide serve` Go HTTPS gateway reference: `/v1/systemone`, `/v1/models`, `/healthz`, TypeSafe SDK setup, auth, truncation, concurrency, token-usage honesty |
| [`docs/tls-and-keys.md`](docs/tls-and-keys.md) | Security notes for the decision gateway: access-key strength, rotation and revocation, certificate and key-file checks, the placement guard, connection admission limits, the loopback-engine port-squatting caveat |
| [`docs/registry-discovery.md`](docs/registry-discovery.md) | Dynamic ports (per-user ranges, all-address bind test), the service registry, TLS-aware health, and how the decision gateway discovers engines through the registry |
| [`docs/scripts/decide.md`](docs/scripts/decide.md) | Per-lib internals of `lib/decide.sh` (typed-decision path, engine dispatch, wizard, capacity/status, serve lifecycle) |
| [`docs/scripts/onnx_server.md`](docs/scripts/onnx_server.md) | Per-lib internals of `lib/onnx_server.py` (the `onnx` engine runner for encoder-class decision models) |
| [`docs/scripts/test_decide.md`](docs/scripts/test_decide.md), [`docs/scripts/test_decide_download.md`](docs/scripts/test_decide_download.md), [`docs/scripts/test_regression_defects.md`](docs/scripts/test_regression_defects.md) | Per-test docs for the decision-model test suites (71 / 14 / 37 captured passing assertions) |
| [`docs/scripts/test_onnx_server.md`](docs/scripts/test_onnx_server.md), [`docs/scripts/test_onnx_download.md`](docs/scripts/test_onnx_download.md) | Per-test docs for the two `onnx`-engine test suites (27 / 27 passing assertions, measured with `scripts/doc_counts.sh`) |
| [`docs/research/README.md`](docs/research/README.md) | Index of the decision-models research briefs (Jev ecosystem survey, verified HF hashes, encoder-model hashes, implementation architecture map) |
| [`docs/qa/decision-models-validation/README.md`](docs/qa/decision-models-validation/README.md) | Captured evidence for the decision-models feature's validation runs (iteration 1: 34 PASS / 7 pre-existing environment FAIL; iteration 2: 36 PASS / 7 environment FAIL) |
| [`docs/validation.md`](docs/validation.md) | The project's V&V (validation & verification) contract |
| [`docs/host-safety.md`](docs/host-safety.md) | Host-hang safeguards after the 2026-10-08 incident: cgroup limits, `bounded-run`, the memory-pressure guard, and the root-only steps |
| [`docs/validation_and_verification.md`](docs/validation_and_verification.md) | Why fully-deterministic V&V matters for CLI-agent-driven development |
| [`docs/CONTINUATION.md`](docs/CONTINUATION.md) | Live session-resumption state: current phase, next action, per-phase findings (Constitution §12.10) |
| [`docs/commit-fully-integration.md`](docs/commit-fully-integration.md) | The `commit-fully` tooling integration |
| [`docs/llmctl_plan.md`](docs/llmctl_plan.md) | The original build plan this project was delivered against |
| [`docs/llmctl_initial_request.md`](docs/llmctl_initial_request.md) | The original project request/scoping exploration |
| [`docs/llmctl_progress_status.md`](docs/llmctl_progress_status.md) | A point-in-time build-progress snapshot from an earlier session |
| [`specs/001-llmctl-completion/spec.md`](specs/001-llmctl-completion/spec.md) | The current feature spec (functional requirements, success criteria, clarifications, edge cases) |
| [`specs/001-llmctl-completion/tasks.md`](specs/001-llmctl-completion/tasks.md) | The phased task breakdown this spec is being executed against |
| [`docs/qa/phase12-final-validation/README.md`](docs/qa/phase12-final-validation/README.md) | Captured evidence (Constitution §11.4.83) for Phase 12's final combined bash + Go test-suite run (T079) |
| [`docs/testing/TEST_TYPE_CLASSIFICATION.md`](docs/testing/TEST_TYPE_CLASSIFICATION.md) | The honest, evidence-cited classification of this project (llmctl/llmctld/claude_toolkit) against the Constitution's 14-class test-type taxonomy — COVERED/PARTIAL/GENUINELY-INAPPLICABLE per class per component |
| [`docs/testing/BENCHMARK_BASELINE.md`](docs/testing/BENCHMARK_BASELINE.md) | `llmctld`'s consolidated benchmark suite (`make bench-all`) and its documented, real-run baseline + acceptable-variance |

## License

MIT (see `LICENSE`).
