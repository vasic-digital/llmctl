# Native (`systemone-native`) decision profiles - catalog, gateway hardening, live run

Date: 2026-10-08 (UTC 08:30-09:25). Host `anton`: Ryzen 7 2700X, 31 GB RAM (~5 GB available, swap full, 15 GB tmpfs/shared held by
other programs), RTX 3060 12 GB (3.0 GB + 3.7 GB held by two other llama-servers). Engine: llama.cpp b11379, commit `1537a0a8b`,
CUDA arch 86 + OpenSSL (`submodules/llama.cpp/build`). The tree is uncommitted; nothing was staged, committed or pushed.

**Golden-set caveat, applies to every accuracy number here: the golden set is agent-authored, human review pending. A figure is
agreement with the authored labels, not an accuracy claim. 132 items, no calibration claim (< 200 labels). Wilson 95% intervals
and baselines are exactly what `scripts/golden/stats.py` printed.**

## 1. Headline

* Six catalog profiles added (ports 8103-8108), pins identical to the admission records and re-verified against the Hugging Face
  tree API at the pinned revision (`pin-reverify.json`, 15/15 files match, 0 mismatch).
* All six were downloaded through `bin/llmctl models download` (sha256 + size verified, native decision smoke run): 13,834,161,408 B
  (12.9 GiB) in total.
* **Live through the real stack (scheduler -> systemd user unit -> HTTPS gateway -> golden set): 3 of 6** - `decide-laya`,
  `decide-julia`, and `decide-kev-08b` (the latter once, under the earlier lower estimate, see 5.3).
  **3 of 6 were refused by the scheduler with numbers and NOT forced**: `decide-lev`, `decide-kev-4b`, `decide-kev-9b` (RAM budget, not VRAM).
  They did load and answer valid typed answers in the CPU download smoke on b11379 (shape evidence only).
* Only `decide-kev-08b` (Kev-0.8B) clears its majority/chance baselines on two types; `decide-laya` clears the choice baseline;
  `decide-julia` clears none (and does not reproduce its card's 73%).
* New finding that matters for host safety: the planner's flat `ctx/8 MiB` estimate under-reserves these models by 2-5x (section 6).
  Fixed with a measured, optional `defaults.overhead_mb`; the three measured profiles carry it.

## 2. Per profile: pins and decisions

All: `engine llama`, `decision.protocol systemone-native`, `max_options 255`, Apache-2.0 (HF API license tag `apache-2.0`,
`pin-reverify.json`), `defaults.parallel 1`, f16 KV, port from the free range 8103+ (8097 stays `decide-max`; 8099/8100/8102/8110/8111
are held by other programs on this host). Name: `.` is not legal in a profile name (instance separator, `ProfileSpec` regex), so
Kev-0.8B is `decide-kev-08b`.

| profile | HF repo @ revision | file | bytes | sha256 | min_tier | catalog ctx / overhead_mb |
|---|---|---|---|---|---|---|
| `decide-julia` 8103 | ggml-org/Julia-1-GGUF @ 16fee17949206fbf58da9347daea44d792a81211 | Julia-1-Q8_0.gguf | 168,166,496 | 1ea6a7e87156eeeda88cb7a36a61265b37ba7b993897b7289b99aea5b5e47069 | below-minimum | 1024 / 1160 |
| `decide-kev-08b` 8104 | ggml-org/Kev-0.8B-GGUF @ e551e319d483ff57e1ff208924b349d397cffc1c | Kev-0.8B-Q8_0.gguf | 812,406,304 | 27278f34eb3273bceea4c053dc50dd61a5161da21a718c4aacdf8fd5830771d0 | below-minimum | 2048 / 1540 |
| `decide-kev-4b` 8105 | ggml-org/Kev-4B-GGUF @ d924f2e2c3872da8b8aaf3eb4453b4126deceb79 | Kev-4B-Q4_K_M.gguf | 3,033,489,824 | 33ae6b18926502b2209a1bf7d3b61a350d65938441515c686bb87d226a19eff9 | baseline | 8192 / (unmeasured) |
| `decide-kev-9b` 8106 | ggml-org/Kev-9B-GGUF @ ec2bbfe6620218aee2e01cc93bb78dee2a96ed58 | Kev-9B-Q4_K_M.gguf | 6,358,923,744 | 86a6084984a6ef6818eb12c07cdc67ed3c47b00208d41a8816c64301bc6bcbda | workstation | 8192 / (unmeasured) |
| `decide-laya` 8107 | ggml-org/Laya-GGUF @ 22265007700297ba9e128297e82540cf28c5d7d4 | Laya-Q8_0.gguf | 449,397,600 | c06528c5746d3bb8baa72a27938be95abbfd0b226f8471e8a9e365ed0bb066d2 | below-minimum | 1024 / 440 |
| `decide-lev` 8108 | ggml-org/lev-GGUF @ 3e9286a79ae857b4e1de051c92fab6dc574581ce | lev-Q4_K_M.gguf | 3,011,777,440 | 3f61b27c00a098dbc79ed099cca3985cbe0b63d17ac7fedebf2dca1d84f7f3a8 | baseline | 8192 / (unmeasured) |

No admission record lacked a field. Re-verification quoted: `python3 specs/009-jev-decision-models/evidence/pin_reverify.py` calls
`GET https://huggingface.co/api/models/<repo>/tree/<revision>?recursive=1` and `GET .../revision/<revision>` per profile; LFS `oid`
= sha256, `size` = bytes (`pin-reverify.json`, retrieved 2026-10-08).

Benchmark provenance written into the catalog (FR-052 classes): Julia-1 73.15% (1,463/2,000, H200 BF16) and lev 68.9% S1Bench:
`vendor-measured`, "not reproduced"; Kev-0.8B/4B/9B and Laya: `unverified` ("no figure recorded"). Admission also records
Laya's upstream 1,024-token default limit - reflected in `decide-laya`'s 1024 window.

Download (project path `bin/llmctl models download`; resume + sha256 + size + native decision smoke; each profile's own log is
`<profile>/project-download-evidence.log`, console in `<profile>/download.txt`): Julia re-used the hardlinked, already verified
file (verification still ran: "already present and verified"), 7 s; Laya 1 m 23 s; Kev-0.8B 19 s; lev 1 m 36 s; Kev-4B 1 m 39 s;
Kev-9B 17 m 52 s (network slowed to ~3 MB/s). Disk: 46 GB free before, 32 GB after (other writers also use it).
All six passed the post-download native smoke (`smoke ok: protocol=systemone-native ...`, 2 and 4 options, shape evidence only).

## 3. Scheduler admission (the "fits / refused" verdicts, with numbers)

Real `bin/llmctl start <profile>` output, `<profile>/start.txt`. The RAM budget is `MemAvailable - 4 GiB` (hard-coded headroom) and
moved between 718 and 2043 MiB while I worked.

| profile | verdict | numbers |
|---|---|---|
| `decide-laya` | started, mode cpu | reserved 996 MiB (428 weights + 128 flat KV + 440 overhead) |
| `decide-julia` | started, mode cpu | reserved 1448 MiB (160 + 128 + 1160). `llmctl plan` a few minutes earlier said it did not fit (needs 1448, 1409 available); the start a minute later was admitted - the budget follows live MemAvailable. |
| `decide-kev-08b` | live run happened at the old estimate (1030 MiB reserved, `LLMCTL_CTX_DECIDE_KEV_08B=2048`); at the final catalog **refused**: needs 2570 MiB, 1835 MiB remain (`decide-kev-08b-refusal-final/`). At the original catalog ctx 8192: needs 1798, 1374 remain (`decide-kev-08b-refusal-default-ctx8192/`) |
| `decide-lev` | **refused** | needs 3896 MiB RAM, 1976 remain (also 1030 and 1557 at other moments) |
| `decide-kev-4b` | **refused** | needs 3916 MiB RAM, 2043 remain (1311 earlier) |
| `decide-kev-9b` | **refused** | needs 7088 MiB RAM, 1746 remain |

With the operator-permitted stop of `llmctl-llama@vision` (VRAM budget rose from 4210 to 7408 MiB) the verdict for lev did not change: the GPU
placement reserves a fixed 2048 MiB of host RAM and only 1557-1680 MiB were available. I did not force anything and did not lower the 4 GiB
headroom. I did not run lev/Kev-4B/Kev-9B outside the scheduler.

## 4. Live results (real HTTPS gateway, real access key, golden set, probes)

Setup: `llmctl decide serve` (bind 127.0.0.1:8095, `LLMCTL_DECIDE_NATIVE=1`, CA/leaf under a scratch `LLMCTL_HOME`, key generated into a scratch
`LLMCTL_ENV_FILE` by the project's own first-start rule and never printed; a 0600 key-only copy fed `run_golden.py --key-file`), engines started by
`bin/llmctl start` (systemd user unit), one model at a time, `nice -n 10`. Harness: `run_live.sh` in this directory. The engine really loaded its
own libraries: `<profile>/engine-libs.txt`.

### 4.1 Accuracy vs baseline (Wilson 95%, from `<profile>/golden-stats.txt`; "cleared" = interval lower bound above the baseline)

| profile | noul n=60 | choice n=41 | score n=31 | flip rate (option order) | well-formed |
|---|---|---|---|---|---|
| `decide-julia` | 55.0% [42.5, 66.9] vs 66.7% majority: no | 34.1% [21.6, 49.5] vs 23.5% chance: no | 22.6% [11.4, 39.8] vs 29.0%: no | 41.5% (17/41) | 132/132 |
| `decide-laya` | 71.7% [59.2, 81.5] vs 66.7%: no | 80.5% [66.0, 89.8] vs 23.5%: **cleared** | 32.3% [18.6, 49.9] vs 29.0%: no | 19.5% (8/41) | 132/132 |
| `decide-kev-08b` | 81.7% [70.1, 89.4] vs 66.7%: **cleared** | 87.8% [74.5, 94.7] vs 23.5%: **cleared** | 29.0% [16.1, 46.6] vs 29.0%: no | 2.4% (1/41) | 132/132 |
| `decide-lev`, `decide-kev-4b`, `decide-kev-9b` | not run (scheduler refusal) | | | | |

Calibration: `insufficient for calibration (n=132, need 200)` on every run; no calibration claim. Probe sets (23 items, tiny n, all intervals
include the baseline): `<profile>/probes-stats.txt`. Julia-1 does not reproduce its card's 73.15%: that figure is H200 BF16 on the vendor set,
this is a Q8_0 on a different, agent-authored set - the two are not comparable, and I make no claim either way beyond what the intervals show.
By option count Julia-1 gets 0/6 at 8 options (interval 0.0-0.39); Kev-0.8B is 100% at 2, 3, 12, 20 options (n=4-7).

### 4.2 Determinism, latency, edge cases (from `determinism-edges.json`, `latency.json`)

* Eight identical requests: **byte-identical 8/8 through the gateway and 8/8 on the engine directly**, for all three live profiles.
* Gateway `model` field = profile name; the engine's own `model` is a local file path (recorded: `engine_model_field_is_a_local_path`).
* Latency through the gateway, golden run (173 requests), p50 / p95 / max: Julia 19 / 32 / 171 ms; Laya 61 / 73 / 87 ms; Kev-0.8B 192 / 357 / 696 ms (all cpu mode, 1 slot).
* Edges (status): single-option choice 422; no key 401; wrong key 401; unknown model 422; 9,000-char state (over the gateway cap) 422;
  7,500 dense hex chars (token overflow) 422; 6,500 and 8,000 char prose states 422 for the 1024-token profiles and 200 for Kev-0.8B (2048);
  20-option choice 200.
* `llmctl decide smoke` against each engine directly and `llmctl decide ask` through the gateway: `smoke.txt`, `cli-ask.txt`.

### 4.3 Memory (own pid; `<profile>/memory.txt`; cgroup `MemoryPeak` and `VmHWM`)

| profile | reserved by scheduler | idle VmHWM | after golden | after edges | VRAM (CUDA context, cpu mode) |
|---|---|---|---|---|---|
| `decide-julia` (ctx 1024) | 1448 MiB | 504 MiB | 814 MiB | 820 MiB (MemoryPeak 531 MiB) | 126-176 MiB |
| `decide-laya` (ctx 1024) | 996 MiB | 680 MiB | 916 MiB | 920 MiB (MemoryPeak 433 MiB) | 174-232 MiB |
| `decide-kev-08b` (ctx 2048, old estimate 1030 MiB) | 1030 MiB | 1220 MiB | 1504 MiB | **2567 MiB** | **2328-2382 MiB** |

**"cpu mode" is not VRAM-free.** The scheduler placed all three in `mode=cpu` (`-ngl 0`, planner VRAM = 0), but a CUDA build offloads large-batch host ops to the GPU (`--op-offload`, default on): the pid held 126-232 MiB for the two encoders and **2.3 GiB for Kev-0.8B** (a ~775 MiB model). `op-offload-vram-experiment.txt` (direct runs): Kev-0.8B 2328 MiB VRAM / 2585 MiB RSS with op-offload vs 104 MiB VRAM but 4248 MiB RSS and 15x higher latency (18.2 s for an 85%-window state vs 1.2 s) with `--no-op-offload`; Laya 174-208 MiB vs 104 MiB VRAM, latency 188 ms vs 5.6 s. On a GPU shared with two other programs this is an unreserved 2.3 GiB for the Qwen3.5-class profiles; I did not change the launch line for it (no clearly better setting exists), flagged below.
Direct CPU vs `-ngl 99` comparison (`gpu-direct/gpu-vs-cpu.jsonl`): answers identical to all printed digits, 8/8 byte-identical both ways; VRAM of
the pid 156 -> 204 MiB (Julia) and 204 -> 564 MiB (Laya). I do not claim from this that the compute ran on the GPU; I only measured placement of memory.

## 5. Code changes with proof

### 5.1 Gateway (`internal/gateway/driver.go`, new `native_engine_advance_test.go`) - G-116
* Engine `HTTP 500 "input (N tokens) is too large to process ... increase the physical batch size"` on `/v1/systemone` -> `422 validation_failed`
  (was the retryable 502). Matches on the message (the type is the generic `server_error`) and only on that path.
* Engine `501 "This model is not a decision model"` on `/v1/systemone` -> non-retryable 500, logged once (was 502).
* Already correct, now pinned by tests: response `model` is the profile name (never the engine's file path); a one-option `choice` is refused by the
  contract with 422 before any engine call.
* RED (`gateway-native-RED.txt`): `TestNativeBatchTooLargeIs422` and `TestNative501NotADecisionModelIsNotRetryable` failed on the pre-change tree. GREEN: package passes.
* Mutation proof (`gateway-native-mutation.txt`): dropping the message check fails `TestNativeOther500StaysBackendFailed`; removing the path restriction fails
  `TestBatchTooLargeMappingIsNativeOnly`; making 501 retryable fails `TestNative501NotADecisionModelIsNotRetryable`. Source restored byte-for-byte after each.
* `internal/gateway/internal/fakebackends`: new `/v1/systemone` handler (test fake only), used by the download-smoke test.

### 5.2 Catalog, scheduler, planner, download
* `models/catalog.json`: six profiles + `ports`; `.specify/memory/constitution.md` port map; `docs/hardware-tiers.md` rows/table; `docs/decision-models.md`; CHANGELOG line; docs/scripts pages.
* `lib/scheduler.sh`: `--batch-size 4096 --ubatch-size 4096 --no-cache-prompt` for native profiles (new `catalog_decision_protocol` in `lib/catalog.sh`); `decide`
  ranking extended with the six (ascending footprint, after `decide-max`). RED `scheduler-native-RED.txt` (7 failures) -> GREEN `scheduler-native-GREEN.txt`;
  golden-false (letter-logit and chat profiles unchanged) included in `tests/test_scheduler.sh` 11b.
* `lib/catalog.sh`: optional `defaults.overhead_mb` (validated 0..65536) added to RAM (cpu) / VRAM (gpu) / capacity footprint. RED: 5 failing assertions
  before the change in `tests/test_planner.sh`; GREEN after; invalid values (-1, "x", 70000) refused with exit 1; absent = unchanged (golden-false).
* `lib/download.sh`: the decision smoke follows `decision.protocol`; native smokes `/v1/systemone` with a 4096 context and no `--expect-choice`
  (a smoke answer is shape evidence). `tests/test_decide_download.sh` 3b: RED (2 failures: protocol and ctx not honoured) -> GREEN.
* Tests updated for the new profile set: `tests/test_planner.sh` (recommended sets, co-residency groups, SC-012 rows, ranking), `tests/test_scheduler.sh`
  (ranking text), `tests/test_catalog_json.sh` (new section 7: pins == admission records, ports, ctx/overhead, 4 paired mutations).
  `scripts/doc_counts.sh --check decide_download` -> match (19).

### 5.3 G-129 (`lib/svc_hook.sh`, tests in `tests/test_service_ops_hardening.sh`, docs svc_hook/service_macos)
Reproduced first (`g129-ldd-repro.txt`; the invoking shell's own `LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu`): `ldd` binds the system `libggml.so.0`, and
loading a model dies with `undefined symbol ggml_flash_attn_ext_set_n_kv_max`; prepending the engine's directory binds the build's own libraries; unsetting also
works. Decision: **prepend, do not unset** (keeps CUDA directories a caller may need). `hk_run_engine` now calls `hk_engine_libpath` before `exec`: prepends the
engine's dir (also `DYLD_LIBRARY_PATH` on Darwin) only when that dir ships `libggml*`. RED `g129-RED.txt` (2 failures, engine saw only the polluted path) -> GREEN
(3 assertions incl. a golden-false for an engine without libggml). The Linux systemd unit already writes `LD_LIBRARY_PATH=<engine dir>` into its EnvironmentFile and was
confirmed fine live (the units' engines mapped `build/bin/libggml.so.0.25.3`). The download smoke already prepended. **macOS verified statically only (no Mac).**

## 6. Findings that need a decision from you

1. **Planner under-reservation (host safety).** Peak RSS of native encoder-class models is dominated by activation buffers that grow with window and state length, not weights
   (`ctx-peak-memory-experiment.txt`, CPU, state at 50/85/97% of the window): Julia-1 (160 MiB weights) peaked at 1.44 GiB (ctx 1024), 2.23 GiB (2048), 3.70 GiB (4096);
   Laya 0.99 / 1.16 / 1.54 GiB. The flat rule reserved 416 MiB / 684 MiB at ctx 2048; real peaks were 2.0 and 1.2 GiB. `-ub` size had no effect (`ubatch-memory-experiment.txt`).
   Mitigation delivered: windows of 1024/1024/2048 tokens and measured `overhead_mb`. **Kev-4B, Kev-9B and lev have NO measured overhead** (never admitted here) - their
   reservation is weights + flat KV only and is very likely too low. Measure before relying on them.
1b. **CPU-mode VRAM is unreserved** (see 4.3): the planner books 0 VRAM for a cpu-mode llama profile, but a CUDA build holds 0.1-0.2 GiB (encoders) to 2.3 GiB (Kev-0.8B; likely larger for the 4B/9B) via op-offload. Either account for it in cpu mode or prefer gpu placement for native Qwen3.5-class profiles; `--no-op-offload` removes the VRAM but makes Kev-0.8B 15x slower and raises its RSS to 4.2 GiB.
2. The first Julia/Laya/Kev-0.8B runs (`decide-julia-ctx2048-pre-overhead/`, `decide-laya-ctx2048-pre-overhead/`, Kev-0.8B) were admitted under the old, too-low estimate; Julia's
   RSS reached 2.0 GiB in the edge battery against a 416 MiB reservation. The final Julia and Laya runs are at the corrected catalog values; Kev-0.8B could not be repeated
   (refused at the final values) so its run stays labelled as such.
3. `LLMCTL_DECIDE_NATIVE=1` is still required (OD-1 gate untouched). I did not flip the default.
4. Restoring vision: `llmctl start vision` was **refused** by the scheduler after I stopped it (needs the fixed 2 GiB RAM, 1343 MiB budget). I restarted the same unit with
   `systemctl --user start llmctl-llama@vision.service` (identical command line, `vision-restore/cmdline-before.txt`), health 200, one real prompt answered `pong`
   (`vision-restore/check.txt`), and recreated its `.run` reservation file with the previous content. Down time ~85 s (09:07:47-09:09). This is the one place I stepped around the scheduler.
5. Not mine, failing now: `go test ./internal/gateway` -> `TestNoCodeReadsTheInternalKeyFromTheEnvironment` fails on the new untracked
   `docs/scripts/test_no_retired_vars.md` (line 12 names the retired env var). Every other test in the package passes.

## 7. Not done / honest gaps
* lev, Kev-4B, Kev-9B: no golden/probe/determinism/memory evidence (refused). Kev-0.8B: no run at the final catalog values.
* Accuracy is on an agent-authored set with human review pending; intervals are wide; flip rates measured, not removed.
* VRAM of kev-4b/lev/kev-9b (likely several GiB even in cpu mode) not measured; VRAM in a real GPU-placed run through the scheduler was not exercised (the scheduler's 2048 MiB host-RAM requirement for gpu placement could not be met).
* `docs/golden-set.md` baseline for `noul` is 66.7% (majority); profiles under it are not "better than always-no".
* macOS `run-engine` path untested on macOS. Containers/other agents' processes (a third-party llama-server on 2574) were not touched.
* `evidence/gaps-register.md` is not mine to edit: G-116 (gateway part), G-117 (RPATH note: now documented), G-129 can be marked FIXED with the references above; G-115, G-114, G-118 remain.

## 8. Gates run (final)
`go vet ./...` clean; `gofmt -l` on changed Go files: none; `go test -race -count=1 ./internal/gateway/... ./cmd/llmctl-decide/...`: all pass except the one in finding 5;
`tests/test_{catalog_json,planner,scheduler,decide_download,service_ops_hardening,gateway_endpoints,decision_capacity,macos_plist,services,decide_service,ctx_kvtype_override,dynamic_ports,doc_reachability,docs_no_literal_keys,archive_completeness,regression_defects,decide,run_tests_format}.sh`: PASS;
`PATH=$HOME/.local/bin:$PATH make lint` rc 0; `make json-check` OK (22 profiles). Full `make test` not run (yours).
Evidence integrity: every profile directory and this directory carry MANIFEST.json + SHA256SUMS (`python3 tests/evidence/manifest.py verify <dir>`); a key scan over all 244+ evidence
files found none of the access or internal keys (same scan path finds a planted needle).
Cleanup: gateway stopped (`decide serve --stop`), every engine stopped through `llmctl stop`; the only processes left are the restored vision service and a third party's llama-server.
