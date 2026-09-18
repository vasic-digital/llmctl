# Implementation Plan: claude_toolkit Residual Test-Isolation Fixes

**Branch**: `007-claude-toolkit-test-fixes` | **Date**: 2026-09-18 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/007-claude-toolkit-test-fixes/spec.md`

**Note**: this plan's Project Structure section names paths in the sibling
repository `/home/milosvasic/Projects/claude_toolkit`, per the spec's own
explicit note that this feature's implementation lives there.

## Summary

Two of claude_toolkit's test files (`test_ccr_upstream_ca.sh`,
`test_kimi_alias_file.sh`) assert "no CA-derived environment variable
leaks to the launched client when no CA is pinned" — but their own sandbox
setup never neutralizes an ambient `CMA_PROVIDER_CA_CERT` (or its two
derived variables) already present in the invoking shell, so the
assertion only holds by accident of what else is running on the host
(research.md R1/R2). This feature adds explicit neutralization to both
files' setup blocks. Separately, `test_providers.sh` has one
intermittently-failing assertion whose actual mechanism is not yet known
(research.md R4 records three candidates, not a conclusion) — this
feature root-causes it via systematic-debugging before fixing it.

## Technical Context

**Language/Version**: Bash (existing `claude_toolkit` test-harness
convention — the same `it "..."` / `assert_eq` DSL already used
throughout `scripts/tests/`)

**Primary Dependencies**: None new — this feature touches only existing
test files and, if R4's investigation implicates it, the shared test
sandbox/stub-recording helpers those files already use

**Storage**: N/A

**Testing**: The claude_toolkit bash test harness itself (self-testing —
this feature's "production code" IS test code, per the spec's own
Assumptions section scoping this to test-harness-only changes)

**Target Platform**: Any host running the claude_toolkit test suite —
the fix must work identically whether or not the host happens to have an
ambient CA-cert variable set (that is the entire point: SC-001 requires
passing BOTH with and without deliberate contamination)

**Project Type**: Single bash-toolkit project (claude_toolkit), test-only
change

**Performance Goals**: N/A (test-isolation and determinism, not
throughput)

**Constraints**: Zero change to `claude-providers.sh`'s or `lib.sh`'s own
production logic (confirmed correct by the prior root-cause investigation
this session already completed and by research.md's confirmation that the
gap is entirely in the two affected TEST files' setup, not the product
code they test); the "WITH CA" scenarios in the same two files must
continue passing unmodified (FR-002); the `test_providers.sh` fix must not
introduce a new timeout-based flake by, e.g., naively adding a fixed
`sleep` where a real wait-for-condition is needed instead (spec's own
Edge Cases section names this risk explicitly)

**Scale/Scope**: Three test files touched (two for the CA-cert isolation
fix, one for the flaky-assertion fix); a full-suite re-run (74 files per
the spec's Success Criteria) to confirm zero regressions

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- **Principle I (Deterministic V&V)**: SATISFIED — both fixes are proven
  by re-running the SPECIFIC previously-failing scenario with captured
  evidence (SC-001: pass with AND without deliberately-injected
  contamination; SC-002: 10 consecutive clean runs), never by a single
  "looks fixed" run.
- **Principle III (Test-First)**: Applied in its reversed, test-repairs-
  test form here — since the deliverable IS test code, "RED first" means:
  (a) for the CA-cert fix, first prove the CURRENT gap by deliberately
  injecting `CMA_PROVIDER_CA_CERT` into the invoking shell and showing the
  two affected tests currently FAIL that way (the RED), THEN add the
  neutralization and show they PASS under the same injected contamination
  (the GREEN) — exactly the spec's own Independent Test for User Story 1;
  (b) for `test_providers.sh`, systematic-debugging's own Phase 1 (root
  cause) MUST complete — with a captured, reproducible trigger for the
  intermittent failure — before Phase 4 (the fix) is attempted, per the
  Iron Law ("no fixes without root cause investigation first").
- No violations requiring Complexity Tracking.

## Project Structure

### Documentation (this feature)

```text
specs/007-claude-toolkit-test-fixes/     # tracked here in llmctl per the spec's own cross-repo note
├── plan.md              # This file
├── research.md          # Phase 0 output (complete)
└── tasks.md             # Phase 2 output (/speckit-tasks)
```

(No `data-model.md`, `contracts/`, or `quickstart.md` beyond what's below
— this feature has no data entities and no external interface; its
"quickstart" IS the Independent Test sections already written into
spec.md's User Stories, which is where a reader should look to run it.)

### Source Code (in `/home/milosvasic/Projects/claude_toolkit`)

```text
scripts/tests/
├── test_ccr_upstream_ca.sh      # MODIFY: "WITHOUT CA" setup block gains an
│                                # explicit `unset CMA_PROVIDER_CA_CERT NODE_EXTRA_CA_CERTS
│                                # SSL_CERT_FILE` before invoking the code under test;
│                                # "WITH CA" scenarios unchanged
├── test_kimi_alias_file.sh      # MODIFY: same neutralization pattern applied to its
│                                # own "no CA pin" scenario (line ~233's negative-control block)
└── test_providers.sh            # MODIFY: once research.md R4's investigation identifies the
                                  # real mechanism (a wait-for-completion fix, an ordering-
                                  # isolation fix, or a flush/sync fix — whichever the evidence
                                  # points to), the specific race is closed at its root cause
```

**Structure Decision**: No new files, no new directories — this feature
is a precision fix to three existing test files in an existing sibling
repository, tracked as a cross-repository planning record in `llmctl`'s
own `specs/` per the spec's own documented convention (matching how
`llmctl/docs/CONTINUATION.md` already tracks related `claude_toolkit`
state from this same body of work).

## Complexity Tracking

*No Constitution Check violations — table intentionally omitted.*
