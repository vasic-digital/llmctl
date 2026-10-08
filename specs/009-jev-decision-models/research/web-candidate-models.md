# Web verification of Jev-class decision-model candidates (009-jev-decision-models)

| Field | Value |
|---|---|
| Retrieved | 2026-10-07 (UTC), all URLs below on that date |
| Method | Anonymous Hugging Face API (`https://huggingface.co/api/models/<repo>?blobs=true`, metadata only), HF model cards (README text only), GitHub API (`gh api`, anonymous-equivalent public data), PyPI JSON, npm registry. **No weights downloaded.** The only file bodies fetched were three small tokenizer/config files of the NLI pin (Section 3.4) to compute their missing sha256. |
| Feeds | spec.md FR-002, FR-003, FR-007, FR-008, FR-052; source-findings.md Sections E, G, H |
| Provenance labels | VENDOR-CLAIM = statement from the model's own card/README, not reproduced. PRIMARY-FACT = read from the HF API / GitHub API / PyPI. ESTIMATE = my arithmetic. UNCONFIRMED = not established. |
| Status | Paper verification only. Nothing here replaces the real-run evidence FR-007 requires. |

## 0. Headline findings

1. **All six currently pinned profiles still match huggingface.co directly** (revision sha, file size, LFS sha256, licence), checked file by file against `jev/llmctl/llmctl/models/catalog.json`. The mirror (hf-mirror.com) values were correct. See Section 3.
2. **The ecosystem is real, not hallucinated.** Of the ~45 names in the brief, only a handful could not be resolved to a primary artifact (Section 2: NOT-FOUND and name-collision list). Most of the "second team" candidates exist.
3. **llama.cpp now has a native decision-model API, and our pin predates it.** PR ggml-org/llama.cpp#29818 ("add /v1/systemone API (models: laya, julia-1, lev, openjev, kev)") merged 2026-10-02 as commit `a4cb4c61…`, first release tag **b11361**. The pinned submodule is tag **b10969** (`391fac16…`), which has no `decision_type`/`/v1/systemone` code (grep of `submodules/llama.cpp`: PRIMARY-FACT). Clef support merged 2026-10-03 (PR #29831, `99b95488…`, first tag **b11371**). Latest release at retrieval: `v0.6.0` (2026-10-05) / tag b11471 (2026-10-07). Native-path candidates (Kev, Laya, Julia-1, lev) therefore need an **engine pin bump** to at least b11361. Open upstream bugs to know first: #30064 (Clef Q8_0 probabilities collapse; Kev-4B Q8_0 reported correct), #30073 (large inputs rejected at default physical batch 512).
4. **Most repos with "Jev" in the name are NOT usable as shipped catalog entries**: many are non-commercial weights (OpenJev, StartLux, Bespoke-Nimble, jev-at-home, bev-decider), LoRA-only or safetensors-only, require custom runtimes (vLLM/DiffusionGemma, patched llama.cpp, vendored runtimes), or are harnesses with no weights of their own (poorjev, SemIf, AnyJev, EdgeJev, local-jev).
5. **Name collisions**: PyPI `kev` is an unrelated 2021 key-value ORM; PyPI `winnow` is an unrelated JSON-schema library; PyPI `openjev` 0.0.1 has no licence metadata. Never `pip install` these by guess.

## 1. Master table

Verdict key: **ADMIT-CANDIDATE** = passes paper gate (Section 4), still needs real-run verification on our host (FR-007); **USER-ONLY** = USER-INSTALLABLE-ONLY (overlay path, FR-008); **REJECT**; **NOT-FOUND**.
"New pin" = needs an llama.cpp bump to >= b11361 (native `/v1/systemone`). "Letter" = existing logit-readout-over-option-letters protocol as in the six pinned llama profiles.

| # | Candidate | Primary source (HTTP) | Weights licence | Format / params | Class / protocol | Verdict |
|---|---|---|---|---|---|---|
| P1 | chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF | HF 200 | Apache-2.0 | GGUF Q4_K_M 529 MB, 0.75 B | decoder, letter-logit via bundled `jev_score.cpp` scorer | **ADMIT-CANDIDATE (pinned, pin verified)** |
| P2 | Mapika/decider-4b-GGUF (v2.1) | HF 200 | Apache-2.0 | GGUF Q4_K_M 2.71 GB, 4.2 B | decoder, letter-logit, per-type temperatures | **ADMIT-CANDIDATE (pinned, pin verified)** |
| P3 | rizzoaiacademy/rizzo-flow (4B Q8_0) | HF 200 | Apache-2.0 | GGUF Q8_0 4.38 GB, arch `spark2_5` | decoder, letter-logit | **ADMIT-CANDIDATE (pinned, pin verified)** |
| P4 | MoritzLaurer/deberta-v3-large-zeroshot-v2.0 | HF 200 | MIT | ONNX fp32 1.74 GB, 435 M | encoder NLI, 1 pass per option | **ADMIT-CANDIDATE (pinned, pin verified; not Jev-shaped, NLI class)** |
| P5a | alibiserikbay/JevK5-GGUF 2B v0.2 Q8_0 | HF 200 | Apache-2.0 | GGUF 2.01 GB, 1.88 B | decoder, letter-logit | **ADMIT-CANDIDATE (pinned, pin verified)** |
| P5b | alibiserikbay/JevK5-GGUF 9B v0.3.3 Q8_0 | HF 200 | Apache-2.0 | GGUF 9.53 GB, 8.95 B | decoder, letter-logit | **ADMIT-CANDIDATE (pinned, pin verified)** |
| 1 | Kev (jaredpalmer/kev-0.8b/4b/9b/27b; ggml-org GGUFs) | HF 200, GH 200 | Apache-2.0 (adapter+head; base Apache-2.0) | upstream: PEFT + `head.pt` (pickle). ggml-org GGUF Q4_K_M/Q8_0 | decoder + pointer head; native `/v1/systemone` | **ADMIT-CANDIDATE: ggml-org GGUFs only, new pin**. Upstream `head.pt` = pickle, do not use |
| 1b | kev-onnx | HF `onnx-community/kev-4b-ONNX` 200; npm `kev-onnx` **404** | Apache-2.0 | transformers.js q4/q4f16 external data | no documented onnxruntime pointer-head protocol; card base mismatch | **REJECT** (npm name NOT-FOUND) |
| 2 | Verdict 151M (`heman10x/rlcd-modernbert-151m`) | HF 200; GH Heman10x-NGU/Verdict-open-jev | Apache-2.0 (HF); GH LICENSE shows NOASSERTION | safetensors + ONNX fp32 606 MB / fp16 304 MB | encoder (GLiClass ModernBERT), 25 option slots, custom SDK pre/post | **USER-ONLY** |
| 2b | verdictml (PyPI 0.1.0) / Manav2op/verdict-small | PyPI 200, HF 200 | Apache-2.0 | 118 M e5-small based, ONNX int8 118 MB | embedding + fitted head, `torch` dependency | **USER-ONLY** (different project from 2) |
| 3 | Laya (convaiinnovations/laya; ggml-org/Laya-GGUF) | HF 200, PyPI `laya` 0.3.29 | Apache-2.0 | GGUF Q8_0 449 MB, 421 M, arch `modern-bert` | non-autoregressive encoder; native `/v1/systemone` | **ADMIT-CANDIDATE (new pin)** |
| 3b | laya-typed-decisions third-party GGUF/ONNX (mys, ti3x-m) | HF 200 | Apache-2.0 | arch `ggmlc` (custom) / ONNX 1.7 GB | custom runtimes | **USER-ONLY** |
| 4 | local-jev (amithgc/local-jev) | GH 200; PyPI **404** | MIT (code) | no weights of its own | harness over NLI + generic LLMs | **REJECT as catalog entry**; its `nli-deberta-large` = `cross-encoder/nli-deberta-v3-large` (Apache-2.0), redundant with P4 -> USER-ONLY |
| 5 | Strands Decider 2B (StrandsAgents/strands-decider-2B-hobson-v19/v21) | HF 200 | Apache-2.0 | PEFT LoRA; third-party GGUF needs "custom Strands-aware runtime" | custom | **USER-ONLY** |
| 6 | NeoHorse-Jev-4B (TokenRhythm) | HF 200 | Apache-2.0 | GGUF Q4_K_M 3.39 GB incl. head and vision | requires bundled llama.cpp-based adapter (`runtime/build.py`) | **USER-ONLY** |
| 7 | SemIf (TheoLeeCJ/SemIf-OpenJev) | GH 200 | MIT (code) | "Model weights ... not included" | harness | **REJECT** (no weights artifact) |
| 8 | poorjev | GH 200, PyPI 200 | MIT | no weights | harness over commodity models | **REJECT** |
| 9 | APUS-OpenJev (apus-ailab) | HF 200 | Apache-2.0 | GGUF 4B Q8_0 4.48 GB; 9B; 35B-A3B | decoder, letter-logit, contract file `openjev_contracts.py` | **ADMIT-CANDIDATE (secondary; Letter)** |
| 10 | Open-Jev | `openjev/openjev` HF 200; `ZefanCai/Open-Jev-*` HF 200 | **openjev/openjev: CC-BY-NC-4.0**; ZefanCai: Apache-2.0 LoRA only | 27 B / adapters | n/a | **REJECT** (NC / adapter-only). `com-kotobalabs/open-jev-deberta-v3-large` Apache-2.0 encoder -> USER-ONLY |
| 11 | opendecider (manjunathshiva) | HF 200, PyPI 0.8.1 | Apache-2.0 | nano: 400 M ONNX; small: 4 B GGUF (arch `qwen3`) | prompt contract in `opendecider` package | **USER-ONLY** (UNCONFIRMED standalone protocol) |
| 12 | djev (mmastrac/djev, DiffusionGemma) | GH 200 | Apache-2.0 (code) | DiffusionGemma + vLLM | unsupported runtime | **REJECT** |
| 13 | Julia 1 (SupersonicLabs/Julia-1; ggml-org/Julia-1-GGUF) | HF 200 | Apache-2.0 | GGUF Q8_0 168 MB, 144 M, `modern-bert` | non-autoregressive encoder; native `/v1/systemone` | **ADMIT-CANDIDATE (new pin)** |
| 14 | GLiNER2.5-Decide (fastino; 3ntr0py-t4m3r GGUF) | HF 200 | Apache-2.0 | safetensors 1.9 GB; GGUF needs patched llama.cpp (arch `deberta-v3`) | gliner head | **USER-ONLY** |
| 15 | RSI-Jev (shgao) | HF 200 | Apache-2.0 | tower+scorer safetensors, custom `rsijev` code, 0 downloads | custom arch | **REJECT** |
| 16 | fern (reoring/fern) | HF 200, GH 200 | Apache-2.0 | 4 B safetensors only, "distilled from DeepSeek V4 Flash" | no GGUF; teacher-terms provenance not reviewed | **USER-ONLY** |
| 17 | Winnow-12B / E4B (EldanRing) | HF 200, GH 200 | Apache-2.0 | GGUF Q8_0 12.7 GB (12B) / 8.0 GB (E4B) | Gemma-4 + MTP assistant; needs its own launcher | **USER-ONLY** |
| 18 | AnyJev (nokia-applied-research/AnyJev) | GH 200, PyPI 0.3.0 | Apache-2.0 | method/library, no weights | wraps any LLM | **REJECT as model** (not a weights artifact) |
| 19 | CLM (Contrastive-LM/CLM) | GH 200 | Apache-2.0 | frozen Qwen3-8B encoder (embedding server) + 75 MB head | two-process | **USER-ONLY** (HF weights repo name not resolved) |
| 20 | decider other sizes (Mapika) | HF 200 | Apache-2.0 | see Section 3.7 | letter-logit | decider-2b-GGUF **ADMIT-CANDIDATE**; 0.8b/12b no GGUF -> **USER-ONLY**; 35b NVFP4 **REJECT** |
| 21 | StartLux-Decision | HF 200; GH `StartLuxLabs/StartLux-Decision` 200 | **CC-BY-NC-4.0 weights** (GH code Apache-2.0) | GGUF 0.8B-27B | custom `gguf_server.py` | **REJECT** (matches source-findings H) |
| 22 | EdgeJev (yzfly/edgejev) | GH 200, PyPI 0.3.2; no HF weights | Apache-2.0 LICENSE text (GH API says NOASSERTION; PyPI Apache-2.0) | converter/runtime for laya/kev ONNX | tool | **REJECT as model** |
| 23 | jev-at-home (Jibril-Frej; jevhome/*) | GH 200, HF 200 | **CC-BY-NC-4.0 weights** (GH MIT) | ONNX encoders 48 M-1 B | cross/bi-encoder | **REJECT** |
| 24 | typecastlm (mihailgribov) | HF 200, PyPI 1.2.2 | Apache-2.0 | GGUF Q8_0 4.0 GB inside HF repo | custom `Reader` (`reader.py`) | **USER-ONLY** |
| 25 | lev (interfaze-ai/lev; ggml-org/lev-GGUF) | HF 200 | Apache-2.0 | GGUF Q4_K_M 3.01 GB, 4.2 B | native `/v1/systemone` (`decision_type: lev`) | **ADMIT-CANDIDATE (new pin)** |
| 26 | Clef-Flash (Cloudflare/clef-flash; ggml-org/Clef-Flash-GGUF) | HF 200 | Apache-2.0 | GGUF Q4_K_M 6.49 GB, 9.1 B | native, needs b11371+; quantization defect open | **USER-ONLY (HOLD)**; Clef 27B -> USER-ONLY |
| 27 | OpenJev GGUF (ggml-org/OpenJev-GGUF, openjev/openjev-GGUF) | HF 200 | **CC-BY-NC-4.0** | 18.9 GB Q4_K_M, 27 B | native | **REJECT** |
| 28 | Bespoke-Nimble-9B-v3 | HF 200 | **CC-BY-NC-4.0** | GGUF 9B | native | **REJECT** |
| 29 | Others found: perplexity-ai/pplx-decider-v1(-1.1)-27b (Apache, safetensors only), autotrust/JEV-9B/27B (Apache, safetensors/vLLM), bev-decider-0.4B (CC-BY-NC), kestrel-decider-230m (licence "other"), IamBusy/OpenJev-0.6B, v6543210/openJev-1.5B (LoRA only) | HF 200 | mixed | mostly safetensors/LoRA | n/a | **REJECT / USER-ONLY** |
| N1 | Verdict "2.0" (`heman10x/openJev-verdict-2.0`) | HF **401** (no such public repo) | n/a | n/a | n/a | **NOT-FOUND** on HF (GH repo exists; weights "tracked as Git LFS pointers") |
| N2 | "EdgeJev" / "poorjev" / "djev" / "SemIf" / "Open-Jev" / "opendecider" **on Hugging Face under those exact names** | HF search | n/a | n/a | n/a | exact-name HF repo NOT-FOUND for edgejev, poorjev; exist only as GitHub/PyPI tools or under other owners |

Counts: see Section 6.

## 2. Existence results for every name in the brief

| Name | Result |
|---|---|
| 5 pinned repos (6 profiles) | all EXIST, HTTP 200, ungated |
| Kev-4B (`jaredpalmer/kev-4b`, GH `jaredpalmer/kev`) | EXISTS (HF 200; GH Apache-2.0, 8,632 stars, releases `kev-1.0` 2026-10-01 and `kev-family`) |
| kev-onnx | HF `onnx-community/kev-4b-ONNX` EXISTS; **npm `kev-onnx` NOT-FOUND (404)**; PyPI `kev` is an unrelated project |
| Verdict / verdictml (151 M) | **Two distinct projects.** (a) 151 M: HF `heman10x/rlcd-modernbert-151m` EXISTS, GH `Heman10x-NGU/Verdict-open-jev`; "Verdict 2.0" HF repo NOT-FOUND. (b) PyPI `verdictml` 0.1.0 = GH `Manavarya09/verdict`, 118 M multilingual-e5-small based, HF `Manav2op/verdict-small` EXISTS. "verdictml (151M)" in the brief conflates the two. |
| Laya (`convaiinnovations/laya`) | EXISTS, 5,317 likes, PyPI `laya` 0.3.29 |
| local-jev (`amithgc/local-jev`) | EXISTS on GitHub (MIT, 16 stars, "a research project, not a finished product"); PyPI `local-jev` NOT-FOUND; models `nli-deberta-large` / `llm-qwen3.5-4b` are registry aliases in `src/local_jev/models.py` pointing to generic third-party models |
| Strands Decider 2B | EXISTS (`StrandsAgents/strands-decider-2B-hobson-v19`, `-v21`) |
| NeoHorse-Jev-4B | EXISTS |
| SemIf | EXISTS as GitHub code (MIT); no first-party weights |
| poorjev | EXISTS (GH + PyPI), no weights |
| APUS reproduction | EXISTS (`apus-ailab/APUS-OpenJev-v1*`) |
| Open-Jev | EXISTS in three unrelated forms (see Section 1 row 10) |
| opendecider | EXISTS |
| djev | EXISTS as DiffusionGemma/vLLM projects |
| Julia 1 | EXISTS |
| GLiNER2.5-Decide | EXISTS |
| RSI-Jev | EXISTS |
| fern | EXISTS (`reoring/fern`, small) |
| Winnow-12B | EXISTS |
| AnyJev | EXISTS (a method, not a model) |
| CLM | EXISTS on GitHub (`Contrastive-LM/CLM`); HF weights repo not resolved |
| decider (other sizes) | EXIST (0.8b, 2b, 4b, 12b, 35b-a3b-nvfp4, chat-gemma4-31b, 2b-vision, 2b-coherent) |
| StartLux-Decision | EXISTS |
| EdgeJev | EXISTS (GH+PyPI); no HF weights |
| jev-at-home | EXISTS (several unrelated GH repos; `Jibril-Frej/jev-at-home` matches the description) |
| typecastlm | EXISTS |
| Additional (not in brief) | lev, Clef, Clef-Flash, OpenJev (openjev/openjev), Bespoke-Nimble-9B-v3, pplx-decider-v1, autotrust/JEV-*, jevhome/*, NanoJev, imajev |

## 3. Pinned six: re-verification against huggingface.co

Comparison made programmatically between `jev/llmctl/llmctl/models/catalog.json` profile entries and the live HF API `siblings[].lfs.{size,sha256}`.

| Profile | Repo | Pinned revision | Live HEAD | Match | File | Size | sha256 | Match |
|---|---|---|---|---|---|---|---|---|
| decide-tiny | chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF | edf37c26a1098f83cf4264b8adbe0dca2d2ebb0c | same | yes | Jev-Style-0.8B-Decision-v3-Q4_K_M.gguf | 529,296,864 | 0a19bc29bacc33e0d871146c8612b24dd14c2ed2e61cedeb7a928b0852628bac | yes |
| decide | Mapika/decider-4b-GGUF | b79f09d9ba7837f1b744295ea267b55d08e958ec | same | yes | decider-4b-v2.1-Q4_K_M.gguf | 2,708,804,640 | c7083fcfc93f650cd66caeade4a3840ef9eeeeb1e80920907c554f70619d7c56 | yes |
| decide-pro | rizzoaiacademy/rizzo-flow | 55633c8cbd2b826bd3eefdeb05310450996649df | same | yes | spark-x2.5-4b-rizzo-flow-lora-q8_0.gguf | 4,375,021,216 | dbec3c89d33984772324e65a8ed56b48e958e301b856cb870a7c1b385d01691a | yes |
| decide-nli | MoritzLaurer/deberta-v3-large-zeroshot-v2.0 | cf44676c28ba7312e5c5f8f8d2c22b3e0c9cdae2 | same | yes | onnx/model.onnx | 1,741,985,401 | beded3d71421ceb718861af381d1a0d29037b3679c7350ebd41edbf79cdced1e | yes |
|  |  |  |  |  | onnx/spm.model | 2,464,616 | c679fbf93643d19aab7ee10c0b99e460bdbc02fedf34b92b05af343b4af586fd | yes |
| decide-2b | alibiserikbay/JevK5-GGUF | ec67b0bfce5119a8b11a2cdb430bb43e3fa3e82a | same | yes | jevk5-2b-v0.2-Q8_0.gguf | 2,012,012,000 | 17222f27a89273aca7614e34083a530b0d90cd51cffeb225c7acc8e79a7e0eba | yes |
| decide-max | alibiserikbay/JevK5-GGUF | ec67b0bf… | same | yes | jevk5-9b-v0.3.3-Q8_0.gguf | 9,527,501,280 | 283de8fd216ad2200506d9236e574ddb5902b16e6a806a6fa38e9dd1b4286edf | yes |

**Result: zero mismatches.** (Caveat: repos can move; JevK5-GGUF, Mapika and ggml-org repos have changed within days. Pin by commit sha, as already done.)

Residual (source-findings D-13): three NLI files are non-LFS (config.json, tokenizer_config.json, tokenizer.json). The HF API exposes only a git SHA-1 blob id for them, no sha256. I fetched them at the pinned revision (the only file bodies downloaded) and computed sha256 (PRIMARY-FACT, 2026-10-07):

| File (rev cf44676c…) | Size | sha256 |
|---|---|---|
| config.json | 1,019 | 3b0a2a3fb311037ba72670d87cbd16f920581985178547a76936dfdb292e5271 |
| tokenizer_config.json | 1,256 | f5a1a74a632c0e9225e09a21ddf60c2e70ef5d3bfc1f261a24fd8ddab27254d2 |
| tokenizer.json | 8,656,646 | 05402ffae6dd382a8491b1d29bfc139bec5d332662e86a026f433ce54c25c202 |

These can replace the `sha256: null` entries.

Other per-pin facts (PRIMARY-FACT unless labelled):

| Item | chaoliang 0.8B v3 | Mapika decider-4b | rizzo-flow | NLI deberta | JevK5 |
|---|---|---|---|---|---|
| Owner | chaoliangUNSW | Mapika | rizzoaiacademy | MoritzLaurer | alibiserikbay |
| Licence / gated | apache-2.0 / no | apache-2.0 / no | apache-2.0 / no | mit / no | apache-2.0 / no |
| Last modified | 2026-09-26 | 2026-09-27 | 2026-09-25 | 2024-04-11 | 2026-09-25 |
| GGUF arch | qwen35 | qwen35 | spark2_5 | n/a (ONNX) | qwen35 |
| Base | Qwen3.5 0.8B (own fine-tune) | Qwen/Qwen3.5-4B-Base | XHToken/Spark-X2.5-4B (LoRA merged) | microsoft/deberta-v3-large | Qwen3.5 2B/4B/9B |
| llama.cpp b10969 can load | yes (`LLM_ARCH_QWEN35`) | yes | yes (`LLM_ARCH_SPARK2_5` present) | n/a | yes |
| Protocol | state + questions rendered by `jev_style_decision_gguf.py`; verdict read by `jev-score` (libllama JSON-lines scorer, built with `build_jev_score.sh`); `readout_config.json` | prompt built by `decider.prompt`; option-letter logits / `decider_config.json` temps (choice 1.11, noul 1.56, score 1.287); `max_options` 255; **score one prompt per decode** | softmax over answer letters A,B,… at last position; card advises recalibration | NLI entailment per hypothesis | letter logits; **each model has its own temperatures** |
| Known issues (VENDOR-CLAIM unless noted) | needs its own scorer program; tested vs llama.cpp commit 441df11f or later | batched multi-prompt decode gives batch-dependent probabilities (up to 0.02 BF16, 0.16 Q4_K_M); CPU vs GPU probabilities differ slightly; conversion used `--no-mtp` | `custom_code` tag applies only to safetensors; "not Jev" disclaimer | encoder, 512-token cap; repo contains `training_args.bin` (pickle) which must NOT be fetched | 9B v0.3 Q4_K_M and 2B Q4_K_M deliberately not published; Q8_0 chosen correctly |
| Benchmark claims (VENDOR-CLAIM) | JevBench v1.4.1 231 items 64.1%; Banking77 68.2% | JevBench top (64.13 in catalog desc); in-task acc 0.8308 | accuracy +0.074 vs base on its workflows | upstream card; no decision benchmark | per-tier: 4B v0.3 Q8_0 easy 1.000 / standard 0.944 / hard 0.784; 2B hard 0.622 (own-run) |
| Commit date risk | no tag, `main` only | no `v2` tag (confirms I-01) | rizzo-flow-1.7b has own repo | stable since 2024 | `main` only |

Expected memory (ESTIMATE, GGUF resident ~ file size x 1.1-1.3 plus KV/compute buffers; the Qwen3.5 hybrid has few full-attention layers so KV is small): decide-tiny ~0.7 GB; decide ~3.3 GB; decide-pro ~5.3 GB; decide-2b ~2.5 GB; decide-max ~11 GB. NLI uses the existing catalog rule (size x 1.5 + 512 MiB = ~3.1 GB).

## 4. Refined admission gate

The proposed gate, refined into checkable items. Every item needs a recorded PRIMARY-FACT, not a card claim.

| ID | Check | Evidence to record | Fail action |
|---|---|---|---|
| G1 | **Weights licence permits use + redistribution of a download-on-demand pin.** Read the licence of the *weights repo* (HF `cardData.license` AND the licence file in that repo), not the code repo. Allow: apache-2.0, mit, bsd, cc-by-4.0, openrail-style only if commercial use is permitted. Block: any `cc-by-nc*`, `other` without text, missing/NOASSERTION. Where code and weights licences differ (StartLux, jevhome, OpenJev), the **weights** decide. | SPDX string + file path + date | REJECT (or USER-ONLY if user may still install) |
| G2 | **Stable revision.** Pin to a 40-hex commit sha; repo not gated/private; (new) record `lastModified` and re-verify at release (several repos changed within days). Tags are optional because most repos have none. | sha, date | REJECT if no immutable ref |
| G3 | **sha256 obtainable from the primary source.** LFS files: `siblings[].lfs.sha256` from huggingface.co. Non-LFS small files: sha256 computed by us at the pinned revision and committed (git blob id is SHA-1, not accepted). Third-party mirrors never count. | sha + size for every file the profile needs (model, tokenizer, head, config, mmproj) | USER-ONLY |
| G4 | **Format we can run.** Pinned llama.cpp loads the GGUF architecture (`general.architecture` in the pinned tree's `llm_arch_names`), including the decision head if the native path is used; or onnxruntime with a documented tokenizer file and I/O contract. | arch name + proof it exists in the pinned submodule, or the bump target | USER-ONLY if a patched engine, vendored runtime, vLLM, MLX, or `trust_remote_code` is required |
| G5 | **Fits an ordinary-host tier.** Use the existing tier mapping seen in the six pins: file <= ~1 GB -> below-minimum, <= ~3 GB -> baseline, ~4.4-10 GB -> workstation, > ~12 GB or needing vision/MTP assistants -> USER-ONLY. | file size, tier, ESTIMATE of RAM/VRAM | USER-ONLY |
| G6 | **Deterministic typed protocol compatible with the Jev shape** (`noul` probability, `choice` with probabilities, `score` expected level over 2-10 levels, answers read from logits, no generation). Documented prompt/readout contract (lettered options, special tokens, heads, per-type temperatures) that our adapter can implement without the vendor package. | card section or file in the repo; list of required tensors/head; max options | USER-ONLY (contract only in a vendor package) |
| G7 | **Safe supply chain.** No pickle load (`.pt/.bin/.pkl/.npz`) on the path we execute; no `trust_remote_code`; no vendor code executed by llmctl; only the files in the pin are fetched. Repos that *contain* pickles (Kev `head.pt`, lev `mode_b_head.pt`, NLI `training_args.bin`) are allowed only if the pin lists explicit files and excludes them. | siblings listing with extensions | REJECT/USER-ONLY |
| G8 | **Provenance and name-collision check.** Confirm owner identity (HF org / GH repo link both ways), and that the PyPI/npm names exist and mean the model (`kev`, `winnow` collide). Card claims labelled VENDOR-CLAIM (FR-052). | cross-link evidence | NOT-FOUND/REJECT |
| G9 | **Known-issues sweep**: search upstream issue trackers for the architecture and the quantization (e.g. llama.cpp #30064, #30073). An open correctness bug on the exact file blocks admission until a real run on our host proves it absent. | issue ids | HOLD |
| G10 | **Real-run on our host** (FR-007): model loads in the pinned engine, deterministic answers on the fixed typed prompts (yes/no, choose-one, rate-on-scale), probabilities sum to 1, repeated runs identical, option-count limit exercised. | captured outputs | no ship |

Additions to the proposal: G2 (immutability + re-verify at release), G7 (explicit file list so pickle-bearing repos can still be admitted), G8 (name collisions), G9 (open-bug sweep), and the explicit rule that weights licence overrides code licence.

## 5. Per-candidate sections

### 5.1 ADMIT-CANDIDATE, native `/v1/systemone` path (needs llama.cpp >= b11361)

Protocol (VENDOR-CLAIM from upstream README of `tools/server`, read at tag b11361): `POST /v1/systemone` with `state` (string/object/array), optional `images`, and `questions` keyed by id, each `{type: choice|score|noul, instructions, criteria}`; `choice` options up to 52 (openjev) / 255 (laya); `score` takes 2-10 level descriptions; response `answers` with `choice`+`probabilities`+`confidence`, `score`+`legend`+`probabilities`, or `noul` probability; `usage.output_tokens` always 0; errors 400 (invalid) / 501 (not a decision model or image unsupported). Probabilities use temperatures stored in the model file. Selected by GGUF key `{arch}.decision.type` (`kev`, `laya`, `lev`, `openjev`, `clef`, `nimble`, `strands`, `gliner`).

Catalog fields (all `engine: llama`, files from the ggml-org converted repos; `capability: ["decide"]`; ports: 8097 is spare, new profiles need 8100+, to be decided in the plan; defaults for the six pins are ctx 8192 / ngl 99 / parallel 2 / flash_attn auto / kv q8_0 - for native decision models the server batch size must be >= the prompt length, see #30073, `-b`/`-ub` value UNCONFIRMED and part of real-run work):

**Kev-4B** (`decide-kev`)
```json
{"hf_repo":"ggml-org/Kev-4B-GGUF","hf_revision":"d924f2e2c3872da8b8aaf3eb4453b4126deceb79",
 "license":"apache-2.0","min_tier":"baseline",
 "files":[{"name":"Kev-4B-Q4_K_M.gguf","size":3033489824,"sha256":"33ae6b18926502b2209a1bf7d3b61a350d65938441515c686bb87d226a19eff9","role":"model"}],
 "alt_files":[{"name":"Kev-4B-Q8_0.gguf","size":4483801504,"sha256":"7c2ebed90560522c2801389db482ac1dc4c36d828f201f6074c1d60e433948da"}]}
```
Owner ggml-org (conversion of jaredpalmer/kev-4b, Qwen3.5-4B-Base + LoRA r16 + pointer head, T=2.41). GGUF `qwen35`, ctx 262,144, `decision_type: kev`. Expected RAM ~3.7-4.5 GB (ESTIMATE). Upstream card VENDOR-CLAIM: held-out index 38.0; Kev-4B 0.817/0.838 on listed sets; validated context 8,192 (trained on states <= 7,552 tokens). Issue #30064 states Kev-4B Q8_0 is correct (reporter, not ours). Upstream `head.pt` (pickle) not used; the GGUF embeds the head.

**Kev-0.8B** (`decide-kev-tiny`): `ggml-org/Kev-0.8B-GGUF` rev `e551e319d483ff57e1ff208924b349d397cffc1c`; `Kev-0.8B-Q8_0.gguf` 812,406,304 B sha256 `27278f34eb3273bceea4c053dc50dd61a5161da21a718c4aacdf8fd5830771d0`; Apache-2.0; min_tier below-minimum; RAM ~1.1 GB (ESTIMATE). No Q4_K_M published.

**Kev-9B** (`decide-kev-pro`): `ggml-org/Kev-9B-GGUF` rev `ec2bbfe6620218aee2e01cc93bb78dee2a96ed58`; `Kev-9B-Q4_K_M.gguf` 6,358,923,744 B sha256 `86a6084984a6ef6818eb12c07cdc67ed3c47b00208d41a8816c64301bc6bcbda` (Q8_0: 9,529,735,648 B `d30b225bfdc985d1856bb04a990be76008d0cf40dccbf78938e3069744bc614c`); Apache-2.0; workstation; RAM ~7-8 GB (ESTIMATE).

**Laya** (`decide-laya`): `ggml-org/Laya-GGUF` rev `22265007700297ba9e128297e82540cf28c5d7d4`; `Laya-Q8_0.gguf` 449,397,600 B sha256 `c06528c5746d3bb8baa72a27938be95abbfd0b226f8471e8a9e365ed0bb066d2`; Apache-2.0; arch `modern-bert`, `decision_type: laya`, ctx 8192, non-causal encoder (421 M, upstream says ~33 ms/decision, VENDOR-CLAIM); min_tier below-minimum; RAM ~0.6 GB (ESTIMATE). Upstream default token budget 1,024 (card: "ships with a 1,024-token limit"; `laya-multilingual` supports 8,192 with `max_len`); `laya` is the English checkpoint, `laya-multilingual` is a separate repo with a community-only GGUF (`meshllm/laya-multilingual-F16-GGUF`, not examined). Laya open server issue #29902 (abort when a batch of questions exceeds `n_ubatch`) is closed.

**Julia 1** (`decide-julia`): `ggml-org/Julia-1-GGUF` rev `16fee17949206fbf58da9347daea44d792a81211`; `Julia-1-Q8_0.gguf` 168,166,496 B sha256 `1ea6a7e87156eeeda88cb7a36a61265b37ba7b993897b7289b99aea5b5e47069`; Apache-2.0; arch `modern-bert`, `decision_type: laya`, ctx 8192; 144 M, base `jhu-clsp/mmBERT-small`; min_tier below-minimum; RAM ~0.3 GB (ESTIMATE). VENDOR-CLAIM: typed decisions 73.15% (1,463/2,000, H200 BF16) vs a "Jev reference" 72.70%; MASSIVE 52 locales 71.50%; Banking77 pilot 64% vs 87% (own card).

**lev** (`decide-lev`): `ggml-org/lev-GGUF` rev `3e9286a79ae857b4e1de051c92fab6dc574581ce`; `lev-Q4_K_M.gguf` 3,011,777,440 B sha256 `3f61b27c00a098dbc79ed099cca3985cbe0b63d17ac7fedebf2dca1d84f7f3a8` (Q8_0 4,482,405,280 B `c6b70833a9ec59c67bda2940f4047c2e1bdc066b4a6f8aec3c36d62b6ea34eef`); Apache-2.0; owner interfaze-ai (Qwen3.5-4B + LoRA); `decision_type: lev`; baseline; RAM ~3.7 GB (ESTIMATE). VENDOR-CLAIM: 68.9% on all 13 S1Bench subsets. Upstream `mode_b_head.pt` is a pickle; the GGUF embeds the head.

Shared caveats: all depend on the engine bump; probabilities "not guaranteed to be calibrated for your data" (llama.cpp docs); Clef-style Q8_0 head-quantization defect (#30064) is a reminder that each quantization of a head must be checked on our host (G9/G10); benchmark numbers above are VENDOR-CLAIM and must not appear as facts (FR-052).

### 5.2 ADMIT-CANDIDATE, letter-logit path (works on the current pin)

**Mapika/decider-2b-GGUF** (`decide-2b` alternative, v11): rev `ff2e5e687327eda9ac34e9a3ca84d3f400672c87`, Apache-2.0, base Qwen3.5-2B-Base; `decider-2b-v11-Q4_K_M.gguf` 1,274,396,800 B sha256 `b7c132a67934d51c81abc96bb7724800f965ff5a288aed3e1ca7d8bc349c1386`; Q8_0 2,012,012,672 B `3657848acb4851da4465ab4abad7c6fe273c7e1f15e83629cd6da972a5282cb3`; also needs `decider_config.json` (1,240 B) and `tokenizer.json` (19,989,325 B sha256 `06b9509352d2af50381ab2247e083b80d32d5c0aba91c272ca9ff729b6a0e523`) (non-LFS config sha256 must be computed). Same readout, same "one prompt per decode" caveat as P2. min_tier baseline; RAM ~1.6-2.6 GB (ESTIMATE). Redundant in size with P5a; admit only if it passes the same real-run as P2 and adds measurable value (FR-007 says admit if it passes; no cap).

**APUS-OpenJev-v1-4B-GGUF** (`decide-apus`): `apus-ailab/APUS-OpenJev-v1-4B-GGUF` rev `7389d774472c9e29ddc84fffb392951f0f25de74` (2026-09-23), Apache-2.0, base Qwen/Qwen3.5-4B; `APUS-OpenJev-v1-4B-Q8_0.gguf` 4,482,403,168 B sha256 `5e57075a169a76de5150f5c5defd805525ce4df86ae8865f70f128e15e57416c`; Q4_K_M 2,708,804,768 B `3e77f041b48a6b28081071dc4dca8b047c10acf0a4b9b9b48603cef6b06ee186`; Contract file `openjev_contracts.py` plus `examples/openjev_local.py` in the repo; card says disable thinking, uses llama-server logprobs, and Ollama top-20 limit. VENDOR-CLAIM: Frozen80 66/80 (82.5%) BF16 with own prompt tokens. Conditional admit: protocol is documented but the adapter is another contract to implement and test; workstation tier by size 4.5 GB, or baseline for Q4_K_M. The 9B and 35B-A3B GGUFs exist but are over the ordinary-host line.

(P1-P5b catalog fields: unchanged from the existing catalog, verified in Section 3.)

### 5.3 USER-INSTALLABLE-ONLY (with reason)

- **Verdict 151 M** `heman10x/rlcd-modernbert-151m` rev `8af2496eb63c…` (full sha in `hf` metadata; 2026-09-20): Apache-2.0 on HF, ONNX fp32 606,323,181 B sha `4ae01f822538b000…`, fp16 303,785,047 B, safetensors 605,529,340 B; base `knowledgator/gliclass-modern-base-v2.0`, 151,378,177 params; 25 option slots (24 + abstention); T=1.0716. Requires the vendor SDK's pre/post-processing (`__insufficient_evidence__` slot, prompt packing); contract not independently documented; GH `LICENSE` reads NOASSERTION on the API while the badge says Apache-2.0 - resolve before any redistribution. VENDOR-CLAIM: "<35 ms", beats Laya/Jev on LocalLLaMA/typed-decisions. Could be upgraded to ADMIT-CANDIDATE after the I/O contract is read from source (UNCONFIRMED).
- **verdictml / Manav2op/verdict-small** (118 M, e5-small based, ONNX int8 118,070,929 B): requires `torch` + `transformers` or `onnxruntime` + `tokenizers`, "fit on your labels" heads; different project from the 151 M. Apache-2.0.
- **Laya third-party formats** (`mys/laya-typed-decisions-GGUF` arch `ggmlc` needs custom ggml; `ti3x-m/laya-typed-decisions-onnx` 1.69 GB external data): not the upstream engine path; use ggml-org Laya instead.
- **local-jev**: MIT harness, "research project, not a finished product"; its `nli-deberta-large` = `cross-encoder/nli-deberta-v3-large` (Apache-2.0, `onnx/model.onnx` 1,742,010,231 B sha `522031148bd5696c…`; repo also holds `pytorch_model.bin`); redundant with P4. `llm-qwen3.5-4b` = generic Qwen3.5-4B zero-shot letters - not a decision-trained model.
- **Strands Decider 2B** v19/v21: PEFT LoRA on Qwen3.5-2B-Base (official `StrandsAgents` org, Apache-2.0); only third-party GGUF (`fabricant451`, 2.0 GB, `decision_type: strands`) says it needs a "custom Strands-aware llama.cpp/wllama runtime". VENDOR-CLAIM: v21 JevBench public 176/231. 
- **NeoHorse-Jev-4B** (Apache-2.0): GGUF Q4_K_M 3,394,729,184 B sha `d2d81e946be2f44954f7183572abe66558a5d3d7510cc710c874f7e90f5edce7` includes backbone + vision + head, but its card says to use the bundled `runtime/` (llama.cpp-based decision adapter built by `runtime/build.py`); VENDOR-CLAIM aggregate 77.70. Admission would need a vendored build, not a catalog pin.
- **opendecider** (nano 400 M `ettin-encoder` ONNX, small 4 B `qwen3` GGUF Q4_K_M 2,497,278,848 B sha `039b057d…`): Apache-2.0, 4.0.x PyPI; prompt/readout contract lives in the `opendecider` package; UNCONFIRMED whether it can be reproduced from the card alone. Could be re-evaluated.
- **GLiNER2.5-Decide**: official `fastino/GLiNER2.5-Decide` is safetensors for the `gliner2` package; `3ntr0py-t4m3r` GGUF (`deberta-v3` arch, `decision_type: gliner`) ships a patch (`0001-deberta-v3-upstream-port.mbox`): no upstream llama.cpp support found (issue search: only closed #6427).
- **Winnow-12B / E4B** (Apache-2.0, Gemma-4 12B/E4B + MTP assistant): GGUF Q8_0 12,669,646,592 B / 8,005,437,472 B; needs the vendor launcher `EldanRing/winnow-inference` (MIT), 64K context + vision; no `decision_type` key in the main-file metadata that the API returned (UNCONFIRMED). VENDOR-CLAIM: JevBench public subset 85.28% BF16 / 85.71% Q8.
- **typecastlm** (`mihailgribov/typecastlm-qwen3.5-3.8b`, Apache-2.0): Q8_0 GGUF 4,007,900,672 B in the HF repo plus `reader.py`; client-library readout (`noul`/`tfu`/choice); VENDOR-CLAIM place 30 on the JevBench open-weights board (composite 19.7, capability 56.5, for 1.3.0).
- **Clef-Flash** `ggml-org/Clef-Flash-GGUF` rev `4a192915ef971886004b5b13294f2b4c7a7fc39d` (Apache-2.0, base Qwen3.5-9B + joint schema head, multimodal, 9.1 B): needs b11371+, 9B; Q4_K_M 6,486,448,288 B and Q8_0 9,657,260,192 B are the files exposed; **open bug #30064 reports Q8_0 collapse toward uniform with BF16 correct; a head-preserving quantization recipe is proposed in the thread** (VENDOR/third-party). HOLD until fixed upstream and re-verified on our host. Clef 27B (`ggml-org/Clef-GGUF`, 19.2 GB Q4_K_M) is over the ordinary-host line.
- **CLM**: GH Apache-2.0; needs a Qwen3-8B embedding server plus a 75 MB head - two processes, no single artifact.
- **fern** (`reoring/fern`): Apache-2.0, 4 B, safetensors only, card says distilled from a hosted frontier model; teacher-output terms not reviewed here; no GGUF.
- **Mapika decider 0.8b/12b**: safetensors only (no GGUF found); decider-12b is Gemma-4-12B-it based.
- **Kev 27B / pplx-decider 27B / autotrust JEV-9B,27B**: Apache-2.0, safetensors for vLLM-style serving, no GGUF; above ordinary-host tier.

### 5.4 REJECT (reason)

| Item | Reason (PRIMARY-FACT) |
|---|---|
| OpenJev (`openjev/openjev`, `ggml-org/OpenJev-GGUF`, `openjev/openjev-GGUF`) | weights `cc-by-nc-4.0` (the card says helper/serve code is Apache-2.0 and the base is Apache-2.0, but the model weights are NC); 27 B |
| Bespoke-Nimble-9B-v3 | `cc-by-nc-4.0` |
| StartLux-Decision (all sizes) | HF weights `cc-by-nc-4.0` (GH code Apache-2.0; confirms source-findings H) |
| jev-at-home / `jevhome/*` | `cc-by-nc-4.0` weights (GH code MIT) |
| bev-decider-0.4B | `cc-by-nc-4.0` |
| kestrel-decider-230m | licence `other` with no text resolved |
| kev-onnx | npm package NOT-FOUND; HF ONNX repo lists base as `Qwen3-4B-Base` (mismatch with Kev's Qwen3.5-4B-Base), q4/q4f16 only, no documented onnxruntime contract |
| RSI-Jev (shgao) | custom architecture code (`rsijev`), vision tower, 0 downloads |
| djev (DiffusionGemma + vLLM) | unsupported runtime |
| SemIf, poorjev, AnyJev, EdgeJev | no first-party weights: harnesses, wrappers or converters |
| Open-Jev LoRAs (`ZefanCai/*`, `IamBusy/OpenJev-0.6B`, `v6543210/openJev-1.5B`) | adapter-only, near-zero adoption |
| Verdict 2.0 HF repo | NOT-FOUND (401) |
| decider-35b-a3b-nvfp4 | NVFP4/MoE format outside supported runtimes (not examined in detail) |

## 6. Counts (distinct artifacts evaluated; each pinned profile counted once)

- Candidate names in the brief: 41. **Resolved to an existing primary artifact: 39. NOT-FOUND (the specific named artifact): 3** - npm `kev-onnx`, HF "Verdict 2.0", an HF-hosted weights repo for CLM (unresolved, not proven absent). PyPI names `kev`, `winnow`, `openjev` exist but point at other things (name collisions).
- Pinned six profiles: 6/6 still ADMIT-CANDIDATE, **0 pin mismatches**.
- Additional ADMIT-CANDIDATE (paper pass): Kev-0.8B, Kev-4B, Kev-9B, Laya, Julia-1, lev (all need engine bump), Mapika decider-2b v11, APUS-OpenJev-4B = **8**. Total ADMIT-CANDIDATE = **14**.
- USER-ONLY: ~19 (Verdict 151M, verdictml, Laya third-party, local-jev NLI, Strands, NeoHorse, opendecider x2, GLiNER2.5-Decide, Winnow x2, typecastlm, Clef-Flash (hold), Clef 27B, CLM, fern, decider 0.8b/12b, large 27B Apache models).
- REJECT: ~14 (NC weights: OpenJev, Nimble, StartLux, jevhome, bev; no weights: SemIf, poorjev, AnyJev, EdgeJev; kev-onnx, RSI-Jev, djev, LoRA-only, kestrel).

## 7. What the spec/plan should take from this

1. **Engine pin bump decision** (FR-007 turns on it): native path candidates need llama.cpp >= b11361 (Clef b11371). Bumping from b10969 affects every existing profile and the colibri/llama integration; needs its own regression gate. Alternative is shipping only the 6+2 letter-logit candidates on the current pin and registering the native-path ones as "pending engine bump" with a reason - FR-007 says evidence governs.
2. **Protocol adapters differ**: P1 needs the `jev_score.cpp` scorer (or re-implementation from `readout_config.json`); P2/decider-2b "score one prompt per decode"; P3 plain letters; native models use `/v1/systemone` (a stable-looking spec in llama.cpp docs; also Ollama >= 0.35.1 has its own variant, not the same). Each adapter is a candidate for the "bring your own export" layer (FR-008) if not shipped.
3. **Replace `sha256: null`** for NLI small files with the Section 3 values.
4. **Record weights-licence vs code-licence** in the candidate register; four otherwise attractive families have NC weights.
5. Treat all benchmark figures (JevBench, S1Bench, Frozen80, Banking77, typed-decisions) as VENDOR-CLAIM and cite the board `benchmarkheaven.com/jev-models` only as a pointer: I did not fetch it (the typecastlm card is the only secondary mention retrieved).
6. Watch #30064/#30073 and re-run this table before release; upstream moves daily (many repos were created 2026-09-18 .. 2026-10-05).

## 8. Sources (retrieval date 2026-10-07 for all)

HF API (metadata): `https://huggingface.co/api/models/<repo>?blobs=true` for chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF, Mapika/decider-4b-GGUF, Mapika/decider-4b, Mapika/decider-2b, Mapika/decider-2b-GGUF, Mapika/decider-0.8b, Mapika/decider-12b, rizzoaiacademy/rizzo-flow, MoritzLaurer/deberta-v3-large-zeroshot-v2.0, alibiserikbay/JevK5-GGUF, jaredpalmer/kev-4b, kev-9b, kev-0.8b, kev-27b, ggml-org/Kev-4B-GGUF, Kev-9B-GGUF, Kev-0.8B-GGUF, Laya-GGUF, Julia-1-GGUF, lev-GGUF, OpenJev-GGUF, Clef-GGUF, Clef-Flash-GGUF, Bespoke-Nimble-9B-v3-GGUF, onnx-community/kev-4b-ONNX, DreamBlooms/kev-4b-GGUF, convaiinnovations/laya, laya-typed-decisions, mys/laya-typed-decisions-GGUF, ti3x-m/laya-typed-decisions-onnx, SupersonicLabs/Julia-1, openjev/openjev, openjev/openjev-GGUF, interfaze-ai/lev, Cloudflare/clef, Cloudflare/clef-flash, bespokelabs/Bespoke-Nimble-9B-v3, heman10x/rlcd-modernbert-151m, heman10x/openJev-verdict-2.0 (401), Manav2op/verdict-small, StrandsAgents/strands-decider-2B-hobson-v19 and -v21, fabricant451/strands-decider-2B-hobson-v19-GGUF, onnx-community/strands-decider-2B-hobson-v19-ONNX, TokenRhythm/NeoHorse-Jev-4B and -GGUF, apus-ailab/APUS-OpenJev-v1-4B and -GGUF, manjunathshiva/opendecider-nano, -small, -small-GGUF, -small-td-GGUF, -nano-ONNX, fastino/GLiNER2.5-Decide and -1B, 3ntr0py-t4m3r/GLiNER2.5-Decide-GGUF, onnx-community/GLiNER2.5-Decide-mobile-ONNX, shgao/rsi-jev-v1.0-qwen3.5-2b, reoring/fern, EldanRing/Winnow-12B and -E4B, mihailgribov/typecastlm-qwen3.5-3.8b, startlux-models/StartLux-Decision-{0.8B-Q8_0-GGUF,2B,4B-Q8_0-GGUF,9B-Q4_K_M-GGUF,27B}, jevhome/jevhome-{B,L,E,B-int8,ettin-1b}, com-kotobalabs/open-jev-deberta-v3-large, onnx-community/open-jev-deberta-v3-large-ONNX, ZefanCai/Open-Jev-2B and -9B, IamBusy/OpenJev-0.6B, v6543210/openJev-1.5B, Kestrelyn/kestrel-decider-230m, avbiswas/bev-decider-0.4B, perplexity-ai/pplx-decider-v1-27b, autotrust/JEV-9B, Meanblock/JEV-CPU, cross-encoder/nli-deberta-v3-large.
HF search: `https://huggingface.co/api/models?search=<term>` for jev, kev-4b, verdict(ml), laya, local-jev, decider, strands decider, neohorse, semif, poorjev, open-jev, opendecider, djev, gliner2.5, rsi-jev, winnow, anyjev, startlux, edgejev, typecast, typed-decisions, decision-model, lev, julia-1, fern, apus, Heman10x, Manav2op, Contrastive-LM, author=ggml-org listing.
HF cards (README text): the repos above; also `https://huggingface.co/Mapika/decider-4b-GGUF/resolve/main/decider_config.json`, `https://huggingface.co/apus-ailab/APUS-OpenJev-v1-4B-GGUF/resolve/main/README.md`, `https://huggingface.co/3ntr0py-t4m3r/GLiNER2.5-Decide-GGUF/resolve/main/README.md`.
Pinned-file bodies fetched (tokenizer/config only): `https://huggingface.co/MoritzLaurer/deberta-v3-large-zeroshot-v2.0/resolve/cf44676c28ba7312e5c5f8f8d2c22b3e0c9cdae2/{config.json,tokenizer_config.json,tokenizer.json}`.
GitHub: ggml-org/llama.cpp PRs #29818, #29831, #29997 and issues #30064, #30073, #29902, #29832, tags b10969/b11361/b11371/b11471, release v0.6.0, `tools/server/README.md` at tag b11361 (`https://raw.githubusercontent.com/ggml-org/llama.cpp/b11361/tools/server/README.md`); jaredpalmer/kev (README, releases); amithgc/local-jev (+ `src/local_jev/models.py` listing); lawrence3699/jev-style; Rizzo-AI-Academy/rizzo-flow; EldanRing/winnow-inference (QUICKSTART); jev-skills/openjev-multimodal; rupeshpoojary9/poorjev; yzfly/edgejev (README, LICENSE); TheoLeeCJ/SemIf-OpenJev; Manavarya09/verdict; Heman10x-NGU/openJev-verdict-2.0 and Verdict-open-jev; nokia-applied-research/AnyJev; razorback16/openjev; mmastrac/djev; StartLuxLabs/StartLux-Decision; Jibril-Frej/jev-at-home; mihail-gribov/typecastlm; Contrastive-LM/CLM; tak-bro/local-jev-bench; reoring/fern; TianyuCodings/NanoJev; GitHub repository searches for poorjev, edgejev, jev-at-home, typecastlm, verdictml, semif, anyjev, open-jev, djev, fern, CLM, StartLux.
PyPI JSON `https://pypi.org/pypi/<name>/json`: verdictml, kev, laya, jev-style, decider-ai, poorjev, edgejev, typecastlm, anyjev, opendecider, openjev, gliner2, winnow (and 404s for rizzo-flow, local-jev, neohorse-decision, julia-decision, semif, winnow-inference, jevhome, verdict-ml, kev-decision). npm registry `https://registry.npmjs.org/kev-onnx` (404).
Local: `/home/milosvasic/Projects/jev/llmctl/llmctl/models/catalog.json`, `/home/milosvasic/Projects/llmctl/submodules/llama.cpp` (tag b10969, `src/llama-arch.cpp`).
Not fetched (stated, not claimed): `benchmarkheaven.com/jev-models`, `docs.typesafe.ai/api`, the Notion/blog posts, and the three source-research docs under `jev/llmctl/llmctl/docs/research/` beyond `decision-model-hashes.md` (first 120 lines).
