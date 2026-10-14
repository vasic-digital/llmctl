# Live `small` validation run - 2026-10-14

| Field | Value |
|---|---|
| Revision | 1 |
| Date | 2026-10-14 (UTC 09:19:37 to 09:19:51) |
| Profile | `small` (Llama 3.2 3B Instruct, Q4_K_M, no mmproj), llama-server on port 8085 |
| Driver | `scripts/livetest/vision_live_test.sh small` with `scripts/livetest/watchdog.sh` (guarded live test, see [live-test-protocol](../../live-test-protocol.md)); `harness.txt`: git head `1f1529c`, `git_dirty_files=1`, `llmctl 3.2.2` |
| Scope | **ONE HOST, ONE RUN, ONE PROFILE.** Every number below is evidence about this machine on this day. Only profile `small` was run to completion here. |
| Verdict | **PASS** (driver exit 0) |
| Companions | [vision run 1](../vision-live-2026-10-13/README.md) and [vision run 2](../vision-live-2026-10-13-run2/README.md) (a different profile, a different suite) |

## Result

| Item | Value (from the files in this directory) |
|---|---|
| Suite | `chat-v1` (`validate.out`: `suite_hash` `d158958d41bf433699f0902869d837b80f518d347f42e17db3d9e1772d37202c`), the suite the profile's catalog entry lists (`verify.out`: "validation suites for 'small': chat-v1") |
| Counts (`validate.out`) | pass=6, fail=0, undetermined=0 (5 golden probes + 0 controls + 1 determinism repeat; all 5 answers matched, determinism identical, 17 judge self-test cases all `ok`) |
| Model sha256 (`identity.txt`) | `6c99cc00ae910f6a532a80022cb4bc1939094527a089c29294b841c0bd87f74d` (`Llama-3.2-3B-Instruct-Q4_K_M.gguf`) |
| mmproj | N/A (text-only profile) |
| llama-server | version 8681 (Debian), CPU backend line as recorded in `identity.txt` |
| Unit `MemoryPeak` (`cgroup_peak.txt`, `peaks.txt`) | 970620928 B = 925 MiB |
| Unit `MemoryHigh` | 5368709120 B = 5120 MiB |
| Unit `MemoryMax` | 6442450944 B = 6144 MiB |
| GPU used (nvidia-smi) | baseline 296 MiB, peak 4335 MiB, final 296 MiB (`samples.csv`, `peaks.txt`, `verdict.txt`) |
| Min MemAvailable during the run | 20309 MiB (`samples.csv`, 5 samples at a 2 s interval) |
| Max memory PSI some avg10 | 0.47 (`samples.csv`) |
| Watchdog | never triggered (`watchdog.log`: started, `llmctl stop small rc=0`, terminated by the parent with no action) |
| After the stop | unit inactive, port 8085 not answering (`post_stop_state.txt`) |
| Prior set | none was running; nothing was switched off or restored (`verdict.txt`, `RESTORE_STATE=none`) |

The unit peak (925 MiB) is far below the `MemoryHigh` / `MemoryMax` values applied, on this one host in this one run. Those caps are not a result of this run
and no cap was changed because of it. The run lasted about 12 s from start to stop, so the peak describes a short load and five short probes only.

## Context: attempts that did not run a model (recorded, not hidden)

| Evidence directory | Profile | Outcome | Why (from the files) |
|---|---|---|---|
| `attempt-refused-psi-20261014T090901Z/` | `small` | REFUSED, exit 3, **nothing started** | pre-gate: `PSI full avg10 1.02 not < 1` (the first attempt for `small`, 10 minutes before the PASS above) |
| `attempt-fast-refused-psi-20261014T093330Z/` | `fast` | REFUSED, exit 3, **nothing started** | pre-gate: `PSI full avg10 1.20 not < 1` |
| `attempt-fast-port-in-use-20261014T093444Z/` | `fast` | **UNDETERMINED, exit 2: `fast` did NOT run live** | the pre-gate passed, then `llmctl switch fast` failed: `port 8080 for "fast" is already in use by another program` (`start.out`). The port owner was HelixCode's `helixcode-server.service`, not an llmctl service (that attribution was observed read-only later in the session with `ss`, about 1 minute after the attempt; it is NOT captured in these files). llmctl failed closed: no usable port, no model loaded, `cleanup stop rc=0`, nothing of the other program was touched. `validate` was never reached |

The two refusals show the pre-gate working as designed on a host that was briefly under memory pressure; they are not failures of a model. The `fast`
attempt is **not** a run of `fast`: no model was served, no probe was answered, and no `fast` claim of any kind follows from it.

## UNKNOWN / not shown by this run

* **Hardware tier.** On this host `llmctl plan` classifies the host as `below-minimum` (its RAM-budget rule), so the profile `small` (`min_tier` baseline) is `tier_ok=false` and not recommended here. The live driver gates on `fits=true` only, as does an explicit `llmctl start` (`docs/hardware-tiers.md`: tier gating affects recommendations and `llmctl auto`). The PASS therefore says nothing about a host that meets the baseline tier. (`plan_fits.txt` and `plan.json` of the run were not copied; the values are quoted from the original run directory.)

* **UNKNOWN: the process `VmHWM`** (not recorded), and the unit peak under a longer, larger-context or heavier workload than five short probes.
* **Run-to-run variation.** There is exactly one `small` run; other hosts, loads and reboots are not covered.
* **Other profiles.** `fast` did not run (see above); `vision-pro` and every other profile have not run live. They remain not validated.
* **Representativeness.** One host cannot say what a smaller or larger host would measure. The GPU peak (4335 MiB) includes whatever the driver and server reserved on this card.
* **What the judge does not check.** The pass means the known-answer suite `chat-v1` judged all of its probes correct; it is not a quality or accuracy benchmark of the model.
* **Tree state.** `harness.txt` records `git_dirty_files=1` at the time of the run; which file that was is not recorded here.

## Files

`verdict.txt` (driver result table), `validate.out` (full `llmctl validate small --json` capture), `identity.txt` (model sha256, GPU baseline/final),
`samples.csv` (watchdog samples), `watchdog.log`, `run.log`, `post_stop_state.txt`, `cgroup_peak.txt`, `peaks.txt`, `thresholds.txt` (gate and watchdog limits
derived for the profile), `gate.log` (pre-gate), `commands.log`, `harness.txt`, `verify.out` (checksum check and suite listing). In the `attempt-*` directories: `verdict.txt`, `run.log`, `gate.log`
(and for the port attempt `start.out`, `stop.out`, `commands.log`). The home directory is written as `$HOME` in these copies. Not copied: the environment-name
list, the systemd journal and the llama-server logs of the run, the plan JSON, and everything that could carry credentials; the credential files of llmctl were never read.
