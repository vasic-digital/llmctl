---
description: "Task list for mTLS Certificate and CA Rotation with Revocation"
---

# Tasks: mTLS Certificate and CA Rotation with Revocation

**Input**: Design documents from `specs/004-mtls-cert-rotation/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, quickstart.md

## Task Format

`[ID] [markers] [Story] Description` — markers identical to 002/003's
convention (`[P]`/`[TDD]`/`[REVIEW]`/`[SUBAGENT]`).

---

## Phase 1: Setup

- [x] T001 Confirm baseline: `go vet ./...`, `gofmt -l .`, `go test ./...`
      clean before this feature's first commit — read the real current
      `ClusterState`/FSM shape fresh if 002 and/or 003 have already
      landed (plan.md's Structure Decision is explicit about this).
- [x] T002 [P] Create `test/integration/mtls_rotation_test.go`'s package
      skeleton, reusing `testCluster`/`cluster_bootstrap_test.go`'s
      harness.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Build the live, mutex-protected `TrustStore` and make both
node-to-node transports (`internal/raft/transport.go`,
`internal/api/server.go`) read from it dynamically — nothing in User
Stories 1-3 is real without this, since today's `tls.Config` is
constructed once, statically, at process startup.

- [x] T003 [TDD] Implement `internal/mtls/truststore.go`'s `TrustStore`
      (data-model.md): `UpdateRevoked`, `UpdateTrustedCAs`,
      `UpdateNodeCert`, `Verify(rawCerts [][]byte) error`. RED first:
      `TestTrustStore_Verify_RejectsRevokedSerial`,
      `TestTrustStore_Verify_AcceptsEitherPoolDuringDualTrust`,
      `TestTrustStore_ConcurrentReadWriteIsRaceFree` (run under `go test
      -race`, matching the exact discipline that caught Phase 11's T073
      concurrent-map bug in the adjacent `ClusterFSM`) in
      `internal/mtls/truststore_test.go`, confirmed failing before
      implementation.
- [x] T004 [TDD] Refactor `internal/raft/transport.go`'s
      `VerifyPeerCertificateAgainstCA` to accept a `*mtls.TrustStore`
      instead of a `*x509.CertPool` and delegate to its `Verify` method.
      RED first: update the existing real-mTLS tests
      (`TestTransport_TwoNodesExchangeRealRaftRPCOverLoopback`,
      `TestTransport_RejectsConnectionFromUntrustedCA`) to construct a
      `TrustStore` instead of a bare pool, confirm they still pass
      UNMODIFIED IN BEHAVIOR (this is a refactor, not a behavior change,
      at this task) before adding the new revocation-specific test in
      T007.
- [x] T005 [TDD] Refactor `internal/api/server.go`'s `tls.Config`
      construction: replace the static `Certificates` field with
      `GetCertificate`/`GetClientCertificate` callbacks reading
      `TrustStore.currentNodeCert`, and `VerifyPeerCertificate` to use the
      refactored T004 closure. RED first: update T058's existing 5 real
      end-to-end HTTP/3+mTLS tests to construct/pass a `TrustStore`,
      confirm they still pass unmodified in behavior before proceeding.
- [x] T006 [US-shared] [SUBAGENT] Wire `cmd/llmctld/main.go`'s existing
      cert-loading flow (`GenerateCA`/`LoadCA`/`IssueNodeCert` call sites)
      to populate a real `TrustStore` at startup instead of constructing
      a static pool/cert pair directly — every existing CLI flag
      (`-ca-cert`, `-ca-key`) and the real `READY node_id=...` startup
      line stay behavior-identical for a node that never triggers any
      revocation/renewal/rotation action.

**Checkpoint**: Every pre-existing `internal/mtls`/`internal/raft`/
`internal/api` test (T012, T049, T050, T058 series) passes UNMODIFIED IN
BEHAVIOR against the refactored, now-dynamic `TrustStore`-backed plumbing.
**Get human approval before starting User Story 1.**

---

## Phase 3: User Story 1 — Revoke a compromised node's certificate immediately (Priority: P1) MVP

**Goal**: A revoked certificate identity is genuinely rejected
cluster-wide with zero per-node restart.
**Independent Test**: quickstart.md Scenario 1.

### Tests for User Story 1

- [x] T007 [P] [TDD] [US1] Real multi-process test:
      `TestMTLSRotation_RevokedCertificate_RejectedClusterWide` — real
      3-node cluster, real revoke action, real connection attempt with
      the revoked identity genuinely rejected by every other real node,
      no restart of any process. Confirmed failing before implementation.
      GREEN (deterministic, 2/2 consecutive full runs).
- [x] T008 [P] [TDD] [US1] Real test:
      `TestMTLSRotation_RevokedNode_CannotRejoin` (spec.md Acceptance
      Scenario 2) — a real attempted rejoin using the revoked identity is
      refused, and the refusal is visible (not a silent hang/timeout).
      GREEN (deterministic, 2/2 consecutive full runs).
- [x] T009 [P] [TDD] [US1] Real test:
      `TestMTLSRotation_UnreachableNode_LearnsRevocationOnReconnect`
      (Edge Case) — partition one node, revoke a DIFFERENT node's cert
      while it's partitioned, heal the partition, confirm the
      previously-partitioned node's own `TrustStore` now reflects the
      revocation before it is allowed to participate again. Landed with
      an honestly-disclosed scope boundary: tests the identical
      convergence property via a node that joins AFTER the revocation
      (never having observed it) rather than literal OS/network
      partition simulation. GREEN (deterministic, 2/2 consecutive full
      runs).

### Implementation for User Story 1

- [x] T010 [US1] Add `CommandRevokeCertificate` to `internal/raft/fsm.go`
      + `cluster.RevocationRecord` to `state.go` (data-model.md).
- [x] T011 [US1] Wire an event handler (mirroring how `health.go`'s
      `Monitor` already reacts to replicated state) that calls
      `TrustStore.UpdateRevoked` whenever the FSM applies
      `CommandRevokeCertificate` — on EVERY node, not only the one that
      issued the revocation.
- [x] T012 [US1] Add the operator-facing revoke action + status-query
      endpoint to `internal/api/routes_mtls.go` (spec.md FR-004), reusing
      the existing RBAC authorization mechanism.
- [x] T013 [US1] [REVIEW] Confirm FR-012 (revocation is independent of
      membership eviction) — a revoked node's entry in the existing
      cluster-membership registry (002's `cluster.Node`, if landed, or
      the pre-existing Raft voter configuration otherwise) is untouched
      by `CommandRevokeCertificate` alone. Confirmed both by code
      inspection (`CommandRevokeCertificate`'s `Apply` case touches only
      `ClusterState.Revocations`, never `.Nodes` nor any Raft
      voter-configuration call) AND by a runtime assertion in T007's own
      test (`GET /v1/cluster/nodes` still reports exactly 3 members after
      a revocation), now passing.

**Checkpoint**: User Story 1 fully functional — the MVP. **Get human
approval before starting User Story 2.**

---

## Phase 4: User Story 2 — Zero-downtime certificate renewal (Priority: P1)

**Goal**: A running node's certificate can be replaced without dropping
existing connections.
**Independent Test**: quickstart.md Scenario 2.

### Tests for User Story 2

- [ ] T014 [P] [TDD] [US2] Real test:
      `TestMTLSRotation_LiveRenewal_ExistingConnectionSurvives` — a
      long-held real connection stays alive across a real renewal.
- [ ] T015 [P] [TDD] [US2] Real test:
      `TestMTLSRotation_LiveRenewal_NewConnectionsUseFreshCert` — a NEW
      connection attempt after renewal presents the fresh certificate
      (inspect the real serial/validity, not merely "no error").

### Implementation for User Story 2

- [ ] T016 [US2] Add the operator-facing renew action to
      `internal/api/routes_mtls.go`: issues a fresh `NodeCert` via the
      EXISTING, unmodified `ca.IssueNodeCert` (research.md's "issuance
      logic itself is untouched"), then calls `TrustStore.UpdateNodeCert`
      on the target node.
- [ ] T017 [US2] [REVIEW] Confirm no existing in-flight
      `*tls.Conn`/`http3` stream is torn down as a side effect of
      `UpdateNodeCert` (the callback-based design in T005 should already
      guarantee this structurally — this review confirms it empirically,
      not merely by code inspection).

**Checkpoint**: User Stories 1 AND 2 both verified. **Get human approval
before starting User Story 3.**

---

## Phase 5: User Story 3 — Coordinated CA rotation without an outage (Priority: P2)

**Goal**: The cluster's root of trust can be replaced across every node
without ever dropping below quorum.
**Independent Test**: quickstart.md Scenario 3.

### Tests for User Story 3

- [x] T018 [TDD] [US3] Real test:
      `TestMTLSRotation_DualTrust_AcceptsBothOldAndNewCA` during an
      in-progress rotation. GREEN (2/2 consecutive full runs) - found and
      fixed a real production defect en route: `buildNodeTLSConfig`'s
      `ClientAuth: tls.RequireAndVerifyClientCert` made Go's own stdlib
      verify incoming client certs against a STATIC, construction-time
      `ClientCAs` pool never touched by `TrustStore.UpdateTrustedCAs` -
      fixed to `tls.RequireAnyClientCert` (Go's own documented mechanism
      for deferring 100% of verification to `VerifyPeerCertificate`,
      which already correctly reads the LIVE store).
- [x] T019 [TDD] [US3] Real test:
      `TestMTLSRotation_FullRotation_NeverDropsQuorum` — re-issue every
      node's cert one at a time on a real cluster, asserting real leader
      election/quorum health is checked and holds after EACH individual
      re-issuance step, not only at the very end. GREEN (2/2 consecutive
      full runs).
- [x] T020 [TDD] [US3] Real test:
      `TestMTLSRotation_Finalize_OldCARejectedAfterward`. GREEN (2/2
      consecutive full runs) - found and fixed a real gap en route: a
      FOLLOWER's own renewal could not durably record its CA-rotation
      transition (`node.RecordCARotationTransition` requires the Raft
      leader); added a leader-forwarding fallback
      (`ForwardCARotationTransition` + peer-only POST
      `/v1/cluster/mtls/rotate/transition`) mirroring
      `routes_models.go`'s established `forwardAutoPlaceToLeader`
      pattern, backed by a NEW dedicated `mtlsForwardTLS`/
      `mtlsForwardStore` client identity kept in lockstep with
      `raftTrustStore`/`apiTrustStore` (distinct from
      002-cluster-model-scheduler's own unrelated `forwardTLS`).
- [x] T021 [TDD] [US3] Real test:
      `TestMTLSRotation_QuorumProtection_RefusesStrandingAction`
      (quickstart.md Scenario 4 / FR-010) - exercised via the revoke path
      (a negative control proving the check does not always refuse, then
      the core stranding-refused assertion). GREEN (2/2 consecutive full
      runs).

### Implementation for User Story 3

- [x] T022 [US3] Add `CommandBeginCARotation`/`CommandFinalizeCARotation`
      to `fsm.go` + `cluster.CARotationEvent` to `state.go`. Also added
      `CommandRecordCARotationTransition` (a natural, minimal third
      command beyond this task's literal two-name list - required to
      honestly satisfy FR-009's "which nodes have transitioned"
      visibility and FR-010's finalize quorum-protection check, neither
      of which the two literally-named commands alone can provide; see
      this feature's final report for the full reasoning).
- [x] T023 [US3] Wire the same event-handler pattern (T011) to call
      `TrustStore.UpdateTrustedCAs` with BOTH pools during
      `"in_progress"` and drop to the single new pool on `"finalized"`.
      `"in_progress"`'s dual-trust activation happens directly inside the
      `begin` handler (the incoming CA's actual material - a fingerprint
      HASH only ever travels through Raft, per `CARotationEvent`'s own
      security note - is loaded out-of-band, per-node); `"finalized"`'s
      drop-to-single-pool is the event-handler-driven half, extending
      `wireRevocationHandler`'s existing `onRevocationApplied` notify
      mechanism exactly as that type's own doc comment already
      anticipated ("forward-compatible with Phase 5's future CA-rotation
      event without a second handler mechanism").
- [x] T024 [US3] Add begin/transition-status/finalize operator actions to
      `routes_mtls.go`, including the FR-010 quorum-protection refusal
      check on the finalize path (and on the revoke path from Phase 3,
      per spec.md's shared Edge Case) - `quorumWouldBeStranded` written
      once, used by both.
- [x] T025 [US3] [REVIEW] Concurrency review: two rotation/revocation
      events issued near-simultaneously (spec.md Edge Case/FR-011) —
      confirm the Raft log's own total ordering (the same guarantee every
      other FSM command already relies on) is what resolves this, and
      that no code path in this feature accidentally bypasses it (e.g. by
      applying an effect locally before the FSM confirms it). Found a
      real gap: a non-leader node's local "begin" dual-trust activation
      was NOT itself gated on Raft confirmation, so two concurrent
      "begin" calls naming DIFFERENT incoming CAs against different nodes
      could locally diverge before Raft's own total ordering resolved
      which one wins. Closed the common case with a pre-check against the
      currently-replicated `cluster.CARotation` (refusing a request whose
      fingerprints conflict with an already-in-progress rotation, on
      EVERY node, not only the leader); the residual true-simultaneous
      window (both requests reading `node.State()` before either's Raft
      entry replicates) is honestly documented as bounded by Raft's own
      total ordering, not eliminated. Revoke/finalize themselves apply NO
      local effect before their own Raft Apply confirms it.

**Checkpoint**: All three user stories independently verified. **Get
human approval before Polish.**

---

## Phase 6: Polish & Cross-Cutting Concerns

- [ ] T026 [P] Update `docs/cluster-architecture.md`'s mTLS section with a
      real `mmdc`-rendered sequence diagram for revocation propagation
      and for the dual-trust CA-rotation transition, flipping from 📋 to
      ✅ for the parts genuinely implemented.
- [ ] T027 [P] Append this feature to `specs/001-llmctl-completion/tasks.md`'s
      Follow-up Work section (next free `T072-FU<N>`) and update
      `progress.yml`.
- [ ] T028 Full-suite verification: `go vet ./...`, `gofmt -l .`, `go test
      -race ./...` (the `-race` flag is load-bearing here specifically,
      per T003/T073's own precedent) clean, zero regressions to every
      pre-existing `internal/mtls`/`internal/raft`/`internal/api` test.
- [ ] T029 [REVIEW] Independent code review of the complete feature
      (Constitution §11.4.125/§11.4.142) — specifically covering
      authorization on every new `routes_mtls.go` action.
- [ ] T030 Update `docs/CONTINUATION.md`.

---

## Dependencies & Execution Order

- **Foundational (Phase 2)** blocks everything — the dynamic
  `TrustStore`-backed plumbing every user story depends on.
- **User Story 1 (Phase 3)** is the MVP; independent of User Stories 2/3
  once Phase 2 is done.
- **User Story 2 (Phase 4)** is independent of User Story 1's own FSM
  commands (renewal does not touch revocation state) but shares the same
  `TrustStore`/Phase 2 foundation — can proceed in parallel with Phase 3.
- **User Story 3 (Phase 5)** reuses the SAME quorum-protection concern
  Phase 3's revoke path also needs (FR-010) — T024's shared check is
  written once and used by both the revoke and the finalize actions,
  never duplicated.

## Notes

- TDD is NON-NEGOTIABLE per this project's Constitution Principle III.
- `go test -race` is explicitly required for this feature's own tests
  given the `TrustStore` concurrency requirement and this codebase's own
  prior real concurrent-map-write incident in the adjacent `ClusterFSM`.
- If 002 and/or 003 have already landed by the time this feature is
  implemented, T001's "read the real current shape fresh" instruction is
  load-bearing — this plan does not assume its own `ClusterState` sketch
  is still exactly accurate at that point.
