# Related tools and names that are easy to confuse

**Revision:** 1 - 2026-10-08. Several third-party projects use "jev" in their names. They are **not** part of llmctl, llmctl does not ship, call or depend on them, and llmctl's own decision gateway
(`llmctl decide serve`, binary `llmctl-decide`) is a separate implementation. Existence and licence statements below come from the research notes
(`specs/009-jev-decision-models/research/web-candidate-models.md`, `jev-md-coverage-2.md`) and were checked against public registries at the time; **UNVERIFIED** means a name was seen in a source but not confirmed to exist.

| Name | What it is | Relation to llmctl |
|---|---|---|
| **llmctl decision gateway** (`llmctl decide`, `llmctl-decide`) | this project's Go HTTPS service that answers `POST /v1/systemone` from local models | the subject of [decide-gateway](decide-gateway.md) |
| **Hosted Jev API / TypeSafe SDKs** (`typesafe-sdk` on PyPI, `@typesafe-ai/sdk` on npm) | the vendor's hosted service and its official clients | llmctl speaks the same request/response wire shape so the SDKs can be pointed at it with `TYPESAFE_BASE_URL`; it is not a clone and not affiliated. Compatibility notes: [decide-gateway](decide-gateway.md) |
| **jev-gateway** (npm) / `jev-opencode` | described in a source as a gateway that runs OpenCode through a Jev endpoint; agents with their own `agent.build.model` bypass it | **UNVERIFIED**; unrelated to `llmctl decide serve`. Note the same bypass caveat applies to any gateway in front of OpenCode ([agents/opencode](agents/opencode.md)) |
| **local-jev** (`amithgc/local-jev`) | an MIT-licensed research harness over an NLI model and generic LLMs ("a research project, not a finished product"); no PyPI package found | prior art for the wire shape; its NLI model is the same public `cross-encoder/nli-deberta-v3-large` family llmctl can run as a user-supplied encoder. Not shipped by llmctl |
| **jev-compatible-local-decider** | named in a source as running on vLLM/SGLang | **UNVERIFIED**; vLLM/SGLang are not llmctl engines |
| **jevclient** (PyPI, unofficial) | an unofficial client library | exists; not used by llmctl |
| **typecastlm**, **kev**, **Verdict**, **Laya**, **Rizzo Flow**, other decision-model repositories | model weights or harnesses with their own licences and runtimes; several are non-commercial or need custom runtimes | evaluated for the catalog through the admission gates (`llmctl admit`); only the profiles listed in [decision-models](decision-models.md) ship. The rest are *user-only* (you may add them yourself) or rejected. Do not read their presence in the research notes as support |
| **llama.cpp `/v1/systemone`** | a native endpoint added upstream (first in tag b11379 for the pinned engine, together with a needed fix) | llmctl's `systemone-native` protocol can use it; the gateway still re-validates every answer through its own contract |
| **llmctld** | llmctl's own opt-in cluster daemon (Raft/mTLS) | unrelated to the decision gateway; see [cluster-architecture](cluster-architecture.md) |
| **Containers submodule** (`vasic-digital/Containers`) | rootless container runtime library llmctl uses for `vantage` and for registry/health/port primitives | a dependency, not a product you operate |

How to tell them apart in practice: llmctl's gateway is the process named `llmctl-decide serve`, listens on `8095` by default over HTTPS with a local CA, and its access key is `LLMCTL_API_KEY`.
Anything that asks you for `npm install -g jev-...` or a hosted account is a different tool.
