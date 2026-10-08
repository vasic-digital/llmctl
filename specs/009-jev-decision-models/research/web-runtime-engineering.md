# Runtime engineering research: llama.cpp serving, ONNX encoder serving, decision readout, gateway, multi-instance

| Field | Value |
|---|---|
| Date | 2026-10-07 |
| Spec | `specs/009-jev-decision-models/spec.md` (FR-064..073, D-01..D-31) |
| Method | Local source reads (pinned submodule, candidate code), live PyPI JSON queries from this host, 30+ web searches and fetches |
| Marking | **FACT(file:line / URL)** = observed this session. **INFERRED** = my reading, not tested. **UNTESTED** = needs a real run (no model download was allowed). |
| Host facts | Linux x86_64, Python 3.14.4, OpenSSL 3 headers installed, no `pip` on PATH, no macOS arm64 machine available |

## 0. Direct answers (read this first)

1. **Does our pinned llama.cpp build serve HTTPS? Yes, it is compiled in on this host; a real HTTPS handshake was NOT exercised (no model was available to start the server).**
   - Evidence the capability is in the build:
     - `submodules/llama.cpp/CMakeLists.txt:144` `option(LLAMA_OPENSSL "llama: use openssl to support HTTPS" ON)`, default ON.
     - `vendor/cpp-httplib/CMakeLists.txt:128-148` runs `find_package(OpenSSL)`, requires OpenSSL >= 3.0 (`0x30000000L`) and then sets `CPPHTTPLIB_OPENSSL_SUPPORT`.
     - `lib/engine.sh:63-92` passes only `-DCMAKE_BUILD_TYPE=Release` plus a GPU flag. It neither enables nor disables SSL, so the upstream default applies.
     - The existing build tree has `LLAMA_OPENSSL:BOOL=ON` and `OPENSSL_SSL_LIBRARY=/usr/lib/x86_64-linux-gnu/libssl.so` (`submodules/llama.cpp/build/CMakeCache.txt`).
     - `ldd` shows `libllama-common.so` and `libllama-server-impl.so` link `libssl.so.3` and `libcrypto.so.3`. `llama-server` itself is a 17,872-byte stub that loads those libraries, so the server code that creates `httplib::SSLServer` links libssl.
   - Code path: `tools/server/server-http.cpp:106-125` creates `httplib::SSLServer(cert, key)` when **both** `--ssl-cert-file` and `--ssl-key-file` are set. If the binary was built without OpenSSL and both flags are given it logs "the server is built without SSL support" and returns false. Minimum protocol is TLS 1.2 (`vendor/cpp-httplib/httplib.cpp:14412`).
   - **Silent-degradation risk (FACT):** if OpenSSL dev files are missing, CMake prints only a `WARNING` and the build still succeeds without HTTPS (`vendor/cpp-httplib/CMakeLists.txt:~150`; `docs/build.md:91` says "the project will build and run without SSL support"). Nothing in `engine.sh` or `doctor.sh` checks this today. **Recommendation for FR-072:** after the build, assert `ldd <bin dir>/libllama-common.so | grep -q libssl` (Linux) or `otool -L` (macOS) and record it; make `llmctl doctor` and `llmctl build` fail loudly or record "no HTTPS" when absent. Then do the runtime test (start a tiny GGUF with `--ssl-*`, `openssl s_client`, `curl --cacert`) in the US3 real-model task.
   - macOS: **INFERRED** that Homebrew OpenSSL is not on the default CMake search path, so a stock build may silently lack HTTPS. Needs `OPENSSL_ROOT_DIR` or `brew --prefix openssl@3`. UNTESTED.
2. **Version discrepancy to record:** the submodule describes as tag-based `b10969` (commit `391fac16`, 2026-09-14), and `llama-server --version` prints `0.4.1-dev (build 10969)`, not `v0.4.0`. Spec text should cite the build number or commit, not "v0.4.0".
3. **Python 3.14 wheels exist for everything the encoder needs, on both Linux x86_64 and macOS arm64 (section B.3 has exact filenames and sha256).**
4. **DeBERTa-v3 is not supported by the pinned llama.cpp** (no `deberta` match in `convert_hf_to_gguf.py` or `src/llama-arch.cpp`; only BERT-family archs: bert, modern-bert, nomic-bert, neo-bert, jina-bert, eurobert). So the encoder profile cannot move to llama.cpp without changing the model.

---

## A. llama.cpp serving of decision profiles

### A.1 Flags and behaviour in the pinned version

All from `submodules/llama.cpp` at `391fac16` unless a URL is given. Verified by `llama-server --help` from the built binary where noted.

| Item | Behaviour | Evidence |
|---|---|---|
| `--api-key KEY` | Comma-separated list; env `LLAMA_API_KEY`. **Visible in `ps` if passed on argv** (D-03). | `common/arg.cpp:3478-3487`, binary `--help` |
| `--api-key-file FNAME` | One key per line, `#` comments, env `LLAMA_ARG_API_KEY_FILE`. **Use this (file mode 0600) or the env var, never `--api-key`.** | `common/arg.cpp:3489-3505` |
| Auth middleware | Accepts `Authorization: Bearer <key>` or `X-Api-Key`. Only `/health`, `/v1/health` and embedded UI assets are public. `/props`, `/slots`, `/metrics`, `/v1/models` need the key. Comparison is `std::find` on strings (not constant time). | `tools/server/server-http.cpp:197-231` |
| `--ssl-cert-file`, `--ssl-key-file` | PEM, env `LLAMA_ARG_SSL_CERT_FILE` / `_KEY_FILE`. Both required. TLS >= 1.2. | `arg.cpp:3507-3520`, `server-http.cpp:106-125` |
| `--host` | Upstream default `127.0.0.1`; ends with `.sock` means **UNIX domain socket**. llmctl overrides via `catalog_bind_host` (`scheduler.sh:271`). | `--help`, `lib/scheduler.sh:271` |
| `--metrics` | Off by default; Prometheus endpoint. Env `LLAMA_ARG_ENDPOINT_METRICS`. | `arg.cpp:3579` |
| `--props` | Off by default; enables **POST** `/props` (mutation). GET `/props` is always served. Leave off. | `arg.cpp:3586`, `server.cpp:249-250` |
| `--slots` / `--no-slots` | On by default; `GET /slots` shows per-slot state, good for a least-loaded balancer. `?fail_on_no_slot=1` returns 503 when all busy (README ~978). | `arg.cpp:3593`, README |
| `--no-webui` / `--no-ui` | Disable embedded UI. Use for decision/engine servers. | `arg.cpp:3457` |
| `-np / --parallel N` | Slots; default -1 = auto. `--kv-unified` is on when slots are auto; `--kv-unified-per-slot N` sizes the pool as `n_parallel*N`. | README 164-168, `arg.cpp:2541` |
| `-cb` | Continuous batching on by default. | `--help` |
| `--threads-http N` | HTTP worker threads. Default per mirror docs: `max(hardware_concurrency-1, parallel+2)` (web, not re-verified in code). | `arg.cpp`, https://cdn04132025.gitlink.org.cn/replica/llama.cpp/commit/8ef969afcec1645d2d9c3ab1fc82263bba968989 |
| `-to/--timeout` | Server read/write timeout, seconds. | `arg.cpp:3541` |
| `GET /health` | 200 `{"status":"ok"}`, 503 while loading; **no key needed**. | README 470-480 |
| `/v1/chat/completions` logprobs | `logprobs:true` sets `n_probs = top_logprobs` (default 20 when omitted). `top_logprobs` without `logprobs` is a 400. | `tools/server/server-common.cpp:1403-1411` |
| `/completion` | `n_probs`, `post_sampling_probs`, `logit_bias`, `grammar`, `json_schema`, `samplers`, `cache_prompt`, `id_slot`. | README 569-599 |
| `/tokenize`, `/apply-template`, `/v1/embeddings`, `/v1/rerank` (+ `/rerank`, `/reranking`, `/v1/reranking`) | Present. | `tools/server/server.cpp:253-285` |

Concrete consequences:

- **Engine port (FR-073).** Two options: (a) bind `127.0.0.1` with `--host 127.0.0.1`, which is simple and testable from a second network location; (b) bind a UNIX socket (`--host /path/engine.sock`, mode 0600 in a 0700 directory), which removes the port entirely and needs file-permission rather than firewall reasoning. Option (b) is **INFERRED** workable: the candidate gateway uses `urllib`, which cannot dial a UNIX socket, so it would need an `http.client.HTTPConnection` subclass. Recommendation: ship (a) now, record (b) as hardening. Either way the engine should also get `--api-key-file` with a random per-start key, so another local user cannot use it.
- **No key on `/health`.** A status poller can use it, but it must not return profile names or model paths. llama.cpp returns only `{"status":"ok"}`, which is fine; the candidate gateway/onnx server health leaks more (D-04).
- **`--props` must stay off** (POST `/props` mutates global settings).
- **`--metrics`** is useful for decision-service observability (requests, tokens, slot usage) and is behind the key. UNTESTED which gauge names the pinned build emits; check with a live run.

### A.2 Extracting a typed decision from a decoder model: techniques compared

Candidate (`jev/llmctl/llmctl/lib/decide_gateway.py:121-170`, `decide.sh:189-275`): render a lettered prompt, call `/v1/chat/completions` with `max_tokens=1, temperature=0, logprobs:true, top_logprobs=max(n,5)`, read `choices[0].logprobs.top_logprobs[0]`, match `token.strip().upper()` to A..Z, softmax over the matched letters divided by a temperature, confidence `(n*p_max-1)/(n-1)`.

What the pinned server actually returns (FACT, code):

- With `logprobs:true` the probabilities are **pre-sampling** by default: `need_pre_sample_logits = n_probs > 0 && !post_sampling_probs` (`server-context.cpp:1790`). `populate_token_probs` then calls `get_token_probabilities(ctx, idx, n_probs)` (`server-context.cpp:1996`), i.e. a softmax over the **raw logits of the whole vocabulary** and the top-N of that. README 579: "for temperature < 0 [sic] ... token probabilities are still calculated via a simple softmax of the logits without considering any other sampler settings".
- INFERRED: because the readout is the raw-logit softmax, `logit_bias`, `grammar` and `temperature` in the request do **not** change the reported probabilities. This is good for a readout (you get the model's own distribution) and means those request fields are not a way to calibrate.
- `completion_token_output::logarithm` returns `lowest()` for p=0, never `-inf`/null (`server-task.cpp:~299`).
- `cache_prompt` defaults to **true** and the README warns this "can cause nondeterministic results" because logits are not bit-identical across batch sizes (README 587). For a decision service that promises repeatable probabilities, send `cache_prompt:false` or document tolerance.
- Chat endpoint applies the **chat template**. The first generated token may not be the answer letter (a "Sure"/"The answer" prefix, or a reasoning block). This is the exact failure measured by Wang et al., ACL Findings 2024: first-token readout and the actual text answer disagreed over 60% of the time for instruction-tuned models, even with constrained prompts (https://arxiv.org/abs/2402.14499, fetched 2026-10-07). **Implication:** first-token readout is valid only for models fine-tuned to emit the letter first. The candidate catalog's decision models are claimed to be such (vendor claims, unverified: source-findings D-06). It must be a per-profile property, checked by a smoke test that asserts p(letters) mass is high (see "mass guard" below).

| Technique | How | Accuracy / determinism | Cost | Failure modes |
|---|---|---|---|---|
| **1. First-token logprob readout (candidate)** | 1 call, `max_tokens=1`, `n_probs`, restrict to letter tokens | Best when model was trained to emit the letter first; deterministic apart from `cache_prompt`/batching jitter. Multiple-choice symbol binding works well only for models with high MCSB ability (Robinson & Wingate, ICLR 2023, https://arxiv.org/abs/2210.12353) | 1 forward pass over prompt + 1 token | Leading-space token (" A" vs "A"); letter outside top-N; mass leaks to non-letter tokens; chat-template prefix; selection bias toward certain letters (Zheng et al., ICLR 2024, https://arxiv.org/abs/2309.03882) |
| **2. Grammar-constrained single letter** (`grammar` or `json_schema` with `enum`) | Sampler masks to allowed tokens, then sample | Returns a *valid* letter always, but gives a *sample*, not a probability, unless you also read `n_probs` (which is pre-sampling and unaffected). Adds nothing to calibration | Same + grammar cost | False sense of validity: a forced letter hides the case where the model wanted to say something else. Use only for text-answer fallback, not as the probability source |
| **3. Score each option's likelihood (cloze)** | N prompts, sum logprob of each option text | Robust to letter bias; suffers "surface form competition" (Holtzman et al., EMNLP 2021, https://arxiv.org/abs/2104.08315; mitigated with PMI_DC, which costs 2x passes) | N passes (or N with shared prefix cache) | Length bias, option-text tokenisation, ~N-fold latency. No built-in llama-server API for scoring a continuation: INFERRED you must use `/completion` with `n_predict:0`+prompt-logprobs-like trick, which this version doesn't expose → UNTESTED |
| **4. `logit_bias` restricted to option tokens** | Bias all non-option tokens to `-inf` | Forces the *sampled* token into the set, but the **reported n_probs stay pre-sampling** (see above), so it doesn't renormalise what you read. Only useful for generating text | Free | Same tokenisation traps; token IDs need `/tokenize` per model |
| **5. `/v1/rerank` or `/v1/embeddings`** | Cross-encoder/bi-encoder | Only for rerank-head models (`--pooling rank`); wrong tool for a generative decider | Cheap | Needs a rank-capable GGUF; none of the catalog deciders are |
| **6. Permutation averaging / PriDe** | Run k permutations of option order, average per-option probabilities (or estimate the letter prior once and subtract) | Removes much of the letter bias. PriDe estimates the prior on a small subset, then debiases the rest, "high computational efficiency" (https://arxiv.org/abs/2309.03882) | k passes (full averaging) or ~1 + small calibration (PriDe) | Prefix cache helps only for the shared stem; must unpermute |
| **7. Contextual calibration** | Score a content-free input (`"N/A"`) with the same prompt and divide by that bias | Cheap prior estimate (Zhao et al., ICML 2021, https://arxiv.org/abs/2102.09690) | +1 call per prompt template (cacheable) | Prompt-template-specific; recompute when template or options change |

**Recommendation (A.2):**

1. Keep technique 1 as the primary path, with `cache_prompt:false`, `n_probs` large enough to normally include every option letter (start at 32; the cost is a vocabulary sort, small next to the forward pass; measure), and **three guards**:
   - **Mass guard:** `mass = sum(p of all letter-like tokens)`. If `mass < threshold` (consumer data, start 0.5) return a typed "no confident decision" result rather than a renormalised guess. This replaces "absent letters get p=0" (`decide_gateway.py:152-163`), which silently turns "the model did not answer with a letter" into a confident-looking distribution.
   - **Missing-letter guard:** if an option's letter is not in the top-N, report an *upper bound* (the smallest reported p) and mark `letters_missing`, instead of p=0.
   - **Tokenisation guard:** accept all spellings (`A`, ` A`, `a`, ` a`), take the **sum of probabilities** (log-sum-exp of logprobs), not the max (`decide_gateway.py:152-155` takes the max). Mind the Gap (EMNLP 2025) found up to 11% accuracy difference depending on whether the space is tokenised with the letter, and that tokenising " A" as one unit improved accuracy and calibration (https://arxiv.org/abs/2509.15020). Therefore build the prompt so the space belongs to the letter token for that tokenizer, and verify per model with `/tokenize` at profile-validation time.
2. Offer **order-bias mitigation as an opt-in per request** ("cyclic permutations", k=2..n) and make the default off, documenting the k-fold latency. PriDe-style prior estimation is the cheap alternative once labeled data exist.
3. **Calibration from user labels, cheaply** (answers "temperature/calibration methods"):
   - **Temperature scaling** (one parameter, fitted by minimising NLL on a held-out set; resistant to overfitting on small sets; Guo et al., ICML 2017, https://proceedings.mlr.press/v70/guo17a.html). The candidate's `LLMCTL_DECIDE_TEMPERATURE` multiplier is exactly this, but it divides **logprobs** of the matched letters, which equals temperature-scaling restricted to the options only if all option logits are included. Fit on `log p_i` over options, which is a faithful subset.
   - **Platt (sigmoid, 2 params)** for binary `noul` questions when n is in the tens to hundreds.
   - **Isotonic regression** only with large sets: scikit-learn's guidance is that it overfits with <<1000 calibration samples and Platt should be used instead (https://scikit-learn.org/1.3/modules/generated/sklearn.calibration.CalibratedClassifierCV.html).
   - Store `{profile, model_revision, prompt_template_hash, method, params, n_samples, fitted_at}` and refuse to apply a calibration whose `model_revision` or `template_hash` differs.

Alternatives considered: grammar-only (rejected as source of probabilities), cloze scoring (rejected as default: N passes and no clean server API), reranker (not applicable to generative deciders). Risks: the vendor claim that these models emit the letter first is unverified (D-06); until a real model proves a high letter mass the whole path is UNTESTED.

---

## B. onnxruntime encoder-NLI serving

### B.1 DeBERTa-v3 ONNX export and tokenisation gotchas

- **`token_type_ids`:** DeBERTa-v3 has `type_vocab_size = 0`; Optimum's export deletes `token_type_ids` from inputs in that case. The candidate feeds only `input_ids` and `attention_mask` (`onnx_server.py:266`), which matches that. A segment input would only appear for an export that kept it; make the server read `session.get_inputs()` and feed exactly those names (fixes D-17 properly) (https://discuss.huggingface.co/t/debertav3-onnx-conversion-error/20679).
- **Export difficulty:** DeBERTa-v3 uses disentangled attention with relative positions; ONNX conversion needs more care than RoBERTa (same thread). The pinned file is an upstream-published fp32 `onnx/model.onnx` (opset 12 per `docs/decision-models.md:31`), so we do not export it ourselves; do not claim parity with the PyTorch model without a logits comparison (UNTESTED).
- **Tokenizer:** the candidate uses SentencePiece `spm.model` and builds ids by hand: `[CLS]=bos_id`, `[SEP]=eos_id` fallback `1/2` (`onnx_server.py:243-262`). **INFERRED risk:** DeBERTa-v3's HF tokenizer adds `[CLS]`/`[SEP]` from its own vocabulary, not from SentencePiece's bos/eos ids, and may normalise differently than raw `EncodeAsIds`. Prove equivalence on a fixed corpus against `transformers.AutoTokenizer` (a test-time dependency only) before trusting probabilities. `tokenizer.json` (HF fast) exists for the same model; `tokenizers` has `cp310-abi3` wheels (below) so the fast tokenizer is the lower-risk single path, and it supports pair encoding with truncation natively.
- **Max length:** `max_position_embeddings=512` for this model; longer inputs degrade both speed and quality (https://huggingface.co/MoritzLaurer/deberta-v3-large-zeroshot-v2.0, fetched 2026-10-07). DeBERTa's relative positions do let it run longer in principle, but the card says it should not be relied on (INFERRED beyond that).
- **Truncation (fixes D-01):** the candidate does `ids[:512]` over `[CLS] premise [SEP] hypothesis [SEP]` (`onnx_server.py:256`), cutting the **end**, which is the hypothesis. Required semantics: truncate the **premise only**, keep both special tokens and the whole hypothesis. In Hugging Face terms that is `truncation="only_first"` when the premise is the first sequence (`only_second` truncates the second; `longest_first` shortens whichever is longer and can eat the hypothesis). My fetch of the HF doc page returned a self-contradictory summary, so this is stated from the standard definition and **must be pinned by a test** (a premise of 2,000 tokens, assert the hypothesis tokens are present in the final ids and the length is exactly 512). If the hypothesis alone exceeds the budget, return a typed error, not a truncation.
- **Batching all option hypotheses in one forward pass:** build a `[n_options, L]` int64 tensor with right padding to the longest row (pad id from the tokenizer), `attention_mask` 0 on pads; run once. INFERRED sound for DeBERTa (padding masked by `attention_mask`), but results with padding can differ in the last decimals from unpadded; assert a tolerance in a test. The model's ONNX graph must have dynamic batch/sequence axes; check with `session.get_inputs()[i].shape` (a fixed batch of 1 would make this impossible; UNTESTED). Cost grows linearly in n_options × L; with the premise repeated per row, cap options (D-10) or share nothing (no prefix cache in ORT).
- **Label order:** the candidate detects it from `config.json` `id2label` (entries with "entail"/"contrad"). `config.json` has `sha256: null` in the catalog (D-13), so a wrong label file changes answers silently; pin its hash.

### B.2 Quantisation, threads, IO binding, providers, memory

- **Dynamic int8:** ORT docs recommend dynamic quantisation for transformer/RNN models and static for CNNs, and say to run the Transformer optimisation tool first (https://onnxruntime.ai/docs/performance/model-optimizations/quantization.html, fetched 2026-10-07). I found **no published accuracy measurement for DeBERTa-v3-large int8**; treat it as UNKNOWN. Plan: ship fp32 as the pinned default and make int8 an opt-in profile only after measuring (a) logits drift vs fp32 on a fixed set, (b) end-task agreement, (c) latency. DeBERTa's disentangled attention is a known awkward case for quantisation tooling (INFERRED, not found in a source).
- **Threads:** defaults (`intra_op_num_threads=0` = physical cores, sequential execution, thread spinning on) (https://onnxruntime.ai/docs/performance/tune-performance/threading.html). Candidate leaves defaults (`onnx_server.py:199-203`). Risks: one process grabbing all cores starves the host and violates the memory/thread headroom rule when several instances run. Recommendation: set `intra_op_num_threads = floor(cores / instances)` (consumer-configurable), `execution_mode=ORT_SEQUENTIAL` (a transformer has few parallel branches), consider `allow_spinning=0` for background services (CPU power) at some latency cost; measure. The docs also note separate cores for multiple sessions/processes avoids contention (same page).
- **Concurrency of a session:** one `InferenceSession` can be shared by multiple threads calling `run()` (ORT FAQ; searched). Each thread must own its input/output arrays. But two concurrent runs share the same intra-op pool, so they time-slice rather than speed up. INFERRED: serialise requests with a small queue unless profiling shows overlap helps.
- **IO binding:** only worthwhile for GPU (avoids host/device copies). On CPU it adds nothing meaningful. Skip.
- **Providers:** the `onnxruntime` wheel is CPU; CUDA/TensorRT need the separate `onnxruntime-gpu` package; CoreML exists as a provider but is described as preview and mostly for iOS/macOS builds (https://onnxruntime.ai/docs/execution-providers/). Whether the PyPI macOS arm64 wheel includes the CoreML EP is UNTESTED (check `ort.get_available_providers()`). Plan: CPU EP only for v1; list GPU/CoreML as future work and do not advertise them.
- **Memory (real RSS for the 1.74 GB fp32 model):** UNTESTED, no model was downloaded. What is known: the catalog planner footprint is `size×1.5 + 512 MiB ≈ 3 GB` (source-findings I-03). ORT's CPU memory arena can keep peak RSS well above the model size and keep it after variable-size inputs; disabling `enable_cpu_mem_arena` and `enable_mem_pattern` reduces retained RSS at some speed cost (https://www.mintlify.com/microsoft/onnxruntime/performance/memory-optimization; one issue reports ~2 MB model → ~6 GB, https://github.com/microsoft/onnxruntime/issues/11627). Recommendation: the US3 real-model task must measure RSS at idle, after a 512-token×26-option request, and after 1,000 mixed-length requests, then set `MemoryHigh/Max` from the measured peak (not the planner estimate), and decide arena settings from that data.
- **Weights loading:** ORT reads fp32 initializers into memory (INFERRED, not found stated), so unlike GGUF via `mmap` the weights are not shared between instances through the page cache (INFERRED). Two encoder instances ≈ 2× weights.

### B.3 Python package pinning and wheel availability (measured from this host, 2026-10-07)

Source: `https://pypi.org/pypi/<pkg>/json`, parsed locally. Python here is 3.14.4 (cp314), macOS target arm64.

| Package | Latest | Python req | cp314 Linux x86_64 wheel | cp314 macOS arm64 wheel | sdist |
|---|---|---|---|---|---|
| onnxruntime | 1.30.0 (2026-09-10) | >=3.11 | `onnxruntime-1.30.0-cp314-cp314-manylinux_2_28_x86_64.whl` sha256 `8b611d24db2954545ce6bd9acd4670183cb368e4642450de7a9ab6474eb374ec` | `onnxruntime-1.30.0-cp314-cp314-macosx_14_0_arm64.whl` sha256 `8b6169c16a48429890d2f4a0c774ebf54dfe9066a998514aad0518a16d398547` | **none** |
| numpy | 2.5.3 (2026-09-06) | >=3.12 | `numpy-2.5.3-cp314-cp314-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl` sha256 `b0521d0f4aebb6e06189451025fa17a913287b13c03d5fe05c017333b654ea5b` | `numpy-2.5.3-cp314-cp314-macosx_14_0_arm64.whl` sha256 `adc1ada2662f8a5f960b8a10d9986897e7499ef07e06d4cfe7197f8cce923c07` (also a `macosx_11_0_arm64`) | yes |
| sentencepiece | 0.2.2 (2026-07-12) | >=3.9 | `sentencepiece-0.2.2-cp314-cp314-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl` sha256 `8d44b20234905ff022b7d535f79d1f823ad7670c9851cc4f03cdc34787cdb3ab` | `sentencepiece-0.2.2-cp314-cp314-macosx_11_0_arm64.whl` sha256 `79bac5a251f23a7341e28fda9ce0d5319edf45328239ce037c0682936f137906` | yes |
| tokenizers | 0.23.2 (2026-09-03) | >=3.10 | `tokenizers-0.23.2-cp310-abi3-manylinux_2_17_x86_64.manylinux2014_x86_64.whl` sha256 `41c2f84d172449b4dadb9cdc508e3e364076613c35b16e76ecfe47a60d1e3305` | `tokenizers-0.23.2-cp310-abi3-macosx_11_0_arm64.whl` sha256 `986670e43691469dcee610ea0f846f91a8f84e91fc6f7a48d4c064414c0ec2bf` | yes |

Findings:

- **Every package has a binary wheel for cp314 on both platforms.** First cp314 releases: onnxruntime 1.24.1 (2026-02-05), sentencepiece 0.2.1 (2025-08-12), numpy 2.3.2 (2025-07-24). So a pin >= those works; pinning the current versions above is feasible.
- **onnxruntime has no sdist.** On a platform or Python without a wheel `pip` cannot build it, so the install fails; make `--only-binary=:all:` the rule so a source build never starts silently.
- **macOS wheel floor:** the onnxruntime arm64 wheel is tagged `macosx_14_0`, so macOS < 14 gets no wheel (INFERRED from the platform tag; pip will refuse it). Add a `doctor` check.
- **Transitive dependencies must be hashed too.** `onnxruntime`'s `requires_dist` is `flatbuffers`, `numpy>=1.21.6`, `packaging`, `protobuf>=4.25.8` (PyPI JSON). `pip install --require-hashes -r requirements.lock` rejects any requirement without a hash, so the lock must list those and their own dependencies, generated and verified by `pip download`/`pip-compile --generate-hashes` in the US3 environment. UNTESTED here (pip is not on PATH; only the four hashes above were read from PyPI JSON, whose integrity I trust only as far as PyPI over HTTPS).
- **Where to install:** a venv under llmctl's state dir with `python3 -m venv` + `--require-hashes --only-binary=:all:`; never `pip install` into the system Python (D-16, D-27). `numpy 2.5.3` needs Python >= 3.12, so the venv interpreter must be checked (system Python 3.11 would resolve to older numpy and a different hash set).
- `tokenizers 1.0.0rc1` also exists with cp314 (first-cp314 query above). Do **not** adopt a release candidate; pin 0.23.2.

### B.4 Lighter alternatives to a Python encoder server

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Python + onnxruntime (candidate)** | Fewest moving parts, wheels exist everywhere checked, matches existing `python3` dependency of the gateway | Interpreter + ~24 MB ORT wheel + numpy; GIL (irrelevant, work is in ORT); venv management; hash-locking transitive deps | Recommended for v1 |
| **Go + `yalue/onnxruntime_go`** | Single static-ish binary for the server, good concurrency | Still needs the ORT **shared library** shipped and `SetSharedLibraryPath`, needs cgo + a toolchain on the build host, Go tokenizers for DeBERTa SentencePiece are not first-party (https://github.com/yalue/onnxruntime_go) | Not worth it: you still ship ORT and need a Go DeBERTa tokenizer |
| **Rust + `ort` + `tokenizers`** | Real DeBERTa tokenizer (HF `tokenizers` is Rust), static linking strategies (`ORT_STRATEGY=download/system/compile`) | New toolchain in a bash project; `ort` 2.x was release-candidate in my search results (https://docs.rs/crate/ort/1.14.1 lists the 1.x line); supply chain and licence review | Defer |
| **llama.cpp for BERT-family encoders** | One engine, one binary, mmap, GGUF checksums, `--pooling rank` for classifiers | **DeBERTa not supported** in the pinned source (no `deberta` match); only BERT-family archs; NLI head support would require the model to be one of those | Not applicable to decide-nli; possible for a future BERT/ModernBERT-based decider (e.g. Laya-style, UNVERIFIED) |

---

## C. Zero-/few-shot NLI as a decision method

- **What works:** NLI zero-shot turns a label into a hypothesis ("This text is about X") and asks if the premise entails it. For `multi_label=False` the pipeline softmaxes the entailment logits **across candidate labels**; for `multi_label=True` each label is judged independently, entailment vs contradiction (https://huggingface.co/MoritzLaurer/deberta-v3-large-zeroshot-v2.0, fetched 2026-10-07; the entailment framing is Yin, Hay and Roth, EMNLP 2019, https://aclanthology.org/D19-1404/). The model card describes it as a *text classification* model, MIT licence, 512-token window, with biases from the base model, the human NLI data and the Mixtral-generated synthetic data.
- **When it fails for choice/score (this answers Jev.md l.2290/2400):**
  1. Per-option hypotheses are not comparable. Each option is a separate NLI problem; the entailment logits of different hypotheses are not on a common scale, so `softmax(entailment logits across options)` is an ad-hoc calibration, not a posterior. Entailment-based zero-shot has large variance across datasets and phrasing, and models lean on lexical overlap (Ma et al., ACL-IJCNLP 2021, "Issues with Entailment-based Zero-shot Text Classification", https://www.microsoft.com/en-us/research/?p=763948; search summary only, not the paper itself).
  2. **Instructions and rubric options are not facts about the premise.** "Does this state say the plan is risky? / which tier fits?" asks for a judgement over criteria; NLI was trained to verify a statement against evidence. A hypothesis that restates the *instruction + option* (as the candidate does) is out of distribution (INFERRED).
  3. **Ordinal `score` questions** (levels 0..k) have no natural NLI hypothesis per level; entailment of "the level is 3" vs "the level is 4" is not monotone. The candidate's expected-value over level probabilities inherits that (INFERRED).
  4. **Long states.** A 512-token window with the hypothesis taking part of it leaves little for the state (D-01).
  5. **Neutral mass.** With 3-way heads, most of the probability on "neutral" says "cannot tell", not "false". Collapsing neutral+contradiction (as `noul` does) merges "no" with "unknown".
- **Fit:** reasonable for *yes/no* (`noul`) questions with a single clear claim and for topic-like choices with short, concrete hypotheses; poor for judgement choices and scores. Evidence in this repo is only stand-in tests (source-findings section C); there is no real-model accuracy for `decide-nli`.
- **Encoder-only "decision heads" (Laya/Verdict/Kev-style per the conversation):** the claim in `Jev.md` is that a head is trained directly on (state, question, options) → option, so the model is optimised for the decision task and need not reuse NLI semantics, and a single pass can output all option scores. I could not verify any of those projects (source-findings E/H list them as unverified), so this document asserts nothing about their accuracy. The structural difference (INFERRED from the descriptions, not from papers): a decision head scores options jointly in one sequence and is trained on those labels, whereas NLI scores each hypothesis independently with a generic entailment objective.
- **Honest documentation caveats to ship with `decide-nli`:**
  1. State plainly: `decide-nli` is a general zero-shot NLI classifier, not a trained decision model; llmctl has not measured its accuracy on decisions; the numbers come from the upstream card for classification.
  2. Probabilities are entailment scores renormalised across options and **are not calibrated**; do not use `confidence` as a probability of being right without fitting calibration on your own labels (section A.2).
  3. Recommended only for short states and single-claim yes/no or topic-style choices; ordinal `score` and judgement `choice` are unsupported claims.
  4. English-oriented; 512-token limit; premise truncation behaviour and header.
  5. Mark `choice`/`score` on this profile as "experimental" in `/v1/models` and the CLI, or refuse them until a real-model evaluation passes (a spec decision).

---

## D. Throughput and latency design for the gateway

Current state (FACT): `ThreadingHTTPServer` in `decide_gateway.py:448` and `onnx_server.py:531`, no pool, no socket timeout, no body-size cap (D-09). Python docs: `ThreadingMixIn` creates one thread per request, `daemon_threads=False` by default, and the listen backlog is `request_queue_size` (default 5) (https://docs.python.org/3/library/socketserver.html; confirmed via search results listing the same, e.g. https://docs.python.org/id/3.11/library/socketserver.html).

| Model | Pros | Cons |
|---|---|---|
| `ThreadingHTTPServer` as is | Zero deps, trivial | Unbounded threads, slow-loris, no admission control, 26-option request holds a thread for the whole fan-out |
| **`ThreadingHTTPServer` subclass + bounded worker semaphore + bounded wait queue** | Stdlib only, small change, protects the host | You must write the queue and the 503 path |
| asyncio (`asyncio.start_server`/streams) | Cheap idle connections; natural timeouts | The backend call (urllib/ORT) is blocking, so it needs `run_in_executor` anyway; hand-rolled HTTP parsing is a security liability |
| External server (uvicorn/aiohttp) | Mature HTTP parsing | New dependencies to pin and hash (conflicts with the minimal-deps goal) |

**Recommendation:** keep stdlib `ThreadingHTTPServer`, but (1) set `daemon_threads=True`, a larger `request_queue_size`, and a per-connection socket timeout; (2) reject bodies over a configured cap before reading; (3) wrap request handling in a **bounded semaphore sized to downstream capacity** (llama slots × instances, or encoder instances) and a **bounded wait queue** with a deadline; when full return `503` + `Retry-After` quickly (backpressure instead of unbounded threads); (4) never echo backend exception text (D-09). For llama.cpp the useful measured limiter is slot count (`-np`); the server itself returns 503 with `?fail_on_no_slot=1`, so the gateway can read slot occupancy from `GET /slots` or just rely on its own semaphore.

- **Request coalescing:** for the llama path a request is already one forward pass; batching across requests is done by llama-server (`-cb`, slots), not by the gateway. For the ONNX path, coalescing *across* requests (several requests' hypotheses in one batch) would raise throughput but adds latency and padding waste; INFERRED not worth it for v1 given 1 request = n_options rows already forming a batch.
- **Per-instance parallel slots:** `-np N` shares weights and (with `--kv-unified`) a pooled KV (README 164-168). Cheaper than N processes for the same GPU. Prompt caching across slots: `cache_prompt` reuses the common prefix per slot; with `id_slot` unset the server picks an idle slot (README 585). Decision prompts share a header, so prefix reuse helps latency but causes the nondeterminism noted in A.2; make it a profile option.
- **Caching decisions** by `(state_hash, question_hash, model_revision)` + TTL:
  - Safe only when output is deterministic for that key. Include in the key: model revision/file hash, prompt-template hash, option list *and order*, calibration id, permutation mode, `cache_prompt` setting. Missing any of these serves wrong answers after a change.
  - Risks (https://tianpan.co/blog/2026/04/20/cache-invalidation-ai-semantic-rag): stale answers after model/prompt change; a wrong answer is served repeatedly rather than decaying; semantic (embedding-keyed) caches are hard to invalidate. Use **exact-match only**, short default TTL, a hard size bound, namespaced by revision (so a revision change is an instant miss), and a per-request `no-cache` escape. Cache only successful typed results, never errors or low-mass "no decision" results. Do not cache state text in plaintext on disk (privacy: states may be sensitive); hash keys, keep values in memory.
  - Default recommendation: **off in v1**, with the key design recorded; turn on after measuring hit rate with real agent traffic.

---

## E. Multi-instance of one profile

Existing mechanism (FACT): systemd template units `llmctl-llama@.service` read an `EnvironmentFile` per instance (`lib/service_linux.sh:137-171`); `_svc_instance_key` (line 81) already namespaces instance keys; one unit name is `llmctl-${engine}@${instance}.service` (line 301).

- **Naming.** Suffix-based instance keys: `decide-tiny`, `decide-tiny.2`, ... (first instance keeps today's name so nothing changes for existing users). Checked on this host: `systemd-escape --template=llmctl-llama@.service "decide-tiny.1"` → `llmctl-llama@decide\x2dtiny.1.service`; a dot is valid in an instance name. Because `-` is escaped by `systemd-escape` but the existing code writes it unescaped (`decide-tiny`), keep using the same convention for both and always derive the unit name from one function, not by string concatenation in three places. The counter separator must not appear in profile names; verify against the catalog (UNVERIFIED here) and parse by `${key##*.}` only when the profile name set is dot-free.
- **Ports.** Catalog ports are fixed per profile (8092..8099). "Ephemeral" ports are a poor fit because clients and the gateway need to discover them. Recommend a **per-profile contiguous block** or an allocator that picks the first free port at start **and writes it to a registry file** in the state dir (atomic rename), which the gateway and `llmctl ps` read. Keep the first instance on the catalog port. A port collision must fail the start with a clear message (never fall back silently).
- **Memory admission.** Each instance is admitted separately through the existing scheduler (`scheduler.sh` reservation logic, lines ~56-121): N copies reserve N × (weights + KV + compute). For GGUF on CPU, `mmap` lets the weights' page cache be shared across processes (INFERRED, default behaviour of llama.cpp loading); on GPU each process holds its own VRAM copy. Therefore **prefer `--parallel N` on one instance over N processes** for throughput on one device; use multiple instances for fault isolation, for separate GPUs, or when the spec's `decision_instances` capacity (§11.4.277(A)) is the contract. Report both numbers in the plan: `instances_possible` from memory and `slots_per_instance`.
- **ONNX instances:** weights are per process (B.2), threads must be partitioned (`intra_op_num_threads = cores/instances`), so N instances multiply memory and are CPU-bound; recommended max instances for `decide-nli` = what the measured RSS and core count allow.
- **Client-side spreading: where it should live.**
  - **Gateway fan-out (recommended):** the gateway owns discovery (registry), health (`GET /health`, which needs no key, plus a real probe), load (`GET /slots` for llama, gateway's own in-flight counter for ONNX) and backpressure. Clients stay simple (one URL, one key). Strategy: **least-loaded with health awareness** (skip instances failing the last k probes, circuit-break with a cool-down), tie-break round-robin; sticky routing only if the prompt-cache benefit is measured.
  - **Client-side:** useful only for callers that cannot pass through the gateway; the contract (`decision_instances` + registry file) lets them do round-robin, but each client then duplicates health logic. Document it as supported-but-secondary.
  - Failure: if every instance is saturated return `503` + `Retry-After`; never queue unbounded.
- **Retries:** decisions are idempotent reads, so the gateway may retry once on a *different* instance for connect errors/5xx, never on timeouts that might still be running (would double the load).

---

## F. Summary of recommendations (for plan/tasks)

1. FR-072: add a post-build SSL presence check + a runtime HTTPS test with a tiny GGUF; do not claim chat-server HTTPS until the runtime test passes; record the macOS caveat.
2. Use `--api-key-file` (0600) or env, never `--api-key`; set `--no-webui`; leave `--props` off; consider `--metrics` behind the key.
3. Bind engines to `127.0.0.1` (UNIX socket as hardening); add an unreachable-from-second-location test (FR-073).
4. Decision readout: pre-sampling `n_probs`, `cache_prompt:false`, sum over letter spellings, mass guard, missing-letter upper bound, per-model tokenisation check; permutation averaging opt-in; calibration = temperature scaling (Platt for binary; isotonic only at ~1000+ labels), stored with model/template hashes.
5. Encoder: `only_first` truncation of the premise, feed inputs per `session.get_inputs()`, tokenizer equivalence test, hash-pinned venv with `--only-binary=:all:`, measured RSS before setting `MemoryMax`, fp32 default, int8 only after measurement.
6. Gateway: bounded concurrency + queue + 503 backpressure, body/time caps, no error echo; cache off by default with a documented key.
7. Multi-instance: registry file, deterministic naming, prefer slots over processes where one device, gateway-side least-loaded with health.

## G. Unverified items and how to close them

| Item | Why open | How to close |
|---|---|---|
| Real HTTPS handshake on the pinned build | No model available; no downloads allowed | Start a tiny GGUF with `--ssl-*`, test with `openssl s_client` and `curl --cacert` (FR-070 negative cases) |
| First-token letter mass of the catalog deciders | Vendor claims only | US3 real-model run; log letter mass, top-N coverage, spelling distribution |
| DeBERTa tokenizer equivalence (spm bos/eos vs HF) | Hand-built ids | Compare against `AutoTokenizer` on a corpus (dev-only dependency) |
| int8 accuracy/latency for DeBERTa-v3-large | No source found | Measure logits drift and agreement vs fp32 |
| Real RSS of the 1.74 GB ONNX model | Not downloaded | Measure idle/peak/after-N-requests with and without arena |
| Transitive wheel hashes for the lock file | `pip` not on PATH here | Generate with `pip-compile --generate-hashes` or `pip download` on Linux x86_64 and macOS arm64, verify by clean install |
| macOS arm64 OpenSSL in llama.cpp build; CoreML EP in ORT wheel | No macOS machine | Check on a Mac (`otool -L`, `ort.get_available_providers()`) |
| `/metrics` gauge names and `--threads-http` default in the pinned build | Read from mirrors only | Run server, `curl /metrics`, read `common/arg.cpp` default |

## H. Sources (all fetched or searched 2026-10-07)

- Local: `submodules/llama.cpp` (CMakeLists.txt:144, vendor/cpp-httplib/CMakeLists.txt:128-190, common/arg.cpp:3479-3600, tools/server/server-http.cpp:106-231, server-context.cpp:1790,1964-2019, server-common.cpp:1403-1411, tools/server/README.md), `lib/engine.sh:55-95`, `lib/service_linux.sh`, candidate `lib/decide_gateway.py`, `lib/decide.sh`, `lib/onnx_server.py`, `docs/decision-models.md`.
- PyPI JSON: https://pypi.org/pypi/onnxruntime/json, `/sentencepiece/json`, `/tokenizers/json`, `/numpy/json`.
- https://onnxruntime.ai/docs/performance/tune-performance/threading.html
- https://onnxruntime.ai/docs/performance/model-optimizations/quantization.html
- https://onnxruntime.ai/docs/execution-providers/
- https://www.mintlify.com/microsoft/onnxruntime/performance/memory-optimization ; https://github.com/microsoft/onnxruntime/issues/11627
- https://huggingface.co/MoritzLaurer/deberta-v3-large-zeroshot-v2.0
- https://discuss.huggingface.co/t/debertav3-onnx-conversion-error/20679
- https://aclanthology.org/D19-1404/ ; https://www.microsoft.com/en-us/research/?p=763948
- https://arxiv.org/abs/2102.09690 ; https://arxiv.org/abs/2309.03882 ; https://arxiv.org/abs/2210.12353 ; https://arxiv.org/abs/2104.08315 ; https://arxiv.org/abs/2509.15020 ; https://arxiv.org/abs/2402.14499
- https://proceedings.mlr.press/v70/guo17a.html ; https://scikit-learn.org/1.3/modules/generated/sklearn.calibration.CalibratedClassifierCV.html
- https://docs.python.org/id/3.11/library/socketserver.html ; https://github.com/yalue/onnxruntime_go ; https://docs.rs/crate/ort/1.14.1
- https://tianpan.co/blog/2026/04/20/cache-invalidation-ai-semantic-rag
- https://cdn04132025.gitlink.org.cn/replica/llama.cpp/commit/8ef969afcec1645d2d9c3ab1fc82263bba968989 (threads-http default)
- systemd specifiers: https://man.archlinux.org/man/systemd.service.5.en ; local `systemd-escape` run.

Search summaries were produced by a retrieval tool; wherever a claim rests only on such a summary (for example the truncation-strategy definitions, the Ma et al. findings, the `threads-http` default) it is flagged above and should be re-read at source before it enters a requirement.
