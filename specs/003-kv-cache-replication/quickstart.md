# Quickstart: Validating Cross-Node KV-Cache Replication

## Scenario 1 — Failover recovers state with zero manual fan-out (User Story 1, SC-001)

1. Bootstrap a real 3-node cluster (reusing `cluster_bootstrap_test.go`'s
   `testCluster` harness).
2. Append + checkpoint real token data to the tenant's replicated stream
   on whichever node is currently primary — via the NORMAL
   `/v1/replication/append`/`checkpoint` calls a real client would make,
   NOT via any test-side fan-out to the other two nodes (the literal
   negation of `failover_state_test.go`'s currently-disclosed workaround).
3. Confirm (before any failure) that the OTHER two nodes' own
   `/v1/replication/state` already shows the same data — proving the
   daemon forwarded it automatically.
4. Kill the primary; confirm the newly-elected primary (per the
   reassignment mechanism) already has the full state with zero data
   loss, matching T062's own already-proven 0% loss bar.

## Scenario 2 — Replica unreachability is retried and visible, never silently dropped (Edge Cases, SC-005)

1. Same cluster; block network reachability to one replica.
2. Append further data on the primary.
3. Query replication-lag (Scenario 4) — assert the blocked replica shows a
   real, non-zero lag, never silently reported as caught up.
4. Restore reachability; confirm the replica catches up and lag returns to
   zero.

## Scenario 3 — Real engine cache warm-restore, strictly optional (User Story 2, SC-003/SC-004)

1. Start a real GGUF profile with the new opt-in `--slot-save-path`
   launch parameter enabled.
2. Drive a long-enough real conversation through it so recomputation from
   scratch is not already near-instant.
3. Trigger a checkpoint; confirm the engine's real cache file is saved and
   (per the transfer mechanism) becomes available on a second node.
4. Fail over to that second node; measure real time-to-first-response with
   the cache file present versus (a separate run) with it deliberately
   made unavailable — confirm the with-cache-file run is measurably
   faster (SC-004), and confirm BOTH runs correctly recover the
   conversation's content (SC-003's "recovery latency is governed only by
   the token-sequence path" — i.e., the WITHOUT-cache-file run must still
   succeed, just slower, never fail).

## Scenario 4 — Replication health is queryable (User Story 3, SC-002)

1. Query the new replication-health endpoint for a tenant with all
   replicas caught up — assert zero lag reported for every node.
2. Repeat during Scenario 2's blocked-replica window — assert the exact
   behind replica and its real lag amount are named.
