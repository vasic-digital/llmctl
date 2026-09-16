# Phase 0 Research: mTLS Certificate and CA Rotation with Revocation

No `[NEEDS CLARIFICATION]` markers remain. Decisions below were resolved by
reading the real source before writing the plan.

## Decision 1: Revocation via an in-memory, Raft-replicated serial-number set — not CRL/OCSP

**Decision**: Revocation is checked by looking up the presented
certificate's serial number against a small, Raft-replicated
"currently-revoked" set inside the existing `VerifyPeerCertificate`
closure, rather than implementing a standards-based CRL or OCSP responder.

**Rationale**: Spec.md's actual requirement is narrower than "publish a
revocation status externally" — it is "every OTHER NODE IN THIS CLUSTER
rejects it" (FR-001). Every relying party here IS already a cluster member
participating in the same Raft-replicated state; there is no external,
non-cluster-member relying party this codebase needs to serve a CRL/OCSP
response to. Building a full CRL/OCSP stack would be solving a problem
this project does not have, at real implementation cost, for zero
additional spec-required capability.

**Alternatives considered**: A standards-based CRL distribution point (the
CA periodically publishing a signed revocation list nodes fetch) was
considered and rejected — it would require this feature to invent a
SECOND coordination/distribution channel exactly where spec.md's FR-002/
FR-014 forbid one, when the existing Raft-replicated `ClusterState` (the
single source of truth every node already trusts for cluster facts)
already solves "get every node to durably agree on a fact."

## Decision 2: `crypto/tls`'s dynamic-callback fields are the correct, standard mechanism for zero-downtime rotation

**Decision**: Refactor `internal/api/server.go`'s (and any other
`tls.Config`-constructing site's) certificate wiring from a static
`Certificates []tls.Certificate` field to the `GetCertificate`/
`GetClientCertificate` callback fields Go's own `crypto/tls` package
exposes specifically for this purpose; similarly keep
`VerifyPeerCertificate` as a closure (already the existing shape, per
`VerifyPeerCertificateAgainstCA`) but make its DATA source
live-mutable.

**Rationale**: This is Go's own documented mechanism for exactly this
problem (a long-lived server that needs to serve a different certificate
without restarting/rebinding its listener) — confirmed against the real
`crypto/tls` package's own documented behavior for these fields (each is
invoked fresh on every new handshake, exactly like
`VerifyPeerCertificate` already is in this codebase per
`transport.go`'s existing, working use of it). No third-party library or
custom listener-swap mechanism is needed.

**Alternatives considered**: Tearing down and rebuilding the entire
`tls.Config`/listener on every renewal was considered and rejected — it
would risk exactly the "abruptly severs existing connections" failure
mode spec.md's Acceptance Scenario 2 (User Story 2) explicitly forbids,
since a listener rebuild is a much coarser, connection-disrupting
operation than swapping what a per-handshake callback returns.

## Decision 3: Coordination reuses the existing Raft FSM — same reasoning as 002/003

**Decision**: `RevocationRecord`/`CARotationEvent` are new Raft-replicated
records, applied via new FSM commands, exactly matching how 002's node
registry and 003's replication-role assignment are each added.

**Rationale**: Identical reasoning to 002's research.md Decision 2 and
003's research.md Decision 2 — one existing, already-race-safety-proven
consensus mechanism, never a second one, per this feature's own FR-002/
FR-014 (which state the constraint explicitly, unlike 002/003 where it was
inferred from "no reinventing what exists").

**Alternatives considered**: None seriously — this is the third feature
in this same planning session to independently arrive at "extend the
existing `ClusterState`/FSM, do not invent a parallel one," which is
itself a signal this is the structurally correct answer for this
codebase's architecture, not a coincidence.

## Decision 4: Revocation is keyed by certificate serial number, independent of node ID

**Decision**: A `RevocationRecord` names a certificate's serial number
(from `x509.Certificate.SerialNumber`, already generated per-issuance by
`certs.go`'s `randomSerial()`), not a node ID.

**Rationale**: Spec.md FR-012 requires revocation to be independent of
cluster-membership eviction — a node whose certificate was revoked because
its key was compromised should be able to be RE-ISSUED a fresh certificate
(new serial number, same node ID, same membership record) and continue
participating, without the revocation record needing to somehow "expire"
or be manually cleaned up in a way that conflates "this specific
certificate is untrusted" with "this node is untrusted forever." Keying by
serial number makes this distinction structurally clean: the OLD serial
stays revoked forever; the NEW serial, once issued, was never listed.

**Alternatives considered**: Keying by node ID (revoking "node X"
generically, applying to whichever certificate node X currently presents)
was considered and rejected — it would make "revoke, then re-issue a
clean replacement" impossible to express (the re-issued certificate would
still be blocked, since the block was keyed to the node identity, not the
compromised key material specifically).
