# Traceability — requirements → phases → test types → evidence

**Feature**: 009-jev-decision-models | **Date**: 2026-10-07 | Phases are defined in [plan.md](plan.md); scenarios (Q#) in [quickstart.md](quickstart.md); endpoint cases (EP-###) in [contracts/endpoint-inventory.tsv](contracts/endpoint-inventory.tsv).

Test-type key: **U** unit (stand-ins allowed, tagged) · **I** integration (real components) · **E** end-to-end · **C** contract/schema · **S** security · **P** performance/benchmark · **X** stress/chaos · **T** TLS conformance/negative · **R** reachability (second vantage) · **A** agent live · **M** matrix · **D** determinism · **G** documentation audit · **Rel** release check.

Rule for `tasks.md`: every row below becomes ≥ 1 task with a RED-first test where the requirement is executable; every FR must have an evidence record of class `real-model` or `real-component` where the spec demands real behaviour.

| Requirement(s) | Summary | Phase | Test types | Evidence / scenario |
|---|---|---|---|---|
| FR-001, 009–011, 013–016 | typed decisions, one template, determinism, bounded shapes, typed failures, real evidence fields | P2, P3, P4 | U, I, E, D | Q3, Q4 |
| FR-002–005 | licences, pins re-verified, null-hash files pinned, catalog schema | P3, P4 | C, I | Q5; `test_catalog_json.sh` + mutation |
| FR-006 | decision profiles never chat | P3 | C, I | catalog test; route inventory |
| FR-007, 008 | candidate register, admit-if-pass, BYO path | P7 | I, E | candidates register; BYO real example |
| FR-012 | limits; encoder never truncates question/option | P2, P3 | U, I | EP-003, 015, 017 |
| FR-017–020 | endpoint shapes, bind default, auth, key hygiene | P2 | I, S, T, M | Q2, Q8, EP-001…061 |
| FR-021–024 | health leakage, hostile clients, safe stop, test seams inert | P1, P2 | U, I, S, X | P1 RED→GREEN; Q9 |
| FR-025, 077 | locked, hash-pinned encoder dependencies, venv | P3 | I, S | lock verification; doctor |
| FR-026 | bind statement consistency | P9 | G | Q15 |
| FR-027–034 | admission, capacity, multi-instance, selection, services, doctor, cleanup, install | P3, P5 | I, E | Q10; install e2e |
| FR-035, 036, 086 | agent docs, discovery contract, integration kit | P8, P9 | A, C | Q12; discovery-contract check |
| FR-037, 079 | request log, metrics, probes | P5 | I, S | EP-040…052 |
| FR-038–043 | test types, no fakes beyond unit, RED-first, machine evidence, generated counts | all | all | evidence JSONL; Q15 |
| FR-044, 045 | port by 3-way merge; no generated/out-of-tree files | P0 | I | Q1 |
| FR-046–049 | live validation, host safety | P4, P6, P8 | E, R, A | Q3–Q12 |
| FR-050–052 | docs, revision headers, provenance labels | P9 | G | Q15 |
| FR-053–056, 084 | version, changelog, release, forge parity, no force-push, constitution harness, supply chain | P10 | Rel | Q16; SC-011, 014 |
| FR-088–091 | dynamic ports, service registry, discovery between services, Containers submodule use | P3, P5, P6 | I, E, X | SC-015; Q17 |
| FR-087 | secrets cannot enter git or release archives (placement guard, `cert/` ignore rule, tracked-file allow-list archive builder, planted-secret test) | P2, P10 | S, I | SC-014; archive plant test |
| FR-057–063 | key variable, resolution, `.env`, display, clients, docs, tests | P2, P9 | U, I, S | Q2, Q13 |
| FR-064, 065, 073 | reachability, cloud reachability, internal engines loopback | P3, P6 | R, I | Q7; EP-070/071 |
| FR-066–072 | HTTPS, BYO cert, trust steps, matrix, negative TLS, docs, chat-server TLS investigation | P2, P4, P6, P9 | T, M, I | Q8, Q11 |
| FR-074 | deterministic mode | P3 | D, I | Q4 |
| FR-075 | hosted contract fidelity | P2, P3 | C, M | EP-001…022 |
| FR-076 | readout guards | P3, P4 | U, I | Q6 |
| FR-078 | backpressure, drain | P2, P5 | I, X | Q9; EP-020/021/046 |
| FR-080 | calibration tooling (OD-23: delivered in 3.1.0) | P5 | U, I | Q6; `decide calibrate` DONE (T134: `internal/calibrate/*_test.go`, `cmd/llmctl-decide/cmd_calibrate_test.go`, `evidence/cmd-REPORT.md`); gateway applies the profile + catalog `decision.template_hash` PENDING (T137) |
| FR-081 | CLI ergonomics (OD-23: all four commands delivered in 3.1.0) | P5 | I, E | `contracts/cli.md` tests; `completions` DONE (T132 `cmd_completions_test.go`), `probe-order` DONE (T133 `cmd_probeorder_test.go`), `calibrate` DONE (T134), `scale` PENDING (T135); the "planned, not in 3.1.0" markers are reverted only when T135 passes (T136) |
| FR-082 | engine HTTPS verification | P4 | I | post-build check + handshake |
| FR-083 | unit hardening probes | P3, P5 | I, S | doctor canary |
| FR-085 | gated engine advance | P7 | I, E | engine gate record |

## Source-coverage closure rules (nothing ignored)

1. **Jev.md** – `research/jev-md-coverage-{1,2,3}.md` (309 rows). Task generation produces, for every ADOPT (41) and ADOPT-AFTER-VERIFICATION (72) row, either a task (cite the row id) or an explicit closure note ("superseded by RD-xx / FR-xx"). REJECT (26) rows are re-audited at P9 to ensure no document re-introduces them; OUT-OF-SCOPE (64) rows are checked to appear in the docs "Related tools / not covered" page where useful; the 3 split rows are handled per part. A script (`tests/coverage_rows.sh`) compares row ids in the coverage files with ids cited in `tasks.md` and fails on any ADOPT/ADOPT-AFTER-VERIFICATION row not cited.
2. **jev/llmctl** – `research/jev-llmctl-inventory.tsv` (519 files). Every MODIFIED and NEW-IN-JEV path appears in the P0 port commit list or in the "do not import" list (`.pyc`, archives, the two QA `.txt` files); a check compares the inventory with the merged tree and fails on any unaccounted path. The 455 IDENTICAL files need no action and are recorded as such.
3. **Findings** – `source-findings.md` rows D-01…D-31, N-01…N-29 (in `research/jev-llmctl-new-files.md`), I-01…I-11: each ends at FIXED (RED→GREEN pair + mutation) or ACCEPTED-LIMITATION (with reason) or NOT-REPRODUCED (with captured evidence).

## FR to verified test mapping (added 2026-10-08)

Each reference below was resolved by `scripts/spec_closure_audit.py`'s reference checker on 2026-10-08 (file exists; the test name is found in the file where one is given). "Ran" means the named suite passed in `evidence/p7-make-test.log`; later changes were not re-run by this audit. Rows with a pending task show it.

| FR | Verified tests | Pending |
|---|---|---|
| FR-001, 009-011, 013-016, 074 | `tests/test_gateway_endpoints.sh` ("8 repeats of one request give byte-identical bodies"); `internal/contract/request_test.go::TestRejections400`; `cmd/llmctl-decide/cmd_ask_test.go::TestAskStateSources` | real-model smoke T044, SC-001 run T046 |
| FR-002-005 | `tests/test_catalog_json.sh` (ran); `evidence/pin-reverify.json` | - |
| FR-007, 008 | `tests/test_admit.sh` (ran); `evidence/admission/SUMMARY.md` (paper checks) | real runs T091, BYO example T092 |
| FR-017-020, 075 | `internal/contract/inventory_test.go`; `tests/test_gateway_endpoints.sh`; matrix 45 cases x 6 clients (`tests/matrix/run.py`, ran via `tests/test_matrix_harness.sh`) | agent adapters + second vantage T055 |
| FR-021-024 | `tests/test_regression_defects.sh`; `tests/test_no_retired_vars.sh` (currently failing, T025) | T025 |
| FR-037, 079 | `internal/audit`, `internal/metrics` (Go unit tier, ran) | - |
| FR-057-063 | `tests/test_keyring_go_cli.sh` (ran); `internal/keyring/export_test.go` | repo-wide key-leak scan T121b (G-019) |
| FR-064, 065, 073 | `tests/test_vantage.sh` (ran); `internal/vantage/probecore` | cloud evidence T058, nezha matrix T058n |
| FR-066-072 | `tests/test_tls_server.sh` (ran); `tests/matrix/negative_tls.py` (ran via the matrix harness) | - |
| FR-076 | `internal/readout/readout_test.go::TestMissingLetterFlaggedWithUpperBoundNotSilentZero` | - |
| FR-078 | `internal/server/server_test.go::TestSaturation529`, `::TestGracefulDrain`; `internal/gateway/router_test.go::TestRouterThroughputLeastLoaded` | stress script T083 |
| FR-082 | `tests/test_engine_build_decide.sh` (ran); engine advance evidence in `evidence/engine-advance-local/` | - |
| FR-083 | `tests/test_unit_hardening.sh` | doctor canary T082 |
| FR-035, 086 | `tests/test_agent_kit.sh`, `tests/test_mcp_stdio.sh` (ran); `docs/agents/*.md` | live agent run T101 |
| FR-044, 045 | `evidence/p0-baseline.json` (T003/T004), `tests/test_archive_completeness.sh` | - |
| FR-050-052 | `tests/test_doc_reachability.sh`, `tests/test_docs_no_literal_keys.sh` (ran) | doc audit tool T121 |
| FR-087 | `tests/test_release_no_secrets.sh` (ran) | - |
| FR-088-091 | `tests/test_dynamic_ports.sh`, `tests/test_registry_discovery.sh`, `tests/test_containers_submodule.sh` (ran) | - |
| SC-004 | `evidence/sc004-closure.md` (generated by `scripts/spec_closure_audit.py`) | 2 high rows open: D-01, D-06 (T129) |
