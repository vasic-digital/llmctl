# Glossary

**Revision:** 1 - 2026-10-08.

| Term | Meaning in llmctl |
|---|---|
| **Profile** | One catalog entry in `models/catalog.json`: a model, its engine, port, memory footprint and (for decision profiles) a `decision` block. Listed by `llmctl models list`; table in [decision-models](decision-models.md) |
| **Engine** | The program that runs a model: `llama` (llama.cpp `llama-server`), `colibri` (pure-C MoE engine), `onnx` (in-tree python3 encoder runtime `lib/onnx_server.py`) |
| **Decision profile / decision model** | A profile with capability `decide`: a small model used to answer typed questions with probabilities, not to chat |
| **Typed question** | A question with a declared answer type: `noul` (yes/no), `choice` (one of N named options), `score` (an ordered level) |
| **noul** | The wire name of the yes/no type (kept verbatim from the hosted API); answer = yes-probability |
| **State** | The text (or JSON) the question is about; sent as data, never as a command-line argument |
| **Criteria** | The option descriptions of a `choice` (`{key: description}`) or the ordered level descriptions of a `score` |
| **Confidence** | `(n*p_max - 1)/(n-1)`: 1.0 when one option holds all the probability, 0.0 at uniform. A shaping convention, not the probability of being right |
| **Abstain** | A client-side refusal to use a low-confidence answer: `--min-confidence X` exits 10 and still prints the JSON |
| **Gateway** | `llmctl decide serve`: the HTTPS service (default port 8095) exposing `POST /v1/systemone`, `GET /v1/models`, `/healthz`, `/readyz`, `/metrics` |
| **Protocol** (`decision.protocol`) | How the gateway talks to an engine: `letter-logit`, `nli-onnx`, `systemone-native` |
| **Letter-logit** | The decoder mechanism: options are lettered A, B, C...; the engine is asked for ONE token with first-token log-probabilities, and the option-letter probabilities are read and renormalised |
| **Readout** | The step that turns engine output into option probabilities (`internal/readout`) |
| **`option_missing` / upper bound** | A flag: an option letter was not in the engine's listed top tokens; its probability is reported as an upper bound and the answer is the conservative worst case |
| **NLI / encoder** | Natural-language inference: one premise (the state) / hypothesis (an option) pair is scored per option by the `decide-nli` encoder |
| **Access key** | The one secret clients present as `Authorization: Bearer ...` (`LLMCTL_API_KEY`). Distinct from the internal engine key |
| **Internal key** | A separate per-profile/instance key (0600 file) the gateway presents to loopback engines; never in env or argv |
| **CA / leaf** | The local certificate authority and the server certificate it signs, under `$LLMCTL_HOME/cert`; clients trust the CA file only |
| **SAN** | Subject Alternative Name: the host names/IPs a certificate is valid for; extended with `LLMCTL_TLS_SAN` |
| **Placement guard** | The check that refuses to create secrets inside a git working tree that git does not ignore |
| **Registry** | The per-user service registry (`$LLMCTL_STATE_DIR/registry/`): which services run on which port, with health |
| **Reconcile** | Verify registry rows against real processes and health and drop dead ones (`registry reconcile`, also an in-gateway loop) |
| **Dynamic ports** | `LLMCTL_PORT_STRATEGY=dynamic`: bind-tested ports from a per-user range instead of fixed documented ports |
| **Deterministic mode** | Default gateway mode: fixed seed, one slot per instance, byte-identical answers per instance and device placement. The opposite is `throughput` |
| **Instance** | One running copy of a profile's engine; `decide capacity` reports how many would fit |
| **Admission / budget refusal** | The scheduler refuses to start profiles whose footprint exceeds the live RAM/VRAM budget and prints the numbers |
| **Hardware tier** | `below-minimum`, `baseline`, `workstation`, `datacenter`; classifies the host from the live probe ([hardware-tiers](hardware-tiers.md)) |
| **Golden set** | The 132 labelled questions + 23 probes used to measure a profile ([golden-set](golden-set.md)); labels are agent-authored, human review pending |
| **Probe** | A deliberately adversarial golden-set item (forged options, injection, arithmetic, dates, double negatives, irrelevant state) |
| **Admission gates (G1-G10)** | `llmctl admit`: mechanical checks a candidate model must pass before it may join the catalog |
| **Vantage** | A rootless container with its own network namespace used to probe the gateway "from outside" (`vantage`) |
| **Containers submodule** | `submodules/containers` (vasic-digital/Containers): rootless container runtime library |
| **Agent kit** | Hooks, router and question templates (`templates/agents/`, `scripts/install_agents.sh`) that let coding agents make decision calls ([agents](agents/README.md)) |
| **MCP** | Model Context Protocol; `llmctl-decide mcp` exposes one tool, `decide`, over stdio |
| **Pin** | An exact version/hash fixed in the repository: engine submodule tags, model sha256 in the catalog, `scripts/agents.lock`, the hash-locked onnx requirements |
| **Gap register** | `specs/009-jev-decision-models/evidence/gaps-register.md`: every known gap with status; the source of the open items in [limitations](limitations.md) |
