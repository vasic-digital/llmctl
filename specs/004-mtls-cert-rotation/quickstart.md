# Quickstart: Validating mTLS Certificate and CA Rotation with Revocation

## Scenario 1 — Revocation is really enforced, cluster-wide, with no restart (User Story 1, SC-001)

1. Bootstrap a real 3-node cluster (reusing the existing `testCluster`
   harness).
2. Confirm all 3 nodes communicate normally (a real HTTP/3+mTLS call
   between any two succeeds).
3. Revoke one node's certificate serial via the new operator-facing
   action.
4. Confirm — WITHOUT restarting any node — that a NEW connection attempt
   presenting that revoked identity is genuinely rejected by every OTHER
   real node, while the other two nodes continue operating normally with
   each other throughout.
5. Query revocation-propagation status; confirm every reachable node
   reports having applied it.

## Scenario 2 — Renewal never drops an in-flight connection (User Story 2, SC-002)

1. Same cluster; establish a long-lived real connection between two
   nodes (or hold one open across the renewal window).
2. Trigger a certificate renewal for one node while that connection is
   active.
3. Confirm the existing connection is NOT severed by the renewal itself.
4. Confirm a NEW connection attempt after renewal presents the fresh
   certificate (inspect the real presented cert's serial/validity).

## Scenario 3 — CA rotation never drops quorum (User Story 3, SC-003)

1. Bootstrap a real 3-node cluster under CA-1.
2. Begin a rotation to CA-2; confirm every node still accepts connections
   from peers still presenting CA-1-signed certificates during the
   transition (dual trust, FR-008).
3. Re-issue each node's certificate under CA-2 one at a time (never all
   simultaneously, matching real operational practice); after each
   re-issuance, confirm the cluster's real Raft leader election/quorum
   state never drops below its operational minimum at any point.
4. Once every node is transitioned, finalize the rotation; confirm a
   connection attempt presenting a CA-1-signed certificate is now
   genuinely rejected everywhere.

## Scenario 4 — Refusal when an action would strand the cluster (Edge Case, FR-010)

1. On a 3-node cluster, attempt to revoke/finalize in a way that would
   leave fewer trusted nodes than the cluster's real quorum requirement.
2. Confirm the action is refused (or clearly, explicitly flagged) rather
   than silently executed and stranding the cluster.
