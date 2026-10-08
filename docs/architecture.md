# Architecture

**Revision:** 4
**Last modified:** 2026-10-08T00:00:00Z

## Layout

```
bin/llmctl          CLI entrypoint (dispatches to the libs below)
lib/common.sh       logging/colors/die, XDG-aware paths, JSON helpers (python3)
lib/os_detect.sh    linux/macos, arch, nproc, package-manager hints
lib/hardware.sh     dynamic probe: CPU/SIMD, RAM, GPUs, storage type
lib/catalog.sh      catalog queries + the hardware planner
lib/download.sh     resumable, checksummed downloads + smoke tests + evidence
lib/engine.sh       llama.cpp / colibri builds from pinned submodules
                    (the onnx engine has no build step - pip hints only)
lib/scheduler.sh    co-residency, switching, auto (LRU eviction)
lib/service_linux.sh  systemd --user template units + linger
lib/service_macos.sh  launchd LaunchAgents
lib/doctor.sh       environment self-diagnosis
lib/decide.sh       thin bash front end of the typed decisions (delegates to llmctl-decide)
cmd/llmctl-decide/  Go decision binary: HTTPS gateway (POST /v1/systemone, port 8095),
                    client (ask/batch/models), key, cert, registry, smoke
internal/{gateway,server,contract,readout,client,keyring,certs,registry,...}
                    the Go packages behind it (drivers per decision protocol,
                    HTTP server, wire contract, logprob readout, ...)
lib/onnx_server.py  onnx engine runner: the INTERNAL encoder scoring runtime
                    (POST /v1/score only; typed questions are answered in Go),
                    CPU-only (e.g. decide-nli, port 8096)
models/catalog.json profiles with real sha256 + byte sizes (HF API-sourced)
tests/              deterministic harness + fixtures
submodules/         llama.cpp (tag b11379, was b10969), colibri v1.11.0, containers, (git submodules)
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
* `onnx`-engine profiles (encoder decision models, CPU-only inference):
  VRAM 0, RAM reservation = `model size × 1.5 + 512 MiB` (weights are
  loaded once at ~1.0×, plus onnxruntime's session/arena overhead).

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
    START["profile requested<br/>(start / auto / switch)"] --> KV["estimate KV cache<br/>ctx x parallel x type-ratio / 8 MiB<br/>(type-ratio=1.0 for f16, less when<br/>kv_cache_type/LLMCTL_KVTYPE_&lt;P&gt; quantizes it)"]
    KV --> ENGINE{engine?}
    ENGINE -->|llama.cpp| FITVRAM{"model + KV<br/>&le; VRAM budget?"}
    FITVRAM -->|yes| GPU["mode = gpu<br/>full offload, ngl from catalog"]
    FITVRAM -->|no| FITRAM{"model + KV<br/>&le; RAM budget?"}
    FITRAM -->|yes| CPU["mode = cpu<br/>ngl 0"]
    FITRAM -->|no| REFUSE["refuse: exact numbers +<br/>suggested alternative"]
    ENGINE -->|colibri| STORAGE{"repo + 10%<br/>&le; free storage?"}
    STORAGE -->|yes| MMAP["mode = colibri<br/>mmap from NVMe, RAM 8/24 GiB"]
    STORAGE -->|no| REFUSE
    ENGINE -->|onnx| FITONNX{"size x 1.5 + 512 MiB<br/>&le; RAM budget?"}
    FITONNX -->|yes| ONXCPU["mode = cpu<br/>VRAM 0 (CPU-only encoder inference)"]
    FITONNX -->|no| REFUSE
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

* Linux: three template units `llmctl-llama@.service` /
  `llmctl-colibri@.service` / `llmctl-onnx@.service` installed into
  `~/.config/systemd/user/`.
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
        L1["llmctl install"] --> L2["systemd --user template units<br/>llmctl-llama@.service<br/>llmctl-colibri@.service<br/>llmctl-onnx@.service"]
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

Fixed per profile (the authoritative list, generated from `models/catalog.json`, is [ports](ports.md)): 8080 fast, 8081 coder,
8082 vision, 8083 vision-pro, 8084 moe-fast, 8085 small, 8086 ws-dense-32b,
8087 ws-moe-30b, 8090 colibri-glm, 8091 colibri-qwen36, 8092 decide-tiny,
8093 decide, 8094 decide-pro, 8096 decide-nli, 8097 decide-max,
8098 decide-2b, and the six native-protocol decision profiles 8103 decide-julia,
8104 decide-kev-08b, 8105 decide-kev-4b, 8106 decide-kev-9b, 8107 decide-laya,
8108 decide-lev; the decide gateway (`llmctl decide serve`)
listens on 8095. Binding differs by kind: the **chat** engines bind `LLMCTL_BIND_HOST`
(default `0.0.0.0`, LAN-accessible, see the README's safety section); the **decision engines**
(and the `onnx` runtime) are launched loopback-only behind the gateway; the **gateway** binds
`LLMCTL_DECIDE_BIND` (default `0.0.0.0`) over HTTPS with a mandatory key. With
`LLMCTL_PORT_STRATEGY=dynamic` these ports are replaced by bind-tested ports from a per-user
range ([registry-discovery](registry-discovery.md)), and `LLMCTL_PORT_<PROFILE>` moves one profile
(see [ports](ports.md)). The diagram below shows every catalog profile; decision profile details are in [decision-models](decision-models.md).

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
    subgraph "Decision profiles"
        P8092["8092<br/>decide-tiny (llama)"]
        P8093["8093<br/>decide (llama)"]
        P8094["8094<br/>decide-pro (llama)"]
        P8096["8096<br/>decide-nli (onnx)"]
        P8098["8098<br/>decide-2b (llama)"]
        P8097["8097<br/>decide-max (llama)"]
        P8103["8103<br/>decide-julia (native)"]
        P8104["8104<br/>decide-kev-08b (native)"]
        P8105["8105<br/>decide-kev-4b (native)"]
        P8106["8106<br/>decide-kev-9b (native)"]
        P8107["8107<br/>decide-laya (native)"]
        P8108["8108<br/>decide-lev (native)"]
        P8095["8095<br/>decide gateway"]
    end
    ALL["chat engines: LLMCTL_BIND_HOST (default 0.0.0.0)<br/>decision engines: 127.0.0.1 only<br/>gateway: HTTPS, LLMCTL_DECIDE_BIND"] --- P8080 & P8081 & P8082 & P8083 & P8084 & P8085 & P8086 & P8087 & P8090 & P8091 & P8092 & P8093 & P8094 & P8095 & P8096 & P8097 & P8098 & P8103 & P8104 & P8105 & P8106 & P8107 & P8108
```

## Decision subsystem (llmctl 3.1.0)

Reference for each box: [decide-gateway](decide-gateway.md), [decision-models](decision-models.md), [registry-discovery](registry-discovery.md), [tls-and-keys](tls-and-keys.md).
The diagrams below were written from the code (`cmd/llmctl-decide`, `internal/*`, `lib/svc_hook.sh`, `lib/service_linux.sh`) and are syntax-checked; see [diagram checking](#diagram-checking).

### System architecture

```mermaid
flowchart LR
    CLIENT["clients<br/>llmctl decide ask / batch<br/>TypeSafe SDKs / agent hooks / MCP"] -->|"HTTPS, CA-verified,<br/>Bearer access key"| GW
    subgraph HOST["one user's host"]
        GW["llmctl-decide serve<br/>(gateway, :8095)<br/>auth, limits, contract, readout"]
        CERT[("$LLMCTL_HOME/cert<br/>CA + leaf")] -.-> GW
        KEY[(".env access key<br/>0600")] -.-> GW
        REG[("registry<br/>$LLMCTL_STATE_DIR/registry")] <-->|"discover / follow"| GW
        GW -->|"HTTP loopback<br/>internal key file"| LL["llama-server<br/>letter-logit / systemone-native<br/>decide, decide-pro, decide-2b, decide-max"]
        GW -->|"HTTP loopback<br/>internal key file"| ON["lib/onnx_server.py<br/>POST /v1/score<br/>decide-nli"]
        SCHED["llmctl start / enable / auto<br/>(scheduler + systemd/launchd)"] --> LL & ON
        SCHED -->|"register / unregister<br/>(svc_hook.sh)"| REG
        LOG[("decide-requests.jsonl<br/>keyed state hash")] <-.- GW
    end
```

### Data flow of one request

```mermaid
flowchart TD
    A["POST /v1/systemone<br/>{model, state, questions}"] --> B{"TLS 1.2+<br/>connection admitted?"}
    B -->|"no: per-source / unauth caps,<br/>pre-auth timeout"| X1["connection reset"]
    B -->|yes| C{"Bearer key valid?<br/>(constant-time)"}
    C -->|no| X2["401 / 429 (throttle)"]
    C -->|yes| D["parse + validate contract<br/>(size, question count, option caps)"]
    D -->|invalid| X3["400 / 413 / 422"]
    D --> E["resolve model to profile<br/>and engine via registry or static endpoint"]
    E -->|none ready| X4["503 not_ready"]
    E --> F["budget: state chars + estimated tokens<br/>vs context (engine /props)"]
    F -->|over budget, truncation off| X5["422 validation_failed"]
    F --> G{"protocol"}
    G -->|letter-logit| H["render lettered prompt,<br/>ONE token + first-token logprobs"]
    G -->|nli-onnx| I["one premise/hypothesis pair<br/>per option to /v1/score"]
    G -->|systemone-native| J["engine's own /v1/systemone,<br/>answer re-validated"]
    H --> K["readout: letter probabilities,<br/>option_missing bound, temperature"]
    I --> K2["entailment column by label name"]
    K --> L["shape answer: probabilities,<br/>confidence, usage estimate"]
    K2 --> L
    J --> L
    L -->|"mass below threshold"| X6["422 readout_failed"]
    L --> M["200 + x-llmctl-decide-mode / -instance<br/>request log line"]
```

### State machine: registry row

```mermaid
stateDiagram-v2
    [*] --> Allocated: port allocate (bind-tested hold)
    Allocated --> Registered: register (pid + start time + argv hash)
    Allocated --> [*]: hold unbound longer than port-grace
    Registered --> Healthy: health probe ok (TLS-verified for https)
    Healthy --> Unhealthy: probe fails
    Unhealthy --> Healthy: probe ok again
    Registered --> Unknown: https entry, no CA found
    Unknown --> Healthy: CA available and probe ok
    Unhealthy --> [*]: process gone, or unhealthy longer than reconcile grace
    Healthy --> [*]: unregister / process gone
    Unknown --> [*]: only with --prune-unknown-after D
```

### State machine: engine service (systemd --user)

```mermaid
stateDiagram-v2
    [*] --> Installed: llmctl install
    Installed --> Starting: llmctl start / enable
    Starting --> Loading: ExecStart (svc_hook run-engine)
    Loading --> Running: engine listens, ExecStartPost registers it
    Loading --> Failed: exit before ready
    Running --> Failed: crash
    Failed --> Starting: Restart=always (max 5 in 60 s)
    Failed --> CrashLoop: StartLimit reached
    CrashLoop --> Installed: reset-failed and fix
    Running --> Stopped: llmctl stop / disable (unregister)
    Stopped --> Starting: start
```

### Sequence: `ask` over HTTPS

```mermaid
sequenceDiagram
    actor U as User or agent
    participant C as llmctl-decide ask
    participant G as gateway :8095
    participant R as registry
    participant E as engine (loopback)
    U->>C: --stdin / --state-file, question
    C->>C: resolve key (env, .env), load CA file
    C->>G: TLS handshake (CA-verified)
    C->>G: POST /v1/systemone, Authorization Bearer
    G->>G: admit connection, check key, validate, budget
    G->>R: pick healthy engine for profile
    G->>E: completion (1 token, logprobs) or /v1/score
    E-->>G: logprobs / scores
    G->>G: readout, shape answer
    G-->>C: 200 answers, usage, headers
    C-->>U: JSON (+ evidence), exit 0 / 10 abstained
```

Key rotation is drawn in [runbooks](runbooks.md#rotate-the-access-key).

### Diagram checking

The new diagrams in this section and in the runbooks were rendered with `mermaid-cli` (`mmdc`, headless Chromium) without error when the 3.1.0 documentation pass ran; re-check with `mmdc -i diagram.mmd -o out.svg` after editing one. A diagram is a description of the code at the time of writing, not a specification: where they disagree, the code wins.
