# Live test protocol: `vision` profile (guarded)

Tooling: `scripts/livetest/vision_live_test.sh` (driver), `scripts/livetest/watchdog.sh` (host-safety watchdog and
bounded-stop helper), hermetic tests `tests/test_livetest_watchdog.sh`.

Background: the host was force-powered-off after a memory/IO stall. This protocol exists so a live model test can
never repeat that: it refuses to start on a stressed host, and a watchdog stops the profile the moment any limit is
crossed.

## Where to run it

Run it from the INTEGRATED main tree, never from an old branch. The installed `llmctl` must have `vision validate`
(`lib/validate.sh`; at the time of writing uncommitted in the main checkout) and `validation/suites/vision-golden-v1`
must exist next to this script's repo root; otherwise the run ends with exit 2. Whether the installed llmctl has the
`hw_pressure_gate` start gate (only on the fix branch at the time of writing) is UNKNOWN until integrated; this
protocol's own gate is deliberately stricter than that gate and does not depend on it.

    scripts/livetest/vision_live_test.sh            # profile `vision` only; `vision-pro` and anything else is refused

Needs the explicit go-ahead of the lead. Never wrap it in retries.

## Exit codes

| code | meaning |
|------|---------|
| 0 | PASS: every probe matched, evidence captured, clean `llmctl stop` (rc 0), unit inactive, port closed |
| 1 | FAIL: at least one wrong answer (`llmctl vision validate` rc 1). Never retried, never excused |
| 2 | undetermined: start/readiness/validate/cleanup could not be confirmed, interrupted, bad or short validate JSON |
| 3 | pre-gate refusal (nothing was started) |
| 4 | aborted by the watchdog (the profile was stopped) |
| 5 | the watchdog itself died: aborted and stopped, the model never runs unguarded |

## Pre-gate (all must hold, else exit 3; unreadable sensor = refusal)

- MemAvailable >= 12000 MiB
- memory PSI `some avg10` < 5 and `full avg10` < 1 (stricter than `hw_pressure_gate`: some<=10, full<=2)
- IO PSI `some avg10` < 10 and `full avg10` < 2
- GPU used (max over GPUs, `nvidia-smi`) < 6000 MiB
- `llmctl status --json` (read-only): `vision` not already running; no other running profile with ram_mb >= 4000 or
  vram_mb >= 2000 (our definition of "large"); no profile in a failed state
- `systemctl --user list-units 'llmctl-*@vision*.service'` shows no failed / activating / auto-restart unit

## Watchdog (started before the model; samples every 2 s)

Trigger (first breach, no debounce): MemAvailable < 5000 MiB; memory PSI some avg10 > 20 or full avg10 > 10;
IO PSI some avg10 > 60 or full avg10 > 30; GPU used > 11500 MiB; wall clock > 600 s; the driver gone (missing or
zombie); three consecutive unreadable sensor reads. IO thresholds are UNCALIBRATED on this host: model loading may
legitimately raise IO pressure, in which case the run aborts (fail-safe) and the numbers are tuned from evidence.

Remedy is a bounded stop: `llmctl stop vision` limited to 20 s (it can queue behind the scheduler flock that `llmctl start`
holds while loading), then `systemctl --user stop llmctl-<engine>@vision.service` (unit name derived from the engine in the
unit env file, as `_svc_unit_for` does). systemd does the killing; this tooling signals no process other than SIGTERM
to the watchdog it started (identity checked via /proc cmdline first). Sensor and `llmctl` calls are detached with
deadlines so a hung `nvidia-smi` cannot freeze it. The driver checks every wait loop that the watchdog is still alive.

## Start path and probes

`LLMCTL_VALIDATE_ON_START=0 LLMCTL_READY_TIMEOUT=0 nice -n 19 ionice -c 3 llmctl start vision` runs in the background
(`LLMCTL_READY_TIMEOUT=0` disables llmctl's own readiness wait, verified in `_sched_wait_ready`, so the lock is released
right after `svc_start`); the driver polls `http://127.0.0.1:<port>/health` every 3 s for up to 180 s (start itself
bounded to 120 s), each iteration also checking the watchdog. Probes:
`llmctl vision validate --profile vision --host http://127.0.0.1:<port> --json --keep`. `--host` makes validate use the
explicit endpoint, so it can never start the profile (without it, validate starts the profile when there is no `.run`
file); its verdict is evidence only and is not recorded as local validation state.

PASS requires: validate rc 0; its JSON parses, verdict PASS, no failed/undetermined, every probe PASS, probe count equal
to the golden suite's (18 for vision-golden-v1); sha256 of the model and mmproj the unit ACTUALLY loaded (from the
unit env file's `-m` / `--mmproj`); final stop rc 0 (not only the systemd fallback); unit inactive; port closed; profile
no longer in `llmctl status`; VRAM within 500 MiB of the baseline (informational when no GPU use was observed, since a
CPU-only model proves nothing by VRAM).

## Evidence: `~/.cache/llmctl-livetest/<UTC ts>/` (dirs 0700, files 0600)

gate.log status_before.json units_before.txt overrides.log harness.txt (harness git HEAD, llmctl version) env_names.txt
(names only) commands.log signals.log samples.csv watchdog.log trigger (if fired) start.out health.out validate.out
validate.err validate.rc validate_check.txt loaded_files.txt stop.out post_stop_state.txt post_stop_samples.csv
(20 s of VRAM after stop) status_after.json logs.txt (`llmctl logs vision 200`) journal.txt (unit journal since start)
bounded.log (timeouts) identity.txt verdict.txt run.log

## Overrides

Thresholds, timings and every sensor/binary redirection (`LT_*`, `LLMCTL_BIN`, `NVIDIA_SMI_BIN`, `SYSTEMCTL_BIN`) are
honoured ONLY when `LT_HERMETIC=1` (the tests). Outside it they are ignored and the ignore is recorded in
`overrides.log`; under it the evidence says loudly it is not a live run.

## Known unknowns

- `llmctl vision validate --json` output was read from `lib/validate_judge.py`, not captured from a live run.
- `llama-server --version` is run after the model is stopped; whether it initialises CUDA here is unverified.
- The unit env file location assumes `LLMCTL_SERVICES_DIR` or `<state dir>/services` as in `lib/common.sh`.
- IO PSI thresholds (see above) and the "large model" thresholds are our choices, not llmctl's.
