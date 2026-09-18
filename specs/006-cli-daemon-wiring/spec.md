# Feature Specification: bash-CLI to Go-daemon Cluster/Tenant/Apikey Wiring

**Feature Branch**: `006-cli-daemon-wiring`

**Created**: 2026-09-18

**Status**: Draft

**Input**: User description: "Wire bin/llmctl's cluster/tenant/apikey subcommands to the real llmctld daemon: cluster join/leave, apikey create/rotate, and tenant create already have real, tested backend HTTP routes that bin/llmctl currently never calls - it hard-dies with 'not yet implemented' for all of them despite lib/cluster.sh already having a working, tested thin HTTP client (cluster::request) used successfully by the one already-wired command, 'cluster status'. tenant list and tenant quota have NO existing backend route at all - the underlying per-tenant quota enforcement logic already exists and is tested, but nothing exposes it over HTTP for an operator to view or list - this feature must add that missing route surface too, not just bash-side wiring, or it will leave two of the seven target commands as bluffed completions. Every wired command must be tested against a real running llmctld instance (not a mock), covering both the success path and the daemon-unreachable hard-fail path, and must not weaken the existing hard-fail-never-silent-fallback guarantee."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - An operator can actually join, leave, and inspect a cluster from the CLI they already use (Priority: P1)

An operator who has `llmctld` running wants to add this node to a cluster, later remove it, and confirm the cluster's state — all through the same `llmctl` command they already use for everything else. Today, `llmctl cluster join` and `llmctl cluster leave` refuse to run at all, even though the daemon they would talk to already implements both operations and `llmctl cluster status` already proves the connection works.

**Why this priority**: This is the most consequential gap — an operator cannot use the cluster feature set at all through the documented entry point, regardless of how complete the underlying daemon is.

**Independent Test**: With a real `llmctld` instance running, run `llmctl cluster join <peer>` against it and confirm the node actually joins (visible in the cluster's own node list), then `llmctl cluster leave` and confirm it actually leaves.

**Acceptance Scenarios**:

1. **Given** a running `llmctld` accepting join requests, **When** an operator runs `llmctl cluster join <peer-addr>`, **Then** the node genuinely joins the cluster, confirmed by querying the cluster's own node list afterward.
2. **Given** a node that has joined a cluster, **When** an operator runs `llmctl cluster leave`, **Then** the node genuinely leaves, confirmed by the same node-list query no longer listing it.
3. **Given** no `llmctld` is reachable, **When** an operator runs `llmctl cluster join` or `llmctl cluster leave`, **Then** the command fails loudly with a clear "daemon unreachable" message and makes no change to any local or cluster state — never a silent fallback to single-host behavior.

---

### User Story 2 - An operator can create and manage API keys without leaving the CLI (Priority: P1)

An operator wants to issue a new API key for a service account and later rotate it, using `llmctl` rather than crafting raw HTTP requests to the daemon by hand.

**Why this priority**: API keys gate access to the cluster's other capabilities; being unable to manage them through the CLI forces every operator onto a manual, undocumented, error-prone path.

**Independent Test**: With a real `llmctld` instance running and valid operator credentials, run `llmctl apikey create <scope>` and confirm a genuinely new, usable key is returned; run `llmctl apikey rotate <key-id>` on it and confirm the old key stops working while the new one works.

**Acceptance Scenarios**:

1. **Given** a running `llmctld` and valid operator credentials, **When** an operator runs `llmctl apikey create <scope>`, **Then** a real key is issued and is usable for a request in that scope.
2. **Given** an existing API key, **When** an operator runs `llmctl apikey rotate <key-id>`, **Then** the old key genuinely stops authenticating and the new key genuinely does.
3. **Given** no `llmctld` is reachable, **When** either command is run, **Then** it fails loudly with the same clear "daemon unreachable" message, no partial or ambiguous state left behind.

---

### User Story 3 - An operator can create, list, and inspect tenant quotas from the CLI (Priority: P2)

An operator wants to create a new tenant namespace and later check what quota that tenant (and every other tenant) currently has, again through `llmctl` rather than a separate tool.

**Why this priority**: Tenant creation already has a backend route and is a smaller gap than P1; tenant listing and quota inspection require new backend work first, making this priority 2 — valuable, but appropriately sequenced after the daemon-side work it depends on.

**Independent Test**: With a real `llmctld` instance running, run `llmctl tenant create <name>` and confirm the tenant exists afterward via `llmctl tenant list`; run `llmctl tenant quota <name>` and confirm it reports that tenant's real, currently-enforced quota values (not placeholder or default-looking numbers unless that tenant genuinely has defaults).

**Acceptance Scenarios**:

1. **Given** a running `llmctld`, **When** an operator runs `llmctl tenant create <name>`, **Then** the tenant genuinely exists afterward, confirmed by `llmctl tenant list` showing it.
2. **Given** one or more tenants exist, **When** an operator runs `llmctl tenant list`, **Then** every genuinely-existing tenant is shown, and none that don't exist are shown.
3. **Given** a tenant with a known, currently-enforced quota, **When** an operator runs `llmctl tenant quota <name>`, **Then** the reported values match what the daemon is actually enforcing for that tenant right now (proven by driving that tenant's real request-rate against the enforcer and observing the reported ceiling is the one actually applied), not a value read from a different, potentially stale source.

---

### Edge Cases

- What happens when the daemon is reachable but returns an unexpected/malformed response to a request (e.g. a partial JSON body from a request that was interrupted mid-response)? The CLI must report this as a distinct failure from "daemon unreachable", never silently treat it as success.
- What happens when an operator's credentials are valid for `cluster status` (unauthenticated) but not authorized for a specific action (e.g. `apikey create`, which requires a JWT)? The failure must clearly distinguish "unauthenticated/unauthorized" from "daemon unreachable" and from "daemon returned an application error".
- What happens when `llmctl cluster join` is run against a peer address that is reachable but is not actually running `llmctld` (e.g. a typo pointing at an unrelated service)? The failure must be attributable to the real cause, not misreported as a generic timeout.
- What happens when `tenant quota` is queried for a tenant name that does not exist? It must report "tenant not found", never a default/zero value that could be mistaken for a real, intentional zero quota.
- What happens if two operators run `llmctl apikey rotate` on the same key-id concurrently? The daemon's own concurrency behavior (whichever it already is) must be surfaced honestly to the CLI user, not papered over by the CLI pretending only one request happened.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `llmctl cluster join <peer-addr>` MUST make a real request to the daemon's existing join capability and report genuine success or failure based on the daemon's real response, never a hardcoded "not yet implemented" refusal.
- **FR-002**: `llmctl cluster leave` MUST make a real request to the daemon's existing leave capability and report genuine success or failure the same way.
- **FR-003**: `llmctl apikey create <scope>` MUST make a real request to the daemon's existing key-issuance capability and return the genuinely-issued key to the operator.
- **FR-004**: `llmctl apikey rotate <key-id>` MUST make a real request to the daemon's existing key-rotation capability and report genuine success or failure.
- **FR-005**: `llmctl tenant create <name>` MUST make a real request to the daemon's existing tenant-creation capability and report genuine success or failure.
- **FR-006**: The daemon MUST expose a new capability to list every currently-existing tenant, and `llmctl tenant list` MUST call it and display genuinely current results.
- **FR-007**: The daemon MUST expose a new capability to report a specific tenant's currently-enforced quota values, and `llmctl tenant quota <name>` MUST call it and display genuinely current results — sourced from the same enforcement state the daemon actually applies to that tenant's requests, not a separately-tracked copy that could drift.
- **FR-008**: Every one of the five newly-wired commands (join, leave, apikey create, apikey rotate, tenant create) plus the two newly-added ones (tenant list, tenant quota) MUST hard-fail with a clear, distinct "daemon unreachable" message when `llmctld` cannot be reached, exactly matching the existing behavior of `cluster status` — never a silent fallback to any other behavior.
- **FR-009**: Every one of these seven commands MUST distinguish, in its failure reporting, between "daemon unreachable", "request rejected due to authentication/authorization", and "daemon reachable but returned an application-level error" — an operator must never have to guess which of the three occurred.
- **FR-010**: None of the newly-wired commands MUST alter the single-host (non-cluster) scheduling behavior of `llmctl` in any way when cluster mode is not in use.

### Key Entities

- **Cluster Membership**: A node's join/leave state within the cluster, already tracked and enforced by the daemon's existing Raft-backed cluster logic; this feature only adds a real CLI path to read and change it.
- **API Key**: A credential the daemon already knows how to issue and rotate; this feature only adds a real CLI path to those existing operations.
- **Tenant**: A namespace the daemon already knows how to create; this feature adds both a real CLI path to that existing operation, and a NEW way (both daemon-side and CLI-side) to list existing tenants and inspect one tenant's currently-enforced quota.
- **Tenant Quota**: The per-tenant request-rate ceiling the daemon's existing quota enforcer already applies internally; this feature makes that already-enforced value visible to an operator for the first time.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: All seven target commands (`cluster join`, `cluster leave`, `apikey create`, `apikey rotate`, `tenant create`, `tenant list`, `tenant quota`) complete a real, successful round trip against a real running daemon in under 5 seconds each under normal conditions.
- **SC-002**: 100% of the seven commands, when run against an unreachable daemon, fail with the same clearly-worded "daemon unreachable" message within the existing request timeout, with zero silent fallback to any other behavior.
- **SC-003**: For `tenant quota`, the value reported by the CLI matches the value actually enforced against that tenant's real traffic in 100% of tested cases — verified by driving requests against the enforcer and comparing the observed ceiling to the reported one.
- **SC-004**: Zero regressions in the pre-existing, already-working `cluster status` command or in single-host (non-cluster) scheduling behavior, confirmed by the full pre-existing test suite passing unchanged.
- **SC-005**: An operator can complete the full cycle — create a tenant, list it, create an API key, join a cluster, inspect quota, rotate the key, leave the cluster — entirely through `llmctl`, without hand-crafting a single raw HTTP request.

## Assumptions

- The daemon's existing routes for join/leave/apikey-create/apikey-rotate/tenant-create are stable and their request/response shapes will not need to change to be called from bash; this feature is additive on the daemon side only for the two genuinely-missing tenant-list/tenant-quota routes.
- Authentication for the daemon-facing commands reuses the existing `LLMCTL_CLUSTER_TOKEN` bearer-token mechanism `lib/cluster.sh` already documents; this feature does not introduce a new credential type.
- "Currently-enforced quota" means the value the daemon's in-memory/persisted enforcer state holds at query time, not a configuration file that might not yet be applied.
- This feature does not change how tenants, keys, or cluster membership are represented internally on the daemon side beyond adding the two new read-only routes — it does not restructure existing storage.
