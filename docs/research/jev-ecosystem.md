# Research Brief: The "Jev" Decision-Model Ecosystem (TypeSafe AI "System One") and Open-Source Local Replications

**Compiled:** October 2026 · For: local-LLM orchestrator integration (llama.cpp/llama-server preferred)
**Verification labels:** [VERIFIED] = primary source (official docs/repo/model card) read directly · [SECONDARY] = reputable third-party coverage · [UNVERIFIED] = claim found but not independently confirmed · [VENDOR] = self-reported by the author/vendor

---

## 1. Official Jev (TypeSafe AI)

### 1.1 What it is
Jev is the first "System One" model from TypeSafe AI (founded by Diogo Almeida — ex-OpenAI RLHF/InstructGPT — Erik Gafni, Sasha Sheng; launched out of stealth 2026-09-15 with $40M seed). It **never generates text**: given `state` + typed `questions`, it returns typed decisions with probabilities from a single parallel pass. Training method: **RLCD** (Reinforcement Learning for Calibrated Decisions); trained exclusively on synthetic data; architecture/weights unpublished. Name references the Jevons paradox.
- Sources: https://typesafe.ai/ , https://www.hackerspot.net/p/what-is-jev-typesafe-ais-system-one [SECONDARY]

### 1.2 API wire format [VERIFIED]
**Endpoint (TypeSafe 1P):** `POST https://api.typesafe.ai/v1/systemone`
**Endpoint (OpenRouter):** `POST https://openrouter.ai/api/alpha/decisions` (also accepts TypeSafe format at `https://openrouter.ai/api/v1/systemone`)
Auth: `Authorization: Bearer <TYPESAFE_API_KEY>` (or OpenRouter key for the OR endpoints).

Request body: `{model, state, questions}` — `state` is a string or JSON object; `questions` is a map of name → question. **Question names are never sent to the model; all meaning must be in `instructions`/`criteria`.** [VERIFIED, TypeSafe API ref via https://github.com/can1357/oh-my-pi/issues/12458]

Three question primitives:

| Primitive | Request shape | Response shape |
|---|---|---|
| `noul` (yes/no) | `{"type":"noul","instructions":..., "criteria":{"true": "...", "false":"..."}}` (criteria optional on 1P; required-if-present on OpenRouter) | `{"type":"noul","noul": <0..1>}` — no separate confidence |
| `choice` | `{"type":"choice","instructions":..., "criteria": {"opt": "description", ...}}` — up to 255 options | `{"type":"choice","choice":"opt","probabilities":{...},"confidence":0..1}` |
| `score` | `{"type":"score","instructions":..., "criteria": ["level 0 desc", ...]}` — ordered, 2–10 levels | `{"type":"score","score": <probability-weighted level, e.g. 1.74>, "legend": {"0":"...","1":"..."}, "probabilities": {...}, "confidence": ...}` |

Full real response (OpenRouter, verified):
```json
{
  "model": "typesafe/jev-1.13-20260917",
  "answers": { "team": {"type":"choice","choice":"billing",
    "probabilities":{"technical":0,"account":0,"billing":1},"confidence":1} },
  "usage": {"input_tokens":357,"output_tokens":38,"cost":0.000014994},
  "id": "gen-dec-1790013975-...",
  "provider": "TypeSafe"
}
```
- Sources: https://openrouter.ai/blog/insights/what-is-jev/ [VERIFIED w/ real responses], https://openrouter.ai/docs/guides/community/jev-tutorial , https://jevaiguide.com/channels/

### 1.3 Model IDs
- TypeSafe 1P: `jev-1.13.0` (current), aliases `jev-latest`, `jev-preview` (both resolve to 1.13.0 as of 2026-09-21)
- OpenRouter: `typesafe/jev-1.13`, alias `~typesafe/jev-latest`; also `typesafe/jev-router` (1M-context chat router built on Jev). Note: Jev does **not** appear in `GET /api/v1/models` and cannot be called via `/api/v1/chat/completions`.
- Vercel AI Gateway: `typesafe-ai/jev`; Cloudflare Workers AI: `typesafe/jev`
- Sources: https://jevaiguide.com/channels/ [VERIFIED table], https://openrouter.ai/typesafe

### 1.4 Pricing, limits, rate limits
- **$0.042 per 1M input tokens; output tokens free** ("too cheap to meter"). [VERIFIED multiple: openrouter.ai blog, hunteralphahub, dymesty]
- Context: 64k tokens total per request, 32k for state + longest question (TypeSafe 1P). OpenRouter/Cloudflare/Vercel list 32,000 total. [VERIFIED jevaiguide.com]
- Vendor latency claim: 70–500 ms end-to-end. [VENDOR]
- Rate limits: none published; TypeSafe paused new account signups 2026-09-22 (waitlist) — OpenRouter is the no-waitlist path. [SECONDARY]
- No published free tier beyond initial access.

### 1.5 SDKs
- **JavaScript/TypeScript SDK** and **Python SDK** — official, from TypeSafe GitHub org; base URL configurable via `TYPESAFE_BASE_URL` env var (confirmed working against third-party compatible servers like local-jev with zero changes). Python usage: `from typesafe_sdk import Choice, Noul, Score, TypeSafeClient; client.system_one(state=..., questions={...})`. [VERIFIED via local-jev README drop-in test]
- **Pydantic AI:** `pydantic-ai-slim[typesafe]`, `TypeSafeModel('jev-latest')` / `'typesafe:jev-latest'`. [VERIFIED https://pydantic.dev/docs/ai/models/typesafe/]
- **System One Adapter** (official): same typed interface over OpenAI/Anthropic/OpenAI-compatible APIs. [listed in awesome-typesafe-jev]
- "jevclient": not found as an official package — the Python SDK is the client. [UNVERIFIED / negative result]
- Awesome list: https://github.com/AbdelStark/awesome-typesafe-jev

### 1.6 Accuracy standing (context for local comparisons)
- JevBench (Benchmark Heaven, MIT, https://github.com/fstandhartinger/jevbench): Jev 1.13.0 composite **63.29 (#3 of 89, v1.4.2.1)**, Intelligence 53.1, Calibration 76.3, hard-tier accuracy 74.1%, judge tier 94.5%, sealed 36.7%; 86.6% on the 231 public items (earlier v1.2/1.3 measurement). [VERIFIED benchmark repo + leaderboard]
- arXiv 2609.37647 (independent, 37 datasets, 346k requests): 95–99% on IMDB/SST-2/HellaSwag/ARC, 86.7% Belebele; beats Qwen3.8-27B on 27/37, Gemma-4-E4B on all 37. [VERIFIED https://arxiv.org/html/2609.37647v1]
- Decision Index v0.2.1: Jev 1.13 = 57.91 (reference); StartLux-Decision-27B 63.88 and decider-chat-gemma4-31b 57.33-class systems beat it. [SECONDARY]
- LangWatch: Jev leads best open sub-1B model by 12–68 points per task on routing/NLI tasks. [SECONDARY https://langwatch.ai/compare/jev-benchmark]

---

## 2. Open-Source Local Replications

### 2.1 amithgc/local-jev — the wire-compatible reference implementation [VERIFIED, primary README read]
- **Repo:** https://github.com/amithgc/local-jev · **License: MIT** (code); weights per-model (Qwen Apache-2.0, DeBERTa MIT)
- **Serves:** FastAPI, `http://127.0.0.1:8765`, **exact Jev wire format**: `POST /v1/systemone`, `GET /v1/models`, `GET /healthz`, `/docs`. Official `typesafe-sdk` works unchanged (`TYPESAFE_BASE_URL=http://127.0.0.1:8765`, any `TYPESAFE_API_KEY`). Optional browser portal (`--ui`). Optional Bearer auth via `LOCAL_JEV_API_KEY`. Long states truncated head+tail with `x-local-jev-truncated: true` header. `jev-latest`/`jev-preview` map to server default.
- **Mechanism:** no text generation; `llm` backend reads next-token probabilities of option letters A/B/C… in one forward pass (plain or JSON prompt layout per card); `nli` backend = entailment cross-encoder; per-model temperature calibration; confidence = `(n·p_max − 1)/(n−1)`.
- **Models & sizes (Apple M4 Max numbers):**

| Model card | Backend | HF model | JevBench public (231) | Median latency | Disk/RAM |
|---|---|---|---|---|---|
| `llm-qwen3.5-4b` (default) | llm | `Qwen/Qwen3.5-4B` | **80.5%** | 651 ms | 9.32 GB disk, ~8.5 GB RAM |
| `llm-qwen3-4b` | llm | `Qwen/Qwen3-4B-Instruct-2507` | 70.1% | 177 ms | 8.04 GB |
| `llm-qwen3.5-2b` | llm | `Qwen/Qwen3.5-2B` | 66.2% | 261 ms | 4.55 GB |
| `llm-qwen2.5-1.5b` | llm | `Qwen/Qwen2.5-1.5B-Instruct` | 58.9% | 74 ms | 3.09 GB |
| `nli-deberta-large` | nli | `MoritzLaurer/deberta-v3-large-zeroshot-v2.0` (MIT) | 54.1% | 76 ms | 0.87 GB |

- vs hosted Jev 86.6% (published) and SemIf 81.0% on same items. When local models say "sure" (confidence ≥0.8) they're right 98–100% of the time on their 100-case set.
- Hardware: Apple Silicon / Linux / WSL2; CUDA or Apple GPU recommended, CPU works. Memory budget `LOCAL_JEV_MEMORY_GB` (default half RAM), LRU unload.
- **No GGUF path** — PyTorch/transformers only. sha256: no published checksums (uses HF cache).
- Note: JevBench leaderboard also lists a separate "local-jev Qwen3.5-4B" row (Intelligence 24.1, below gate, 35% Noul decisive rate — earlier version measured by the benchmark).

### 2.2 "jev-at-home" — DiffusionGemma/djev (vLLM structured reads)
- No repo literally named "jev-at-home"; the phrase is Matt Mastracci's "We have Jev at home." [VERIFIED negative + origin]
- **Project:** djev — Jev-style decision architecture on Google's DiffusionGemma via **vLLM PR #57250** ("structured generation mode for DiffusionGemma model (Jev-like)"), fork `siliconflow/vllm-structured-reads`. Fixed answer slots in the diffusion canvas; single parallel diffusion pass → distribution over options. Runs on a single DGX Spark; early head-to-head ~tied with Jev on accuracy. [VERIFIED PR exists: https://github.com/vllm-project/vllm/pull/58626 references merge; https://explainx.ai/blog/diffusiongemma-jev-vllm-open-source-2026, https://thakicloud.com/tech-blog/en/dev/diffusiongemma-jev-vllm/]
- Apache-licensed decision server on DiffusionGemma 26B (NVIDIA + Apple silicon) per awesome-typesafe-jev. **Not llama.cpp-compatible** (diffusion model).

### 2.3 poorjev (rupeshpoojary9) [VERIFIED repo exists]
- **Repo:** https://github.com/rupeshpoojary9/poorjev · `pip install poorjev` · Owner Rupesh Poojary
- "Poor man's Jev": local-first System One layer on **commodity zero-shot NLI models** with temperature scaling + **conformal abstention**; reproducible calibration eval (ECE 0.170 → 0.071 on its own labelled set, cross-validated); fully offline, no API key. [VERIFIED via PRD.md + awesome list card; PRD dated 2026-09-19 said "not started — this PRD is the build spec", Reddit launch post confirms it was built]
- License: not read directly [UNVERIFIED; likely MIT]. Stars: low (PRD-stage project). Not llama.cpp-based.

### 2.4 Rizzo Flow (Rizzo-AI-Academy) [VERIFIED, primary README read]
- **Repo:** https://github.com/Rizzo-AI-Academy/rizzo-flow · **~810 stars, 53 forks (2026-10-04)** · License: code open (README implies permissive; weights Apache-2.0 inherited from Spark-X2.5)
- **Runs on llama.cpp** (release b11081 prebuilt binaries; Apple/NVIDIA/AMD/Intel/CPU) — **this is the most directly relevant project to our constraint.**
- **Serves:** `http://127.0.0.1:8017`, Jev-compatible `POST /v1/systemone` + `GET /v1/models`, plus playground UI; model ids `rizzo-latest`, `rizzo-flow-4b-q8_0`, `rizzo-spark-x2.5-4b-q8_0`; optional `RIZZO_API_KEY` Bearer auth. Also `POST /v1/decisions` and its own numeric primitive. `TYPESAFE_BASE_URL=http://127.0.0.1:8017` designed for (untested with real SDK per README).
- **Models (HF):** `rizzoaiacademy/rizzo-flow` (4B, LoRA fine-tune r16/α32, 32.4M params merged → GGUF) and `rizzoaiacademy/rizzo-flow-1.7b` on base `XHToken/Spark-X2.5-4B` / `-1.7B` (Apache-2.0; **native 1M-token context**, default 8,192/question via `--ctx`; KV ~144 KiB/token → 1.4 GiB @8k, 4.8 GiB @32k).
- **Sizes:** 4B Q8_0 ≈ **4.4 GB** download; 1.7B ≈ 1.8 GB; Q4_K_M variants also published (ties Q8_0 on 4B, −5 pts on 1.7B).
- **Accuracy (author, typed-decisions benchmark, Q8_0):** base 0.574 → fine-tuned 0.648 (Jev 0.727 on same); Brier 0.205, ECE 0.112. ~150 ms/decision on RTX 5060 Ti (MLX runtime; llama.cpp ~1.8× faster). Authors explicitly disclaim Jev parity; probabilities need user calibration. sha256: not published [UNVERIFIED].

### 2.5 APUS fast-browser-use + APUS-OpenJev [VERIFIED, primary README read]
- **Repo:** https://github.com/APUS-AI-Lab/fast-browser-use · **MIT** · ~202 stars (trendshift snapshot) · First public Jev reproduction (2026-09-19, 4 days after launch)
- Browser-agent skill (Claude Code/Codex/Cursor): DOM → candidate action tuples `(CLICK, btn_7)` mapped to vocab tokens; single forward pass softmax over candidate logits → zero selector hallucination. 79 ms/decision on RTX PRO 6000; ~18 s median full Wiki task offline on M2 Pro. MLX or PyTorch (CUDA/CPU); `fbu download` fetches pinned **Qwen3.5-9B 4-bit (~5.95 GB)**. Not wire-compatible with Jev API (it's an action selector, Python API + CLI, not `/v1/systemone`).
- **Models (HF):** `apus-ailab/APUS-OpenJev-v1` family (Apache-2.0): **Qwen3.5-4B** (merged BF16 checkpoint-5949), **Qwen3.5-9B**, **Qwen3.5-35B-A3B**; effort=low (16 layers) / high (32 layers); community GGUF + MLX ports within hours of release. Evals: Frozen80 88.75% / 85.0% vs Jev API 82.5%; 1,000-question panel 82.2/81.1/80.5% vs Jev 77.0%, Laya 50.5%; 9B service median 25.58 ms. [VERIFIED via hanxiao.io tracker + HF collection reference; https://huggingface.co/apus-ailab/APUS-OpenJev-v1]

### 2.6 Other major Jev-class local models (survey)

| Project | Repo / HF | Base, size | License | Serves / format | JevBench / accuracy | Notes |
|---|---|---|---|---|---|---|
| **Mapika/decider** | https://github.com/Mapika/decider, `Mapika/decider-4b`, `-2b`, `-12b`, `-0.8b`, GGUF variants | Qwen3.5-4B-Base (4.2B), 2B, Gemma-4-12B | Apache-2.0 | PyPI `decider-ai` System One server, **`/v1/systemone` wire format**; TypeSafe SDKs work | **decider-4b v2: JevBench #1 of 89, 64.13** (Jev 63.29); hard 0.649; 17 ms median | **GGUF: decider-2b-GGUF Q4_K_M 1.3 GB, decider-4b-GGUF Q4_K_M 2.7 GB**, llama.cpp on CPU (0.12–0.7 s/req on 8 threads). Pin HF tag `v2` for the #1 weights |
| **StartLux-Decision** | https://github.com/StartLuxLabs/StartLux-Decision, `startlux-models/StartLux-Decision-<size>-<prec>-GGUF` | Qwen3.5 arch; 0.8B/2B/4B/9B/27B (+35B-A3B) | Code Apache-2.0; **weights CC BY-NC-4.0** | In-folder `startlux_decision.gguf_server` runs in front of llama-server, TypeSafe-compatible `/v1/systemone` | 27B: Decision Index 63.88 vs Jev 57.91 (31/38 wins); JevBench 208/231; 4B Q8_0 100% decision parity | **GGUF all dense sizes: BF16/Q8_0/Q4_K_M; 4B Q8_0 4.48 GB, Q4_K_M 2.71 GB**; multimodal, 256K ctx. Non-commercial weights! |
| **JevK5** (alibiserikbay) | HF `alibiserikbay/JevK5-*`, `alibiserikbay/JevK5-GGUF`, `alibiserikbay/JevK5-Lite` (437M DeBERTa encoder) | Qwen3.5-4B/2B/9B + merged LoRA r16 | Apache-2.0 | own runtime, ~9–13 ms/decision on H100 | v0.2.0 JevBench #4 (62.04); 4B 0.804, 2B 0.751 on held-out | **2B: 3.5 GB bf16; GGUF Q8_0 2.0 GB** in JevK5-GGUF. Plumb-4B (crh225, JevK5 v0.2+LoRA) is JevBench **#1 overall 65.84** |
| **Jev-Style (chaoliangUNSW)** | https://jevstyle.com, HF `chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF`, `...-Qwen3.5-2B-Decision-GGUF`, `...-MLX-bf16` | Qwen3.5-0.8B full FT / Qwen3.5-2B | Apache-2.0 | **llama.cpp / LM Studio / Ollama direct**: prompt format + 1-token `top_logprobs` readout (client renormalises option letters); works over OpenAI-compatible `/v1/chat/completions` | v3 0.8B: 79.2% on 2,000 typed decisions (Laya 76.6, Jev zero-shot 72.7); 2B v1: 82.3% held-out, ECE 0.017; v3 2B: 73.6% JevBench | **0.8B Q4_K_M = 0.53 GB** (25,600-token input, 51 languages, no option cap); 2B Q4_K_M 1.3 GB / Q8_0 2.1 GB / BF16 3.9 GB |
| **Open-Jev (Zefan-Cai)** | https://github.com/Zefan-Cai/Open-Jev (MIT, ~156★), HF `ZefanCai/Open-Jev-2B/-9B/-27B-v1.1` (sha-pinned revisions) | Qwen3.5-2B/9B, Qwen3.8-27B + LoRA + scalar head | MIT code | `python -m jev.server` (HF transformers; CPU/MPS/Docker guides) | 9B: open competence 61.8/sealed 65.9 (JevBench v1.5.4 snap); 2B weak | Pinned revisions in README (e.g. 2B rev `0c7aa498…`) |
| **SemIf (TheoLeeCJ/SemIf-OpenJev)** | https://github.com/TheoLeeCJ/SemIf-OpenJev | Qwen3.5-4B (262k native ctx) | MIT | open option-logit baseline, `--max-tokens` CLI | 81.0% on JevBench 231 public (local-jev measured) | Contributed JSON prompt layout + shared-state prefix reuse ideas; credited by local-jev & Rizzo Flow |
| **Laya (ConvAI Innovations)** | https://github.com/NandhaKishorM/laya, HF `convaiinnovations/laya` (~25.5k★) | **ModernBERT-large 421M encoder** + decision head (RLCD-trained) | Apache-2.0 | `pip install laya`; `laya-serve` Jev-compatible `/v1/systemone` (+batch); Python SDK, ONNX path, router, MCP | 92.2% @50% coverage; ~33–38 ms GPU; JevBench Intelligence 1.8 (weak absolute accuracy, great latency/cost) | English + multilingual (100+ langs) + typed-decisions checkpoints, ~1.5 GB total. GGUF conversions exist but are **not loadable by llama.cpp** (TurboLLM docs warning) |
| **kev (Jared Palmer)** | https://github.com/jaredpalmer/kev (~7.2k★), HF `jaredpalmer/kev-0.8b` (rev `9a45d25e`) | Qwen3.5-0.8B-Base frozen + LoRA r16 + pointer head, T=2.35 | Apache-2.0 | prefill-only server, state cached & shared across questions | best open sub-1B in LangWatch tasks (e.g. 91.3% 20-intent routing, beats Jev there) | 4B/9B siblings; GGUF demos `espetro/kev-*-demo-gguf` |
| **opendecider (manjunathshiva)** | https://github.com/manjunathshiva/opendecider, HF `manjunathshiva/opendecider-small-GGUF` | small model + LoRA | [UNVERIFIED] | **LM Studio/Ollama/vLLM; `opendecider serve` → Jev `/v1/systemone`** on top of llama.cpp-compatible runtimes | [UNVERIFIED] | `ollama pull hf.co/manjunathshiva/opendecider-small-GGUF:Q8_0` |
| **OpenJev / SemIf note**: leaderboard "OpenJev" Intelligence 70.3 vs "SemIf, formerly OpenJev" 27.1 — naming collision; also **ekzhang/openjev** (Qwen3.6-35B-A3B + SGLang radix cache, Jev-compatible public API) | — | — | — | — | — |
| DiffusionGemma-class: **djev** (above), **Nemotron Diffusion 8B** (JevBench Intelligence 20.4) | vLLM PR #57250 | DiffusionGemma | Apache-2.0 | vLLM structured-reads | ~tied with Jev (early) | not llama.cpp |
| **Julia 1 (Supersonic Labs)** | HF (Apache-2.0) | 144.3M, mmBERT-small encoder + decision head | Apache-2.0 | CPU-first; ONNX/WebGPU in browser | +0.45 vs Jev reference on one suite; misses Banking77 | trained for ~US$104; picks from 2–20 options |
| **Fastino GLiNER2.5-Decide** | HF `fastino/GLiNER2.5-Decide` (340M) | DeBERTa-class | open | hosted API + weights | best local classifier in zero-shot-ie-bench; JevBench capability 37.6 | GLiNER-style, single-label softmax |
| **RSI-Jev** (shanghua-gao) | https://github.com/shanghua-gao/rsi-jev | 2B | MIT code, Apache-2.0 weights | `/v1/systemone`-compatible server | 0.791 typed-decisions; 0.774 held-out scienthoon | trained by recursively self-improving system |
| **fern** (reoring) | https://github.com/reoring/fern | Qwen3.5-4B distilled from DeepSeek-V4-Flash (2-bit GGUF teacher) | [UNVERIFIED] | reads A–Z/0–9/yes/no logits; Jev-compatible API | demo: 1,200 decisions in 9 s | plain `Qwen3_5ForCausalLM` checkpoint |
| **Winnow-12B** | HF `EldanRing/Winnow-12B` | Gemma 4 12B IT | [UNVERIFIED] | Q8 GGUF, 64K ctx + vision on 16 GB RTX 5070 Ti | ties Jev 85.71% on 231 public items | JevBench Intelligence 59.5 |
| **Nokia AnyJev** | https://github.com/nokia-applied-research/AnyJev | training-free wrapper over any LLM | [UNVERIFIED] | next-token distribution readout, debiasing L0/L1 | — | Turns any chat LLM into a decision model without training |
| **CLM-8B (Contrastive-LM)** | HF `Contrastive-LM/...` | frozen Qwen3-8B + 20M head | open | contrastive | "on par with Jev" on computer-use tasks (vendor) | JevBench Intelligence 0.1 |
| **Others seen on JevBench leaderboard:** Quyet-1.0 (Intel 73.4, top), wity-1, torchcast-decision-12b, deck-31B/4B, Cygnet, Jev-Omni, swanOne, AutoJev-27B, Eikos-27B, Clef (Jev-compatible host), OpenThai-SystemOne (gated), Jev-Style MacJev-322M, ballot-jev-0.5b (order-invariant), Bosun v3.1 (Hanno-Labs, GGUF F16/Q8/Q4_K_M, `Hanno-Labs/jev-compatible-server`), Dohnuts-0.8B (multimodal), Jev-Japanese-Judgment (LFM2.5-1.2B-JP, **Q4_K_M GGUF 698 MB via llama-embedding + head.npz**), Argos1111/jev_local (**modified llama.cpp** + Sarashina vision mmproj for image decisions) | | | | | | |

Full trackers: https://hanxiao.io/all-about-jev/ (1,691 replications tracked), https://benchmarkheaven.com/jev-models (leaderboard), https://www.datacamp.com/blog/top-open-source-jev-alternatives.

---

## 3. Serving decision models via llama.cpp / llama-server (GGUF)

### 3.1 Can a small Qwen GGUF answer noul/choice/score? Yes — two proven patterns:

**Pattern A — single-token logprob readout over OpenAI-compatible API** (works with stock llama-server):
Render state + question + lettered options into a prompt ending `Answer:`, request **1 token** with `top_logprobs`, renormalize the probabilities of the option-letter tokens (` A`, ` B`, … or `yes`/`no`) into a distribution. This is exactly `jev_style_client.py` from `chaoliangUNSW/Jev-Style-Qwen3.5-2B-Decision-GGUF` [VERIFIED card]:
```bash
llama-server -hf chaoliangUNSW/Jev-Style-Qwen3.5-2B-Decision-GGUF:Q8_0 --port 8080
python jev_style_client.py --url http://localhost:8080   # decide / decide_bool / decide_score
```
Verified end-to-end through llama.cpp/LM Studio: 81.6% accuracy, ECE 0.028, ~110 ms/decision over HTTP on M1 Max. Choice = options as letters; Score = ordered levels as letters (expectation = weighted score); Noul = `yes`/`no` tokens. Constraint: ≤26 options per call through `top_logprobs` (20 in practice) — larger sets need grouped runoff (StartLux does this).
Alternatively use `logit_bias` to force the answer token into the option-letter set (guarantees on-schema single token; you still need logprobs for probabilities).

**Pattern B — decision server in front of llama-server** (Jev wire format):
- `python -m startlux_decision.gguf_server` (Apache-2.0) wraps llama-server and serves `POST /v1/systemone`. [VERIFIED StartLux README]
- **Rizzo Flow** embeds llama.cpp directly and serves `/v1/systemone` on :8017.
- **opendecider serve** puts `/v1/systemone` on top of LM Studio/Ollama runtimes.
- decider-2b/4b-GGUF: Q4_K_M via llama.cpp, 0.12–0.7 s/request on 8 CPU threads.

### 3.2 Existing GGUF classifier/decision models on HF (llama.cpp-loadable)
- `chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF` — Q4_K_M **0.53 GB** [VERIFIED]
- `chaoliangUNSW/Jev-Style-Qwen3.5-2B-Decision-GGUF` — Q4_K_M 1.3 GB, Q8_0 2.1 GB, BF16 3.9 GB [VERIFIED]
- `alibiserikbay/JevK5-GGUF` — 2B Q8_0 2.0 GB [VERIFIED via card]
- `Mapika/decider-2b-GGUF`, `Mapika/decider-4b-GGUF` — Q4_K_M 1.3 GB / 2.7 GB [VERIFIED README]
- `startlux-models/StartLux-Decision-{0.8B,2B,4B,9B,27B}-{BF16,Q8_0,Q4_K_M}-GGUF` — 4B Q8_0 4.48 GB / Q4_K_M 2.71 GB (15 GGUF repos) [VERIFIED]; weights CC BY-NC-4.0
- `rizzoaiacademy/rizzo-flow` — 4B Q8_0 ~4.4 GB + Q4_K_M [VERIFIED]
- `manjunathshiva/opendecider-small-GGUF` — Q8_0 [VERIFIED README]
- `Hanno-Labs/Bosun v3.1` — 0.6B F16/Q8_0/Q4_K_M GGUF [SECONDARY]
- `fukayatti0/jev-japanese-judgment` — merged-LoRA GGUF Q4_K_M 698 MB (llama-embedding + MLP head) [SECONDARY]
- `espetro/kev-{0.8b,4b,9b}-demo-gguf` — demo builds [SECONDARY]
- Laya GGUF conversions: **do NOT load in llama.cpp** [VERIFIED TurboLLM docs]

### 3.3 Alternatives outside llama.cpp (noted; we prefer llama.cpp)
- ONNX DeBERTa NLI: `MoritzLaurer/deberta-v3-large-zeroshot-v2.0` (0.87 GB, MIT) — used by local-jev's nli backend; DeBERTa is an encoder → **not GGUF/llama.cpp compatible**; use ONNX Runtime (Laya ships an ONNX path) or transformers.
- vLLM structured reads (djev/DiffusionGemma), SGLang `/v1/score` restricted-softmax readout (Hyperstack reproduced Jev mechanism on Qwen2.5-0.5B: 463 ms scoring vs 848 ms generation) — the SGLang scoring trick is conceptually identical to Pattern A and could equally be done against llama-server's completion logprobs.
- **Bottom line for our constraint:** stock llama-server + Pattern A with a fine-tuned decision GGUF (Jev-Style v3, JevK5, decider) is sufficient; if exact Jev wire format is required, run a thin adapter that translates `/v1/systemone` → chat-completions-with-logprobs, or adopt Rizzo Flow / startlux gguf_server / opendecider serve.

---

## 4. Download URLs, sha256 pinning, quantization, RAM footprints

HF resolve URL pattern (pin to a commit sha for immutability):
```
https://huggingface.co/<repo>/resolve/<revision>/<filename>
# e.g. https://huggingface.co/chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF/resolve/main/Jev-Style-0.8B-Decision-v3-Q4_K_M.gguf
```
**sha256 checksums:** HF publishes per-file LFS sha256 via the API (`GET https://huggingface.co/api/models/<repo>?blobs=true` → `siblings[].lfs.sha256`) and in the `x-linked-etag` header of resolve redirects. I could **not fetch specific sha256 values** in this session (HF API blocked by the research proxy) — **[UNVERIFIED: no project above publishes out-of-band sha256 manifests in what I read; verify at integration time with `curl -sI <resolve-url> | grep -i x-linked-etag` or `huggingface_hub.model_info(..., files_metadata=True)`]**. Zefan-Cai/Open-Jev pins model **revisions** (git-style sha, e.g. `0c7aa498b1627be8da4acf34c863ff0ee0a92785`) — revision pinning is the recommended integrity approach [VERIFIED README].

RAM footprint rule of thumb (llama.cpp): ~GGUF file size × 1.05–1.2 + KV cache (Rizzo measured 144 KiB/token on a 4B → 1.4 GiB @ 8k ctx; decision workloads use short contexts, so budget is modest).

| Candidate | Repo / file | Quant | File size | Approx RAM @ 8k ctx |
|---|---|---|---|---|
| Jev-Style 0.8B v3 | `chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF` / `*-Q4_K_M.gguf` | Q4_K_M | **0.53 GB** | ~0.8–1.0 GB |
| Jev-Style 2B (v1) | `chaoliangUNSW/Jev-Style-Qwen3.5-2B-Decision-GGUF` / `...-Q4_K_M.gguf` / `...-Q8_0.gguf` | Q4_K_M / Q8_0 | 1.3 / 2.1 GB | ~1.7 / ~2.6 GB |
| decider-2b | `Mapika/decider-2b-GGUF` | Q4_K_M | 1.3 GB | ~1.7 GB |
| decider-4b | `Mapika/decider-4b-GGUF` | Q4_K_M | 2.7 GB | ~3.4 GB |
| JevK5-2B | `alibiserikbay/JevK5-GGUF` | Q8_0 | 2.0 GB | ~2.5 GB |
| StartLux-Decision-4B | `startlux-models/StartLux-Decision-4B-Q8_0-GGUF` / `...-Q4_K_M-GGUF` | Q8_0 / Q4_K_M | 4.48 / 2.71 GB | ~5.5 / ~3.4 GB |
| Rizzo Flow 4B | `rizzoaiacademy/rizzo-flow` | Q8_0 (also Q4_K_M) | ~4.4 GB | ~5.5 GB (+1.4 GiB KV @8k) |
| Rizzo Flow 1.7B | `rizzoaiacademy/rizzo-flow-1.7b` | Q8_0 | ~1.8 GB | ~2.3 GB |
| opendecider-small | `manjunathshiva/opendecider-small-GGUF` | Q8_0 | [size UNVERIFIED, ~1–2 GB class] | ~2 GB |
| Qwen3.5-4B (generic, local-jev default) | `Qwen/Qwen3.5-4B` (+ community GGUF) | bf16 safetensors | 9.32 GB (bf16); Q4_K_M ~2.5 GB class | ~8.5 GB bf16 / ~3.2 GB Q4 |
| NLI fallback | `MoritzLaurer/deberta-v3-large-zeroshot-v2.0` | fp32 | 0.87 GB | ~0.9 GB (transformers/ONNX only) |

---

## 5. Recommended candidate models for local decision profiles

Constraint: **llama.cpp/llama-server only**, Jev-style typed decisions (noul/choice/score), local-LLM orchestrator integration.

1. **Best tiny / CPU profile — Jev-Style 0.8B v3:** `chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF`, file `Jev-Style-0.8B-Decision-v3-Q4_K_M.gguf` (0.53 GB). Apache-2.0, 25.6k ctx, 51 languages, 79.2% on typed-decisions. Serve with stock llama-server + logprob readout (Pattern A). Calibrated out of the box (temperature folded into weights).
2. **Best small accuracy / wire-compat — decider-4b:** `Mapika/decider-4b-GGUF` (Q4_K_M 2.7 GB; pin HF tag **v2** for the JevBench #1 weights) with the `decider-ai` server for native `/v1/systemone`, or raw GGUF via Pattern A. Apache-2.0. JevBench 64.1 > hosted Jev 63.3.
3. **Best mid profile with long context — JevK5-2B / 4B:** `alibiserikbay/JevK5-GGUF` (2B Q8_0 2.0 GB). Apache-2.0, strong held-out calibration (ECE 0.071 hard tier).
4. **Full Jev API drop-in server — Rizzo Flow:** `rizzoaiacademy/rizzo-flow` (4B Q8_0 4.4 GB) + its llama.cpp-based server on :8017, native `/v1/systemone`. Fine-tuned for well-shaped probabilities; plan to recalibrate on own data (authors' explicit caveat).
5. **Max local accuracy (GPU available), non-commercial OK — StartLux-Decision-4B:** `startlux-models/StartLux-Decision-4B-Q8_0-GGUF` (4.48 GB, 100% decision parity with bf16 on JevBench 231). **Caution: CC BY-NC-4.0 weights** — not for commercial orchestrator use.
6. **Fallback / bulk classification outside llama.cpp (only if we relax the constraint):** `MoritzLaurer/deberta-v3-large-zeroshot-v2.0` (0.87 GB, MIT) via ONNX, or `convaiinnovations/laya` (421M, Apache-2.0) via its own engine.
7. **Integration pattern:** one llama-server per decision profile; thin adapter translating `{state, questions}` → lettered-option prompt → 1-token `top_logprobs` (or `logit_bias`-constrained) → Jev-shaped `{noul|choice|score, probabilities, confidence}`; `confidence = (n·p_max−1)/(n−1)` to match the ecosystem convention; Score = probability-weighted level expectation. Keep per-model temperature calibration hooks (Rizzo/local-jev approach).

**Key caveats:** All accuracy numbers vs hosted Jev are on public benchmarks with varying integrity; several leaderboard entries are author-measured. No open model matches Jev on knowledge-heavy/multi-hop hard items (Jev still leads Intelligence axis). TypeSafe MCA §2.3(b) prohibits training on Jev outputs — all recommended projects state they use only public data. sha256 values must be pulled from HF at pin time (§4).
