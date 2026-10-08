# Source Material Findings Register — 009-jev-decision-models

**Created**: 2026-10-07 | **Status**: Draft (input to planning) | **Spec**: [spec.md](spec.md)

This register records what was found in `/home/milosvasic/Projects/jev` by four independent read-only analyses (conversation `Jev.md`; research and QA documents; the second team's code; the toolkit and constitution snapshots). **Provenance of every finding:** subagent report, read-only, this session. Findings marked CONFIRMED were seen in code by the analyst; SUSPECTED were inferred. **None has yet been independently reproduced by us.** FR-040 requires each defect to be reproduced by a failing test on the unmodified candidate before it is fixed; until then the status of every row below is `UNREPRODUCED`.

Severity is a first-pass triage for planning (H = fix before release, M = fix or record accepted limitation, L = fix or document).

## A. Material inventory and disposition

| Source | Size / content | Disposition |
|---|---|---|
| `jev/Jev.md` | 3,715 lines, search-augmented AI Q&A; no citations | Context only. Facts verified individually before use (Section E). |
| `jev/llmctl/llmctl/` | Modified llmctl copy, no `.git`, VERSION 3.0.2, post-3.0.2 main snapshot + decision work | Candidate implementation. Merge by comparison onto HEAD `a9ebefe` (FR-044). |
| `jev/llmctl/llmctl.tar.gz`, `.zip` | Archives | Verified identical to the directory by the analyst (635/634 entries). Not imported. |
| `jev/claude_toolkit/` | Toolkit v1.30.5 snapshot; the Jev work is absent from the real toolkit repo (v1.30.4) | External consumer for contract checks only (US9). |
| `jev/constitution/` | Constitution tag v70 snapshot, **reduced tree** (286 gate scripts and 156 fast-cycle files present in our pin are absent) | Anchors §11.4.277–284 read as requirements; tree not adopted. |
| `jev/constitution/Prompt.md` | 596-line setup prompt for the v70 decision layer | Read; its llmctl-facing requirements are captured in FR-028/029/036 and US9. |
| `docs/research/*` (5 files), `docs/qa/decision-models-validation/*` (4 files) | Hash research, ecosystem survey, architecture map, three captured test outputs | Re-verified (Sections C, D); moved into the repo only after correction. |

## B. Defects in the candidate implementation

| ID | Sev | Finding | Evidence (candidate tree) | Status |
|---|---|---|---|---|
| D-01 | H | Encoder path truncates the combined text to 512 tokens **from the end**; for states beyond ~470 tokens the hypothesis (instructions + option) is cut off and the model answers on the state alone, with no error and no truncation header. Gateway cap is 8,192 characters, so this is reachable. | `lib/onnx_server.py:253,256` | **OPEN** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED, CONFIRMED by reading |
| D-02 | H | API-key mismatch: scheduler starts the encoder runtime with a key, but the CLI and the gateway proxy never send one → 401 / 502 whenever a key is set. Untested combination. | `lib/scheduler.sh:427-428`, `lib/decide_gateway.py:241-251`, `lib/decide.sh:331-334` | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED, CONFIRMED |
| D-03 | H | API key passed on command lines (visible in process listings) and written to service env files / plist without owner-only permissions. Violates the credentials rule. | `lib/decide.sh:886-890,904`; `lib/scheduler.sh:428`; `lib/service_linux.sh:273-316`. macOS: `lib/service_macos.sh` itself handles no key; its plist renderer (lines 86-88) copies every argument it is given into the plist, so the key reaches the plist exactly when the caller passes it as an argument, and the file mode of the plist is not set by that file (to be verified in P1) | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED; Linux paths read from source, macOS path inferred and to be verified |
| D-04 | H | No guard against non-loopback bind without credential (default engine bind in this repo is `0.0.0.0`); health endpoint leaks profile name and backend state; docs say loopback only. | `lib/decide_gateway.py:420`, `lib/onnx_server.py:487`, `lib/common.sh:74` | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED, CONFIRMED. Clarifications 1, 4, 5 supersede the guard approach: network-wide + mandatory key + HTTPS only; the plain-HTTP engine servers behind decision profiles also bind to all interfaces by default and must become loopback-only (FR-073). |
| D-05 | H | `decide serve --stop` kills whatever PID is in a pidfile (TERM then KILL) without verifying the process identity; start/write race. | `lib/decide.sh:840-866` | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED, CONFIRMED |
| D-06 | H | No real-model evidence exists: real inference classes (`OnnxModel`) and real `llama-server` readout have never run; `onnxruntime`/`sentencepiece` are not installed here. | QA captures; analyst run | **OPEN** (evidence/sc004-closure.md, 2026-10-08); was: OPEN — addressed by US3 |
| D-07 | M | `SystemExit` raised inside request thread (`die()` when logits count ≠ 3) → connection dropped, no HTTP response. | `lib/onnx_server.py:269` | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED |
| D-08 | M | Non-object JSON body (list / string) → `AttributeError`, connection dropped. | `decide_gateway.py:333`, `onnx_server.py:432` | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED |
| D-09 | M | No concurrency/time limits: unbounded threads, no socket timeout (slow-loris), 26-option request = 26 encoder passes; backend exception text echoed in 502 bodies. | gateway / runtime server code | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED |
| D-10 | M | `LLMCTL_DECIDE_MAX_OPTIONS` ignored by encoder runtime (only hard cap 26); with default 30 s timeout very likely to time out (SUSPECTED, not measured). | `onnx_server.py:317` | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED |
| D-11 | M | Test seams live in production paths: backend host/port env override redirects user state to another host; fake-model env flag lets a download be "verified" without opening the model. | `decide.sh:466,875`; gateway defaults `:421-423`; `_dl_smoke_test_onnx` | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED |
| D-12 | M | Download ends with "SUCCESS … verified" after skipping the smoke test when prerequisites are missing; service then crash-loops under `Restart=always`; `auto decide` ranks the encoder profile 2nd. | `lib/download.sh:604-612` | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED |
| D-13 | M | Three small config files have `sha256: null` and fall back to the same hosting API as the download (trust-on-first-use), yet `config.json` determines label order. | `download.sh:105-135`, catalog | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED |
| D-14 | M | Smoke-test background server has no trap cleanup → orphan on interrupt. | `download.sh:623-627` | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED |
| D-15 | L | Decision unit sets `MemoryHigh`/`MemoryMax` to total host RAM. **Re-assessed by the plan review:** `lib/service_linux.sh:119-130` records the operator decision of 2026-09-15 that served profiles carry no artificial ceiling, so this follows the recorded policy and is not a defect; whether decision units should differ is operator decision OD-14. | `lib/service_linux.sh` | **DEMOTED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED |
| D-16 | M | Unpinned runtime package installs (hints only, no versions or hashes). | `engine.sh`, `onnx_server.py` | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED |
| D-17 | M | Session feeds only two inputs; exports requiring a segment-type input would fail (SUSPECTED); `--tokenizer` never passed by scheduler/smoke/docs, so tokenizer-file-only custom profiles cannot work without hand-editing. | `onnx_server.py:266`, `scheduler.sh:419`, `download.sh:620` | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED |
| D-18 | M | Planner behaviour change: baseline `recommended` set now contains four decision profiles; affects `plan`, `auto`, and eviction alternatives. Intentional or not is undocumented. | `tests/test_planner.sh` diff; `scheduler.sh:590` | **DEMOTED** (evidence/sc004-closure.md, 2026-10-08); was: OPEN — SC-012 |
| D-19 | M | Gateway health-wait always probes 127.0.0.1 regardless of bind; gateway has no service unit (foreground only); hard dependency on `python3` with no fallback. | `decide.sh:913` | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED |
| D-20 | L | `latency_ms` is a multiple of 1000 (uses whole-second counter). | `decide.sh:491,498` | **DEMOTED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED |
| D-21 | L | Wasted pass: yes/no question on the encoder runs both hypotheses but uses one. | `onnx_server.py:346` | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED |
| D-22 | L | Downloaded-but-unused 8.6 MB `tokenizer.json`. | catalog `decide-nli` | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED |
| D-23 | L | Key compare uses `==`, not constant-time. | `decide_gateway.py:285`, `onnx_server.py:395` | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED |
| D-24 | L | Error text in `scheduler.sh:870` still says `(chat\|coder\|vision)`; stale comment `decide.sh:26`; `build` usage omits onnx. | listed | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED |
| D-25 | L | Compiled-cache directories present in tree (`lib/__pycache__`, fixtures); must not be imported or tracked. | tree | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED |
| D-26 | L | Tests cite out-of-tree research path `/mnt/agents/research/...` (binding doc not tracked in repo). | `tests/test_catalog_json.sh` | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED |
| D-27 | L | macOS/launchd path for the encoder runtime untested; system Python may lack packages. | analyst | **ACCEPTED-LIMITATION** (evidence/sc004-closure.md, 2026-10-08); was: UNVERIFIED on this host |
| D-29 | H | Clarification 1 changes the credential model: candidate variable `LLMCTL_DECIDE_API_KEY` is retired in favour of `LLMCTL_API_KEY` (env → `.env` → generate-on-first-start). Every candidate reference (code, tests, docs, unit env files) must be migrated; D-02/D-03 are re-examined under the new model. | all candidate files | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: OPEN — FR-057..063 |
| D-30 | H | Release archive builder (`scripts/release/build_archive.sh`) contains no `.env` exclusion rule; whether a local `.env` holding a real key could enter a published archive is **unverified**. `.gitignore` does ignore `.env` and `.env.*`. Must be proven by a test that builds an archive with a planted `.env` and inspects it. | `scripts/release/build_archive.sh` (no match for `.env`) | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: UNVERIFIED — to test |
| D-31 | L | It is not yet established whether any existing llmctl code reads `.env` (e.g. for the Hugging Face token) or only documents it; the key-resolution mechanism must reuse the existing loader if one exists rather than add a second. | `.env.example`, `lib/*.sh` | **DEMOTED** (evidence/sc004-closure.md, 2026-10-08); was: UNVERIFIED — planning |
| D-28 | M | Prompt-injection residual: state is inserted raw into the lettered prompt for generative profiles. Must be documented and tested for option-order/answer-hijack behaviour. | `render_prompt()` | **FIXED** (evidence/sc004-closure.md, 2026-10-08); was: UNREPRODUCED |

## C. Evidence quality (QA captures)

- Captures ran in a different environment (`/mnt/agents/llmctl`), never on a Linux dev host.
- Totals: stage12 PASS 33 / FAIL 7; stage34 PASS 34 / FAIL 7; iter2 PASS 36 / FAIL 7. The same 7 failures every time (3 need a Go toolchain; 2 need populated submodules; 1 needs a full git checkout; 1 related to constitution inheritance) — environmental, not feature failures, but also **not proof that those 7 pass**.
- Per-suite assertion counts in the final capture (decide 71, gateway 45, download 9, encoder-server 28, encoder-download 21) differ from the documented 55/36/9; analyst re-ran the suites here and also observed 71/45/9/28/21 (all passing). Documentation counts are stale (FR-043).
- Everything is **stand-in based**: stub backend with scripted log-probabilities, a "fake" mode with synthetic logits, toy profiles. No real model download, load or inference appears anywhere. Accuracy numbers are upstream/vendor claims.
- GPU measurements are skipped in the captures.

## D. Documentation inconsistencies in the candidate research

| ID | Finding | Where |
|---|---|---|
| I-01 | Recommends pinning a `v2` tag for the 4B decider; no such tag exists, only `main` carrying `v2.1` files (which ship). | `jev-ecosystem.md:213` vs `decision-model-hashes.md:35,179` |
| I-02 | Claims a 1.7B Q4_K_M variant of Rizzo Flow; it exists only for 4B. | `jev-ecosystem.md:106` vs `decision-model-hashes.md:54,180` |
| I-03 | NLI model described as 0.87 GB / ~0.9 GB RAM; that is the safetensors. The shipped ONNX export is 1,741,985,401 B; planner footprint ≈ size×1.5+512 MiB ≈ 3 GB. | `jev-ecosystem.md:84,175,204,217` vs `encoder-model-hashes.md:10,44,59` |
| I-04 | Laya "~1.5 GB total" vs three checkpoints ≈ 2.33 GB. | `jev-ecosystem.md:124` |
| I-05 | Hash document says "Verified 2025" while everything else says pins captured 2026-10-06. | `decision-model-hashes.md:3` |
| I-06 | Hash sources: the only source was a third-party mirror; the primary host was blocked; "hashes were not re-checked by download". | `decision-model-hashes.md:182` |
| I-07 | QA README says stage12 had "two consecutive passes"; capture has one summary line. | QA README:16-17 |
| I-08 | Architecture doc says "no interactive prompts anywhere" but the candidate adds an interactive wizard. | `llmctl-architecture.md:249` |
| I-09 | `CLAUDE.md` says all servers bind to 127.0.0.1; code and changelog say default `0.0.0.0`. (This is true of the **real** repo today.) | `CLAUDE.md:32`, `lib/common.sh:74` |
| I-10 | Typo `LLMCTX_CTX_<PROFILE>`; engine enum lists only two kinds; profile list stops at 10. | `llmctl-architecture.md:249,69,135` |
| I-11 | Research README revision/timestamp are placeholders (midnight). | `docs/research/README.md:3-4` |

## E. Claims from `Jev.md` that need independent verification before any use

(Line numbers refer to `Jev.md`. None has been checked.)

- Vendor facts: "former OpenAI researcher", 40 M views, 13% of Vercel gateway teams (l.11); pricing $0.042/M input tokens and rate limits (l.74, 822); speed/cost multipliers 193.6x / 444.6x (l.9, 75); "nine documented failure modes" (l.17).
- Benchmarks: hosted Jev 86.6% public / 73.9% vs 74.1% hard (l.674, 1939, 3013); Laya 54.4 composite #33, hard tier 34.1% vs 35.0%, 30.3% order-flip vs 1.8% (l.1944, 2719, 2863, 3013); Kev 67.7%→73.6% after a 15-minute, ~$1 fine-tune (l.1951, 3369); Qwen3.8-Flash-Next 95.8% / 77.5% (l.1941).
- Packages, repositories and identifiers: `amithgc/local-jev` (l.725), `jaredpalmer/kev(-4b)` (l.2735, 3476), `jevcal` (l.1770), `jevassert` (l.2606), `jev-mcp-server`, `jev-pi` vs `pi-jev` (l.913 vs l.1671), `jev-code`, `jev-spec`, `verdictml`, `kev-onnx`, `EdgeJev`, "Strands Decider 2B", gateway projects (l.2626-2635).
- Model names/prices that look invented or future-dated: "Claude Opus 5.5 $4/$20" (l.519-521), `gpt-5.6-luna`, `grok-4.6`, `claude-opus-5` (l.972-974, 3416).
- Internal contradictions: Pi gets an MCP package (l.1063, 1229) then is said to have no MCP client (l.1569); llama.cpp recommendation reverses between table and prose (l.3691 vs 3711); a "fully local" routing example sends two routes to the hosted endpoint (l.3206, 3226); cost table conflates tokens with decisions (l.785-790, 757 vs 806); two different Kev fine-tune flag sets (l.3351 vs 3649); an NLI cross-encoder is assigned to choice/score routes without explanation (l.2290, 2400); the guide relies on hosted CI workflows, which this project forbids.
- Wire-format facts reused by the candidate (hosted request shape, three primitives, confidence formula) are consistent across sources but come from vendor documentation; they will be confirmed against the hosted service's published documentation, or labelled vendor-stated.

## F. Constitution / toolkit contract items the feature must satisfy

| Source anchor | llmctl obligation |
|---|---|
| §11.4.277(A) | Machine-readable plan exposes per-profile decision capacity (`decision_instances`). |
| §11.4.280 | Capacity computed from the plan; callers spread traffic across instances; host safety is the only limiter. |
| §11.4.282(D) | Decision profiles never appear in chat configs; capability excluded from chat selection. |
| §11.4.284 | llmctl is installable/updatable as a pinned dependency; its own installer is what a wrapper invokes. |
| Toolkit snapshot | Expects local gateway at `127.0.0.1:8095` first in priority; reads `/v1/models`; classifies as decision; creates no alias. |
| Our pinned constitution (v68+358, Revision 71) | Does not contain §11.4.276–284 at all; decide in planning whether and how to adopt without losing existing gates. |

## G. Pinned decision profiles (candidate catalog) — to be re-verified (FR-003)

| Profile | Port | Runtime | Min tier | Source / file | Size (B) | License | Claimed benchmark provenance |
|---|---|---|---|---|---|---|---|
| decide-tiny | 8092 | llama | below-minimum | chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF · Q4_K_M | 529,296,864 | Apache-2.0 | vendor |
| decide | 8093 | llama | baseline | Mapika/decider-4b-GGUF · v2.1 Q4_K_M | 2,708,804,640 | Apache-2.0 | vendor + independent |
| decide-pro | 8094 | llama | workstation | rizzoaiacademy/rizzo-flow · 4B Q8_0 | 4,375,021,216 | Apache-2.0 | vendor (disclaims parity) |
| decide-nli | 8096 | onnx | below-minimum | MoritzLaurer/deberta-v3-large-zeroshot-v2.0 · fp32 ONNX + spm.model | 1,741,985,401 | MIT | upstream card; no decision benchmark |
| decide-2b | 8098 | llama | baseline | alibiserikbay/JevK5-GGUF · 2B Q8_0 | 2,012,012,000 | Apache-2.0 | vendor |
| decide-max | 8099 → 8097 (planned: 8099 is held by another program on this host; the catalog value moves to the spare 8097) | llama | workstation | alibiserikbay/JevK5-GGUF · 9B Q8_0 | 9,527,501,280 | Apache-2.0 | vendor |

Gateway: port 8095 (not a catalog profile). Port 8097 unused. Total download for all six ≈ 20.9 GB.

## H. Candidates named but not shipped by the second team (for the register, FR-007)

StartLux-Decision (weights CC BY-NC-4.0 → excluded); Laya (no prebuilt export → bring-your-own path); local-jev, poorjev, APUS reproduction, Open-Jev, SemIf, Kev (4B Apache-2.0 per the conversation), opendecider, djev (not compatible with the engine), Julia 1, GLiNER2.5-Decide, RSI-Jev, fern, Winnow-12B, AnyJev, Verdict/verdictml (151M), CLM, decider (other sizes), Strands Decider 2B, NeoHorse-Jev-4B, Qwen3.8-Flash-Next. Each needs a recorded outcome after verification; none of the above has been verified by us.

## P1 reproduction register (task T013, generated from `tests/red/results/*.jsonl`, 2026-10-07)

Run against the ported, otherwise unmodified candidate. RED = the defect reproduced by a failing test through the real entry point; NOT-REPRODUCED = the test passed (the defect is not present as described); SKIP = cannot be exercised here (reason in the result file); HARDENING = precondition cannot occur with a real model/input, so any fix is defensive hardening and cannot close the item as a defect (Helix §11.4.115(G)). **The D-32 row does not exist; the register's highest id is D-31.**

Totals: 66 entries — 1 HARDENING, 4 NOT-REPRODUCED, 54 RED, 7 SKIP.

| Id | Status | Result file | Excerpt |
|---|---|---|---|
| D-01 | SKIP | `d01_d15.jsonl` | tokenizer files not present (no DeBERTa spm.model under ~/.local/share/llmctl or HF cache; sentencepiece not i |
| D-02 | RED | `d01_d15.jsonl` | gateway(onnx proxy, same key as runtime) answered 502: {"error": "onnx backend query failed: HTTP Error 401: U |
| D-03 | RED | `d01_d15.jsonl` | key present in /proc/<pid>/cmdline of onnx_server / key present in /proc/<pid>/cmdline of decide_gateway / ser |
| D-04 | RED | `d01_d15.jsonl` | scheduler launches encoder runtime with --host 0.0.0.0 by default (rc=0) / unauthenticated onnx /health leaks  |
| D-05 | RED | `d01_d15.jsonl` | decide serve --stop (rc=1) TERM/KILLed unrelated process (a 'sleep 300' we started) because its PID was in the |
| D-06 | SKIP | `d01_d15.jsonl` | OPEN item addressed by US3: no real-model inference can run offline on this host (onnxruntime/sentencepiece ab |
| D-07 | RED | `d01_d15.jsonl` | model returned 2 logits (not 3) -> SystemExit in request thread -> no HTTP response, connection dropped (Remot |
| D-08 | RED | `d01_d15.jsonl` | onnx_server non-object JSON b'[1,2,3]' -> connection dropped (RemoteDisconnected) / onnx_server non-object JSO |
| D-09 | RED | `d01_d15.jsonl` | 502 body echoes backend exception text: {"error": "backend query failed: <urlopen error [Errno 111] Connection |
| D-10 | RED | `d01_d15.jsonl` | LLMCTL_DECIDE_MAX_OPTIONS=3 ignored by encoder runtime: 8-option request -> 200 (8 encoder passes executed) |
| D-11 | RED | `d01_d15.jsonl` | env override LLMCTL_DECIDE_BACKEND_HOST redirected user state to a non-profile host (127.0.0.2) in the product |
| D-12 | RED | `d01_d15.jsonl` | download_profile exit 0 and prints 'downloaded and verified' although the onnx smoke test was SKIPPED (missing |
| D-13 | RED | `d01_d15.jsonl` | decide-nli catalog files without pinned sha256 (trust-on-first-use via HF API): config.json, tokenizer_config. |
| D-14 | RED | `d01_d15.jsonl` | after SIGTERM to the smoke-test shell the onnx_server child (pid 1545746) is still running as an orphan |
| D-15 | NOT-REPRODUCED | `d01_d15.jsonl` | re-assessed as recorded operator policy (2026-09-15), not a defect; unit lines: MemoryHigh=32768M,MemoryMax=32 |
| D-16 | RED | `d16_d32.jsonl` | onnx-server: onnxruntime is not installed - the onnx engine needs it for real inference. Install: pip install  |
| D-17a | RED | `d16_d32.jsonl` | /home/milosvasic/Projects/llmctl/lib/onnx_server.py --model-dir /tmp/llmctl-red-2vrkpc_n/models/decide-nli --h |
| D-17b | RED | `d16_d32.jsonl` | status=400 body={"error": "question 'q': Required inputs (['token_type_ids']) are missing from input feed"} [s |
| D-18 | NOT-REPRODUCED | `d16_d32.jsonl` | recommended=['fast', 'coder', 'vision', 'moe-fast', 'small', 'decide-tiny', 'decide', 'decide-nli', 'decide-2b |
| D-19a | RED | `d16_d32.jsonl` | WARN-line: WARN: decide gateway did not report healthy within 6s (backend may still be starting); check /tmp/l |
| D-19b | RED | `d16_d32.jsonl` | matches='' |
| D-19c | HARDENING | `d16_d32.jsonl` | python3 is a hard dependency by design; a fallback is a feature choice, not asserted |
| D-20 | RED | `d16_d32.jsonl` | latency_ms=[0, 0, 1000] |
| D-21 | RED | `d16_d32.jsonl` | encoder passes=2 |
| D-22 | RED | `d16_d32.jsonl` | lists tokenizer.json=True spm.model=True |
| D-23 | RED | `d16_d32.jsonl` | statuses=401/401 compare_digest calls gateway=0 onnx=0 |
| D-24 | RED | `d16_d32.jsonl` | auto error omits decide: 'ERROR: unknown capability: bogus (chat/coder/vision)' // build usage omits onnx: 'bu |
| D-25 | RED | `d16_d32.jsonl` | ignored=False tracked_pycache=False |
| D-26 | RED | `d16_d32.jsonl` | tests/test_catalog_json.sh |
| D-27 | SKIP | `d16_d32.jsonl` | macOS/launchd path not exercisable on this host |
| D-28 | RED | `d16_d32.jsonl` | status=200 lines_starting_'A) '=2 |
| D-29 | RED | `d16_d32.jsonl` | onnx status=200 gateway status=200; files still using retired LLMCTL_DECIDE_API_KEY=['lib/decide.sh', 'lib/sch |
| D-30 | SKIP | `d16_d32.jsonl` | owned by another agent (release-archive secret test) |
| D-30/tar.gz | RED | `d30.jsonl` | control needle found in tar.gz (instrument sees); secrets present: env -> .env, ca.key -> cert/ca/ca.key, log. |
| D-30/zip | RED | `d30.jsonl` | control needle found in zip (instrument sees); secrets present: env -> .env, ca.key -> cert/ca/ca.key, log.key |
| D-31 | NOT-REPRODUCED | `d16_d32.jsonl` | no .env loader / HF_TOKEN handling in lib/*.sh or bin/llmctl |
| D-32 | SKIP | `d16_d32.jsonl` | present=False |
| N-01 | RED | `n01_n29.jsonl` | control small-state rc=0 OK; 200000-char state-file -> rc=126: /home/milosvasic/Projects/llmctl/lib/decide.sh: |
| N-02 | RED | `n01_n29.jsonl` | CLI forwarded full state (backend saw 40171 chars, no truncation) and the failure is opaque: curl: (22) The re |
| N-03 | RED | `n01_n29.jsonl` | lower-case article ' a' counted as option A: gateway choice=billing shell choice=billing (expected legal) |
| N-04 | RED | `n01_n29.jsonl` | noul with letter A absent -> 0.0 (no error); all -inf logprobs -> NaN in answer (invalid JSON); shell prints N |
| N-05 | RED | `n01_n29.jsonl` | CLI rc=1 traceback=True; gateway accepted bad seed at start and answered 502 {"error": "backend query failed:  |
| N-06 | RED | `n01_n29.jsonl` | EOF at a prompt: rc=1 (want 2), message=False, sourcing shell killed silently=True; stderr='' |
| N-07 | RED | `n01_n29.jsonl` | misspelled flag silently accepted: status rc=0, capacity rc=0 (want 2) |
| N-08 | RED | `n01_n29.jsonl` | doc names undefined function(s): decide_model_downloaded |
| N-09 | RED | `n01_n29.jsonl` | docs claim prompts go to stderr, but with piped stdin no prompt text is emitted (bash read -p only prints on a |
| N-10 | SKIP | `n01_n29.jsonl` | needs a real model per profile (first generated token may be a thinking/format token); no model installed and  |
| N-11 | SKIP | `n01_n29.jsonl` | SC-001 byte-identical logprobs across llama.cpp slot/batch compositions can only be measured on the real engin |
| N-12 | RED | `n01_n29.jsonl` | after an error response the next request on the same connection is mis-parsed (leftover body): {'gateway': (40 |
| N-13 | RED | `n01_n29.jsonl` | upstream 401 collapsed into 502 with raw exception text: {"error": "onnx backend query failed: HTTP Error 401: |
| N-14 | RED | `n01_n29.jsonl` | runtime truncated (direct header=true) but gateway response omits x-llmctl-decide-truncated (status 200) |
| N-15 | RED | `n01_n29.jsonl` | state object/array rejected (object,array statuses): {'gateway': (400, 400), 'onnx': (400, 400)} |
| N-16 | RED | `n01_n29.jsonl` | MAX_OPTIONS=abc --render-prompt: traceback rc=1; DECIDE_PORT=abc: traceback rc=1; decide ask MAX_OPTIONS=abc:  |
| N-17 | RED | `n01_n29.jsonl` | unknown/non-string model accepted and echoed (status,echo,status2,echo2): {'gateway': (200, True, 200, True),  |
| N-18 | RED | `n01_n29.jsonl` | status=200; gateway performed 500 full model passes for one request (no questions cap) |
| N-19 | RED | `n01_n29.jsonl` | each unauth hit probes backend (backend /health hits=5) and body leaks profile: {"status": "ok", "profile": "t |
| N-20 | RED | `n01_n29.jsonl` | sequence length 512; ctx 128 ignored (MAX_LEN literal 512) and the scheduler onnx arm passes no ctx arg |
| N-21 | RED | `n01_n29.jsonl` | (a) root config.json preferred over onnx/config.json beside model.onnx (ent idx=2, source=config.json) (b) LAB |
| N-22 | RED | `n01_n29.jsonl` | engines disagree on the same request: noul criteria='banana': gateway=400 onnx=200; choice 5 options, MAX_OPTI |
| N-23 | RED | `n01_n29.jsonl` | /health=200 {"status": "ok", "profile": "p", "fake": false} although every inference fails (health never exerc |
| N-24 | RED | `n01_n29.jsonl` | RuntimeError during inference -> connection dropped (RemoteDisconnected: Remote end closed connection w); NaN  |
| N-25 | RED | `n01_n29.jsonl` | fixed PORT literals {'test_decide_download.sh': 18732, 'test_onnx_download.sh': 18733}; control rc=0 with port |
| N-26 | RED | `n01_n29.jsonl` | tests assert 'download <p>: SUCCESS' while smoke is skipped/disabled (D-12 encoded as correct): test_onnx_down |
| N-27 | RED | `n01_n29.jsonl` | stale documented counts: test_decide doc=55 actual=71; test_decide_gateway doc=36 actual=45 (host-dependent, n |
| N-28 | RED | `n01_n29.jsonl` | CONFIRMED claims with only hf-mirror.com as source and no independent huggingface.co reference: encoder-model- |
| N-29 | NOT-REPRODUCED | `n01_n29.jsonl` | tracked at HEAD=38, worktree=43; no suite-size claim other than HEAD/worktree counts in the normative specs/00 |
