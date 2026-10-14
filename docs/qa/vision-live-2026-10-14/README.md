# Live `vision` validation run - 2026-10-14

| Field | Value |
|---|---|
| Revision | 1 |
| Date | 2026-10-14 (UTC 11:48:38 to 11:53, see the files) |
| Host | `anton` (one host; every number below is about this machine on this day) |
| Profile | `vision` (Gemma 3 4B instruct Q4_K_M + mmproj f16), llama-server build 11379 (commit 1537a0a8b), port 8082, systemd user unit |
| Driver | `llmctl vision validate` directly (NOT the guarded driver `scripts/livetest/vision_live_test.sh`; no watchdog ran) |
| Code | llmctl at `f6add5b` (the commit that added `host` to the validation record) |
| Verdict | **PASS**, `VERDICT: PASS pass=21 fail=0 undetermined=0`, exit 0 (`04_vision_validate.txt`) |
| Companions | [2026-10-13 run 1](../vision-live-2026-10-13/README.md), [2026-10-13 run 2](../vision-live-2026-10-13-run2/README.md) |

## Sequence (each step is a file in this directory)

| File | What happened |
|---|---|
| `00_resources.txt` | Before: 16263 / 30974 MiB used (52 %; the 60 % cap is 18584 MiB), MemAvailable 14710 MiB, memory PSI full avg10 0.00, 11140 MiB VRAM free, 1.1 TB disk free. `vision` already downloaded, so nothing was downloaded. `require-validated vision` exit **1**: `host changed (validated null, now "anton")`. The record from 2026-10-12 predates the `host` field and is refused, as intended. |
| `01_vision_validate.txt` | First attempt, exit **2** (UNDETERMINED): the profile started, then the host-pressure gate refused before any probe (`PSI full avg10=4.03 > 2`), stopped the profile again and recorded nothing. Correct gate behaviour. (Its message says "nothing was started or probed", although this call had started the profile and then stopped it - wording inaccuracy, open item below.) |
| `02_psi_idle.txt` | With nothing of ours running, full avg10 decayed 1.48 -> 0.01 within 55 s. |
| `03a_psi_ambient_45s.txt` | 45 s ambient sample: full avg10 0.00 throughout. |
| `03_start.txt`, `03b_psi_during_load.txt` | `LLMCTL_VALIDATE_ON_START=0 llmctl start vision` while sampling PSI every second: full avg10 **0.00 for all 50 samples** (the model files were in page cache by then). |
| `04_vision_validate.txt` | `llmctl vision validate` against the running unit: PASS 21/0/0, then `require-validated vision` exit **0**, record `status=pass host=anton engine_tag="build 11379, commit 1537a0a8b"`, suite hash `9a897414...8320f`. |
| `05_memory_and_stop.txt` | Unit `MemoryCurrent` 1070665728 B, `MemoryPeak` 1071599616 B (1022 MiB), `MemoryMax` 6144 MiB; host 16288 MiB used (53 %); GPU 4128 MiB used; `llmctl stop vision` exit 0. |

## Raw answers per screenshot (`04_vision_validate.txt`)

| Probe | Answer | Verdict |
|---|---|---|
| 01_text_large/read | `ORANGE TIGER\n42` | PASS |
| 02_shapes_count/red_circles | `3` | PASS |
| 02_shapes_count/blue_squares | `2` | PASS |
| 03_login_form/transcribe | `SIGN IN\nUSERNAME\nPASSWORD\nLOGIN` | PASS |
| 03_login_form/screen_type | `This screenshot depicts a classic, pixelated login screen reminiscent of early 1980s computer systems.` | PASS |
| 04_list_view/items | `APPLE\nBANANA\nCHERRY\nGRAPE` | PASS |
| 04_list_view/count | `4` | PASS |
| 05_table/transcribe | `NAME   AGE   CITY\nANNA   31   PARIS\nBORIS  45   OSLO\nCLARA  27   ROME` | PASS |
| 05_table/lookup | `OSLO` | PASS |
| 06_dialog/transcribe | `WARNING\nDELETE FILE?\nCANCEL\nDELETE` | PASS |
| 06_dialog/buttons | `CANCEL, DELETE` | PASS |
| 07_dark_theme/transcribe | `SETTINGS\nDARK MODE\nVOLUME 75` | PASS |
| 07_dark_theme/theme | `Dark` | PASS |
| 08_small_text/invoice | `7731` | PASS |
| 08_small_text/total | `58.40` | PASS |
| 09_color_blocks/colors | `Red, Green, Blue` | PASS |
| 90_bad_blank/read (golden-bad control) | `NO TEXT` | PASS |
| 91_bad_wrong_content/read (golden-bad control) | `PURPLE HORSE\n17` | PASS |
| control 90_bad_blank vs 01_text_large/read | `NO TEXT` - golden checks FAIL on it, as required | PASS |
| control 91_bad_wrong_content vs 01_text_large/read | `PURPLE HORSE\n17` - golden checks FAIL on it, as required | PASS |
| determinism 01_text_large/read | repeated request byte-identical | PASS |

No answer was wrong, so no expectation was touched and no root-cause investigation of a wrong answer was needed.

## Limits (read before quoting)

* **One host, one profile.** `vision-pro` and every other profile were not run here.
* **The cause of the first refusal's pressure is UNCONFIRMED.** Measured: ambient pressure was 0.00 before and after, and a warm-cache load produced 0.00. The first attempt was the first read of the 3.3 GB model files after a host reset (cold page cache); reproducing a cold cache needs a root-only cache drop, which was not done.
* **`MemoryPeak` here (1022 MiB) is not comparable to run 2's 3005 MiB.** The files were already in page cache, first read (and charged) by the earlier unit that the gate stopped. It is not evidence of a smaller footprint.
* **Not the guarded driver.** No watchdog and no `samples.csv`; the host was sampled by hand (files `00`, `02`, `03a`, `03b`, `05`).

## Open item found by this run

* The pressure-refusal message of `validate_profile` says "nothing was started or probed" also when that same call had started the profile (and then stopped it, as the next line says). The behaviour is right; the sentence is not. Not changed in this run.
