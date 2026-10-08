# Specification Quality Checklist: Jev-Class Decision Models in llmctl

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-10-07
**Feature**: [spec.md](../spec.md)
**Validation iterations**: 2 (initial self-review plus mechanical scan; re-validation after the 2026-10-07 clarification session of 5 questions; see Notes)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs) — Caveat: the Background section names the existing candidate's components and port numbers because they are the subject material, and FR-018/FR-020 state security properties (credentials not in process arguments) that constrain behaviour without prescribing a design. No language, framework or library is prescribed for the work itself.
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders — Caveat: the product is a command-line infrastructure tool, so the audience is operators and maintainers; the user stories are written in operator terms and avoid code-level detail.
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain (mechanical count: 0)
- [x] Requirements are testable and unambiguous — one hedged requirement (FR-029, multi-instance) was made decisive during validation; FR-016 and FR-012 reference configured budgets/limits whose values are set in planning.
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details) — Caveat: SC-005 and SC-006 name process listings and hostile traffic because those are the observable security outcomes.
- [x] All acceptance scenarios are defined (9 stories, each with scenarios and an independent test)
- [x] Edge cases are identified (28 listed, including the reported long-state truncation, disk pressure at 95%, shared GPU, and test-switch misuse)
- [x] Scope is clearly bounded (Out of Scope section; hosted Jev, toolkit porting, training and Windows excluded)
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria (91 requirements map to the 9 stories and 15 success criteria; see traceability.md)
- [x] User scenarios cover primary flows (run, expose, verify, agents, capacity, admit models, operate, release, contract)
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification (see first Content Quality caveat)

## Notes

- **Honest status of inputs.** Every defect in `source-findings.md` was reported by read-only analysis and is marked UNREPRODUCED. The spec therefore requires reproduction before fixing (FR-040) and does not assert any of them as established fact. The Jev.md claims list (Section E) is entirely unverified.
- **Decisions made by default, to be confirmed in planning** (none significant enough to block the specification, so no clarification markers): minor version bump to 3.1.0; the pinned constitution is not replaced by the reduced v70 snapshot; toolkit code is not ported; live testing runs only what this host can fit, with "not exercised" recorded for the rest.
- **Known tension to resolve in planning**: the constitution's live-testing rule and this host's limits (about 4.8 GiB GPU free, 95% full disk, an already-running vision server) mean some profiles may only be exercised after freeing resources, which needs the operator's consent.
- Items marked incomplete would require spec updates before `/speckit-clarify` or `/speckit-plan`. None remain.
- **Re-validation after clarification (2026-10-07)**: 16/16 items passing before and after; no regressions and no newly passing items. Five operator decisions were integrated (HTTPS-only network-wide endpoints with a generated `LLMCTL_API_KEY`, key scope limited to decision endpoints, evidence-gated admission of further models, self-signed certificate under the user's home directory, no plain-HTTP listener). Operator-dictated names (`LLMCTL_API_KEY`, the certificate directory, self-signed HTTPS) are requirements, not design choices, so the 'no implementation details' items stay checked with the caveat above.
- **Deferred to planning, with defaults recorded in the spec**: whether the decision gateway needs its own boot-time service unit (FR-031 covers profiles; the candidate ran the gateway only in the foreground), and consent to free GPU/disk resources for live tests of the larger profiles.
