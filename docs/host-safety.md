# Host safety (user-level safeguards against memory/task exhaustion)

| Field | Value |
|---|---|
| Revision | 6 |
| Created | 2026-10-09 |
| Status | active (guard ships in DRY-RUN) |
| Code | `scripts/hostsafety/` |
| Tests | `tests/test_hostsafety.sh`, `tests/test_agent_containment.sh`, `tests/test_shim_no_self_recursion.sh` |

## Why: the 2026-10-08 incident (host `anton`, 31 GB RAM, 8 GB swap, 16 CPUs)

A runaway recursive post-commit hook in a catalogizer test (fixed elsewhere) forked
without bound. Nothing on the host limited it:

| Evidence | Value |
|---|---|
| Swap | 100% full from ~16:02 |
| Memory PSI `full` | 98% for ~1 h |
| Load average | 535-629 |
| CPU | 76% sys |
| Outcome | host hung, power-cycled |

Gaps found afterwards, and what answers each (user-level here; root-level in `root-steps.sh`):

| Gap | Answer |
|---|---|
| `user-1000.slice` / `user@1000.service` `MemoryMax=infinity`, user `TasksMax` 81641 | slice drop-ins (`app`, `background`, `user`) - installed |
| `systemd-oomd` active; the *vendor* rule on `user@.service` sets `ManagedOOMMemoryPressure=kill` (50% for 20 s) | **not** disabled here (operator decision, no `/etc` change); it killed 259 units on 2026-10-12 including `llmctl-llama@vision` - see *systemd-oomd vendor rule* and *llmctl service limits* |
| `earlyoom` absent | in `root-steps.sh` (root) - **the live host still runs the package default `-r 3600` (no protection list at all) until the operator runs `sudo bash scripts/hostsafety/root-steps.sh --apply`** |
| 22 of 63 podman containers had no memory limit; limited ones sum to ~50 GiB | `hostsafety-podman-audit` (report-only) |
| GNOME `localsearch-3` indexed `~/go/pkg/mod`, 2.3M journal messages | `hostsafety-tracker-exclude`; journald rate limit in `root-steps.sh` |
| swap 8 GB, swappiness 60 | `vm.swappiness=20` in `root-steps.sh` (root) |
| `boba-resource-pressure-check.timer` | **only warns**: hourly oneshot that runs a 5-signature challenge script and shows `failed` in `systemctl --user status`; it never signals anything and its hour-long period cannot catch a 1-hour incident early. Not extended (it lives in another repo and is a detector with a different cadence); the new guard acts every 10 s. |

## What is installed

`scripts/hostsafety/install.sh` (idempotent; prints every change; backs up anything it
overwrites to `~/.local/share/hostsafety-backup/<timestamp>/`):

1. **Slice limits** - `~/.config/systemd/user/{app,background,user}.slice.d/10-hostsafety.conf`,
   sized from `MemTotal` and CPU count at install time (re-run to re-size):

   | Slice | Holds | MemoryHigh | MemoryMax | MemorySwapMax | TasksMax |
   |---|---|---|---|---|---|
   | `app.slice` | agent/test fleet (`tmx-*.scope`, `app-*.scope`, user services such as `helixcode-server`) | 70% | 80% | 1 GiB | clamp(CPU*1024, 4096, 32768) |
   | `background.slice` | low-priority jobs | 40% | 50% | 512 MiB | clamp(CPU*256, 1024, 8192) |
   | `user.slice` (in the user manager) | rootless podman `libpod-*.scope` / conmon | 60% | 75% | 2 GiB | clamp(CPU*512, 2048, 16384) |

   These three drop-ins never name `session.slice` (gnome-shell and the desktop), but `session.slice`
   is **not** unlimited in effect: its parent, the root-level `user-1000.slice` (a system unit, written by
   `root-steps.sh`), is the ancestor of `user@1000.service` *and* every login session. The live host currently
   has `MemoryHigh=90%` / `MemoryMax=95%` there (from the earlier root run; `systemctl show user-1000.slice -p
   MemoryHigh -p MemoryMax`). What a hard limit at that level really does: when the whole subtree hits it, the
   kernel's memcg OOM killer chooses the victim by `oom_score` over *all* tasks below - the browser first, then
   possibly gnome-shell - and nothing can exempt `session.slice` from a parent limit. So the new `root-steps.sh`
   sets **only** `MemoryHigh=90%` (a throttle/reclaim pressure point, never a kill) and `TasksMax=40000` on
   `user-1000.slice` and **drops `MemoryMax`**; the live file keeps the old `MemoryMax=95%` until the operator
   re-runs `sudo bash scripts/hostsafety/root-steps.sh --apply` (the installer cannot touch `/etc`). Hard limits
   belong on `app`/`background`/`user` slices and on `bounded-run` scopes, where a kill stays inside the fleet.
   Swap caps never exceed 1/4 of the swap device. `MemoryHigh` makes the kernel throttle/reclaim a slice
   before it can starve the host; `MemoryMax` is the hard ceiling (a cgroup OOM inside that slice only).
2. **`bounded-run`** (`~/.local/bin/bounded-run`) - run any command in a transient scope
   (`bounded-run [-m MEM] [-t TASKS] [-c CPU%] [-s SWAP] [-T SECONDS] [-n NAME] [--tiny] [--no-disk-tmp] -- CMD...`).
   Defaults computed from the host: `MemoryMax` 50% of RAM (**< 1 GiB is refused with exit 125 unless `--tiny`**),
   `MemoryHigh` 75% of that, `MemorySwapMax` min(MemoryMax/2, SwapTotal/4) (8 GiB swap -> at most 2 GiB; not 0, see
   "Why GNOME says Application Stopped"), `TasksMax` clamp(CPU*128, 512, 8192), `CPUQuota` 75% of all CPUs, and
   `TMPDIR`/`TEMP`/`TMP`/`GOTMPDIR` pointed at a per-run 0700 directory on **disk**
   (`${XDG_CACHE_HOME:-~/.cache}/bounded-run/tmp/<name>.XXXXXX`, root overridable with `BOUNDED_RUN_TMP_ROOT`,
   removed on exit, opt out with `--no-disk-tmp`). Override with flags or
   `BOUNDED_RUN_{MEM,TASKS,CPU,SWAP,TIMEOUT}`. Containment and the timeout work by **cgroup**
   (`systemctl --user kill/stop` on the scope): no pid or process-group signalling, so a bad pgid can
   never become `kill -1` (constitution 11.4.263). Exit codes: the command's, `124` on timeout,
   `125` bounded-run's own error. Orphans left by the command die with the scope.
3. **Memory-pressure guard** - `hostsafety-guard.timer` (every 10 s) runs `guard.py` once per tick,
   in `session.slice`, which none of the three slice drop-ins limits (it is still below `user-1000.slice`, whose
   `MemoryHigh` throttle - not a kill - can in the extreme slow it too).
   - Trigger (sustained for 2 consecutive runs, ~20 s): memory PSI `full avg10 >= 25`, **or**
     swap free `<= 10%` together with PSI `some avg10 >= 10` (swap being full alone is not an
     emergency). Tunable in `~/.config/hostsafety/guard.env`.
   - Victim: whole process **groups** and **single processes** are ranked together by cost (RSS+swap plus 2 MiB
     per process, so a fork storm of tiny processes is seen) x scope weight (`bounded-run-*` x4, other scopes x2,
     services x0.5); only processes owned by the current user inside a cgroup **under `app.slice` or
     `background.slice`** (allowlist) count. A group is signalled *as a group* only if every member is eligible;
     members of a group that holds a protected process still compete as **single processes**.
   - **Storm sharing a protected group** (the 40 x 200 MB `git` in claude's process group case, fixture T1): the
     protected group is never signalled. The best individually-eligible single process of it competes in the same
     ranking, so an idle 5 MB group elsewhere never wins. If the *unprotected* cost of a skipped group is more than
     2x the best other candidate (many tiny storm members, fixture T1b), the victim is the best single process of
     *that* group (`partial` in the log - the rest of the storm remains and the next tick may take another) and the
     unrelated small group is not touched. If the only consumers are protected groups the log says
     `storm inside protected group: no safe victim` / `the only consumers are protected groups` with the evidence
     (`largest_skipped_group`, `dominant_skipped_group`) and nothing is killed. claude's own big footprint is *not*
     a storm: a real runaway elsewhere is still chosen (T1c2).
   - Never selected: other users' processes; anything outside the allowlist (so gnome-shell, login
     sessions, podman/conmon/libpod, the user manager); the guard itself, its ancestors and its process
     group; any process named (kernel `comm`) `systemd`, `gnome-shell*`, `gnome-session*`, `Xwayland`, `sshd*`,
     `tmux*`, `claude`, `podman`, `conmon`, `crun`, `dbus*`, `pipewire*`, `ibus*`, `gsd-*`, `gvfs*`, `gnome-terminal*`,
     `ptyxis*`, tracker/localsearch and similar. Protection is by **kernel process name only** - neither argv[0]
     nor the command line: a test runner whose arguments merely mention `tmux`, or a process started as
     `/tmp/x/claude` (comm `sleep`), stays killable (golden-FALSE carrier, constitution 11.4.201). Cgroup protection
     is precise: `app-gnome-shell*`, `gnome-session*`, `org.gnome.Shell*`, session scopes, podman/conmon/dbus/pipewire...;
     a gnome-terminal or vscode scope (`app-gnome-*.scope`) holds ordinary programs whose runaways **are** killable.
     Residual: `comm` can be set by any process via `prctl`; a process that names itself `claude` makes itself
     unkillable (fail-safe direction; this is accident protection, not a defence against a hostile process).
   - Signalling: SIGTERM, 2 s, then SIGKILL. **Before each signal** the target is re-read from `/proc`: it must still
     be exactly the selected processes (same pids **and same start times** - a reused pgid or pid fails this), each
     still ours, unprotected, inside the cgroup allowlist, and neither the guard nor one of its ancestors; any
     mismatch withholds that signal (`revalidation-failed:<why>`) and the SIGKILL. Single processes are signalled
     through a `pidfd` opened *before* the re-check. `pgid <= 1` and the guard's own group are refused outright.
   - PSI robustness: a missing or malformed `/proc/pressure/memory` yields `psi_available:false` in the heartbeat
     and one `psi-unavailable` log event (no rule can fire; the guard is blind, not "healthy").
   - **Dry-run by default.** `~/.config/hostsafety/guard.env` ships `HOSTSAFETY_GUARD_ARM=0`: the
     guard logs `would-kill` with the victim evidence (counts + first/last 20 pids; see the cost section below) to `~/.local/state/hostsafety/guard.log`
     and the journal, and signals nothing. A heartbeat `~/.local/state/hostsafety/guard.status` is
     written every run (a silent guard must be distinguishable from a dead one). To arm, review the
     `would-kill` records first, then set `HOSTSAFETY_GUARD_ARM=1` (picked up on the next tick).
4. **Audits/exclusions**: `hostsafety-podman-audit` (report only - lists containers, UNLIMITED
   ones, and the sum of limits against `MemTotal`; it never touches a container) and
   `hostsafety-tracker-exclude` (adds build-tree basenames - `node_modules .cache __pycache__ .venv
   .gradle .m2 .npm .cargo .terraform` - to Tracker3 `ignored-directories` if the key exists, prints
   before/after, records what it added so `--revert` removes only that; plus a `.trackerignore`
   marker in `~/go/pkg/mod`, because the basename `mod` is far too generic for the list).
   Restart the miner to apply at once: `systemctl --user restart localsearch-3`.

## Install / uninstall / verify

```bash
scripts/hostsafety/install.sh --dry-run     # show exactly what would change
scripts/hostsafety/install.sh               # install; reads effective values back
scripts/hostsafety/install.sh verify        # re-check effective cgroup values + guard timer
scripts/hostsafety/install.sh uninstall     # remove managed files, restore backed-up originals
hostsafety-podman-audit                     # report-only
tail -f ~/.local/state/hostsafety/guard.log; cat ~/.local/state/hostsafety/guard.status
systemctl --user show app.slice -p MemoryHigh,MemoryMax,TasksMax,MemorySwapMax
```

Root-level pieces (journald rate limit, swappiness, `user-1000.slice` throttle + task cap, earlyoom) are **not**
applied by the installer: `sudo bash scripts/hostsafety/root-steps.sh` prints the plan **and the earlyoom
command line that is running right now**, `--apply` applies it and prints the running command line again as a
post-check (it fails if `--ignore` is missing), `--revert` restores the pre-hostsafety originals kept under
`/var/backups/hostsafety/orig/` (or removes our files if there was none).

**earlyoom, exactly:** `--ignore` is a *hard* exclusion; `--avoid` only subtracts 300 from `oom_score` and could not
keep a large gnome-shell/claude from being picked, so it is not used. The regexes match the kernel `comm`
(15 chars: `tmux: server`, `sshd-session`, `gnome-session-c`), expanded by systemd without quote or escape processing
(no whitespace/backslash in them). `--ignore`: `systemd*`, `(sd-pam)`, `gnome-shell*`, `gnome-session*`, `gdm*`,
`Xwayland`, `Xorg`, `gjs`, `mutter*`, `sshd*`, `tmux*`, `claude`, `conmon`, `dbus*`, `pipewire*`, `wireplumber`,
`ibus*`, `gsd-*`, plus `--ignore-root-user`. `--prefer` (soft, +300): `git post-commit make go cc1 cc1plus rustc
cargo ld collect2 ninja` - `sh`/`bash` cannot be preferred (they are also every pane and agent shell) and
`llama-server` is not listed (a legitimate multi-GB service that comm cannot tell from a runaway), so a runaway
shell/python/node runner is chosen by size only. The test suite proves the list against the real earlyoom 1.9.0
(`--dryrun -d`, fed through systemd's own `EnvironmentFile`/`$EARLYOOM_ARGS` expansion).

## Containing agent and test jobs

Anything an agent or a test runs that can fork (probes, shims, generated scripts, fixtures) goes through one command:

```
agent-run [--tasks N] [--mem SIZE] [--timeout S] [-n NAME] [-q] -- CMD [ARGS...]
bounded-run --agent [--tasks N] [--mem SIZE] [--timeout S] -- CMD [ARGS...]   # same thing
```

`agent-run` is `bounded-run --agent`; `--tasks`, `--mem` and `--timeout` are long forms of `-t`, `-m` and `-T`
(`--tasks=N` also works), and explicit flags beat the profile. Plain `bounded-run` keeps its host-sized defaults for builds.

| Setting | Agent default | Why |
|---|---|---|
| `TasksMax` | 200 | a runaway fork loop hits `EAGAIN` at 200 tasks instead of exhausting the host |
| `MemoryMax` | 1G (`MemoryHigh` at 75%) | 1 GiB is the floor `bounded-run` accepts; builds and `go test -race` need `-m 4G`/`6G` |
| timeout | 300 s | a hung probe cannot outlive the session; exit status 124 |
| `ManagedOOMPreference` | not `avoid` (live scope reads `none`) | `systemd-oomd` must be able to pick the runaway scope before containers or the desktop |
| scope | new transient `bounded-run-<NAME>.scope` per call | one cgroup per job, no shared session scope |

On timeout, `bounded-run` kills and stops **its own scope only** (`systemctl --user kill`/`stop` on the scope it created and
proved started); a scope with the same name is refused (exit 125), and no pid or process group is ever signalled.
Command exit status is passed through; the TMPDIR is disk-backed and removed afterwards.

### Why: the 2026-10-13 incident

A review script put a PATH shim named `tr` first on `PATH`. The shim's body ran `tr` by bare name, so `PATH` resolved it
to the shim itself: every call re-executed itself and forked. The shell was in the uncapped session scope, so nothing stopped it:
about 6,000 processes accumulated on host `anton`. A cap of 200 tasks
would have stopped the chain at 200 processes with `EAGAIN`.

Evidence that the cap now holds (`tests/test_agent_containment.sh`, `TasksMax=40` for a fast test, same shape as the incident):

```
fork-bomb fixture  : spawned=39 failed=261 max_events=261 peak=40
recursive tr shim  : max_events=5 peak=40
afterwards         : scope gone, 0 processes left in the scope, pids.events max > 0, pids.peak <= cap, bystander scope still active
                     (the host-wide fork rate is deliberately NOT a gate: it moves with unrelated load)
```

### Limits of the containment (read before relying on it)

* Short options (`-m -t -T ...`) are parsed after the long ones and win; `BOUNDED_RUN_*` environment variables override the `--agent` profile.
* A nested `bounded-run` creates a **sibling** scope, not a child: the outer scope's caps do not cover it. Give every level its own caps.
* The timeout watchdog is a plain child of the wrapper. As an independent backstop the scope itself carries `RuntimeMaxSec=timeout+10`
  and `TimeoutStopSec=5` (probed: `systemd-run --scope -p RuntimeMaxSec=3` ends the command after 3 s on this host, systemd 259), so the
  command still ends if the wrapper and its watchdog are both killed (tested: both killed, scope gone 13 s later).
* A scope that systemd could not start (no user manager, bad property) exits **125** with the command not run; invalid `-m`/`-s` values and
  unknown long options also exit 125.
* UNKNOWN: whether tearing down a whole enclosing session cgroup also ends a capped scope (they are siblings under the same slice, not nested).

### Rules for shims and fakes

* A generated shim must `exec` the real binary by **absolute path** (or a variable holding one); it must never call, by bare
  name, a command that is also a shim in the same directory, itself included.
* What the lint enforces (`tests/test_shim_no_self_recursion.sh`, `tests/lint_shim_self_recursion.py`): shims written by here-document,
  `... | tee`, one-line `printf`/`echo`, one-line and multi-line `{ echo ...; } > file` groups, and `for t in a b; do printf ... > "$B/$t"` loop
  writers; a bare call at command position of the shim's own name, a sibling's name, or any name of its loop, also behind `exec env command
  nice xargs time timeout sudo nohup builtin stdbuf` (`command -v X` is not a call). Each shape has a planted needle and a negative control.
* Honest coverage on the repository (`tests/*.sh tests/*/*.sh tests/*.py scripts lib internal/*/*_test.go`, as printed by the test):
  108 shell shebang-writing sites, all 108 recognised by the lint's own definition (a cruder line count gives about 113 because it also counts
  lines inside planted-needle heredocs, which are data), 95 with a resolved name and checked, **10 with a dynamic name that cannot be checked**
  (e.g. `> "${STUB}"`; counted, not hidden), 0 findings.
* Go test shims (6 sites in `internal/*/*_test.go`) are written to a temp dir and run by absolute path, never through `PATH`; the lint only checks that no
  script literal in the same file calls the shim's literal name. Python shebang literals (5) are counted and **not** checked.
* A deliberate recursive fixture needs `# SHIM-LINT-OK: <reason>` and may only run under `agent-run`/`bounded-run`.
* Never run an unfamiliar script that writes shims outside a capped scope.
* UNKNOWN: whether `systemd-oomd` on this host would pick an agent scope first under real pressure (the property is not `avoid`;
  the selection itself was not exercised).

## Tests

`tests/test_hostsafety.sh` - fixture-driven (fake `/proc` with pids above `pid_max`, fake
podman/gsettings, temp install dirs) plus a live containment section that runs only in its own
tiny scope: a fork-bomb-like fixture is capped at `TasksMax=100` (kernel `EAGAIN`, `pids.current`
peak <= 100, no survivors), the timeout returns 124, and an armed guard kills only a runaway
scope it was restricted to. Run it inside a scope, never bare:
`scripts/hostsafety/bounded-run -m 3G -t 600 -T 280 -- bash tests/test_hostsafety.sh`.
`tests/hostsafety_guard_fixtures.py` is the synthetic guard fixture suite (T1, kill-path re-validation, pgid reuse,
PSI/stat parsing); `test_hostsafety.sh` section 4b also mutates a scratch copy of `guard.py` (A, B, C, D, E, F, I, J ...)
and requires each mutation to make a named fixture fail. `bounded-run` only ever kills a scope **this run created**
(a pre-existing scope of the same `-n` name makes it exit 125 and is untouched; a lost start race leaves no marker
and nothing is killed).

`tests/test_agent_containment.sh` (live, needs `systemd --user`; run it inside a scope too) covers the agent profile, the
long flags, the fork-bomb and recursive-shim fixtures under `TasksMax=40`, and the timeout tearing down only its own scope.

## Why GNOME says "Application Stopped" (2026-10-09 evidence chain)

Symptom: GNOME shows *"Application Stopped - Device memory is nearly full. An application was using a lot of memory and
was forced to stop."* although the machine had gigabytes free.

1. **The notification source.** `/usr/libexec/gsd-housekeeping` (function `notify_oom_kill`) raises it whenever a
   *user systemd unit ends with result `oom-kill`* - any unit, including transient `run-p*.scope` units created by
   `systemd-run --user --scope` from an agent shell. It is not about system-wide memory.
2. **The kills.** `journalctl -b 0 -k | grep -E 'Memory cgroup out of memory|oom_memcg'` showed exactly three kernel
   *memcg* OOM kills this boot (12:29:44 `git`, 12:30:24 `git`, 12:32:46 `zip`), each inside an agent-created
   `app.slice/run-p*.scope` with `-p MemoryMax=2G/4G`. The host itself was never short of memory.
3. **The mechanism.** `/tmp` is a 16 GiB **tmpfs** (RAM). Pages written there are shmem, charged to the cgroup of the
   *writer*, and unreclaimable without swap. A release-prep step produced a 2.19 GB tarball plus ~780 MB git bundles
   (`/tmp/ba_bundle.*`) in `/tmp` under a 2-4 GiB cap, so the cap was filled by file data that could not be reclaimed
   and the next allocation (inside `git`/`zip`) was OOM-killed.
4. **Reproduced once, deliberately (scope `MemoryMax=96M MemoryHigh=72M MemorySwapMax=0`):**
   - `dd` 200 MB into `$HOME/.cache/...` (disk): finished, rc 0, **peak 74 MB, no OOM** (page cache is reclaimable/writeback-able).
   - `dd` 200 MB into `/tmp` (tmpfs): the process was throttled at `MemoryHigh` for **2 min 15 s**, then
     `kernel: Memory cgroup out of memory: Killed process (dd)`, `oom_memcg=.../hs-exp-tmp.scope`,
     `systemd: hs-exp-tmp.scope: Failed with result 'oom-kill'` (this probe itself may have popped the notification once).
   Note the secondary effect: unreclaimable memory under `MemoryHigh` does not "fail fast", it *stalls* for minutes first.
5. **The fix, in `bounded-run`** (not in the desktop): TMPDIR on disk by default; `MemoryHigh` = 75% of Max; a little
   swap allowed (shmem *is* swappable, unlike with `MemorySwapMax=0`); caps under 1 GiB refused without `--tiny`. The
   guard heartbeat additionally reports `tmpfs_used_pct` and logs a report-only `tmpfs-high` event when `/tmp` is > 60% full
   (`HOSTSAFETY_TMPFS_WARN_PCT`), once per crossing, never killing anything. Since 2026-10-14 the event also carries
   `top_writers`: the 5 largest children of `/tmp` and `$XDG_RUNTIME_DIR` (`du -x -a -d 1 -B1`, all directories together capped at
   `HOSTSAFETY_TOP_WRITERS_TIMEOUT_S` = 2 s, entries marked `timed_out` when cut off; skipped with `top_writers_skipped` when memory PSI
   `full avg10` is already >= the advisory's critical value, because a du adds IO to a stalling host). These are **file sizes**, not
   processes: a tmpfs page is charged to the cgroup that first touched it and outlives its writer, so per-process attribution of shmem
   does not exist. **Killing a process does not free tmpfs pages; only deleting the files does.**

### Do / don't for agents

| Don't | Do |
|---|---|
| `systemd-run --user --scope -p MemoryMax=2G ...` for a build or archive | `bounded-run -m 6G -T <s> -- cmd` |
| Write archives, bundles, build trees to `/tmp` | Write them to disk: `$TMPDIR` under `bounded-run`, else `~/.cache/<tool>/`, or the repo's ignored build dir |
| Copy a cap you saw elsewhere | Use the minimums: `go test -race` 4G; builds/archives 6G+ with TMPDIR on disk; `llama-server` = model size + 3G |
| Pass `--tiny` to "be safe" | `--tiny` only for deliberate containment tests of a runaway (the test suite uses it) |
| Leave temp bundles/tarballs behind | Remove them when the step finishes (`bounded-run` removes its own TMPDIR) |

### What remains by design

A genuine runaway **is** killed inside its cap, and GNOME **will** show the notification for it. That is the
containment working, not a bug: the kill stays inside the transient scope and the desktop, gnome-shell, claude and tmux
are untouched. What this change removes is the *spurious* kills (a normal tool OOM-killed by a RAM-backed temp dir
under a cap too small to hold it).

### Read-only audit of the app.slice limits (2026-10-09, boot of 09:20, 209 min)

- OOM kills this boot: 3 agent scopes above + 1 from the reproduction above (`dd`). No browser, gnome-shell, claude or
  tmux victim (`journalctl -b 0 -k | grep 'Killed process'`). Previous boot: one kernel global-OOM `gunicorn`
  (a container worker, `oom_score_adj=200`), nothing else. `systemd-oomd` is running but logged no kills.
- `app.slice` `memory.events.local`: `high 16028`, `max 0`, `oom_kill 0` since boot; no 30 s window of activity at idle
  (`high` delta 0, full-stall delta 0). Cumulative memory PSI: `some` 74 s / `full` 71 s over 209 min (0.6% of the
  time), `avg300` peak ~5%; usage 16.9 GB of `MemoryHigh` 22.7 GB, dominated by 14.2 GB file cache.
  Reading: the High counter is large but it counts cache-reclaim events, and the stall time is small. **No retune
  recommended on this evidence.** UNCONFIRMED: whether any individual `high` burst coincided with a user-visible stall
  (needs a time-series; the new heartbeat plus `memory.pressure` sampling would give it).

## Guard cost, log size and the `tasks_storm` rule (2026-10-13 incident, host `anton`)

**Evidence** (guard.log / journal / `~/.cache/anton-hang-forensics/`): during a process storm (a `bash p1.sh` process group of
about 6,000 processes in `app.slice/tmx-notes-8580.scope`, cost heuristic 22-48 GB, ~6,950 processes on the host) the guard,
which was a 10 s oneshot at default priority:

- walked `/proc` on **every** run, before looking at PSI: ~0.8 s per run, roughly 8-10% of one core while the host was already
  starved;
- wrote ~152 KB per `would-kill` record (the full pid list and the starttimes map), so `guard.log` reached 96.8 MB (1,306
  lines since 10-09) and the journal split the records into truncated `python3[...]` lines; nothing rotated it;
- chose the right victim (the 6,000-process group) 629 times over 105 minutes and correctly refused the group holding `claude`
  (protected comm) - but, dry-run, decided nothing.

**What changed** (the guard is **still dry-run: arming is an operator decision**; none of this changes `HOSTSAFETY_GUARD_ARM`):

| Change | Behaviour |
|---|---|
| Unit cost caps | `hostsafety-guard.service`: `Nice=19`, `IOSchedulingClass=idle`, `CPUWeight=10`, `MemoryMax=256M`, `TimeoutStartSec=15` (the only effective wall-clock cap: `RuntimeMaxSec` is ignored for `Type=oneshot`, probed with `RuntimeMaxSec=3` ignored / `TimeoutStartSec=3` enforced). |
| Lazy `/proc` walk | PSI, swap, cgroup counters and the streak/cooldown are evaluated first; `/proc/<pid>` is read only when a decision is actually due (sustained pressure, no cooldown). Healthy, "pressure-building" and cooldown runs never touch it. |
| Bounded log detail | `guard.log` and the journal carry `pid_count`, `pids_first`/`pids_last` (20 each) and `starttimes_count`. With `HOSTSAFETY_GUARD_ARM=1` only, the full victim (pids + starttimes) is also written to `guard-victim.json` beside the log (mode 0600, at most `HOSTSAFETY_VICTIM_FILE_MAX_BYTES`, previous kept as `.1`). It is forensics only: the kill path re-reads every pid **and starttime from `/proc`** before each signal and never reads the log or this file (fixture L8). |
| Log rotation | `guard.log` > `HOSTSAFETY_LOG_MAX_BYTES` (default 5 MiB, floor 1 MiB; 0/negative/garbage = default) is gzipped (the new archive is written and verified before any old one is shifted, so a full disk loses nothing; the check compares content, not just length; a non-blocking flock on `guard.log.lock` makes overlapping runs skip rotation - a systemd oneshot cannot overlap itself, a manual run can; keep 1..10)  to `guard.log.1.gz` ... `.3.gz` (`HOSTSAFETY_LOG_KEEP`, default 3); done inside `guard.py`, no logrotate. |
| `tasks_storm` rule | Every run reads `pids.current` of the `app.slice`/`background.slice` descendants (O(cgroups), no per-pid walk; heartbeat fields `max_scope_tasks`, `max_scope_cg`). While PSI `full avg10 >= HOSTSAFETY_PSI_FULL`, a scope above `HOSTSAFETY_TASKS_STORM` (default 2500) adds the reason `tasks_storm=<cgroup>:<n>><limit>` and is tried first as the would-kill candidate (`"rule": "tasks_storm"`). The rule only narrows where a victim may be anchored; uid, protected process names (`claude`, `tmux*`, `gnome*` ...), the cgroup allowlist, the own-group rule and the pid+starttime revalidation are the same shared predicates. A scope whose group holds `claude` is therefore still never signalled as a group, and when the storm scope yields no eligible victim the normal cost ranking applies (`"rule": "psi"`). The storm victim is used only if it costs at least `HOSTSAFETY_STORM_MIN_COST_FRAC` (default 0.5) of the PSI-ranked best victim; otherwise the PSI pick stands and the record carries `tasks_storm_rejected` (a compact list; every one of up to 3 storm scopes is tried, the best acceptable one wins) (a 6,000-task scope with comparable cost still wins; a 3,000-task 0.5 GB build never displaces a 20 GB hog). A big scope without PSI pressure triggers nothing. |

Tunables (`~/.config/hostsafety/guard.env`): `HOSTSAFETY_PSI_FULL`, `HOSTSAFETY_PSI_SOME`, `HOSTSAFETY_SWAP_FREE_PCT`,
`HOSTSAFETY_CONSECUTIVE`, `HOSTSAFETY_COOLDOWN_S`, `HOSTSAFETY_TASKS_STORM`, `HOSTSAFETY_STORM_MIN_COST_FRAC`, `HOSTSAFETY_LOG_MAX_BYTES`, `HOSTSAFETY_LOG_KEEP`,
`HOSTSAFETY_VICTIM_FILE_MAX_BYTES`, `HOSTSAFETY_SCAN_DEADLINE_S`, `HOSTSAFETY_TOP_WRITERS_TIMEOUT_S`, and the `HOSTSAFETY_ADV_*` advisory
thresholds (see *Pressure advisory*).

**Not measured / unknown**: the CPU saving on the real host is an estimate. On a synthetic 6,950-process `/proc` tree (tmpfs files,
not kernel-generated `/proc`) a healthy-run took ~0.44 s before and ~0.06 s after; real `/proc` reads cost more (0.8 s observed), so
the live gain should be larger but is unconfirmed until measured on `anton`. `guard.log`, its archives and `guard.status` are mode 0600; records are strict JSON (non-finite floats are written as `null`). With a fixture `--proc-root` the armed guard refuses to signal anything unless `HOSTSAFETY_TEST_ALLOW_FIXTURE_PROC=1` (tests only). The new unit and
guard were installed on `anton` on 2026-10-14 (see *2026-10-14 hang*); the guard is still not armed.

## Pressure advisory (`pressure.json`)

Every guard pass writes `~/.local/state/hostsafety/pressure.json` (beside `guard.log`; override `--pressure-file` or
`HOSTSAFETY_PRESSURE_FILE`). It is **report-only**: the guard never acts on it. Agent admission control (`scripts/agent-admit.sh` in
the umbrella repository) reads it. It is written **before** anything slow (the du scan, the `/proc` walk) and atomically (tmp file 0600
in the same directory, fsync, rename), so a reader sees the old or the new document, never a torn one, and the file survives a guard
that is killed at `TimeoutStartSec` (fixture PA7: the walk is made to hang on a FIFO; the advisory and heartbeat are already there).

Format (`"schema": "hostsafety.pressure/1"`; keys are only ever added, never renamed or removed, within `/1`):

| Key | Meaning |
|---|---|
| `schema` | `hostsafety.pressure/1` |
| `ts`, `ts_epoch` | time of the pass (local ISO 8601, epoch seconds). **Readers must treat a file older than ~30 s as UNKNOWN** (the timer fires every 10 s; an old file means the guard is dead or timing out) |
| `level` | `ok` / `warn` / `critical`: critical if ANY critical rule holds, else warn if ANY warn rule holds |
| `reasons` | the rules that fired, e.g. `tmpfs_used_pct=65.0>=60` |
| `unknown` | signals that could not be read (`psi`, `tmpfs_used_pct`, `app_slice_ratio`); the level is computed from the rest - an unreadable signal is never evidence of health |
| `psi_available`, `psi_mem_some_avg10`, `psi_mem_full_avg10` | host memory PSI (`null` when unreadable) |
| `tmpfs_used_pct`, `tmpfs_path` | fullness of `/tmp` (df semantics) |
| `app_slice_current_bytes`, `app_slice_high_bytes`, `app_slice_anon_bytes`, `app_slice_shmem_bytes` | `app.slice` `memory.current`, `memory.high` (`null` for `max`), `memory.stat` anon/shmem |
| `app_slice_current_ratio` | `memory.current / memory.high` (includes reclaimable page cache) |
| `app_slice_pinned_ratio` | `(anon + shmem) / memory.high` (memory that only swap can free) |
| `app_slice_ratio_basis` | which ratio the level uses: `pinned` (default) or `current` |
| `thresholds` | the effective thresholds of this pass |

Rules and tunables (`~/.config/hostsafety/guard.env`; a non-finite value falls back to the default):

| Level | Rule (any one) | Variables (default) |
|---|---|---|
| warn | `/tmp` >= 40%, app.slice ratio >= 0.85, PSI `some avg10` >= 15 | `HOSTSAFETY_ADV_WARN_TMPFS_PCT` (40), `HOSTSAFETY_ADV_WARN_APP_RATIO` (0.85), `HOSTSAFETY_ADV_WARN_PSI_SOME` (15) |
| critical | `/tmp` >= 60%, app.slice ratio >= 0.95, PSI `full avg10` >= 10 | `HOSTSAFETY_ADV_CRIT_TMPFS_PCT` (60), `HOSTSAFETY_ADV_CRIT_APP_RATIO` (0.95), `HOSTSAFETY_ADV_CRIT_PSI_FULL` (10) |

**Why the app.slice ratio defaults to `pinned`, not `memory.current / memory.high`.** Measured live on 2026-10-14 at 15:00 on a
healthy host (PSI 0): `memory.current` 22.01 GB of `memory.high` 22.74 GB (**0.968**), of which anon 11.2 GB and file cache 9.1 GB
(pinned ratio **0.46**). Page cache sitting at `MemoryHigh` is normal reclaim, so a current/high basis would report `critical`
permanently and block every agent. What hurt on 2026-10-14 was shmem and anon (which only swap can free, and `MemorySwapMax` capped
swap). `HOSTSAFETY_ADV_APP_RATIO_BASIS=current` selects the literal current/high basis (fixture PA4c).

The decision `/proc` walk has a deadline, `HOSTSAFETY_SCAN_DEADLINE_S` (10 s, below the unit's `TimeoutStartSec=15`). Past it the guard
logs `scan-deadline-exceeded` (entries read / total) and decides nothing (a partial table is never used: an unread member of a group could
be protected). Before this change a slow walk ended as a silent unit timeout.

## 2026-10-14 hang (host `anton`)

The host stalled from about 14:22 CEST. The previous boot's journal ends at 14:37:02 (a hard power cut followed). Evidence: sar/atop
(operator), `guard.log` (now `guard.log.1.gz`), the user journal of boot -1.

| Time | tmpfs shmem (sar) | Other evidence |
|---|---|---|
| 13:20 | 0.33 G | healthy |
| 13:40 | 1.8 G | |
| 14:00 | 3.1 G | |
| 14:10 | 4.9 G | |
| 14:16:20 | | guard `tmpfs-high`: `/tmp` **70.6%** full (of 15.9 GB) |
| 14:20 | 5.2 G | |
| 14:22:37 | | guard `pressure-building`: PSI `full avg10` 32.3 |
| 14:22:47 - 14:28:04 | | 30 dry-run `would-kill` records (below) |
| 14:28:35 - 14:36:52 | | **25 consecutive guard runs `Failed with result 'timeout'`** (old unit, `TimeoutStartSec=20`) |
| 14:30 | 8.1 G | PSI `full` 53% (later 92%), load 430, 385 blocked tasks, `pgscand` 356k/s, sys CPU 1108% |
| 14:37:02 | | last journal line; power cut |

UNCONFIRMED: the guard's own `/tmp` reading at 14:16 (70.6% of 15.9 GB, about 11 GB used) is larger than sar's shmem at 14:20
(5.2 G). The two are not the same measure (`statvfs` of `/tmp` vs. the kernel's `Shmem`; swapped-out tmpfs pages leave `Shmem`), and the
gap was not resolved: the tmpfs content was lost at the power cut. **UNCONFIRMED as well: the per-agent split of the 8.1 G.**

**Mechanism.** Files written to the RAM-backed `/tmp` (a 16 GB tmpfs, half of RAM) are shmem charged to the writers' cgroups in
`app.slice`. `app.slice` has `MemoryHigh` 21.2 G (70%) and `MemorySwapMax` 1 G: once shmem plus anon passed `MemoryHigh`, the kernel
throttled every task in `app.slice` into direct reclaim, and with swap capped at 1 G for the slice, shmem could not be moved out. Result:
reclaim storm (`pgscand` 356k/s, sys CPU 1108%), memory PSI `full` 53-92% for more than 8 minutes, load 430.

**Defences that did not act, and why:**

| Defence | Why it did nothing |
|---|---|
| `systemd-oomd` | monitors `user@1000.service` at 50% for 20 s; it kills cgroups, and killing processes cannot free tmpfs pages (the files stay) |
| `earlyoom` | running with the package default `-r 3600` (this repository's `root-steps.sh` has never been applied on this host); it acts only when memory AND swap are both below its minimums, and swap stayed ~75% free because `app.slice` could not use more than 1 G of it |
| hostsafety guard | dry-run (`HOSTSAFETY_GUARD_ARM=0`). The installed copy was the old 2026-10-09 guard (no lazy walk, no unit cost caps): it walked `/proc` on every run and from 14:28:35 timed out 25 times in a row. Its decisions: 25 x the `git push origin main` group (16 processes, 1.9 GB) in `tmx-vasic-6017.scope`, then a 319 MB `lumen-linux-amd` process (pid 26965) as the best single member of a 68-process group that also holds `claude`. Even armed it would have freed ~2.2 GB of anon at most and **not one tmpfs page** |

**What changed (this repository):**

- The repository guard (10-13 fixes: lazy `/proc` walk, `Nice=19`, `IOSchedulingClass=idle`, `CPUWeight=10`, `MemoryMax=256M`,
  `TimeoutStartSec=15`, `tasks_storm`, log rotation; and `bounded-run --agent`) is installed on `anton` (2026-10-14 14:51, previous files
  backed up to `~/.local/share/hostsafety-backup/20261014T145138/`; still DRY-RUN).
- `pressure.json` (above) and named `top_writers` on `tmpfs-high`.
- The decision walk has a visible deadline (`scan-deadline-exceeded`).
- Measured on `anton` (2026-10-14, unit properties reproduced with `systemd-run --user --slice=session.slice -p Nice=19
  -p IOSchedulingClass=idle -p CPUWeight=10 -p MemoryMax=256M`): a cheap pass took 0.07 s idle and **0.10-0.12 s with all 16 CPUs
  saturated** by 32 spinners in `app.slice` (40 runnable, 0% idle). `IOSchedulingClass=idle` is a no-op for the NVMe disks here
  (scheduler `none`). **Not reproduced**: a memory reclaim storm (it cannot be produced safely); under one, every allocating task
  stalls, the guard included, which is why the advisory is written first and the walk has a deadline.

**Operator decisions (not taken by this change):**

1. **Arm the guard** (`HOSTSAFETY_GUARD_ARM=1` in `~/.config/hostsafety/guard.env`). It would not have prevented this hang (it cannot
   free tmpfs); see the review of all past decisions in the commit that adds it.
2. **Shrink `/tmp`** from 16 GB to about 4 GB (root): `scripts/hostsafety/root-steps.sh` (tmp.mount drop-in).
3. **`app.slice` `MemorySwapMax` 1 G** vs. shmem/anon swappability: the installer's swap cap formula.
4. **earlyoom thresholds** (`-m`/`-s`): earlyoom 1.9.0 has no PSI trigger at all; see *earlyoom, exactly*.
5. **`systemd-oomd` `ManagedOOMMemoryPressureLimit`** (vendor 50% / 20 s on `user@.service`): unchanged; changing it is `/etc` (root).

## Limits of this approach (read before trusting it)

- **A kill inside `user-1000.slice` is not steerable.** That is why only a `MemoryHigh` throttle lives there.
- **Cgroup limits protect the host from a slice, not a slice from itself.** The agent fleet
  (claude, tmux server and the tests they spawn) shares one `tmx-*.scope` under `app.slice`; a
  `MemoryMax` hit inside `app.slice` makes the kernel OOM-kill *within* it and can take out claude/tmux.
  The slice ceilings are a backstop; the primary containment is running risky work through
  `bounded-run` (its own scope, tiny limits) so a runaway dies alone.
- **Page cache counts against `MemoryHigh`.** `app.slice` showed ~16 GiB file cache vs ~2.7 GiB
  anon; reclaim of cache is normal and harmless, but a large mmap'd model (llama.cpp) working set
  near the limit will be throttled. If that bites, raise `app` limits via a later drop-in (`20-*.conf`).
- **`systemd-oomd` IS active for the user manager (vendor rule)**: the distribution ships a drop-in on
  `user@.service` with `ManagedOOMMemoryPressure=kill` and a 50% / 20 s limit; no hostsafety drop-in overrides it.
  It kills a whole cgroup, and the agent fleet shares one scope with claude - see the next section. (This section
  used to say oomd was "not enabled for these slices"; that was wrong.)
- **The guard is conservative**: a storm spawned directly under claude's process group cannot be stopped as a
  group; it is thinned one eligible process per tick (and only while pressure persists). `bounded-run`
  guarantees a separate scope and group, which is the real protection.
- The guard samples every 10 s and acts after ~20 s of sustained pressure; a fork bomb that
  exhausts memory faster than that is stopped by `TasksMax`/`MemoryMax` first, not the guard.
- Memory PSI is host-wide, not per cgroup; the victim choice is per cgroup/group.
- The guard does not act inside `session.slice`; a runaway inside the desktop session is out of scope.
- Dry-run is the default: until armed the guard only observes.

## systemd-oomd vendor rule (user@.service)

Measured 2026-10-12 from the journal: the vendor drop-in on `user@.service` (`ManagedOOMMemoryPressure=kill`, pressure
limit 50% for 20 s) made `systemd-oomd` kill 259 units in one event, among them `llmctl-llama@vision.service` and the
podman healthcheck units. llmctl does **not** change `/etc`, the oomd configuration, the `app.slice`/user-slice drop-ins
or the guard's arming (operator decisions). It reduces its own exposure instead (next section) and asks oomd to prefer
other victims (`ManagedOOMPreference=avoid`; UNKNOWN whether the user manager honours it for an unprivileged unit - it
is harmless when ignored).

## llmctl service limits and gates (fix/bounded-restart-and-pressure-gates)

| Layer | Setting | Why |
|---|---|---|
| Memory (per profile drop-in `llmctl-<engine>@<profile>.service.d/05-memory.conf`) | `MemoryHigh` = 1.25x, `MemoryMax` = 1.5x of the plan footprint (code floors: 1024 / 1280 MiB; always < 90% of RAM). A GPU-mode profile whose provenance is not `measured` (the plan's 2048 MiB RAM is a placeholder; CUDA context and pinned/compute buffers are host-side) gets at least 5120 / 6144 MiB, because a cgroup OOM kill of a healthy model is final. **Measure VmHWM on the first live run** and record it (memory.gpu `measured`) to tighten the cap | a runaway profile dies alone, early; previously `MemoryHigh=MemoryMax=total RAM` contained nothing |
| Memory (template backstop) | `MemoryHigh` 70% / `MemoryMax` 85% of RAM; gateway 20% / 25% (cap 3 / 4 GiB) | for a unit with no drop-in |
| Swap / priority | `MemorySwapMax=0`, `Nice=10`, `IOWeight=50`, `CPUWeight=50`, `OOMScoreAdjust=500` | a swapping or hot model must not stall the desktop and agent fleet |
| Stop / start | `TimeoutStopSec=20`, `TimeoutStartSec=300`, `KillMode=control-group` | the stop path was seen to exceed 90 s under pressure |
| Restart | `Restart=on-failure`, `RestartSec=5`, `RestartSteps=4`, `RestartMaxDelaySec=120`; `[Unit]` `StartLimitBurst=3` per `StartLimitIntervalSec=900` | the old 5 / 60 s could never trip because a real cycle (model load) exceeds 60 s |
| No restart after | `RestartPreventExitStatus=SIGKILL SIGTERM 98` | an OOM kill, a deliberate stop, or "port already in use" only repeat themselves |

**Precedence**: llmctl writes `05-memory.conf`, which sorts before the operator's `10-hostsafety.conf`; systemd applies drop-ins in lexical order, so an existing `10-hostsafety.conf` (live: `llmctl-llama@decide-kev-08b`, `llmctl-onnx@decide-nli`, `llmctl-decide-gateway`) stays authoritative and llmctl never edits or removes it.

Existing installed units are reported stale (`llmctl doctor`, `svc_stale_units`) and `start`/`enable` refuse a unit whose
bound is weaker than 3 starts / 900 s: regenerate with `llmctl install`.

**Start gate** (`hw_pressure_gate`, exit code **75** = EX_TEMPFAIL): a start, restart, `enable`, `switch` (a PSI-only check
before anything is stopped; the memory check runs after the stop) are refused when memory PSI `full avg10 > 2`,
`some avg10 > 10`, or `MemAvailable < footprint + 4 GiB`. It also runs as the unit's first `ExecStartPre`
(`svc_hook.sh gate <instance>`) so systemd restarts are gated. Overrides for tests: `LLMCTL_PSI_FILE`,
`LLMCTL_MEMINFO_FILE`; tuning: `LLMCTL_GATE_FULL_MAX`, `LLMCTL_GATE_SOME_MAX`, `LLMCTL_GATE_RESERVE_MB`.

**The unit gate waits.** `svc_hook.sh gate` (ExecStartPre) polls every `LLMCTL_GATE_POLL` s (default 5) for up to
`LLMCTL_GATE_WAIT` s (default 120) and exits 75 only if the pressure persists; an immediate 75 would be retried by
`Restart=on-failure` and burn `StartLimitBurst`. `TimeoutStartSec=600` covers wait + model load. **Lockout trade-off**:
pressure lasting through three consecutive waits (about 3 x (120 + 5) s, inside the 900 s window) still ends in
`start-limit-hit` - the deliberate fail-closed end state; clear it with `systemctl --user reset-failed <unit>` (or wait
out the 900 s window) once the host is healthy. Interactive `start`/`enable`/`switch` do not wait: they refuse at once.

**Not wired from this branch**: `llmctl validate` (lib/validate.sh, owned by another change set and absent here) does **not** call the gate yet. The hook point is `_sched_pressure_gate <profile>` in `lib/scheduler.sh`; the validate path must call it before `sched_start`. Until then a validate run is gated only by `sched_start` / the unit's `ExecStartPre`, if it goes through them.

**Start is bounded and verified.** The scheduler holds its lock across `systemctl start`; `LLMCTL_START_WAIT` (default 20 s) bounds that call (the unit's gate may wait up to 120 s - past the bound the unit counts as "still starting" and the readiness poll decides, stopping the unit if the model never answers). After a successful start the unit must be active/activating, otherwise `start`/`enable` fail with "unit not active after start" (an ExecCondition port-in-use skip) instead of trusting a foreign listener on the port.

**Rollback caveat**: a failed `switch` restores the previous set without the scheduler-side gate, but the unit's own `ExecStartPre` gate still applies: under persistent pressure the restore waits up to `LLMCTL_GATE_WAIT` and then fails 75, so a rollback can leave nothing running (the switch then exits 75 and says so).

**Exit codes**: 75 = refused by the pressure gate; 98 = `prestart` found the profile's port already listening (it does
not rotate the key and does not load the model).

**One engine unit per profile**: `enable`/`disable` disable and stop any other engine's unit for the same profile;
`llmctl doctor` FAILs when a profile has two enabled engine units, or a live llama-server/onnx_server process of this
install has no registry row. Registry rows are only dropped by `unregister` when the row's pid is dead or is the
stopping unit's own pid; `unregister` is bounded (2 s) and the registration waiter is killed on stop.

UNKNOWN: whether this systemd applies `RestartPreventExitStatus` to a failing `ExecStartPre` (the StartLimit bound
applies either way).
