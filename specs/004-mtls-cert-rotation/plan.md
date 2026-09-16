# Implementation Plan: mTLS Certificate and CA Rotation with Revocation

**Branch**: `004-mtls-cert-rotation` (developed directly on `main`, same
pattern as 002/003) | **Date**: 2026-09-15 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `specs/004-mtls-cert-rotation/spec.md`

## Summary

Close T012/T075's disclosed boundary: `internal/mtls`'s CA and per-node
leaf certificates are generated once, loaded once into each process's
`tls.Config` at startup, with a fixed 1-year validity, no revocation
mechanism, and no rotation mechanism. Add: revocation (User Story 1, P1),
zero-downtime renewal (User Story 2, P1), and coordinated CA rotation
(User Story 3, P2) — all built on the existing `internal/mtls` issuance
primitives and the existing Raft-replicated cluster state for
coordination, per spec.md FR-002/FR-014.

**Investigation-grounded technical approach** (verified by reading
`internal/mtls/certs.go`, `internal/raft/transport.go`'s
`VerifyPeerCertificateAgainstCA`, and `cmd/llmctld/main.go`'s cert-loading
flow before writing this plan):

1. **The verification hook is already a closure, not a fixed field —
   this is the load-bearing enabler.** `VerifyPeerCertificateAgainstCA(pool
   *x509.CertPool) func(...) error` returns a closure that
   `tls.Config.VerifyPeerCertificate` stores. Today that closure captures
   a `*x509.CertPool` built ONCE at process startup. This feature
   refactors it to close over a small, mutex-protected `TrustStore` (new)
   instead of a fixed pool — the closure itself is re-evaluated on EVERY
   real TLS handshake (that is simply how `VerifyPeerCertificate` already
   works), so making its DATA source live-mutable, rather than
   reconstructing `tls.Config` itself, is sufficient for revocation and
   dual-CA-trust-during-rotation to take effect on the very next
   connection attempt with zero process restart.
2. **A node's own presented certificate becomes dynamically swappable the
   same way**, using `tls.Config.GetCertificate`/`GetClientCertificate`
   callback fields (the standard Go idiom for live cert rotation, reading
   from the same `TrustStore`-adjacent mutex-protected current-`NodeCert`
   holder) instead of the current static `Certificates: []tls.Certificate{...}`
   field construction — confirmed as the correct approach against Go's
   own documented `crypto/tls` API (these callback fields exist
   specifically to avoid needing to rebuild a whole `tls.Config`/listener
   to rotate a certificate).
3. **Coordination reuses the existing Raft-replicated `ClusterState`**
   (the SAME mechanism 002/003 also extend) via new FSM commands for
   revocation and CA-rotation-event records, per spec.md FR-002/FR-014 —
   no second consensus/coordination channel.
4. **Certificate issuance logic itself is untouched.** `mtls.GenerateCA`/
   `LoadCA`/`IssueNodeCert` are reused exactly as they are; this feature
   adds lifecycle operations AROUND them (when/how a new one gets issued,
   propagated, and trusted), never redesigns the cryptographic primitives
   themselves.
5. **Revocation is identity-based, keyed by certificate serial number**
   (the field `x509.Certificate.SerialNumber` — already generated per-cert
   via `randomSerial()` in `certs.go`, confirmed unique per issuance), NOT
   by node ID alone — spec.md FR-012 requires revocation to be
   independent of cluster-membership eviction, and a node can be re-issued
   a FRESH certificate (a new serial) after a prior one is revoked without
   needing to also change its node ID or membership record.

## Technical Context

**Language/Version**: Go (`llmctld/internal/mtls`, `internal/raft`,
`internal/api`, `internal/cluster`) — no new language.
**Primary Dependencies**: Go's standard `crypto/tls`/`crypto/x509`
(already used throughout `internal/mtls`); `github.com/hashicorp/raft`
(already vendored, reused for coordination per Decision 3 in research.md).
No new third-party dependency — deliberately NOT introducing a full X.509
CRL/OCSP responder library, since spec.md's revocation requirement
("rejected by every OTHER NODE's mTLS verification immediately") is fully
satisfiable by an in-memory, Raft-replicated revoked-serial-number set
checked inside the existing verification closure — a heavier standards-
based CRL/OCSP mechanism would be solving a different problem (external,
non-cluster-member relying parties checking revocation) this project does
not have.
**Storage**: The new `RevocationRecord`/`CARotationEvent` records live in
the same Raft-replicated `ClusterState` (or sibling structure) 002/003
also extend — additive, not a new storage engine.
**Testing**: Real multi-process integration tests (matching T049's own
"real TLS certs from internal/mtls... real transports on loopback"
established pattern) — a revoked identity's connection attempt must be
REALLY rejected by a REAL running node's REAL TLS handshake, never
asserted against the verification function in isolation alone (though
unit tests of the function are also required, per TDD).
**Target Platform**: Linux + macOS `llmctld` cluster nodes.
**Project Type**: Backend daemon extension (Go).
**Performance Goals**: A revocation MUST take effect for a NEW connection
attempt as soon as the issuing node's own Raft-applied state reflects it,
and for every OTHER node as soon as their own Raft replication catches up
(bounded by the cluster's existing Raft-replication latency — no new,
separate latency budget invented; SC-001 measures "rejected", not a
specific millisecond bound the spec does not itself impose beyond "no
per-node manual reconfiguration required").
**Constraints**: MUST NOT introduce a second coordination/consensus
mechanism (FR-002/FR-014); MUST NOT change `mtls.CA`/`mtls.NodeCert`'s
existing struct shapes or `GenerateCA`/`LoadCA`/`IssueNodeCert`'s existing
signatures (every existing `internal/mtls` test — T012's own — MUST keep
passing unmodified); MUST NOT silently couple revocation to membership
eviction (FR-012); MUST refuse (or clearly warn on) an action that would
strand the cluster below quorum (FR-010).

## Constitution Check

*GATE: Must pass before proceeding. Re-check after design phase.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Deterministic Validation & Verification | PASS | Every claim (revocation rejected, renewal is downtime-free, rotation preserves quorum) is proven via real multi-process TLS handshakes and real captured rejection/acceptance evidence, matching T049's own established real-mTLS test bar. |
| II. CLI-First Interface & Text I/O | PASS | Extends the existing JSON HTTP cluster API; no new CLI surface required beyond what the existing `cmd/llmctld` subcommand pattern already supports for operator-triggered actions. |
| III. Test-First with Anti-Bluff Gates (NON-NEGOTIABLE) | PASS (gate applies at execution time) | Every new FSM command and every new TLS-config-dynamic-source change gets a RED-first test. |
| IV. Integration Testing & Real Environment Execution | PASS | Revocation/renewal/rotation are inherently real-multi-process, real-TLS-handshake concerns — no mocking at the harness level, matching T049/T058's own established discipline for this exact subsystem. |
| V. Anti-Bluff Covenant | PASS | "Rejected immediately" (SC-001) is proven by a real rejected connection attempt, not by inspecting the revocation list's presence alone. |
| VI. Absolute Codebase & Data Safety | PASS | No destructive operation; `ClusterState` extension is additive. |
| VII. Host-Session Safety | PASS | No new unbounded loop; verification-closure lookups against an in-memory set are O(1)-adjacent and add negligible per-handshake cost. |
| VIII. Submodule Governance | N/A | Touches only `llmctld/internal/*`; no submodule touched. |
| IX. Documentation Up to Nano-Details | PASS (gate applies at execution time) | `docs/cluster-architecture.md`'s mTLS section gains a new revocation/rotation subsection with a real sequence diagram, matching the established discipline. |
| X. Changelog Discipline & Multi-Format Export | PASS (gate applies at execution time) | Same T072-FU-chain documentation pattern. |

## Project Structure

### Documentation (this feature)

```text
specs/004-mtls-cert-rotation/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
└── checklists/requirements.md
```

### Source Code (repository root)

```text
llmctld/
├── internal/
│   ├── mtls/
│   │   ├── certs.go           # UNCHANGED (issuance primitives reused as-is)
│   │   └── truststore.go      # NEW: mutex-protected TrustStore{CAPools
│   │                              []*x509.CertPool (1 during steady
│   │                              state, 2 during a rotation transition),
│   │                              RevokedSerials map[string]struct{},
│   │                              CurrentNodeCert *tls.Certificate (for
│   │                              GetCertificate/GetClientCertificate)}
│   │                              + methods to update each field safely
│   │                              under lock, read by the closures below.
│   ├── raft/
│   │   ├── transport.go        # MODIFY: VerifyPeerCertificateAgainstCA
│   │   │                          refactored to read from a *TrustStore
│   │   │                          instead of a fixed *x509.CertPool
│   │   │                          (checks the presented cert's serial
│   │   │                          against RevokedSerials FIRST, then
│   │   │                          chains against whichever CAPool(s) are
│   │   │                          current)
│   │   └── fsm.go              # MODIFY: new CommandRevokeCertificate,
│   │                              CommandBeginCARotation,
│   │                              CommandFinalizeCARotation
│   ├── cluster/state.go        # MODIFY: RevocationRecord,
│   │                              CARotationEvent additions
│   └── api/
│       ├── server.go            # MODIFY: tls.Config construction uses
│       │                          GetCertificate/GetClientCertificate
│       │                          callbacks reading from *TrustStore
│       │                          instead of a static Certificates field
│       └── routes_mtls.go       # NEW: operator-facing revoke/renew/
│                                   rotate-begin/rotate-finalize + status
│                                   endpoints
└── test/integration/
    └── mtls_rotation_test.go    # NEW
docs/
└── cluster-architecture.md      # MODIFY
```

**Structure Decision**: Direct-on-`main`, same rationale as 002/003. This
feature's `ClusterState`/FSM extension coordinates with whichever shape
002/003 have already landed, exactly as 003's own plan.md already notes
for its relationship to 002 — read the real current shape before
implementing, never assume this document's sketch is still exactly
current if executed after either of the other two features.

## Execution Strategy

### TDD Requirements

- [ ] `internal/mtls/truststore.go`: strict RED-GREEN — concurrent-safety
      is the load-bearing property (a handshake reading the store while
      an update is applied must never race), matching the exact class of
      defect `internal/raft/fsm.go`'s own doc comment already documents
      having been found and fixed once (Phase 11 T073's concurrent-map
      bug) in an adjacent part of this codebase.
- [ ] `internal/raft/transport.go`'s refactored verification closure:
      strict RED-GREEN, extending T049's own real-mTLS test pattern with
      a real revoked-certificate-rejected test.
- [ ] `internal/raft/fsm.go`'s new commands: strict RED-GREEN, matching
      the existing command-addition pattern (T007/T010 in 002, T003 in
      003).
- [ ] `internal/api/server.go`'s `GetCertificate`/`GetClientCertificate`
      wiring: strict RED-GREEN against a REAL running server proving a
      live cert swap takes effect for new connections without dropping
      existing ones (User Story 2, Acceptance Scenario 2).

### Parallel Execution Opportunities

- [ ] `internal/mtls/truststore.go` (the shared data structure) must land
      first; `transport.go`'s and `server.go`'s consumption of it can then
      proceed as two independent subagent streams (different files,
      different consumers).
- [ ] The FSM-command layer (revocation + CA-rotation records) can be
      developed in parallel with `truststore.go` itself, converging when
      `routes_mtls.go` wires an FSM-applied event to an actual
      `TrustStore.Update*` call.

### Human Checkpoints

1. After `truststore.go` + the refactored verification closure lands —
   verify a real revoked certificate is really rejected by a real running
   node, with every pre-existing `internal/mtls`/`internal/raft` test
   (T012, T049, T050 series) still passing unmodified.
2. After live cert renewal (`GetCertificate`/`GetClientCertificate`
   wiring) lands — verify zero dropped in-flight connections during a
   real renewal on a real multi-node cluster.
3. After CA rotation (dual-trust transition + finalize) lands — verify a
   real multi-node cluster never drops below quorum across a full
   rotation cycle.
4. Before folding into `specs/001-llmctl-completion`'s Follow-up Work
   section — full `go vet`/`gofmt`/`go test ./...` clean, zero
   regressions, independent review.

### Review Gates

- [ ] `truststore.go`'s concurrency safety: review specifically against
      the T073 concurrent-map-write defect class already found once in
      this codebase's Raft-adjacent state.
- [ ] The quorum-protection check (FR-010): review for the exact edge
      case spec.md names (a revocation/finalization that would strand the
      cluster) — this is a safety-critical refusal path, not merely a
      nice-to-have warning.
- [ ] `routes_mtls.go`'s authorization: review that only appropriately
      privileged operators can trigger revoke/rotate actions, reusing the
      existing RBAC mechanism (never a new, parallel authorization
      concept for this one subsystem).

## Complexity Tracking

*No unjustified Constitution violations — table intentionally empty.*
