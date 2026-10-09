# Host safety (user-level safeguards against memory/task exhaustion)

| Field | Value |
|---|---|
| Revision | 2 |
| Created | 2026-10-09 |
| Status | active (guard ships in DRY-RUN) |
| Code | `scripts/hostsafety/` |
| Tests | `tests/test_hostsafety.sh` |

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
| `systemd-oomd` active but no `ManagedOOMMemoryPressure` | deliberately not enabled, see *Limits* |
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
     guard logs `would-kill` with the full victim evidence to `~/.local/state/hostsafety/guard.log`
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
   (`HOSTSAFETY_TMPFS_WARN_PCT`), once per crossing, never killing anything.

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
- **`systemd-oomd` is not enabled for these slices on purpose**: it kills a whole cgroup, and the
  fleet shares one scope with claude.
- **The guard is conservative**: a storm spawned directly under claude's process group cannot be stopped as a
  group; it is thinned one eligible process per tick (and only while pressure persists). `bounded-run`
  guarantees a separate scope and group, which is the real protection.
- The guard samples every 10 s and acts after ~20 s of sustained pressure; a fork bomb that
  exhausts memory faster than that is stopped by `TasksMax`/`MemoryMax` first, not the guard.
- Memory PSI is host-wide, not per cgroup; the victim choice is per cgroup/group.
- The guard does not act inside `session.slice`; a runaway inside the desktop session is out of scope.
- Dry-run is the default: until armed the guard only observes.
