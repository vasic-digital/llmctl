# Phase 1 Data Model: mTLS Certificate and CA Rotation with Revocation

## `mtls.TrustStore` (new — the live, mutex-protected verification data source)

Not Raft-replicated itself — it is the LOCAL, per-process, in-memory
structure each node's own TLS callbacks read from; it is kept in sync with
the Raft-replicated records below by an event handler that updates it
whenever the FSM applies a relevant command (mirroring how `health.go`'s
`Monitor` already reacts to replicated state changes elsewhere in this
codebase).

| Field | Type | Notes |
|---|---|---|
| `mu` | `sync.RWMutex` | Guards every field below — read on every handshake (`RLock`), written on every FSM-driven update (`Lock`), matching `internal/raft/fsm.go`'s own documented `ClusterFSM.mu` rationale for the identical concurrency shape. |
| `trustedCAPools` | `[]*x509.CertPool` | Exactly one entry in steady state; exactly two during a CA-rotation transition (old + new, per FR-008). A presented certificate chaining to ANY pool in this slice is chain-valid. |
| `revokedSerials` | `map[string]struct{}` (keyed by `SerialNumber.String()`) | Checked FIRST, before chain validation — a revoked serial is rejected regardless of which pool it would otherwise chain to. |
| `currentNodeCert` | `*tls.Certificate` | This node's own currently-active certificate+key, read by `GetCertificate`/`GetClientCertificate` callbacks — swapped in place on renewal (User Story 2), never requiring a new `tls.Config`. |

Methods: `UpdateRevoked(serials map[string]struct{})`,
`UpdateTrustedCAs(pools []*x509.CertPool)`, `UpdateNodeCert(cert
*tls.Certificate)` — each takes the lock, replaces the field, releases.
`Verify(rawCerts [][]byte) error` — the actual logic
`VerifyPeerCertificateAgainstCA` now delegates to: parse the leaf
certificate, reject immediately if its serial is in `revokedSerials`,
otherwise verify the chain against the CURRENT `trustedCAPools` (any one
of them).

## `cluster.RevocationRecord` (new, Raft-replicated)

| Field | Type | Notes |
|---|---|---|
| `SerialNumber` | `string` | The revoked certificate's serial (research.md Decision 4). |
| `NodeID` | `string` | Informational — which node this certificate was issued to, for operator visibility (spec.md FR-004/FR-013); NOT used as the revocation key itself. |
| `Reason` | `string` | Operator-supplied (e.g. "suspected key compromise"). |
| `RevokedBy` | `string` | Who/what triggered it (spec.md FR-013 auditability). |
| `RevokedAt` | `time.Time` | Carried in the log entry, computed once by the proposer (matching every other timestamp-carrying command in `fsm.go`). |

## `cluster.CARotationEvent` (new, Raft-replicated)

| Field | Type | Notes |
|---|---|---|
| `OutgoingCAFingerprint` | `string` | Identifies the CA being retired (a stable hash of its cert, not the full PEM — the full CA cert/key material is distributed via the existing out-of-band mechanism `-ca-cert`/`-ca-key` already uses, per plan.md's Constraints; the Raft-replicated record coordinates STATE about the rotation, never the CA private key material itself, which must never travel through the general-purpose replicated log). |
| `IncomingCAFingerprint` | `string` | Identifies the new CA. |
| `TransitionedNodeIDs` | `[]string` | Which nodes have confirmed re-issuance under the incoming CA so far (spec.md FR-009/SC-004 visibility). |
| `Status` | `string` (`"in_progress"\|"finalized"`) | `finalized` means the outgoing CA is no longer trusted anywhere (an operator-explicit action, never an automatic timeout, per FR-009). |
| `BegunAt`, `FinalizedAt` | `time.Time` (the latter zero-value until finalized) | |

**Security note**: the CA's own private key material is deliberately
NEVER placed in `CARotationEvent` or any other Raft log entry — Raft's
replicated log is durable and readable by every node's own storage, which
is the correct trust boundary for cluster-membership/health/revocation
FACTS but the wrong one for a root private key. The incoming CA's actual
key material is distributed via the same out-of-band mechanism
(`-ca-cert`/`-ca-key` files) the existing bootstrap flow already uses —
this feature's Raft-replicated state is purely COORDINATION metadata
("here is what stage of rotation we are at, and who has transitioned"),
never the secret itself.

## Relationship to existing entities

- `RevocationRecord`/`CARotationEvent` live alongside 002's `Node`/
  `RunningProfile` and 003's `ReplicationRole` in whichever `ClusterState`
  shape is current at implementation time — additive, independently
  keyed, no shared fields to conflict over.
- `mtls.TrustStore.currentNodeCert` replaces the STATIC `tls.Certificate`
  currently baked into `internal/api/server.go`'s/`internal/raft/transport.go`'s
  `tls.Config.Certificates` field construction — the ONE existing piece of
  state this feature changes the shape of (from static to
  dynamically-read), per plan.md's Project Structure.
