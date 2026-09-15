# FAQ

**Revision:** 1
**Last modified:** 2026-09-15T00:00:00Z

This FAQ answers the Edge Cases enumerated in
[`specs/001-llmctl-completion/spec.md`](../specs/001-llmctl-completion/spec.md#edge-cases),
one entry per case (closely related cases are grouped). Every entry is
labeled honestly:

- **Status: current behavior** — this is what the codebase does today,
  verified against real source and/or a real passing test in this repo.
- **Status: planned (Phase N, USx)** — this describes the *design intent*
  captured in the spec/tasks, but the corresponding code does not exist yet
  in this repository. No planned feature is described as if it already
  works.

Per the project's hybrid testing approach (fixtures for CI/CD determinism,
real models for release gating — see [`docs/quickstart.md`](quickstart.md)),
"current behavior" entries below are backed by either a fixture-driven
automated test (part of `make test`) or a real-model manual verification
step; each entry says which.

Before writing this file we verified exactly which parts of the cluster
daemon (`llmctld`) exist today:

```
$ find /home/milosvasic/Projects/llmctl/llmctld -name '*.go'
llmctld/internal/cluster/state.go
llmctld/internal/cluster/state_test.go
llmctld/internal/audit/log.go
llmctld/internal/audit/log_test.go
llmctld/internal/mtls/certs.go
llmctld/internal/mtls/certs_test.go
llmctld/internal/raft/fsm.go
llmctld/internal/raft/fsm_test.go
llmctld/internal/raft/testhelpers_test.go
llmctld/cmd/llmctld/main.go
```

`llmctld/cmd/llmctld/main.go` itself prints
`"llmctld: cluster mode is not yet implemented (Phase 1 scaffold only)"` and
exits 1 for every invocation except `version`/`--version`. The four
`internal/` packages that do exist are early Foundational-phase scaffolding
(a Raft FSM, an mTLS cert helper, a cluster state type, and — notably — a
fully implemented and unit-tested tamper-evident audit hash-chain; see the
audit-log entry below for the nuance). There is no tenant, quota, OIDC, WAL,
LoRA-checkpoint, or HTTP API code anywhere in `llmctld` today. `bin/llmctl`'s
`cluster`/`tenant`/`apikey` subcommands are real CLI entry points that
hard-fail with an explicit `"...is not yet implemented (Phase N, USx)"`
message the moment you try to use them against a real `llmctld` — see
`bin/llmctl` lines 195–223.

---

## Hardware, scheduling, and local model lifecycle

### What happens when my hardware is below the minimum supported tier?

**Status: current behavior.**

`lib/catalog.sh`'s `catalog_classify_tier()` classifies the live hardware
probe into one of four tiers (`below-minimum < baseline < workstation <
datacenter`) using fixed, documented thresholds (e.g. `below-minimum` is
anything under 8 cores + 32 GiB RAM). `catalog_plan_json()` then marks a
catalog profile `"recommended"` only when it both fits the live memory
budgets *and* its minimum tier requirement is met
(`d["tier_ok"] and d["fits"]`, `lib/catalog.sh` around line 195). On a host
classified `below-minimum`, no catalog profile can satisfy `tier_ok`, so
`llmctl plan` reports `tier: below-minimum` with an empty `recommended`
list — exactly as spec.md's edge case describes.

Verified by the deterministic fixture-driven suite `tests/test_planner.sh`,
which asserts the exact recommended-profile set for the `baseline` and
`workstation` hardware fixtures under `tests/fixtures/hw-*.json` (part of
`make test`; no GPU or network required).

### What happens when the combined footprint of the models I asked to start exceeds my budgets?

**Status: current behavior.**

`lib/scheduler.sh`'s `sched_start()` computes each requested profile's RAM
and VRAM footprint, sums them against the live budgets (probed free memory
minus a 4 GiB RAM headroom / 15% VRAM headroom, minus whatever is already
reserved by running profiles), and refuses with the exact shortfall if the
combined total would exceed either budget:

```
err "cannot start '${p}': needs ${ram} MiB RAM + ${vram} MiB VRAM, but only $(( ram_budget - used_ram )) MiB RAM + $(( vram_budget - used_vram )) MiB VRAM remain"
```

(`lib/scheduler.sh` line 212). `llmctl auto <capability>` handles the same
situation differently — it evicts non-enabled services in LRU order until
the requested profile fits, but never evicts a service the operator
explicitly `enable`d (documented in `README.md`'s "Safety guarantees" and
`lib/scheduler.sh`'s header comment). Verified by `tests/test_scheduler.sh`
against the deterministic hardware fixtures (`make test`).

### What happens when a downloaded model's sha256 doesn't match?

**Status: current behavior.**

`lib/download.sh`'s `_dl_verify_file()` computes the sha256 of the
downloaded `.part` file and compares it against the catalog's expected
value (or a value fetched live from the Hugging Face API when the catalog
entry is `null`) **before** the atomic rename into the final model path —
see `lib/download.sh` lines 83–166 and README's "Safety guarantees"
section. A mismatch calls `err "sha256 mismatch for ${path}"` and the
partially-downloaded content never reaches the final path; the verification
command, its exit code, and its output are appended as evidence to
`~/.local/state/llmctl/verify/<profile>.log`. Verified by
`tests/test_download.sh` (part of `make test`, using synthetic fixtures —
no real multi-GB download needed for this check).

### What happens when a model service fails to start, or crash-loops because the model can never actually start?

**Status: current behavior.**

Both failure shapes are handled by the same OS-level mechanism, described
once in the README's "Safety guarantees" section:

- **Linux** (`lib/service_linux.sh`): every generated systemd `--user` unit
  carries `Restart=always` plus a bounded restart budget —
  `StartLimitBurst=5` within `StartLimitIntervalSec=60`
  (`lib/service_linux.sh` lines 71–72 and 94–95). Once that burst limit is
  exceeded within the interval, systemd stops restarting the unit and
  `llmctl status` reports it as `failed (crash-loop)` with the last
  captured log line, rather than looping forever (this is the FR-044
  crash-loop signal referenced in `lib/service_linux.sh` around line 197).
  A model that can never actually start — corrupted GGUF, VRAM no longer
  sufficient, wrong engine flags — surfaces this way instead of restarting
  indefinitely.
- **macOS** (`lib/service_macos.sh`): launchd's `KeepAlive` plus a widened
  `ThrottleInterval=60` bound the restart *rate* (launchd has no native
  give-up-after-N-restarts primitive, so this is documented as a rate bound
  rather than a total-attempt bound — see the README's Safety guarantees
  section for the explicit honest caveat).

Verified by `tests/test_services_crashloop.sh` (part of `make test`, using
`LLMCTL_DRY_RUN` fixtures — no real crashing model process needed to
exercise the generated-unit-file logic).

Logs for a failed service are captured under
`~/.local/state/llmctl/logs/`, addressing the more general "service fails to
start" edge case as well.

### What happens if my CLI agent's config is invalid?

**Status: current behavior (documentation-backed).**

`llmctl` doesn't validate a CLI agent's own config file — that file belongs
to the agent, not to `llmctl`. What `llmctl` guarantees is a stable,
documented OpenAI-compatible endpoint per profile (`127.0.0.1:<fixed-port>`,
see the port map in `README.md`) and per-agent config examples + a `verify`
step for all 7 supported agents in
[`docs/integrations.md`](integrations.md) (e.g. `pi`'s `models.json`/
`settings.json` example around line 155, each agent's own `--version`/
`--help` verification command). If an agent's config points at the wrong
port, has a malformed JSON provider entry, or otherwise doesn't match its
own real, current schema, the agent itself reports a connection error (it
cannot reach `llmctl`'s server, or `llmctl`'s server rejects a malformed
request) — `docs/integrations.md`'s per-agent sections are the
troubleshooting reference, matching spec.md's edge-case description
verbatim.

### What happens when a model prompt/response needs to be deterministic (e.g. for live challenges)?

**Status: current behavior, with one honestly-tracked gap.**

Server-side determinism (Clarification 2) is real:
`lib/scheduler.sh`'s `LLMCTL_SEED` environment variable, when set, appends
`--seed <value> --temp 0` to a llama.cpp profile's launch arguments — it is
opt-in rather than baked into every default launch, since an always-fixed
seed would make ordinary interactive coding sessions identically
non-creative (`docs/integrations.md`, "Live-challenge determinism" section).

But determinism is *measured* one layer up, at the full CLI-agent output
artifact (transcript/diff/edited files), not the raw model API response —
two runs can still differ in non-deterministic fields unrelated to the
model's actual answer (timestamps, per-run temp-directory paths, UUIDs,
elapsed-time/token-usage reporting). Per-agent normalization filters at
`docs/integrations/normalize_<agent>.sh` (one per supported agent, built on
shared primitives in `docs/integrations/lib_normalize_common.sh`) strip
exactly those known field classes before a byte-identical comparison.
Verified by `tests/test_normalize_agents.sh` (part of `make test`) against
synthetic fixture pairs under `tests/fixtures/agent_output/<agent>/`.

**Honest boundary** (stated explicitly in `docs/integrations.md` itself):
those fixture pairs are synthetic, not reverse-engineered from a real
captured run of any of the 7 agents against a live `llmctl` server. The
live, real-GPU capture proving "two runs of the same fixed prompt through
the real agent produce byte-identical output after normalization" is
release-gating work per the project's hybrid testing approach, not yet
performed. One non-deterministic field class named by FR-048/Clarification
17 — output *ordering* — is not yet addressed by any of the 7 filters,
because no real captured transcript exists yet to show whether a given
agent's output needs deterministic re-ordering at all.

### What happens when two `llmctl` invocations race on the scheduler state file (e.g. cron + interactive user)?

**Status: current behavior.**

`lib/scheduler.sh`'s `scheduler::with_lock()` wraps every state-reading and
state-writing scheduler operation in an exclusive advisory `flock` on
`${LLMCTL_RUNTIME_DIR}/.scheduler.lock`. A second concurrent invocation
blocks on `flock -x` until the first releases the lock, then re-reads fresh
state before proceeding — it never acts on a stale read
(`lib/scheduler.sh` lines 56–70, citing this exact scenario as FR-043 in
its own comment, matching Clarification 13). Verified by
`tests/test_scheduler_lock.sh` (part of `make test`), which drives two
concurrent invocations against the same state directory and asserts no
lost update.

### What happens when a multi-GB model download is interrupted mid-transfer (network drop, disk full, Ctrl+C)?

**Status: current behavior.**

`lib/download.sh` downloads into a `<file>.part` sidecar using
`curl -fL --continue-at - --retry 3 --retry-delay 5 -o "${part}" "${url}"`
(line 144). Re-running the download resumes via an HTTP Range request
against the existing `.part` file. If the server doesn't support Range
requests (curl exit code 33), the stale `.part` file is discarded and the
download restarts from byte 0 rather than hard-failing (lines 148–158,
documented inline as a deliberate fallback, not a bug). sha256 is verified
only once the file is fully reassembled, and the atomic rename into the
final path happens only after that verification succeeds (lines 162–167) —
matching Clarification 15 exactly. Verified by
`tests/test_download_resume.sh` (part of `make test`, using a synthetic
interrupted-transfer fixture — no real multi-GB network transfer needed to
exercise the resume logic itself; the real multi-GB download path is
exercised manually per `docs/quickstart.md` section 2 as a release-gating
step).

### What happens when a host is configured for cluster mode but its local `llmctld` daemon is unreachable?

**Status: current behavior (CLI-side hard-fail), even though the daemon it targets is not yet built.**

`lib/cluster.sh`'s `cluster::require_daemon()` probes
`GET /v1/cluster/status` against the configured
`LLMCTL_CLUSTER_ENDPOINT`. If that probe fails, it hard-fails immediately
with an explicit error naming the daemon and exactly how to restart it on
both supported OSes, and states outright that `llmctl` never silently falls
back to single-host scheduling — because doing so would misrepresent which
mode actually served the request:

```
die "llmctld unreachable at ${LLMCTL_CLUSTER_ENDPOINT} - cluster mode requires the daemon to be running. ..."
```

(`lib/cluster.sh` lines 59–70), matching Clarification 12 verbatim. This
guard is real and already wired into every `bin/llmctl cluster|tenant|apikey`
subcommand (`bin/llmctl` lines 195, 206, 218). What it guards, however — a
working `llmctld` daemon — does not exist yet; see the note at the top of
this document. Today, `cluster::require_daemon` will always report the
daemon unreachable, because there is no real daemon to reach.

---

## Distributed cluster orchestration (User Story 7)

**Status for this whole section: planned (Phase 9, US7).** None of the
following exists in this repository today. `llmctld/internal/raft/fsm.go`
and `llmctld/internal/cluster/state.go` are early scaffolding types with
unit tests of their own internal logic, but there is no Raft transport, no
node bootstrap/join/leave, no placement/bin-packing algorithm, no health
loop, and no partition-handling code (`internal/raft/transport.go`,
`internal/raft/node.go`, `internal/cluster/placement.go`, and
`internal/cluster/health.go` — named in `specs/001-llmctl-completion/tasks.md`
Phase 9, tasks T049–T058 — do not exist under `llmctld/`).

### What happens when a cluster node fails?

**Status: planned (Phase 9, US7).** Per spec.md and tasks.md T053/T054, the
design intent is: a 10-second health-check loop against each node's
`/v1/cluster/status` detects the failure, the Raft leader initiates
rescheduling via a bin-packing placement algorithm, and the failed node's
models are rescheduled onto healthy nodes within 30 seconds with zero data
loss (SC-015).

### What happens during a network partition?

**Status: planned (Phase 9, US7).** Per spec.md and tasks.md T055, the
design intent is: on quorum loss the minority partition's node drains
in-flight requests and stops accepting new ones, then steps down; the
majority partition continues serving (SC-016).

### What happens when a model exceeds a single node's VRAM?

**Status: planned (Phase 9, US7).** Per spec.md and tasks.md T057, the
design intent is tensor/model-parallelism placement hints in the
placement algorithm so the model is split across multiple nodes, with
throughput targeted within 15% of a single-node baseline (SC-017). Tasks.md
explicitly notes this may need to be marked `[OPEN]` (Constitution
§11.4.223 provenance marker) if full tensor-parallel execution is deferred
past the first pass at this phase.

### What happens when the Raft leader fails?

**Status: planned (Phase 9, US7).** Per spec.md and tasks.md T049/T050
(`internal/raft/node.go`'s `LeaderCh() <-chan bool`), the design intent is a
new leader election completing within 5 seconds, after which the new
leader continues cluster operations (SC-013).

### What happens when a model replica fails its health check?

**Status: planned (Phase 9, US7).** Per spec.md and tasks.md T052a, the
design intent is: the unhealthy replica is marked unhealthy and removed
from the load balancer, and a placement reconciliation pass spawns a
replacement replica on a healthy node to maintain the configured target
replica count (default N=3), keeping availability at 99.9% with one
replica tolerated as failed (SC-018).

### What happens during a split-brain scenario?

**Status: planned (Phase 9, US7).** Per spec.md, the design intent is that
Raft's own quorum requirement prevents split-brain by construction: a
partition that cannot reach quorum cannot elect a leader or commit writes,
so the minority partition's node steps down rather than continuing to
serve as if it were authoritative.

### What happens to an in-flight streaming (SSE) completion during a planned drain or minority-partition drain?

**Status: planned (Phase 9, US7).** Per spec.md and tasks.md T055
(Clarification 22), the design intent is: the draining node lets
already-accepted streams finish within a bounded ~30-second grace period
while refusing all new requests immediately, so no in-flight response is
truncated mid-token.

---

## Model state persistence & recovery (User Story 8)

**Status for this whole section: planned (Phase 10, US8).** None of
`internal/replication/wal.go`, `internal/replication/checkpoint.go`, or
`internal/replication/lora.go` (named in tasks.md T059–T064) exist under
`llmctld/` today.

### What happens when a KV cache checkpoint fails, or the WAL grows too large?

**Status: planned (Phase 10, US8).** Per spec.md and tasks.md T059/T060/T063,
the design intent is: checkpoint failure doesn't stop WAL logging — the
next checkpoint attempt simply includes the previously-missed delta. If the
WAL grows too large, an early checkpoint is forced and the WAL is truncated
once that checkpoint succeeds. The target bounds are ≤5% token loss and
≤30s recovery time on failover (SC-019), with checkpoint interval
configurable by token count or elapsed time (SC-020).

### What happens when a LoRA adapter checkpoint fails?

**Status: planned (Phase 10, US8).** Per spec.md and tasks.md T061, the
design intent is synchronous LoRA adapter replication on creation, with
retry using exponential backoff on failure and an alert raised on repeated
failure, so adapter state is preserved exactly across failover/scaling
(SC-019 second definition in spec.md).

---

## Authentication, authorization & multi-tenancy (User Story 9)

**Status for this whole section: planned (Phase 11, US9).** None of
`internal/auth/jwt.go`, `internal/auth/rbac.go`, `internal/auth/apikey.go`,
`internal/auth/oidc.go`, `internal/tenancy/tenant.go`, or
`internal/tenancy/quota.go` (named in tasks.md T065–T074a) exist under
`llmctld/` today.

### What happens when a tenant exceeds its quota?

**Status: planned (Phase 11, US9).** Per spec.md and tasks.md T070, the
design intent is a `429` response with a `Retry-After` header, enforced
within 1ms of the limit being reached, with zero impact on other tenants
(SC-023).

### What happens when an API key is compromised?

**Status: planned (Phase 11, US9).** Per spec.md and tasks.md T067, the
design intent is: rotating the key immediately revokes the old value (a
rotated key's old value is rejected on the very next request), and the
audit log traces every request the compromised key was used for.

### What happens when a tenant admin tries to access another tenant's models?

**Status: planned (Phase 11, US9).** Per spec.md and tasks.md T069, the
design intent is: the access is denied by tenant namespace isolation
(Tenant A's models are invisible to Tenant B without an explicit share),
and the audit log records the attempt.

### What happens when the OIDC provider is unavailable, and what happens once the 5-minute fallback cache then expires?

**Status: planned (Phase 11, US9).** Per spec.md and tasks.md T068
(Clarification 24), the design intent is a two-stage fallback: while the
OIDC provider is unreachable, previously-cached tokens remain valid for up
to 5 minutes and local auth continues to serve OIDC-backed sessions from
that cache. Once that 5-minute cache expires and OIDC is *still*
unavailable, new requests requiring OIDC-backed identity are denied with
`401` until OIDC recovers; sessions backed by non-OIDC local auth are
unaffected by any of this.

### What happens if the audit log itself is tampered with (an entry deleted, reordered, or the log truncated)?

**Status: partially implemented — algorithm built and unit-tested; not yet wired into any live decision path.**

This one needs the most precise honesty of any entry in this document,
because it sits exactly between "current" and "planned."

The tamper-evidence *algorithm* is real, implemented, and passing today:
`llmctld/internal/audit/log.go` implements a hash-chained, append-only
audit log where each entry chains to the previous entry's hash, plus a
periodic Anchor record (head hash + entry count) that catches what a
forward hash-chain alone cannot — an attacker who deletes an entry and then
correctly recomputes every subsequent hash forward, or truncates the tail
of the log. This directly implements Constitution §11.4.268 and is proven
by real, passing tests in `llmctld/internal/audit/log_test.go`:
`TestVerifyChain_CleanChainPasses`,
`TestVerifyChain_TamperedMiddleEntryDetected`,
`TestVerifyChain_DoesNotCatchDeletionRecomputedForward` (the test that
proves the honest limit of chain-only verification),
`TestVerifyAgainstAnchor_DetectsWhatChainAloneCannot`,
`TestVerifyAgainstAnchor_DetectsTailTruncation`, and
`TestVerifyAgainstAnchor_CleanLogPasses`. Run with `cd llmctld && go test
./internal/audit/...`.

What is **not yet built**: this audit log is not yet wired into any real
authZ/authN decision path, because there is no JWT validation, RBAC check,
or quota check for it to observe yet (those are Phase 11, US9, tasks
T065–T070). Wiring it into every such decision path — so 100% of real
authZ/authN decisions actually produce a chained entry — is explicit future
work: tasks.md T071 ("Wire the audit log ... into every authZ/authN
decision path"). Until that wiring lands, the audit log's tamper-evidence
guarantee is proven correct against *synthetic* entries in its own test
suite, not yet exercised by any real request flowing through `llmctld`.

---

## Release automation (User Story 5)

**Status for this whole section: planned (Phase 8, US5).** No
`scripts/release/` directory exists in this repository today; searching
the repo root and `Makefile` for release automation confirms only
third-party submodules (`llama.cpp`, `colibri`, the `constitution`
submodule) have their own, unrelated release scripts.

### What happens when `gh release create` succeeds but `glab release create` fails, or vice versa?

**Status: planned (Phase 8, US5).** Per spec.md and tasks.md T045
(Clarification 19), the design intent is: the whole release is treated as
failed/not-published regardless of which single forge succeeded, and the
release script is idempotent — a re-run retries only the forge that failed,
without re-creating (and thus duplicating) the one that already succeeded.

### What happens when a pinned submodule's ref is unreachable at release-packaging time (upstream private/deleted/rate-limited)?

**Status: planned (Phase 8, US5).** Per spec.md and tasks.md T044
(Clarification 21), the design intent is a `scripts/release/preflight_submodules.sh`
that verifies every pinned submodule ref — including the constitution
submodule's 17 nested submodules — is fetchable before packaging, and
hard-fails naming the specific unreachable submodule and its expected ref;
no release artifact is ever produced with a missing or empty submodule
directory.

Note: this is distinct from `lib/doctor.sh`'s existing, *current* submodule
check, which only confirms `submodules/llama.cpp` and `submodules/colibri`
are initialized in the local working tree (`_doc_pass "submodule ${m}
initialized (...)"` / `_doc_warn "submodule ${m} not initialized"` — see
`lib/doctor.sh` lines 59–63). That check runs today as part of `llmctl
doctor`/`llmctl setup`, but it verifies local initialization, not
release-packaging-time reachability of every pinned ref across all 17+
nested submodules — the release-specific preflight described above does
not exist yet.
