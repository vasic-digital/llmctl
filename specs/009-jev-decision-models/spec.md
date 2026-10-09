# Feature Specification: Jev-Class Decision Models in llmctl

**Feature Branch**: `009-jev-decision-models` (no branch was created; the `before_specify` git hook is not registered in this project)

**Created**: 2026-10-07

**Status**: Draft

**Input**: User description: "In directory /home/milosvasic/Projects/jev we have per project pre-work with in depth documentation, materials, full work by our 2nd developers team ... to fully incorporate support for Jev model and other Jev-like models into llmctl System ... bring them up locally and expose to local host or local network like we already do with traditional LLM models ... fully LIVE test new version on current host, all supported models, from all supported CLI agents ... release new version using GitHub and GitLab CLI agents ... All documentation MUST BE in sync ... version and change logs." (full verbatim text preserved in the invocation that created this file)

## Background and Source Material *(mandatory context)*

**What a "decision model" is.** A decision model does not write text. It answers a typed question about a piece of state in a single pass and returns a probability-shaped answer. There are three question types: a yes/no question (a probability), a pick-one-of-N question (the chosen option plus a probability for every option and a confidence), and a rate-on-an-ordered-scale question (a probability-weighted score plus a confidence). "Jev" is the hosted commercial model of this kind (vendor: TypeSafe AI). Its wire format has become the de-facto shape that a family of open "Jev-like" models imitate.

**Honest premise that shapes the whole feature.** The original Jev has closed weights and is available only as a hosted service. It **cannot** be brought up locally by any means. What llmctl can bring up locally are open Jev-like models that speak the same typed-decision shape. "Support for Jev" in llmctl therefore means: serve open, locally-run decision models behind a Jev-compatible interface, with no claim of parity with hosted Jev.

**What exists today.**
- The real repository (version 3.0.2, HEAD `a9ebefe`) has **no decision-model support**: 10 chat profiles, no `decide` command, no decision gateway.
- A second developer team produced a complete candidate implementation in `/home/milosvasic/Projects/jev/llmctl/llmctl` (a snapshot taken from a post-3.0.2 state of the main branch): six decision profiles, a `decide` command (ask / capacity / status / interactive / serve), an HTTP gateway, a pure-Python ONNX runner for encoder-class models, catalog and planner extensions, tests, research notes and QA captures.
- Sibling snapshots in the same material set show how the wider system expects llmctl to behave: a toolkit snapshot (`claude_toolkit` v1.30.5, not present in the real toolkit repository) that discovers a local llmctl decision gateway on port 8095, and a constitution snapshot (tag `helixconstitution-v70`, a *reduced* tree that lacks ~286 gate scripts present in our pinned constitution) whose anchors §11.4.277–§11.4.284 require llmctl to report decision capacity, keep decision models out of chat configurations, and be installable as a dependency.
- The research conversation `Jev.md` (3,715 lines) is search-augmented AI output. Many figures, package names and repositories in it are unverified, internally contradictory, or look invented.

**Governing principle.** The second team's work is *input to be verified and merged*, not an authority. Every claim carried into the product (hash, size, license, accuracy figure, behaviour) must be re-established against the real artifact or be labelled with its true provenance. A complete register of everything found in the source material, with its disposition, is in [`source-findings.md`](source-findings.md).

## Clarifications

### Session 2026-10-07

- Q: When started with no further configuration, should a decision endpoint listen only on this machine or on the whole network like the chat servers? → A: Whole network by default (Option B), with a key that is auto-generated at first start and required for every request. The key is named `LLMCTL_API_KEY` and MUST be documented/persisted either in llmctl's `.env` file or as an exported variable in the operator's main shell startup file (`.bashrc` / `.zshrc`). The whole mechanism MUST be fully documented in the docs and manuals and covered by deterministic, verifiable tests.
- Q: Should `LLMCTL_API_KEY` protect only the decision endpoints, or also the existing chat model servers? → A: Decision endpoints only (Option A). Chat servers keep their current behaviour and the documentation states plainly that they are not covered by the key.
- Q: Must this release add further Jev-like models to the shipped catalog, or only evaluate them? → A: Evaluate every named model against the same admission gate and add each one that fully passes (Option A); record the rest as rejected with the reason. Note from the operator: all endpoints, APIs and models MUST be fully available inside the local network or from the cloud once they are run.
- Q: For reaching llmctl endpoints from the cloud, how should the connection be protected in transit? → A: Option A with a self-signed certificate: llmctl's decision endpoints serve HTTPS themselves, using a self-signed certificate that is created automatically in a certificate directory under the home directory of the user llmctl runs as (proposed location: `llmctl/cert` inside that home directory). Everything MUST be documented to the smallest detail for end users, and every single API call MUST be tested over HTTPS from various clients.
- Q: Should decision endpoints answer only over HTTPS, or also keep a plain-HTTP listener for programs on the same machine? → A: HTTPS only (Option A), on every address including loopback; no plain-HTTP listener exists for any user-facing decision endpoint. Same-machine tools must use `https://` and trust the generated certificate.

### Amendments made during planning (2026-10-07) — review and revert any you disagree with

Planning research (see `research/`) established facts that required these edits to keep the specification true and consistent. None changes an operator decision above; each refines how it is realised.
- **Topology (resolves a conflict between FR-018 and FR-073):** the gateway is the only network-facing decision endpoint; all engines and runtimes behind it, including the encoder runtime, are internal, loopback-only and use a per-start internal key. FR-018, FR-019, FR-066, FR-073 reworded.
- **Certificate realisation:** "self-signed" is realised as a locally generated certificate authority plus the server certificate it signs, because a single self-signed certificate must be re-trusted by every client on every address change (verified experimentally). FR-066 reworded; a single self-signed certificate remains a documented fallback mode.
- **Verified vendor facts replace unverified conversation claims:** choice up to 255 options and scale 2–10 levels (the conversation said 100 and 8); yes/no has no confidence field. New FR-075.
- **Determinism is scoped:** byte-identical repeats are only achievable in a deterministic mode (batch size changes the logits); SC-001 reworded, new FR-074.
- **SC-003 tightened:** accuracy reported with interval and baseline from the same tool; no calibration figure from small samples.
- **New requirements FR-074 to FR-086** capture research-backed production needs: contract fidelity, readout guards, encoder correctness and locked dependencies, backpressure and drain, observability, calibration tooling, client ergonomics, engine HTTPS verification, unit hardening, release/supply-chain, a gated engine advance, and an agent integration kit.
- **Dynamic ports and discovery (operator, 2026-10-07):** "Make sure we have dynamic ports assignment capability with full and proper services discovery mechanism between each other! Use our containers Submodule" → FR-088..FR-091, SC-015; the Containers submodule was added at `submodules/containers` (pinned 4a8f04e).
- **Language rule (operator, 2026-10-07):** "Main programming language for anything bigger stays Go lang. Main framework for Go APIs - Gin Gonic." The decision gateway, the `decide` client and the key/certificate handling are therefore Go with Gin, in one module and one binary; the Python implementations written in the first execution wave were prototypes superseded by it and are removed (task T025b, done: the Go versions passed the same vectors, `evidence/go-port-parity.json`; the retired Python gateway of the candidate is archived in `evidence/python-gateway-retired/`); the implementation is Go + Gin, binary `llmctl-decide`. Python remains only for the encoder runtime (`lib/onnx_server.py`).
- **Independent review round 1 (2026-10-07, report `research/plan-review-1.md`, NO-GO → fixes applied):** hosted-SDK wording (AS2) corrected; state over budget is rejected by default and shortening is opt-in (FR-012); status set reconciled (FR-075; >255 options is 400; readout failure is a non-retryable 422, FR-076); per-source connection cap and failed-auth throttle scoped so a valid key is never throttled (FR-022); probes plural (FR-019); chat-server cloud access only through an authenticated overlay (FR-065); matrix floors and agent subset fixed in advance (FR-069, SC-013, SC-007); SC-001/003/004 made measurable; memory-limit policy now follows the recorded 2026-09-15 operator decision instead of overriding it (FR-031, FR-083, US7 AS3 — this corrected a defect in the first planning draft, which had silently reversed that decision); hook templates fail closed by default (FR-086); the log hash key is separate from the access key (FR-079).


## User Scenarios & Testing *(mandatory)*

### User Story 1 - Run a decision model locally and get a typed answer (Priority: P1)

An operator on a normal host (Linux or macOS) wants to put a typed question to a local decision model, for example "Is this change risky?" with a piece of state, and receive a machine-readable answer with probabilities, without writing any glue code and without sending data off the host.

**Why this priority**: This is the core capability. Without it nothing else in the feature has value. It must work end to end with real model files, not stand-ins.

**Independent Test**: On a host with the default decision profile available, run one typed question of each of the three types from the command line and confirm each returns a well-formed typed answer whose probabilities sum correctly, in a measured time, with the answering model and port recorded in the output. Repeat the identical question and confirm the answer is identical (determinism).

**Acceptance Scenarios**:

1. **Given** a host where a decision profile has been downloaded and verified, **When** the operator asks a yes/no question, **Then** a probability between 0 and 1 is returned and the model that answered is identified.
2. **Given** the same host, **When** the operator asks a pick-one-of-N question with N options, **Then** the answer names exactly one option, gives a probability for every option summing to 1 within tolerance, and gives a confidence in [0, 1].
3. **Given** a scale question with 2–10 ordered levels, **When** it is asked, **Then** a probability-weighted score within the scale bounds is returned together with the per-level probabilities.
4. **Given** a host that cannot fit the requested profile in the remaining memory budget, **When** the operator asks, **Then** the request is refused with the exact numbers (needed versus available), never silently degraded, and the host is left unharmed.
5. **Given** the operator asks without naming a profile, **When** the choice is automatic, **Then** the best profile that fits the host is selected and the selection reason is shown.
6. **Given** a download of a decision model, **When** the file's size or checksum differs from the pinned value, **Then** the download is rejected and nothing unverified is used.

---

### User Story 2 - Expose the decision endpoint to this host or the local network, safely (Priority: P1)

An operator wants other programs and other machines to call the decision layer the same way they already call llmctl's chat models: a stable address, a standard request/response shape compatible with the hosted Jev wire format, health reporting, and the choice of loopback-only or LAN exposure.

**Why this priority**: The stated goal is to "bring them up locally and expose to local host or local network like we already do". Exposure is also the biggest risk, because the repository's engines bind to all interfaces by default.

**Independent Test**: Start the endpoint, call it from the same host and from a second host on the network, and confirm identical typed answers. Then start it on a fresh installation with no configuration and confirm a key was generated and persisted, the endpoint is reachable from the network, and callers without the key are rejected. Confirm wrongly-authenticated callers are rejected and that a restart reuses the same key. Repeat every call over HTTPS from several different client programs, on this host and from a second network location.

**Acceptance Scenarios**:

1. **Given** the endpoint is running, **When** a client sends the hosted-Jev-shaped request (state plus a named set of typed questions), **Then** it receives answers keyed by the same question names, in the hosted shape, plus usage information.
2. **Given** a client built for the hosted Jev, **When** it is pointed at the local endpoint with the base address, the access key and trust for the generated certificate authority changed (the exact per-SDK steps come from the transport tests), **Then** it works for the three question types.
3. **Given** a fresh installation where `LLMCTL_API_KEY` is neither exported in the environment nor present in `.env`, **When** a decision endpoint is first started with default settings, **Then** a strong random key is generated and saved to `.env` with owner-only permissions, the endpoint listens on the network (not only on this machine), the start-up message states the bind address and where the key is stored (never the key itself), and every request needs the key.
4. **Given** the key is available, **When** a request arrives with a missing or wrong key, **Then** it is rejected with an authorization error, and the key never appears in process listings, logs, evidence files, or world-readable files.
5. **Given** the operator has exported `LLMCTL_API_KEY` in the main shell startup file, **When** the endpoint starts, **Then** that value is used and no new key is generated or written.
6. **Given** the operator prefers to keep the key on this machine only, **When** they override the bind address to loopback, **Then** the endpoint listens only locally and still requires the key.
7. **Given** the endpoint is running, **When** a health probe is made, **Then** health reflects whether the underlying model is actually ready, and exposes nothing about the model or host beyond what the operator allows.
8. **Given** a client sends a malformed, oversized, slow, or non-object request, **When** it reaches the endpoint, **Then** the endpoint answers with a clear error (or closes the slow connection within a bounded time) and keeps serving other clients.
9. **Given** the operator stops the endpoint, **When** a stale process record points at an unrelated process, **Then** that unrelated process is never signalled.
10. **Given** a fresh installation, **When** a decision endpoint is first started, **Then** a self-signed certificate and its private key are created in the certificate directory under the user's home (private key readable only by its owner), the endpoint answers over HTTPS, and a second start reuses the same certificate.
11. **Given** a client that has been told to trust the generated certificate, **When** it calls any endpoint path over HTTPS, **Then** the call succeeds; **and given** a client that has not been told to trust it, **Then** the client's verification fails with a clear message and no data is exchanged.
12. **Given** the operator supplies their own certificate and key in the certificate directory, **When** the endpoint starts, **Then** those are used and validated, and an invalid pair stops the start with an actionable message.

---

### User Story 3 - Trust the evidence: every claim verified against real models (Priority: P1)

A maintainer (and a release reviewer) must be able to rely on every statement in the catalog, the documentation and the test results. Today the second team's QA proves only that the code paths work against stand-in backends; no real model has been downloaded, hash-checked, loaded or queried, and no real accuracy has been measured by llmctl.

**Why this priority**: The project's rules treat an unverified "PASS" as a defect. The user explicitly demands real-model, machine-produced, deterministic evidence and no fabricated or inflated results.

**Independent Test**: For each shipped decision profile, download from the real source, compare size and checksum with the catalog pin, load it in the real runtime, ask a fixed golden question set, and store the machine-produced evidence. A profile that cannot be exercised on this host is recorded with the exact reason, not counted as passed.

**Acceptance Scenarios**:

1. **Given** each shipped decision profile, **When** it is downloaded from its real source, **Then** the recorded size and checksum match the catalog pin, or the pin is corrected from the real artifact and the discrepancy is recorded.
2. **Given** each profile that fits this host, **When** the golden question set is run, **Then** typed answers are produced by the real model and the measured accuracy, sample size and method are recorded; vendor-claimed numbers are never presented as llmctl-measured.
3. **Given** the encoder-class profile, **When** its real runtime is used, **Then** the label order and inputs are validated against the real model files, not assumed.
4. **Given** a profile that cannot run here (insufficient memory, runtime unavailable), **When** the evidence report is produced, **Then** it states "not exercised" with the reason, and no summary line claims it passed.
5. **Given** the same test run twice from a clean state, **When** results are compared, **Then** they are identical apart from timing.
6. **Given** a deliberately broken artifact (corrupted file, wrong label order, backend without log-probability support), **When** the verification runs, **Then** it fails loudly — proving the checks can fail.

---

### User Story 4 - Use the decision layer from every supported coding agent (Priority: P2)

A developer using any of the seven supported coding agents (opencode, pi, crush, Claude Code, aider, continue, Cline) wants that agent to be able to put typed questions to the local decision endpoint, and wants documented, tested instructions for each.

**Why this priority**: The user requires live proof "from all supported CLI agents". It depends on Stories 1–3 and delivers integration value rather than core capability.

**Independent Test**: For each agent, install it if absent by its official mechanism, configure it from the documentation, instruct it to make a decision call, and confirm from the endpoint's own request record (not from the agent's say-so) that the call arrived and what was answered.

**Acceptance Scenarios**:

1. **Given** a supported agent installed on the host, **When** it is configured per the documentation and asked to make a decision call, **Then** the endpoint's independent request record shows a matching request and the agent received the answer.
2. **Given** an agent that cannot be installed or driven non-interactively on this host, **When** the live test is attempted, **Then** the result is recorded as "not exercised" with the reason and the documentation states the limitation honestly.
3. **Given** the decision endpoint, **When** any agent's chat-model configuration is generated or inspected, **Then** decision models never appear as chat models.

---

### User Story 5 - Plan, discover and use decision capacity (Priority: P2)

An operator (and the surrounding tooling) wants to know, before starting anything, how many decision instances this host could run, and wants discovery tooling to find running decision endpoints without side effects.

**Why this priority**: Cluster-wide governance rules require capacity to be computed from the machine-readable plan, and require decision work to use all available instances. It builds on Story 1.

**Independent Test**: Request the machine-readable plan and confirm it lists, per decision profile, how many instances fit on the GPU and on the CPU and the resulting number of concurrent decision slots; confirm the figures match what the scheduler actually admits.

**Acceptance Scenarios**:

1. **Given** any host, **When** the machine-readable plan is requested, **Then** a decision-capacity section is present, parseable, and consistent with admission control.
2. **Given** no decision profile is running or downloaded, **When** discovery is run, **Then** it reports an explicit, reasoned "none available" rather than an empty or fabricated result.
3. **Given** more than one decision instance can fit, **When** the operator asks to run several instances of one profile, **Then** each gets its own address, all are admitted within the memory budget, and callers can spread work across them.
4. **Given** the planner's recommendation set, **When** it is compared with the previous release, **Then** every change to recommended/automatic selections caused by the new profiles is intentional, documented and tested.

---

### User Story 6 - Admit more Jev-like models through a safe, repeatable gate (Priority: P2)

A maintainer wants the process for adding further Jev-like models (the research names Kev, Verdict, Laya, local-jev's models, a Strands decider and others) to be explicit: a candidate is added only after its license, source, size/checksum, format, runtime compatibility and real behaviour are verified; otherwise it is recorded as rejected with the reason.

**Why this priority**: The user asked for "Jev model and other Jev-like models" and "no skipping or ignoring". Evaluating every named candidate honestly satisfies this without shipping unverified models.

**Independent Test**: Take one named candidate and walk it through the gate; confirm the outcome (admitted or rejected) and its evidence are recorded in a candidate register. Take one deliberately non-compliant candidate (non-commercial license, or no checksum obtainable) and confirm it is rejected.

**Acceptance Scenarios**:

1. **Given** every Jev-like model named anywhere in the source material, **When** the register is reviewed, **Then** each has a recorded outcome (shipped, user-installable, or rejected) with its reason.
2. **Given** a model whose weights forbid commercial use, **When** it is evaluated, **Then** it is not shipped by default and the licence reason is recorded (the second team already excluded one such model).
3. **Given** a model with no prebuilt artifact in a supported format, **When** it is evaluated, **Then** the supported "bring your own export" path is documented and tested with a real example, or the model is rejected with the reason.
4. **Given** an operator-supplied custom catalog, **When** a custom decision profile is added, **Then** the same size/checksum/format checks and the same safety rules apply to it.

---

### User Story 7 - Operate decision models like any other service (Priority: P2)

An operator wants decision profiles to be managed with the existing lifecycle: start, stop, restart at boot, status, logs, doctor diagnostics, memory limits — on Linux (systemd user services) and macOS (launch agents) — with the new runtime's missing prerequisites reported clearly before they cause crash loops.

**Why this priority**: A decision model that cannot survive reboots or that crash-loops when a prerequisite is missing is not production quality.

**Independent Test**: Enable a decision profile as a service, reboot or simulate restart, confirm it returns; remove a prerequisite and confirm the system reports the cause instead of looping silently.

**Acceptance Scenarios**:

1. **Given** a decision profile enabled as a service, **When** the host restarts, **Then** it comes back and the status view is accurate.
2. **Given** a required runtime package is missing, **When** the operator downloads, enables or starts the profile, **Then** the problem is reported before or at the first start, and a "verified" claim is not made for something that was only skipped.
3. **Given** a service unit, **When** its memory limits are inspected, **Then** they follow the project's recorded memory-limit policy consistently with the other units (currently the 2026-09-15 operator decision, see FR-083), and the measured peak memory is recorded.
4. **Given** macOS, **When** the same flow is run, **Then** it is either verified on macOS or explicitly documented as not verified there.

---

### User Story 8 - Release a new version with everything in sync (Priority: P1)

A maintainer wants a new version published on both GitHub and GitLab, with artifacts, a changelog, and documentation (README, manuals, guides, FAQs, architecture, API reference, per-script docs, diagrams) that all describe exactly what shipped, with test counts and numbers that match measurement.

**Why this priority**: It is the final, explicit deliverable and the point at which all prior work is checked together.

**Independent Test**: After release, download the published artifacts from each forge, verify their checksums, run the release's own test entry point from the extracted copy, and run an automated documentation audit that fails on any stale count, wrong port, missing page link, or code/doc mismatch.

**Acceptance Scenarios**:

1. **Given** all other stories are done and the full suite is green, **When** the release is cut, **Then** the same version tag, notes and artifacts exist on both forges and match each other.
2. **Given** the documentation audit, **When** it runs on the release candidate, **Then** it reports zero mismatches (test counts, ports, profile lists, command lists, links).
3. **Given** the changelog, **When** it is read, **Then** it lists the user-visible additions, behaviour changes (including changed planner recommendations), security fixes, and honest known limitations of this version.
4. **Given** any earlier step failed, **When** a release is attempted, **Then** it is blocked; no history is rewritten and nothing is force-pushed to make it pass.

---

### User Story 9 - Consume a stable contract from the wider tooling (Priority: P3)

The toolkit and constitution tooling that discover decision endpoints need a stable, documented contract from llmctl: the machine-readable capacity report, the gateway address and wire shape, the rule that decision models are never chat models, and a defined way to install and update llmctl as a dependency.

**Why this priority**: It keeps the surrounding system working but is not required for llmctl to be useful on its own.

**Independent Test**: Run the toolkit snapshot's discovery against the local endpoint (as an external consumer, unmodified) and confirm it finds, classifies and records the endpoint as a decision endpoint with no chat alias created.

**Acceptance Scenarios**:

1. **Given** the endpoint is running over HTTPS, **When** the external discovery tool probes it with the generated certificate trusted and the key supplied through its environment, **Then** it recognises it, records its models, and creates no chat alias; **and given** the tool as shipped in the snapshot (which expects plain HTTP at `http://127.0.0.1:8095`), **Then** the incompatibility is recorded as a documented contract change for the toolkit's maintainers, not hidden or worked around by weakening llmctl.
2. **Given** the contract documentation, **When** llmctl's actual outputs are compared with it by an automated check, **Then** they agree field for field.

---

### Edge Cases

- A state text longer than the model can read: it is rejected by default (as the hosted service does); shortening the state is an explicit opt-in and is reported in a response header and the request log; the question and options are never shortened (the candidate encoder path cut them off), and hosted SDKs do not surface custom headers, which is why rejection is the default.
- Questions with the maximum number of options on a slow, one-pass-per-option encoder: the request must stay within the stated timeout or fail with a clear message, never hang or overload the host.
- Backend lacks the probability readout a profile depends on: the decision fails explicitly rather than returning invented numbers.
- All log-probability readouts fall outside the option letters (the model "talks" instead of choosing): an explicit error, not a default answer.
- Model files are present but corrupted, partially downloaded, or replaced after verification: detected by the next verification; never served silently.
- The disk is nearly full (this host has ~93 GB free at 95% usage and the six profiles total ~20 GB): downloads check space first and fail cleanly; a failed download leaves no partial files that look complete.
- Another model (for example the vision server already running here) already occupies GPU memory: admission control accounts for it and refuses with numbers instead of crashing it.
- Two operators or scripts start the same profile concurrently: exactly one wins; no duplicate processes or ports.
- A port from the catalog is already taken by an unrelated process: clear error naming the port and the override variable.
- The endpoint is asked to authenticate against a backend that has its own credential (gateway in front of the encoder runtime): the credential flow must work end to end in the tested combinations.
- Test-only switches (fake backend host, fake model outputs) set in a production environment: must be impossible to trigger silently, or loudly warned, and must never let a download be "verified" without opening the model.
- Option order bias: reordering options may change an answer; this is a model property to measure and document, not to hide.
- A client sends prompt-injection text in the state: the system must keep the question/options under its own control (state is data) and document the residual risk honestly.
- The host has no network access to the model host during a test: the failure is reported as environment-blocked, not as a product defect, and not as a pass.
- The operator's catalog overlay defines a decision profile with a wrong or missing capability: it is rejected by validation with a precise message.
- A decision profile is selected by a chat client (for example via `auto` with the chat capability): decision profiles must never be chosen for chat.
- The key exists both in the environment and in `.env` with different values: the environment wins, and diagnostics tell the operator that `.env` is shadowed.
- `.env` cannot be written (read-only location, full disk, no permission): the first start fails with an actionable message and no endpoint is left running without a persisted key.
- Two profiles or the gateway and runtime start at the same time on a fresh installation: exactly one key is generated and all components use it.
- The key is lost: the documented recovery is an explicit rotation, after which all clients must be updated.
- The operator copies the repository or the `.env` file to another machine or into a backup: documentation explains the key travels with `.env`, and that `.env` must stay out of version control and shared archives (the release archive builder must exclude it).
- An existing client or tool expects plain HTTP at a decision address: it fails with a clear transport error, never a silent downgrade; the documentation lists the exact change needed.
- The host's network address changes (for example a new address from DHCP) or its name changes: the certificate no longer covers it; diagnostics must say so and renewal must fix it without losing the key or breaking clients that pinned by name.
- The system clock is wrong: certificates appear expired or not yet valid; the failure message must mention the clock.
- The home directory (or the certificate directory) cannot be written, is on a read-only filesystem, or the service runs with a different home: the start fails with an actionable message and nothing is left running over plain HTTP as a fallback.
- Several users on one host each run llmctl: each has their own certificate directory and key; documentation explains that clients must trust the right one, and that the users cannot share the gateway port or the catalog ports (per-user port overrides are documented).
- A client built for the hosted service insists on a public certificate authority: the documented trust step for that client must work, or the limitation is stated.
- Windows or other unsupported platforms: unsupported and documented as such.

## Requirements *(mandatory)*

### Functional Requirements

**Model support and catalog**

- **FR-001**: The system MUST provide local decision-model profiles that answer the three typed question types (yes/no, pick-one-of-N, rate-on-a-scale) through both a command-line interface and a network endpoint.
- **FR-002**: The shipped catalog MUST contain only decision models whose licence permits the intended use; models with non-commercial weights MUST NOT ship by default, and each shipped model's licence MUST be recorded.
- **FR-003**: Every shipped decision model file MUST be pinned by exact upstream revision, byte size and checksum, and every pin MUST be confirmed against the real artifact before release; discrepancies MUST be recorded and corrected, never papered over.
- **FR-004**: Small configuration files that cannot be pinned by checksum MUST be verified by a defined integrity mechanism whose trust assumption is documented, and any file that influences answers (for example label ordering) MUST be integrity-protected or validated.
- **FR-005**: The catalog schema extensions (new engine kind, decision capability, below-minimum tier, tokenizer/config file roles, new ports) MUST be validated by the catalog test suite, and unknown or malformed values MUST be rejected with precise messages.
- **FR-006**: Decision profiles MUST NOT be selectable for chat, MUST NOT appear in any generated chat-model configuration, and the automatic chat selector MUST never choose one.
- **FR-007**: Every Jev-like model named in the source material MUST receive a recorded outcome (shipped, user-installable, or rejected) with its reason, in a candidate register kept with the feature. Each candidate that fully passes the admission gate (permitted licence, verifiable source and checksum, supported format and runtime, and a real run on this host that meets the same evidence bar as the six candidate profiles) MUST be added to the shipped catalog in this release; no candidate may be added that has not passed every check, and the release scope therefore follows the evidence.
- **FR-008**: The system MUST support a documented, tested "bring your own export" path for decision models that lack a prebuilt artifact, using a user-supplied catalog overlay.

**Running decisions**

- **FR-009**: The system MUST render each question deterministically from a single authoritative template so the one-shot command and the network endpoint can never disagree.
- **FR-010**: Given identical input, model and settings, the system MUST produce identical typed answers in deterministic mode (FR-074; fixed seed where a sampler is involved).
- **FR-011**: Answers MUST be probability-shaped and bounded: probabilities in [0, 1] summing to 1 within tolerance for choice and scale questions; confidence in [0, 1]; scale scores within the declared bounds.
- **FR-012**: The system MUST enforce documented limits on number of options, scale levels, state length and request size. A state longer than the profile's budget MUST be rejected with a validation error by default, as the hosted service does; shortening the state (head and tail kept) is an explicit opt-in setting, and when used it MUST be reported in a response header and in the request log. Question and option text MUST never be shortened under any setting, and an encoder model MUST never shorten anything but the state.
- **FR-013**: Failure of the underlying model (missing readout, unusable output, timeout, wrong number of outputs) MUST produce a typed error to the caller and MUST NOT crash the serving process or return fabricated probabilities.
- **FR-014**: The reported evidence for each answer (answering profile, port, latency) MUST use real, unquantised measurements.
- **FR-015**: Confidence MUST be documented as a shaping convention, not a calibrated probability of correctness, and any calibration control MUST be documented with its limits.
- **FR-016**: Per-request resource use MUST be bounded: requests whose cost (for example one model pass per option) would exceed a configured budget MUST be refused or rate-limited with a clear message.

**Network exposure and security**

- **FR-017**: The endpoint MUST accept the hosted-Jev-shaped request and return the hosted-shaped answer for the three question types, plus a model list and a health probe.
- **FR-018**: The decision gateway, the single network-facing decision endpoint, MUST listen on the network by default, like the chat servers, with the existing bind-address overrides (global and per profile) available to restrict it to this machine; in every bind configuration it MUST refuse to start unless an access key is available (resolved or generated per FR-058), and its start-up message MUST state the bind address, the HTTPS address and the key's storage location, never the key.
- **FR-019**: Every request to a decision endpoint except the minimal liveness and readiness probes MUST be authenticated with the access key; the check MUST NOT reveal key information through response timing; authentication MUST work consistently for every client of the gateway (llmctl's own command-line client, external clients and agents) because they all resolve the same `LLMCTL_API_KEY`; the internal hops from the gateway to the engines and runtimes behind it use a separate random per-start internal key that is never shown to operators.
- **FR-020**: The access key MUST NOT appear in process arguments, process listings, logs, evidence files or documentation (documentation uses placeholders only), and any file holding it MUST have owner-only permissions.
- **FR-021**: The health probe and error bodies MUST NOT leak internal exception text, file paths or host details to unauthenticated callers.
- **FR-022**: The server MUST bound concurrent connections both globally and per source address (shedding before the TLS handshake when slots are exhausted) and per-connection time, MUST throttle repeated failed authentications from a source without ever throttling a request that carries the valid key, and MUST survive malformed, hostile or slow clients without affecting others.
- **FR-023**: Stopping the endpoint MUST verify the identity of the process (command line) before signalling it, MUST NOT signal an unrelated process from a stale record, and MUST be safe against start/stop races.
- **FR-024**: Test-only switches MUST be inert in normal operation, MUST be visibly reported when active, and MUST NOT be able to cause a model to be recorded as verified without being opened.
- **FR-025**: Required extra runtime packages MUST be installable by a documented, version-pinned, integrity-checked procedure, and absence MUST be reported by diagnostics before use.
- **FR-026**: The repository's documentation and code MUST agree about the default bind address of every server (currently the documentation and the code disagree) and the documented default for decision endpoints MUST be the clarified one: network-wide with a mandatory access key. The project-level statement "all servers bind to 127.0.0.1 / local-only" MUST be corrected wherever it appears.
- **FR-057**: The decision layer MUST use exactly one credential variable, `LLMCTL_API_KEY`, for the endpoints and for every llmctl-provided client (an optional, expiring rotation-overlap value MAY be stored beside it in the same file, FR-058). The candidate's `LLMCTL_DECIDE_API_KEY` is retired (it was never released) and MUST NOT remain in code, tests or documentation. The key protects decision endpoints only: the existing chat servers MUST behave exactly as before (a regression test MUST prove an unchanged request to a chat server still succeeds without a key), and every document that mentions the key MUST state this scope, including the fact that the generic variable name does not imply chat-server protection.
- **FR-058**: The access key MUST be resolved in this order: (1) the value exported in the process environment (for example from the operator's main shell startup file `.bashrc` or `.zshrc`); (2) the value stored in llmctl's `.env` file (the one in the llmctl installation root, as `.env.example` documents; overridable with `LLMCTL_ENV_FILE`). A blank, whitespace-only or malformed value MUST be an explicit error, never treated as "no key". If neither source provides a key, the first start MUST generate a cryptographically strong random key (at least 256 bits, in a documented text-safe format), persist it to `.env`, and reuse it on every later start; a key MUST never be regenerated or overwritten silently, and rotation MUST be an explicit operator action.
- **FR-059**: `.env` MUST be gitignored, created or updated with owner-only permissions, and a pre-existing `.env` with looser permissions MUST be tightened or refused with an actionable message. llmctl MUST NOT modify shell startup files on its own; an explicit operator command MAY add the export line to the file the operator names, showing exactly what it will write, writing it at most once (idempotent), and warning that such files are often readable by other users.
- **FR-060**: The operator MUST be able to learn where the key is stored and to display it only through a deliberate command; normal output, logs, status views and evidence MUST NOT print it. Diagnostics MUST report whether a key is available and whether its storage permissions are safe, without revealing it.
- **FR-061**: Every llmctl-provided client (the decision command, smoke checks, health checks that need the key) MUST resolve the key by the same order so that a same-machine setup works out of the box; callers on other machines MUST be told, in the documentation, how to supply the key in their own environment.
- **FR-062**: The key mechanism MUST be fully documented in the README, user manual, quickstart/tutorial, FAQ (lost key, rotation, "401/unauthorized" troubleshooting), the integrations page for each of the seven agents, the security notes, the architecture and API reference pages, the decision-model and gateway pages, and `.env.example` (placeholder only, never a real value).
- **FR-063**: The key lifecycle MUST be covered by deterministic tests that assert properties rather than random values: generation length/format/entropy bound, uniqueness across fresh installs, persistence, idempotent reuse across restarts, environment-over-`.env` precedence, owner-only permissions and tightening of loose permissions, blank/malformed rejection, explicit rotation, idempotent startup-file helper, and a repository-wide scan proving no key value leaks into arguments, logs, evidence or documentation. No production randomness override is allowed; tests may supply a key through the environment.
- **FR-064**: Once a decision endpoint (the network-facing surface of any decision model, per FR-073) or an existing chat server is running, it MUST be reachable from other machines on the local network at its documented address and port, not only from the host that runs it, and this MUST be verified from a second network location (another machine, or an isolated network namespace with its own address when no second machine is available, with the choice recorded in the evidence). A start-up or diagnostic check MUST report when a running endpoint is bound only to this machine, or is blocked by the host firewall, so that "running" is never mistaken for "reachable".
- **FR-065**: Reachability from the cloud (from outside the local network) MUST be a documented capability with the exact steps an operator takes (firewall rules, router or tunnel setup, name resolution) and the risks of each. For the key-protected HTTPS gateway the documented methods include port forwarding, a private overlay network and tunnels (FR-066 to FR-072 protect the connection). The existing chat servers have no key and no transport protection by default, so their cloud access is documented only through an authenticated private overlay, and the documentation MUST say plainly that publishing them directly to the internet is unsafe. Cloud reachability is tested from an external vantage when the operator provides one (OD-12); without one the documentation is the deliverable and the evidence records "not exercised: no external vantage". llmctl cannot control routers or third-party networks, so verification states explicitly what could not be proven.
- **FR-066**: The decision gateway MUST serve HTTPS using a self-signed certificate, realised as a locally generated certificate authority that signs the server certificate (so clients trust the authority once and the server certificate can be reissued when the host's addresses change without re-trusting), created automatically the first time it is needed and stored in a certificate directory under the home directory of the user llmctl runs as (default location `llmctl/cert` inside that home directory, overridable and documented). The private key MUST be readable only by its owner; the certificate MUST be reused on every later start and never regenerated silently; it MUST be valid for the names and addresses the host answers to (host name, loopback, its network addresses, plus operator-listed extra names); its validity period MUST be documented, and diagnostics MUST warn before it expires or when the host's addresses no longer match it. Renewal MUST be an explicit operator action. No user-facing decision endpoint, including the health probe, MAY answer over plain HTTP on any address (loopback included), and llmctl's own components that call the gateway (the command-line client, smoke checks) MUST use HTTPS and verify the certificate. The hops from the gateway to the internal engines and runtimes are loopback-only (FR-073). The certificate authority MUST be restricted by name constraints to the host's own names, `localhost`, loopback and private-network address ranges plus the operator-listed extra names, so that a leaked authority key cannot impersonate arbitrary domains; the documentation recommends per-client trust bundles first, operating-system-wide trust only with the constraints on, and an offline-authority-key mode; a name outside the constraints requires a bring-your-own certificate (FR-067) or a deliberate authority re-creation that the documentation explains.
- **FR-067**: An operator MUST be able to replace the generated certificate with their own certificate and key placed in the same directory; the pair MUST be validated at start (matching, unexpired, readable) and an invalid pair MUST stop the start with an actionable message.
- **FR-068**: The public part of the certificate and its fingerprint MUST be obtainable through a deliberate command so that clients can trust or pin it, and the documentation MUST give exact, per-client trust steps (curl, a Python client, a Node.js client, a Go client, browsers, each of the seven agents, and clients built for the hosted Jev). Turning certificate verification off is allowed only as a clearly warned last resort in the documentation and MUST NOT be a default of any llmctl-provided client or example.
- **FR-069**: Every API call of every decision endpoint (each path and method; success and every error class; authenticated and unauthenticated) MUST be tested over HTTPS from several different client implementations — at minimum curl, a Python client, a Node.js client, a Go client, a browser-driven client, llmctl's own command-line client, and each of the seven agents where it can make HTTP calls — both from this host and from the second network location of FR-064. An automated inventory of the endpoints' paths and methods MUST prove that no call is left untested, and the matrix result (client by call) MUST be stored as evidence. Floors: every programmatic client (curl, Python, Node, Go, llmctl's own client) MUST pass every applicable case from both vantages; "not exercised" (with the reason) is allowed only for named classes fixed in the inventory in advance: the browser client on non-GET cases, the seven agents outside their defined subset (one authenticated success call and one unauthenticated call each), the hosted SDKs where no CA-trust mechanism works (recorded as a trust-configuration failure, never hidden), the hosted SDKs for calls outside the model-list/answer subset they implement (`sdk-outside-subset`), and transport-level cases that are not per-client behaviours, such as the slow-client, per-source-cap and engine-port-refusal cases (`transport-not-per-client`, exercised once by the transport suite instead).
- **FR-070**: Negative transport tests MUST exist and pass: host name not covered by the certificate, expired certificate, untrusted certificate, a certificate or key that was altered, plain HTTP sent to the HTTPS port, and a client offering only outdated protocol versions or weak ciphers; the minimum accepted protocol version MUST be documented.
- **FR-071**: End-user documentation MUST describe the whole HTTPS feature to the smallest detail, assuming no prior knowledge: what the certificate is and why it is self-signed, where each file lives, how it is created, how to inspect it, how to trust it from each client, how to use your own certificate, how to renew, what each common error message means and the fix (certificate verify failed, host name mismatch, expired, connection refused, unauthorized), with a glossary, an FAQ and copy-paste examples that are themselves tested.
- **FR-072**: Whether the pinned inference engines behind the existing chat servers can serve HTTPS with this same certificate MUST be determined by a real test of the built engine, and recorded. If supported, enabling it MUST be an opt-in setting (default behaviour unchanged, per Clarification 2) and covered by the same client matrix; if not supported, the documentation MUST state that plainly and MUST NOT imply chat servers are encrypted.
- **FR-073**: The engine servers and runtimes that sit behind a decision profile (the inference server started for a generative decision profile, and the encoder runtime, which speak plain HTTP) are internal implementation details that authenticate callers with the internal per-start key: they MUST accept connections only from this host, MUST NOT be reachable from the network at any address even though chat servers are, and MUST NOT be documented or offered as user-facing endpoints. The only network-facing surface of a decision model is the HTTPS, key-protected decision endpoint. A test MUST prove that, with a decision profile running, its internal engine port is not reachable from the second network location while the HTTPS endpoint is.
- **FR-074**: Decision profiles MUST run in a documented deterministic mode by default (a single processing slot, no prompt caching, no request coalescing, probabilities rounded to a documented precision); byte-identical repeats are guaranteed only in that mode, and any throughput mode (batching, caching) MUST be opt-in and be marked in the response evidence.
- **FR-075**: The gateway MUST reproduce the hosted request and response shapes and limits exactly as established from the vendor's documentation: choice questions with up to 255 options where the profile supports them (each profile's lower documented cap is published per model in the model list; more than 255 options is a 400, as the hosted service answers), scale questions with 2 to 10 levels, yes/no answers carrying only the probability (no confidence field), a usage block, and error responses with the hosted statuses 400, 401, 422, 429 and 529 where the hosted service defines them, plus the llmctl-defined 404, 405, 413, 502 and 503 listed in the OpenAPI contract, with a body `{message, error_type}`; it MUST accept the state as text, an object or an array; it MUST map the hosted model names (`jev-latest`, `jev-1.13.0`, `jev-preview`) and the local profile names to the served profile, return the real local model identifier in every answer, answer an unknown model name with a typed error, answer a known profile that has no ready instance with 503 (never starting one on demand), and never claim to be the hosted model. Every request MUST receive a correlation identifier in a response header.
- **FR-076**: The decoder-profile readout MUST be guarded against silently invented confidence: probability mass over all spellings of an option letter is summed; if the combined mass over the option letters is below a configured threshold the request fails with a typed, non-retryable validation error (`readout_failed`, so retrying clients do not multiply the cost) instead of returning a renormalised guess; an option letter missing from the readout is reported as an upper bound and flagged, never as zero; and the readout protocol (first-token behaviour, spelling and tokenisation) MUST be checked per profile with the real model before the profile is admitted.
- **FR-077**: The encoder runtime MUST truncate only the state (never the question or option text), feed the model exactly the inputs its graph declares, validate its tokenizer against the reference tokenizer on a fixed corpus, take its label order from a checksum-pinned configuration, and run inside a dedicated virtual environment whose requirements are version- and hash-locked and installed from binary distributions only (FR-025); a host whose interpreter or operating system is too old for the locked wheels MUST be told so before use.
- **FR-078**: The gateway MUST bound concurrency and queue length, answer saturation with a retryable status (529 for saturation, 503 when not ready or draining, 429 for throttling) and a retry hint within the hosted client's default timeout, and drain gracefully on stop (readiness flips first, in-flight requests complete within a documented grace period).
- **FR-079**: The gateway MUST expose a liveness probe and a separate readiness probe, a key-protected metrics endpoint in the standard text exposition format with bounded label sets (never state text, question names, request identifiers or key material), and a structured request log containing a keyed hash of the state rather than the state, keyed with a per-installation log key that is separate from the access key (so rotating the access key does not break correlation).
- **FR-080**: llmctl MUST ship calibration and quality tooling: calibration metrics (expected and maximum calibration error, Brier score) over operator-labelled data, a one-parameter temperature fit, a calibration profile bound to the model checksum and prompt-template hash and refused when either differs, an option-order sensitivity probe that reports the answer-flip rate, optional abstention below a minimum confidence, and an opt-in decision log (with state text only by explicit consent) for external calibration.
- **FR-081**: The command-line client MUST support reading the state from standard input, a question file matching the Typed Question entity, newline-delimited batch input and output, an explanation view (rendered prompt and per-option probabilities), a dry-run, shell completions, emitters of the question schema as tool definitions for coding agents, and a documented exit-code contract; no argument-length limit may fail large states.
- **FR-082**: After building the inference engine, llmctl MUST verify and record whether HTTPS support was actually compiled in (and refuse to claim HTTPS for engines where it was not), and diagnostics MUST report it.
- **FR-083**: Every deployed unit or agent definition for decision components MUST use only hardening directives that are verified to take effect on the host's service manager (and say so when sandboxing is not enforced), apply the project's recorded memory-limit policy consistently with the other units (currently the operator decision of 2026-09-15: no artificial ceiling below the machine's physical memory; changing that policy is an operator decision, OD-14), record the measured peak memory of every decision component in the evidence regardless of policy, and place restart-limit settings where the service manager honours them.
- **FR-084**: The release MUST include assets on both forges (archives, checksum file, software bill of materials listing every shipped model and locked package with licence and checksum, and a licence notice), a reproducible archive build, a test proving no key, certificate private key or `.env` can enter an archive, an honest statement of the supply-chain assurance level actually achieved (no higher claim than a maintainer machine can support), and the release tooling's gaps (no assets, implicit tag creation, no verification) fixed.
- **FR-085**: If the pinned inference engine is advanced to obtain native decision-model support, the advance MUST be a separate, gated step: all existing chat profiles and tests pass unchanged, the engine's build identifier is recorded in the documentation, and models that need the newer engine are admitted only after that gate passes and their real run succeeds; otherwise they are recorded as pending the engine advance.
- **FR-086**: An agent integration kit MUST be provided and tested: command-hook templates for the agents that support hooks (fail-closed by default for gates on dangerous actions; fail-open only by explicit choice, stated in the template), a minimal local tool server for agents that speak the tool protocol, and the tool-definition emitters of FR-081, all calling the HTTPS gateway with certificate verification on.

**Scheduling, capacity and operation**

- **FR-027**: Decision profiles MUST go through the existing admission control, memory budgeting and refusal-with-numbers behaviour, with footprints for the new runtime that are measured, not assumed.
- **FR-028**: The machine-readable plan MUST include a decision-capacity section (per profile: instances that fit on GPU and on CPU, per-instance footprint, concurrent decision slots), and its figures MUST equal what admission control actually permits.
- **FR-029**: The system MUST allow running more than one instance of a decision profile where capacity permits (the candidate can only report such capacity, because each profile has a single fixed address), each instance with its own address, admitted only within the memory budget, and MUST document and test how callers spread load across instances. Starting more instances than the capacity report allows MUST be refused with numbers.
- **FR-030**: Automatic selection for the decision capability MUST pick the best profile that fits and MUST explain the choice; the ranking and any resulting change to the recommended sets MUST be documented and covered by tests.
- **FR-031**: Decision profiles MUST be manageable as services (enable, disable, start, stop, restart, status, logs) on Linux and macOS, restart on failure with sane limits, and follow the project's recorded memory-limit policy (FR-083).
- **FR-032**: Diagnostics MUST report missing runtime prerequisites for decision profiles, and download or enable MUST NOT print a success/"verified" claim for steps that were skipped.
- **FR-033**: Smoke checks MUST clean up any process they start, even on interruption.
- **FR-034**: Installation, upgrade and uninstallation of llmctl (including the new runtime files and units) MUST keep working and be covered by the existing end-to-end install tests.

**Integration with agents and tooling**

- **FR-035**: Documentation and tested instructions MUST exist for calling the decision endpoint from each of the seven supported agents.
- **FR-036**: The external discovery contract (capacity report, gateway address and shape, "never a chat model" rule, dependency installation) MUST be documented and checked by an automated comparison against actual output.
- **FR-037**: A request log (without raw state text) MUST be available as independent evidence that an agent's call reached the endpoint.

**Evidence, testing and quality**

- **FR-038**: Every test type applicable to the feature MUST exist and be run: unit, integration, end-to-end, security, performance/benchmark, stress/chaos, and the repository's existing challenge-style checks; each non-applicable type MUST be listed with the reason.
- **FR-039**: Outside unit tests, tests MUST exercise real components; stand-in backends and fake model outputs MUST be confined to unit tests and clearly marked, and each stand-in-based result MUST be reported as such, never as proof of real behaviour.
- **FR-040**: Each defect listed in `source-findings.md` MUST be reproduced by a failing test on the unmodified candidate code first, then fixed, then shown passing by the same test; a test that has never been seen to fail does not count.
- **FR-041**: Each new check (verification, guard, gate) MUST be shown able to fail by a deliberate corrupted case.
- **FR-042**: Test evidence MUST be machine-produced, stored with the run, include the exact command, environment and result, and be reproducible; summaries MUST be derived from raw results, never typed by hand.
- **FR-043**: Documented test counts, port lists, profile lists and command lists MUST be generated or machine-checked against the code so they cannot drift.
- **FR-044**: Merging the candidate work MUST be a careful merge onto the current main branch (HEAD `a9ebefe`), preserving all changes made there after the candidate snapshot was taken; wholesale file replacement is forbidden. No regressions in the existing 38 test files are permitted.
- **FR-045**: Files in the source material that are generated (compiled caches, archives) or out-of-tree references MUST NOT be imported; out-of-tree documentation cited by tests MUST be replaced by in-repository references.

**Live validation on this host**

- **FR-046**: The release candidate MUST be installed and run for real on this host, and every supported decision profile that fits MUST be downloaded, verified, started, queried through the CLI and the endpoint, and stopped, with evidence stored.
- **FR-047**: Existing (chat) profiles MUST be regression-checked live to the extent the host can run them, and profiles the host cannot run MUST be listed as "not exercised, host cannot fit" with the numbers.
- **FR-048**: Each supported agent MUST be exercised live as in User Story 4, with results recorded per agent (passed / not exercised with reason), and no agent may be reported as passed on the strength of its own claim alone.
- **FR-049**: Live tests MUST respect host safety: memory and process ceilings, no interference with the already-running vision server, and no action that suspends, reboots or exhausts the host.

**Documentation and release**

- **FR-050**: All documentation affected by this feature MUST be updated and kept consistent: README, user manual, quickstart/tutorial, FAQ, architecture and diagrams, API reference, hardware tiers, integrations, per-script documents for every new script, decision-model and gateway pages, CLAUDE.md/AGENTS.md project statements, continuation notes, and the research and QA records.
- **FR-051**: Every new or changed document MUST carry a current revision header and be reachable from the main README.
- **FR-052**: Benchmark and accuracy numbers MUST be labelled by provenance (llmctl-measured, vendor-measured, independent, unverified), and unverified claims from the research conversation MUST NOT appear as facts.
- **FR-053**: The version MUST be incremented (a new minor version, since this adds user-visible capability), and the changelog MUST be generated from the history, extended with an honest highlights and known-limitations section.
- **FR-054**: The release MUST be published on both GitHub and GitLab using their command-line tools, with the same tag, notes and artifacts, followed by a download-and-verify check of the published artifacts.
- **FR-055**: All pushes MUST be fast-forward to every configured remote; force-pushing, history rewriting and bypassing verification hooks are forbidden. No automated pipelines are added to any repository.
- **FR-056**: The constitution's own verification harness and mutation check MUST pass before the release is considered valid.
- **FR-087**: Secret material (the access key file, the certificate authority and server private keys, the log key) MUST be unable to enter version control or a release artifact: creation inside a git work tree is refused unless version control ignores the path; the repository ignores `cert/`; the release archive builder includes only tracked files and submodule contents (never the raw working tree); and a test plants each kind of secret inside the repository and proves none reaches either archive.
- **FR-088**: llmctl MUST offer dynamic port assignment alongside the documented fixed ports. Strategy `fixed` (default, unchanged behaviour: each profile has its documented port and a taken port fails loudly naming the port and the override variable) and strategy `dynamic` (selected globally by `LLMCTL_PORT_STRATEGY=dynamic` or per profile by `LLMCTL_PORT_<PROFILE>=auto`): the port is taken from a configurable range (`LLMCTL_PORT_RANGE`), proven free by an actual bind test at assignment time, never handed to two services, released on stop, and reused for the same service on restart when still free. An explicit numeric `LLMCTL_PORT_<PROFILE>` always wins. The assigned port is recorded wherever llmctl records a service (plan output, unit or agent definition, registry, logs).
- **FR-089**: Every running llmctl service (chat profiles, decision instances, the gateway, the encoder runtime) MUST be published in ONE service registry: name, host, port, protocol, health path, labels (kind, profile, protocol, instance) and health status. A service is registered when it becomes ready and unregistered when it stops; an entry whose process is gone or whose health check fails past a grace period is marked unhealthy and then removed (liveness proven from the real process identity and a health probe, never from the entry's existence). The registry is safe for concurrent writers, survives crashes without corruption, is readable by every llmctl component and by operators (`llmctl discover [--json]`), and its rows MUST equal the set of live services (a registry row without a live service, or a live service without a row, is a defect the doctor reports).
- **FR-090**: Components MUST find each other through the registry, not through static port tables: the gateway resolves its backends (decision instances, encoder runtime) by name and labels and re-resolves when the registry changes (new instance, removed instance, moved port) without a restart; `GET /v1/models` and the capacity view reflect the live registry; clients can discover the gateway's address and the CA to trust from the same place; engines and runtimes stay loopback-only and their entries say so.
- **FR-091**: Port allocation, registry, health probing, endpoint resolution and any containerised workload (including the second network location used by the transport tests and any optional containerised runtime) MUST use the project's Containers submodule (`digital.vasic.containers`, vendored as a git submodule) rather than parallel implementations; a missing capability is added to that submodule upstream, not worked around locally. Containers run rootless. The submodule is pinned to an exact commit and recorded in the dependency manifest.


### Key Entities

- **Decision Profile**: A catalog entry for a decision model: identity, source repository and pinned revision, files with size and checksum, runtime kind, capability (decide), minimum host tier, default port, default context/parallelism, licence, provenance-labelled benchmark note.
- **Typed Question**: One of three kinds (yes/no, pick-one-of-N, scale), with instructions and criteria (options or levels) and a name that only keys the answer.
- **Typed Answer**: The probability-shaped result for a question, with the kind-specific fields, confidence where applicable, and evidence (profile, port, latency).
- **Decision Endpoint**: The network service exposing the hosted-compatible interface for one or more profiles: bind address, credential policy, limits, health.
- **Access Key**: The single secret named `LLMCTL_API_KEY` that authorises requests to decision endpoints: resolved from the environment first, then `.env`, generated once on first start if absent; owner-only storage; never printed except by a deliberate command.
- **Server Certificate**: The self-signed certificate and private key that let decision endpoints serve HTTPS, stored in the certificate directory under the user's home; has names/addresses it is valid for, a validity period, a fingerprint, an owner-only private key, and an explicit renewal action.
- **Decision Capacity Report**: The machine-readable per-profile statement of how many instances fit and how many concurrent decision slots result.
- **Candidate Model Record**: The register entry for a Jev-like model: identity, licence, format, checksum availability, runtime compatibility, verification outcome and admission decision with reason.
- **Evidence Record**: A machine-produced, reproducible record of a test or live run: command, environment, raw output, result, and the provenance class (real model / stand-in / not exercised).
- **Findings Register**: The list of defects, gaps and doc inconsistencies found in the source material, each with severity, reproduction, fix and verifying test.
- **Release Record**: The version, tag, notes, artifacts and published locations on each forge, with the post-publication verification result.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Starting from a host with the default decision profile present, a scripted run of the documented first-start steps (using only the documentation, model download excluded) obtains a first valid typed answer for each of the three question types in under 5 minutes, and, in deterministic mode (FR-074, one instance and one device placement), repeating a question yields a byte-identical answer in 100% of 20 repeats.
- **SC-002**: 100% of shipped decision-profile files have a size and checksum confirmed against the real upstream artifact (or the pin corrected and the correction recorded); 0 pins remain unconfirmed at release.
- **SC-003**: For every shipped decision profile that fits this host, 100% of a fixed golden question set (at least 30 questions across the three types) produces a well-formed typed answer from the real model, and the measured accuracy is published with its sample size, a confidence interval and the trivial baseline computed by the same tool, and, for each profile, the lower bound of the accuracy interval exceeds that baseline (a profile that does not clear it is not shipped, or ships labelled experimental with its measured numbers); the golden set includes imbalanced items and reports per-class accuracy against a majority baseline; no calibration figure (such as ECE) is claimed from fewer than 200 labelled items; profiles that do not fit are listed as "not exercised" with the reason.
- **SC-004**: 100% of the defects in the findings register and in the file-review defect list (`research/jev-llmctl-new-files.md`, rows N-xx) that are rated high or critical are fixed, each with a test that was first observed failing and then passing; 0 high or critical items remain open at release, and every medium or low item is either fixed or recorded as an accepted limitation with a reason. A finding that is a missing-evidence gap rather than a code defect (such as D-06) may be closed by demotion with captured evidence (T129), but any code defect that evidence exposes is a new high or critical item that this criterion binds in full (fixed with a failing-first test, tracked in the gap register).
- **SC-005**: 100% of requests to a decision endpoint without the correct access key are rejected on every bind configuration; 100% of first starts on a fresh installation end with a persisted owner-only key and an endpoint that needs it; and 0 key values are present in process listings, logs, evidence files, documentation or world-readable files across the whole test run (checked by an automated scan).
- **SC-006**: Under a defined hostile-traffic scenario (malformed, oversized and slow requests alongside normal requests), valid requests continue to be answered, and the service never exits or hangs.
- **SC-007**: Each of the seven supported agents has a recorded live result; for every agent reported as passed, the endpoint's independent request record contains the matching request; 0 agents are reported as passed on the agent's own claim alone; each agent's driving model, its provider and its credential source are recorded, and an agent that needs a paid or personal account is run only with the operator's consent (OD-13).
- **SC-008**: The complete test suite (all pre-existing test files plus the new ones, across every applicable test type) passes with 0 failures on this host, the pre-existing tests show 0 regressions relative to HEAD `a9ebefe`, and every documented test count equals the measured count.
- **SC-009**: The documentation audit reports 0 mismatches between documentation and code (profile list, ports, commands, environment variables, bind-address statements, test counts, links) and 0 documents unreachable from the README.
- **SC-010**: The capacity report's instance and slot figures equal the number of instances admission control actually accepts in a live check, for every decision profile that fits this host.
- **SC-011**: The new version is published on both GitHub and GitLab with identical tag, notes and artifact checksums, and a fresh download of each published artifact passes its own test entry point.
- **SC-012**: A planner comparison against the previous release shows every change in recommended or automatically selected profiles, each with a documented reason; 0 unexplained changes.
- **SC-013**: For every decision endpoint path and method, 100% of cells in the client-by-call matrix (at least six client implementations plus the seven agents' defined subset, each from this host and from the second network location) are passing over HTTPS or fall in the "not exercised" classes fixed in advance by FR-069, each with its reason; 0 paths are absent from the matrix; and all negative transport cases of FR-070 behave as documented.
- **SC-014**: The software bill of materials lists 100% of the shipped models and locked packages with licence and checksum; a test that plants a key, a private key and an `.env` file in the working tree finds 0 of them in either release archive; every published asset's checksum matches its entry in the checksum file after a fresh download from each forge; and the documented assurance level is exactly the one the evidence supports.
- **SC-015**: In a live check with three services started under the dynamic strategy while one default port is deliberately occupied by another program, all three start on distinct free ports, appear in the registry, are routed to by the gateway, and disappear from the registry and from routing within one health interval after one is killed; the registry listing equals the set of live service processes in 100% of 20 random start/stop/kill sequences; a second user on the same host gets a disjoint port set.


## Assumptions

- The original hosted Jev cannot be hosted locally; llmctl will not proxy to the hosted service (the toolkit handles hosted endpoints). Wire-compatibility with the hosted shape is the only "Jev" promise.
- The second team's snapshot is treated as input and merged into current main by careful comparison; the candidate's six profiles, the `decide` command, gateway and ONNX runner are the starting design, subject to the fixes in the findings register.
- The new version is a **minor** bump (3.1.0), because user-visible capability is added; this can be revised in planning.
- The constitution pinned in this repository is **not** replaced by the reduced v70 snapshot in the material. llmctl provides the contract surface the new anchors require (capacity report, gateway address and shape, never-a-chat-model rule, installability). Whether the upstream constitution tag exists and can be adopted is checked during planning and adopted only if it carries no loss of existing gates.
- The toolkit changes in the material (discovery command, gate hook, MCP server, per-agent installers) exist only in the snapshot, not in the real toolkit repository, and the snapshot assumes a plain-HTTP, keyless gateway at `http://127.0.0.1:8095`; under Clarifications 1, 4 and 5 that assumption no longer holds and the required toolkit-side change (HTTPS address, certificate trust, `LLMCTL_API_KEY`) is documented in the contract, not implemented here. They are out of scope to port, but are used as an unmodified external consumer to verify the contract (User Story 9).
- Inference always runs on the operator's own hardware and no state is sent to any third-party service. Because decision endpoints listen on the network by default (Clarification 1), they serve HTTPS with a self-signed certificate so that state and the access key are encrypted in transit; the existing chat servers are unchanged by default (Clarification 2) and their encryption depends on the engine (FR-072).
- Live testing on this host (16 CPUs, ~30 GB RAM of which ~13 GB currently available, a 12 GB GPU of which ~4.8 GiB was free at the time of writing, ~93 GB disk free at 95% usage, an already-running vision server) can exercise the small and mid-sized decision profiles; the largest profile and any chat profile that needs a workstation-class host are expected to be "not exercised, host cannot fit" with exact numbers. Downloading all six profiles needs ~20 GB, which fits the disk.
- The seven supported agents are those already integrated (opencode, pi, crush, Claude Code, aider, continue, Cline). Three of them (aider, continue, Cline) were not found on this host when checked (continue and Cline are IDE extensions rather than CLIs); opencode, pi, crush and Claude Code are installed and are installed by their documented official mechanisms before testing; any that cannot be installed or driven non-interactively here are recorded as "not exercised" with the reason.
- Network access to model hosts may be restricted (the second team used a mirror); if the real source is unreachable, the affected verification is reported as environment-blocked, not passed.
- Platform support is Linux (systemd user services) and macOS (launch agents); Windows is unsupported. macOS behaviour not verifiable on this host is documented as unverified.
- The repository forbids automated pipelines; all verification is local and release is performed from the maintainer's machine with the GitHub and GitLab command-line tools.
- The accuracy benchmarks quoted in the research (hosted Jev, vendors, leaderboards) are context only and are never reproduced as llmctl claims unless llmctl measures them itself.

## Dependencies

- Current main branch of this repository (HEAD `a9ebefe`) and its 38 existing test files (`tests/test_*.sh`).
- The pinned inference engine submodule with log-probability support for the generative profiles.
- Optional third-party runtime packages for the encoder-class profile (to be pinned and integrity-checked as part of FR-025).
- Outbound network access to the model hosting service and, for release, to GitHub and GitLab.
- Installed, authenticated GitHub and GitLab command-line tools on the maintainer's machine.
- The source material under `/home/milosvasic/Projects/jev` (read-only input).

## Out of Scope

- Training, fine-tuning or distilling decision models.
- Hosting or proxying the original hosted Jev.
- Calibration pipelines driven by a large conventional model (the constitution's auto-tuning loop) beyond exposing the data and hooks they need.
- Porting the toolkit's discovery, gate, MCP and per-agent installer code into this repository.
- Windows support.
- Adding automated pipelines of any kind.
