# Feature Specification: Honest Full Test-Type Coverage Classification and Gap Closure

**Feature Branch**: `008-full-test-coverage`

**Created**: 2026-09-18

**Status**: Draft

**Input**: User description: "Achieve honest, complete test-type coverage across llmctl (bash CLI), llmctld (Go daemon), and claude_toolkit against Constitution's 14-class test-type taxonomy (unit, integration, e2e, full-automation, security, DDoS, scaling, chaos, stress, performance, benchmarking, UI, UX, Challenges/HelixQA-style autonomous QA). This feature must produce an honest, checked-in classification of every one of the 14 classes as COVERED (with evidence), PARTIAL (with a concrete gap statement), or GENUINELY-INAPPLICABLE (with a stated reason, never silently dropped), then close every real, applicable gap with actual new tests - never claim a class is covered without genuine, real, non-mocked evidence, and never invent a fake UI/UX test just to check a box for a project that has no UI."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - An operator can see, at a glance, exactly which test types this project genuinely has and which it doesn't (Priority: P1)

An operator or reviewer wants to know whether this project's quality claims are real. Today, whether a given test type (e.g. "chaos testing" or "security testing") exists at all is scattered across the codebase and has to be discovered by reading source files directly. This feature produces one checked-in document that states, for each of the 14 recognized test-type classes, exactly what exists, what evidence backs it, and — for anything not covered — an honest, specific reason (a concrete gap, or a stated reason the class does not apply to this kind of project).

**Why this priority**: Every other outcome in this feature depends on first having an accurate, evidence-based map of the current state — closing gaps before honestly identifying them risks closing the wrong ones, or claiming closure without evidence.

**Independent Test**: Read the produced classification document and independently verify, for at least three of the "COVERED" classes, that the cited evidence (a specific test file, a specific passing run) genuinely exists and genuinely tests what it claims to.

**Acceptance Scenarios**:

1. **Given** the classification document, **When** a reviewer checks any class marked COVERED, **Then** it cites a specific, real, currently-passing test as evidence — never a vague claim.
2. **Given** the classification document, **When** a reviewer checks any class marked GENUINELY-INAPPLICABLE, **Then** it states a specific, checkable reason (e.g. "this project has no graphical interface") rather than a bare assertion.
3. **Given** the classification document, **When** a reviewer checks any class marked PARTIAL, **Then** it states exactly what exists and exactly what is still missing, in concrete terms.

---

### User Story 2 - The project has a real, repeatable way to know its own resource limits under load (Priority: P2)

An operator wants to know how the daemon and the model-serving layer behave under sustained load and under a flood of requests, rather than assuming they are fine because nothing has broken yet in normal use. Today, no dedicated stress or DDoS-style test exists for either the `llmctld` API or a running model server.

**Why this priority**: This is the most consequential concrete gap identified by the initial investigation — the two test classes with genuinely zero existing coverage anywhere in either repository.

**Independent Test**: Run a new, dedicated sustained-load test against the daemon's API and observe it either handles the load within a defined, documented limit, or fails in a controlled, understood, and reported way (never an unhandled crash with no diagnostic).

**Acceptance Scenarios**:

1. **Given** a running `llmctld` instance, **When** it receives a sustained high rate of legitimate requests, **Then** its behavior at and beyond its documented capacity is observed and recorded, not assumed.
2. **Given** a running `llmctld` instance, **When** it receives a flood of requests explicitly designed to exceed reasonable limits, **Then** it degrades or refuses excess load in a controlled way (rate-limiting, backpressure, or a clear error) rather than crashing or becoming unresponsive to legitimate requests.

---

### User Story 3 - The project has a real, documented performance baseline, not just scattered one-off measurements (Priority: P3)

An operator wants a single, repeatable benchmark suite with a documented baseline for key operations (request latency, quota-check throughput, cache-restore timing), so a future change's performance impact can be compared against a known number rather than re-measured from scratch each time.

**Why this priority**: The individual benchmark tests already exist and pass; what's missing is consolidation into a repeatable, documented baseline — valuable, but lower urgency than the zero-coverage gaps in User Story 2.

**Independent Test**: Run the consolidated benchmark suite twice in a row and confirm both runs produce results within a documented acceptable variance of each other and of the recorded baseline.

**Acceptance Scenarios**:

1. **Given** the existing individual benchmark tests, **When** they are run together as a suite, **Then** a single, documented report of current results is produced.
2. **Given** a documented baseline exists, **When** the same suite is run again later, **Then** its results can be compared against that baseline to detect a regression or improvement.

---

### Edge Cases

- What happens when a test class is genuinely inapplicable for one of the three components (llmctl, llmctld, claude_toolkit) but applicable for another (e.g. a "scaling" test might mean something different for a single-process bash CLI than for a multi-node Raft cluster)? The classification must be granular enough not to force one verdict across components where the honest answer differs.
- What happens when a new stress/DDoS test itself risks affecting other work running on this shared development host? The test design must bound its own resource usage and be safely stoppable, consistent with this project's existing host-safety discipline.
- What happens when the classification document itself becomes stale as new tests are added later? It must be tied to a mechanism (even a manual one, documented here) for re-verification, not written once and left to drift.
- If a stress or DDoS-style test is run against a real GPU-accelerated model server (depending on the outcome of the separate GPU-enablement work), does the load test need different limits than against a CPU-only server? The test's documented capacity limits must be host-configuration-aware, not a single hardcoded number that is wrong on a different host.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: A single, checked-in classification document MUST enumerate all 14 recognized test-type classes and, for each, state COVERED (with a specific evidence citation), PARTIAL (with a specific gap statement), or GENUINELY-INAPPLICABLE (with a specific, checkable reason) — separately for each of llmctl, llmctld, and claude_toolkit where the answer could genuinely differ between them.
- **FR-002**: No class MUST be marked COVERED without a cited, currently-real, currently-passing test as evidence — a claim of coverage with no evidence is a defect in the document, not an acceptable state.
- **FR-003**: No class MUST be silently omitted from the document — every one of the 14 classes MUST appear with one of the three verdicts.
- **FR-004**: A new stress test MUST exist for `llmctld`'s API surface, exercising sustained load and recording its observed behavior at and beyond a documented capacity limit.
- **FR-005**: A new DDoS-style (request-flood) test MUST exist for `llmctld`'s API surface, confirming it degrades or refuses excess load in a controlled, documented way rather than crashing or becoming unresponsive to legitimate traffic.
- **FR-006**: The existing individual benchmark tests MUST be consolidated into one repeatable suite producing a single report, with a documented baseline for future comparison.
- **FR-007**: The project's existing security-relevant test coverage (mTLS, JWT, RBAC) MUST be supplemented with at least one dedicated adversarial test per mechanism (e.g. an expired/malformed/tampered token rejected, an unauthorized RBAC action refused, a rotated CA correctly invalidating an old certificate) beyond the happy-path functional tests that already exist.
- **FR-008**: Any class marked GENUINELY-INAPPLICABLE MUST be re-examined and confirmed still accurate whenever a component's fundamental nature changes (e.g. if a graphical interface were ever added, UI/UX would need re-classification) — the document MUST state this re-examination trigger explicitly rather than leaving the inapplicability judgment as a one-time, unrevisited claim.
- **FR-009**: Every newly-added test in this feature MUST be run against real components (a real running daemon, a real model server where applicable) — mocked-only tests do not satisfy this feature's own no-bluff requirement for the classes they claim to cover.

### Key Entities

- **Test-Type Classification Document**: The single, checked-in artifact enumerating all 14 classes, their verdicts, evidence citations, and gap statements, per component.
- **Stress Test**: A new, dedicated test exercising sustained legitimate load against `llmctld`'s API to observe real behavior at and beyond documented capacity.
- **DDoS-Style Test**: A new, dedicated test exercising an excessive request flood against `llmctld`'s API to confirm controlled degradation rather than an uncontrolled failure.
- **Consolidated Benchmark Suite**: A single runnable entry point aggregating the existing individual benchmark tests, producing one report and comparable against a documented baseline.
- **Adversarial Security Test**: A new test per security mechanism (mTLS, JWT, RBAC) proving the mechanism correctly REJECTS an invalid/malicious case, complementing existing tests that prove it accepts a valid one.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: All 14 test-type classes have a documented verdict (COVERED/PARTIAL/GENUINELY-INAPPLICABLE) with a specific citation or reason, for each applicable component — zero classes left unaddressed.
- **SC-002**: A new, real stress test against `llmctld` produces a documented capacity observation (a specific request rate or concurrency level at which behavior changes), not an assumption.
- **SC-003**: A new, real DDoS-style test against `llmctld` demonstrates the daemon continues serving legitimate requests correctly while under an excessive-request flood, or documents the specific, controlled way it declines to.
- **SC-004**: The consolidated benchmark suite runs to completion and produces one report; running it twice in immediate succession produces results within a documented acceptable variance of each other.
- **SC-005**: Each of mTLS, JWT, and RBAC has at least one passing adversarial test proving the mechanism correctly rejects an invalid case, in addition to its existing happy-path coverage.
- **SC-006**: Zero previously-passing tests regress as a result of this feature, confirmed by a full-suite re-run across all three components.

## Assumptions

- The 14-class taxonomy is taken as-is from this project's own governance framework; this feature does not add or remove classes from that list, only classifies and closes gaps against it.
- "Genuinely inapplicable" is a real, defensible classification for UI and UX given this project's confirmed current shape (a CLI, a headless daemon, and a bash toolkit with no graphical interface anywhere) — this feature does not invent a UI to create UI/UX tests against.
- Challenges/HelixQA-style autonomous QA banks, as referenced in the project's inherited governance framework, are not currently adopted as dependencies by this project; this feature classifies that class as GENUINELY-INAPPLICABLE (not adopted) rather than PARTIAL, since "partial" would incorrectly imply the intent to adopt them was already underway.
- A documented capacity limit for the new stress/DDoS tests is expected to be host-hardware-dependent (especially once GPU enablement work lands separately) and this feature records whatever the real, current host actually demonstrates, not a fixed, universal number.
- This feature's new tests are added to the existing test suites in-place (bash tests alongside existing bash tests, Go tests alongside existing Go tests) rather than introducing a new, separate test framework.
