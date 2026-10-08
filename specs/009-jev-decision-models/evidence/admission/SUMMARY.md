# Admission summary (paper checks)

| Field | Value |
|---|---|
| Records | 48 |
| Last retrieved (UTC) | 2026-10-07T16:16:22Z |
| Method | `llmctl admit --paper-only` against the live Hugging Face API; no weights downloaded |
| Gates | G1-G10 per `research/web-candidate-models.md` section 4 |

## Dispositions

| Disposition | Count |
|---|---|
| ADMITTED | 0 |
| ADMIT-CANDIDATE | 13 |
| USER-ONLY | 19 |
| HOLD | 1 |
| REJECTED | 14 |
| NOT-FOUND | 1 |

## Existence verdicts (Helix 11.4.270)

| Verdict | Count |
|---|---|
| VERIFIED | 40 |
| AMBIGUOUS | 1 |
| UNVERIFIED | 7 |

## Gate failures

| Gate | Failing candidates |
|---|---|
| G1 | Kestrelyn/kestrel-decider-230m, avbiswas/bev-decider-0.4B, ggml-org/Bespoke-Nimble-9B-v3-GGUF, ggml-org/OpenJev-GGUF, jevhome/jevhome-B, openjev/openjev, startlux-models/StartLux-Decision-4B-Q8_0-GGUF |
| G3 | Kestrelyn/kestrel-decider-230m, StrandsAgents/strands-decider-2B-hobson-v21, autotrust/JEV-9B, avbiswas/bev-decider-0.4B, com-kotobalabs/open-jev-deberta-v3-large, fastino/GLiNER2.5-Decide, jaredpalmer/kev-4b, manjunathshiva/opendecider-nano, openjev/openjev, perplexity-ai/pplx-decider-v1-27b, reoring/fern, shgao/rsi-jev-v1.0-qwen3.5-2b |
| G4 | 3ntr0py-t4m3r/GLiNER2.5-Decide-GGUF, ggml-org/Clef-Flash-GGUF |
| G5 | EldanRing/Winnow-12B, ggml-org/OpenJev-GGUF |
| G6 | EldanRing/Winnow-12B, EldanRing/Winnow-E4B, Kestrelyn/kestrel-decider-230m, Manav2op/verdict-small, StrandsAgents/strands-decider-2B-hobson-v21, TokenRhythm/NeoHorse-Jev-4B-GGUF, autotrust/JEV-9B, avbiswas/bev-decider-0.4B, com-kotobalabs/open-jev-deberta-v3-large, fastino/GLiNER2.5-Decide, heman10x/rlcd-modernbert-151m, jaredpalmer/kev-4b, jevhome/jevhome-B, manjunathshiva/opendecider-nano, manjunathshiva/opendecider-small-GGUF, mihailgribov/typecastlm-qwen3.5-3.8b, mys/laya-typed-decisions-GGUF, onnx-community/kev-4b-ONNX, openjev/openjev, perplexity-ai/pplx-decider-v1-27b, reoring/fern, shgao/rsi-jev-v1.0-qwen3.5-2b, startlux-models/StartLux-Decision-4B-Q8_0-GGUF |
| G9 | ggml-org/Clef-Flash-GGUF |

## Gates still PENDING (count of candidates)

| Gate | Candidates |
|---|---|
| G10 | 13 |
| G3 | 2 |
| G4 | 8 |
| G9 | 39 |

## ADMIT-CANDIDATEs (not pinned) needing real runs

| Repo | Protocol | Engine advance needed | Command |
|---|---|---|---|
| Mapika/decider-2b-GGUF | letter-logit | no | `LLMCTL_ADMIT_REAL_RUN=<real-run-executor> llmctl admit Mapika/decider-2b-GGUF` |
| apus-ailab/APUS-OpenJev-v1-4B-GGUF | letter-logit | no | `LLMCTL_ADMIT_REAL_RUN=<real-run-executor> llmctl admit apus-ailab/APUS-OpenJev-v1-4B-GGUF` |
| ggml-org/Julia-1-GGUF | systemone-native | yes | `LLMCTL_ADMIT_REAL_RUN=<real-run-executor> llmctl admit ggml-org/Julia-1-GGUF` |
| ggml-org/Kev-0.8B-GGUF | systemone-native | yes | `LLMCTL_ADMIT_REAL_RUN=<real-run-executor> llmctl admit ggml-org/Kev-0.8B-GGUF` |
| ggml-org/Kev-4B-GGUF | systemone-native | yes | `LLMCTL_ADMIT_REAL_RUN=<real-run-executor> llmctl admit ggml-org/Kev-4B-GGUF` |
| ggml-org/Kev-9B-GGUF | systemone-native | yes | `LLMCTL_ADMIT_REAL_RUN=<real-run-executor> llmctl admit ggml-org/Kev-9B-GGUF` |
| ggml-org/Laya-GGUF | systemone-native | yes | `LLMCTL_ADMIT_REAL_RUN=<real-run-executor> llmctl admit ggml-org/Laya-GGUF` |
| ggml-org/lev-GGUF | systemone-native | yes | `LLMCTL_ADMIT_REAL_RUN=<real-run-executor> llmctl admit ggml-org/lev-GGUF` |

## All candidates

| Candidate | Repo | Disposition | Existence | Protocol | First reason |
|---|---|---|---|---|---|
| gliner2.5-decide-gguf | 3ntr0py-t4m3r/GLiNER2.5-Decide-GGUF | USER-ONLY | VERIFIED | systemone-native | G4: GGUF arch 'deberta-v3' is absent from the pinned tree and an engine bump is not proven to add it (custom / patched architecture) |
| winnow-12b | EldanRing/Winnow-12B | USER-ONLY | VERIFIED | unsupported | G5: over the file-size budget: largest model file gguf/Winnow-12B-Q8_0.gguf = 12669646592 B (cap 10737418240 B), tier workstation, memory ESTIMATE 164 |
| winnow-e4b | EldanRing/Winnow-E4B | USER-ONLY | VERIFIED | unsupported | G6: unsupported / unclassified protocol (curated hint 'unsupported'); fail closed |
| kestrel-decider-230m | Kestrelyn/kestrel-decider-230m | REJECTED | VERIFIED | unsupported | G1: weights licence other is not on the allow-list ['apache-2.0', 'mit', 'bsd-2-clause', 'bsd-3-clause', 'cc-by-4.0', 'cc0-1.0', 'isc', 'unlicense'];  |
| verdictml-small | Manav2op/verdict-small | USER-ONLY | VERIFIED | unsupported | G6: unsupported / unclassified protocol (curated hint 'unsupported'); fail closed |
| decider-2b | Mapika/decider-2b-GGUF | ADMIT-CANDIDATE | VERIFIED | letter-logit | G3 PENDING: model sha256 pinned from the API LFS oid (decider-2b-v11-Q4_K_M.gguf=b7c132a67934...); aux file(s) ['decider_config.json'] are non-LFS: sh |
| decide | Mapika/decider-4b-GGUF | ADMIT-CANDIDATE | VERIFIED | letter-logit | G3 PENDING: model sha256 pinned from the API LFS oid (decider-4b-v2.1-Q4_K_M.gguf=c7083fcfc93f...); aux file(s) ['decider_config.json'] are non-LFS: s |
| decide-nli | MoritzLaurer/deberta-v3-large-zeroshot-v2.0 | ADMIT-CANDIDATE | VERIFIED | nli-onnx | G9 PENDING: live upstream issue-tracker sweep not done by this driver (offline); none recorded in the research register |
| strands-decider-2b-v21 | StrandsAgents/strands-decider-2B-hobson-v21 | USER-ONLY | VERIFIED | unsupported | G3: no GGUF or ONNX file in the repo to pin (siblings: ['.gitattributes', 'LICENSE.md', 'MANIFEST.sha256', 'README.md', 'chat_template.jinja', 'eval/i |
| neohorse-jev-4b | TokenRhythm/NeoHorse-Jev-4B-GGUF | USER-ONLY | VERIFIED | unsupported | G6: unsupported / unclassified protocol (curated hint 'unsupported'); fail closed |
| decide-2b+max | alibiserikbay/JevK5-GGUF | ADMIT-CANDIDATE | VERIFIED | letter-logit | G9 PENDING: live upstream issue-tracker sweep not done by this driver (offline); none recorded in the research register |
| anyjev | - | REJECTED | UNVERIFIED | unsupported | no weights artifact: harness / library, not a model (kind=harness) |
| apus-openjev-4b | apus-ailab/APUS-OpenJev-v1-4B-GGUF | ADMIT-CANDIDATE | VERIFIED | letter-logit | G9 PENDING: live upstream issue-tracker sweep not done by this driver (offline); none recorded in the research register |
| autotrust-jev-9b | autotrust/JEV-9B | USER-ONLY | VERIFIED | unsupported | G3: no GGUF or ONNX file in the repo to pin (siblings: ['.gitattributes', 'README.md', 'adapter/README.md', 'adapter/adapter_config.json', 'adapter/ad |
| bev-decider-0.4b | avbiswas/bev-decider-0.4B | REJECTED | VERIFIED | unsupported | G1: weights licence cc-by-nc-4.0 is not on the allow-list ['apache-2.0', 'mit', 'bsd-2-clause', 'bsd-3-clause', 'cc-by-4.0', 'cc0-1.0', 'isc', 'unlice |
| decide-tiny | chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF | ADMIT-CANDIDATE | VERIFIED | letter-logit | G9 PENDING: live upstream issue-tracker sweep not done by this driver (offline); none recorded in the research register |
| clm | - | REJECTED | UNVERIFIED | unsupported | no weights artifact: harness / library, not a model (kind=harness) |
| open-jev-deberta | com-kotobalabs/open-jev-deberta-v3-large | USER-ONLY | VERIFIED | unsupported | G3: no GGUF or ONNX file in the repo to pin (siblings: ['.gitattributes', 'README.md', 'added_tokens.json', 'config.json', 'head.safetensors', 'model. |
| djev | - | REJECTED | UNVERIFIED | unsupported | no weights artifact: harness / library, not a model (kind=harness) |
| edgejev | - | REJECTED | UNVERIFIED | unsupported | no weights artifact: harness / library, not a model (kind=harness) |
| gliner2.5-decide | fastino/GLiNER2.5-Decide | USER-ONLY | VERIFIED | unsupported | G3: no GGUF or ONNX file in the repo to pin (siblings: ['.gitattributes', 'GLiNER-2.5-Decision-HF-Banner.png', 'README.md', 'SKILL.md', 'config.json', |
| bespoke-nimble-9b | ggml-org/Bespoke-Nimble-9B-v3-GGUF | REJECTED | VERIFIED | systemone-native | G1: weights licence cc-by-nc-4.0 is not on the allow-list ['apache-2.0', 'mit', 'bsd-2-clause', 'bsd-3-clause', 'cc-by-4.0', 'cc0-1.0', 'isc', 'unlice |
| clef-flash | ggml-org/Clef-Flash-GGUF | HOLD | VERIFIED | systemone-native | G9: blocking open issue recorded: llama.cpp#30064 Q8_0 head quantisation collapses probabilities toward uniform (open at 2026-10-07); also needs b1137 |
| julia-1 | ggml-org/Julia-1-GGUF | ADMIT-CANDIDATE | VERIFIED | systemone-native | G4 PENDING: pending engine advance (FR-085): pinned tree has arch modern-bert=yes, /v1/systemone=no; needs llama.cpp >= b11361 |
| kev-0.8b | ggml-org/Kev-0.8B-GGUF | ADMIT-CANDIDATE | VERIFIED | systemone-native | G4 PENDING: pending engine advance (FR-085): pinned tree has arch qwen35=yes, /v1/systemone=no; needs llama.cpp >= b11361 |
| kev-4b | ggml-org/Kev-4B-GGUF | ADMIT-CANDIDATE | VERIFIED | systemone-native | G4 PENDING: pending engine advance (FR-085): pinned tree has arch qwen35=yes, /v1/systemone=no; needs llama.cpp >= b11361 |
| kev-9b | ggml-org/Kev-9B-GGUF | ADMIT-CANDIDATE | VERIFIED | systemone-native | G4 PENDING: pending engine advance (FR-085): pinned tree has arch qwen35=yes, /v1/systemone=no; needs llama.cpp >= b11361 |
| laya | ggml-org/Laya-GGUF | ADMIT-CANDIDATE | VERIFIED | systemone-native | G4 PENDING: pending engine advance (FR-085): pinned tree has arch modern-bert=yes, /v1/systemone=no; needs llama.cpp >= b11361 |
| openjev-gguf | ggml-org/OpenJev-GGUF | REJECTED | VERIFIED | systemone-native | G1: weights licence cc-by-nc-4.0 is not on the allow-list ['apache-2.0', 'mit', 'bsd-2-clause', 'bsd-3-clause', 'cc-by-4.0', 'cc0-1.0', 'isc', 'unlice |
| lev | ggml-org/lev-GGUF | ADMIT-CANDIDATE | VERIFIED | systemone-native | G4 PENDING: pending engine advance (FR-085): pinned tree has arch qwen35=yes, /v1/systemone=no; needs llama.cpp >= b11361 |
| verdict-2.0 | heman10x/openJev-verdict-2.0 | NOT-FOUND | AMBIGUOUS | unsupported | existence AMBIGUOUS: HTTP 401: huggingface.co answers 401 for both private and non-existent repos; cannot be told apart anonymously |
| verdict-151m | heman10x/rlcd-modernbert-151m | USER-ONLY | VERIFIED | unsupported | G6: unsupported / unclassified protocol (curated hint 'unsupported'); fail closed |
| kev-4b-upstream | jaredpalmer/kev-4b | USER-ONLY | VERIFIED | unsupported | G3: no GGUF or ONNX file in the repo to pin (siblings: ['.gitattributes', 'README.md', 'adapter_config.json', 'adapter_model.safetensors', 'added_toke |
| jevhome-b | jevhome/jevhome-B | REJECTED | VERIFIED | unsupported | G1: weights licence cc-by-nc-4.0 is not on the allow-list ['apache-2.0', 'mit', 'bsd-2-clause', 'bsd-3-clause', 'cc-by-4.0', 'cc0-1.0', 'isc', 'unlice |
| local-jev | - | REJECTED | UNVERIFIED | unsupported | no weights artifact: harness / library, not a model (kind=harness) |
| opendecider-nano | manjunathshiva/opendecider-nano | USER-ONLY | VERIFIED | unsupported | G3: no GGUF or ONNX file in the repo to pin (siblings: ['.gitattributes', 'LICENSE', 'README.md', 'config.json', 'head.safetensors', 'model.safetensor |
| opendecider-small | manjunathshiva/opendecider-small-GGUF | USER-ONLY | VERIFIED | unsupported | G6: unsupported / unclassified protocol (curated hint 'unsupported'); fail closed |
| typecastlm | mihailgribov/typecastlm-qwen3.5-3.8b | USER-ONLY | VERIFIED | unsupported | G6: unsupported / unclassified protocol (curated hint 'unsupported'); fail closed |
| laya-typed-decisions-gguf | mys/laya-typed-decisions-GGUF | USER-ONLY | VERIFIED | unsupported | G6: unsupported / unclassified protocol (curated hint 'unsupported'); fail closed |
| kev-onnx | onnx-community/kev-4b-ONNX | USER-ONLY | VERIFIED | unsupported | G6: unsupported / unclassified protocol (curated hint 'unsupported'); fail closed |
| openjev-27b | openjev/openjev | REJECTED | VERIFIED | unsupported | G1: weights licence cc-by-nc-4.0 is not on the allow-list ['apache-2.0', 'mit', 'bsd-2-clause', 'bsd-3-clause', 'cc-by-4.0', 'cc0-1.0', 'isc', 'unlice |
| pplx-decider-27b | perplexity-ai/pplx-decider-v1-27b | USER-ONLY | VERIFIED | unsupported | G3: no GGUF or ONNX file in the repo to pin (siblings: ['.gitattributes', 'LICENSE', 'NOTICE', 'README.md', 'chat_template.jinja', 'config.json', 'dec |
| poorjev | - | REJECTED | UNVERIFIED | unsupported | no weights artifact: harness / library, not a model (kind=harness) |
| fern | reoring/fern | USER-ONLY | VERIFIED | unsupported | G3: no GGUF or ONNX file in the repo to pin (siblings: ['.gitattributes', 'README.md', 'chat_template.jinja', 'config.json', 'eval.json', 'generation_ |
| decide-pro | rizzoaiacademy/rizzo-flow | ADMIT-CANDIDATE | VERIFIED | letter-logit | G9 PENDING: live upstream issue-tracker sweep not done by this driver (offline); none recorded in the research register |
| semif | - | REJECTED | UNVERIFIED | unsupported | no weights artifact: harness / library, not a model (kind=harness) |
| rsi-jev | shgao/rsi-jev-v1.0-qwen3.5-2b | USER-ONLY | VERIFIED | unsupported | G3: no GGUF or ONNX file in the repo to pin (siblings: ['.gitattributes', 'README.md', 'code/load_release.py', 'code/rsijev/__init__.py', 'code/rsijev |
| startlux-decision-4b | startlux-models/StartLux-Decision-4B-Q8_0-GGUF | REJECTED | VERIFIED | unsupported | G1: weights licence cc-by-nc-4.0 is not on the allow-list ['apache-2.0', 'mit', 'bsd-2-clause', 'bsd-3-clause', 'cc-by-4.0', 'cc0-1.0', 'isc', 'unlice |

## Honest gaps (what this paper run does NOT establish)

- G10 (loadability, smoke answer, determinism repeats, option-order sensitivity, measured memory) is PENDING for every non-rejected candidate: no weights were downloaded and nothing was run. A paper pass is not admission (FR-007).
- No real-run executor script exists yet; `LLMCTL_ADMIT_REAL_RUN` must point at one (it is called as `<exe> <repo> <record.json>` and must print the JSON documented in docs/scripts/admit.md). The commands above are therefore the intended invocation, not something that can be run today.
- The protocol class comes from the API's `gguf.decision_type` when present and otherwise from the curated hint in candidates.tsv (VENDOR-CLAIM / paper); an unhinted candidate is `unsupported` (fail closed), so USER-ONLY here can mean 'no hint was curated', not 'proven unusable'.
- G9 is PENDING everywhere except the recorded blocking issue: upstream issue trackers were not queried by the driver (offline logic); the notes come from research/web-candidate-models.md.
- G3: non-LFS auxiliary files have no sha256 in the API; they stay PENDING until a pin step computes it.
- Non-HF names (GitHub/PyPI tools) were not probed; existence is UNVERIFIED by this driver and their REJECTED disposition rests on the research register (no weights artifact).
- G4 for native-decision models is PENDING the engine advance (FR-085): the pinned tree has the architectures but not `/v1/systemone`.
- Differences from the research register are possible because the gates are mechanical: e.g. repos holding only adapters or safetensors come out USER-ONLY here where the register says REJECT.
