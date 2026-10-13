# Live `vision` validation run 2 - 2026-10-13

| Field | Value |
|---|---|
| Revision | 1 |
| Date | 2026-10-13 (UTC 13:25:38 to 13:26:14) |
| Profile | `vision` (Gemma 3 4B instruct, Q4_K_M, with mmproj), llama-server on port 8082 |
| Driver | `scripts/livetest/vision_live_test.sh` with `scripts/livetest/watchdog.sh` (guarded live test, see [live-test-protocol](../../live-test-protocol.md)), the version that records the unit's `MemoryPeak` |
| Scope | **ONE HOST, run 2 of 2.** Every number below is evidence about this machine on this day. Nothing here is a universal or a per-tier claim. Only profile `vision` was run. |
| Verdict | **PASS** (driver exit 0) |
| Companion | [run 1](../vision-live-2026-10-13/README.md) (same host, same day, earlier; did not record the unit's memory) |

## Result

| Item | Value (from the files in this directory) |
|---|---|
| Counts (`validate.out`) | pass=21, fail=0, undetermined=0 |
| Unit `MemoryPeak` (`cgroup_peak.txt`) | 3151007744 B = 3005 MiB |
| Unit `MemoryHigh` | 5368709120 B = 5120 MiB |
| Unit `MemoryMax` | 6442450944 B = 6144 MiB |
| Why those caps | `vision` is a GPU-mode profile whose memory footprint is not a measured provenance, so the unmeasured-GPU floors (5120 MiB high / 6144 MiB max) applied (`lib/service_linux.sh`, `_svc_profile_caps`) |
| GPU used (nvidia-smi) | baseline 277 MiB, max 4109 MiB, final 277 MiB (`samples.csv`, `verdict.txt`) |
| Min MemAvailable | 19281 MiB (`samples.csv`) |
| Max memory PSI some avg10 | 2.17 (`samples.csv`) |
| Watchdog | never triggered (`watchdog.log`: started, `llmctl stop vision rc=0`, terminated by the parent with no action) |
| After the stop | unit inactive, port 8082 not answering (`post_stop_state.txt`) |

## Calibration conclusion

The measured unit peak (3005 MiB) is below `MemoryHigh` (5120 MiB) by about 2.1 GiB and below `MemoryMax` by about 3.1 GiB, on this one host in this
one run. Decision recorded: **the cap floors are left unchanged.** Two runs on one host and one profile are not a basis to lower a safety margin.

## UNKNOWN / not shown by this run

* **UNKNOWN: the process `VmHWM`** (not recorded), and the unit peak under a longer or heavier workload than the 21 validation probes.
* **Run-to-run variation** beyond these two runs on this host; other hosts, loads and reboots.
* **Other profiles.** `vision-pro` and every other profile were not run; they remain not validated.
* **Representativeness.** One host cannot say what a smaller or larger host would measure.

## Files

`verdict.txt` (driver result table), `validate.out` (full `llmctl vision validate --json` capture), `identity.txt` (model/mmproj sha256, GPU baseline/final),
`samples.csv` (watchdog samples), `watchdog.log`, `run.log`, `post_stop_state.txt`, `cgroup_peak.txt`. The home directory is written as `$HOME` in these
copies; the environment-name list, journal and logs of the run were not copied.
