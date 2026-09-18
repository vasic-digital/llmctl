# Phase 0 Research: claude_toolkit Residual Test-Isolation Fixes

**Feature**: [spec.md](./spec.md) | **Date**: 2026-09-18

**Note**: implementation lives in the sibling repository
`/home/milosvasic/Projects/claude_toolkit`, which has no SpecKit of its own
(confirmed: neither `.specify/` nor `specs/` exists there) — all file paths
below are relative to that repository's root.

## R1: What is the COMPLETE set of environment variables `CMA_PROVIDER_CA_CERT` derives, that a "WITHOUT CA" test scenario must neutralize?

**Decision**: Exactly two — `NODE_EXTRA_CA_CERTS` and `SSL_CERT_FILE` —
plus `CMA_PROVIDER_CA_CERT` itself (the source variable). No other
variable name is derived from it anywhere in the codebase.

**Evidence gathered this phase**: a repo-wide grep of `scripts/lib.sh` and
`scripts/claude-providers.sh` for every symbol textually adjacent to
`CMA_PROVIDER_CA_CERT` shows it feeding exactly two derived exports, at
every one of its five call sites (`lib.sh` lines ~1869-1894 for the CCR/Go
router transport path, ~2551-2557 and ~3900-3905 and ~4169-4171 for the
native-transport launch paths, and `claude-providers.sh` line ~2990-2994
which additionally re-serializes the raw `CMA_PROVIDER_CA_CERT` value back
into a per-pid `.env` file): `NODE_EXTRA_CA_CERTS="${CMA_PROVIDER_CA_CERT}"`
(Node's own APPEND-to-system-roots variable) and
`SSL_CERT_FILE="${CMA_PROVIDER_CA_CERT}"` (or, in the CCR/Go-router case, a
COMBINED bundle file path built FROM it — Go's SSL_CERT_FILE REPLACES the
trust pool rather than appending, which is why that one path builds a
combined system+extra bundle rather than pointing SSL_CERT_FILE at the raw
pin directly). This confirms the affected tests' own docstrings (already
correct, `test_ccr_upstream_ca.sh` lines 19-28) name the right two derived
variables — the gap is not in what the tests CHECK, it is in what the
tests' own SANDBOX SETUP fails to clear beforehand.

## R2: Why does the "WITHOUT CA" scenario fail only sometimes (i.e., only when contaminated)?

**Decision**: Confirmed root cause — the affected tests' "WITHOUT CA"
setup writes a per-alias `.env` fixture file that OMITS a
`CMA_PROVIDER_CA_CERT=` line, but never explicitly `unset`s
`CMA_PROVIDER_CA_CERT` (nor its two derived variables) in the actual shell
process that then sources/invokes the code under test. When the invoking
shell already has `CMA_PROVIDER_CA_CERT` exported from an unrelated
ambient source (confirmed this session: `env | grep -i CA_CERT` on this
exact host shows it set to a sibling project's cert path,
`/home/milosvasic/Projects/helix_code/submodules/helix_llm/certs/cert.pem`),
the product code under test reads that ambient value — it has no way to
distinguish "the test's fixture intentionally configured no CA" from "the
test's fixture said nothing, so whatever the process environment already
has applies" (the product code's own `[[ -n "${CMA_PROVIDER_CA_CERT:-}" ]]`
checks, correctly, treat both cases identically — the omission is a
TEST-HARNESS gap, not a place the PRODUCT code should special-case).

**Evidence**: this diagnosis matches this session's own earlier
confirmed finding (`env | grep -i CA_CERT` on this exact host) and the
inherited-summary root-cause note; it is treated as the working hypothesis
this feature's implementation MUST re-confirm with a fresh, deliberate
repro (per this project's own §11.4.199 exact-reproduction-sequence
discipline) before landing the fix, not assumed as already fully proven
absent that repro.

## R3: Where is the correct place to add the neutralization?

**Decision**: Each affected test file's own sandbox-setup section (the
top-of-file block that creates the per-alias `.env` fixtures and starts
the stub `ccr`/`claude` recorders), NOT a shared, repo-wide test-harness
helper — because the fix must clear the two derived variables (R1) AND the
source variable BEFORE invoking the code under test, and the two affected
files (`scripts/tests/test_ccr_upstream_ca.sh`,
`scripts/tests/test_kimi_alias_file.sh`) already have their own
self-contained setup blocks (confirmed by direct read) rather than sharing
one common sandbox-init function — matching the existing per-file
convention rather than introducing a new shared helper this feature does
not otherwise need.

**Alternatives considered**: adding a repo-wide `it_test_harness.sh`-style
"always unset every known contamination variable" hook run before every
test file in the suite: rejected for this feature's scope — it would
touch every test file's invocation path for a fix only two files need,
increasing this feature's blast radius past what FR-001/FR-002 (scoped
explicitly to these two files) call for; left as a natural follow-up if a
THIRD affected test is ever discovered (tracked via this project's own
recurrence-links-not-mints discipline rather than assumed here).

## R4: What is the `test_providers.sh` intermittent-failure candidate mechanism?

**Decision**: Not yet root-caused — genuinely unknown pending the
Phase 4 investigation this spec's User Story 2 commits to. This research
phase records the CANDIDATE mechanisms to investigate first (in
descending likelihood, per the spec's own Input framing), without
asserting any one of them as the cause ahead of the actual investigation
(per this project's own no-guessing / §11.4.6 discipline: "probably a
race" is not a finding).

**Candidates to investigate, in order** (documented here so the
implementation phase's systematic-debugging pass has a starting point, not
a conclusion):
1. **A background process/subshell whose log-write completion the test
   does not wait for** before grepping for "refreshed" — the classic
   write-vs-read race the spec's own Edge Cases section already names.
2. **An ordering dependency on a PRIOR test's side effect** (e.g., a
   shared cache file, a shared alias `.env`, a shared port) that only
   sometimes leaves state in the shape this assertion expects, depending
   on which other tests ran first in that invocation.
3. **A log-buffering artifact** — the "refreshed" string is written to a
   file the test reads before the writer's buffer has flushed, distinct
   from (1)'s process-completion race (a completed process can still have
   unflushed buffered output on some platforms/redirection modes).

**Evidence gathered this phase**: the spec's own Input notes a later
re-run passed cleanly at 427/427 with no code change — consistent with
(1) or (3) (both are inherently non-deterministic timing races) and
somewhat less consistent with (2) alone (an ordering dependency would
usually reproduce deterministically given the SAME preceding test
sequence, though a non-deterministic PRECEDING test could still make (2)
look intermittent too) — this observation narrows but does not yet
resolve which candidate is real; the implementation phase's first task is
proving it with a captured repro, per systematic-debugging Phase 1, before
attempting any fix.
