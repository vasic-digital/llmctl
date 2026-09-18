# Feature Specification: claude_toolkit Residual Test-Isolation Fixes

**Feature Branch**: `007-claude-toolkit-test-fixes`

**Created**: 2026-09-18

**Status**: Draft

**Input**: User description: "Fix claude_toolkit's remaining residual test failures with real root-cause fixes, not disclosure-only workarounds. Confirmed root cause for test_ccr_upstream_ca.sh (2 failures) and test_kimi_alias_file.sh (1 failure): the test harness's 'WITHOUT CA' scenarios never explicitly unset CMA_PROVIDER_CA_CERT (and its derived NODE_EXTRA_CA_CERTS/SSL_CERT_FILE exports) before running - so an ambient value already present in the invoking shell's environment leaks through and makes the 'stays unset when no CA pin is configured' assertion fail, even though the actual claude-providers.sh logic being tested is correct. This is a test-isolation gap in the harness's sandbox setup, not a product defect. Also resolve test_providers.sh's one intermittently-failing assertion ('non-quiet refresh logs 'refreshed'') - it passed cleanly on a later re-run (427/427), suggesting a real timing/ordering race rather than a stable defect; root-cause it properly rather than accepting the flakiness or ignoring it. Every fix must be proven with the specific previously-failing test re-run clean, plus a full-suite re-run confirming zero regressions elsewhere."

**Note**: This feature's implementation lives entirely in the sibling repository `/home/milosvasic/Projects/claude_toolkit`, which has no SpecKit setup of its own; this spec is tracked here (in `llmctl`'s `specs/`) as a cross-repository planning record, matching how `llmctl/docs/CONTINUATION.md` already tracks related `claude_toolkit` state from this same body of work.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The CA-cert test suite genuinely proves the "no CA pin" behavior, regardless of what else is running on the host (Priority: P1)

An operator (or CI) runs `claude_toolkit`'s test suite on a shared host that also has other, unrelated projects with their own environment variables set. The tests that assert "when no CA is pinned, no CA-related environment variable is exported to the launched client" must genuinely prove that — today, they instead prove "as long as nothing else on this host happened to set a CA-related variable first", which is not the same claim and is not reliably true on a real shared host.

**Why this priority**: A test that only passes by accident of what else is running is not testing what it claims to test — it is exactly the kind of ambiguous, environment-dependent result this project's own anti-bluff discipline exists to eliminate.

**Independent Test**: Deliberately set `CMA_PROVIDER_CA_CERT` (and related variables) to an arbitrary, obviously-external value in the invoking shell before running the affected test files, and confirm they still pass — proving the test's own sandbox setup neutralizes ambient contamination rather than merely hoping it is absent.

**Acceptance Scenarios**:

1. **Given** an ambient `CMA_PROVIDER_CA_CERT` value is present in the shell that invokes the test suite, **When** the "WITHOUT CA" test scenarios in `test_ccr_upstream_ca.sh` run, **Then** they still correctly assert that no CA-derived variable reaches the launched client, unaffected by the ambient value.
2. **Given** the same ambient contamination, **When** `test_kimi_alias_file.sh`'s equivalent scenario runs, **Then** it too passes correctly, unaffected.
3. **Given** NO ambient CA-related variables are present at all (the "clean" case), **When** the same test files run, **Then** they continue to pass exactly as before — the fix must not change behavior for the already-clean case, only make the contaminated case behave the same as the clean one.

---

### User Story 2 - The one intermittently-failing assertion is understood and made reliably deterministic (Priority: P2)

An operator running the full test suite occasionally sees `test_providers.sh`'s "non-quiet refresh logs 'refreshed'" assertion fail, and sometimes sees it pass, with no code change in between. This must be root-caused to a specific, understood mechanism (a race between when a log line is written and when the test reads it, an ordering dependency on some other test's side effect, or another concrete cause) and then made to pass reliably, not merely observed to "usually pass".

**Why this priority**: Priority 2 relative to the CA-cert fix because it is a single assertion with a lower failure rate observed so far, but it is still a genuine gap in this project's zero-flakiness bar and must not be left as an accepted, unexplained intermittent failure.

**Independent Test**: Run the specific affected test file repeatedly (a meaningful number of consecutive runs, back to back, with no code changes between runs) both before and after the fix, and confirm the failure rate drops from non-zero to zero.

**Acceptance Scenarios**:

1. **Given** the un-fixed test, **When** it is run repeatedly, **Then** the actual root cause of its intermittent failure is identified and documented with evidence (not guessed).
2. **Given** the fix is applied, **When** the same test is run the same number of times repeatedly, **Then** it passes every single time.

---

### Edge Cases

- What happens if a host has a CA-cert-derived environment variable that this feature's fix does not know to unset (a variable name not yet identified)? The fix's own list of variables to neutralize must be complete relative to every variable the product code itself can set from `CMA_PROVIDER_CA_CERT`, not merely the ones currently observed to leak.
- What happens to a test scenario that legitimately DOES want a CA to be pinned (the "WITH CA" cases) — the fix must not accidentally unset variables in those cases too, since that would make the "with CA" assertions fail instead.
- If the `test_providers.sh` race turns out to involve a background process or subshell whose completion isn't properly waited for, does the fix risk making the test slower in a way that would itself introduce a new timeout-based flake?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Every "WITHOUT CA" test scenario in `test_ccr_upstream_ca.sh` and `test_kimi_alias_file.sh` MUST explicitly clear every CA-cert-derived environment variable the product code under test can set, before that scenario runs, so its result does not depend on what else is present in the invoking shell's ambient environment.
- **FR-002**: The "WITH CA" test scenarios in the same files MUST continue to correctly assert their existing behavior, unaffected by the fix to the "WITHOUT CA" scenarios.
- **FR-003**: `test_providers.sh`'s intermittently-failing assertion MUST have its actual root cause identified and documented with reproducible evidence, not assumed.
- **FR-004**: Once root-caused, the underlying race or ordering issue MUST be fixed such that the specific assertion passes on every run across a meaningful number of consecutive repeated runs.
- **FR-005**: The full pre-existing test suite (all currently-passing test files) MUST continue to pass unchanged after these fixes, confirmed by a fresh, full-suite run.
- **FR-006**: Both fixes MUST be demonstrated by re-running the exact specific test files that previously failed and confirming a clean pass, with the evidence captured (not merely asserted).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: `test_ccr_upstream_ca.sh` and `test_kimi_alias_file.sh` pass with zero failures both with and without a deliberately-injected ambient CA-cert environment variable present before the run — proving genuine isolation rather than accidental cleanliness.
- **SC-002**: `test_providers.sh` passes its previously-intermittent assertion on 100% of at least 10 consecutive repeated runs with no code changes between runs.
- **SC-003**: The full test suite's overall pass count returns to 74/74 (currently 71/74, the 3 failures this feature closes), with zero new failures introduced anywhere else in the suite.
- **SC-004**: Re-running the full suite a second time immediately after the first clean run produces the identical 74/74 result, demonstrating the fix is stable, not itself a one-off pass.

## Assumptions

- The set of CA-cert-derived environment variables to neutralize is the set the product code (`claude-providers.sh`, `lib.sh`) itself derives from `CMA_PROVIDER_CA_CERT` — enumerated by reading that code directly, not guessed from the two variables already observed leaking (`NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`).
- This feature only touches test-harness code (the affected `.sh` test files and any shared test-sandbox setup helper they use), not `claude-providers.sh`'s or `lib.sh`'s own production logic, since the root cause is confirmed to be test isolation, not product behavior.
- "A meaningful number of consecutive repeated runs" for demonstrating the flaky-test fix is interpreted as at least 10, absent a project-specific convention already establishing a different number.
