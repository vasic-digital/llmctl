# Documentation pass report (agent DOCS, 2026-10-08)

## Created
- `scripts/check_doc_reachability.sh`, `tests/test_doc_reachability.sh` (test written first: 17 failures RED, then GREEN; 18 assertions; control needle = planted orphan; negative control; real tree orphans=0; bash 3.2-style code, not run under a real 3.2)
- `docs/cloud-exposure.md`, `docs/runbooks.md`, `docs/limitations.md`, `docs/glossary.md`, `docs/related-tools.md`, `docs/scripts/README.md`, `docs/qa/README.md`
- 41 `docs/scripts/*.md` pages (generated from each file's own header comment: golden/*.py, check_doc_reachability, 35 test suites); no hand-typed counts (test_doc_reachability states 18, matches `doc_counts.sh --check`)

## Changed
README.md (engine pin, release note, command table, documentation index incl. new docs, llmctld-cluster-tls), CHANGELOG.md (3.1.0: pin advance, tenant ids, aider offline, migration rows, cluster CLI fix), docs/architecture.md (corrected stale v0.4.0 and "127.0.0.1 only"; 5 new Mermaid diagrams: architecture, data flow, registry-row and engine-service state machines, ask sequence), docs/user-manual.md (build targets, decide batch/models/key/cert/registry/schema/admit, cluster|tenant|apikey rewritten; fixed a broken anchor), docs/tutorial.md, docs/faq.md, docs/validation.md, docs/integrations.md, docs/decide-gateway.md (schema/MCP section, G-063), docs/agents/README.md (wrong `llmctl cert/key` commands), docs/scripts/test_engine.md.
Not touched: VERSION (still 3.0.2; T123 owner), docs/decision-models.md, files owned by NATIVE.

## Verified how
- `bash tests/test_doc_reachability.sh` PASS; `scripts/check_doc_reachability.sh --check-links`: reachable=178 orphans=0 broken=0
- `tests/test_docs_no_literal_keys.sh` PASS; `tests/test_syntax.sh` PASS; `make lint` run (shellcheck 0.11.0); `doc_counts.sh --check docs_no_literal_keys doc_reachability` match
- Mermaid: the 5 new architecture diagrams and the runbook diagram rendered with `mmdc` without error (pre-existing diagrams not re-rendered)
- Commands/flags/exit codes checked by running a scratch-built `llmctl-decide` (key doctor/rotate, cert ensure/show/doctor, usage of every subcommand) in a temp home; nothing left in the repo
- Full `make test` and `doc_counts --all` NOT run (as instructed)

## Findings for the coordinator (code, not changed by me)
1. `lib/decide.sh:559` does not forward `smoke`, `mcp`, `vantage` (`llmctl decide smoke` -> "unknown decide subcommand") although help/usage list smoke. Docs say to run the binary directly. Fix = add them to the passthrough case.
2. Needs a section once implemented (OD-23: scale, calibrate, probe-order, completions): docs/user-manual.md (decide section), docs/decide-gateway.md, docs/faq.md, docs/limitations.md ("No calibration is claimed" paragraph and the option-order bullet), docs/decision-models.md (calibration section), docs/golden-set.md, README command table, CHANGELOG Added, docs/scripts/decide.md, usage text in lib/decide.sh, glossary, runbooks (if calibration profiles need backup).
3. docs/faq.md cluster/tenant/apikey entries are still "planned" in many places; I added an update banner but did not re-audit each entry.
4. docs/decision-models.md / hardware-tiers.md / architecture port map list profiles; catalog now has more decide profiles (8103-8108); README/user-manual now point to decision-models.md instead of enumerating.
5. No dedicated "ports page" (idea 3-I16) was created; the port map is in architecture.md and runbooks "Port conflicts".
6. Spec/plan still mention the Python gateway in places (G-021) - not swept.

## Unverified statements in the new docs
- Cloud-exposure advice is reasoned from code and research notes; no internet-facing deployment was exercised.
- `SIGHUP` reload and `cert renew` swap were read from code/docs, not re-run live here.
- related-tools: third-party facts come from the research notes; jev-gateway and jev-compatible-local-decider are marked UNVERIFIED.
- limitations "verified live" list is taken from the gap register state at writing; golden-set accuracy numbers: none exist; any later number must carry "provisional - labels agent-authored, human review pending".
- Generated script pages reproduce header comments; they contain no behavioural claims beyond them.
- Cluster: "real curl over QUIC" unverified (stated in docs).
