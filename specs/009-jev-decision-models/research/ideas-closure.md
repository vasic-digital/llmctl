# Closure of the "ideas not yet in the spec" lists (42 ideas)

**Created**: 2026-10-07 | Resolves independent-review finding R-036. Each idea from the three `Jev.md` coverage indexes gets an explicit disposition and a target. Id form: `<slice>-I<nn>` (slice 1 = `jev-md-coverage-1.md` §A, slice 2 = `-2.md` §(a), slice 3 = `-3.md` §2). `tests/coverage_rows.sh` (task P9) fails if an ADOPT / ADOPT-AFTER-VERIFICATION idea id is not cited in `tasks.md`.

Disposition key: **ADOPT** (in 3.1.0), **ADOPT-AFTER-VERIFICATION** (in 3.1.0 only if the named check passes), **ADOPT-LATER** (valuable, recorded for a later release with the reason), **DONE** (already realised in the spec/plan – cites where), **MERGED** (same as another idea), **SUPERSEDED** (evidence overtook it).

| Idea | Summary | Disposition | Target (requirement / decision / phase / test) |
|---|---|---|---|
| 1-I01 | Differential tests with real hosted SDKs and local-jev | ADOPT-AFTER-VERIFICATION | `typesafe-sdk` (Py, PyPI 0.7.2) and `@typesafe-ai/sdk` (npm): ADOPT in matrix (RD-06, Q11, P6). `jevclient` (real, unofficial, PyPI 1.2.0): existence verdict then optional row. `jev-mcp-server`: existence NOT verified → verdict first (P8). local-jev server: harness only (REJECT as catalog) – optional comparator. |
| 1-I02 | `model` field handling | DONE | FR-075, RD-05, EP-007/016/016b |
| 1-I03 | Key format / header compatibility with hosted SDKs | ADOPT-AFTER-VERIFICATION | FR-058 format `[A-Za-z0-9_-]{32,}`; P6: confirm real SDKs accept it and send `Authorization: Bearer` (the hosted `ts_` prefix is a vendor convention, not validated by llmctl) |
| 1-I04 | Imbalanced base-rate items + per-class accuracy | DONE | SC-003 amended; golden set in P4/Q6 |
| 1-I05 | Shadow/measure workflow and `decide` statistics | ADOPT (log) / ADOPT-LATER (stats command) | log: FR-079, FR-080 (opt-in decision log); `decide stats` command recorded for a later release; `/metrics` already exposes latency histograms |
| 1-I06 | Extend candidate register (jev-at-home, typecastlm, JevBench) | DONE | web-candidate-models: jev-at-home REJECT (NC weights), typecastlm USER-ONLY, JevBench = RD-08; source-findings §H updated |
| 1-I07 | Exit-code contract for `decide` | DONE | `contracts/cli.md`, FR-081 |
| 1-I08 | Accepted `state` types | DONE | FR-075, data-model §3, P2 tests |
| 1-I09 | No literal keys on command lines in per-agent docs | ADOPT | FR-062; P9 doc-audit rule: fail on a literal key pattern, `--env KEY=`, `-H "Authorization: Bearer <literal>"` forms |
| 1-I10 | Limitations page from the vendor's documented failure modes + probes | ADOPT | P9 limitations page (the vendor documents **ten**, not nine); P4 probe set (arithmetic, dates read as text, double negatives, irrelevant-state sensitivity, injection) – results published as measured |
| 1-I11 | Agent-instruction snippet ("should this be a decision call?") | ADOPT | FR-035/FR-086, per-agent docs, P8 |
| 2-I01 | Ensemble / voting mode | ADOPT-LATER | Voting across identical temperature-0 instances has no mechanism for gain (innovation §3 item 4); across different profiles only after a measured agreement-vs-correctness study (needs an operator scope decision). Recorded, not in 3.1.0. |
| 2-I02 | Option-order sensitivity measurement | DONE | FR-080 (`probe-order`), SC-003, Q6, admission gate |
| 2-I03 | Request `model` → profile semantics, list, error | DONE | FR-075, EP-016/016b |
| 2-I04 | Per-profile calibration evidence separate from the accuracy set | ADOPT | FR-080, SC-003 (no ECE from < 200 labels); P4 runs a calibration-sized evaluation only where a licence-clean labelled set of ≥ 200 items exists, otherwise reports "insufficient for ECE" |
| 2-I05 | Opt-in decision log with state text | DONE | FR-080, env `LLMCTL_DECIDE_LOG_STATE` |
| 2-I06 | `decide ask` accepts a question file | DONE | FR-081, `--question-file` |
| 2-I07 | Verify with hosted-built clients (`jev-mcp-server`, `pi-jev`/`jev-pi`) | ADOPT-AFTER-VERIFICATION | P8: dependency-existence verdict (§11.4.270 style: VERIFIED / AMBIGUOUS / UNVERIFIED with evidence) then base-URL, CA trust and header checks; the conversation itself flips the Pi package name, so the verdict is mandatory before documenting either |
| 2-I08 | Fail-closed guidance for risk-gating | DONE | FR-086 (fail-closed default), P9 docs |
| 2-I09 | Seed the golden set from realistic coding-workflow questions | ADOPT | P4 golden set (dangerous-command yes/no, spec-satisfied yes/no, task-complexity choice, description-completeness score), human-labelled |
| 2-I10 | Reconcile documented limits with hosted limits | DONE | FR-075 (255 options, 2–10 levels), RD-02, `/v1/models` limits |
| 2-I11 | Name-disambiguation page (similar third-party gateways) | ADOPT | P9 "Related tools" page |
| 3-I01 | Accept wire name `noul` verbatim + J3-068 request as fixture | DONE | RD-03, EP-001; the J3-068 request becomes `tests/fixtures/systemone_request_all_types.json` |
| 3-I02 | `model` field semantics | MERGED | = 2-I03 |
| 3-I03 | Tested reference consumer-side router over HTTPS with key | ADOPT | P8 integration kit example (fixes the source's two buggy snippets; fail-closed fallback) |
| 3-I04 | Option-order flip rate as admission-gate metric | MERGED | = 2-I02 (published llmctl-measured number per profile) |
| 3-I05 | Accuracy-vs-option-count curve → recommended maximum | ADOPT | P4 measurement; result sets the catalog `decision.max_options` for each profile (evidence-based, not only a hard cap) |
| 3-I06 | External-client rows: typesafe SDK, `jevcal`, `jevassert` | ADOPT-AFTER-VERIFICATION | SDKs: see 1-I01. `jevcal`/`jevassert`: existence + licence verdict first (names appear only in the conversation); optional rows in P6 |
| 3-I07 | Local chat model as labelling "teacher" | ADOPT-LATER | Documented workflow in a later release; needs a consent/privacy design |
| 3-I08 | Local drift check (record once, replay, compare) | ADOPT (harness) / ADOPT-LATER (user command) | The frozen golden harness is a test asset (innovation #13, P4); a user-facing `decide verify` + timer recipe is recorded for later |
| 3-I09 | Opt-in shadow log with state text | MERGED | = 2-I05 |
| 3-I10 | Explicit "hooks for calibration tools" (stable fields) | ADOPT | OpenAPI + P9 page "Fields a calibration tool may rely on" |
| 3-I11 | Optional multi-instance vote mode | MERGED | = 2-I01 (ADOPT-LATER) |
| 3-I12 | End-to-end bring-your-own-export example | ADOPT | FR-008, P7: real example = a USER-ONLY encoder (e.g. `cross-encoder/nli-deberta-v3-large` ONNX, Apache-2.0) via a catalog overlay through the encoder backend; the fine-tune → GGUF journey is documented as a pointer only (training is out of scope) |
| 3-I13 | Harmful-pass measurement or "not a guardrail" statement | ADOPT | P9: state plainly that decision profiles are not safety guardrails; no guardrail claim unless llmctl measures it |
| 3-I14 | Language coverage per profile; golden set English-only | ADOPT | P9 docs + P4 statement of the golden set's language |
| 3-I15 | INT8 ONNX export of the NLI model | ADOPT-LATER | RD-18: fp32 default; int8 only after measured drift/latency (no published DeBERTa-v3-large int8 numbers found) |
| 3-I16 | Ecosystem ports list; port-conflict message names the override variable | ADOPT | P9 ports page (generated from catalog + known third-party ports); P3 test that the message names `LLMCTL_PORT_<PROFILE>`; host collisions on 8080/8082/8087/8099/8100/8102 documented |
| 3-I17 | p50/p95 and counts in `decide status` | ADOPT-LATER | `/metrics` histograms (FR-079) cover it for scrapers; a status summary view is recorded for later |
| 3-I18 | Candidate evaluation order (Verdict first …) | SUPERSEDED | Evidence changed the order: Verdict is USER-ONLY (contract unverified, torch dependency); P7 order = pinned six → letter-logit additions (decider-2b, APUS-4B) → native candidates behind the engine gate |
| 3-I19 | Seed prompts from `dangerous_command`, `best_model_tier`, `department`, `is_urgent` | MERGED | = 2-I09 |
| 3-I20 | Fail-closed guidance for gate users | MERGED | = 2-I08 |

Counts (generated from the table by leading disposition keyword; a split disposition such as "ADOPT / ADOPT-LATER" is counted under its first keyword): 42 ideas → 15 ADOPT, 4 ADOPT-AFTER-VERIFICATION, 4 ADOPT-LATER, 12 DONE, 6 MERGED, 1 SUPERSEDED.
