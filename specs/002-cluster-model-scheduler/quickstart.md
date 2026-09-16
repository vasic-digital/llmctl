# Quickstart: Validating Cluster-Wide Model-Placement Scheduling

Prerequisites: a built `llmctld` binary from this repository (`go build
./llmctld/cmd/llmctld`), and (for real, non-`LLMCTL_DRY_RUN` validation) a
real `bin/llmctl` checkout each node's `LocalExecutor` shells out to.

## Scenario 1 — Automatic placement onto the node with room (User Story 1, SC-001)

1. Bootstrap a 3-node cluster on loopback, exactly as
   `test/integration/cluster_bootstrap_test.go`'s `testCluster` harness
   already does (`cluster bootstrap` on node A, `cluster join` for nodes
   B and C, each supplying its real hardware-probe-derived `Resources` per
   the extended join contract).
2. Confirm via `GET /v1/cluster/nodes` (or the extended `/v1/cluster/status`)
   that all three nodes' real resource capacity is genuinely visible in
   `ClusterState.Nodes` — the foundational check this feature's Human
   Checkpoint 1 requires before anything else is meaningful.
3. Issue `POST /v1/tenants/:id/models/small/start` with NO `node` field.
4. **Expected**: the response names the node that accepted the work; that
   node's own `bin/llmctl status` (under `LLMCTL_DRY_RUN=1`) shows `small`
   running; the other two nodes do not.

## Scenario 2 — Budget refusal with exact shortfall (SC-002)

1. Same 3-node cluster, but issue a start request for a profile whose
   footprint exceeds every node's current advertised remaining capacity
   (use `LLMCTL_FAKE_HW` fixtures, matching the existing hardware-fixture
   pattern in `tests/fixtures/`, to make every node's advertised capacity
   deterministic and controllable).
2. **Expected**: `insufficient_capacity` response, `considered` lists all 3
   nodes with their real shortfall numbers; no node actually attempted to
   start anything (verify via each node's own status).

## Scenario 3 — Name-only status/stop across the cluster (User Story 2, SC-003)

1. Start `small` automatically (Scenario 1) — note which node it landed on
   without recording it anywhere the test itself tracks.
2. Query `GET /v1/tenants/:id/models/small/status` with no `node` — assert
   the response identifies the real hosting node and its real status.
3. Issue `POST /v1/tenants/:id/models/small/stop` with no `node` — assert
   the response identifies the same node, and that node's own status
   confirms `small` is no longer running.
4. Query `GET /v1/cluster/status` — assert `running_profiles` reflects the
   post-stop state (empty for `small`).

## Scenario 4 — Concurrent placement never double-books a node (User Story 3, SC-004)

1. Configure fixtures so exactly one node has room for profile X and a
   DIFFERENT specific node has room for profile Y (neither fits on the
   third, and X does not fit where Y fits and vice versa).
2. Fire both start requests concurrently (e.g. via two goroutines each
   issuing a real HTTP/3 request at the same time, matching the concurrency
   pattern the existing lock tests (`TestAcquire_SecondCallerBlocksUntilRelease`)
   already use for proving Raft-Apply-based serialization).
3. **Expected**: both succeed, X lands on its correct node, Y lands on its
   correct node — never both on the same node, never a refusal for either.

## Scenario 5 — Placement decision is auditable (SC-005)

1. After Scenario 1's start, inspect the recorded `PlacementDecision` via
   `internal/audit/log.go`'s existing audit-record retrieval path.
2. **Expected**: the record names the chosen node, every considered node's
   capacity at decision time, and a human-readable reason — reconstructable
   without querying any node's LIVE state (the whole point of an audit
   record, per data-model.md's `PlacementDecision` persistence note).

Every scenario above is written to become the acceptance-scenario basis
for `llmctld/test/integration/cluster_placement_test.go`
(`Execution Strategy` in plan.md) — this file is validation guidance, not
a duplicate of that test's actual Go source.
