# Documentation pass 2 report (agent DOCS2, 2026-10-08)

Nothing staged or committed.

## Files changed
- Version: `VERSION` (3.1.0), `bin/llmctl` (`LLMCTL_VERSION` 0.1.0 -> 3.1.0; it printed a stale 0.1.0), `tests/test_cli.sh` (pinned string updated, plus new assertion that `llmctl version` equals `VERSION`), `docs/user-manual.md`. `models/catalog.json` NOT edited: its `version` is the schema version (1), no bump needed. Tests mentioning `3.0.2` refer to the previous release tag; correct, untouched.
- FAQ (task 1): `docs/faq.md` rev 2: intro, legend, daemon-unreachable, all cluster / persistence / auth / tenant / quota / OIDC / audit entries rewritten as wired / library only / not built; release-automation entries (also stale: said no scripts/release exists) rewritten.
- `docs/cluster-architecture.md` (stale intro box and section 4 said no HTTP routes exist; text and one diagram corrected), `docs/api-reference.md` (section 2 rewritten from the real route registrations; bind-address statement corrected).
- Ports (tasks 2, 3): new `docs/ports.md`; `docs/hardware-tiers.md` (ranking now lists the six native profiles, slots, gating, new section "How the planner estimates memory" with no numbers that will change); `docs/architecture.md` port map and diagram (six native profiles); README docs index row.
- HTTP/3: `docs/llmctld-cluster-tls.md` (verification text plus new section "Getting a curl that lists HTTP3"), `docs/user-manual.md`, `docs/faq.md`, `docs/tutorial.md`, `docs/limitations.md`, `CHANGELOG.md`.
- Release status: `CHANGELOG.md` (heading date policy, release-status block with the manual-QA waiver, new Known limitations section, ports doc), `docs/validation.md` (new "Release gate status"), `docs/limitations.md` rev 2 (release status, maturity policy, native-profile section, rewritten platform bullets), `README.md` (support table).
- `docs/runbooks.md`: new "The scheduler refuses a start" (incl. CPU-mode VRAM), LD_LIBRARY_PATH section rewritten, port conflicts links to ports.md.
- G-021: `specs/009-jev-decision-models/plan.md`, `research.md` (RD-21/26/27 marked historical), `spec.md` (T025b now done). spec/data-model/quickstart/contracts/checklists otherwise had no stale Python-gateway statements. No `amber` promises found in any doc.
- `docs/scripts/README.md`: rows for `coverage` and `spec_closure_audit` (coordinator request).

## How claims were verified
- Cluster entries: read `llmctld/cmd/llmctld/main.go` wiring and `internal/api/routes_*.go`; test names cited exist (`grep ^func Test`). Findings: health monitor + replication-role reassignment wired; `PartitionWatcher`, `Enforcer.AllowRequest` (429), `OIDCAuthenticator`, `ShouldCheckpoint`, `ReplicateAdapter` backoff have NO non-test callers; audit log is in-memory and `Anchor()` is never called by the daemon; inference does not pass through llmctld. Not run: the Go tests themselves.
- Catalog table in ports.md and sizes/tiers/slots in hardware-tiers checked by script against `models/catalog.json`; ranking against `sched_rank_for_capability`; conflict message and `LLMCTL_PORT_<PROFILE>` rule against `lib/scheduler.sh`, `lib/catalog.sh`, `lib/portreg.sh`.
- HTTP/3 claims copied from `evidence/curl-h3/CURL-H3-REPORT.md`; native-profile numbers from `evidence/live/NATIVE-REPORT.md`.
- Mermaid: edited cluster diagram and port-map diagram rendered with mmdc (`--no-sandbox`).
- Gates run: `tests/test_docs_no_literal_keys.sh` PASS, `tests/test_doc_reachability.sh` PASS, `scripts/check_doc_reachability.sh --check-links` reachable=181 orphans=0 broken=0, `tests/test_syntax.sh` PASS, `tests/test_cli.sh` PASS, `make lint` rc=0, `doc_counts --check docs_no_literal_keys doc_reachability` match. Full `make test` not run.

## Honest gaps
- ports.md "Defaults of other tools" (11434, 8000, 1234, 7860, 8080) is general knowledge, labelled not verified.
- Collisions on the dev host: only 8099/8100/8102/8110/8111 are recorded as other programs; 8080/8082/8087 may be llmctl's own services (stated on the page).
- FAQ statements about what is not exercised (partition, multi-host) are absence of tests, not measured failures.
- `docs/scripts/test_cli.md` has no pinned count, so nothing to update; the new test assertion changes `test_cli` to 29 ok.
- Maturity labels are documented as policy only; T138 not built.

## Items for other owners
- `docs/decide-gateway.md:312` still says the shell front end does not forward `mcp`/`smoke`/`vantage`; it now does (`_DECIDE_FORWARDED`). Other agent's file.
- `.specify/memory/constitution.md` and `specs/.../contracts/cli.md` not checked for the same.

## Places still needing the four new commands (scale, calibrate, probe-order, completions)
`docs/user-manual.md` (decide section, subcommand list), `docs/decide-gateway.md`, `docs/faq.md` (calibration / option-order entries), `docs/limitations.md` ("No calibration is claimed" paragraph and option-order bullet), `docs/decision-models.md`, `docs/golden-set.md`, `README.md` command table, `CHANGELOG.md` Added, `docs/scripts/decide.md`, `lib/decide.sh` usage, `docs/glossary.md`, `docs/runbooks.md` (calibration profile backup), `docs/ports.md` none.
