# Host capacity and the host reserve (`llmctl capacity`, `llmctl reserve`)

| Field | Value |
|---|---|
| Revision | 3 |
| Created | 2026-10-28 |
| Since | 3.4.0 |
| Code | `lib/reserve.sh`, `lib/capacity.sh`, `lib/service_linux.sh` (`_svc_resource_directives`), `lib/svc_hook.sh` (unit gate), `lib/scheduler.sh` (admission). `llmctld` runs `bin/llmctl` and has no reserve code of its own |
| Tests | `tests/test_host_reserve.sh`, `tests/test_capacity.sh`, `tests/test_host_reserve_review.sh`, `tests/test_host_reserve_review2.sh`, `tests/test_host_reserve_review3.sh` (unit-class, hermetic fixtures) |
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
   When the only reason is the planner's RAM/VRAM verdict, `start` defers to the planner path, which refuses (exit 1
   with the exact MiB numbers), as before 3.4.0. `restart` has no planner step: a restart whose ONLY reason is the
   planner's verdict is ADMITTED (the unit keeps the limits it already runs with; the reserve, pressure and CPU checks
   above still apply). This is a deliberate choice, not an oversight: the planner counts the running unit itself, so
   it would refuse a restart that changes nothing.
3. the admission fails closed: a capacity measurement that fails, times out or is empty (`undetermined`), an unknown
   profile, or an unreadable verdict refuses with **75** and the fallback line; it never lets a start through
   unchecked.
4. on Linux the gate itself also fails closed (review round 4): when the memory PSI (`some` or `full`), `meminfo`
   `MemAvailable`, the CPU PSI or `loadavg` cannot be read or does not parse as a number, the start is refused with
   **75** and a message naming the input. Before 3.4.0 round 4 such an input skipped its test and the start went
   through. On other platforms (no `/proc`) a missing input still skips its test, as before.

`restart` is judged as a start of the same profile that excludes the replaced unit's own limits and counts that unit's
resident memory as coming back. A restart keeps the unit's existing limits, so when only a reduced thread count would
fit it is refused (75; run `llmctl stop` then `llmctl start`). `decide scale <profile> <n>` judges all new instances
together at the full decision cap. Every unit's own `ExecStartPre` gate (systemd restarts and boot included)
re-checks the pressure, the load and the combined CPU + RAM budget within its bounded wait; it does not re-run the
per-profile verdict and prints no fallback line.

`restart` runs its admission and the unit restart under the scheduler lock (the same lock `start` takes), so a
concurrent `start` cannot be admitted against the same free budget in between (review round 4). A restart that cannot
get the lock within `LLMCTL_SCHED_LOCK_WAIT` fails without restarting anything.

`enable` starts the profile now AND at login/boot (as before 3.4.0); the start now passes the same gate.

`LLMCTL_HOST_RESERVE=0` is a diagnostics switch that restores the pre-3.4.0 behaviour so the old failure can be
reproduced. It is reported loudly: `OFF` in `llmctl reserve`, `DISABLED` in `llmctl status` and `llmctl doctor`.

## `llmctl capacity [--json] [profile...]`

Re-evaluable at any time; it changes nothing. It reads `/proc` (meminfo, loadavg, pressure, `/proc/<pid>/status` for
the thread count), `/sys/fs/cgroup`, the catalog, `getrlimit(RLIMIT_NPROC)`, and it RUNS the hardware probe and the
planner (`llmctl plan --json`; the GPU probe can call `nvidia-smi` or a similar tool), each within the time bounds
below.

`--json` may appear anywhere in the argument list (`llmctl capacity decide-tiny --json`); any other argument that
starts with `-` is a usage error (exit **2**). Before review round 4 a `--json` after the profile was taken as a profile
name.

### Verdict-critical inputs (fail closed)

The verdict depends on some inputs; if one of them is unreadable or does not parse, the whole document is
`undetermined` (`measurement.ok: false`, `measurement.reason` names the inputs, every named profile `undetermined`,
fallback `cloud`/`none`, exit 75). They are listed in `measurement.critical_inputs_unreadable`.

| input                                   | critical when                                  |
|-----------------------------------------|------------------------------------------------|
| `/proc/meminfo` `MemAvailable`          | always                                         |
| memory PSI `some` and `full` avg10      | always                                         |
| CPU PSI `some` avg10                    | reserve on and CPU checks on                   |
| `/proc/loadavg` 1-minute load           | reserve on and CPU checks on                   |
| the cgroup tree the llmctl units are counted under (the whole `LLMCTL_CGROUP_FS` mount, every owner; `LLMCTL_CGROUP_ROOT` narrows it to one manager) | reserve on |
| the `/proc` thread census (`nproc`)     | reserve on; the census must see its own process |

Informational only (recorded `readable: false`, value `null`, the verdict does not change): I/O PSI, the scope's
cgroup `memory.max`, `memory.current`, `cpu.max` and `cpu.stat`. This applies on Linux. On other platforms
(no `/proc`) the critical list is not enforced and the verdict is computed from what can be read; this was not tested
live. A Linux kernel without PSI (`CONFIG_PSI` off, or `psi=0`) therefore refuses every local start while the gate is
in use; that is the intended fail-closed behaviour, not a bug.

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
  "measurement": {"ok": bool, "reason": str (only when ok is false), "timeout_s": int, "probe_timeout_s": int,
                  "critical_inputs_unreadable": [str]},
  "host": {
    "cpus_online": int, "mem_total_mb": int, "mem_available_mb": int, "usable_mem_mb": int,
    "swap_total_mb": int, "swap_free_mb": int,
    "load": {"1": float, "5": float, "15": float},
    "psi": {"memory": {"some": float, "full": float}, "cpu": {"some": float}, "io": {"some": float, "full": float}},
    "cgroup": {"path": str, "memory_max_mb": int|null, "memory_current_mb": int|null, "cpu_max_pct": int|null,
               "cpu_stat": {"nr_periods": int, "nr_throttled": int, "throttled_usec": int}|null},
    "nproc": {"rlimit_soft": int|null, "rlimit_hard": int|null, "user_threads": int|null, "headroom": int|null,
              "limit_override": int|null, "source": str}
  },
  "inputs": {"<name>": {"source": str, "read_at": float, "readable": bool}},
  "reserve": {
    "enabled": bool, "cpus_reserved": int, "cpus_reserved_set": str, "cpus_model_budget": int,
    "cpus_model_set": str, "chat_cpu_cap": int, "decide_cpu_cap": int,
    "mem_reserved_mb": int, "mem_model_budget_mb": int,
    "cpu_short": bool   // true when the host has too few CPUs to keep the CPU reserve (a 1-CPU host reserves 0)
  },
  "llmctl": {
    "units": [{"unit": str, "profile": str, "base_profile": str, "cpu_quota_pct": int|null, "memory_max_mb": int|null,
               "memory_current_mb": int|null, "memory_current_provenance": "measured"|null,
               "cpu_stat": {...}|null, "status": "ok"|"degraded", "reasons": [str], "suggest": str|null}],
    "cpu_pct_used": int, "mem_limits_used_mb": int, "cpu_pct_free": int, "mem_budget_free_mb": int,
    "units": [... , "owner": "self"|"user-<uid>"|"system"|"other", "cgroup": str],
    "consumption_scope": {"cgroup_root": str, "max_depth": int, "scope": "host"|"manager", "owners": [str],
                          "units": str, "not_counted": str}
  },
  "pressure": {"ok": bool, "reasons": [str]},
  "profiles": {
    "<profile>": {
      "class": "decide"|"chat",
      "verdict": "fits"|"fits_with_reduced_threads"|"does_not_fit"|"undetermined"|"running",
      "verdict_class": "fits"|"fits_reduced"|"does_not_fit"|"undetermined"|null, "running": bool,
      "reasons": [str], "threads": int,
      "headroom": {"cpu_pct_free": int, "cpu_pct_need": int, "mem_budget_free_mb": int,
                   "mem_limit_need_mb": int, "footprint_mb": int, "footprint_provenance": "declared",
                   "footprint_source": str, "vram_provenance": str|null, "mem_available_after_mb": int}
    }
  },
  "unknown_profiles": [str],
  "largest_decision_fit": str|null,
  "degraded": bool,
  "fallback": {"recommended": "local"|"cloud"|"none", "route": "local"|"hosted"|"none", "reason": str,
               "key_variable": str|null}
}
```

- `inputs` (review round 3, §11.4.291(C)): one entry per input the verdict used - `meminfo`, `loadavg`, `psi_memory`,
  `psi_cpu`, `psi_io`, `cgroup_memory_max`, `cgroup_memory_current`, `cgroup_cpu_max`, `cgroup_cpu_stat`, `units`,
  `plan`, `rlimit_nproc` - each `{"source": str, "read_at": float (epoch seconds), "readable": bool}`. An unreadable
  input is recorded `readable: false` and its value is `null`, never a default.
- `headroom.footprint_mb` is the planner's DECLARED RAM for the profile (`llmctl plan --json` `profiles.<p>.ram_mb`,
  times the number of new instances), not a measurement: `footprint_provenance` is `"declared"` and `footprint_source`
  names it. A running unit's `memory_current_mb` is MEASURED (cgroup `memory.current`):
  `memory_current_provenance: "measured"`.
- `host.nproc` (§12.12): `rlimit_soft` / `rlimit_hard` (`null` = unlimited), `user_threads` (threads of processes whose
  real uid is this user, from `/proc/<pid>/status`; only this pid namespace is visible, so it is a lower bound of what
  the kernel counts), `headroom` = soft - threads, `limit_override` (`LLMCTL_NPROC_LIMIT`, which can only LOWER the
  limit). With the reserve on, a profile whose cap is larger than the headroom is `does_not_fit` with a
  `RLIMIT_NPROC headroom ...` reason. The check uses the thread CAP; a model's real thread count is somewhat higher
  (HTTP and helper threads), so this is a floor, not a guarantee.
- `host.cgroup.cpu_stat` and each unit's `cpu_stat` (§11.4.225): `nr_periods`, `nr_throttled`, `throttled_usec` from
  `cpu.stat`, CUMULATIVE since the cgroup was created. llmctl does not compute deltas: a caller diagnosing throttling
  takes two documents and subtracts (the anchor's diagnosis is on deltas over a window, with a quiet-phase control).
  `null` when the file could not be read.
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
- `fallback.recommended` is `local` when a decision profile fits or THIS tenant's own decision unit is running and `ok`
  (`LLMCTL_TENANT_ID` set: only `<tenant>--...` units count; unset: only units without a tenant prefix; another tenant's
  unit never makes the route local - review round 3), never when a named profile was refused; `cloud` otherwise when one
  of the variables in `LLMCTL_HOSTED_KEY_VARS` (default `TYPESAFE_API_KEY OPENROUTER_API_KEY JEV_API_KEY`) holds a real
  key; `none` otherwise. A value that is a placeholder does not count (the same rule as the constitution's
  `scripts/jev/lib_keys.sh`: shorter than 16 characters, one repeated character, a control character, or one of
  `x`, `changeme`, `replace-me`, `your-key-here`, `your_api_key`, `placeholder`, `dummy`, `test`, `none`, `null`,
  `todo`, `empty`, `<...>`, case-insensitive). Only the variable NAME is reported; the value is never printed.
- Callers route decisions to the hosted endpoint on `cloud`; on a refused start the same answer is printed as
  `llmctl-fallback: cloud|none` on stderr.

## `llmctl reserve [--json]`

Prints the computed reserve, the gate thresholds and the running llmctl units. `--json` emits
`{"enabled", "cpus": {"online", "reserved", "reserved_set", "model_budget", "model_set", "chat_cap", "decide_cap",
"reserve_pct", "reserve_min", "short"}, "memory": {"total_mb", "reserved_mb", "model_budget_mb", "reserve_pct",
"reserve_min_mb", "short"}, "gate": {"cpu_psi_some_max", "load_per_cpu_max"}, "units": [... "owner", "cgroup"], "units_scope": "host"|"manager",
"units_readable", "units_error"}`; when the unit tree cannot be read (`units_readable` false) the text output says "UNKNOWN" and every
start is refused; `reserve_pct` and
`reserve_min` show the EFFECTIVE values, so a looser knob shows up as the floor it was raised to. `llmctl doctor` and
`llmctl status` print a one-line summary of the same numbers.

## Limits (honest)

- The reserve bounds llmctl units only. It cannot stop other workloads on the host from using the reserved CPUs.
- `AllowedCPUs=` has no effect without a delegated `cpuset` controller; `CPUAffinity=` is what binds then (it is
  inherited by every thread, which the live evidence reads back per thread).
- The capacity verdict is a snapshot. A model admitted at time t can become `degraded` later; `llmctl capacity`
  reports that, it does not stop the model by itself.
- If the capacity measurement itself fails or times out (a hung GPU probe), or a verdict-critical input (see above) is
  unreadable or does not parse, the start is refused (75, `undetermined`): the admission fails closed. Before review
  round 4 an unreadable meminfo, PSI, loadavg or cgroup root was skipped and the start was admitted; round 4 fixed
  meminfo, PSI and loadavg and a MISSING cgroup root in `llmctl capacity` only. Round 5 fixed the rest of the cgroup
  case: a missing root, a mode-000 root and an unreadable directory under the root now refuse with 75 in `llmctl
  capacity`, `capacity_admit`, the start gate (`hw_pressure_gate`), the combined budget check and the unit
  `ExecStartPre` gate (`hk_gate`: every start, systemd restart and boot). An unreadable tree is never counted as
  "no units". The `/proc` thread census must see the process doing the counting, else the measurement is not ok.
  The start gate and `hk_gate` read no thread census; only `capacity_admit` checks the RLIMIT_NPROC headroom.
- `capacity_admit` does not decide RAM/VRAM: when the only reasons are the planner's, it returns 0 and defers the verdict to the
  planner path in `start`, which refuses with exit 1 and the exact MiB numbers. The reserve, CPU, PSI and thread cases are its own.
- **1-CPU hosts (`reserve.cpu_short`).** With one online CPU the CPU reserve is 0 (the last CPU is never reserved), so a model can use the
  whole CPU. `capacity_admit` admits it and prints a loud `WARNING: this host has too few CPUs to keep a CPU reserve` on stderr; set
  `LLMCTL_HOST_RESERVE_STRICT=1` to refuse such a host (exit 75, `llmctl-fallback:` line) and route decisions to a hosted endpoint instead.
- **Memory budget and the cgroup chain (round 8, F1).** The model memory budget is the host RAM, bounded by the tightest numeric
  `memory.high` / `memory.max` of this user's `app.slice`, of the user manager and of every ancestor up to the cgroup mount
  (a `max` bounds nothing; a limit larger than the RAM bounds nothing). Reserve and budget are computed from that bound
  (`host.mem_total_mb` shows the bounded figure). Not read: limits on sibling slices, on a scope the unit does not run in, and a limit
  set after the measurement (the verdict is a snapshot).
- **Gate knobs only tighten (round 8, F3).** While the reserve is on, `LLMCTL_GATE_RESERVE_MB` cannot go below the computed
  reserve, `LLMCTL_GATE_FULL_MAX` is at most 2 and `LLMCTL_GATE_SOME_MAX` at most 10 (stricter values are honoured; the
  same clamps apply in `llmctl capacity`). A non-numeric `LLMCTL_GATE_RESERVE_MB` refuses with exit 75 and an
  `llmctl-fallback:` line. With `LLMCTL_HOST_RESERVE=0` the legacy values apply unchanged. The scheduler's own PSI-only
  and restart checks no longer use this variable (they use an internal one).
- Further round-8 limits, stated plainly: only the literal `LLMCTL_HOST_RESERVE=0` turns the reserve off (F2); `capacity_admit`
  leaves the RAM/VRAM verdict to the planner (F4); the live evidence is one run on one 16-CPU host and its memory-pressure
  case could not run in every repetition (live PSI was already above the stricter threshold it needs) (F5, F6: the
  reviewer's own wording for these two was not available to the author of this text; they are recorded here as the
  limits the author could verify, and the review record in `docs/qa/2026-10-28-host-reserve/review-r7/README.md` lists
  what was not proven live).
- `LLMCTL_HOST_RESERVE`: only the literal `0` disables the reserve (diagnostics). `1`, `yes`, `off`, an empty value or unset all keep it ON.
- cgroup v2 only: the unit census scans `LLMCTL_CGROUP_FS` (default `/sys/fs/cgroup`), and this user's own manager
  (`$LLMCTL_CGROUP_FS/user.slice/user-<uid>.slice/user@<uid>.service`) supplies the `host.cgroup` figures, only when
  the mount has `cgroup.controllers` (the unified hierarchy). On a cgroup v1 or hybrid host the units cannot be counted and the reserve refuses every local start with
  a message that says so (use the hosted fallback, or `LLMCTL_HOST_RESERVE=0` for diagnostics only). Not tested on such
  a host; the refusal is covered by a hermetic test (`tests/test_host_reserve_review5.sh`).
- Consumption scope (`llmctl.consumption_scope`): the CPU and memory already in use by models is counted from the
  llmctl units (`llmctl-llama@*`, `llmctl-onnx@*`, `llmctl-colibri@*`, plus `LLMCTL_RESERVE_EXTRA_UNIT_GLOB`) found
  anywhere in the cgroup v2 tree (`LLMCTL_CGROUP_FS`, at most 8 levels deep): this user's manager, every other
  user's manager (`user.slice/user-<uid>.slice/user@<uid>.service/...`, depth 6) and `system.slice`. Every owner counts
  as consumption; each unit is reported with `owner` and `cgroup`. Only `owner: self` units are this user's instances:
  only they can be "running" for a profile and only they are replaced by this user's `restart`. Any unreadable
  directory in the tree fails the census, and the start is refused (75): a partial census is not a count. A directory that
  disappears while the tree is being walked (a unit stopping; find exits 1 with only "No such file or directory"
  messages) counts as absent, not unreadable; any other find message (for example Permission denied) fails closed.
  Anything deeper than the 8 levels scanned also refuses (the message says the tree is deeper than the scan covers) instead
  of being skipped. An llmctl unit inside a container scope (`*.scope`) under this user's manager is reported with
  `owner: container`.
  `LLMCTL_CGROUP_ROOT` (tests, non-standard layouts) narrows the scan to one manager root at depth 3 and the scope then
  says `manager`. Every non-llmctl workload is outside the model budget (covered only by the PSI/load gate).

  Decision (review round 5, F3), measured on the reference host (cgroup v2, one user): a full scan of
  `/sys/fs/cgroup` at depth 8 visits 310 cgroups, 0 unreadable, in about 23 to 38 ms. Options compared:
  - (A, chosen) llmctl scans the whole cgroup tree and counts units of every owner. Works without privileges for
    every unit the kernel lets this user read, sees other users' and system units, and fails closed where it cannot
    read. Cost: two `find` walks per admission (the unit census, and a one-level-deeper probe that detects a tree deeper
    than the scan).
  - (B, rejected) a shared `llmctl.slice` with a parent `MemoryMax`/`CPUQuota`, so the kernel enforces the aggregate.
    A user unit can only join slices of its own systemd manager, so other users' and system units would stay
    outside it (the F3 gap); a host-wide slice needs root to create; a parent limit in a delegated user subtree can be
    raised by that same user, so it is no host guarantee; and it would move every unit's cgroup path. The per-unit
    caps (`MemoryMax`, `CPUQuota`, `AllowedCPUs`) still apply under A.
  - (C, rejected) enumerate units with `systemctl --user -M <user>@` and `systemctl --system`. Reaching other users'
    managers needs privileges, and it shows nothing the cgroup tree does not already show.
  Residual risk: a host that hides part of its cgroup tree from this user refuses every local start while the reserve
  is on (fail closed, with a message naming the scan root); only hermetic tests cover other-user and system units.
- Outside the host reserve, two older instruments still read an unreadable source as "nothing": the planner's
  per-unit memory list (`systemctl list-units` failing yields no units) and the scheduler's reservation sum (a missing
  runtime directory yields 0 MiB). The reserve's own budget check does not depend on them. Follow-up; inventory in
  `docs/qa/2026-10-28-host-reserve/review-r5/class_inventory.log`.
- A host with less than about **4.6 GiB** of RAM refuses EVERY local start while the reserve is on: the memory reserve
  (at least 4 GiB) leaves less than 512 MiB for models. Use the hosted fallback there, or `LLMCTL_HOST_RESERVE=0` for
  diagnostics only.
- `LLMCTL_RESERVE_EXTRA_UNIT_GLOB` is a QA knob: the live harness runs its engine as transient
  `llmctl-qa-reserve-*.service` units and counts them as llmctl units through it. It is not meant for normal use.
