# Live test protocol: `vision` profile (guarded)

Tooling: `scripts/livetest/vision_live_test.sh` (driver), `scripts/livetest/watchdog.sh` (host-safety watchdog),
hermetic tests `tests/test_livetest_watchdog.sh`.

Background: the host was force-powered-off after a memory/IO stall. This protocol exists so a live model
test can never repeat that: it refuses to start on a stressed host, and a watchdog stops the profile
(only via `llmctl stop vision`) the moment any limit is crossed.

## Run (operator or lead, only with explicit go-ahead)

    scripts/livetest/vision_live_test.sh            # profile defaults to `vision`; `vision-pro` and anything else is refused

Never run it on a host that is already under pressure; the gate will refuse anyway. Do not wrap it in retries.

## Exit codes

| code | meaning |
|------|---------|
| 0 | PASS: all known-answer probes matched, evidence captured, profile stopped, VRAM back near baseline |
| 1 | FAIL: at least one wrong answer (`llmctl vision validate` rc 1). Never retried, never excused |
| 2 | undetermined: start/readiness/validate could not be determined, interrupted, evidence or cleanup not confirmed |
| 3 | pre-gate refusal (nothing was started) |
| 4 | aborted by the watchdog (profile was stopped by it) |

## Pre-gate (all must hold, else exit 3)

- MemAvailable >= 12000 MiB
- memory PSI `some avg10` < 5 and `full avg10` < 1
- GPU used (max over GPUs, `nvidia-smi`) < 6000 MiB; unreadable sensor = refusal
- `llmctl status --json` (read-only): `vision` not already running; no other running profile with
  ram_mb >= 4000 or vram_mb >= 2000 (our definition of "large"); no profile in a failed state
- `systemctl --user list-units 'llmctl-*@vision*.service'` shows no failed / activating / auto-restart unit

## Watchdog (started before the model; samples every 2 s)

Stops the profile with `llmctl stop vision`, records the reason in `<evidence>/trigger`, then exits, when:
MemAvailable < 5000 MiB, or PSI `some avg10` > 20, or GPU used > 11500 MiB, or wall clock > 600 s, or
the driver script vanished, or three consecutive unreadable sensor reads. It never signals any process.
The driver sends exactly one signal in its life: SIGTERM to the watchdog PID it started (`signals.log`
records it). No process-group signals, no pkill/killall, no reboot/suspend. `nvidia-smi` is run detached so a
hung driver cannot freeze the watchdog.

## Start path

Only `LLMCTL_VALIDATE_ON_START=0 nice -n 19 ionice -c 3 llmctl start vision`, then poll
`http://127.0.0.1:<port>/health` every 3 s for up to 180 s (port from `llmctl status --json`, default 8082).
Probes: `llmctl vision validate --profile vision --json --keep` (requires an installed llmctl that has this
subcommand; otherwise exit 2 rather than a substitute). Always ends with `llmctl stop vision`
(also on EXIT/INT/TERM/HUP), then checks `nvidia-smi` is within 500 MiB of the pre-test baseline and
`llmctl status --json` no longer lists the profile.

## Evidence: `~/.cache/llmctl-livetest/<UTC ts>/`

`gate.log status_before.json units_before.txt commands.log signals.log samples.csv watchdog.log watchdog.out
trigger (only if fired) start.out health.out validate.out validate.err validate.rc stop.out status_after.json
identity.txt (model/mmproj sha256, llama-server version, VRAM baseline/final) verdict.txt run.log`

## Thresholds are constants

They are only overridable when `LT_HERMETIC=1` (used by the hermetic tests). Do not set it for live runs.
Sensor/command redirection variables (`LT_MEMINFO`, `LT_PSI`, `NVIDIA_SMI_BIN`, `LLMCTL_BIN`, `SYSTEMCTL_BIN`) exist for tests.

## Known unknowns

- The exact JSON shape of `llmctl vision validate --json` is not parsed; PASS requires rc 0 plus non-empty captured output.
- `llmctl vision validate` is, at this branch point, only an uncommitted working-tree feature of the main checkout.
- `llama-server --version` is run after the model is stopped; whether it initialises CUDA on this host is unverified.
