# Feature Specification: llmctl Full Production Completion

**Feature Branch**: `001-llmctl-completion`

**Created**: 2025-09-15

**Status**: Draft

**Input**: User description: "We have project which has been already developed to certain extent and came to one of the development phases. Dive deep into all Markdown documentation we have in docs to get familiar what has been completed and what is not. We MUST bring the project to full completion - all features fully incorporated, covered with all supported test types (defined in constitution). Every test MUST produce machine rock-solid evidence which always be fully validated and verified fully deterministically! No false or faulty results is allowed, no any gaps, shortcomings, weak spots or danger zones! There MUST BE no AI slop or bluff in any form or of any kind ANYWHERE! Whole project MUST BE fully covered with exhaustive documentation, user guides and manuals, FAQs, tutorials, quick start guides. We MUST HAVE all possible diagrams, schemes, graphs and illustrations and all of it properly incorporated in all documentation we have! All constitution rules MUST BE followed, respected and applied! There MUST BE no violation, ignoring of them, skipping or avoiding! After everything is implemented, fully LIVE tested after setup and enabling of the systemctl --user space services and other components, validated and verified we should do first release of the project using GitHub and GitLab CLIs with properly written change and version logs! LIVE testing MUST really use models we run through all installed CLI agents available on current host where everything is being tested! All supported CLI agents MUST BE fully covered! Any missing CLI agent MUST BE installed using its curl (or other) setup mechanism, properly configured and tested against our running solution! Challenges against models ran by our solution MUST BE fully deterministic to prove everything working for real-world development and coding use-case scenarios!"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Complete Feature Implementation & Integration (Priority: P1)

**Description**: As a developer, I want all llmctl features (model download, hardware probing, scheduling, service management, multi-model co-residency) fully implemented and integrated so that the system works end-to-end without gaps.

**Why this priority**: Core functionality must be complete before any testing or release can occur.

**Independent Test**: Can be fully tested by running `make test` which executes the deterministic test harness covering all components.

**Acceptance Scenarios**:
1. **Given** a fresh clone of llmctl, **When** running `./bin/llmctl setup`, **Then** all engines build, hardware is probed, and model catalog is validated
2. **Given** a system with compatible GPU, **When** running `./bin/llmctl start fast`, **Then** llama-server starts on port 8080 and serves OpenAI-compatible API
3. **Given** multiple models downloaded, **When** running `./bin/llmctl auto coder vision`, **Then** co-residency is computed and services start if budgets allow

### User Story 2 - Deterministic Test Suite with Rock-Solid Evidence (Priority: P1)

**Description**: As a quality engineer, I want every test to produce machine-verifiable evidence (exit codes, raw output, JSON artifacts) so that pass/fail is objectively verifiable without human interpretation.

**Why this priority**: Anti-bluff covenant (Constitution §11.4) requires positive-evidence-only validation.

**Independent Test**: Each test file in `tests/` runs independently and produces parseable JSON/evidence logs.

**Acceptance Scenarios**:
1. **Given** `make test`, **When** executed, **Then** all test scripts print exact command, exit code, and raw output
2. **Given** a test failure, **When** re-run with same fixture, **Then** identical failure occurs (deterministic)
3. **Given** `LLMCTL_FAKE_HW=tests/fixtures/hw-baseline.json`, **When** `llmctl hw --json`, **Then** output matches fixture exactly

### User Story 3 - Exhaustive Documentation Suite (Priority: P2)

**Description**: As a user, I want complete documentation including quick start guides, tutorials, FAQs, user manuals, architecture diagrams, and API references so I can use llmctl without external help.

**Why this priority**: Documentation completeness is required by Constitution §6 and §11.4.11 (file-layout discipline).

**Independent Test**: Each documentation file can be validated for completeness and cross-referenced.

**Acceptance Scenarios**:
1. **Given** README.md, **When** inspected, **Then** contains quickstart, command reference, safety guarantees, and integration configs
2. **Given** docs/architecture.md, **When** inspected, **Then** contains Mermaid diagrams for data flow, memory model, scheduler state, service backends
3. **Given** docs/integrations.md, **When** inspected, **Then** contains configs for opencode, pi, crush, Claude Code, aider, continue.dev, Cline
4. **Given** docs/hardware-tiers.md, **When** inspected, **Then** contains tier rules, baseline reference, workstation, Apple Silicon, datacenter specs with diagrams

### User Story 4 - Live System Testing with Real Models & CLI Agents (Priority: P1)

**Description**: As a release engineer, I want to run live end-to-end tests with real downloaded models served through llmctl, accessed by all supported CLI agents (opencode, pi, crush, Claude Code, aider, continue.dev, Cline) to prove real-world coding use cases work.

**Why this priority**: Constitution §11.4.3 requires per-environment-topology test dispatch; live testing validates the full stack.

**Independent Test**: Each CLI agent can be configured and tested independently against a running llmctl service.

**Acceptance Scenarios**:
1. **Given** `llmctl start fast`, **When** opencode configured with baseURL `http://127.0.0.1:8080/v1`, **Then** opencode can complete a coding task using the local model
2. **Given** `llmctl start coder`, **When** aider configured with OPENAI_API_BASE, **Then** aider can edit files using the local model
3. **Given** `llmctl start colibri-qwen36`, **When** Claude Code with ANTHROPIC_BASE_URL, **Then** Claude Code can use native Anthropic API via colibri
4. **Given** missing CLI agent (e.g., pi), **When** installed via curl, **Then** pi can be configured and tested against running service

**Clarification**: Live testing uses a **hybrid approach** (Clarification 1):
- **CI/CD pipelines**: Fixture-based deterministic testing (LLMCTL_FAKE_HW fixtures, no GPU required) for reproducible automated testing
- **Release gating**: Real downloaded multi-GB models on real GPU hardware for manual live validation before release
- Both approaches required: fixtures for CI/CD determinism, real models for release gating validation

### User Story 5 - Release Automation with GitHub/GitLab CLIs (Priority: P2)

**Description**: As a maintainer, I want automated release process using `gh` and `glab` CLIs that creates tags, generates changelogs, and publishes artifacts.

**Why this priority**: Release process must be deterministic and auditable (Constitution §5).

**Independent Test**: Release script can be run in dry-run mode to verify all steps.

**Acceptance Scenarios**:
1. **Given** version bump to v1.0.0, **When** release script runs, **Then** GitHub release created with assets, GitLab release created, changelog generated
2. **Given** artifacts built via `make archive`, **When** uploaded, **Then** llmctl.tar.gz and llmctl.zip available on both forges

### User Story 6 - Constitution Compliance Verification (Priority: P1)

**Description**: As a governance officer, I want all Constitution rules verified as followed (no violations, ignoring, skipping, or avoiding any rule).

**Why this priority**: Constitution is the highest governing document; non-compliance is a release blocker.

**Independent Test**: Each Constitution section can be audited against implementation.

**Acceptance Scenarios**:
1. **Given** Constitution §1 (test coverage), **When** checked, **Then** four-layer test coverage exists for all changes
2. **Given** Constitution §1.1 (mutation-paired gates), **When** checked, **Then** meta-test mutations prove gates catch regressions
3. **Given** Constitution §9 (data safety), **When** checked, **Then** hardlinked backups before destructive ops, no force-push without authorization
4. **Given** Constitution §11.4 (anti-bluff), **When** checked, **Then** no PASS-bluffs, recorded evidence for all PASS
5. **Given** Constitution §12 (host safety), **When** checked, **Then** 60% RAM ceiling enforced, CONTINUATION.md maintained

### User Story 7 - Distributed Multi-Host Model Orchestration (Priority: P2)

**Description**: As a platform engineer, I want llmctl to support multi-host model orchestration where a cluster of machines can share a model pool, with distributed scheduler coordination, model replication, and failover capabilities.

**Why this priority**: Constitution §11.4.3 requires per-environment-topology test dispatch; distributed topologies are a valid environment topology that must be supported for enterprise deployments.

**Independent Test**: Each scheduler node can be tested independently; cluster state converges under network partitions.

**Acceptance Scenarios**:
1. **Given** a 3-node cluster, **When** a model is requested, **Then** the scheduler places it on the optimal node based on GPU/CPU/RAM availability
2. **Given** a node failure, **When** detected via health checks, **Then** running models are rescheduled on healthy nodes within 30s
3. **Given** a model request exceeds single-node capacity, **When** tensor/model parallelism is configured, **Then** the model is sharded across multiple nodes
4. **Given** network partition, **When** quorum is lost, **Then** minority partition gracefully drains and stops accepting new requests

**Clarification 6**: Scheduler is **multi-host/distributed** (Clarification 6):
- Scheduler state is distributed via Raft consensus (etcd/consul)
- Model placement uses bin-packing with GPU/CPU/RAM/Network awareness
- Model replication for HA: each model runs on N replicas (configurable)
- Tensor parallelism across nodes for models exceeding single-node VRAM
- Failover: leader election via Raft, automatic rescheduling on node failure
- Network partition: minority partition drains, majority continues serving

### User Story 8 - Model State Persistence & Recovery (Priority: P2)

**Description**: As a user, I want my conversation context (KV cache, conversation history, LoRA adapters) preserved during failover, scaling, and replica synchronization so that long-running sessions survive infrastructure events.

**Why this priority**: Long-running conversations and fine-tuned adapters represent significant user investment; losing state breaks user experience and wastes compute.

**Independent Test**: Failover of a model with active conversation preserves KV cache within 5% token loss; LoRA adapters preserved exactly.

**Acceptance Scenarios**:
1. **Given** an active conversation with 5000 tokens, **When** the primary replica fails, **Then** the new primary restores KV cache from latest checkpoint + replays recent tokens from WAL within 5% token loss
2. **Given** a LoRA adapter applied to a model, **When** replica is promoted, **Then** LoRA weights are identical on new primary
3. **Given** a scaling event adding a new replica, **Then** new replica initializes with latest KV cache checkpoint + replays WAL

**Clarification 7**: Model state uses **async KV cache replication with periodic checkpoints** (Clarification 7):
- KV cache replicated asynchronously via WAL (write-ahead log)
- Periodic checkpoints every N tokens (configurable, default 1000) or T seconds (default 30s)
- On failover: new primary restores from latest checkpoint + replays WAL from checkpoint
- LoRA adapters: replicated synchronously on creation; state replicated as part of checkpoint
- Target: ≤5% token loss on failover; ≤30s recovery time

### User Story 9 - Built-in Authentication, Authorization & Multi-Tenancy (Priority: P2)

**Description**: As a platform admin, I want llmctl cluster to have built-in authentication, authorization, and multi-tenancy with users, roles, API keys, and RBAC so that multiple teams can securely share the cluster with isolated workloads and enforced quotas.

**Why this priority**: A distributed cluster serving multiple teams needs built-in authN/authZ to isolate workloads, enforce quotas, and protect model weights without external dependencies.

**Independent Test**: Each tenant can only access their models; quota enforcement prevents noisy neighbors; RBAC enforces least privilege.

**Acceptance Scenarios**:
1. **Given** a cluster with 3 tenants, **When** tenant A creates a model, **Then** tenant B cannot access it without explicit sharing
3. **Given** tenant A with quota 1000 req/min, **When** exceeded, **Then** requests return 429 with retry-after header
4. **Given** user with role "model-operator", **When** they attempt to delete a model, **Then** action allowed; "viewer" role denied

**Clarification 8**: Built-in authentication, authorization & multi-tenancy (Clarification 8):
- Built-in user management: users, teams, API keys (JWT), service accounts
- Role-based access control (RBAC): predefined roles (admin, model-operator, model-viewer, tenant-admin) + custom roles
- API keys: per-user and per-service-account with scopes, rotation, expiration
- Multi-tenancy: tenant isolation at scheduler level; model/namespace per tenant
- Quotas: per-tenant request rate, concurrent requests, GPU/CPU/RAM, storage
- Audit logging: all authZ/authN decisions logged with user, action, resource, decision
- No external IdP dependency; optional OIDC integration for SSO

---

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST complete all pending feature implementations from llmctl_plan.md (model download with sha256 verification, hardware probe, planner, scheduler, service backends)
- **FR-002**: System MUST pass `make test` with zero failures, producing deterministic evidence (exit codes, raw output) for every test
- **FR-003**: System MUST pass `make lint` (shellcheck) with zero warnings
- **FR-004**: System MUST pass `make validate` (json-check + lint + test) as the combined validation gate
- **FR-005**: System MUST pass Constitution verification harness: `bash constitution/scripts/validation/run_verification.sh`
- **FR-006**: System MUST pass meta-test mutation: `bash constitution/scripts/validation/meta_test_verification.sh` (both mutations caught)
- **FR-007**: System MUST pass inheritance verification: `bash tests/test_constitution_inheritance.sh` (10/10 invariants)
- **FR-008**: Documentation MUST include: quick start guide, tutorial, FAQ, user manual, architecture diagrams (Mermaid), API reference, integration guides for all 7 CLI agents
- **FR-009**: System MUST support live testing with real models via `llmctl start <profile>` and `llmctl auto <capabilities>`
- **FR-010**: System MUST support all 7 CLI agents: opencode, pi, crush, Claude Code, aider, continue.dev, Cline with configs in docs/integrations.md
- **FR-011**: Missing CLI agents MUST be installable via their curl setup mechanisms and testable against running llmctl. **Both automated installation scripts AND documented manual installation steps with verification required** (Clarification 3).
- **FR-012**: Live challenges MUST be deterministic: same prompt → same model response. **Use temperature 0 AND fixed seed (`--seed <fixed_value>`) for llama.cpp; document any additional model-specific determinism parameters** (Clarification 2).
- **FR-013**: Release MUST be created via `gh release create` and `glab release create` with generated changelog
- **FR-014**: Release artifacts MUST include `llmctl.tar.gz` and `llmctl.zip` with **working tree + `.git` + ALL submodules recursively** (including constitution's 17 nested submodules) for full offline reproducibility (Clarification 4).
- **FR-015**: System MUST enforce 60% RAM ceiling (Constitution §12.6) and OS-level protection (systemd MemoryHigh/MemoryMax)
- **FR-016**: System MUST use hardlinked git backups before destructive ops (Constitution §9.3)
- **FR-017**: System MUST maintain CONTINUATION.md for session resumption (Constitution §12.10)
- **FR-018**: All submodules MUST have CLAUDE.md/AGENTS.md with Helix Constitution inheritance pointers
- **FR-019**: System MUST support distributed multi-host scheduler with Raft consensus for cluster state coordination
- **FR-020**: Scheduler MUST support model placement optimization across cluster (GPU/CPU/RAM/Network awareness)
- **FR-022**: Scheduler MUST support tensor/model parallelism across nodes for models exceeding single-node VRAM
- **FR-023**: Cluster MUST handle network partitions gracefully: minority partition drains, majority continues serving
- **FR-024**: System MUST support model sharding across nodes for models exceeding single-node capacity
- **FR-025**: Cluster health monitoring via Raft leader heartbeat; failover within 30s on node failure
- **FR-026**: System MUST support async KV cache replication via WAL with periodic checkpoints (N tokens / T seconds)
- **FR-027**: System MUST support LoRA adapter state replication as part of checkpoint synchronization
- **FR-028**: Failover MUST restore KV cache from latest checkpoint + replay WAL (≤5% token loss, ≤30s recovery)
- **FR-029**: System MUST support distributed lock service for coordinated model loading/updates
- **FR-030**: System MUST support built-in authentication with users, teams, API keys (JWT), service accounts
- **FR-031**: System MUST support role-based access control (RBAC) with predefined roles (admin, model-operator, model-viewer, tenant-admin) + custom roles
- **FR-032**: System MUST support API keys with scopes, rotation, expiration for users and service accounts
- **FR-033**: System MUST support multi-tenancy with tenant isolation at scheduler level (model/namespace per tenant)
- **FR-034**: System MUST enforce per-tenant quotas (request rate, concurrent requests, GPU/CPU/RAM, storage)
- **FR-035**: System MUST audit log all authZ/authN decisions (user, action, resource, decision)
- **FR-036**: System MUST support optional OIDC integration for SSO (optional, no external IdP dependency)
- **FR-037**: System MUST support tenant-scoped model namespaces with explicit sharing mechanism
- **FR-038**: System MUST enforce per-tenant quotas (request rate, concurrent requests, GPU/CPU/RAM, storage)
- **FR-039**: Cluster coordination (Raft consensus, KV-cache replication, JWT/RBAC, audit logging — US7-9) MUST be implemented as a separate Go daemon (`llmctld`) using Gin Gonic, HTTP/3 (QUIC), and Brotli compression; single-host operation MUST remain pure bash/shell, unmodified (Clarification 9).
- **FR-040**: `llmctld` MUST embed Raft consensus via a Go Raft library (e.g. hashicorp/raft); no external etcd/consul dependency is required for consensus (Clarification 10).
- **FR-041**: Node-to-node cluster traffic (Raft heartbeats, replication) MUST authenticate via mutual TLS; client-facing traffic (CLI agents, admin/API clients) MUST authenticate via JWT bearer tokens; both transported over HTTP/3 (QUIC, TLS 1.3) (Clarification 11).
- **FR-042**: When cluster mode is configured but the local `llmctld` daemon is unreachable, `bin/llmctl` MUST hard-fail with an explicit error naming the daemon and remediation steps; it MUST NOT silently fall back to single-host scheduling (Clarification 12).
- **FR-043**: Scheduler state file operations MUST use an advisory file lock (flock); a concurrent invocation waits for the lock, then re-reads state before proceeding — no lost updates (Clarification 13).
- **FR-044**: Service units (systemd/launchd) MUST bound automatic restarts (e.g. StartLimitBurst/StartLimitIntervalSec) with backoff; after the limit is exceeded the unit stops and `llmctl status` surfaces the failure with the last captured error (Clarification 14).
- **FR-045**: Model downloads MUST support resume via HTTP Range requests against a `.partial` file; sha256 verification occurs only after full assembly, followed by an atomic rename into the final path (Clarification 15).
- **FR-046**: Credentials (Hugging Face token, JWT signing secrets) MUST be stored in `.env` file(s) at a fixed, gitignored path with `chmod 600`, accompanied by a tracked `.env.example` placeholder (Constitution §11.4.10) (Clarification 16).
- **FR-047**: Live-challenge determinism (SC-008) MUST be verified at the full CLI-agent-output layer — the complete artifact each agent produces (files/diffs) — not merely the raw model API response (Clarification 17).
- **FR-048**: Each of the 7 supported CLI agents MUST have a documented, versioned normalization filter (in `docs/integrations.md` + `tests/fixtures/`) that strips known non-deterministic fields (timestamps, temp paths, ordering) before byte-identical comparison (Clarification 17).
- **FR-049**: Tenant model instances sharing a cluster node MUST run as separate OS processes under per-tenant systemd scopes/cgroups with per-tenant memory limits; KV cache and WAL storage MUST live in per-tenant directories with filesystem permissions enforced (Clarification 18).
- **FR-050**: Release automation MUST treat a GitHub/GitLab release as atomic across both forges — if either `gh release create` or `glab release create` fails, the release is NOT considered published; re-running the release script MUST be idempotent, retrying only the failed forge (Clarification 19).
- **FR-051**: KV cache checkpoints and WAL entries MUST be encrypted at rest using a per-tenant key; filesystem permissions alone are insufficient given conversation-content sensitivity (Clarification 20).
- **FR-052**: Release packaging MUST hard-fail (naming the submodule and expected ref) if any pinned submodule ref is unreachable, rather than producing an artifact with a missing/empty submodule (Clarification 21).
- **FR-053**: During a planned drain or minority-partition drain, in-flight streaming completions MUST be allowed to finish (bounded grace period, e.g. 30s) while new requests are refused immediately (Clarification 22).
- **FR-054**: The audit log (FR-035) MUST be a tamper-evident hash chain with periodic anchor records (Constitution §11.4.268) — deletion, reordering, and truncation of past entries MUST be mechanically detectable (Clarification 23).
- **FR-055**: When the OIDC fallback cache (5min, per Edge Cases) expires while OIDC remains unavailable, requests requiring OIDC-backed identity MUST be denied (401) until OIDC recovers; local-auth users are unaffected (Clarification 24).

### Key Entities

- **Model Profile**: Represents a downloadable model with engine (llama.cpp/colibri), size, min_tier, port, sha256, engine flags
- **Hardware Profile**: Represents host capabilities (CPU cores, SIMD, RAM, GPU VRAM, storage type, tier classification)
- **Service Unit**: Represents a running model instance (systemd --user or launchd) with reservation record (RAM/VRAM, port, start epoch)
- **Scheduler State**: Represents co-residency groups, eviction policies, LRU ordering, budget enforcement
- **CLI Agent Config**: Represents integration config for each supported agent (baseURL, apiKey, model ID)
- **Cluster Node**: Represents a host in the cluster with unique ID, hardware profile, health status, assigned models
- **Cluster State**: Distributed state managed via Raft (leader, term, log, committed index, cluster membership)
- **Model Placement**: Decision record (node_id, profile_id, replica_id, resources, status)
- **Model Replica**: Replica instance (node_id, profile_id, replica_id, status, health_check_endpoint)
- **KV Cache State**: Represents token cache state (tokens, positions, attention weights) with checkpoint/WAL
- **LoRA Adapter State**: Adapter weights, config, and synchronization status
- **WAL Entry**: Write-ahead log entry (token_id, kv_delta, timestamp, replica_id)
- **Checkpoint**: Periodic KV cache snapshot (tokens, timestamp, hash, replica_id)
- **User**: Identity with credentials (password hash, API keys), team membership, roles
- **Team**: Group of users with shared resources and quotas
- **Tenant**: Isolated namespace with models, users, quotas, audit log
- **Role**: Named permission set (admin, model-operator, model-viewer, tenant-admin, custom)
- **API Key**: Credential with scopes, rotation, expiration, associated with user/service account
- **Tenant Quota**: Resource limits (request rate, concurrent, GPU/CPU/RAM, storage) per tenant
- **Audit Log Entry**: AuthZ/authN decision record (user, action, resource, decision, timestamp)
- **Permission**: Atomic action (model:create, model:delete, model:infer, tenant:manage, etc.)
- **Cluster Daemon (llmctld)**: Go binary (Gin Gonic, HTTP/3 QUIC, Brotli) handling Raft consensus, KV-cache replication, RBAC/JWT auth, and tamper-evident audit logging for cluster mode; embeds Raft (no external etcd/consul); single-host bash CLI is a thin client to it only when cluster mode is enabled — single-host mode never depends on it.

---

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: `make test` passes 100% with zero flaky tests (all test scripts exit 0, deterministic evidence captured)
- **SC-002**: `make lint` passes with zero shellcheck warnings
- **SC-004**: Constitution verification harness passes (17/17 submodules verified, required submodules check passes)
- **SC-005**: Meta-test mutations both caught (missing submodule detection + corrupted logic detection)
- **SC-006**: Inheritance verification passes (10/10 invariants)
- **SC-007**: All 7 CLI agents successfully configured and tested against running llmctl services
- **SC-008**: Live challenges with deterministic prompts produce identical responses across runs. **Use temperature 0 AND fixed seed (`llama-server --seed <fixed_value>`); document any additional model-specific determinism parameters** (Clarification 2).
- **SC-009**: Release created on GitHub and GitLab with proper changelog, assets uploaded, tags pushed. **Use Semantic Versioning (SemVer MAJOR.MINOR.PATCH) with pre-release tags (e.g., v1.0.0-rc.1)** (Clarification 5).
- **SC-010**: All Constitution rules audited with zero violations found
- **SC-011**: Documentation completeness: 100% of planned docs exist and are cross-referenced
- **SC-012**: Architecture diagrams rendered as Mermaid in docs (data flow, memory model, scheduler, service backends, port map)
- **SC-013**: Distributed scheduler forms cluster of 3+ nodes, elects leader via Raft within 5s
- **SC-014**: Model placement achieves optimal bin-packing across cluster (GPU/CPU/RAM/Network)
- **SC-015**: Node failure detected within 10s; failover completes within 30s with zero data loss
- **SC-016**: Network partition handled: minority partition drains, majority continues serving
- **SC-017**: Tensor parallelism splits model across nodes; throughput within 15% of single-node baseline
- **SC-018**: Model replication achieves 99.9% availability (N=3 replicas, 1 failure tolerated)
- **SC-019**: KV cache failover achieves ≤5% token loss, ≤30s recovery time
- **SC-019**: LoRA adapter state preserved exactly across failover/scaling
- **SC-020**: Checkpoint interval configurable (N tokens, T seconds); WAL replay deterministic
- **SC-021**: AuthN/AuthZ decisions < 5ms latency; quota enforcement < 1ms overhead
- **SC-022**: Multi-tenancy isolation: zero cross-tenant data leakage in 1000 concurrent requests
- **SC-023**: Quota enforcement: 429 with retry-after within 1ms of limit
- **SC-024**: Audit log: 100% of authZ/authN decisions logged with < 10ms latency

---

## Assumptions

- Target OS: Linux (systemd --user) and macOS (launchd); Windows out of scope
- Hardware: Minimum baseline tier (8 cores, 32GB RAM, 12GB VRAM) for baseline testing
- Models: Downloaded from Hugging Face with sha256 verification; engines built from pinned submodules
- Engines: llama.cpp v0.4.0 and colibri v1.11.0 as git submodules
- CLI Agents: opencode, pi, crush, Claude Code, aider, continue.dev, Cline available or installable. **Both automated installation scripts AND documented manual installation steps with verification required** (Clarification 3).
- Network: Access to Hugging Face API for model downloads and sha256 verification; **Cluster nodes communicate over HTTP/3 (QUIC) on a dedicated network — mutual TLS for node-to-node Raft/replication traffic, JWT bearer tokens for client-facing traffic (Clarification 11)**
- Cluster subsystem: Implemented as a separate Go daemon (`llmctld`) using Gin Gonic, HTTP/3 (QUIC), and Brotli compression, with embedded Raft consensus (e.g. hashicorp/raft); single-host bash CLI is unmodified and never depends on this daemon unless cluster mode is explicitly enabled (Clarification 9, Clarification 10)
- Privileges: User-level systemd (linger enabled), no root required for normal operation; **Cluster setup requires root for network config**
- Constitution: Helix Universal Constitution at `constitution/Constitution.md` is the governing document

---

## Edge Cases

- What happens when hardware is below minimum tier? → `llmctl plan` reports `below-minimum`, no profiles recommended
- What happens when combined model footprint exceeds budgets? → `llmctl start` refuses with exact numbers and suggests alternatives
- What happens when model download sha256 mismatches? → Content never reaches final path, hard failure, evidence logged
- What happens when service fails to start? → systemd/launchd Restart=always, logs captured in `~/.local/state/llmctl/logs/`
- What happens when CLI agent config is invalid? → Agent reports connection error; docs/integrations.md provides troubleshooting
- What happens when model prompt is non-deterministic? → **Temperature 0 AND fixed seed (`llmctl-server --seed <fixed_value>`) enforced for challenges; document any additional model-specific determinism parameters** (Clarification 2)
- What happens when cluster node fails? → Health check detects failure within 10s; Raft leader initiates rescheduling; models rescheduled on healthy nodes within 30s
- What happens when network partition occurs? → Minority partition drains models and stops accepting requests; majority continues serving
- What happens when model exceeds single-node VRAM? → Tensor parallelism splits model across nodes; throughput within 15% of single-node
- What happens when Raft leader fails? → New election within 5s; new leader continues cluster operations
- What happens when model replica fails health check? → Replica marked unhealthy; removed from load balancer; new replica spawned on healthy node
- What happens when KV cache checkpoint fails? → WAL continues logging; next checkpoint attempt includes previous delta
- What happens when WAL grows too large? → Checkpoint triggered; WAL truncated after successful checkpoint
- What happens when LoRA adapter checkpoint fails? → Retry with exponential backoff; alert on repeated failure
- What happens during split-brain? → Raft quorum prevents split-brain; minority partition steps down
- What happens when tenant exceeds quota? → 429 with retry-after; no cross-tenant impact
- What happens when API key is compromised? → Key rotation revokes old key; audit log traces usage
- What happens when tenant admin tries to access another tenant's models? → Denied; audit log records attempt
- What happens when OIDC provider is unavailable? → Fallback to local auth; cached tokens valid for 5min
- What happens when the OIDC 5-minute fallback cache expires and OIDC is still unavailable? → New requests requiring OIDC-backed identity are denied (401) until OIDC recovers; local-auth (non-OIDC) sessions are unaffected (Clarification 24)
- What happens when two `llmctl` invocations race on the scheduler state file (e.g. cron + interactive user)? → An advisory file lock (flock) serializes them; the second invocation waits, re-reads state after the lock releases, then proceeds — no lost updates (Clarification 13)
- What happens when a service unit crash-loops because a model can never actually start (corrupted GGUF, VRAM no longer sufficient, wrong engine flags)? → Bounded restart + backoff (systemd StartLimitBurst/StartLimitIntervalSec); once exceeded the unit stops and `llmctl status` surfaces the failure with the last captured error, rather than looping forever (Clarification 14)
- What happens when a multi-GB model download is interrupted mid-transfer (network drop, disk full, Ctrl+C)? → Resumes via an HTTP Range request against the `.partial` file on re-run; sha256 is verified only once the file is fully reassembled, then atomically renamed into place (Clarification 15)
- What happens when a host is configured for cluster mode but its local `llmctld` daemon is unreachable? → `llmctl` hard-fails with an explicit error naming the daemon and how to restart it; it never silently falls back to single-host scheduling, which would misrepresent which mode actually served the request (Clarification 12)
- What happens when `gh release create` succeeds but `glab release create` fails, or vice versa? → The whole release is treated as failed/not-published; the release script is idempotent and a re-run retries only the forge that failed, without re-creating the one that already succeeded (Clarification 19)
- What happens when a pinned submodule's ref is unreachable at release-packaging time (upstream private/deleted/rate-limited)? → Release packaging hard-fails, naming the unreachable submodule and its expected ref; no artifact is produced with a missing or empty submodule directory (Clarification 21)
- What happens to an in-flight streaming (SSE) completion during a planned drain or minority-partition drain? → The draining node lets already-accepted streams finish within a bounded grace period (~30s) while refusing all new requests immediately, avoiding a response truncated mid-token (Clarification 22)
- What happens if the audit log itself is tampered with (an entry deleted, reordered, or the log truncated)? → The audit log is a tamper-evident hash chain with periodic anchor records (Constitution §11.4.268); deletion, reordering, and truncation of past entries are mechanically detected, never merely discouraged (Clarification 23)

---

## Clarifications

### Session 2025-09-15

- **Q: Should live testing use real models or fixtures?** → **A: Hybrid approach - Fixtures for CI/CD (deterministic, no GPU), real models for release gating (real GPU, multi-GB models). Both required: fixtures for CI/CD determinism per Constitution §11.4.3, real models for release gating validation.**
- **Q: What determinism parameters for live challenges?** → **A: Temperature 0 AND fixed seed (`llama-server --seed <fixed_value>`) for llama.cpp; document any additional model-specific determinism parameters for colibri and other engines.**
- **Q: How to handle missing CLI agent installation?** → **A: Both automated installation scripts (curl + config + verify) AND documented manual installation steps with verification required.**
- **Q: Release artifact submodule scope?** → **A: All submodules recursively (including constitution's 17 nested submodules) for full offline reproducibility per "working tree + .git + submodules".**
- **Q: Release versioning scheme?** → **A: Semantic Versioning (SemVer MAJOR.MINOR.PATCH) with pre-release tags (e.g., v1.0.0-rc.1).**
- **Q: Should scheduler support multi-host/distributed cluster?** → **A: Yes - distributed scheduler with Raft consensus, model replication, tensor parallelism, and graceful partition handling per Constitution §11.4.3 (per-environment-topology test dispatch).**
- **Q: How to handle model state (KV cache, LoRA adapters) during failover/scaling?** → **A: Async KV cache replication with periodic checkpoints (N tokens/T seconds); WAL replay on failover; LoRA adapters in checkpoints; ≤5% token loss, ≤30s recovery.**
- **Q: How to handle authentication, authorization, and multi-tenancy?** → **A: Built-in authN/authZ with users, teams, API keys (JWT), service accounts; RBAC with predefined roles; multi-tenancy with tenant isolation, quotas, audit logging; optional OIDC integration for SSO.**

### Session 2026-09-15 (Brainstorm — US1-6 and US7-9 edge cases)

- **Q: llmctl is pure bash/shell today; US7-9 requires Raft consensus, mTLS/JWT, KV-cache WAL replication. How should this be implemented?** → **A: A new Go daemon (`llmctld`) using Gin Gonic, HTTP/3 (QUIC), and Brotli compression, handling cluster/auth/replication only; single-host bash CLI stays unmodified.**
- **Q: Should the Go daemon embed Raft or delegate to etcd/consul?** → **A: Embed Raft directly (e.g. hashicorp/raft) — no external consensus store dependency.**
- **Q: How should the new daemon relate to the existing single-host bash scheduler?** → **A: Opt-in cluster daemon — single-host stays 100% bash; `llmctld` is only started when cluster mode is enabled, and bash `llmctl` becomes a thin HTTP client to it in that mode.**
- **Q: What auth scheme for node-to-node vs. client-facing cluster traffic?** → **A: Mutual TLS for node-to-node Raft/replication traffic; JWT bearer tokens for client-facing (CLI agents, admin API) traffic; both over HTTP/3 (QUIC, TLS 1.3).**
- **Q: What happens when `llmctl` runs in cluster mode but `llmctld` is unreachable?** → **A: Hard error naming the daemon and remediation; never a silent fallback to single-host (anti-bluff).**
- **Q: How are concurrent `llmctl` invocations against scheduler state handled?** → **A: Advisory file lock (flock); the second invocation waits, re-reads state, then proceeds.**
- **Q: How is a service crash-loop (model that can never start) bounded?** → **A: systemd StartLimitBurst/StartLimitIntervalSec bounds restarts with backoff; unit stops and `llmctl status` surfaces the failure with the last error.**
- **Q: How are interrupted multi-GB model downloads handled?** → **A: Resume via HTTP Range against a `.partial` file; sha256 verified only after full reassembly, then atomic rename.**
- **Q: Where are credentials (HF token, JWT secrets) stored?** → **A: `.env` file(s) at a fixed gitignored path, chmod 600, with a tracked `.env.example` placeholder.**
- **Q: At what layer is live-challenge determinism (SC-008) measured?** → **A: Full CLI-agent output, byte-identical — the complete artifact each agent produces, not just the raw model API response.**
- **Q: How is per-agent non-determinism (timestamps, temp paths) normalized before comparison?** → **A: A documented, versioned per-agent normalization filter in `docs/integrations.md` + `tests/fixtures/`.**
- **Q: What isolation level do tenant model instances get on a shared cluster node?** → **A: Process + namespace isolation — separate OS process per tenant under its own systemd scope/cgroup with per-tenant memory limits; per-tenant directories with filesystem permissions for KV cache/WAL.**
- **Q: What happens if `gh release create` succeeds but `glab release create` fails, or vice versa?** → **A: Whole release fails/not-published; idempotent re-run retries only the failed forge.**
- **Q: Should KV cache checkpoints and WAL entries be encrypted at rest?** → **A: Yes, per-tenant key encryption — filesystem permissions alone are insufficient given conversation-content sensitivity.**
- **Q: What happens if a pinned submodule ref is unreachable at release-packaging time?** → **A: Hard-fail the release, naming the submodule and expected ref.**
- **Q: What happens to an in-flight streaming completion during a drain/failover?** → **A: Finish in-flight within a bounded grace period (~30s); refuse new requests immediately.**
- **Q: Should the audit log be tamper-evident?** → **A: Yes — hash chain with periodic anchor records (Constitution §11.4.268); deletion/reorder/truncation mechanically detected.**
- **Q: What happens when the OIDC 5-minute fallback cache expires and OIDC is still down?** → **A: Deny new OIDC-backed requests (401) until OIDC recovers; existing local-auth sessions unaffected.**

---

## Notes

- **Clarification 1**: Hybrid live testing approach reconciles CI/CD determinism (Constitution §11.4.3) with real model validation for release gating.
- **Clarification 2**: Explicit seed parameter (`--seed`) ensures true determinism per Constitution §11.4.6 (no guessing); llama.cpp-specific; colibri and other engines may have different parameters.
- **Clarification 3**: Automated scripts enable CI/CD integration; documented steps enable manual verification and troubleshooting.
- **Clarification 4**: "Working tree + .git + submodules" interpreted as full recursive inclusion per Constitution §5 and §11.4.11.
- **Clarification 5**: SemVer enables dependency management and pre-release workflows per industry standard.
- **Clarification 6**: Distributed scheduler with Raft consensus enables multi-host orchestration, model replication, tensor parallelism, and graceful partition handling per Constitution §11.4.3 (per-environment-topology test dispatch).
- **Clarification 7**: Async KV cache replication via WAL with periodic checkpoints; WAL replay on failover; LoRA adapters in checkpoints; ≤5% token loss, ≤30s recovery.
- **Clarification 8**: Built-in authN/authZ with users, teams, API keys (JWT), service accounts; RBAC with predefined roles; multi-tenancy with tenant isolation, quotas, audit logging; optional OIDC integration for SSO.
- **Clarification 9**: Cluster/auth/replication logic (US7-9) is a new Go daemon (`llmctld`) using Gin Gonic, HTTP/3 (QUIC), and Brotli — chosen because Raft consensus, mTLS/JWT, and WAL replication are impractical to hand-roll in bash; the existing single-host bash CLI (`bin/llmctl`, `lib/*.sh`) is unmodified and is a thin HTTP client to `llmctld` only when cluster mode is explicitly enabled.
- **Clarification 10**: Raft is embedded directly in `llmctld` (e.g. hashicorp/raft) rather than delegated to an external etcd/consul cluster, avoiding an extra operational dependency to install and operate.
- **Clarification 11**: Node-to-node traffic (Raft heartbeats, replication) uses mutual TLS for peer authentication; client-facing traffic (CLI agents, admin/API) uses JWT bearer tokens per the RBAC model in US9; both ride over HTTP/3 (QUIC), which supplies TLS 1.3 transport encryption regardless of the auth scheme layered on top.
- **Clarification 12**: A daemon-unreachable condition in cluster mode is a hard, explicit failure (never a silent single-host fallback) per Constitution §11.4 anti-bluff — a silent fallback would let a command appear to succeed while actually being served by a different scheduling mode than the operator configured.
- **Clarification 13**: Scheduler state file concurrency is serialized via `flock`; the losing invocation blocks until the lock releases, then re-reads state (never acts on a stale snapshot) before proceeding — no lost updates, no corruption, per Constitution §9.
- **Clarification 14**: Crash-loop protection bounds systemd/launchd auto-restarts (StartLimitBurst/StartLimitIntervalSec) so a permanently-broken model (corrupted file, insufficient VRAM, bad flags) fails visibly instead of consuming CPU/I/O forever; `llmctl status` surfaces the last captured error for diagnosis.
- **Clarification 15**: Download resume uses HTTP Range requests against a `.partial` file; the sha256 (Constitution §11.4.38 installable-asset evidence) is verified only once the file is fully reassembled, then the verified file is atomically renamed into its final path — an interrupted download never leaves a corrupt or half-verified artifact at the final path.
- **Clarification 16**: Credentials live in `.env` file(s) at a fixed, gitignored path with `chmod 600` and a tracked `.env.example` placeholder, per Constitution §11.4.10 (credentials-handling mandate) and §11.4.30 (.gitignore mandate) — applies to both the existing Hugging Face token and the new JWT signing secrets for `llmctld`.
- **Clarification 17**: Determinism for SC-008 is measured at the full CLI-agent-output layer (the complete artifact each of the 7 agents produces), not merely the raw model API response, because the acceptance criterion is "the CLI agent reliably completes the same coding task the same way" — this requires a documented, versioned, per-agent normalization filter (docs/integrations.md + tests/fixtures/) stripping known non-deterministic fields (timestamps, temp paths, ordering) before byte-identical comparison; the filter set is itself version-controlled so it can be audited and updated as each agent evolves.
- **Clarification 18**: Tenant isolation on a shared cluster node is process + namespace isolation — each tenant's model server is a separate OS process under its own systemd scope/cgroup with per-tenant memory limits, and KV cache/WAL storage lives in per-tenant directories with filesystem permissions enforced; this is the isolation mechanism SC-022's "zero cross-tenant data leakage" claim rests on.
- **Clarification 19**: Release publication across GitHub and GitLab is atomic — a failure on either forge means the release is not considered published, and the idempotent release script retries only the forge that failed, per Constitution §11.4.253 (idempotency under retry) and the general no-partial-state discipline of §11.4.264 (build once, promote one artifact).
- **Clarification 20**: KV cache checkpoints and WAL entries are encrypted at rest with a per-tenant key because they persist actual conversation content across tenants sharing infrastructure; filesystem permissions (Clarification 18) protect against cross-process access but not against a filesystem-level compromise or backup exposure.
- **Clarification 21**: An unreachable pinned submodule ref at release-packaging time hard-fails the release (naming the submodule and expected ref) rather than silently shipping an artifact with an empty/missing submodule directory, per Constitution §11.4.36 (mandatory install_upstreams) and the FR-014/Clarification-4 full-recursive-submodule requirement — a release artifact missing a declared dependency is not the artifact the spec promised.
- **Clarification 22**: An in-flight SSE completion during a planned drain or minority-partition drain is allowed to finish within a bounded grace period (~30s) while new requests are refused immediately — this avoids truncating a response mid-token while still bounding how long a draining node keeps serving.
- **Clarification 23**: The audit log (FR-035) is a tamper-evident hash chain with periodic anchor records per Constitution §11.4.268 — each entry links to the previous via a hash chain, and periodic anchors make wholesale deletion or truncation a detected absence rather than silence, closing the gap a plain append-only log cannot: an actor who deletes an entry and recomputes the chain forward is only caught against the anchor, not the chain alone.
- **Clarification 24**: When the OIDC 5-minute fallback cache (existing Edge Case) expires while OIDC remains unavailable, requests requiring OIDC-backed identity are denied (401) rather than extending the cache indefinitely — this trades availability for not honoring stale identity claims past their intended freshness window; local-auth (non-OIDC) users are entirely unaffected since they never depended on OIDC.

---

## Brainstorm Log

### Session 2025-09-15

- **Q: Should live testing use real models or fixtures?** → **A: Hybrid approach - Fixtures for CI/CD (deterministic, no GPU), real models for release gating (real GPU, multi-GB models). Both required: fixtures for CI/CD determinism per Constitution §11.4.3, real models for release gating validation.**
- **Q: What determinism parameters for live challenges?** → **A: Temperature 0 AND fixed seed (`llama-server --seed <fixed_value>`) for llama.cpp; document any additional model-specific determinism parameters for colibri and other engines.**
- **Q: How to handle missing CLI agent installation?** → **A: Both automated installation scripts (curl + config + verify) AND documented manual installation steps with verification required.**
- **Q: Release artifact submodule scope?** → **A: All submodules recursively (including constitution's 17 nested submodules) for full offline reproducibility per "working tree + .git + submodules".**
- **Q: Release versioning scheme?** → **A: Semantic Versioning (SemVer MAJOR.MINOR.PATCH) with pre-release tags (e.g., v1.0.0-rc.1).**
- **Q: Should scheduler support multi-host/distributed cluster?** → **A: Yes - distributed scheduler with Raft consensus, model replication, tensor parallelism, and graceful partition handling per Constitution §11.4.3 (per-environment-topology test dispatch).**
- **Q: How to handle model state (KV cache, LoRA adapters) during failover/scaling?** → **A: Async KV cache replication with periodic checkpoints (N tokens/T seconds); WAL replay on failover; LoRA adapters in checkpoints; ≤5% token loss, ≤30s recovery.**
- **Q: How to handle authentication, authorization, and multi-tenancy?** → **A: Built-in authN/authZ with users, teams, API keys (JWT), service accounts; RBAC with predefined roles; multi-tenancy with tenant isolation, quotas, audit logging; optional OIDC integration for SSO.**

### Session 2026-09-15 — Deep-dive edge cases across core completion (US1-6) and distributed cluster (US7-9)

**Scope-mismatch finding**: `llmctl` is entirely bash/shell today (`bin/llmctl`, `lib/*.sh`, bash test scripts — verified against the actual tree, no compiled-language runtime present). US7-9's Raft consensus, mTLS/JWT auth, and KV-cache WAL replication are not reasonably implementable in POSIX shell. Resolved by introducing a new, separate Go daemon (`llmctld`, Gin Gonic + HTTP/3/QUIC + Brotli) that owns cluster/auth/replication concerns exclusively; single-host operation remains pure bash, untouched, and never depends on the daemon unless cluster mode is explicitly enabled. This is the most consequential decision of the session — it's now FR-039 through FR-041 and Clarifications 9-11.

**Architecture decisions locked in**: embedded Raft (no external etcd/consul, Clarification 10); mTLS for node-to-node traffic + JWT for client-facing traffic, both over HTTP/3 (Clarification 11); hard-fail (never silent fallback) when `llmctld` is unreachable in cluster mode (Clarification 12) — this last one is a direct instance of the project's anti-bluff covenant applied to a new subsystem.

**Core-completion (US1-6) gaps closed**: the original spec had no answer for concurrent `llmctl` invocations racing on scheduler state (now flock-serialized, Clarification 13), unbounded service crash-loops (now bounded restart+backoff, Clarification 14), interrupted multi-GB downloads (now resumable via HTTP Range + `.partial` files, Clarification 15), or credential storage location/permissions (now `.env` + chmod 600 + `.env.example`, Clarification 16, directly required by Constitution §11.4.10).

**Determinism scope sharpened**: SC-008's "deterministic live challenges" was ambiguous about whether determinism applies to the raw model API or the full CLI-agent artifact. Resolved toward the stricter reading — full CLI-agent output, byte-identical — which in turn requires a new, explicit deliverable: a documented, versioned per-agent normalization filter for each of the 7 CLI agents (Clarification 17, now FR-047/FR-048). This is real scope, not a free clarification — it should be sized accordingly in the implementation plan.

**Multi-tenancy hardening**: SC-022's "zero cross-tenant data leakage" claim previously had no stated isolation mechanism. Resolved to process + namespace isolation (per-tenant systemd scope/cgroup + per-tenant directories, Clarification 18) plus per-tenant encryption at rest for KV cache/WAL (Clarification 20), since checkpoint/WAL data persists actual conversation content across tenants sharing infrastructure.

**Release-process hardening**: two previously-unaddressed failure modes now have explicit behavior — a partial GitHub/GitLab release failure is treated as a whole-release failure with idempotent retry-only-the-failed-forge (Clarification 19), and an unreachable pinned submodule ref at packaging time hard-fails release packaging by name (Clarification 21), both closing gaps where the original FR-013/FR-014 described the happy path only.

**Audit-log integrity**: FR-035's "100% audit logging" requirement had no tamper-evidence guarantee. Resolved to a hash-chained, periodically-anchored log per Constitution §11.4.268 (Clarification 23) — a plain append-only log cannot detect an actor who deletes an entry and recomputes the chain forward; only the anchor catches that.

**Remaining honest gap**: this session resolved architecture and edge-case *behavior*, not implementation sizing. FR-039 through FR-055 collectively represent a new Go service with its own build, test, and deployment lifecycle — the next planning pass should treat `llmctld` as its own work-stream rather than folding it into the existing bash-only `make test`/`make lint`/`make validate` gates.
