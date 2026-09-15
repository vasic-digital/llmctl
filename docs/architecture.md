# Architecture

**Revision:** 2
**Last modified:** 2026-09-15T00:00:00Z

## Layout

```
bin/llmctl          CLI entrypoint (dispatches to the libs below)
lib/common.sh       logging/colors/die, XDG-aware paths, JSON helpers (python3)
lib/os_detect.sh    linux/macos, arch, nproc, package-manager hints
lib/hardware.sh     dynamic probe: CPU/SIMD, RAM, GPUs, storage type
lib/catalog.sh      catalog queries + the hardware planner
lib/download.sh     resumable, checksummed downloads + smoke tests + evidence
lib/engine.sh       llama.cpp / colibri builds from pinned submodules
lib/scheduler.sh    co-residency, switching, auto (LRU eviction)
lib/service_linux.sh  systemd --user template units + linger
lib/service_macos.sh  launchd LaunchAgents
lib/doctor.sh       environment self-diagnosis
models/catalog.json profiles with real sha256 + byte sizes (HF API-sourced)
tests/              deterministic harness + fixtures
submodules/         llama.cpp v0.4.0, colibri v1.11.0 (git submodules)
llmctld/            opt-in Go cluster daemon (Phase 2 scaffolding only —
                    internal/cluster, internal/raft, internal/mtls,
                    internal/audit; no HTTP API routes exist yet, see
                    docs/cluster-architecture.md's honest boundary)
```

Data flow: `hw` (probe) → `plan` (planner) → `models download` (verified
fetch + smoke test) → `start/auto/switch` (scheduler) → service backend
(systemd `--user` or launchd, chosen by OS).

```mermaid
flowchart LR
    HW["llmctl hw<br/>(hardware probe)"] --> PLAN["llmctl plan<br/>(tier + catalog matching)"]
    PLAN --> DL["llmctl models download<br/>(sha256 verify + smoke test)"]
    DL --> SCHED["llmctl start / auto / switch<br/>(scheduler: budgets, co-residency, LRU eviction)"]
    SCHED --> SVC{OS?}
    SVC -->|Linux| SYSTEMD["systemd --user<br/>template units"]
    SVC -->|macOS| LAUNCHD["launchd<br/>LaunchAgents"]
    SYSTEMD --> SERVER["llama-server / coli serve<br/>127.0.0.1:&lt;port&gt;"]
    LAUNCHD --> SERVER
    SERVER --> AGENT["CLI agent<br/>(opencode, aider, Claude Code, ...)"]
```

## Memory model (planner)

Deliberately simple and conservative:

* RAM budget = `MemAvailable − 4 GiB` headroom.
* VRAM budget = `total VRAM × 0.85` (15% headroom).
* KV cache estimate = `ctx_tokens × parallel_slots / 8` MiB — a conservative
  upper estimate for f16 KV across the catalog's architectures.
* GGUF profiles choose between exactly two modes:
  `gpu` (full offload, `ngl` from catalog defaults, 2 GiB host RAM) when
  `model + KV ≤ VRAM budget`, else `cpu` (`ngl 0`) when
  `model + KV ≤ RAM budget`, else the profile does not fit.
* Colibri profiles memory-map weights from NVMe: VRAM 0, RAM reservation
  8 GiB (<100 GiB repos) or 24 GiB (larger), storage must fit the repo +10%.

Co-residency groups are computed by greedy bin-packing of the recommended
profiles (in port order) against both budgets.

**Note on the two distinct memory-budget mechanisms in this project** (an
operator decision recorded 2026-09-15, Phase 6/T035): the planner's RAM/VRAM
*budgets* above are an **admission-control** check — they decide whether
llmctl should let a *new* profile start alongside what is *already running*,
to avoid overcommitting across several co-resident profiles (thrashing/swap
death would hurt every running profile's performance, which is the opposite
of this project's goal). This is deliberately unrelated to, and NOT the same
mechanism as, the systemd/launchd `MemoryMax`/`MemoryHigh` OS-level ceiling
described in "Service backends" below, which governs one *already-running*
service's own hard resource limit.

```mermaid
flowchart TD
    START["profile requested<br/>(start / auto / switch)"] --> KV["estimate KV cache<br/>ctx x parallel / 8 MiB"]
    KV --> ENGINE{engine?}
    ENGINE -->|llama.cpp| FITVRAM{"model + KV<br/>&le; VRAM budget?"}
    FITVRAM -->|yes| GPU["mode = gpu<br/>full offload, ngl from catalog"]
    FITVRAM -->|no| FITRAM{"model + KV<br/>&le; RAM budget?"}
    FITRAM -->|yes| CPU["mode = cpu<br/>ngl 0"]
    FITRAM -->|no| REFUSE["refuse: exact numbers +<br/>suggested alternative"]
    ENGINE -->|colibri| STORAGE{"repo + 10%<br/>&le; free storage?"}
    STORAGE -->|yes| MMAP["mode = colibri<br/>mmap from NVMe, RAM 8/24 GiB"]
    STORAGE -->|no| REFUSE
```

## Scheduler state

* `~/.local/state/llmctl/services/<profile>.env` — launch parameters
  (systemd `EnvironmentFile`; also the record the macOS plist is rendered
  from). `<profile>.enabled` marks autostart-enabled services.
* `$XDG_RUNTIME_DIR/llmctl/<profile>.run` (fallback
  `~/.local/state/llmctl/run/`) — reservation record of a running service:
  mode, port, reserved RAM/VRAM MiB, start epoch.

`start` re-probes hardware, subtracts live reservations, and refuses with
exact numbers + a fitting alternative when the combined footprint exceeds the
budgets. `auto <capability>` picks the best-ranked recommended profile per
capability (fixed ranking tables in `sched_rank_for_capability`) and, when
space is short, evicts **non-enabled** services oldest-first (LRU).
`switch` stops everything and starts exactly one profile. Every scheduler
mutation acquires `scheduler::with_lock` (an advisory `flock`) first, so two
concurrent `llmctl` invocations (e.g. a cron job racing an interactive user)
never lose an update — the second waits, re-reads state after the first
releases, then proceeds (proven by `tests/test_scheduler_lock.sh`: 200
concurrent increments lose zero updates).

```mermaid
stateDiagram-v2
    [*] --> Stopped
    Stopped --> Starting: start / auto / enable
    Starting --> Running: budget check passes
    Starting --> Stopped: budget refused (exact numbers + alternative)
    Running --> Evicting: auto needs room (LRU, non-enabled only)
    Evicting --> Stopped: service stopped, reservation removed
    Running --> Stopped: stop / switch
    Running --> CrashLoop: process exits repeatedly within StartLimitIntervalSec
    CrashLoop --> Failed: StartLimitBurst exceeded
    Failed --> Starting: restart / re-enable (operator-initiated)
    Running --> [*]: stop all
```

## Service backends

* Linux: two template units `llmctl-llama@.service` /
  `llmctl-colibri@.service` installed into `~/.config/systemd/user/`.
  `Restart=always`, `RestartSec=5`, bounded restarts via
  `StartLimitBurst=5` within `StartLimitIntervalSec=60` (once exceeded the
  unit stops and `llmctl status` reports `failed (crash-loop)` with the
  last captured log line, rather than looping forever — Constitution
  Clarification 14). `MemoryHigh`/`MemoryMax` = the full probed total
  system RAM (an operator decision, 2026-09-15: no artificial ceiling below
  hardware capacity — see the memory-model note above; the directives still
  cgroup-contain a runaway profile to a clean OOM-kill of just that service
  rather than an uncontrolled whole-host kernel OOM event). Logs appended
  to `~/.local/state/llmctl/logs/<profile>.log`, linger enabled via
  `loginctl enable-linger` (with a sudo fallback hint).
* macOS: `~/Library/LaunchAgents/com.llmctl.<profile>.plist` with
  `KeepAlive`, a widened `ThrottleInterval=60` (launchd has no native
  give-up-after-N-restarts mechanism the way systemd's `StartLimitBurst`
  does — this is an honest, documented platform-parity gap; the 60s
  interval bounds the *rate* of restarts, not the total attempt count),
  `RunAtLoad`, the same log paths. launchd has no clean per-process
  memory-ceiling analog to systemd's cgroup `MemoryMax`/`MemoryHigh`, so no
  equivalent directive is set on macOS.

Both backends honor `LLMCTL_DRY_RUN=1`: files are generated for real,
process-management calls are printed instead of executed.

```mermaid
flowchart TD
    subgraph Linux
        L1["llmctl install"] --> L2["systemd --user template units<br/>llmctl-llama@.service<br/>llmctl-colibri@.service"]
        L2 --> L3["Restart=always, RestartSec=5<br/>StartLimitBurst=5 / IntervalSec=60<br/>MemoryMax=MemoryHigh=full probed RAM"]
        L3 --> L4["~/.local/state/llmctl/logs/&lt;profile&gt;.log"]
    end
    subgraph macOS
        M1["llmctl install"] --> M2["~/Library/LaunchAgents/<br/>com.llmctl.&lt;profile&gt;.plist"]
        M2 --> M3["KeepAlive, RunAtLoad<br/>ThrottleInterval=60<br/>(no memory-ceiling analog)"]
        M3 --> L4
    end
```

## Port map

Fixed per profile (documented in README/integrations): 8080 fast, 8081 coder,
8082 vision, 8083 vision-pro, 8084 moe-fast, 8085 small, 8086 ws-dense-32b,
8087 ws-moe-30b, 8090 colibri-glm, 8091 colibri-qwen36. All services bind to
`127.0.0.1` only.

```mermaid
flowchart LR
    subgraph "GGUF profiles (llama.cpp)"
        P8080["8080<br/>fast"]
        P8081["8081<br/>coder"]
        P8082["8082<br/>vision"]
        P8083["8083<br/>vision-pro"]
        P8084["8084<br/>moe-fast"]
        P8085["8085<br/>small"]
        P8086["8086<br/>ws-dense-32b"]
        P8087["8087<br/>ws-moe-30b"]
    end
    subgraph "Colibri profiles (mmap from NVMe)"
        P8090["8090<br/>colibri-glm"]
        P8091["8091<br/>colibri-qwen36"]
    end
    ALL["127.0.0.1 only<br/>(no external bind)"] --- P8080 & P8081 & P8082 & P8083 & P8084 & P8085 & P8086 & P8087 & P8090 & P8091
```
