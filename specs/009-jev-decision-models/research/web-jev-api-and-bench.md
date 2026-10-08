# Web research: hosted Jev API contract, JevBench, SDKs, replicas, ecosystem

Feature: 009-jev-decision-models. Retrieval date for every URL below: 2026-10-07. Method: WebSearch + WebFetch (about 12 searches, 35+ fetches). The product is real, public since Sept 2026, and well documented by the vendor; the ecosystem around it is days to weeks old and mostly self-reported.

Labels: VERIFIED-PRIMARY (vendor docs/SDK repo/package registry), VERIFIED-SECONDARY (third party or reseller doc), VENDOR-CLAIM (marketing/self-reported performance), NOT-FOUND, INFERENCE (my reading, not stated by a source).

Caveat on fetch tooling: WebFetch summarises pages with a small model, so quoted strings are tool-extracted, not byte-exact. Anything contract-critical (field names, limits) should be re-checked against the raw `.md` pages listed in Sources before being frozen into a golden fixture.

## Searches used and result quality

| Query (abridged) | Quality |
|---|---|
| Jev System One TypeSafe AI decision model API | Good (DataCamp, vendor echo) |
| JevBench benchmark typed decisions | Good (repo README, benchlm.ai, HN mirror) |
| typesafe.ai docs jev api reference systemone choice score noul | Good (found DigitalOcean, composio, opentweet pages) |
| openrouter typesafe/jev-1.13 | Good |
| open source Jev replica /v1/systemone TYPESAFE_BASE_URL | Good (Kev, Rizzo, Von) |
| Jev hacker news calibration limitations | Good (arXiv paper, HN summary) |
| Vercel AI Gateway typesafe jev systemone | Excellent (Vercel docs, last_updated 2026-10-05/07) |
| OpenAI Decisions API decisions.create | Medium (secondary only; OpenAI reference URL 404) |
| Jev option order bias / replicas | Good (wavect, creativeainews) |
| Jev MCP server | Weak (one tiny community server) |
| JevBench 231 public items | Did NOT confirm 231 (see Q3) |

Dead/blocked: `developers.openai.com/api/reference/resources/decisions/methods/create` (404), `openrouter.ai/typesafe/jev-1.13` (404 via fetch, but listed by search), npmjs.com (403), JevBench `docs/METHODOLOGY.md` guessed path (404).

## Q1. Hosted wire contract

### Endpoint, auth, model ids
- `POST https://api.typesafe.ai/v1/systemone`, `Authorization: Bearer <API_KEY>`, `Content-Type: application/json`. VERIFIED-PRIMARY (https://docs.typesafe.ai/api.md).
- Native API is not OpenAI-compatible, no streaming, text only (string, JSON object or array of text). VERIFIED-SECONDARY for "not OpenAI compatible / no streaming" (DigitalOcean doc); VERIFIED-PRIMARY for "text only" (https://docs.typesafe.ai/models.md).
- Model ids: canonical `jev-1.13.0`; aliases `jev-latest` and `jev-preview` both point at `jev-1.13.0` ("There is no preview build available right now"). VERIFIED-PRIMARY (https://docs.typesafe.ai/models.md). Other host-specific ids: OpenRouter `typesafe/jev-1.13` / `typesafe/jev-latest`; Vercel AI Gateway `typesafe-ai/jev`; DigitalOcean `typesafe-jev-1.13.0`. VERIFIED-SECONDARY. There is no `jev-1.13` bare id in the vendor docs; only `jev-1.13.0`.
- Response `model` field echoes the versioned id (vendor example: `"model": "jev-1.13.0"`). VERIFIED-PRIMARY (noul page).
- A `GET /v1/models` listing exists on the TypeSafe SDK surface (SDK has `ModelCard`/`Models` types and a "list models" method; Vercel exposes `GET /typesafe/v1/models`). The raw `api.md` page does not document it. VERIFIED-SECONDARY.
- Correlation header: `x-typesafe-request-id` on responses. VERIFIED-PRIMARY (Python SDK responses/exceptions docs).

### Request schema
```
{ "model": "jev-latest",
  "state": <string | object | array>,
  "questions": { "<id>": { "type": "noul"|"choice"|"score", "instructions": <string|object|array|null>, "criteria": ... } } }
```
- `criteria` for noul: optional `{ "true": ..., "false": ... }`. For choice: required map option -> description (value may be null per SDK quickstart). For score: required ordered array of level descriptions, lowest to highest. VERIFIED-PRIMARY (api.md, primitives/*.md, SDK quickstarts).
- `instructions`/criteria entries may be string, object, array or null (JSON-structured rubrics). VERIFIED-PRIMARY (primitives/advanced.md).
- Question keys are user-chosen; no documented max number of questions per request ("Ask independent questions together", no limit stated). NOT-FOUND for a numeric limit.

### Response schema
```
{ "model": "jev-1.13.0",
  "answers": { "<id>": { "type": "noul", "noul": 0.99 }
             | { "type": "choice", "choice": "x", "probabilities": {"x":..}, "confidence": 0..1 }
             | { "type": "score", "score": 2.97, "legend": {"0":"..",..}, "probabilities": {"0":..}, "confidence": 0..1 } },
  "usage": { "input_tokens": 360, "output_tokens": 39 } }
```
VERIFIED-PRIMARY (api.md, noul.md, score.md, choice.md).
- Noul: single float 0..1 = P(yes); **no `confidence` field** for noul. VERIFIED-PRIMARY ("There is no separate `confidence` value for a Noul").
- Choice: `choice` = argmax option; `probabilities` sums to 1.0.
- Score: levels are numbered from 0; `score` = sum(level_index x probability), range 0..(n-1), fractional; `probabilities` keyed by level number as a string; `legend` maps level number to its description.
- `output_tokens` is non-zero in vendor examples (39, 20) even though output is free. VERIFIED-PRIMARY/SECONDARY.

### Limits (contradictions resolved in the table below)
- Choice options: **255 max** per Choice. VERIFIED-PRIMARY (api.md, choice.md). Min not documented by the vendor; Vercel's OpenAI-shaped adapter states 1..255 choices. A third-party measurement says the hosted API returns `400 Too many choices` at 256 (VERIFIED-SECONDARY, creativeainews).
- Score levels: **min 2, max 10** ("at least two levels; the API accepts up to 10"). VERIFIED-PRIMARY (score.md, api.md).
- Context: 64K tokens per request; 32K for `state` plus the longest question; over-limit requests are rejected. VERIFIED-PRIMARY (models.md) and VERIFIED-SECONDARY (DigitalOcean). OpenRouter lists 32K (their context-window field). The 32K figure is the "state + longest question" budget, not the request total.
- Rate limits (VERIFIED-PRIMARY, models.md): "100K tokens per second / 80 requests per second", dynamically adjusting, "can change without notice". Contradicting third-party figures: 250,000 tokens/s and 1,200 requests/min (CometAPI page; also in Jev.md l.822). Treat CometAPI/Jev.md as stale or reseller-specific.
- Pricing: $0.042 per 1M input tokens ($42 per billion), output tokens free. VERIFIED-PRIMARY (models.md, typesafe.ai home). About $0.0004 per case is a VENDOR-CLAIM.
- Latency 70-500 ms and "0% structured output error rate": VENDOR-CLAIM.

### Confidence definition
"A statistic computed from the probability distribution the answer already gives you"; 1 when all probability is on one outcome, 0 when spread evenly. Choice formula given by the vendor: `confidence = (p_max - 1/n) / (1 - 1/n)`. VERIFIED-PRIMARY (https://docs.typesafe.ai/confidence.md). For Score the doc says "computed from how probabilities is spread. A single peak on one level means high confidence"; the exact formula for Score is NOT-FOUND (INFERENCE: same normalised-peak form over n levels; do not assume without a golden fixture from the hosted service). Note that confidence is NOT correctness and calibration is a property over groups of predictions (VERIFIED-PRIMARY, concepts/system-one.md).

### Errors and status codes
- Documented statuses: 401 (missing/invalid key), 422 (body validation), 429 (rate limit; retry with exponential backoff), 529 (temporarily overloaded). VERIFIED-PRIMARY (api.md). Python SDK also maps 400, 403, 404 and any 5xx (VERIFIED-PRIMARY, sdk/python/api/exceptions.md). SDK retries 408, 429, 5xx by default.
- Error body shape: vendor docs only say "standard HTTP status codes with a JSON body". The Vercel gateway page, which says it uses "TypeSafe's shape", shows `{ "message": "...", "error_type": "invalid_request" }` (VERIFIED-SECONDARY). Only the `invalid_request` value is shown; the full `error_type` vocabulary is NOT-FOUND.
- `Retry-After`: the SDK honours it and exposes `retry_after_ms` (VERIFIED-PRIMARY), so servers should emit it on 429.

## Q2. Is "noul" the real name?
Yes. VERIFIED-PRIMARY: `"type": "noul"` in the request, `"noul": <float>` in the answer, `Noul(...)` / `noul()` in the Python/JS SDKs, `https://docs.typesafe.ai/primitives/noul.md` ("A Noul question asks the TypeSafe model to evaluate a yes/no question and return the probability that the answer is yes"). It is not a typo.
Aliases elsewhere (important for llmctl): Vercel AI SDK/gateway native `/v1/evaluate` calls it `boolean` with answer field `probability`; its TypeSafe-compatible endpoint still accepts `noul`. The OpenAI Decisions API calls it `predicate` with field `probability`. OpenRouter's skill text still says `noul`. VERIFIED-SECONDARY.

## Q3. JevBench
- Not a TypeSafe product. It is a third-party, one-person benchmark: https://github.com/fstandhartinger/jevbench ("Benchmark Heaven"), explicitly "not affiliated with or endorsed by TypeSafe AI". VERIFIED-PRIMARY (README, benchlm.ai) + VERIFIED-SECONDARY ("one-person hobby project funded by donations", aiskill.market). 235 stars at fetch time.
- Licence: MIT for the harness and the 72 original public decisions; "everything else keeps its own licence" (imported items, weights, upstream datasets; see THIRD-PARTY.md). VERIFIED-PRIMARY.
- Data in the public tier (README v1.4.2.2): `datasets/public/original.jsonl` 72 items (36 paraphrase pairs), `easy.jsonl` 48, `hard.jsonl` 111 -> 231 public items (72+48+111). So the "231 public items" in Jev.md l.674 is arithmetically consistent with the repo, as 72+48+111 (INFERENCE from README counts; no source states "231"). Held-out private: 24 original + 24 easy + 109 hard. Imported: 146 decisions (78 routing, 68 answer-adequacy) from the maintainer's auto-router experiment, with upstream licences.
- Version drift: README says 534 decisions per system (v1.4.x); benchlm.ai describes v1.5 with 1,624 decisions (904 open, 720 sealed) and a doubled sealed share (50% of Intelligence); a Sept-30 snippet says 308 sealed decisions for v1.3-era blending. Methodology is moving; a "score" is only meaningful with a pinned benchmark version.
- Item format: state + instructions + bounded rubric + exact label set; models return a typed answer ideally with probabilities for every option. Question families: routing, answer adequacy, policy checks, intent, ordinal scoring, extraction. Hard tier written by Claude Opus 5 and GPT-5.6 Sol, cross-reviewed, frozen and hashed before any system ran. VERIFIED-PRIMARY.
- Scoring: JevBench Score = geometric mean (README; benchlm says harmonic composite for v1.5) of Intelligence (chance-corrected: (acc-chance)/(1-chance), tier weights hard 30 / easy 14 / standard 28 / judge 28; quadratic penalty under 50), Calibration (ECE on top-label confidence, 10 equal-width bins), Speed (log scale, 0.1 s = 100), Cost (USD per 1,000 decisions, $0.001 = 100). 25% each. VERIFIED-PRIMARY. Hosted Jev 1.13.0 composite: 63.29 (v1.4 era per aiskill.market), 74.4 (v1.3.0 per HN mirror); Jev.md's 86.6% / 73.9% hard figures are accuracy claims not found in any fetched source (NOT-FOUND).
- Leaderboard: sealed items publish aggregates only; top of the v1.5 table at fetch time was Cygnet 73.70, Winnow-12B Q8 73.23; README v1.4.2.2 table led by Imajev-4B 67.37, Plumb-4B 65.84, decider-4b v2 64.13. 106 ranked of 112 entries. These are self-reported by the benchmark owner. Note decider-4b (our `decide` profile) is on the list.
- Reproduce a score: Python 3.10+, stdlib-only HTTP adapters. Adapters: `typesafe`, `openai_compat`, `gradio_space`, `local_openjev`. Command for a custom endpoint (VERIFIED-PRIMARY, README):
  `python -m jevbench.cli run --tasks datasets/public/original.jsonl --adapter typesafe --endpoint https://YOUR-ENDPOINT --key-env '' --model jev-latest --cost-basis no_billable_account_public_endpoint --results RUN/results.jsonl --raw-dir RUN/raw`
  Run dirs are write-once; budgets file-locked. Sealed items cannot be run locally, so an official sealed-inclusive score cannot be reproduced by a third party; only public-tier numbers can.
- Redistribution: MIT items (the 72 originals) may be redistributed with licence notice. The 111 public hard items and 48 easy items: licence is "MIT for the 72 original public decisions"; the README sentence does not clearly cover easy/hard files, so treat them as NOT-CLEARED until THIRD-PARTY.md / per-file headers are read. Imported 146: original upstream licences. Recommendation: llmctl should run the harness locally against pinned commits and never vendor items it cannot show a licence for.
- Use as accuracy golden set: README: "The public half can be trained on or selected against". So public items are legitimate for tuning/regression, but models that were tuned on them (several replicas) are contaminated; llmctl should label results "public tier, contamination possible" and not claim sealed-equivalent accuracy. Other small benchmarks exist (jev-rerank-bench, jev-benchmarks 300 examples, typesafe-ai-benchmark) but are narrow pilots (aiskill.market).

## Q4. SDK behaviour
- Python: PyPI `typesafe-sdk` 0.7.2 (2026-09-26), MIT, Python >=3.10, import `typesafe_sdk`; sync `TypeSafeClient`, async `AsyncTypeSafeClient`; core dep `httpx`, extra `typesafe-sdk[http2]`. VERIFIED-PRIMARY (PyPI, docs). (The SDK doc pages mention `httpx2.Client`/`httpx2.Timeout`; PyPI lists `httpx`. Discrepancy unresolved; INFERENCE: docs naming artifact. Check `pip show` in a venv before relying on either.)
- JS: npm `@typesafe-ai/sdk`, Node >=20, ESM+CJS; `new TypeSafeClient({apiKey, baseURL, timeout, fetch, defaultHeaders, retry, defaultModel, logger, logLevel})`. VERIFIED-PRIMARY. Repos: `typesafe-ai/typesafe-sdk-python`, `typesafe-ai/typesafe-sdk-js` (MIT).
- Base-URL override: yes, first-class. Python `base_url=` or env `TYPESAFE_BASE_URL`; JS `baseURL` or `TYPESAFE_BASE_URL`; default `https://api.typesafe.ai`. Other env vars: `TYPESAFE_API_KEY`, `TYPESAFE_DEFAULT_MODEL`, `TYPESAFE_LOG_LEVEL`. VERIFIED-PRIMARY (constants.md, TypeSafeClientConfig.md). The SDK appends `/v1/systemone` to the base; Vercel's base `https://ai-gateway.vercel.sh/typesafe` -> `/typesafe/v1/systemone` confirms this. The API key is required by the client, so a local server must accept any non-empty bearer token or the user must set a dummy key.
- Timeouts: default 10.0 s per attempt (Python) / 10000 ms (JS). Retry: default 2 retries, statuses 408/429/5xx, backoff 0.5 s doubling to 5 s, jitter 0.25, honours `Retry-After`, total retry budget 30 s; connection/timeout errors retried; `RetryPolicy(max_retries=0)` disables. VERIFIED-PRIMARY (retries.md). Consequence for llmctl: a local model cold-load or a slow CPU decision >10 s will be cut off by the default client timeout, so the gateway must answer fast or queue with 429+Retry-After.
- TLS/self-signed: no `verify`/`ssl`/`proxy` constructor option is documented. Python allows `http_client=` (a pre-built httpx client, mutually exclusive with `transport=`), so a custom CA or `verify=False` is done by passing your own client. JS allows a custom `fetch`. VERIFIED-PRIMARY for those hooks. Env vars: no vendor statement. INFERENCE (general library behaviour, NOT verified here against this SDK): httpx honours `SSL_CERT_FILE`/`SSL_CERT_DIR` and proxy vars (`HTTPS_PROXY`) when `trust_env` is on, and does NOT read `REQUESTS_CA_BUNDLE`; Node honours `NODE_EXTRA_CA_CERTS`. llmctl should test these empirically (hermetic test with a private CA) rather than cite them; the lowest-risk recommendation is to keep local gateways on `http://127.0.0.1` (already the llmctl rule), avoiding TLS entirely.
- Python SDK maps errors to classes; `TypeSafeAPIResponseValidationError` is raised on structurally invalid 200 responses with a `field_path`, so a replica returning a missing required field fails hard in the official SDK. Required, based on the SDK: `answers`, `usage`, `model`.

## Q5. Independent evidence on replicas and failure modes
- Hosted Jev's own documented jagged edges (VERIFIED-PRIMARY, https://docs.typesafe.ai/model-jaggedness/jev-1.13.md): literal reading, no arithmetic/counting, poor numeric proximity, dates read as text, double negatives, accuracy falls with irrelevant state, adversarial/injected content not treated as hostile, contradictory instructions, **choice option order bias ("leans toward the option that comes first")**, cannot generate text.
- Replicas that claim the hosted wire contract: Kev (https://github.com/jaredpalmer/kev, Apache-2.0; `/v1/systemone`, `/v1/models`, plus extensions `/v1/systemone/permute` and `/separate`; states to 65,536 tokens + 8,192 per question; 1-255 options/levels; 422 on over-limit, never silent truncation; bearer via `KEV_API_KEY`; says point the Python SDK at it "unchanged"), Rizzo Flow ("The interface is compatible, the model is not Jev"; probabilities uncalibrated by default; max 26 options vs Jev 255; 4B at 0.648 accuracy vs Jev 0.727 on its fixture), Von (`/v1/systemone`), plus `system-one-adapter-python` (official org repo, MIT: a drop-in client backed by OpenAI/Anthropic/Gemini LLMs). VENDOR-CLAIM for each replica's own compatibility and accuracy; none independently verified end-to-end (DataCamp disclaimer: "not all examples have been independently tested end-to-end").
- Independent measurements (VERIFIED-SECONDARY, third-party blogs, weak independence): four people measured hosted Jev on Banking77 with 87.0 / 83.2 / 77.8 / 76.3% accuracy, a 10.7-point spread ("six teams reproducing six different targets"); hosted Jev ECE 0.246 reported worst among tested; open replicas reached ECE 0.03-0.08 only after temperature scaling on held-out data; hosted Jev changed 13% of choices under option permutation vs 37% for the worst LLM; accuracy degrades above about 77 labels (creativeainews). On Qwen3-8B: raw 23.0% flip rate under option reversal, 7.3% after cyclic-rotation averaging; ECE 0.240 -> 0.095 with temperature scaling (wavect AnyJev, project-reported). Laya on 77 labels 0.425 vs Jev 0.870 (its own model card). A calibration paper on 499,500 crash narratives reports hosted Jev F1 0.908 and a "resolution-floor bound" on discrete probability grids (arXiv 2609.24052, VERIFIED-SECONDARY).
- Implication: replicas are not interchangeable with hosted Jev on calibration; the confidence field is the weakest-matched part of the contract.

## Q6. Ecosystem that should change llmctl's exposure design
1. **Standardisation is already happening, in three dialects.** (a) TypeSafe native `/v1/systemone` (noul/choice/score, map-shaped answers, `criteria`). (b) Vercel AI Gateway native `/v1/evaluate` (formerly "evaluation models"): types `boolean`/`choice`/`score`, answer `probability`, camelCase usage. (c) **OpenAI Decisions API** (announced DevDay 2026-09-29, limited preview; model `gpt-6-luna-decisions`): `POST /v1/decisions`, `input` + array `questions` of `predicate`/`choice`/`score`, answers returned in order with `probability`, arrays of `{value, probability}`, `confidence`, `refusal` answer type, `choices` 1-255, `levels` 2-10. VERIFIED-SECONDARY (Vercel's openai-decisions doc is the best source; the OpenAI reference page itself was not fetchable). Vercel proxies all three to any decision model, including `typesafe-ai/jev`.
2. OpenRouter serves Jev both at `POST /api/v1/systemone` and `POST /api/alpha/decisions`, no waitlist, 32K context shown. VERIFIED-SECONDARY (OpenRouter community doc).
3. Vercel AI SDK (`experimental_decide`, `ai` >= 7.0.128), TanStack AI `decide()`, eve.dev evals, n8n node `n8n-nodes-typesafe-ai`, DigitalOcean serverless inference all consume the above. VERIFIED-SECONDARY.
4. MCP: no vendor MCP server found. One community server `amidabuddha/jev-decision-mcp` (MIT, 1 star) wraps the hosted API using `TYPESAFE_API_KEY`, `TYPESAFE_DEFAULT_MODEL`, `JEV_TIMEOUT_MS`. VERIFIED-SECONDARY, immature. The vendor ships an agent skill (https://docs.typesafe.ai/agent-skill.md; repo `typesafe-ai/skills`, 2.6k stars) instead. Jev.md names `jev-mcp-server`, `jevcal`, `jevassert`, `verdictml` etc.; none verified here.
5. `jevclient` (Jev.md l.127) is real but unofficial: PyPI 1.2.0, MIT, Python 3.12+, by an independent author; the official SDK is `typesafe-sdk`. Do not make it the reference client.
6. Free/third-party hosted tiers (BeatAPI `jev-1.13-free`, etc., from Jev.md) NOT verified.

## Contradictions resolved

| Topic | Jev.md / our notes | Primary-source answer | Label |
|---|---|---|---|
| Choice option count | Jev.md l.2233: 2-100; notes: <=255 | Max **255** (api.md, choice.md); 256 -> `400 Too many choices` measured; Vercel/OpenAI adapters say 1..255 | VERIFIED-PRIMARY |
| Score levels | Jev.md l.2234: 2-8; notes: 2-10 | **2-10** (score.md, api.md) | VERIFIED-PRIMARY |
| "noul" spelling | Jev.md uses noul; some docs say boolean | `noul` is the TypeSafe name; `boolean` (Vercel) and `predicate` (OpenAI) are other dialects | VERIFIED-PRIMARY |
| Rate limits | Jev.md l.822: 250k tok/s, 1,200 req/min | Vendor: 100K tok/s, 80 req/s, dynamic; 250k/1,200 appears only on CometAPI | VERIFIED-PRIMARY vs reseller |
| Context | OpenRouter 32K; others 64K | 64K total per request; 32K for state + longest question | VERIFIED-PRIMARY |
| Model ids | jev-latest, jev-1.13.0, typesafe/jev-1.13 | `jev-1.13.0` canonical; `jev-latest`/`jev-preview` aliases; `typesafe/jev-1.13` OpenRouter only; `typesafe-ai/jev` Vercel; `typesafe-jev-1.13.0` DigitalOcean | VERIFIED-PRIMARY/SECONDARY |
| Confidence for noul | Jev.md l.2128 falls back to |p-0.5|*2 | Noul has **no confidence field**; any derived value is a client convention | VERIFIED-PRIMARY |
| Noul response field | n/a | `noul` (not `probability`) in native shape | VERIFIED-PRIMARY |
| "231 public items" | Jev.md l.674 | Matches 72+48+111 public files in repo README (derived); no source states 231 | INFERENCE |
| Hosted Jev 86.6% / hard 73.9% | Jev.md | Not found in any fetched source; JevBench publishes composite 63.29-74.4 depending on version | NOT-FOUND |
| JevBench ownership | Jev.md implies standard | Third-party hobby benchmark, not TypeSafe's | VERIFIED |
| Official Python client | Jev.md uses `jevclient` | Official is `typesafe-sdk`; `jevclient` independent | VERIFIED-PRIMARY |

## Recommended contract decisions for llmctl

1. Make `POST /v1/systemone` (TypeSafe native) the primary, byte-compatible gateway route on `127.0.0.1:8095`: map-shaped `questions`/`answers`, `noul`/`choice`/`score`, `usage.input_tokens`/`output_tokens`, response `model` echoing the served model id.
2. Enforce hosted limits exactly so client code fails the same way: choice options 1..255 minimum 2 recommended (hosted min undocumented; reject <1), score levels 2..10, 422 on schema/over-limit, 400 for too many choices, 401 missing key, 429 with `Retry-After` on saturation, 529 on overload. Return error bodies as `{message, error_type}`.
3. Noul answers carry only `noul`; never invent a confidence field. Score `score` = expected level index (0-based), `legend` keyed by string level number, `probabilities` keyed by string level number.
4. Confidence: implement the vendor's published Choice formula `(p_max - 1/n)/(1 - 1/n)`; for Score apply the same normalised-peak form and document it as llmctl-defined until a hosted golden fixture exists.
5. Accept auth leniently on loopback (any non-empty bearer), because the official SDKs require a key; do not require the vendor key.
6. Declare model ids: serve and accept `jev-latest` and `jev-1.13.0`-style aliases mapped to the local profile, but return the real local model id in `model`; never claim to be `jev-1.13.0`.
7. Add thin dialect adapters rather than separate engines: `/v1/evaluate` (`boolean`/`probability`) and `/v1/decisions` (OpenAI shape: `predicate`/`choice`/`score`, ordered answers, `refusal`). Treat the OpenAI shape as provisional until the OpenAI reference page is verified.
8. Respect SDK defaults: 10 s per-attempt timeout and 2 retries on 408/429/5xx. Keep decisions fast; return 429+`Retry-After` instead of queuing past ~8 s. Document `TYPESAFE_BASE_URL=http://127.0.0.1:8095` as the client switch.
9. Do not promise TLS-env behaviour; ship plain HTTP on loopback. If TLS is ever offered, test `SSL_CERT_FILE` (httpx) and `NODE_EXTRA_CA_CERTS` (Node) empirically and use the SDK `http_client`/`fetch` hooks as the supported path.
10. Mitigate documented biases: offer an opt-in option-order permutation/cyclic averaging (Kev's `/permute` is prior art), expose per-profile calibration status, and label replica probabilities uncalibrated unless a temperature fit on a held-out set exists.
11. Accuracy evidence: run JevBench public tier locally via its `typesafe` adapter with `--endpoint`, pin the repo commit and benchmark version, record contamination caveat, and never publish sealed-style claims. Do not vendor non-MIT or unlicensed items; vendoring only the 72 original MIT items is safe.
12. Keep claims about hosted Jev (86.6%, speed multipliers, nine failure modes) out of llmctl docs unless cited to docs.typesafe.ai; the documented failure-mode list has ten entries, not nine.
13. Track as an open item: obtain a hosted-Jev golden response set (needs a paid key) to confirm Score confidence, `error_type` vocabulary and whether `GET /v1/models` is served by the vendor. Not done here (no signup/paid calls).

## Sources (all retrieved 2026-10-07)

Vendor / primary
- https://docs.typesafe.ai/llms.txt (doc index)
- https://docs.typesafe.ai/api.md
- https://docs.typesafe.ai/models.md
- https://docs.typesafe.ai/confidence.md
- https://docs.typesafe.ai/primitives/choice.md, /score.md, /noul.md, /advanced.md
- https://docs.typesafe.ai/model-jaggedness/jev-1.13.md
- https://docs.typesafe.ai/concepts/system-one.md
- https://docs.typesafe.ai/sdk/python.md, /sdk/python/api/constants.md, /clients/sync.md, /retries.md, /types/responses.md, /exceptions.md
- https://docs.typesafe.ai/sdk/javascript.md, /sdk/javascript/api/interfaces/TypeSafeClientConfig.md
- https://docs.typesafe.ai/introduction/coding-agents.md
- https://typesafe.ai
- https://github.com/typesafe-ai (org: typesafe-sdk-python, typesafe-sdk-js, system-one-adapter-python, skills)
- https://github.com/typesafe-ai/system-one-adapter-python
- https://pypi.org/project/typesafe-sdk/ (0.7.2); https://pypi.org/project/jevclient/ (independent)
- https://github.com/typesafe-ai/typesafe-sdk-python

Third-party / platform docs
- https://vercel.com/docs/ai-gateway/sdks-and-apis/typesafe
- https://vercel.com/docs/ai-gateway/modalities/decision
- https://vercel.com/docs/ai-gateway/sdks-and-apis/openai-decisions
- https://openrouter.ai/docs/guides/community/jev
- https://docs.digitalocean.com/products/inference/how-to/use-system-one-api/
- https://www.datacamp.com/blog/system-one-models-jev
- https://www.datacamp.com/blog/top-open-source-jev-alternatives
- https://www.cometapi.com/en/models/typesafe-ai/jev
- https://www.eesel.ai/blog/openai-decisions-api
- https://arxiv.org/abs/2609.24052

JevBench and replicas
- https://github.com/fstandhartinger/jevbench and https://raw.githubusercontent.com/fstandhartinger/jevbench/main/README.md
- https://benchlm.ai/benchmarks/jevbench
- https://zeli.app/story/49800574 (HN mirror)
- https://aiskill.market/blog/the-jev-benchmark-landscape-roundup
- https://www.creativeainews.com/articles/open-jev-clones-benchmark-disagreement-2026/
- https://wavect.io/blog/anyjev-calibration-option-order-bias/
- https://github.com/jaredpalmer/kev
- https://github.com/Rizzo-AI-Academy/rizzo-flow

Local
- /home/milosvasic/Projects/jev/Jev.md (claims checked: l.127, 674, 822, 2233-2234)
- /home/milosvasic/Projects/llmctl/specs/009-jev-decision-models/source-findings.md (Sections E, G)
