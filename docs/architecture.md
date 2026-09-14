# Architecture

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
vendor/             llama.cpp v0.4.0, colibri v1.11.0 (git submodules)
```

Data flow: `hw` (probe) → `plan` (planner) → `models download` (verified
fetch + smoke test) → `start/auto/switch` (scheduler) → service backend
(systemd `--user` or launchd, chosen by OS).

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
`switch` stops everything and starts exactly one profile.

## Service backends

* Linux: two template units `llmctl-llama@.service` /
  `llmctl-colibri@.service` installed into `~/.config/systemd/user/`.
  `Restart=always`, `RestartSec=5`, `StartLimitIntervalSec=0`,
  `MemoryHigh`/`MemoryMax` = 90% / 100% of (probed RAM − 4 GiB), logs appended
  to `~/.local/state/llmctl/logs/<profile>.log`, linger enabled via
  `loginctl enable-linger` (with a sudo fallback hint).
* macOS: `~/Library/LaunchAgents/com.llmctl.<profile>.plist` with
  `KeepAlive`, `ThrottleInterval=5`, `RunAtLoad`, the same log paths.

Both backends honor `LLMCTL_DRY_RUN=1`: files are generated for real,
process-management calls are printed instead of executed.

## Port map

Fixed per profile (documented in README/integrations): 8080 fast, 8081 coder,
8082 vision, 8083 vision-pro, 8084 moe-fast, 8085 small, 8086 ws-dense-32b,
8087 ws-moe-30b, 8090 colibri-glm, 8091 colibri-qwen36. All services bind to
`127.0.0.1` only.
