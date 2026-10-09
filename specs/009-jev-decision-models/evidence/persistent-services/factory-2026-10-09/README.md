# llmctl persistent services on the-factory (10.6.100.221) — 2026-10-09

**Engine is the CPU-ONLY fallback build** (llama.cpp 1537a0a8b, GNU 15.2.1, HTTPS yes). The host has the NVIDIA driver 570.169 and
CUDA *runtime* libs 12.8/12.9 but no `nvcc` (needs root: see ROOT-STEPS.txt). The planner and unit files still say `mode=gpu`
(`--n-gpu-layers 99`), which the CPU binary silently ignores: **nothing runs on the RTX 5090 (VRAM used 18 MiB of 32607, GPU util 0 %).**
All latencies and the golden runs below are CPU numbers (Threadripper 7970X, 64 threads). No VRAM-per-profile measurement was possible.

## What is enabled and active (systemd --user, Linger=yes; see final-state.out, reboot-static.out)
Gateway `llmctl-decide-gateway` (0.0.0.0:8095, TLS, access-key auth, LLMCTL_DECIDE_NATIVE=1) + 10 engines:
decide-nli (onnx, cpu), decide-2b, decide-pro, decide-max, decide-kev-08b, decide-kev-4b, decide-kev-9b, decide-lev, decide-julia, decide-laya.
`llmctl decide models` -> all 10 `ready` (llmctl-status-models.out). NOT installed: `decide` (G-157), decide-tiny (not servable), chat/coder/vision (not requested).
Models: 10 profiles downloaded with size+sha256 verification and the decision smoke test passed each (verify/*.log). ~41 GiB on disk (catalog sum of the 10: ~29.9 GiB weights).
Per-unit limit drop-ins (units/*.50-llmctl-limits.conf): MemoryHigh/Max max 24/28G, kev-9b 16/20G, pro 10/12G, 2b 10/12G (raised from 6/8G after RSS 7.8G was seen), kev-4b & lev 8/10G, nli 6/8G, kev-08b 4/6G, julia & laya 2/3G, gateway 2/3G; TasksMax 512/256. Sum of MemoryMax = 118 GiB (< 251 GiB; my choice, not an operator-given figure).
Resources at the end (final-state.out): RAM used 96 GiB of 251 (available 157 GiB, ~63%), buffers/cache included in used. PSI: **/proc/pressure is not available on this kernel**, so the PSI stop condition could not be monitored; MemAvailable was checked instead (min ~157 GiB). No journal warnings.
Other things running on the host (untouched): claude, qdrant, lumen, azmcp, pipewire etc.; helix units are disabled.

## Live verification through the services
* asks/asks-all-profiles.txt: noul/choice/score on all 10 profiles via `llmctl decide ask --json` against the gateway: all 30 well-formed (CPU, wall 76 ms julia ... 920 ms lev; max 788-983 ms). (An earlier run with a shell-quoting error in my script is not part of this.)
* TLS: leaf SANs the-factory, localhost, 127.0.0.1, ::1, 10.6.100.221 (+ auto fd5f:...); `curl --cacert ca.crt https://10.6.100.221:8095/healthz` -> {"status":"ok"}; no-key `/v1/models` -> 401. Gateway cert generated with `decide cert ensure --san ...`; CA at ~/llmctl/cert/ca/ca.crt on the factory (public cert only copied nowhere).
* Golden (golden/<profile>/{questions,probes}/, stats.txt; run through the gateway, --permute-groups on questions, --max-options per catalog: max 16, kev-9b 255, pro 20, 2b 16):
  | profile | noul | choice | score |
  |---|---|---|---|
  | decide-max | 0.967 (n=60) | 0.878 (41, 4 limit-refused) | 0.806 (31) |
  | decide-kev-9b | 0.967 | 1.000 (41) | 0.710 |
  | decide-pro | 0.883 | 0.951 | 0.645 |
  | decide-2b | 0.867 | 0.732 (4 limit-refused) | 0.290 (= majority baseline, CI lower not above it) |
  Probes (n=22) are small; see stats.txt. Calibration "insufficient" (n<200). Maturity stays experimental.
* First attempt wrote probes over the question results (same out-dir); questions were re-run into questions/ and probes kept in probes/ (golden.sh = first launcher, golden2.sh = questions re-run).

## Reboot survival without rebooting
default.target.wants symlinks for all 11 units, Linger=yes, `systemd-analyze --user verify` clean (reboot-static.out); deleting all `/run/user/1000/llmctl/*.run` then `llmctl status` reconciled 10 reservations; `systemctl --user daemon-reexec` kept all 11 MainPIDs unchanged and active (reexec.out). Not proven by a real reboot. Caveat: the CPU llama.cpp binary lives in ~/llmctl-3.1.0-factory (must stay).

## Deviations / honest notes
* CPU-only engine (blocker: nvcc missing, root needed). Planner/unit `mode=gpu` is therefore misleading until the CUDA rebuild.
* Tree: HEAD d9cf7a5 + patch (PROVENANCE); the first (superseded) patch was reverse-applied. llama.cpp `.git` markers are fake files so `llmctl build llama` accepts the archive copy.
* Model downloads through the jump host were slow (about 1-4 MB/s per stream), so 10 parallel downloads were run as transient user services (a first nohup batch was killed by the session end and restarted; --continue-at resumed).
* Gateway timeout is the 8 s default (no profile is CPU-flagged by `-ngl 0`); all measured CPU answers were well below it, but a CPU engine presented as gpu is not covered by the CPU-adaptive rule.
* Key material never copied; env files redacted (state-env/); leak check for the access key over this directory: none.
