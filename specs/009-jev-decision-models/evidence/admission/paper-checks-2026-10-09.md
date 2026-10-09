# Paper admission checks, refreshed 2026-10-09 (T091 / T094 / T092 groundwork)

| Field | Value |
|---|---|
| Date (UTC) | 2026-10-09 |
| Method | `LLMCTL_ADMIT_EVIDENCE_DIR=<scratch> llmctl admit --all --paper-only` (candidates: `candidates.tsv`, 48 rows) against the live Hugging Face API; metadata only, no weights downloaded |
| Pinned engine tree read by G4 | `submodules/llama.cpp` at `b11379` (`git describe`), which contains `POST /v1/systemone` |
| Machine-readable | `paper-checks-2026-10-09.json` (condensed) and `paper-2026-10-09/*.json` (full per-candidate records, schema `llmctl.admission/1`) |
| Committed baseline NOT modified | `SUMMARY.md`, `SUMMARY.json` and the 2026-10-07 per-candidate records in this directory are untouched |
| Registry | No ADMITTED / USER-ONLY / REJECTED field exists in `models/catalog.json`; the only verdict store is these evidence records (written by `llmctl admit` itself). Nothing was written to the catalog. |
| Result | 0 ADMITTED, 13 ADMIT-CANDIDATE, 19 USER-ONLY, 1 HOLD, 14 REJECTED, 1 NOT-FOUND (identical counts to the 2026-10-07 run) |

A paper check never means ADMITTED. G9 (upstream issue sweep) and G10 (real run) are PENDING for every non-rejected candidate.

## What changed vs the 2026-10-07 record (honest delta)

- G4 for the six `systemone-native` ADMIT-CANDIDATEs (Julia-1, Kev-0.8B/4B/9B, Laya, lev) is now **PASS** (arch present and `/v1/systemone` present in the b11379 tree). The 2026-10-07 SUMMARY showed G4 PENDING (pre engine-advance, T093). Their disposition stays ADMIT-CANDIDATE because G9/G10 remain PENDING.
- Dispositions, existence verdicts and all other gate results are unchanged.
- `candidates.tsv` has 48 rows, not 41; the "41 named candidates" in T091 is the count in the research register. UNCONFIRMED which 7 rows were added later (not investigated).

## Gate legend

Column "G1..G10": one letter per gate in order, `P` PASS, `F` FAIL, `?` PENDING, `-` SKIP. G1 licence allow-list, G2 stable revision, G3 pinned size+sha256, G4 loadable by pinned engine, G5 budgets, G6 protocol/contract, G7 supply chain (no pickle), G8 provenance, G9 known-issue sweep, G10 real run. "Profile" is the existing `models/catalog.json` profile for that repo (a registered profile is not the same as ADMITTED).

## All 48 candidates

| Repo | Disposition | Existence | Protocol | G1..G10 | Largest pin | Profile | First reason |
|---|---|---|---|---|---|---|---|
| 3ntr0py-t4m3r/GLiNER2.5-Decide-GGUF | USER-ONLY | VERIFIED | systemone-native | `PPPFPPPP?-` | 0.30 GB | - | G4: GGUF arch 'deberta-v3' is absent from the pinned tree and an engine bump is not proven to add it (custom / |
| EldanRing/Winnow-12B | USER-ONLY | VERIFIED | unsupported | `PPP-FFPP?-` | 12.67 GB | - | G5: over the file-size budget: largest model file gguf/Winnow-12B-Q8_0.gguf = 12669646592 B (cap 10737418240 B |
| EldanRing/Winnow-E4B | USER-ONLY | VERIFIED | unsupported | `PPP-PFPP?-` | 8.01 GB | - | G6: unsupported / unclassified protocol (curated hint 'unsupported'); fail closed |
| Kestrelyn/kestrel-decider-230m | REJECTED | VERIFIED | unsupported | `FPF--FPP?-` | - | - | G1: weights licence other is not on the allow-list ['apache-2.0', 'mit', 'bsd-2-clause', 'bsd-3-clause', 'cc-b |
| Manav2op/verdict-small | USER-ONLY | VERIFIED | unsupported | `PPP-PFPP?-` | 0.12 GB | - | G6: unsupported / unclassified protocol (curated hint 'unsupported'); fail closed |
| Mapika/decider-2b-GGUF | ADMIT-CANDIDATE | VERIFIED | letter-logit | `PP?PPPPP??` | 1.27 GB | - | G3 PENDING: model sha256 pinned from the API LFS oid (decider-2b-v11-Q4_K_M.gguf=b7c132a67934...); aux file(s) |
| Mapika/decider-4b-GGUF | ADMIT-CANDIDATE | VERIFIED | letter-logit | `PP?PPPPP??` | 2.71 GB | decide | G3 PENDING: model sha256 pinned from the API LFS oid (decider-4b-v2.1-Q4_K_M.gguf=c7083fcfc93f...); aux file(s |
| MoritzLaurer/deberta-v3-large-zeroshot-v2.0 | ADMIT-CANDIDATE | VERIFIED | nli-onnx | `PPPPPPPP??` | 1.74 GB | decide-nli | G9 PENDING: live upstream issue-tracker sweep not done by this driver (offline); none recorded in the research |
| StrandsAgents/strands-decider-2B-hobson-v21 | USER-ONLY | VERIFIED | unsupported | `PPF--FPP?-` | - | - | G3: no GGUF or ONNX file in the repo to pin (siblings: ['.gitattributes', 'LICENSE.md', 'MANIFEST.sha256', 'RE |
| TokenRhythm/NeoHorse-Jev-4B-GGUF | USER-ONLY | VERIFIED | unsupported | `PPP-PFPP?-` | 3.39 GB | - | G6: unsupported / unclassified protocol (curated hint 'unsupported'); fail closed |
| alibiserikbay/JevK5-GGUF | ADMIT-CANDIDATE | VERIFIED | letter-logit | `PPPPPPPP??` | 9.53 GB | decide-max | G9 PENDING: live upstream issue-tracker sweep not done by this driver (offline); none recorded in the research |
| anyjev (no HF repo) | REJECTED | UNVERIFIED | unsupported | `----------` | - | - | no weights artifact: harness / library, not a model (kind=harness) |
| apus-ailab/APUS-OpenJev-v1-4B-GGUF | ADMIT-CANDIDATE | VERIFIED | letter-logit | `PPPPPPPP??` | 4.48 GB | - | G9 PENDING: live upstream issue-tracker sweep not done by this driver (offline); none recorded in the research |
| autotrust/JEV-9B | USER-ONLY | VERIFIED | unsupported | `PPF--FPP?-` | - | - | G3: no GGUF or ONNX file in the repo to pin (siblings: ['.gitattributes', 'README.md', 'adapter/README.md', 'a |
| avbiswas/bev-decider-0.4B | REJECTED | VERIFIED | unsupported | `FPF--FPP?-` | - | - | G1: weights licence cc-by-nc-4.0 is not on the allow-list ['apache-2.0', 'mit', 'bsd-2-clause', 'bsd-3-clause' |
| chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF | ADMIT-CANDIDATE | VERIFIED | letter-logit | `PPPPPPPP??` | 0.53 GB | decide-tiny | G9 PENDING: live upstream issue-tracker sweep not done by this driver (offline); none recorded in the research |
| clm (no HF repo) | REJECTED | UNVERIFIED | unsupported | `----------` | - | - | no weights artifact: harness / library, not a model (kind=harness) |
| com-kotobalabs/open-jev-deberta-v3-large | USER-ONLY | VERIFIED | unsupported | `PPF--FPP?-` | - | - | G3: no GGUF or ONNX file in the repo to pin (siblings: ['.gitattributes', 'README.md', 'added_tokens.json', 'c |
| djev (no HF repo) | REJECTED | UNVERIFIED | unsupported | `----------` | - | - | no weights artifact: harness / library, not a model (kind=harness) |
| edgejev (no HF repo) | REJECTED | UNVERIFIED | unsupported | `----------` | - | - | no weights artifact: harness / library, not a model (kind=harness) |
| fastino/GLiNER2.5-Decide | USER-ONLY | VERIFIED | unsupported | `PPF--FPP?-` | - | - | G3: no GGUF or ONNX file in the repo to pin (siblings: ['.gitattributes', 'GLiNER-2.5-Decision-HF-Banner.png', |
| ggml-org/Bespoke-Nimble-9B-v3-GGUF | REJECTED | VERIFIED | systemone-native | `FPPPPPPP?-` | 6.32 GB | - | G1: weights licence cc-by-nc-4.0 is not on the allow-list ['apache-2.0', 'mit', 'bsd-2-clause', 'bsd-3-clause' |
| ggml-org/Clef-Flash-GGUF | HOLD | VERIFIED | systemone-native | `PPPPPPPPF-` | 6.49 GB | - | G9: blocking open issue recorded: llama.cpp#30064 Q8_0 head quantisation collapses probabilities toward unifor |
| ggml-org/Julia-1-GGUF | ADMIT-CANDIDATE | VERIFIED | systemone-native | `PPPPPPPP??` | 0.17 GB | decide-julia | G9 PENDING: non-blocking note recorded (llama.cpp#30073 large inputs rejected at default physical batch 512 (o |
| ggml-org/Kev-0.8B-GGUF | ADMIT-CANDIDATE | VERIFIED | systemone-native | `PPPPPPPP??` | 0.81 GB | decide-kev-08b | G9 PENDING: non-blocking note recorded (llama.cpp#30073 large inputs rejected at default physical batch 512 (o |
| ggml-org/Kev-4B-GGUF | ADMIT-CANDIDATE | VERIFIED | systemone-native | `PPPPPPPP??` | 3.03 GB | decide-kev-4b | G9 PENDING: non-blocking note recorded (llama.cpp#30073 large inputs rejected at default physical batch 512 (o |
| ggml-org/Kev-9B-GGUF | ADMIT-CANDIDATE | VERIFIED | systemone-native | `PPPPPPPP??` | 6.36 GB | decide-kev-9b | G9 PENDING: non-blocking note recorded (llama.cpp#30073 large inputs rejected at default physical batch 512 (o |
| ggml-org/Laya-GGUF | ADMIT-CANDIDATE | VERIFIED | systemone-native | `PPPPPPPP??` | 0.45 GB | decide-laya | G9 PENDING: non-blocking note recorded (llama.cpp#30073 large inputs rejected at default physical batch 512 (o |
| ggml-org/OpenJev-GGUF | REJECTED | VERIFIED | systemone-native | `FPPPFPPP?-` | 18.97 GB | - | G1: weights licence cc-by-nc-4.0 is not on the allow-list ['apache-2.0', 'mit', 'bsd-2-clause', 'bsd-3-clause' |
| ggml-org/lev-GGUF | ADMIT-CANDIDATE | VERIFIED | systemone-native | `PPPPPPPP??` | 3.01 GB | decide-lev | G9 PENDING: non-blocking note recorded (llama.cpp#30073 large inputs rejected at default physical batch 512 (o |
| heman10x/openJev-verdict-2.0 | NOT-FOUND | AMBIGUOUS | unsupported | `----------` | - | - | existence AMBIGUOUS: HTTP 401: huggingface.co answers 401 for both private and non-existent repos; cannot be t |
| heman10x/rlcd-modernbert-151m | USER-ONLY | VERIFIED | unsupported | `PPP-PFPP?-` | 0.61 GB | - | G6: unsupported / unclassified protocol (curated hint 'unsupported'); fail closed |
| jaredpalmer/kev-4b | USER-ONLY | VERIFIED | unsupported | `PPF--FPP?-` | - | - | G3: no GGUF or ONNX file in the repo to pin (siblings: ['.gitattributes', 'README.md', 'adapter_config.json',  |
| jevhome/jevhome-B | REJECTED | VERIFIED | unsupported | `FPP-PFPP?-` | 0.60 GB | - | G1: weights licence cc-by-nc-4.0 is not on the allow-list ['apache-2.0', 'mit', 'bsd-2-clause', 'bsd-3-clause' |
| local-jev (no HF repo) | REJECTED | UNVERIFIED | unsupported | `----------` | - | - | no weights artifact: harness / library, not a model (kind=harness) |
| manjunathshiva/opendecider-nano | USER-ONLY | VERIFIED | unsupported | `PPF--FPP?-` | - | - | G3: no GGUF or ONNX file in the repo to pin (siblings: ['.gitattributes', 'LICENSE', 'README.md', 'config.json |
| manjunathshiva/opendecider-small-GGUF | USER-ONLY | VERIFIED | unsupported | `PPP-PFPP?-` | 2.50 GB | - | G6: unsupported / unclassified protocol (curated hint 'unsupported'); fail closed |
| mihailgribov/typecastlm-qwen3.5-3.8b | USER-ONLY | VERIFIED | unsupported | `PPP-PFPP?-` | 4.01 GB | - | G6: unsupported / unclassified protocol (curated hint 'unsupported'); fail closed |
| mys/laya-typed-decisions-GGUF | USER-ONLY | VERIFIED | unsupported | `PPP-PFPP?-` | 0.42 GB | - | G6: unsupported / unclassified protocol (curated hint 'unsupported'); fail closed |
| onnx-community/kev-4b-ONNX | USER-ONLY | VERIFIED | unsupported | `PPP-PFPP?-` | 0.00 GB | - | G6: unsupported / unclassified protocol (curated hint 'unsupported'); fail closed |
| openjev/openjev | REJECTED | VERIFIED | unsupported | `FPF--FPP?-` | - | - | G1: weights licence cc-by-nc-4.0 is not on the allow-list ['apache-2.0', 'mit', 'bsd-2-clause', 'bsd-3-clause' |
| perplexity-ai/pplx-decider-v1-27b | USER-ONLY | VERIFIED | unsupported | `PPF--FPP?-` | - | - | G3: no GGUF or ONNX file in the repo to pin (siblings: ['.gitattributes', 'LICENSE', 'NOTICE', 'README.md', 'c |
| poorjev (no HF repo) | REJECTED | UNVERIFIED | unsupported | `----------` | - | - | no weights artifact: harness / library, not a model (kind=harness) |
| reoring/fern | USER-ONLY | VERIFIED | unsupported | `PPF--FPP?-` | - | - | G3: no GGUF or ONNX file in the repo to pin (siblings: ['.gitattributes', 'README.md', 'chat_template.jinja',  |
| rizzoaiacademy/rizzo-flow | ADMIT-CANDIDATE | VERIFIED | letter-logit | `PPPPPPPP??` | 4.38 GB | decide-pro | G9 PENDING: live upstream issue-tracker sweep not done by this driver (offline); none recorded in the research |
| semif (no HF repo) | REJECTED | UNVERIFIED | unsupported | `----------` | - | - | no weights artifact: harness / library, not a model (kind=harness) |
| shgao/rsi-jev-v1.0-qwen3.5-2b | USER-ONLY | VERIFIED | unsupported | `PPF--FPP?-` | - | - | G3: no GGUF or ONNX file in the repo to pin (siblings: ['.gitattributes', 'README.md', 'code/load_release.py', |
| startlux-models/StartLux-Decision-4B-Q8_0-GGUF | REJECTED | VERIFIED | unsupported | `FPP-PFPP?-` | 4.48 GB | - | G1: weights licence cc-by-nc-4.0 is not on the allow-list ['apache-2.0', 'mit', 'bsd-2-clause', 'bsd-3-clause' |

Cross-cutting checks (from the full records; every non-rejected repo): `gated` is false for all 40 VERIFIED repos that returned an `api` block (UNCONFIRMED for the 8 candidates without an HF repo or the AMBIGUOUS 401 repo `heman10x/openJev-verdict-2.0`, which anonymous HTTP cannot tell apart from private). G7 (pickle) PASS everywhere it was evaluated. Licences: G1 FAILs are CC-BY-NC-4.0 (avbiswas bev-decider, ggml-org OpenJev-GGUF, Bespoke-Nimble-9B, jevhome-B, openjev, StartLux) plus `other` (Kestrelyn). Size vs budget (G5): only Winnow-12B (12.67 GB, cap 10.74 GB) and OpenJev-GGUF (18.97 GB) exceed the file cap.

## Proposed registry statuses (NOT written; propose only)

| Class | Candidates | Proposed status | Evidence |
|---|---|---|---|
| Already shipped profile, ADMIT-CANDIDATE | Mapika/decider-4b (`decide`), deberta-v3-large-zeroshot (`decide-nli`), JevK5 (`decide-2b`, `decide-max`), Jev-Style-0.8B (`decide-tiny`), rizzo-flow (`decide-pro`), Julia-1, Kev-0.8B/4B/9B, Laya, lev (6 native profiles) | stay ADMIT-CANDIDATE; ADMITTED only after G9 sweep + a G10 run through the executor | records above; live runs in `evidence/live-models/INDEX.md` are not G10 executor output (UNCONFIRMED whether they satisfy the five G10 sub-checks) |
| Not yet a profile, ADMIT-CANDIDATE | Mapika/decider-2b-GGUF, apus-ailab/APUS-OpenJev-v1-4B-GGUF | ADMIT-CANDIDATE (needs profile + G10) | all of G1..G8 PASS |
| HOLD | ggml-org/Clef-Flash-GGUF | HOLD (llama.cpp#30064, open at 2026-10-07; not re-queried today) | G9 FAIL recorded from the research register |
| USER-ONLY (19) | GLiNER2.5 variants, Winnow-12B/E4B, verdict-small, strands-decider, NeoHorse, autotrust, open-jev-deberta, kev-4b-upstream, kev-onnx, opendecider-*, typecastlm, laya-typed-decisions, rsi-jev, pplx-decider-27b, fern, rlcd-modernbert | USER-ONLY (overlay path, own risk) | mostly G6 unsupported-protocol or G3 no GGUF/ONNX to pin; caveat: `unsupported` means "no curated protocol hint", not proven unusable |
| REJECTED (14) | 6 CC-BY-NC / `other` licence repos + 8 harness/library names with no weights | REJECTED | G1 FAIL or `kind=harness` |
| NOT-FOUND | heman10x/openJev-verdict-2.0 | NOT-FOUND (existence AMBIGUOUS; retry with `HF_TOKEN`) | HTTP 401 |

## T094 specifics

- T094 text says "decider-2b". The catalog profile named `decide-2b` is **alibiserikbay/JevK5-GGUF** (JevK5 2B v0.2 Q8_0), not Mapika. **Mapika/decider-2b-GGUF is not in the catalog** (grep of `hf_repo` confirms). The status doc's "decide-2b is in models/catalog.json" therefore does not satisfy a Mapika decider-2b reading. Which one T094 means is UNCONFIRMED; research (`web-candidate-models.md` line 194) calls Mapika decider-2b "`decide-2b` alternative". Both are letter-logit.
- APUS-4B HF repo id: `apus-ailab/APUS-OpenJev-v1-4B-GGUF`, rev `7389d774472c9e29ddc84fffb392951f0f25de74` (2026-09-23), Apache-2.0, not gated, one file `APUS-OpenJev-v1-4B-Q8_0.gguf` 4,482,403,168 B sha256 `5e57075a169a76de5150f5c5defd805525ce4df86ae8865f70f128e15e57416c`, arch `qwen35` (present in the b11379 tree), chat template embedded, G1..G8 PASS, memory ESTIMATE 5.43 GiB (size*1.3, `workstation` tier). Q4_K_M variant 2.71 GB exists per research.
- Mapika/decider-2b-GGUF: rev `ff2e5e68...` per research, Apache-2.0, `decider-2b-v11-Q4_K_M.gguf` 1,274,396,800 B sha256 `b7c132a67934d51c81abc96bb7724800f965ff5a288aed3e1ca7d8bc349c1386`, G1..G8 PASS (the auxiliary `decider_config.json` is non-LFS and has no API sha256; G3 note says it must be pinned by computing the hash after a download of ~KB).
- To close T094: add a profile entry (copy `decide`'s block: `engine llama`, `decision.protocol letter-logit`, sha256/size above), then G10 run. Neither profile was added here (no commit, no catalog edit).

## What a real run (G10) needs for the 8 ADMIT-CANDIDATEs

"The 8 new ADMIT-CANDIDATEs" are, per SUMMARY.md: Mapika/decider-2b, APUS-4B, Julia-1, Kev-0.8B, Kev-4B, Kev-9B, Laya, lev. Six of them already have catalog profiles and prior live runs (`evidence/live-models/INDEX.md`); only decider-2b and APUS-4B are unprofiled. No real-run executor exists (`LLMCTL_ADMIT_REAL_RUN` unset; G-013), so none can be run through `llmctl admit` today.

| Candidate | Download | Est. memory (size*1.3) | anton (31 GiB + RTX 3060 12 GB) | nezha (62 GiB, CPU) | factory (251 GiB, RTX 5090 32 GB) | Engine |
|---|---|---|---|---|---|---|
| Mapika/decider-2b-GGUF (Q4_K_M) | 1.27 GB | 1.5 GiB | fits | fits | fits | stock llama-server, letter-logit |
| APUS-OpenJev-v1-4B (Q8_0) | 4.48 GB | 5.4 GiB | fits (GPU) | fits | fits | stock llama-server, letter-logit |
| ggml-org/Julia-1-GGUF | 0.17 GB | 0.2 GiB | fits | fits | fits | b11379 `/v1/systemone` (modern-bert) |
| ggml-org/Kev-0.8B-GGUF | 0.81 GB | 1.0 GiB | fits | fits | fits | qwen35, systemone |
| ggml-org/Kev-4B-GGUF (Q4_K_M) | 3.03 GB | 3.7 GiB | fits | fits | fits | qwen35, systemone |
| ggml-org/Kev-9B-GGUF | 6.36 GB | 7.7 GiB | CUDA OOM seen on anton (INDEX.md); CPU only | fits (ran there) | fits easily | qwen35, systemone |
| ggml-org/Laya-GGUF | 0.45 GB | 0.5 GiB | fits | fits | fits | modern-bert, systemone |
| ggml-org/lev-GGUF | 3.01 GB | 3.6 GiB | fits | fits | fits | qwen35, systemone |

Total download for all eight: about 19.6 GB (decider-2b Q4_K_M + APUS Q8_0 + the six native files). Host memory columns are the driver's flat estimate, not measurements (UNCONFIRMED for the factory host: it was not probed; the RTX 5090 32 GB / 251 GiB figures come from the task statement). Peak memory of a native decision engine is higher than size*1.3 (compute buffer sized from `--ubatch-size 4096`, see the catalog.py comment), so measured numbers must replace these before ADMITTED.

Recommendation: all eight fit on the factory host with large margin and can be run autonomously there later, in this order: (1) build the missing real-run executor (G-013, "T091b"), a code task, not host-bound; (2) decider-2b and APUS-4B after adding profiles; (3) the six native ones, re-run on the clean pinned release tree (the INDEX notes kev-4b/9b/lev ran on an unpinned earlier tree); (4) a G9 sweep needs outbound GitHub/HF issue queries, which the driver does not do offline. Run under `bounded-run -m` limits and do not run Kev-9B on anton's GPU.

## T092: encoder bring-your-own example

Existing mechanism (grep-verified): the only override seam is the env var `LLMCTL_CATALOG` (`lib/common.sh:43`), which replaces the whole catalog file; there is no merge-style overlay and no `catalog.d`. Docs (`docs/decision-models.md:60`, `docs/faq.md:387`) mention "your own catalog overlay" for StartLux without steps, and no test or doc demonstrates a USER-ONLY encoder. Spec FR-008 and idea 3-I12 ask for one; the nominated model in `research/ideas-closure.md` is `cross-encoder/nli-deberta-v3-large` (Apache-2.0).

Feasible without a large download: yes. Chosen small public encoder: **cross-encoder/nli-deberta-v3-xsmall**, Apache-2.0, not gated, rev `a150876415327c80daeff35ca6f68f5ed8cf5c24`. Files the `onnx` engine needs: `onnx/model.onnx` 284,200,859 B (sha256 `7105da41...5d4`), `spm.model` 2,464,616 B, `config.json` 1,053 B, `tokenizer_config.json` 1,346 B: **total 286.7 MB** (under 300 MB). `id2label` is `{0: contradiction, 1: entailment, 2: neutral}`. Smaller alternative: the same repo's `onnx/model_qint8_avx512.onnx` (87 MB), but the runner only looks for `model.onnx` (`lib/onnx_server.py` `_find_first(model_dir, "model.onnx")`), so it would need renaming at install time; not tried.

Done now (no download): a profile fragment `byo-nli-xsmall-profile.json` (this directory), cloned from `decide-nli` with the real sizes/sha256/revision above. Merged into a scratch copy of the catalog and used with `LLMCTL_CATALOG=<copy> llmctl models list`, the profile is accepted and listed (`byo-nli-xsmall 8096 onnx 1 below-minimum decide`). `llmctl models verify byo-nli-xsmall` correctly says not downloaded. `tests/test_catalog_json.sh` still passes (it tests the shipped catalog, not the overlay). Defect to fix in the example: the cloned `port` (8096) collides with `decide-nli`; give the BYO profile an unused port in both `profiles.<n>.port` and the top-level `ports` map.

Exact steps for the real demo (NOT run; the download is about 287 MB):
1. `cp models/catalog.json ~/llmctl-byo.json`; merge the fragment's profile under `profiles` and add its name to `ports` with a free port.
2. `export LLMCTL_CATALOG=~/llmctl-byo.json`; `llmctl models list` (profile shows).
3. `bounded-run -m 3G -t 600 -T 900 -q -- llmctl models download byo-nli-xsmall` (verified download; the onnx smoke needs onnxruntime and sentencepiece via `llmctl build onnx`).
4. `llmctl decide smoke --url http://127.0.0.1:<port> --protocol nli-onnx` or `llmctl decide ...` with the profile; record output in `evidence/admission/byo-encoder-example/`.
5. Add a doc section (docs/decision-models.md) and a test; the existing `tests/test_onnx_download.sh` is the template (local fixture, stub backends).
Not claimed: that the xsmall encoder gives usable decisions (accuracy unmeasured), or that the download and smoke succeed.

## Tests

`bash tests/test_admit.sh` under `bounded-run -m 3G -t 300 -T 600`: RESULT: PASS (run 2026-10-09). There is no other `tests/test_admit*.sh`.

## Remaining / not done

- No registry/catalog/tasks.md edits; no commits.
- T091 and T094 stay open: real runs (G10), G9 sweeps and the executor are missing; T094 profile entries absent.
- T092 stays open: fragment prepared and validated for listing only; no download, test or doc yet.
