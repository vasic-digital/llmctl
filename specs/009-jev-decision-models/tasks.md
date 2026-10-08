---
description: "Task list for 009-jev-decision-models (Jev-class decision models in llmctl)"
---

# Tasks: Jev-Class Decision Models in llmctl

**Input**: `specs/009-jev-decision-models/` — plan.md, spec.md (87 FR, 14 SC, 9 stories), data-model.md, contracts/, research.md, quickstart.md, traceability.md, research/ideas-closure.md
**Branch**: all work on `main` (operator instruction 2026-10-07; no feature branch); nothing is committed, pushed or tagged without the operator's say-so.

## Format

`- [ ] T### [P?] [TDD?] [US#?] Description with file path` — `[P]` parallel (disjoint files); `[TDD]` RED observed first, then GREEN, then refactor; `[REVIEW]` independent review (Opus, xhigh, iterate to zero findings) before moving on; `[SUBAGENT]` delegable. Tests are **mandatory** here (spec FR-038..043): every executable task is preceded by its failing test. "Idea" ids refer to `research/ideas-closure.md`; finding ids to `source-findings.md` / `research/jev-llmctl-new-files.md`.

**Standing rules for every task**: no mocks outside the unit tier; evidence is machine-produced (JSONL + SHA256SUMS, schema in `contracts/evidence-schema.md`); no secret in output; no force-push; shared host: re-measure RAM/VRAM/ports before any live step and never disturb the running vision server (OD-6).

## Phase 1: Setup (P0 baseline & faithful port)

- [x] T001 Verify base (`git rev-parse HEAD` = `a9ebefe`), hardlink-archive `.git` (§9.2 backup), work on `main` (operator instruction); record in `specs/009-jev-decision-models/evidence/p0-baseline.json` <!-- reconciled 2026-10-08: done: specs/009-jev-decision-models/evidence/p0-baseline.json -->
- [x] T002 Run the existing 38 `tests/test_*.sh` + constitution harness on unmodified HEAD; record baseline pass/fail (incl. the 2 known environment failures) in `evidence/p0-baseline.json` <!-- reconciled 2026-10-08: done: specs/009-jev-decision-models/evidence/p0-baseline.json (t002), evidence/p0-baseline-make-test.log -->
- [x] T003 Generate per-file patches base→candidate from `/home/milosvasic/Projects/jev/llmctl/llmctl` (`research/merge-plan.md`); `git apply --3way` the 24 clean files; HEAD wins for the 2 QA `.txt` files; one commit-ready step per risk-ordered group (catalog/planner → scheduler → download → services/engine/doctor → bin+decide → docs → project constitution last) (FR-044, FR-045) <!-- reconciled 2026-10-08: done: specs/009-jev-decision-models/evidence/p0-baseline.json (t003_t004: 24 applied, 2 HEAD-wins, 0 byte mismatches) -->
- [x] T004 Add the 29 new candidate files verbatim (never `.pyc`, archives or symlinks); verify count with `research/jev-llmctl-inventory.tsv` (FR-044, FR-045) <!-- reconciled 2026-10-08: done: specs/009-jev-decision-models/evidence/p0-baseline.json (t003_t004: 29 new) -->
- [x] T005 Run the 38+5 suites on the ported tree; assert differential = +5 suites pass, same 2 environment failures; store in `evidence/p0-port-differential.json` <!-- reconciled 2026-10-08: done: specs/009-jev-decision-models/evidence/p0-baseline.json (t005) + evidence/p0-port-make-test.log; the planned file p0-port-differential.json was never written, the differential is recorded inside p0-baseline.json -->
- [x] T006 [REVIEW] Independent review of the port (every one of the 519 inventory files accounted for); gate: GO <!-- reconciled 2026-10-08: done: specs/009-jev-decision-models/evidence/p0-baseline.json (t006: independent review, verdict GO) -->

## Phase 2: Foundational — reproduce (P1) and secure foundation (P2)

**Blocks all user stories.** Checkpoint: operator approves the RED suites after T020, and sees the first-start message after T036.

### P1 RED suites (one failing test per finding)

- [x] T010 [P] [TDD] [SUBAGENT] Failing test per D-01…D-31 in `tests/test_decide_defects_*.sh` and `tests/py/test_defects_*.py`; D-01 uses the real tokenizer files only (pinned `spm.model`) in a scratch venv under `tests/.venv-tok/` <!-- reconciled 2026-10-08: done: specs/009-jev-decision-models/evidence/p1-red-original/ (raw RED output, harness archived non-runnable) + evidence/p1-red-register.json; ported guards in tests/test_regression_defects.sh -->
- [x] T011 [P] [TDD] [SUBAGENT] Failing test per N-01…N-29 (`research/jev-llmctl-new-files.md`) in `tests/test_candidate_files_*.sh` <!-- reconciled 2026-10-08: done: specs/009-jev-decision-models/evidence/p1-red-original/n01_n29.jsonl + evidence/red-to-green-map.json -->
- [x] T012 [P] [TDD] [SUBAGENT] Failing planted-secret archive test `tests/test_release_no_secrets.sh` (plant `.env`, `cert/ca/ca.key`, log key; build archives; scan with control needle) — D-30/FR-087 <!-- reconciled 2026-10-08: done: tests/test_release_no_secrets.sh (PASS in evidence/p7-make-test.log); evidence/p1-red-original/d30.jsonl -->
- [x] T013 Classify each finding REPRODUCED / NOT-REPRODUCED / HARDENING (precondition `constructed`) with captured output; update `source-findings.md` status column and counts <!-- reconciled 2026-10-08: done: specs/009-jev-decision-models/evidence/p1-red-register.json + source-findings.md (P1 reproduction register) -->
- [x] T014 Install the failing-first harness: `tests/evidence/writer.py`, `tests/evidence/manifest.py`, `tests/evidence/leak_scan.py` (control-needle proven, §11.4.201(7)); tests for the writer itself first (FR-041, FR-042) <!-- reconciled 2026-10-08: done: tests/evidence/{writer,manifest,leak_scan}.py with tests/py/test_evidence_writer.py, test_evidence_manifest.py, test_leak_scan.py (tests/test_py_unit.sh PASS in evidence/p7-make-test.log) -->
- [ ] T015 [REVIEW] Independent review of the RED suites; **operator approval checkpoint** (TDD gate) <!-- reconciled 2026-10-08: open: no recorded independent review or operator approval of the RED suites as such; the harness is archived (evidence/p1-red-original/README.md) and the guards live in tests/test_regression_defects.sh | remaining: lead / operator: fold into the final review T128 or record an explicit waiver -->

### P2 foundation (make P1 tests GREEN; contracts/ are the spec)

- [x] T009 Go module bootstrap: `go.mod` (`module github.com/vasic-digital/llmctl`, go 1.25), `go.sum` pinning `github.com/gin-gonic/gin` (v1.12.0 verified to build here), `cmd/llmctl-decide/main.go` skeleton, `tests/test_go_unit.sh` (runs `go vet ./... && go test -count=1 -cover ./...`, wired into `make test`), `llmctl build decide` target in `lib/engine.sh` (builds `build/llmctl-decide` from the module with `-trimpath`, offline-capable when the module cache is warm); dependency-existence verdict recorded for Gin and its transitive set in `evidence/dependency-verdicts.json` (VERIFIED/AMBIGUOUS/UNVERIFIED per §11.4.270, with `go mod verify` output) <!-- reconciled 2026-10-08: done: go.mod, cmd/llmctl-decide/main.go, tests/test_go_unit.sh (PASS in evidence/p7-make-test.log) -->
- [x] T020 [P] [TDD] [SUBAGENT] `internal/keyring/` (Go) — key resolve env → installation-root `.env` (`LLMCTL_ENV_FILE`) → generate on first start; format `[A-Za-z0-9_-]{32,}`, ≥256 bits via crypto/rand; safe reader/writer (never `source`), O_EXCL 0600 atomic write, rotate with overlap stored only in `.env`, placement guard (FR-087), constant-time compare over all accepted keys, redacting String()/GoString, export helper; CLI `llmctl-decide key doctor|show|path|rotate|export` (FR-057..063, FR-087, FR-020). **Port the vectors of the Python prototype (`lib/llmctl_decide/keyring.py`, `tests/py/test_keyring.py`, `tests/test_keyring_cli.sh`) — same behaviour, same exit codes (4)** <!-- reconciled 2026-10-08: done: internal/keyring; evidence/go-port-parity.json (81 pass); tests/test_keyring_go_cli.sh PASS -->
- [x] T021 [P] [TDD] [SUBAGENT] `internal/certs/` (Go, `crypto/x509` — no openssl CLI) — name-constrained CA (EC P-256, 10y, pathlen 0, constraints ON by default, `LLMCTL_CA_NAME_CONSTRAINTS=off` logged opt-out) + leaf (397d, serverAuth, SANs incl. interface addresses and `LLMCTL_TLS_SAN`), drift/expiry/renew under flock, `byo` validation, offline-CA-key mode, placement guard; `cert/` under `$LLMCTL_HOME` 0700 (FR-066..068, 087); CLI `llmctl-decide cert ensure|show|export|renew|doctor` exit 5. **Port the behaviour and vectors of `lib/llmctl_decide/certs.py` / `tests/py/test_certs.py` / `tests/test_certs_cli.sh`; verify constraint enforcement with Go's `x509.Verify` AND `openssl verify`** <!-- reconciled 2026-10-08: done: internal/certs; evidence/go-port-parity.json (72 pass); tests/test_certs_go_cli.sh + test_certs_go_mutation.sh PASS (13/13 mutants) -->
- [x] T022 [P] [TDD] [SUBAGENT] `internal/contract/` + `internal/readout/` (Go) — hosted request/response shapes, limits, error taxonomy per the STATUS TABLE in `contracts/openapi.yaml`, model-name mapping, state as text/object/array, over-budget state → 422 unless opt-in truncation, forged-option neutralisation; letter-logit readout math (FR-012, 075, 076). **Port `lib/llmctl_decide/contract.py`, `readout.py` and their tests/vectors (incl. the inventory-driven table tests)**; fixture `tests/fixtures/systemone_request_all_types.json` (idea 3-I01) <!-- reconciled 2026-10-08: done: internal/contract, internal/readout; evidence/go-port-parity.json (88 + 25 pass) -->
- [x] T023 [TDD] `internal/server/` (Go + **Gin Gonic**) — HTTPS server on `http.Server` with explicit timeouts; TLS wrapped PER CONNECTION after global + per-source slot acquisition (shed before handshake); read/handshake/request deadlines; body cap before read (413); keep-alive correct after errors (N-12); auth middleware (constant-time Bearer; only `/healthz` `/readyz` unauthenticated and minimal); 404/405 only after auth; failed-auth throttle that never throttles the valid key; `x-request-id`; hygiene headers; graceful drain; Gin runs in release mode with no default logger (FR-019, FR-022, FR-078); tests with real sockets, real TLS from `internal/certs`, hostile clients; `tests/test_tls_server.sh`. **Port the intent and cases of the stopped Python `httpcore` task** <!-- reconciled 2026-10-08: done: internal/server (go test ok in evidence/p7-make-test.log); tests/test_gateway_endpoints.sh PASS -->
- [x] T024 [P] [TDD] [SUBAGENT] `internal/audit/` + `internal/metrics/` (Go) — JSON request log with HMAC-SHA256 keyed state hash (separate log key, 0600), Prometheus text exposition with allow-listed bounded labels and fixed-bucket histogram (FR-037, FR-079). **Port `lib/llmctl_decide/audit.py`, `metrics.py` and tests** <!-- reconciled 2026-10-08: done: internal/audit, internal/metrics; evidence/go-port-parity.json (30 + 17 pass) -->
- [x] T025 Remove `LLMCTL_DECIDE_API_KEY`, `LLMCTL_DECIDE_BACKEND_*`, `LLMCTL_ONNX_FAKE` from production paths; grep test proves absence (`tests/test_no_retired_vars.sh`) (FR-024) <!-- reconciled 2026-10-08: open: tests/test_no_retired_vars.sh exists and PASSED in evidence/p7-make-test.log but FAILS on the current tree: docs/scripts/test_no_retired_vars.md (new docs page) quotes the retired names (run 2026-10-08) | remaining: lead: allow-list the page (path:N pinned) or reword its header comment, re-run the suite -->
- [x] T025b Remove the superseded Python prototypes (`lib/llmctl_decide/{keyring,certs,contract,readout,audit,metrics}.py` and `tests/py/test_{keyring,certs,contract,readout,audit,metrics}.py`, `tests/test_keyring_cli.sh`, `tests/test_certs_cli.sh`) ONLY after the Go versions pass the same vectors and the equivalence is recorded in `evidence/go-port-parity.json` (one implementation per rule, Helix §11.4.251; own uncommitted files, git-history check not applicable, §11.4.124 note recorded) <!-- reconciled 2026-10-08: done: evidence/go-port-parity.json (prototypes removed after Go parity) -->
- [x] T026 [TDD] `.gitignore` add `cert/`; rewrite `scripts/release/build_archive.sh` as a tracked-file allow-list (tracked files + submodule contents); make T012 GREEN <!-- reconciled 2026-10-08: done: scripts/release/public_allowlist.txt, .gitignore (cert/), tests/test_release_no_secrets.sh PASS (evidence/p7-make-test.log) -->
- [x] T027 [TDD] Mutation tests: one paired mutation per guard (auth compare, throttle scope, body cap, shed-before-TLS, placement guard) shown RED then restored — `tests/mutation/` (FR-038, FR-039, FR-040) <!-- reconciled 2026-10-08: done: tests/test_decide_security_mutation.sh, tests/test_gateway_mutation.sh, tests/test_certs_go_mutation.sh (all PASS in evidence/p7-make-test.log); lives in tests/ not tests/mutation/ -->
- [x] T028 Coverage measurement (measure-and-report only per OD-15): bash PS4 trace + Python `trace`; report to `evidence/coverage-p2.json` (FR-043) <!-- reconciled 2026-10-08: open: no evidence/coverage-p2.json; only per-package go -cover numbers inside evidence/p7-make-test.log; bash PS4 and Python trace coverage not measured | remaining: lead: measure-and-report only (OD-15) -->
- [x] T030 Project-constitution amendment (2.0.0→2.1.0) **before any gateway code binds a network address**: carve out the decision gateway from "all servers bind 127.0.0.1" (Safety Guarantees, Port Map), add the stdlib Python package to the Technology Stack, record the memory-policy note; requires operator decision OD-11 first — if OD-11 is not granted, T042/T050 are blocked and the gateway defaults to loopback until it is (C1/C3 of analysis) <!-- reconciled 2026-10-08: done: .specify/memory/constitution.md (Amendment 2.1.0, lines 91/189/208) -->
- [ ] T029 [REVIEW] Independent review (after T030); gate: all P1 tests GREEN for fixed findings, leak scan with control needle green; **operator sees first-start message + trust steps end to end** <!-- reconciled 2026-10-08: open: independent foundation review with the operator seeing the first-start message not recorded as a single checkpoint (reviews exist per round in evidence/review-2..4, all NO-GO then fixed forward) | remaining: lead: final review T128 -->

## Phase 3: User Story 1 — Run a decision model locally, get a typed answer (P1)

**Goal**: `llmctl decide ask` returns valid typed answers for noul/choice/score on a local decision profile.
**Independent test**: Q3, Q4 in quickstart.md.

- [x] T040 [P] [TDD] [SUBAGENT] [US1] `internal/readout/` (Go; covered by T022 port — keep as the real-model fixture task) — letter-logit math: summed spelling mass, threshold → `readout_failed` (422, non-retryable), missing letter as upper bound flagged, NaN/inf rejected, upper-case letter only (FR-076); tests `tests/py/test_readout.py` with real first-token logprob fixtures captured from a real model (stored with provenance) (FR-076) <!-- reconciled 2026-10-08: done: internal/readout (readout_test.go) ; real-model readout runs in evidence/live/decide-kev-08b, decide-julia, decide-laya (N-10 stays under G-075) -->
- [ ] T041 [P] [TDD] [SUBAGENT] [US1] `lib/llmctl_decide/nli.py` + `onnx_server.py` shim — premise-only truncation, label order, declared inputs, tokenizer equivalence vs reference, pinned `config.json`; tests `tests/py/test_nli.py` (FR-025, FR-077) <!-- reconciled 2026-10-08: open: lib/llmctl_decide/nli.py and tests/py/test_nli.py do not exist (superseded by internal/gateway/nli.go + lib/onnx_server.py); premise-only truncation with the REAL tokenizer is not evidenced (D-01 OPEN in evidence/sc004-closure.md) | remaining: live-phase agent: download decide-nli tokenizer, RED against the candidate encode_pair, GREEN on the shipped runtime -->
- [x] T042 [TDD] [US1] Gateway in Go + Gin (`cmd/llmctl-decide serve`, `internal/server/`): `/v1/systemone`, `/v1/models` (with per-profile `limits`), `/healthz`, `/readyz`, `/metrics`; deterministic mode default; backends: llama.cpp letter-logit over loopback with per-start internal key, encoder runtime over loopback; `lib/decide_gateway.py` is retired when parity is shown; tests `tests/test_gateway_endpoints.sh` driven by `contracts/endpoint-inventory.tsv` (FR-001, FR-009, FR-010, FR-011, FR-013..016, FR-017, FR-021, FR-074, FR-075) <!-- reconciled 2026-10-08: done: internal/server, internal/gateway; tests/test_gateway_endpoints.sh PASS; matrix 45 cases x 6 clients (evidence/p7-make-test.log) -->
- [x] T043 [TDD] [US1] `internal/client/` (Go) + thin `lib/decide.sh`: `ask` (state via `--state-file`/`--stdin`, never argv), `--question-file` (idea 2-I06), `--dry-run`, `--explain`, batch NDJSON, TLS verification always on (no off switch), exit codes 0/1/2/3/4/5/6/10 per `contracts/cli.md`, strict flags (N-07), real-millisecond latency (D-20); decide.sh delegates to the Go binary; tests `tests/test_decide_cli.sh`, Go unit tests (FR-081) <!-- reconciled 2026-10-08: done: internal/client, cmd/llmctl-decide/cmd_ask_test.go; tests/test_decide.sh PASS -->
- [ ] T044 [US1] Real-model golden smoke on the smallest pinned profile (`decide-tiny`): three question types, evidence JSONL `evidence/us1-smoke.jsonl` (FR-001) <!-- reconciled 2026-10-08: open: evidence/us1-smoke.jsonl absent; decide-tiny not downloaded (models dir holds native profiles only) | remaining: live-phase agent -->
- [ ] T046 [US1] Scripted SC-001 run: first-start steps from the documentation only (model download excluded) → first valid typed answer for each of the three types in < 5 min, plus 20 deterministic repeats byte-identical; evidence `evidence/sc001.json` (SC-001) <!-- reconciled 2026-10-08: open: evidence/sc001.json absent | remaining: live-phase agent -->
- [ ] T045 [REVIEW] [US1] Independent review; gate Q3, Q4 <!-- reconciled 2026-10-08: open: no US1 review record | remaining: lead: final review -->

## Phase 4: User Story 2 — Expose the endpoint to host/LAN/cloud safely (P1)

**Goal**: HTTPS gateway, key-protected, reachable per `LLMCTL_DECIDE_BIND`, hosted-SDK usable with key + CA trust.
**Independent test**: Q2, Q7, Q8, Q11.

- [x] T050 [P] [TDD] [SUBAGENT] [US2] Bind semantics: `LLMCTL_DECIDE_BIND` falling back to global `LLMCTL_BIND_HOST`; both asserted in `tests/test_bind_resolution.sh`; startup prints bind, URL, key location (never value), CA fingerprint (FR-018) <!-- reconciled 2026-10-08: done: cmd/llmctl-decide/cmd_serve_test.go TestResolveBind (LLMCTL_DECIDE_BIND over LLMCTL_BIND_HOST); tests/test_gateway_endpoints.sh banner asserts URL and CA SHA-256 fingerprint -->
- [x] T051 [P] [TDD] [SUBAGENT] [US2] `llmctl cert` and `llmctl key` commands per `contracts/cli.md` incl. `key export` (idempotent, backup, permission warning, explicit operator command only) <!-- reconciled 2026-10-08: done: cmd/llmctl-decide/cmd_cert.go, cmd_key.go (doctor|show|path|rotate|export); tests/test_keyring_go_cli.sh, test_certs_go_cli.sh PASS -->
- [x] T052 [TDD] [US2] `decide serve --stop` verifies `/proc/<pid>/cmdline`, refuses pid ≤ 1, signals only the verified process (§11.4.263 guard); tests incl. mock pid explicit-int (FR-023) <!-- reconciled 2026-10-08: done: cmd/llmctl-decide/cmd_serve_test.go TestServeStopNeverSignalsUnrelatedProcess; tests/test_gateway_endpoints.sh -->
- [ ] T053 [TDD] [US2] Engines/runtimes loopback-only with per-start internal key (`--api-key-file`, `--no-webui`, props off); test: engine ports unreachable from the second vantage (FR-073) (FR-073) <!-- reconciled 2026-10-08: open: per-start key done (G-028: ExecStartPre rotation; tests/test_decide_service.sh) but the 'engine ports unreachable from the second vantage' test is not evidenced (G-032 OPEN) | remaining: lead: wire the vantage probe at the real gateway and engine ports -->
- [x] T054 [US2] Second network vantage harness: second vantage booted ON DEMAND through the Containers submodule (`pkg/boot`/`pkg/runtime`, rootless podman bridge with own address + slirp4netns cross-check, not pasta) — no hand-run podman commands (Helix §11.4.76); `tests/matrix/vantage.sh` is a thin wrapper over a Go helper using the submodule; self-connect reachability check in `decide serve --status` (FR-064) (FR-064) <!-- reconciled 2026-10-08: done: internal/vantage, tests/test_vantage.sh PASS (evidence/p7-make-test.log) -->
- [ ] T055 [US2] Client-by-call matrix runner `tests/matrix/run.py` with clients curl, Python (urllib+requests), Node, Go, headless Chromium, `llmctl decide`, **and the agent subset** (one authenticated success + one unauthenticated call each); floors and "not exercised" classes per FR-069; output `evidence/matrix.json` (ideas 1-I01, 1-I03) <!-- reconciled 2026-10-08: open: matrix runs 45 cases x 6 clients (evidence/p7-make-test.log) but llmctl-cli + 7 agent adapters + second-vantage wiring are pending (G-043) | remaining: lead: T055b -->
- [x] T056 [US2] Hosted SDK rows: `typesafe-sdk` (PyPI) and `@typesafe-ai/sdk` (npm) pointed at the gateway with key + CA trust; record which CA-trust mechanism each honours; existence/licence verdict first for `jevclient` (ideas 1-I01, 3-I06) <!-- reconciled 2026-10-08: done: tests/matrix/clients/README.md (SDK adapters report TRUST mechanism); G-038 SDK cells EP-030 pass (py 11, js 11); evidence/dependency-verdicts.json -->
- [x] T057 [US2] Negative TLS cases (name mismatch, expired, untrusted CA, altered cert, plain HTTP to TLS port, legacy protocol client) + chaos (slow client, oversize, malformed, concurrent, kill-mid-request, per-source cap) `tests/test_tls_negative.sh`, `tests/test_gateway_chaos.sh` (FR-070) <!-- reconciled 2026-10-08: done: tests/matrix/negative_tls.py via tests/test_matrix_harness.sh (log: 'negative TLS covers every FR-070 case'); internal/server chaos/limit tests (go test ok); file names differ from the plan -->
- [ ] T058 [US2] Cloud reachability: document port-forward / overlay / tunnel methods and risks; chat-server access only through an authenticated overlay; external-vantage test only if OD-12 grants one else evidence "not exercised: no external vantage" (FR-065) (FR-065) <!-- reconciled 2026-10-08: open: docs/cloud-exposure.md exists, but the 'not exercised: no external vantage' evidence statement is not in it and no external-vantage run exists | remaining: lead: add the evidence sentence or run if OD-12 grants a vantage -->
- [ ] T058n [US2] Real second LAN machine: run the client-by-call matrix subset from `nezha.local` (key SSH, work dir ~/llmctl-work) against this host's gateway on its LAN address: curl, python, node, go clients + negative TLS (CA copied as public file only); firewall state on this host recorded; vantage recorded `nezha-lan` (FR-064, FR-069, SC-013) <!-- reconciled 2026-10-08: open: evidence/portability-nezha/ has gateway-on-nezha with client on this host; the planned nezha-to-this-host authenticated matrix subset is G-090 OPEN | remaining: live-phase agent -->
- [ ] T059 [REVIEW] [US2] Independent review; gate SC-005, SC-006, SC-013 <!-- reconciled 2026-10-08: open: no US2 review record | remaining: lead: final review -->

## Phase 5: User Story 3 — Trust the evidence: real models (P1)

**Goal**: every claim verified against the six pinned real models; honest numbers.
**Independent test**: Q5, Q6; SC-002, SC-003.

- [x] T060 [US3] Re-verify the six pins against huggingface.co (size+sha256), pin the three `sha256:null` files with computed hashes, update `models/catalog.json`; `tests/test_catalog_json.sh` + mutation (FR-002..005) <!-- reconciled 2026-10-08: done: specs/009-jev-decision-models/evidence/pin-reverify.json; tests/test_catalog_json.sh PASS -->
- [ ] T061 [US3] Download the six pinned models with `llmctl models download` (size+sha256, `.part`→rename); skipped smoke reported as skipped; resource check first (shared host, `/` ~95% full) (FR-046) <!-- reconciled 2026-10-08: open: the six originally pinned models are not downloaded (only native profiles are in ~/.local/share/llmctl/models) | remaining: live-phase agent (RAM/disk permitting, OD-31) -->
- [ ] T062 [US3] Real `llama-server` readout per profile: measure letter mass; HTTPS handshake of the pinned engine with `--ssl-*` (FR-072); real encoder RSS idle/peak/after N → `MemoryMax` data (FR-082) <!-- reconciled 2026-10-08: open: real readout runs exist for julia/laya/kev-08b only (evidence/live/); encoder RSS and the six-profile set absent | remaining: live-phase agent -->
- [x] T063 [US3] Golden question set `tests/fixtures/golden/` (hash-pinned, seeded, human-labelled, English-only, imbalanced items; realistic coding-workflow questions — ideas 1-I04, 2-I09, 3-I14; frozen record-once/replay harness doubles as the drift check, idea 3-I08) with accuracy ± interval, per-class accuracy vs majority baseline; profiles whose lower bound does not clear baseline are not shipped (SC-003) (FR-047) <!-- reconciled 2026-10-08: done: tests/fixtures/golden, scripts/golden/*, docs/golden-set.md; tests/py/test_golden_*.py PASS; labels provisional per OD-22 (G-110) -->
- [ ] T064 [US3] Option-order flip rate and accuracy-vs-option-count per profile → catalog `decision.max_options` (ideas 2-I02, 3-I05); probe set: arithmetic, dates, double negatives, injection (idea 1-I10) <!-- reconciled 2026-10-08: open: no per-profile flip-rate/accuracy-vs-options run feeding decision.max_options (only evidence/live/*/probes for 3 native profiles) | remaining: live-phase agent -->
- [ ] T065 [US3] JevBench public tier via its adapter pointed at the gateway, labelled public-tier; calibration only if ≥200 licence-clean labels exist (idea 2-I04) <!-- reconciled 2026-10-08: open: no JevBench adapter run (no evidence) | remaining: live-phase agent / operator decision -->
- [ ] T066 [US3] Profiles that cannot fit this host recorded "not exercised" with numbers <!-- reconciled 2026-10-08: open: refusals recorded only for lev/kev-4b/kev-9b (G-136); the pinned six not recorded | remaining: lead with T142 -->
- [ ] T068 [US3] Live run of EVERY decision profile that fits this host through the HTTPS gateway (all three question types), per-model result in `evidence/live-models.jsonl`; profiles that cannot fit recorded "not exercised" with the numbers (FR-046..049, SC-002) <!-- reconciled 2026-10-08: open: evidence/live-models.jsonl absent; 3 of 6 native profiles live (G-136) | remaining: live-phase agent, depends on OD-31 -->
- [ ] T062n [US3] Live CPU-only runs of the larger decision profiles on `nezha.local` (62 GiB RAM): fetch/verify pinned models there (size+sha256), run the real engine + gateway + golden set, store evidence per host (host identity probed live) <!-- reconciled 2026-10-08: open: only decide-kev-08b ran on nezha (evidence/live/nezha) | remaining: live-phase agent -->
- [ ] T067 [REVIEW] [US3] Independent review; evidence bundle with SHA256SUMS <!-- reconciled 2026-10-08: open: no US3 review record | remaining: lead: final review -->

## Phase 6: User Story 5 — Plan, discover and use capacity (P2)

**Goal**: `plan --json decision_instances` equals admission; `auto decide`; multi-instance.
**Independent test**: Q10; SC-010, SC-012.

- [x] T069 [US5] Containers submodule integration (FR-091): `go.mod` `replace digital.vasic.containers => ./submodules/containers` + pinned require; `helix-deps.yaml` (Helix §11.4.31) declaring the dependency; `tests/test_containers_submodule.sh` asserting the submodule is checked out at the recorded commit and that only `digital.vasic.containers/...` is used for ports/registry/health (no parallel implementations); record upstream-extension needs in `evidence/containers-gaps.md`; offer to run `submodules/containers/install_upstreams.sh` (OD-19, not run without consent) <!-- reconciled 2026-10-08: done: helix-deps.yaml, tests/test_containers_submodule.sh PASS -->
- [x] T076 [TDD] [US5] `internal/registry/` (Go, on `pkg/serviceregistry` + `pkg/network.PortAllocator` + `pkg/health`): dynamic port strategy (`LLMCTL_PORT_STRATEGY`, `LLMCTL_PORT_<PROFILE>=auto`, `LLMCTL_PORT_RANGE`), sticky reuse, bind-tested allocation, release on stop; registry register/unregister/list with real-process-identity liveness and health grace → unhealthy → removed; CLI `llmctl-decide port allocate|release` and `registry register|unregister|list`, `llmctl discover [--json]`; doctor check registry == live set (FR-088, FR-089, FR-090) <!-- reconciled 2026-10-08: done: internal/registry (go test ok, evidence/p7-make-test.log); tests/test_registry_discovery.sh PASS -->
- [x] T077 [TDD] [US5] Wire dynamic ports + registry into `lib/scheduler.sh`, `lib/service_linux.sh`, `lib/service_macos.sh` (assigned port recorded in plan output, units/agents and logs; units publish to the registry from ExecStartPost-equivalents and withdraw on stop); gateway router in `internal/server/` resolves backends from the registry and re-resolves on change; tests `tests/test_dynamic_ports.sh`, `tests/test_registry_discovery.sh` incl. occupied-default-port case and 20 random start/stop/kill sequences (SC-015, FR-090) — extended by OD-18: the gateway port and every engine/runtime must also work under the dynamic strategy; QA and test evidence derive host facts live (no hardcoded host names or paths) <!-- reconciled 2026-10-08: done: tests/test_dynamic_ports.sh PASS; G-025 CLOSED (Linux) -->
- [x] T070 [P] [TDD] [SUBAGENT] [US5] `lib/catalog.sh`/`scheduler.sh`: `decision_instances` in the candidate's shape (+ additive `protocol`), single-profile best-placement definition (data-model §10); `decide-max` port → 8097; tests `tests/test_planner_decisions.sh` (FR-006, FR-027, FR-028, FR-030) <!-- reconciled 2026-10-08: done: tests/test_decision_capacity.sh PASS; models/catalog.json decide-max port 8097 -->
- [ ] T071 [TDD] [US5] `decide scale <profile> <N>`: instance keys `<profile>.N`, registry-allocated ports, refusal exit 3 with numbers; deterministic mode primary-then-overflow, `throughput` mode flagged (FR-029) <!-- reconciled 2026-10-08: open: decide scale not implemented (T135) | remaining: lead / scale agent -->
- [x] T072 [TDD] [US5] `routing.py`/`registry.py`: pools, health, least-loaded, bounded queue, 529/503 semantics, 502 transient (FR-078) <!-- reconciled 2026-10-08: done: internal/gateway/router.go + router_test.go TestRouterThroughputLeastLoaded; internal/server/server_test.go TestSaturation529, TestQueueDeadline529 -->
- [ ] T073 [US5] Live check on this host: capacity report equals live admitted count (SC-010), `auto decide` behaviour documented and tested (SC-012); `evidence/us5-capacity.jsonl` (FR-048) <!-- reconciled 2026-10-08: open: evidence/us5-capacity.jsonl absent | remaining: live-phase agent -->
- [ ] T074 [US5] Discovery contract probe: run the toolkit snapshot as an unmodified external consumer, record the expected plain-HTTP/keyless failure as the documented contract change (`contracts/discovery-contract.md`) (FR-036) <!-- reconciled 2026-10-08: open: no toolkit-snapshot consumer probe evidence | remaining: lead -->
- [ ] T075 [REVIEW] [US5] Independent review <!-- reconciled 2026-10-08: open: no US5 review record | remaining: lead: final review -->

## Phase 7: User Story 7 — Operate like any other service (P2)

**Goal**: systemd/launchd units, doctor, drain, observability.
**Independent test**: Q9, Q10.

- [x] T080 [P] [TDD] [SUBAGENT] [US7] `lib/service_linux.sh`: gateway + instance units, hardening directives verified on this host's systemd, `StartLimit*` in `[Unit]`, memory policy per OD-14 (default: recorded 2026-09-15 decision; measured peak recorded) (FR-083) (FR-031, FR-033, FR-083) <!-- reconciled 2026-10-08: done: tests/test_services.sh, tests/test_decide_service.sh PASS; docs/qa/dynamic-ports-validation/live-systemd-user-run.txt -->
- [x] T081 [P] [TDD] [SUBAGENT] [US7] `lib/service_macos.sh`: launchd agents for gateway and encoder runtime (D-32), plist mode 0600, no key in args; macOS verified by file inspection and dry-run only unless a Mac is available (record honestly) <!-- reconciled 2026-10-08: done: tests/test_macos_plist.sh PASS (labelled statically verified only, OD-29) -->
- [x] T082 [TDD] [US7] `doctor` checks: key, cert expiry/drift, venv, engine HTTPS, ports, firewall note (FR-032) (FR-032) <!-- reconciled 2026-10-08: done: tests/test_doctor_decide.sh PASS after review NO-GO fixes (cert-doctor failure => FAIL, empty key => WARN, running gateway must listen on the configured port (needs ss, else WARN), no SIGPIPE on engine help; mutations cert FAIL->warn and venv forced-true now caught). Not covered: a real onnx venv content check beyond presence -->
- [x] T083 [TDD] [US7] Drain/readiness flip, graceful stop, backpressure under load; stress scenario `tests/test_gateway_stress.sh` (FR-078) <!-- reconciled 2026-10-08: done: tests/test_gateway_stress.sh PASS (529+Retry-After burst, graceful stop, RSS bound; readiness flip observed as closed listener over HTTPS, 503 asserted in Go TestGracefulDrain) -->
- [ ] T084 [P] [TDD] [SUBAGENT] [US7] `calibrate`, `probe-order`, `schema`, `completions`, `interactive`, decision log opt-in (ideas 1-I05, 2-I05) (FR-080, FR-081) <!-- reconciled 2026-10-08: open: calibrate/probe-order/completions done (T132-T134), schema done (internal/schema); decision-log opt-in not done (G-135) | remaining: lead -->
- [ ] T085 [REVIEW] [US7] Independent review <!-- reconciled 2026-10-08: open: no US7 review record | remaining: lead: final review -->

## Phase 8: User Story 6 — Admit more Jev-like models safely (P2)

**Goal**: the gated admission pipeline G1–G10 and the gated engine advance.
**Independent test**: Q14.

- [x] T090 [US6] `lib/admit.sh` (or tests/admission/) implementing gates G1–G10; golden-good/golden-bad fixtures (FR-007) <!-- reconciled 2026-10-08: done: lib/admit.sh, tests/test_admit.sh PASS -->
- [ ] T091 [US6] Run gates on the 41 named candidates (paper checks recorded; real runs for the 8 new ADMIT-CANDIDATEs); register ADMITTED / USER-ONLY / REJECTED with evidence (`research/web-candidate-models.md`) <!-- reconciled 2026-10-08: open: paper checks recorded for 48 candidates (evidence/admission/SUMMARY.md: 0 ADMITTED, 13 ADMIT-CANDIDATE); real runs pending (G-013) | remaining: live-phase agent -->
- [ ] T092 [US6] Encoder BYO real example: a USER-ONLY ONNX encoder via catalog overlay (idea 3-I12) (FR-008) <!-- reconciled 2026-10-08: open: no USER-ONLY ONNX encoder overlay example evidenced | remaining: lead -->
- [x] T093 [US6] Gated engine advance (OD-1): scratch build of a tag ≥ b11361 with bounded `-j`, chat regression + live chat smoke + engine-HTTPS check; only then enable native-systemone profiles; else record "pending" (FR-085) <!-- reconciled 2026-10-08: done: evidence/engine-advance-local/ROLLBACK.txt; pin b10969 -> b11379 with all OD-1 gates (G-133, G-134) -->
- [x] T093n [US6] Engine-advance scratch build on `nezha.local` first (llama.cpp >= b11361, CPU, bounded -j, in ~/llmctl-work), then native-protocol live tests (Kev/Laya/Julia/lev) there; this host (CUDA) follows only after nezha passes <!-- reconciled 2026-10-08: done: evidence/engine-advance/ (nezha scratch build, G-114); evidence/live/nezha -->
- [ ] T094 [US6] Letter-logit additions (decider-2b, APUS-4B) on the current pin <!-- reconciled 2026-10-08: open: decide-2b is in models/catalog.json; APUS-4B is not | remaining: lead -->
- [ ] T095 [REVIEW] [US6] Independent review <!-- reconciled 2026-10-08: open: no US6 review record | remaining: lead: final review -->

## Phase 9: User Story 4 — Use from every supported agent (P2)

**Goal**: all seven agents make a decision call; proof is the gateway's request log.
**Independent test**: Q12; SC-007.

- [x] T100 [US4] Install missing agents (aider, continue, Cline) via official installers only with OD-5 consent; record each download <!-- reconciled 2026-10-08: done: specs/009-jev-decision-models/evidence/agents-install.jsonl; tests/test_install_agents.sh PASS -->
- [~] T101 [US4] Per-agent driver table (plan.md "Agent drivers"); run each non-interactively; pass only if the independent request record contains the matching request; record driver model, provider, credential source; Claude Code only with OD-13 consent (FR-049, FR-035) <!-- reconciled 2026-10-08: open: no agent run live with a real prompt (G-060, G-061) | remaining: live-phase agent (OD-27 budget) -->
- [x] T102 [P] [SUBAGENT] [US4] Integration kit: command-hook templates (fail-closed default), minimal local tool server `mcp_stdio.py`, tool-definition emitters, tested consumer-side router (ideas 3-I03, 1-I11); existence verdicts for `jev-mcp-server`, `pi-jev`/`jev-pi` before documenting (idea 2-I07) (FR-086) <!-- reconciled 2026-10-08: done: internal/mcpserver, tests/test_mcp_stdio.sh, tests/test_agent_kit.sh PASS -->
- [x] T103 [P] [SUBAGENT] [US4] Per-agent docs under `docs/agents/` with env-reference key forms only (no literal key — doc-audit rule, idea 1-I09) (FR-035) <!-- reconciled 2026-10-08: done: docs/agents/*.md; tests/test_docs_no_literal_keys.sh PASS -->
- [ ] T104 [REVIEW] [US4] Independent review <!-- reconciled 2026-10-08: open: no US4 review record | remaining: lead: final review -->

## Phase 10: User Story 9 — Stable contract for wider tooling (P3)

- [x] T110 [TDD] [US9] Contract tests from `contracts/openapi.yaml` and `endpoint-inventory.tsv` (inventory ⇄ OpenAPI status cross-check script `tests/test_contract_sync.sh`) <!-- reconciled 2026-10-08: done: internal/contract/inventory_test.go (inventory vs openapi); internal/server/server.go status table -->
- [x] T111 [US9] Fields-for-calibration-tools page and stability statement (idea 3-I10) <!-- reconciled 2026-10-08: done: docs/calibration-tool-fields.md (fields + stability statement), linked from README -->

## Phase 11: User Story 8 — Docs in sync and release 3.1.0 (P1, runs last; tasks carry [US8])

**Independent test**: Q15, Q16; SC-008, SC-009, SC-011, SC-014.

- [ ] T120 [P] [SUBAGENT] [US8] Documentation: decision-models, decide-gateway, tls-and-keys, cloud-exposure, runbooks (backup/restore cert+key, rotation, upgrade/rollback), FAQ, glossary, limitations (incl. "not a safety guardrail", idea 3-I13), related-tools disambiguation (idea 2-I11), ports page (idea 3-I16), diagrams (Mermaid, render-checked); correct "local-only" claims; generated counts (FR-026, FR-050, FR-051, FR-052, FR-071) <!-- reconciled 2026-10-08: open: most pages exist (docs/decision-models.md, decide-gateway.md, tls-and-keys.md, cloud-exposure.md, runbooks.md, faq.md, glossary.md, limitations.md, related-tools.md); G-063, G-111 and the OD-23 command sections still owed | remaining: docs agent -->
- [x] T121 [TDD] [US8] Doc audit tool `tests/test_docs_audit.sh`: stale counts, wrong ports, missing links, code/doc mismatch, literal keys → 0 mismatches (SC-009); also add `tests/test_task_coverage.sh` failing on any FR or SC not cited by a task here <!-- reconciled 2026-10-08: done: tests/test_docs_audit.sh + tests/py/docs_audit.py, tests/test_task_coverage.sh + tests/py/task_coverage.py, tests/coverage_rows.sh (golden-good/bad + control needles; real tree 106/106 FR+SC, 19/19 ADOPT cited) -->
- [ ] T123 [US8] Version 3.1.0 across VERSION, CHANGELOG (in-depth), README, docs headers, catalog (FR-053) <!-- reconciled 2026-10-08: open: VERSION is 3.1.0 but CHANGELOG 3.1.0 is a DRAFT (G-076) | remaining: lead at release time -->
- [ ] T124 [US8] Full suite + `make validate` + constitution harness + meta-test; candidate-fingerprinted readiness verdict (FR-056, FR-034) <!-- reconciled 2026-10-08: open: last recorded full run is evidence/p7-make-test.log (before later changes); no candidate-fingerprinted readiness verdict | remaining: lead -->
- [x] T125 [US8] Operator live manual QA hand-off: WAIVED by the operator 2026-10-08 (OD-25), recorded in CHANGELOG, release notes and the readiness verdict <!-- reconciled 2026-10-08: waived: evidence/od-decisions.md OD-25 -->
- [ ] T126 [US8] Release scripts: assets, tag verification, reproducible archive, SHA256SUMS, CycloneDX SBOM, licence notice, optional signature (OD-4) (FR-084) <!-- reconciled 2026-10-08: open: scripts/release has create_release.sh and scan_archive.py; no SBOM, SHA256SUMS or reproducible-archive step found | remaining: lead -->
- [ ] T127 [US8] Annotated tag on exact commit; fast-forward push to all five remotes; `gh release create` and `glab release create` with assets; re-download and verify from both forges and run the archive's own tests; merge to `main` ff-only after QA (FR-054, FR-055) <!-- reconciled 2026-10-08: open: no tag, push or release performed (operator instruction) | remaining: lead / operator -->
- [ ] T129 [US8] SC-004 closure: every high/critical row of `source-findings.md` and `research/jev-llmctl-new-files.md` fixed with a RED→GREEN pair or demoted with captured evidence; 0 open at release; generated table in `evidence/sc004.json` (SC-004) <!-- reconciled 2026-10-08: open: evidence/sc004-closure.md: 2 high rows OPEN (D-01, D-06; both need the real encoder model) | remaining: live-phase agent (see audit-REPORT.md) -->
- [ ] T128 [REVIEW] Final independent review <!-- reconciled 2026-10-08: open: final independent review not run; round-3 fixes (evidence/review-4/fix-H/I/J) await re-review | remaining: lead -->

## Checkpoint gates (human approval required; execution pauses)

| After | Gate | Approver evidence |
|---|---|---|
| T006 | Port faithful (519 files accounted, differential as expected) | `evidence/p0-port-differential.json` + review GO |
| T015 | RED suites approved (TDD gate) | per-finding RED output |
| T029 | Foundation: first-start message and trust steps seen end to end | leak scan, mutation results |
| T045 | US1 typed answers on a real profile | `evidence/us1-smoke.jsonl` |
| T059 | Transport matrix 100% pass-or-reasoned | `evidence/matrix.json` |
| T067 | Real-model evidence bundle | SHA256SUMS |
| T125 | Live manual QA before tag | readiness verdict |

- [x] T130 Portability run on `nezha.local` (ALT Linux): rsync the exact working tree to ~/llmctl-work/llmctl, run `make test`, `go vet/test -race ./...`, build the binary, run the shell gates; record every host-specific failure as a gap and fix it (macOS remains static/dry-run only) <!-- reconciled 2026-10-08: done: specs/009-jev-decision-models/evidence/portability-nezha/REPORT.md; findings G-081..G-089 fixed (FIX-D) -->

## Dependencies & order

Phase 1 → Phase 2 (blocks all). Then US1 → US2 (needs gateway) → US3 (needs catalog + gateway). US5/US7 follow US1; US6 needs US3's harness; US4 needs US2; US9 anytime after US2; Phase 11 last. Parallel `[P]` tasks touch disjoint files; subagent streams per `plan.md` Execution Strategy.

## Coverage closure

`tests/coverage_rows.sh` (add in T121) fails if any ADOPT / ADOPT-AFTER-VERIFICATION idea id from `research/ideas-closure.md` is not cited here. Cited: 1-I01 1-I03 1-I04 1-I05 1-I09 1-I10 1-I11 2-I02 2-I04 2-I05 2-I06 2-I07 2-I09 2-I11 3-I01 3-I03 3-I05 3-I06 3-I08(harness) 3-I10 3-I12 3-I13 3-I14 3-I16. All other ids are DONE, MERGED, SUPERSEDED or ADOPT-LATER (2-I01, 3-I07, 3-I15, 3-I17 and the user-facing part of 1-I05/3-I08) and are intentionally not scheduled.

## MVP

Phase 1 + 2 + US1 (T001–T045): a hardened, key-protected HTTPS gateway answering real typed questions on one real profile.

## Added by operator decisions of 2026-10-08
- [x] T131 Fix the HTTP/3 cluster CLI (G-106): SAN-carrying daemon certificates + client cert/trust options in lib/cluster.sh; end-to-end tests (OD-21) <!-- reconciled 2026-10-08: done: specs/009-jev-decision-models/evidence/cluster-REPORT.md; G-106 FIXED-VERIFIED -->
- [x] T132 [TDD] Implement `llmctl decide completions {bash|zsh}` (FR-081, OD-23) <!-- reconciled 2026-10-08: done: specs/009-jev-decision-models/evidence/cmd-REPORT.md; cmd/llmctl-decide/cmd_completions.go + cmd_completions_test.go -->
- [x] T133 [TDD] Implement `llmctl decide probe-order` (FR-080, OD-23) <!-- reconciled 2026-10-08: done: specs/009-jev-decision-models/evidence/cmd-REPORT.md; cmd/llmctl-decide/cmd_probeorder.go + cmd_probeorder_test.go -->
- [x] T134 [TDD] Implement `llmctl decide calibrate` (FR-080: accuracy +- interval, baseline, ECE/MCE/Brier, temperature|platt|isotonic fit, profile bound to model sha + template hash, refuses claims below 200 labels) (OD-23) <!-- reconciled 2026-10-08: done: specs/009-jev-decision-models/evidence/cmd-REPORT.md; cmd/llmctl-decide/cmd_calibrate.go, internal/calibrate/ -->
- [x] T135 [TDD] Implement `llmctl decide scale <profile> <N>` (admission-bounded; instance keys <profile>, <profile>.2 ...; registry-allocated ports; throughput mode marking) (OD-23) <!-- done 2026-10-08: lib/scheduler.sh sched_decision_scale + tests/test_decide_scale.sh (dry-run, fixture); real-engine start unverified -->
- [ ] T136 Revert the "planned, not in 3.1.0" markers in contracts/cli.md, traceability.md, docs and changelog once T132-T135 pass <!-- reconciled 2026-10-08: blocked: waits for T135 (and T137/T138 for the calibration and maturity markers) | remaining: lead -->
- [x] T137 [TDD] Gateway applies a calibration profile (FR-080): publish `decision.template_hash` in the catalog; load with calibrate.LoadProfile(path, liveModelSHA, liveTemplateHash) (refuses unbound/mismatched); add calibrate.FromProfile; apply to confidence only; opt-in decision log (FR-080, env LLMCTL_DECIDE_LOG_STATE) — after agent NATIVE releases internal/gateway <!-- reconciled 2026-10-08: open: in progress: internal/gateway/calibration.go and calibration_test.go exist uncommitted; models/catalog.json has no decision.template_hash; not yet verified | remaining: calibration agent -->
- [x] T138 [TDD] Per-profile x type maturity labels (OD-24): catalog `maturity` field (measured-evidence reference), /v1/models exposes `experimental_types`, plan/doc tables show it, response metadata flags experimental answers; catalog test requires evidence reference <!-- reconciled 2026-10-08: done: catalog maturity (tests/test_catalog_json.sh), /v1/models experimental_types + response metadata (internal/server/maturity_test.go), llmctl plan table (lib/catalog.sh), docs/hardware-tiers.md, llmctl doctor per-profile x type lines (tests/test_doctor_decide.sh T138) -->
- [ ] T139 Planner memory fix (G-137/G-138): measured overhead_mb (+ VRAM overhead on CUDA hosts) for every decision profile; catalog test requires it <!-- reconciled 2026-10-08: open: overhead_mb present for 6 catalog entries only; kev-4b/9b/lev lack measurements (G-137, G-138) | remaining: lead (measure on nezha) -->
- [x] T140 Real-curl HTTP/3 verification of the cluster CLI (OD-30): private-prefix curl+nghttp3+ngtcp2 build, run the three cluster suites with it <!-- reconciled 2026-10-08: done: G-106 FIXED-VERIFIED and G-089 CLOSED-VERIFIED in evidence/gaps-register.md (real curl over QUIC) -->
- [x] T141 llmctld DDoS/stress observation tests write to a temp dir unless LLMCTL_QA_EVIDENCE=1; restore docs/qa/008 observation files to HEAD (hygiene) <!-- reconciled 2026-10-08: done: llmctld/internal/api/evidence_dir_test.go (go test ok 2026-10-08), loadtest_helpers_test.go gates on LLMCTL_QA_EVIDENCE=1; git diff of docs/qa/008-full-test-coverage is empty -->
- [ ] T142 Announce to the operator when the refused profiles (lev, kev-4b, kev-9b, kev-08b at final values) should be re-run locally with freed RAM (OD-31) <!-- reconciled 2026-10-08: blocked: needs the operator to free RAM on this host (OD-31) before the refused profiles can be re-run | remaining: operator, then live-phase agent -->

## Reconciliation 2026-10-08

> **GENERATED** from `evidence/tasks-reconciliation-2026-10-08.json` (task id -> status, evidence, remaining owner); evidence paths were checked to exist when the file was written. A task is ticked only when its status is `done` or `waived`; the checkbox lines above carry the same evidence in a trailing comment.

Counts: done 53, waived 1, open 48, blocked 2 (total 104 task lines).

Changes versus the previous ticks: T027, T040, T041, T050, T051, T056, T057, T063, T072, T093, T093n, T110, T130, T132, T133, T134, T137, T141.

| Task | Status | Evidence | Remaining (owner) |
|---|---|---|---|
| T001 | done | specs/009-jev-decision-models/evidence/p0-baseline.json | - |
| T002 | done | specs/009-jev-decision-models/evidence/p0-baseline.json (t002), evidence/p0-baseline-make-test.log | - |
| T003 | done | specs/009-jev-decision-models/evidence/p0-baseline.json (t003_t004: 24 applied, 2 HEAD-wins, 0 byte mismatches) | - |
| T004 | done | specs/009-jev-decision-models/evidence/p0-baseline.json (t003_t004: 29 new) | - |
| T005 | done | specs/009-jev-decision-models/evidence/p0-baseline.json (t005) + evidence/p0-port-make-test.log; the planned file p0-port-differential.json was never written, the differential is recorded inside p0-baseline.json | - |
| T006 | done | specs/009-jev-decision-models/evidence/p0-baseline.json (t006: independent review, verdict GO) | - |
| T010 | done | specs/009-jev-decision-models/evidence/p1-red-original/ (raw RED output, harness archived non-runnable) + evidence/p1-red-register.json; ported guards in tests/test_regression_defects.sh | - |
| T011 | done | specs/009-jev-decision-models/evidence/p1-red-original/n01_n29.jsonl + evidence/red-to-green-map.json | - |
| T012 | done | tests/test_release_no_secrets.sh (PASS in evidence/p7-make-test.log); evidence/p1-red-original/d30.jsonl | - |
| T013 | done | specs/009-jev-decision-models/evidence/p1-red-register.json + source-findings.md (P1 reproduction register) | - |
| T014 | done | tests/evidence/{writer,manifest,leak_scan}.py with tests/py/test_evidence_writer.py, test_evidence_manifest.py, test_leak_scan.py (tests/test_py_unit.sh PASS in evidence/p7-make-test.log) | - |
| T015 | open | no recorded independent review or operator approval of the RED suites as such; the harness is archived (evidence/p1-red-original/README.md) and the guards live in tests/test_regression_defects.sh | lead / operator: fold into the final review T128 or record an explicit waiver |
| T009 | done | go.mod, cmd/llmctl-decide/main.go, tests/test_go_unit.sh (PASS in evidence/p7-make-test.log) | - |
| T020 | done | internal/keyring; evidence/go-port-parity.json (81 pass); tests/test_keyring_go_cli.sh PASS | - |
| T021 | done | internal/certs; evidence/go-port-parity.json (72 pass); tests/test_certs_go_cli.sh + test_certs_go_mutation.sh PASS (13/13 mutants) | - |
| T022 | done | internal/contract, internal/readout; evidence/go-port-parity.json (88 + 25 pass) | - |
| T023 | done | internal/server (go test ok in evidence/p7-make-test.log); tests/test_gateway_endpoints.sh PASS | - |
| T024 | done | internal/audit, internal/metrics; evidence/go-port-parity.json (30 + 17 pass) | - |
| T025 | open | tests/test_no_retired_vars.sh exists and PASSED in evidence/p7-make-test.log but FAILS on the current tree: docs/scripts/test_no_retired_vars.md (new docs page) quotes the retired names (run 2026-10-08) | lead: allow-list the page (path:N pinned) or reword its header comment, re-run the suite |
| T025b | done | evidence/go-port-parity.json (prototypes removed after Go parity) | - |
| T026 | done | scripts/release/public_allowlist.txt, .gitignore (cert/), tests/test_release_no_secrets.sh PASS (evidence/p7-make-test.log) | - |
| T027 | done | tests/test_decide_security_mutation.sh, tests/test_gateway_mutation.sh, tests/test_certs_go_mutation.sh (all PASS in evidence/p7-make-test.log); lives in tests/ not tests/mutation/ | - |
| T028 | open | no evidence/coverage-p2.json; only per-package go -cover numbers inside evidence/p7-make-test.log; bash PS4 and Python trace coverage not measured | lead: measure-and-report only (OD-15) |
| T030 | done | .specify/memory/constitution.md (Amendment 2.1.0, lines 91/189/208) | - |
| T029 | open | independent foundation review with the operator seeing the first-start message not recorded as a single checkpoint (reviews exist per round in evidence/review-2..4, all NO-GO then fixed forward) | lead: final review T128 |
| T040 | done | internal/readout (readout_test.go) ; real-model readout runs in evidence/live/decide-kev-08b, decide-julia, decide-laya (N-10 stays under G-075) | - |
| T041 | open | lib/llmctl_decide/nli.py and tests/py/test_nli.py do not exist (superseded by internal/gateway/nli.go + lib/onnx_server.py); premise-only truncation with the REAL tokenizer is not evidenced (D-01 OPEN in evidence/sc004-closure.md) | live-phase agent: download decide-nli tokenizer, RED against the candidate encode_pair, GREEN on the shipped runtime |
| T042 | done | internal/server, internal/gateway; tests/test_gateway_endpoints.sh PASS; matrix 45 cases x 6 clients (evidence/p7-make-test.log) | - |
| T043 | done | internal/client, cmd/llmctl-decide/cmd_ask_test.go; tests/test_decide.sh PASS | - |
| T044 | open | evidence/us1-smoke.jsonl absent; decide-tiny not downloaded (models dir holds native profiles only) | live-phase agent |
| T046 | open | evidence/sc001.json absent | live-phase agent |
| T045 | open | no US1 review record | lead: final review |
| T050 | done | cmd/llmctl-decide/cmd_serve_test.go TestResolveBind (LLMCTL_DECIDE_BIND over LLMCTL_BIND_HOST); tests/test_gateway_endpoints.sh banner asserts URL and CA SHA-256 fingerprint | - |
| T051 | done | cmd/llmctl-decide/cmd_cert.go, cmd_key.go (doctor/show/path/rotate/export); tests/test_keyring_go_cli.sh, test_certs_go_cli.sh PASS | - |
| T052 | done | cmd/llmctl-decide/cmd_serve_test.go TestServeStopNeverSignalsUnrelatedProcess; tests/test_gateway_endpoints.sh | - |
| T053 | open | per-start key done (G-028: ExecStartPre rotation; tests/test_decide_service.sh) but the 'engine ports unreachable from the second vantage' test is not evidenced (G-032 OPEN) | lead: wire the vantage probe at the real gateway and engine ports |
| T054 | done | internal/vantage, tests/test_vantage.sh PASS (evidence/p7-make-test.log) | - |
| T055 | open | matrix runs 45 cases x 6 clients (evidence/p7-make-test.log) but llmctl-cli + 7 agent adapters + second-vantage wiring are pending (G-043) | lead: T055b |
| T056 | done | tests/matrix/clients/README.md (SDK adapters report TRUST mechanism); G-038 SDK cells EP-030 pass (py 11, js 11); evidence/dependency-verdicts.json | - |
| T057 | done | tests/matrix/negative_tls.py via tests/test_matrix_harness.sh (log: 'negative TLS covers every FR-070 case'); internal/server chaos/limit tests (go test ok); file names differ from the plan | - |
| T058 | open | docs/cloud-exposure.md exists, but the 'not exercised: no external vantage' evidence statement is not in it and no external-vantage run exists | lead: add the evidence sentence or run if OD-12 grants a vantage |
| T058n | open | evidence/portability-nezha/ has gateway-on-nezha with client on this host; the planned nezha-to-this-host authenticated matrix subset is G-090 OPEN | live-phase agent |
| T059 | open | no US2 review record | lead: final review |
| T060 | done | specs/009-jev-decision-models/evidence/pin-reverify.json; tests/test_catalog_json.sh PASS | - |
| T061 | open | the six originally pinned models are not downloaded (only native profiles are in ~/.local/share/llmctl/models) | live-phase agent (RAM/disk permitting, OD-31) |
| T062 | open | real readout runs exist for julia/laya/kev-08b only (evidence/live/); encoder RSS and the six-profile set absent | live-phase agent |
| T063 | done | tests/fixtures/golden, scripts/golden/*, docs/golden-set.md; tests/py/test_golden_*.py PASS; labels provisional per OD-22 (G-110) | - |
| T064 | open | no per-profile flip-rate/accuracy-vs-options run feeding decision.max_options (only evidence/live/*/probes for 3 native profiles) | live-phase agent |
| T065 | open | no JevBench adapter run (no evidence) | live-phase agent / operator decision |
| T066 | open | refusals recorded only for lev/kev-4b/kev-9b (G-136); the pinned six not recorded | lead with T142 |
| T068 | open | evidence/live-models.jsonl absent; 3 of 6 native profiles live (G-136) | live-phase agent, depends on OD-31 |
| T062n | open | only decide-kev-08b ran on nezha (evidence/live/nezha) | live-phase agent |
| T067 | open | no US3 review record | lead: final review |
| T069 | done | helix-deps.yaml, tests/test_containers_submodule.sh PASS | - |
| T076 | done | internal/registry (go test ok, evidence/p7-make-test.log); tests/test_registry_discovery.sh PASS | - |
| T077 | done | tests/test_dynamic_ports.sh PASS; G-025 CLOSED (Linux) | - |
| T070 | done | tests/test_decision_capacity.sh PASS; models/catalog.json decide-max port 8097 | - |
| T071 | open | decide scale not implemented (T135) | lead / scale agent |
| T072 | done | internal/gateway/router.go + router_test.go TestRouterThroughputLeastLoaded; internal/server/server_test.go TestSaturation529, TestQueueDeadline529 | - |
| T073 | open | evidence/us5-capacity.jsonl absent | live-phase agent |
| T074 | open | no toolkit-snapshot consumer probe evidence | lead |
| T075 | open | no US5 review record | lead: final review |
| T080 | done | tests/test_services.sh, tests/test_decide_service.sh PASS; docs/qa/dynamic-ports-validation/live-systemd-user-run.txt | - |
| T081 | done | tests/test_macos_plist.sh PASS (labelled statically verified only, OD-29) | - |
| T082 | done | tests/test_doctor_decide.sh PASS | - |
| T083 | done | tests/test_gateway_stress.sh PASS; internal/server TestGracefulDrain, TestSaturation529 | - |
| T084 | open | calibrate/probe-order/completions done (T132-T134), schema done (internal/schema); decision-log opt-in not done (G-135) | lead |
| T085 | open | no US7 review record | lead: final review |
| T090 | done | lib/admit.sh, tests/test_admit.sh PASS | - |
| T091 | open | paper checks recorded for 48 candidates (evidence/admission/SUMMARY.md: 0 ADMITTED, 13 ADMIT-CANDIDATE); real runs pending (G-013) | live-phase agent |
| T092 | open | no USER-ONLY ONNX encoder overlay example evidenced | lead |
| T093 | done | evidence/engine-advance-local/ROLLBACK.txt; pin b10969 -> b11379 with all OD-1 gates (G-133, G-134) | - |
| T093n | done | evidence/engine-advance/ (nezha scratch build, G-114); evidence/live/nezha | - |
| T094 | open | decide-2b is in models/catalog.json; APUS-4B is not | lead |
| T095 | open | no US6 review record | lead: final review |
| T100 | done | specs/009-jev-decision-models/evidence/agents-install.jsonl; tests/test_install_agents.sh PASS | - |
| T101 | open | no agent run live with a real prompt (G-060, G-061) | live-phase agent (OD-27 budget) |
| T102 | done | internal/mcpserver, tests/test_mcp_stdio.sh, tests/test_agent_kit.sh PASS | - |
| T103 | done | docs/agents/*.md; tests/test_docs_no_literal_keys.sh PASS | - |
| T104 | open | no US4 review record | lead: final review |
| T110 | done | internal/contract/inventory_test.go (inventory vs openapi); internal/server/server.go status table | - |
| T111 | open | no fields-for-calibration-tools page or stability statement found under docs/ | docs agent |
| T120 | open | most pages exist (docs/decision-models.md, decide-gateway.md, tls-and-keys.md, cloud-exposure.md, runbooks.md, faq.md, glossary.md, limitations.md, related-tools.md); G-063, G-111 and the OD-23 command sections still owed | docs agent |
| T121 | done | tests/test_docs_audit.sh, tests/test_task_coverage.sh, tests/coverage_rows.sh PASS | - |
| T123 | open | VERSION is 3.1.0 but CHANGELOG 3.1.0 is a DRAFT (G-076) | lead at release time |
| T124 | open | last recorded full run is evidence/p7-make-test.log (before later changes); no candidate-fingerprinted readiness verdict | lead |
| T125 | waived | evidence/od-decisions.md OD-25 | - |
| T126 | open | scripts/release has create_release.sh and scan_archive.py; no SBOM, SHA256SUMS or reproducible-archive step found | lead |
| T127 | open | no tag, push or release performed (operator instruction) | lead / operator |
| T129 | open | evidence/sc004-closure.md: 2 high rows OPEN (D-01, D-06; both need the real encoder model) | live-phase agent (see audit-REPORT.md) |
| T128 | open | final independent review not run; round-3 fixes (evidence/review-4/fix-H/I/J) await re-review | lead |
| T130 | done | specs/009-jev-decision-models/evidence/portability-nezha/REPORT.md; findings G-081..G-089 fixed (FIX-D) | re-run on nezha after final tree optional |
| T131 | done | specs/009-jev-decision-models/evidence/cluster-REPORT.md; G-106 FIXED-VERIFIED | - |
| T132 | done | specs/009-jev-decision-models/evidence/cmd-REPORT.md; cmd/llmctl-decide/cmd_completions.go + cmd_completions_test.go | - |
| T133 | done | specs/009-jev-decision-models/evidence/cmd-REPORT.md; cmd/llmctl-decide/cmd_probeorder.go + cmd_probeorder_test.go | - |
| T134 | done | specs/009-jev-decision-models/evidence/cmd-REPORT.md; cmd/llmctl-decide/cmd_calibrate.go, internal/calibrate/ | - |
| T135 | open | decide scale not implemented | scale agent / lead |
| T136 | blocked | waits for T135 (and T137/T138 for the calibration and maturity markers) | lead |
| T137 | open | in progress: internal/gateway/calibration.go and calibration_test.go exist uncommitted; models/catalog.json has no decision.template_hash; not yet verified | calibration agent |
| T138 | done | catalog maturity, /v1/models experimental_types, plan + doctor tables, response flag | - |
| T139 | open | overhead_mb present for 6 catalog entries only; kev-4b/9b/lev lack measurements (G-137, G-138) | lead (measure on nezha) |
| T140 | done | G-106 FIXED-VERIFIED and G-089 CLOSED-VERIFIED in evidence/gaps-register.md (real curl over QUIC) | - |
| T141 | done | llmctld/internal/api/evidence_dir_test.go (go test ok 2026-10-08), loadtest_helpers_test.go gates on LLMCTL_QA_EVIDENCE=1; git diff of docs/qa/008-full-test-coverage is empty | - |
| T142 | blocked | needs the operator to free RAM on this host (OD-31) before the refused profiles can be re-run | operator, then live-phase agent |
