# Live test protocol: one profile at a time (guarded)

Tooling: `scripts/livetest/vision_live_test.sh` (driver, one profile per run; the file name is historical),
`scripts/livetest/watchdog.sh` (host-safety watchdog and bounded-stop helper), `scripts/livetest/lt_profiles.py` (derives the
allow-list and the pass criteria; read-only), `scripts/livetest/run_profiles.sh` (thin sequential runner), hermetic tests
`tests/test_livetest_watchdog.sh`, `tests/test_livetest_profiles.sh`, `tests/test_livetest_runner.sh` (shared fake environment:
`tests/livetest_fake_lib.sh`).

Which profiles may be live-tested is NOT a fixed list: it is derived at run time, per host, from `models/catalog.json`,
`llmctl plan --json` and the validation suites (next section). The operator decided (recorded) to live-test, one at a time
under this same watchdog, `vision`, `vision-pro`, the fitting chat/coder profiles and the embedding profile. Only `vision`
(twice) and `small` (once) have ever run live (PASS each time, one host, 2026-10-13 and 2026-10-14); everything else below is covered by hermetic tests only until it has run.

Background: the host was force-powered-off after a memory/IO stall. This protocol exists so a live model test can
never repeat that: it refuses to start on a stressed host, and a watchdog stops the profile the moment any limit is
crossed.

## Dynamic switching: the resident set is switched off for the run and restored (operator decision, accepted)

llmctl manages models by dynamic switching, so the profile under test is loaded the way llmctl itself loads one and nothing is left
idle: **this interrupts every resident llmctl service for the duration of a run, enabled ones included (e.g. the decision gateway
backend `decide-nli`); the operator has accepted that.**

1. Before anything is stopped the running set is RECORDED (fail closed if `llmctl status --json` cannot be read): `prior_status.json`
   (the raw rows, `enabled` flag included), `prior_set.txt` (the running base profiles, restore order = status order),
   `prior_units.txt` (`systemctl --user list-units 'llmctl-*@*.service'`), `prior_unrestorable.txt` (scaled instances `p.N`:
   `llmctl start p` brings back ONE instance, so they are reported as a failed restore (exit 7) and named in `restore.txt`,
   `RESTORE_MANUAL.txt` and the runner summary, never silently dropped - also through the runner, whose `--restore-only` call reads the
   recorded `prior_status.json` next to the set file).
2. The profile is loaded with llmctl's own `llmctl switch <profile>` (same env as before: `LLMCTL_VALIDATE_ON_START=0`,
   `LLMCTL_READY_TIMEOUT=0`, nice 19, ionice idle, in the background under the watchdog): llmctl takes the scheduler lock, applies its
   pressure gate, stops EVERY running profile, starts exactly the target, and rolls back by itself if the start fails. This tool stops
   nothing but the profile under test (its own, with the bounded stop below), never signals a foreign process, never touches a unit
   llmctl does not own (the only `systemctl stop` that can ever happen is the bounded fallback on the test profile's own
   `llmctl-<engine>@<profile>.service`). Evidence: `commands.log` (the switch and every restore command).
3. The pre-gate counts the RAM/VRAM llmctl has reserved for the resident set (status json `ram_mb`/`vram_mb`, estimates) as free,
   because the switch stops it: `effective = measured + reserved` (memory, free VRAM) / `measured - reserved` (GPU used); both are
   written to `gate.log`. The credit never lowers the watchdog's floor: the watchdog checks RAW MemAvailable while the resident set is still
   loaded, so the gate also refuses unless RAW MemAvailable >= 5000 (watchdog floor) + 1024 MiB, and a last `guard` check (watchdog
   triggered/dead) runs right before the switch is launched; otherwise the resident set would be stopped for a run the watchdog aborts
   at once. The 1024 MiB raw-memory margin is an estimate-based choice (it can only cost an abort followed by a restore, never a lost set). `ram_mb`/`vram_mb` are llmctl's ESTIMATES; `llmctl switch` has its own pressure gate and rolls the set back itself when
   the target fails to start, so a wrong estimate costs a refused or rolled-back switch, not a lost set. A resident profile in a failed state is still a refusal; another resident profile is no longer one. The
   post-stop VRAM check compares with the MEASURED pre-switch value when a set was switched off.
4. After the run, on EVERY exit path (PASS, FAIL, abort, failed switch, signal; via the existing EXIT trap), once the test model is
   confirmed stopped and the watchdog is reaped, the recorded set is RESTORED with
   `LLMCTL_VALIDATE_ON_START=0 nice -n 19 ionice -c 3 llmctl start <profile>`, one profile at a time, bounded (300 s each, never
   signalled), each preceded by a pressure check (memory PSI some < 5 / full < 1, IO PSI some < 10 / full < 2, MemAvailable >= the
   profile's reserved RAM + 2048 MiB; when a row's `ram_mb` is missing, zero or non-numeric the conservative default floor of 6144 MiB
   is used and the reason says so) and each followed by a health check (the unit env file's `LLMCTL_REG_HEALTH` path for ANY engine,
   else `/healthz` for onnx and `/health`; the status row's port, else the env file's `LLMCTL_PORT`; unit active when no port is
   known; up to 120 s). Restore is idempotent: a profile that already runs is only verified (`ALREADY RUNNING`).
   Evidence: `restore.txt` (one line per profile: `RESTORED (healthy)` / `ALREADY RUNNING` / `SKIPPED (why)` / `FAILED (why)`),
   `after_status.json`, `after_units.txt`; the verdict table has `resident set switched off` and `prior set restored`.
5. A restore that cannot or must not run is LOUD, never silent: if the host is under pressure, or the stop of the test model is not
   confirmed, or its start is still pending, nothing is started, the exact command is printed and written to `RESTORE_MANUAL.txt`
   (`nice -n 19 ionice -c 3 llmctl start <profiles>`), and the exit code is **6**; a profile that failed to start, never became healthy
   or is a scaled instance gives **7** (the others are still attempted). When the run itself ended non-zero (1 FAIL, 2, 3, 4 abort,
   5) that code stays and is never masked: the restore problem is in the verdict reason, `restore.txt` and `RESTORE_MANUAL.txt`.
   A machine-readable `RESTORE_STATE=<ok|manual|failed|none>` line ends the verdict output and the runner summary and is stored in the
   `restore_state` evidence file, so a consumer that only sees the run's own code (1 to 5) still learns the host-service state
   (`deferred` appears only with `--no-restore`, when the caller restores).
   A first INT/TERM/HUP during the restore lets the start attempt in flight finish (llmctl runs it detached; abandoning it would leave
   an untracked half-started unit), starts nothing further, marks the rest `SKIPPED (interrupted)`, writes their exact commands to
   `RESTORE_MANUAL.txt` and exits 6; a second signal changes nothing. SIGKILL cannot be handled (see Known unknowns).
   Group-delivered signals (terminal/ssh close, a TERM to the whole process group) do not kill the `llmctl start` in flight: it is
   started with TERM/HUP/INT ignored (inherited through exec; nobody is signalled by us). The 300 s limit is only a WAIT deadline:
   when it passes the tool stops waiting (the profile is reported FAILED) and signals nothing, so a runaway start keeps running and,
   being immune, ignores TERM/HUP/INT. The real bounds are llmctl's own: `LLMCTL_START_WAIT` (default 20 s) limits `systemctl --user start`, `LLMCTL_READY_TIMEOUT` (default 60 s, 1 s steps, `_sched_wait_ready`) the readiness poll, about 80 s per
   profile plus time queued on the scheduler lock. The **operator abort path** for such an orphan is `systemctl --user stop
   <llmctl-engine>@<profile>.service` (printed in the message and in `RESTORE_MANUAL.txt`) or SIGKILL of its recorded pid. Because the
   signals are ignored at entry, llmctl's own TERM/INT traps inside the restore tree are disabled (a signal ignored at entry cannot
   be trapped) - intended. A scaled instance is `ALREADY RUNNING` only when it is also healthy (same health check as a base profile,
   port from its status row); a present reservation whose health cannot be verified is reported `RESERVED (... health not verified)`,
   leaves RESTORE_STATE=manual and exits 6. The runner no longer scrapes the driver's stdout for the evidence path: the driver writes it
   to a file (`LT_EVIDENCE_PATH_FILE`, honoured only with `LT_VIA_RUNNER=1`) and the runner accepts a path only under the evidence root
   and owned by the user. Profile names must not contain `.` (a test asserts it for the catalog). Limits:
   SIGKILL cannot be ignored, and the main-flow `llmctl switch` (a background job of the driver) is NOT immune - a group signal there
   ends the switch and the cleanup path (stop of the test profile, then restore) takes over.
   `--no-restore` run directly by a human prints a WARNING on stderr when a resident set was switched off (naming
   `RESTORE_MANUAL.txt` and the exact `llmctl start` command) and a final `NOT RESTORED: ...` line; the exit code is unchanged. The runner
   marks its own driver calls with `LT_VIA_RUNNER=1` (no warning there) and instead restores, once at the end, the recorded set PLUS any
   profile a later driver run found running and switched off (shown in the summary as `additionally restored`); scaled instances found
   that way end as RESTORE_STATE=manual (exit 6). A scaled instance that llmctl's switch rollback already brought back is reported
   `ALREADY RUNNING`; otherwise `FAILED` with the command `llmctl decide scale <base> <count>`.
   The restore itself is not under the watchdog (the watchdog guards the test model); it relies on the per-profile pressure check
   before every start and llmctl's own admission/pressure gates.
6. `--plan` is a dry run: static refusals, `llmctl plan --json` fit and the recording run, then it prints what would be stopped, what
   would be started and how, and what would be restored, and exits 0 (verdict `PLAN`) without a switch, start, stop, verify or restore.
   `--no-restore` (used by the runner) leaves the restore to the caller; `--restore-only <set-file>` restores a recorded set
   (names, one per line; RAM figures read from a `prior_status.json` next to it) and is idempotent.

## Which profile is accepted (derived at run time; every refusal is exit 3 and starts nothing)

    vision_live_test.sh [--allow-large] [--gate-only] [<profile>]      # default profile: vision; env LT_ALLOW_LARGE=1 = --allow-large

The profile is accepted only when ALL of these hold; nothing is hard-coded by profile name or size:

1. it is in `models/catalog.json`, its engine is `llama` (the driver hashes the `-m` / `--mmproj` files of the unit env file,
   so colibri/onnx profiles are refused), and its catalog `validation.suites` is non-empty with every suite file present
   (`decide*` profiles have none: refused);
2. `llmctl plan --json` (read-only, bounded 60 s) lists it with `fits: true` for THIS host; `fits: false`, missing, an unusable
   plan or a failed plan = refused (a flag never overrides a plan that says it does not fit);
3. `llmctl models verify <profile>` (checksums of the files on disk, niced, bounded 1800 s) returns 0: not downloaded, a mismatch
   or a timeout = refused ("not verified"). It runs BEFORE any model starts and hashes GBs, so it may raise IO PSI; run the
   driver again once the host is quiet (the gate then judges that);
4. it is not already running (`llmctl status --json`, including scaled instances `<profile>.N`);
5. a LARGE profile (catalog `min_tier` workstation/datacenter, or a catalog footprint >= 10 GiB: with the shipped catalog that is
   `vision-pro` and the 18 GiB coder profiles) additionally needs `--allow-large` (or `LT_ALLOW_LARGE=1`; `LT_ALLOW_LARGE=0` is not
   a flag). The 10 GiB rule is this tooling's choice, not the operator's: UNKNOWN whether the operator wants coder-class profiles
   behind the flag.

`--gate-only` runs checks 1, 2, 4, 5 and the pre-gate, starts nothing and does not hash (the verify is left to the real run), and
exits 0 with verdict `GATE-OK` (not PASS). The runner uses it between runs.

## Preconditions (checked by the gate, exit 3 before anything starts)

1. Sensors as listed below.
2. The profile's validation suites exist in this script's repo tree (run from the integrated tree).
3. The `llmctl` on PATH resolves (`readlink -f`) INSIDE this script's tree, so it is the llmctl that has `vision validate --host` /
   `validate --host` (an installed copy elsewhere is refused). Explicit override: `LT_LLMCTL_TREE=<dir>`; it is honoured and logged in `overrides.log`.
4. The scheduler lock `<runtime dir>/.scheduler.lock` (`LLMCTL_RUNTIME_DIR`, else `$XDG_RUNTIME_DIR/llmctl`, else
   `<state>/run`) is not held by another process (non-blocking shared probe, never held past the check). Reason:
   `scheduler::with_lock` takes `flock -x` with NO timeout, so a holder makes both our start and our stops queue behind it.
   The refusal names the holder when `fuser` can.
5. `llmctl vision help` (vision suites) or `llmctl help` (all other suites) shows `--host` (checked again after the start).

## Where to run it

Run it from the INTEGRATED main tree, never from an old branch. The installed `llmctl` must have `vision validate`
(`lib/validate.sh`; at the time of writing uncommitted in the main checkout) and `validation/suites/vision-golden-v1`
must exist next to this script's repo root; otherwise the run ends with exit 2. Whether the installed llmctl has the
`hw_pressure_gate` start gate (only on the fix branch at the time of writing) is UNKNOWN until integrated; this
protocol's own gate is deliberately stricter than that gate and does not depend on it.

    scripts/livetest/vision_live_test.sh                         # profile vision
    scripts/livetest/vision_live_test.sh <profile>               # any profile accepted by the rules above
    scripts/livetest/vision_live_test.sh --allow-large vision-pro

Needs the explicit go-ahead of the lead. Never wrap it in retries. One profile per invocation; for several use the runner below.

## Exit codes

| code | meaning |
|------|---------|
| 0 | PASS: every probe matched, evidence captured, clean `llmctl stop` (rc 0), unit inactive, port closed |
| 1 | FAIL: at least one wrong answer (`llmctl vision validate` rc 1). Never retried, never excused |
| 2 | undetermined: start/readiness/validate/cleanup could not be confirmed, interrupted, bad or short validate JSON |
| 3 | refusal: not allowed for this profile/host, or the pre-gate refused (nothing was started) |
| 4 | aborted by the watchdog (the profile was stopped) |
| 5 | the watchdog itself died: aborted and stopped, the model never runs unguarded |
| 6 | the run itself PASSed (or `--restore-only`) but the prior set was NOT restored: restore skipped (pressure / test model stop unconfirmed); manual command printed |
| 7 | the run itself PASSed (or `--restore-only`) but a prior profile failed to restart, never became healthy, or was a scaled instance |

## Pre-gate (all must hold, else exit 3; unreadable sensor = refusal)

- MemAvailable >= max(12000 MiB, catalog footprint + 4096 + 2048 MiB) (the catalog footprint is the sum of the profile's file sizes;
  4096 is the RAM headroom `llmctl plan` already subtracts; the 12000 floor is the original vision gate and is never lowered)
- memory PSI `some avg10` < 5 and `full avg10` < 1 (stricter than `hw_pressure_gate`: some<=10, full<=2)
- IO PSI `some avg10` < 10 and `full avg10` < 2
- GPU used (max over GPUs, `nvidia-smi`) < 6000 MiB (unchanged for every profile)
- when the plan gives the profile VRAM > 0: GPU free VRAM (`memory.free`, max over GPUs) >= the plan's `vram_mb` + 1024 MiB; an
  unreadable value is a refusal
- `llmctl status --json` (read-only): the profile not already running; no profile in a failed state (other RUNNING profiles are not a
  refusal: they are the resident set that the switch stops and the tool restores, see above)
- `systemctl --user list-units 'llmctl-*@<profile>*.service'` shows no failed / activating / auto-restart unit

## Watchdog (started before the model; samples every 2 s)

Trigger (first breach, no debounce): MemAvailable < 5000 MiB; memory PSI some avg10 > 20 or full avg10 > 10;
IO PSI some avg10 > 60 or full avg10 > 30; GPU used > 11500 MiB; wall clock > 600 s; the driver gone (missing or
zombie); three consecutive unreadable sensor reads. IO thresholds are UNCALIBRATED on this host: model loading may
legitimately raise IO pressure, in which case the run aborts (fail-safe) and the numbers are tuned from evidence.

Limits derived per profile (the driver passes `--min-mem-mb` / `--max-gpu-mb`; `thresholds.txt` records what was used): the memory
abort floor stays 5000 MiB (it is only ever raised, never lowered: the gate already guarantees >= footprint + 6 GiB before the start);
the GPU ceiling is `max(11500, GPU baseline + plan VRAM + 1024)` MiB, capped at `card total - 256` when the total is readable (so a
small card lowers it). For the shipped `vision` profile on a 12 GiB card both equal the original constants (5000 / 11500). All other
thresholds are unchanged. A non-numeric limit makes the watchdog exit 2 without running.

Remedy is a bounded stop: `llmctl stop <profile>` limited to 20 s (it can queue behind the scheduler flock that `llmctl start`
holds while loading), then `systemctl --user stop llmctl-<engine>@vision.service` (unit name derived from the engine in the
unit env file, as `_svc_unit_for` does). systemd does the killing; this tooling signals no process other than SIGTERM
to the watchdog it started (identity checked via /proc cmdline first). Sensor and `llmctl` calls are detached with
deadlines so a hung `nvidia-smi` cannot freeze it. The driver checks every wait loop that the watchdog is still alive.

## Start path and probes

`LLMCTL_VALIDATE_ON_START=0 LLMCTL_READY_TIMEOUT=0 nice -n 19 ionice -c 3 llmctl start <profile>` runs in the background
(`LLMCTL_READY_TIMEOUT=0` disables llmctl's own readiness wait, verified in `_sched_wait_ready`, so the lock is released
right after `svc_start`); the driver polls `http://127.0.0.1:<port>/health` every 3 s for up to 180 s (start itself
bounded to 120 s), each iteration also checking the watchdog. Probes:
`llmctl vision validate --profile <profile> --host http://127.0.0.1:<port> --json --keep` when every suite of the profile is a vision suite,
else `llmctl validate <profile> --host http://127.0.0.1:<port> --json --keep` (all the profile's suites, one JSON report each).
`--host` makes validate use the
explicit endpoint, so it can never start the profile (without it, validate starts the profile when there is no `.run`
file); its verdict is evidence only and is not recorded as local validation state.

PASS requires: validate rc 0; its JSON parses, there is exactly one report per suite of the profile, each with verdict PASS, no
failed/undetermined, every probe PASS, and the counts the SUITE FILE implies (read by `lt_profiles.py`, never constants), with
counts.pass equal to their sum:

| suite kind | probes | controls | determinism | counts.pass of the shipped suite |
|---|---|---|---|---|
| vision | every fixture probe | one per `discriminates` entry | `determinism_repeat` keys | 21 for vision-golden-v1 (18 + 2 + 1, as captured from the real judge, see tests/fixtures/livetest/) |
| chat, coder | every case | 0 (the judge's self-test controls are not counted) | `determinism_repeat` keys | 6 chat-v1, 5 coder-v1 |
| embedding | every case | 0 | 0 | 2 embedding-v1 |

(`tests/test_livetest_profiles.sh` section 0 derives these from the suite files and compares them with the counts of the REAL
`lib/validate_judge.py` run against the fixture server: equal for all four suites.) A profile with several suites (the coder
profiles: coder-v1 + chat-v1) needs every one of them to pass. Further PASS requirements: sha256 of the model (and, only for a
profile whose catalog has an mmproj file, the mmproj; otherwise `N/A`) the unit ACTUALLY loaded (from the
unit env file's `-m` / `--mmproj`); final stop rc 0 (not only the systemd fallback); unit inactive; port closed; profile
no longer in `llmctl status`; VRAM within 500 MiB of the baseline (informational when no GPU use was observed, since a
CPU-only model proves nothing by VRAM).

## Evidence: `~/.cache/llmctl-livetest/<UTC ts>-<profile>/` (dirs 0700, files 0600; a same-second rerun gets `-2`, ...)

New per profile: `plan.json` / `plan_fits.txt` (what `llmctl plan --json` said), `verify.out` (checksum verification),
`thresholds.txt` (profile, suites, footprint, the derived gate and watchdog limits), `peaks.txt` (GPU peak from the watchdog's samples,
GPU baseline/final, the unit's cgroup `MemoryPeak`/`MemoryHigh`/`MemoryMax` captured before the stop; `UNKNOWN`, never 0, when not
captured; written also for aborted runs). Unchanged:
gate.log status_before.json units_before.txt overrides.log harness.txt (harness git HEAD, llmctl version) env_names.txt
(names only) commands.log signals.log samples.csv watchdog.log trigger (if fired) start.out health.out validate.out
validate.err validate.rc validate_check.txt loaded_files.txt stop.out post_stop_state.txt post_stop_samples.csv
(20 s of VRAM after stop) status_after.json logs.txt (`llmctl logs <profile> 200`) journal.txt (unit journal since start)
bounded.log (timeouts) identity.txt verdict.txt run.log

## Running several profiles: `scripts/livetest/run_profiles.sh`

    run_profiles.sh [--allow-large] <profile> [<profile>...]     # explicit, ordered
    run_profiles.sh [--allow-large] --fitting                    # derived: catalog + plan + downloaded

The runner records the resident set ONCE before the first run, runs the driver with `--no-restore` per profile (each driver `switch`
stops the previous test model, so two test models are never resident), and restores the recorded set ONCE after the last run - also
after a stop or an abort or an interrupt, whenever anything was switched off - through `vision_live_test.sh --restore-only`. Its exit
code is the first failing profile's code, else the restore's (6/7). `--plan` prints the whole sequence and does nothing.

Strictly sequential, never parallel: a `flock` on `<evidence root>/.runner.lock` refuses a second runner, the driver is run in the
foreground, and before every run the runner refuses when ANY profile of the sequence shows as running in `llmctl status --json`.
Before anything starts, every profile of the list is checked statically (an unknown/unsupported/large-without-flag profile anywhere
refuses the whole sequence). From the second profile on it waits 20 s, then runs `vision_live_test.sh --gate-only <p>` (host
re-check, nothing started). It STOPS at the first non-zero exit of anything (FAIL, undetermined, refusal, watchdog abort 4,
watchdog death 5): a watchdog abort is never continued past, and the remaining profiles are listed `NOT RUN`. One summary table
(`#  PROFILE  EXIT  VERDICT  EVIDENCE`) is printed and kept as `<ts>-sequence/summary.txt` with the per-profile logs. The runner's
exit code is 0 or that of the first profile that did not pass. It sends no signal to anything. `--fitting` takes profiles with a
validation suite, engine llama, plan `fits: true`, a directory under the models dir (downloaded; the driver still verifies
checksums), large ones only with `--allow-large`, smallest catalog footprint first.

## Overrides

Thresholds, timings and every sensor/binary redirection (`LT_*`, `LLMCTL_BIN`, `NVIDIA_SMI_BIN`, `SYSTEMCTL_BIN`) are
honoured ONLY when `LT_HERMETIC=1` (the tests). Outside it they are ignored and the ignore is recorded in
`overrides.log`; under it the evidence says loudly it is not a live run.

## If the start is still pending at cleanup (scheduler lock contention)

If the backgrounded `llmctl start` has not returned after START_WAIT (60 s) when cleanup runs (it is queued behind a lock holder),
the driver does NOT reap the watchdog. The watchdog (own session, outlives the driver) keeps re-checking the unit for
at least 240 s after it fires, and as long as the start process is alive, and stops the unit again if it comes up late; if the driver
is gone its parent-gone path does the same. The verdict then says `start still pending, watchdog left running (pid N) - CHECK
llmctl status / systemctl --user is-active <unit>` and `WATCHDOG_LEFT_RUNNING.txt` is written. Always check that unit by hand afterwards.
Cleanup ignores further Ctrl-C / TERM / HUP while it runs, so a second Ctrl-C cannot cut the stops short.

## llmctl bookkeeping caveats (read from lib/scheduler.sh)

- `LLMCTL_READY_TIMEOUT=0` makes `_sched_wait_ready` return at once, so llmctl writes the `.run` reservation and publishes the
  registry entry right after `svc_start`, BEFORE the model answers. llmctl will therefore also not stop a model that never becomes
  ready; this driver's own readiness deadline and cleanup do that.
- Only `llmctl stop` (`_sched_stop_impl`) removes `<runtime>/<profile>.run` and withdraws the registry entry. A systemd-fallback
  stop leaves them; `_sched_reconcile_reservations` only ADDS missing reservations and never removes stale ones. A stale `.run`
  keeps showing as running in `llmctl status` and keeps reserving RAM/VRAM in the scheduler budget until an `llmctl stop vision`
  succeeds. The tooling therefore retries `llmctl stop` once after a successful fallback (logged as "post-fallback llmctl stop");
  if that also fails, run `llmctl stop vision` by hand.
- A late `llmctl start` (the unit appearing after the first stop) is handled by the watchdog's 60 s post-fire re-check and by the
  driver's cleanup waiting for the background start and stopping again.
- The watchdog runs in its own session (`setsid`), so a group signal at the driver does not also hit it; conversely a
  Ctrl-C does not reach it either, which is intended (the driver's trap reaps it).

## Notes for the release notes (CHANGELOG-ready; headings of CHANGELOG.md untouched)

- The guarded live-test driver now takes any profile that passes the derived allow-list (catalog + `llmctl plan --json` fits +
  `llmctl models verify` + validation suites + not running; large profiles also need `--allow-large`), instead of `vision` only.
  `vision-pro` is no longer refused unconditionally: it is refused unless the plan says it fits AND `--allow-large` is given.
- Pass criteria are suite-aware (vision / chat / coder / embedding): the expected counts come from the suite files.
- Pre-gate memory and free-VRAM thresholds and the watchdog's GPU ceiling scale with the catalog footprint and are never below the
  original vision values; evidence directories are `<ts>-<profile>`; new `thresholds.txt` and `peaks.txt`.
- Dynamic switching: the resident llmctl set is recorded, the profile under test is loaded with `llmctl switch`, and the set is
  restored (pressure-gated, health-checked; exit 6 skipped / 7 failed; `--plan` dry run). It interrupts enabled services for the
  duration of a run (accepted by the operator).
- New `scripts/livetest/run_profiles.sh` runs an ordered list (or `--fitting`) one at a time and stops at the first non-zero exit.
- Live evidence: unchanged. Only `vision` has ever run live; the new paths are verified by hermetic tests (fake llmctl/systemctl/nvidia-smi),
  which prove the checks and the flow, not any model's behaviour.

## Known unknowns

- `harness.txt` records `git_head` from the driver's own checkout; an archive copy without `.git` shows `UNKNOWN` (the run is still valid).
- The hermetic tree-check test forces `LT_LLMCTL_TREE` (hermetic sensors); the default-tree derivation (`readlink -f $HERE/../..`) is only exercised live.

- The restore is verified only against the hermetic fake llmctl: how a real `llmctl start <profile>` behaves for an enabled service
  whose unit llmctl stopped (it may want `llmctl enable`/the waiter), whether `LLMCTL_VALIDATE_ON_START=0` is right for a restart,
  and the accuracy of the status json `ram_mb`/`vram_mb` reservations used for the effective-memory gate are UNKNOWN until a live run.
  `llmctl switch` itself restores the prior set when the target fails to start; this tool's restore is the second line.
- If this tool is killed hard (SIGKILL, power loss) between the switch and the restore, nothing restores the set: the recorded
  `RESTORE_MANUAL.txt` in the evidence dir is the recovery.

- Nothing but `vision` and `small` has run live. Whether `llmctl validate <profile> --host ... --json --keep` of a chat/coder/embedding profile
  behaves on a live llama-server as in the hermetic runs (several JSON objects for a multi-suite profile; `--embeddings` needed for
  an embedding profile) is UNKNOWN until it has run. The shipped catalog has NO embedding profile (the embedding-v1 suite is
  exercised by tests/test_validation_suites.sh and, here, by a fixture profile), so "the embedding profile" does not exist on this
  catalog unless one is added.
- `fits` of `llmctl plan --json` is computed from the CURRENT free RAM/VRAM; `tier_ok` is recorded but not required (a below-minimum
  host can list a profile as fitting). The 10 GiB "large" rule, the +2048 MiB RAM and +1024 MiB VRAM margins and the 1800 s verify
  bound are this tooling's choices, not llmctl's.
- A longer model load (large profiles) may need more than the 180 s readiness deadline; the run then ends exit 2 and the profile is
  stopped. The deadline is unchanged and not scaled.

- `llmctl vision validate --json` output was read from `lib/validate_judge.py`, not captured from a live run.
- `llama-server --version` is run after the model is stopped; whether it initialises CUDA here is unverified.
- The unit env file location assumes `LLMCTL_SERVICES_DIR` or `<state dir>/services` as in `lib/common.sh`.
- IO PSI thresholds (see above) and the "large model" thresholds are our choices, not llmctl's.
