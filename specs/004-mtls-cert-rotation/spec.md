# Feature Specification: mTLS Certificate and CA Rotation with Revocation

**Feature Branch**: `004-mtls-cert-rotation`

**Created**: 2026-09-15

**Status**: Draft

**Input**: User description: "mTLS certificate and CA rotation with revocation: closes T012/T075's disclosed boundary. Today internal/mtls/certs.go issues a fresh self-signed CA at cluster bootstrap and every node's own leaf certificate once at process startup, both with a fixed 1-year validity; certs are loaded once into the process's TLS configuration and never reloaded, refreshed, or replaced for the life of the process. There is no certificate rotation mechanism, no live reload, and no revocation mechanism of any kind - a node whose private key is compromised, or a leaf certificate that needs to be replaced for any reason, cannot be invalidated before its natural 1-year expiry, and there is no mechanism to rotate the shared CA itself without manually regenerating and manually redistributing to every node, with no documented process for doing so without an availability-impacting full-cluster restart. This feature must add: (1) a way to issue a replacement leaf certificate for a running node before its current one expires or is suspected compromised, without requiring that node or the cluster to go offline; (2) a way to revoke a specific node's certificate so it is rejected by every other node's mTLS verification immediately; (3) a way to rotate the CA itself when needed, propagated to every node's trust store without an availability-impacting full-cluster outage."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Revoke a compromised node's certificate immediately (Priority: P1)

An operator discovers (or suspects) that one cluster node's private key has
been compromised. They need every other node in the cluster to stop
trusting that node's certificate right now — not after a slow manual
per-node reconfiguration, and not only after that certificate's natural
expiry up to a year later.

**Why this priority**: This is the highest-severity gap: a compromised key
is an active security incident, and the current system has no way to
respond to one short of manually reconfiguring and restarting every node
in the cluster (which is itself the "availability-impacting full-cluster
outage" this feature exists to avoid needing).

**Independent Test**: Can be fully tested by revoking one node's
certificate identity and confirming every other real node in a live
cluster genuinely rejects a connection attempt presenting that identity
immediately afterward, while the rest of the cluster keeps operating
normally throughout.

**Acceptance Scenarios**:

1. **Given** a healthy multi-node cluster, **When** an operator revokes a
   specific node's certificate identity, **Then** every other node in the
   cluster rejects any new connection attempt presenting that identity,
   without needing to be individually reconfigured or restarted.
2. **Given** a node's certificate has just been revoked, **When** that
   same node (using its old, now-revoked identity) attempts to rejoin or
   communicate with the cluster, **Then** it is refused, and the refusal
   is visible to an operator (not a silent, unexplained connection
   failure).
3. **Given** a revocation has been issued, **When** an operator checks
   whether it actually took effect across the whole cluster, **Then** they
   can see confirmation that every currently-reachable node has applied
   the revocation, and which (if any) have not yet confirmed it.

---

### User Story 2 - Renew a node's certificate before it expires, with zero downtime (Priority: P1)

An operator running a long-lived cluster wants a node's certificate
replaced with a fresh one before its validity period runs out — whether
because it is approaching expiry, because the operator wants to shorten
the effective validity window as a security hardening measure, or simply
as routine hygiene — without taking that node offline or disrupting the
cluster's ongoing operation.

**Why this priority**: Equally severe in a different way: without this,
every certificate in the cluster is a ticking clock toward an
availability-impacting event (an expired certificate that can no longer
authenticate at all), and the only currently-documented remedy is a full
manual redo of the affected node.

**Independent Test**: Can be fully tested by issuing a node a replacement
certificate while it continues serving live cluster traffic, confirming
the node adopts the new certificate for all NEW connections without
dropping its existing ones, and confirming the old certificate identity
stops being used going forward.

**Acceptance Scenarios**:

1. **Given** a running node's certificate is nearing expiry, **When** an
   operator (or an automated policy) triggers a renewal for that node,
   **Then** the node begins presenting the fresh certificate for new
   connections without needing to be restarted or taken out of the
   cluster.
2. **Given** a renewal is in progress, **When** other nodes are already
   mid-connection with the node being renewed, **Then** those existing
   connections are not abruptly severed by the renewal itself.
3. **Given** a renewal has completed, **When** an operator checks that
   node's active certificate, **Then** it reflects the new one, with the
   old one no longer being presented for new connections.

---

### User Story 3 - Rotate the cluster's shared root of trust without an outage (Priority: P2)

An operator needs to replace the CA every node's trust ultimately depends
on — for example because a security policy mandates periodic root
rotation, or because the current CA's own key is suspected compromised
(the highest-severity version of this scenario) — and wants this to
happen as a coordinated, cluster-wide event that never requires taking the
whole cluster down at once.

**Why this priority**: This is the deepest, hardest, and least frequently
needed of the three capabilities (a compromised CA is a rarer, though more
severe, event than a single node's key needing replacement), which is why
it is P2 rather than P1 — but it closes the same class of gap at the root
of the trust chain rather than at one leaf.

**Independent Test**: Can be fully tested by introducing a new CA
alongside the existing one, confirming every node comes to trust BOTH
during a transition window, confirming every node's own certificate is
re-issued under the new CA during that window, and confirming the old CA
is fully retired afterward with the cluster never losing quorum or
availability at any point in the process.

**Acceptance Scenarios**:

1. **Given** an operator initiates a CA rotation, **When** the rotation
   begins, **Then** every node continues accepting connections signed by
   EITHER the old or the new CA for a transition period, so nodes that
   have not yet received their new certificate are not immediately cut off.
2. **Given** the transition period is in progress, **When** each node is
   individually re-issued a certificate under the new CA, **Then** the
   cluster as a whole never drops below the minimum number of
   simultaneously-reachable nodes needed to keep operating.
3. **Given** every node has been re-issued under the new CA, **When** an
   operator finalizes the rotation, **Then** the old CA is no longer
   trusted by any node, and an operator can confirm this finalization
   completed everywhere.

---

### Edge Cases

- What happens when a node is unreachable (temporarily partitioned, or
  genuinely down) at the moment a revocation or renewal is issued? The
  moment it becomes reachable again, it must learn of and apply any
  revocation/rotation event it missed before it is allowed to participate
  in the cluster again — never rejoin under a stale trust state.
- What happens if a CA rotation is initiated but not every node can be
  reached to receive its new certificate within a reasonable window
  (e.g., a node is down for an extended period)? The operator must be able
  to see which nodes have not yet transitioned, and the transition period
  must not auto-expire in a way that locks out a node that was legitimately
  offline through no fault of its own — finalizing the rotation is an
  explicit, operator-visible decision, not a silent timeout.
- What happens if an operator tries to revoke or rotate in a way that
  would leave the cluster without enough trusted nodes to maintain
  quorum/availability? The system must refuse (or clearly warn about) an
  action that would strand the cluster, rather than silently executing an
  action that breaks its own availability.
- What happens if two rotation/revocation events are issued concurrently
  (e.g., two operators, or an automated policy and a manual action, at the
  same time)? The system must resolve them consistently across every node
  — never have some nodes apply one order of events and other nodes apply
  a different order.
- What happens to a node's identity in the cluster's other
  membership/health records (the same records other features in this
  project rely on to know a node exists) when that node's certificate is
  revoked? Revocation is a trust-layer action; whether the node is also
  removed from cluster membership is a separate, distinct decision an
  operator makes independently — revoking trust must not silently also
  evict a node from membership records other parts of the system depend
  on, unless the operator explicitly also removes it.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST allow an operator to revoke a specific
  node's certificate identity such that every other reachable node in the
  cluster rejects a connection attempt presenting that identity, without
  requiring any node to be individually reconfigured or restarted to learn
  of the revocation.
- **FR-002**: A revocation MUST propagate to every node using the
  cluster's existing coordinated-state mechanism (the same mechanism
  already used to keep every node's view of cluster membership
  consistent) — it MUST NOT rely on a second, independent coordination
  channel that could disagree with the first about what has been decided.
- **FR-003**: A node that was unreachable when a revocation was issued
  MUST learn of it and apply it before being allowed to participate in the
  cluster again upon reconnecting — it MUST NOT be able to rejoin under a
  stale trust state that predates the revocation.
- **FR-004**: An operator MUST be able to see, for a given revocation or
  rotation event, which currently-reachable nodes have confirmed applying
  it and which have not.
- **FR-005**: The system MUST allow an operator (or an automated policy)
  to issue a running node a replacement certificate, and that node MUST
  begin using the replacement for new connections without being restarted
  or removed from the cluster.
- **FR-006**: Renewing a node's certificate MUST NOT abruptly terminate
  that node's already-established connections with other nodes solely
  because of the renewal itself.
- **FR-007**: The system MUST allow an operator to initiate rotation of
  the shared root of trust (the CA) as a coordinated, cluster-wide,
  multi-step process, never a single all-or-nothing action that could
  leave some nodes trusting a CA others no longer do without an explicit
  transition period.
- **FR-008**: During a CA rotation's transition period, every node MUST
  continue to accept connections authenticated under EITHER the outgoing
  or the incoming CA, so that a node not yet re-issued under the new CA is
  not cut off from the cluster.
- **FR-009**: An operator MUST be able to see which nodes have and have
  not yet been re-issued a certificate under the new CA during a
  transition period, and MUST explicitly finalize the rotation (retiring
  trust in the old CA) rather than have it happen on an automatic timeout
  that could strand a legitimately-offline node.
- **FR-010**: The system MUST refuse (or, at minimum, clearly and
  explicitly warn about) a revocation or CA-rotation-finalization action
  that would leave the cluster without enough trusted, reachable nodes to
  maintain its own operational quorum.
- **FR-011**: Concurrent or near-simultaneous revocation/rotation events
  MUST be resolved to the same final outcome on every node — the system
  MUST NOT allow different nodes to durably disagree about which
  revocation/rotation events have taken effect or in what order.
- **FR-012**: Revoking a node's certificate identity MUST be a distinct
  action from removing that node from the cluster's membership records —
  the system MUST NOT silently perform one as a side effect of the other.
- **FR-013**: Every revocation, renewal, and rotation action MUST be
  attributable and auditable after the fact (who/what triggered it, when,
  and what the outcome was), matching the same accountability bar this
  project's other security-sensitive actions already meet.
- **FR-014**: All of the above MUST be built on the cluster's existing
  internal certificate-authority mechanism and existing node-to-node
  authenticated communication channel — this feature MUST NOT introduce a
  second, competing trust or transport mechanism alongside them.

### Key Entities *(include if feature involves data)*

- **Revocation Record**: A durable, cluster-wide-agreed statement that a
  specific certificate identity is no longer trusted, from a specific
  point onward, with who/what issued it and why.
- **CA Rotation Event**: A durable, cluster-wide-agreed record of an
  in-progress or completed root-of-trust rotation: which CA is outgoing,
  which is incoming, which nodes have transitioned, and whether the
  rotation has been finalized.
- **Node Certificate Lifecycle State**: For a given node, which
  certificate identity it currently presents, when it was issued, its
  validity window, and whether a renewal or revocation is pending or has
  been applied.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A revoked node's certificate identity is rejected by every
  reachable node in the cluster, with no per-node manual reconfiguration
  step required to achieve that outcome.
- **SC-002**: A node can have its certificate renewed while remaining a
  fully participating, continuously-available member of the cluster
  throughout the process — zero cluster-visible downtime attributable to
  the renewal itself.
- **SC-003**: A full CA rotation can be completed across every node in the
  cluster without the cluster ever dropping below its minimum operational
  quorum at any point during the process.
- **SC-004**: An operator can determine, at any point during a
  revocation, renewal, or rotation event, exactly which nodes have and
  have not yet applied it, without needing to individually inspect each
  node.
- **SC-005**: Every revocation/renewal/rotation action taken is
  attributable after the fact — an operator reviewing the cluster's
  history can identify who/what triggered each one, when, and its outcome.

## Assumptions

- The existing internal certificate authority + per-node leaf-certificate
  issuance mechanism (already built and tested in this codebase) is reused
  as-is for actually generating replacement certificates; this feature
  does not redesign certificate issuance itself, only adds the missing
  lifecycle operations (revoke, renew-live, rotate-root) around it.
- The cluster's existing coordinated cluster-state mechanism (the same one
  already used to keep every node's view of membership/health consistent)
  is the correct, and only, mechanism used to propagate
  revocation/rotation decisions — this feature does not introduce a
  second coordination channel.
- "Minimum operational quorum" (FR-010/SC-003) is whatever threshold the
  cluster's existing consensus mechanism already requires to keep
  operating; this feature does not redefine that threshold, only respects
  it when deciding whether a revocation/finalization action is safe to
  allow.
- A node whose certificate is revoked is NOT automatically removed from
  cluster membership records (FR-012) — an operator who wants both
  performs both actions explicitly; this keeps the trust-layer action and
  the membership-layer action independently reasoned about, matching how
  this project already keeps related-but-distinct concerns (e.g., cluster
  membership vs. tenant authorization) in separate, composable mechanisms
  elsewhere in the codebase.
- CA rotation's transition period (the window during which both the old
  and new CA are simultaneously trusted) has no fixed, invented duration —
  it ends only on an explicit operator finalization action (FR-009),
  never an automatic timeout, since a timeout risks permanently locking
  out a node that was legitimately unreachable through no fault of its
  own.
- This feature is scoped to the cluster's internal node-to-node mTLS trust
  chain; client-facing authentication (the existing separate JWT/API-key
  mechanism this project already has for callers talking to the cluster's
  HTTP API) is a distinct, already-separately-governed concern this
  feature does not change.
