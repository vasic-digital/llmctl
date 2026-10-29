# Host capacity and the host reserve (`llmctl capacity`, `llmctl reserve`)

| Field | Value |
|---|---|
| Revision | 2 |
| Created | 2026-10-28 |
| Since | 3.4.0 |
| Code | `lib/reserve.sh`, `lib/capacity.sh`, `lib/service_linux.sh` (`_svc_resource_directives`), `lib/svc_hook.sh` (unit gate), `lib/scheduler.sh` (admission). `llmctld` runs `bin/llmctl` and has no reserve code of its own |
| Tests | `tests/test_host_reserve.sh`, `tests/test_capacity.sh`, `tests/test_host_reserve_review.sh` (unit-class, hermetic fixtures) |
| Live evidence | `scripts/qa/host_reserve_live.sh` -> `docs/qa/2026-10-28-host-reserve/` |

## Why

On 2026-10-28 one local decision model under four parallel requests used 5 to 6.5 CPUs of a 16-CPU host, and two
models could take every CPU. The root causes (measured, see `docs/host-safety.md` "Host reserve"):

| # | Cause |
|---|---|
| RC1 | `llama-server` was started without `--threads`; it ran 28 threads |
| RC2 | no unit had `CPUQuota=` or a CPU affinity |
| RC3 | a unit's `MemoryMax` could reach 90% of RAM, the start gate kept a fixed 4 GiB, nothing summed the limits of running units |
| RC4 | the start gate looked at memory PSI only, never at CPU PSI or load |
| RC5 | the smoke-test launch had no thread cap |

## The reserve (computed from the live host, nothing hard-coded per machine)

| Symbol | Formula | Knob (default; only stricter is accepted) |
|---|---|---|
| N | online CPUs (`/sys/devices/system/cpu/online`) | |
| Rc | `max(MIN, ceil(N*PCT/100))`, rounded up to whole physical cores (SMT siblings together), at most N-1 | `LLMCTL_RESERVE_CPU_MIN` (2), `LLMCTL_RESERVE_CPU_PCT` (25) |
| Bc | `N - Rc` - CPUs all llmctl models together may use | |
| chat cap | `max(1, floor(Bc*CHAT/100))` threads and CPUQuota | `LLMCTL_CHAT_CPU_PCT` (50) |
| decide cap | `max(1, floor(Bc*DECIDE/100))`, never above the chat cap | `LLMCTL_DECIDE_CPU_PCT` (25) |
| Rm | `max(MIN_MB, MemTotal*PCT/100)` | `LLMCTL_RESERVE_MEM_MIN_MB` (4096), `LLMCTL_RESERVE_MEM_PCT` (20) |
| Bm | `MemTotal - Rm` - the sum of all llmctl unit memory limits. Below 512 MiB the host is "short": every local start is refused (75) | |

Only stricter values are honoured: the reserve percentages accept 25..100 (CPU) and 20..100 (memory), the memory minimum
4096 MiB or more, the per-model caps 1..50 (chat) and 1..25 (decision). A looser or non-numeric value falls back to the
default; `llmctl reserve --json` shows the effective value.

Every llmctl engine unit gets, with the reserve on:

| Directive | Value |
|---|---|
| `CPUQuota=` | cap x 100% |
| `CPUAffinity=` / `AllowedCPUs=` | the model CPU set (the reserved cores are never in it). `AllowedCPUs` needs the `cpuset` controller delegated to the user manager; where it is not, `CPUAffinity` is what binds |
| `--threads` / `OMP_NUM_THREADS` | cap |
| `Nice=` / `CPUWeight=` / `IOWeight=` | 15 / 20 / 20 |
| `MemoryHigh=` / `MemoryMax=` | per profile, bounded so the sum over running units stays within Bm |
| `MemorySwapMax=` | 0 |
| `OOMScoreAdjust=` | 800 (the kernel kills the model long before the desktop) |

### The start gate

Before any unit is written or started (`start`, `switch`, `auto`, `enable`, `restart`, `decide scale`):

1. memory PSI gate (unchanged), plus CPU PSI `some avg10` above `LLMCTL_GATE_CPU_SOME_MAX` (default 80, clamped to
   0..80) or `load1` above `LLMCTL_GATE_LOAD_PER_CPU` x N (default 3, clamped to 1..3). The wait is bounded; a
   refusal exits **75** (`EX_TEMPFAIL`), prints `llmctl-fallback: cloud|none` and starts nothing.
2. the capacity verdict for the profile (below). `does_not_fit` exits **75** with a `llmctl-fallback:` line;
   `fits_with_reduced_threads` starts it with fewer threads and a lower CPUQuota (the override can only lower the cap).
   When the only reason is the planner's RAM/VRAM verdict, the planner path refuses instead (exit 1 with the exact MiB
   numbers), as before 3.4.0.
3. the admission fails closed: a capacity measurement that fails, times out or is empty (`undetermined`), an unknown
   profile, or an unreadable verdict refuses with **75** and the fallback line; it never lets a start through
   unchecked.

`restart` is judged as a start of the same profile that excludes the replaced unit's own limits and counts that unit's
resident memory as coming back. A restart keeps the unit's existing limits, so when only a reduced thread count would
fit it is refused (75; run `llmctl stop` then `llmctl start`). `decide scale <profile> <n>` judges all new instances
together at the full decision cap. Every unit's own `ExecStartPre` gate (systemd restarts and boot included)
re-checks the pressure, the load and the combined CPU + RAM budget within its bounded wait; it does not re-run the
per-profile verdict and prints no fallback line.

`enable` starts the profile now AND at login/boot (as before 3.4.0); the start now passes the same gate.

`LLMCTL_HOST_RESERVE=0` is a diagnostics switch that restores the pre-3.4.0 behaviour so the old failure can be
reproduced. It is reported loudly: `OFF` in `llmctl reserve`, `DISABLED` in `llmctl status` and `llmctl doctor`.

## `llmctl capacity [--json] [profile...]`

Re-evaluable at any time (it reads only `/proc`, `/sys/fs/cgroup` and the catalog; it changes nothing).

Exit codes: `0` every named profile fits (or none named and nothing is degraded); `75` a named profile does not fit, is
unknown, or the measurement is `undetermined` - then stderr also carries `llmctl-fallback: cloud|none` (never `local`);
`3` none named and a running llmctl unit is degraded.

### Time bounds

The measurement can never hang `start`, `llmctl capacity` or llmctld (a GPU probe such as `nvidia-smi` stuck on a wedged
driver used to hang them until killed). Each probe step (the hardware probe and the planner) gets
`LLMCTL_CAPACITY_PROBE_TIMEOUT` seconds (default **3**, clamped to 1..30, never more than the whole budget) and the
whole measurement `LLMCTL_CAPACITY_TIMEOUT` seconds (default **5**, clamped to 2..30); a non-integer value uses the
default. A probe that runs past its bound is killed together with every process it started (only that process tree,
by parent pid, each pid checked before it is signalled), and the result is a schema-compatible document with
`measurement.ok: false`, a `measurement.reason`, every named profile `undetermined` and a `cloud`/`none` fallback. A
healthy measurement took about 0.8 s on the 16-CPU reference host.

### Verdict vocabulary

llmctl keeps its own verdict names; `verdict_class` and `route` carry the anchor vocabulary (§11.4.230 / the host-reserve
mandate) so a consumer does not have to parse llmctl's names:

| `verdict` (llmctl)           | `verdict_class`  | meaning                                                                   |
|------------------------------|------------------|---------------------------------------------------------------------------|
| `fits`                       | `fits`           | a start would be admitted with the profile's full CPU cap                 |
| `fits_with_reduced_threads`  | `fits_reduced`   | admitted with `threads` < the cap (start only; restart and scale refuse)   |
| `does_not_fit`               | `does_not_fit`   | refused with 75                                                           |
| `undetermined`               | `undetermined`   | the measurement timed out or a probe failed; refused with 75              |
| `running`                    | `null`           | not a candidate verdict: this host's own unit instance is already up      |

| `fallback.recommended` | `fallback.route` |
|------------------------|------------------|
| `local`                | `local`          |
| `cloud`                | `hosted`         |
| `none`                 | `none`           |

Both fields are additive; the schema stays `llmctl.capacity/1`.

### JSON schema `llmctl.capacity/1`

```text
{
  "schema": "llmctl.capacity/1",
  "measurement": {"ok": bool, "reason": str (only when ok is false), "timeout_s": int, "probe_timeout_s": int},
  "host": {
    "cpus_online": int, "mem_total_mb": int, "mem_available_mb": int, "usable_mem_mb": int,
    "swap_total_mb": int, "swap_free_mb": int,
    "load": {"1": float, "5": float, "15": float},
    "psi": {"memory": {"some": float, "full": float}, "cpu": {"some": float}, "io": {"some": float, "full": float}},
    "cgroup": {"path": str, "memory_max_mb": int|null, "memory_current_mb": int|null, "cpu_max_pct": int|null}
  },
  "reserve": {
    "enabled": bool, "cpus_reserved": int, "cpus_reserved_set": str, "cpus_model_budget": int,
    "cpus_model_set": str, "chat_cpu_cap": int, "decide_cpu_cap": int,
    "mem_reserved_mb": int, "mem_model_budget_mb": int
  },
  "llmctl": {
    "units": [{"unit": str, "profile": str, "base_profile": str, "cpu_quota_pct": int|null, "memory_max_mb": int|null,
               "memory_current_mb": int|null, "status": "ok"|"degraded", "reasons": [str], "suggest": str|null}],
    "cpu_pct_used": int, "mem_limits_used_mb": int, "cpu_pct_free": int, "mem_budget_free_mb": int
  },
  "pressure": {"ok": bool, "reasons": [str]},
  "profiles": {
    "<profile>": {
      "class": "decide"|"chat",
      "verdict": "fits"|"fits_with_reduced_threads"|"does_not_fit"|"undetermined"|"running",
      "verdict_class": "fits"|"fits_reduced"|"does_not_fit"|"undetermined"|null, "running": bool,
      "reasons": [str], "threads": int,
      "headroom": {"cpu_pct_free": int, "cpu_pct_need": int, "mem_budget_free_mb": int,
                   "mem_limit_need_mb": int, "footprint_mb": int, "mem_available_after_mb": int}
    }
  },
  "unknown_profiles": [str],
  "largest_decision_fit": str|null,
  "degraded": bool,
  "fallback": {"recommended": "local"|"cloud"|"none", "route": "local"|"hosted"|"none", "reason": str,
               "key_variable": str|null}
}
```

- `fits_with_reduced_threads`: the CPU budget left is below the profile's cap but at least one CPU; `threads` is what
  `start` will use.
- `degraded` (per unit): host pressure (memory/CPU PSI or load over the gate) or the unit's memory at >= 90% of its
  limit; `suggest` is `llmctl stop <base_profile>` and is set only on a degraded unit. `base_profile` maps an instance
  unit (`decide-tiny.2`) or a tenant unit (`<tenant>--decide-tiny`) to its catalog profile; a profile whose own name
  contains a dot is kept intact.
- `running`: THIS host's own unit instance of the profile is already up - the tenant key (`LLMCTL_TENANT_ID`) plus the
  primary name, exactly the unit `start` would write. Another instance of the same profile (`decide-tiny.2`) or another
  tenant's unit (`t1--decide-tiny`) is NOT "running" for this start: it only counts as consumption, and the start is
  judged next to it (before review round 2 such a start was admitted unchecked). Under `restart` and `decide scale`
  the named profile is judged as a new start instead.
- `undetermined` (whole document, `measurement.ok: false`): the host fields are `null`, every named profile is
  `undetermined`, `pressure.ok` is false and the fallback is `cloud` or `none`.
- `fallback.recommended` is `local` when a decision profile fits or a decision unit is running and `ok` (never when a
  named profile was refused), `cloud` otherwise and one of the variables in
  `LLMCTL_HOSTED_KEY_VARS` (default `TYPESAFE_API_KEY OPENROUTER_API_KEY JEV_API_KEY`) is set and non-empty, `none`
  otherwise. Only the variable NAME is reported; the value is never read into the output.
- Callers route decisions to the hosted endpoint on `cloud`; on a refused start the same answer is printed as
  `llmctl-fallback: cloud|none` on stderr.

## `llmctl reserve [--json]`

Prints the computed reserve, the gate thresholds and the running llmctl units. `--json` emits
`{"enabled", "cpus": {"online", "reserved", "reserved_set", "model_budget", "model_set", "chat_cap", "decide_cap",
"reserve_pct", "reserve_min", "short"}, "memory": {"total_mb", "reserved_mb", "model_budget_mb", "reserve_pct",
"reserve_min_mb", "short"}, "gate": {"cpu_psi_some_max", "load_per_cpu_max"}, "units": [...]}`; `reserve_pct` and
`reserve_min` show the EFFECTIVE values, so a looser knob shows up as the floor it was raised to. `llmctl doctor` and
`llmctl status` print a one-line summary of the same numbers.

## Limits (honest)

- The reserve bounds llmctl units only. It cannot stop other workloads on the host from using the reserved CPUs.
- `AllowedCPUs=` has no effect without a delegated `cpuset` controller; `CPUAffinity=` is what binds then (it is
  inherited by every thread, which the live evidence reads back per thread).
- The capacity verdict is a snapshot. A model admitted at time t can become `degraded` later; `llmctl capacity`
  reports that, it does not stop the model by itself.
- If the capacity measurement itself fails or times out (unreadable `/proc`, a hung GPU probe), the start is refused
  (75, `undetermined`): the admission fails closed.
- A host with less than about **4.6 GiB** of RAM refuses EVERY local start while the reserve is on: the memory reserve
  (at least 4 GiB) leaves less than 512 MiB for models. Use the hosted fallback there, or `LLMCTL_HOST_RESERVE=0` for
  diagnostics only.
- `LLMCTL_RESERVE_EXTRA_UNIT_GLOB` is a QA knob: the live harness runs its engine as transient
  `llmctl-qa-reserve-*.service` units and counts them as llmctl units through it. It is not meant for normal use.
