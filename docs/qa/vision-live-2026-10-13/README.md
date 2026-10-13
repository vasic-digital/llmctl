# Live `vision` validation run - 2026-10-13

| Field | Value |
|---|---|
| Revision | 1 |
| Date | 2026-10-13 (UTC 11:50:09 to 11:50:45) |
| Profile | `vision` (Gemma 3 4B instruct, Q4_K_M, with mmproj), llama-server on port 8082 |
| Driver | `scripts/livetest/vision_live_test.sh` with `scripts/livetest/watchdog.sh` (guarded live test, see [live-test-protocol](../../live-test-protocol.md)) |
| Scope | **THIS HOST ONLY, ONE RUN.** Every number below is evidence about this machine on this day. Nothing here is a universal or a per-tier claim. |
| Verdict | **PASS** (driver exit 0) |

## Result

| Item | Value (from the files in this directory) |
|---|---|
| Counts (`validate.out`) | pass=21, fail=0, undetermined=0 |
| Composition | 16 golden probes + 2 control-self probes + 2 discrimination controls + 1 determinism repeat (identical); judge self-test 19/19 entries ok |
| Suite | `vision-golden-v1`, suite hash `9a897414915ef2d8bc7d83b2a82e209f7fe2da3c09e8a9ae7c22579ccc18320f` |
| Model file | `gemma-3-4b-it-Q4_K_M.gguf`, sha256 `882e8d2db44dc554fb0ea5077cb7e4bc49e7342a1f0da57901c0802ea21a0863` |
| mmproj file | sha256 `8c0fb064b019a6972856aaae2c7e4792858af3ca4561be2dbf649123ba6c40cb` |
| Readiness | up about 11 s after `llmctl start vision` (`run.log`) |
| Watchdog | never triggered (`watchdog.log`: started, then terminated by the parent with no action) |
| Note on the figures | `validate.out` holds 18 probe results (16 golden, 2 control-self), 2 discrimination controls, 1 determinism entry (21 = 18+2+1) and 19 judge self-test entries, all ok. The task brief that requested this write-up said "self-test 20/20"; the file says 19/19 and the file is the evidence. |
| Min MemAvailable | 19397 MiB (start 20135 MiB), from `samples.csv` |
| Max memory PSI some avg10 | 1.74, from `samples.csv` |
| GPU used (nvidia-smi) | baseline 277 MiB, max 4109 MiB during the run, back to 277 MiB after the stop (`samples.csv`, `identity.txt`) |
| After the stop | unit `llmctl-llama@vision.service` inactive, port 8082 not answering (`post_stop_state.txt`) |

Host selection note: which model a host gets is decided per host (catalog tiers and `llmctl plan`). That `vision` fits and passes here says nothing about another host.

## Known defect recorded in this evidence (fixed afterwards)

`verdict.txt` as captured says `no GPU use observed, peak 0MiB`. That line is **wrong**: `samples.csv` shows `gpu_used_mb` up to 4109. Root cause: the
driver read column 6 of `samples.csv` (`io_some_avg10`, a decimal) instead of the `gpu_used_mb` column (8, last), so the peak always came out 0. The
verdict and the PASS were not affected (the VRAM check is informational; the pass/fail rule compares the final value with the baseline). Fixed in the
driver, which now looks the column up by header name; the real `samples.csv` of this run is the regression fixture
(`tests/fixtures/livetest/real_samples_vision_2026-10-13.csv`, `tests/test_livetest_watchdog.sh` section G1). The file here is left as captured.

## UNKNOWN / not shown by this run

* **Superseded for the unit peak by [run 2](../vision-live-2026-10-13-run2/README.md): `MemoryPeak` 3005 MiB (3151007744 B) on this host.** The text below describes run 1 as it was. **UNKNOWN in run 1: unit cgroup peak (`MemoryPeak`) and the process VmHWM.** The driver of this run did not record them. Without them the memory cap of
  the `vision` unit is not calibrated by this run. The driver now records `MemoryPeak`, `MemoryHigh` and `MemoryMax` of the unit before the stop
  (`cgroup_peak.txt`, verdict rows `unit Memory* MiB`; `infinity`, `[not set]` and unavailable are reported as UNKNOWN, never 0); the first real value
  exists only after the next live run.
* **Single run.** No repeat across days, loads or reboots; run-to-run variation is UNKNOWN.
* **CPU/GPU split.** What the files show: the `llama-server --version` line prints a CPU backend library and the GPU memory rose to 4109 MiB. How many
  layers were offloaded is not recorded here; no further claim is made.
* **Other profiles.** `vision-pro` and every other profile were not tested; they remain not validated.

## Files

| File | What it is |
|---|---|
| `verdict.txt` | the driver's result table (contains the defective GPU-peak note, see above) |
| `validate.out` | the full `llmctl vision validate --json` capture, every raw model answer |
| `identity.txt` | model and mmproj sha256, llama-server version line, GPU baseline/final |
| `samples.csv` | watchdog samples every ~2-3 s: MemAvailable, memory/io PSI, GPU used |
| `watchdog.log` | watchdog start, the bounded stop, clean termination |
| `run.log` | driver timeline (gate, start, ready, final stop) |
| `post_stop_state.txt` | unit state and port check after the stop |

Sanitising: the only edit is the home directory prefix replaced by `$HOME` in these copies. Not copied on purpose: `env_names.txt`, `journal.txt`, `logs.txt`
(environment variable names and service logs) and the other raw driver files. The original evidence directory stays on the host that ran the test.
