# llmctl persistent services on nezha.local — 2026-10-09

Install: `~/llmctl-3.1.0` on nezha (user `milosvasic`), from `git archive HEAD` of local HEAD
`d9cf7a5ede1e16fc6e3f5a583ca91504fa83427e` (no submodules; the uncommitted working tree is NOT deployed). See `PROVENANCE`.

## What was done (commands, in order)
1. `git archive HEAD | ssh nezha.local 'tar -x -C ~/llmctl-3.1.0'`.
2. `llmctl-decide` built locally from a clean HEAD export (+ `submodules/containers` @4a8f04e), under
   `bounded-run -m 6G -t 800 -T 900`: `CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build ./cmd/llmctl-decide`,
   sha256 `3d2f3c43e647faab46cb3e3b104280b40ef3c08122e1ae476e486ba827f59d84`, scp'd to `~/llmctl-3.1.0/build/`.
3. Models hardlinked (no copy) from `~/llmctl-work/models/*` and `~/llmctl-work-realcheck/data/models/decide-nli`
   into `~/.local/share/llmctl/models/`; `llmctl models verify <p>` → "passed checksum verification" for
   decide, decide-pro, decide-2b, decide-max, decide-nli (see `models-plan-final.out`).
4. ONNX venv: `llmctl build onnx` (hash-locked, `--require-hashes`) → `~/.local/share/llmctl/venv-onnx`.
5. `LLMCTL_LLAMA_SERVER=~/llmctl-work-live/llama.cpp/build/bin/llama-server` (commit 1537a0a, reused; RPATH points into that
   work dir, so it must stay) — `llmctl install` (units), `llmctl plan`, `llmctl enable decide-nli|decide-2b|decide`.
6. Gateway: `~/.local/state/llmctl/decide/gateway.conf` = `LLMCTL_DECIDE_TIMEOUT=120` (explicit; the CPU-adaptive default is
   uncommitted), then the unit was installed/enabled/started by calling `decide_service_enable` (lib/service_linux.sh)
   directly: committed `llmctl decide serve` has **no `--enable` flag** (`flag provided but not defined: -enable`).

## Planner verdict (`llmctl plan`, budget RAM 55652 MiB, VRAM 0, tier baseline)
FITS: decide, decide-nli, decide-2b (+ others). GATED `min_tier=workstation`: **decide-pro, decide-max** (downloaded and
checksum-verified, NOT enabled — the tier gate was not overridden). Enabled RAM booked: 3671+3006+3006 MiB.

## Deviations / defects found (honest)
* **D1 committed bug**: `lib/portreg.sh` writes `LLMCTL_REG_HEALTH=/health` for the onnx engine but `lib/onnx_server.py`
  serves `/healthz` → decide-nli is never registered, the gateway never sees it. Workaround applied ONLY to state, not code:
  `services/decide-nli.env` `LLMCTL_REG_HEALTH=/healthz`, then restarted the nli unit and the gateway. A future
  `llmctl enable decide-nli` regenerates the env file and re-introduces the bug until portreg.sh is fixed. The
  Tracebacks (`ConnectionResetError`) in `decide-nli.log` are from the pre-fix waiter probing `/health` (404), not model failures.
* **D2**: profile `decide` (4B letter-logit) answers `noul` but `choice` and `score` return HTTP 422 `readout_failed`
  (consistent with open G-155). decide-2b and decide-nli answer all three types.
* **D3**: gateway leaf cert SANs are `nezha,localhost,127.0.0.1,::1` — a remote client using `nezha.local` or `192.168.1.90`
  fails hostname verification unless it uses `-k` or a re-issued cert.
* `llmctl decide serve --enable` documented in service_linux.sh comments is not wired in the CLI (see step 6).

## Live verification (all on nezha, through the services)
* `is-enabled`/`is-active` = enabled/active for the 4 units; `llmctl status` lists 3 profiles running;
  `llmctl decide models` → decide, decide-2b, decide-nli all `ready` (`step4-reexec-check.out`).
* `llmctl decide ask --json` noul/choice/score on decide-nli and decide-2b: well-formed answers (e.g. nli choice billing 0.926,
  2b score 3.60, latencies 0.1–1.4 s); `decide` noul ok (0.997), choice/score 422 (D2).
* No-key `GET /v1/models` → 401; `/healthz` → 200 `{"status":"ok"}` (also from this workstation via https://nezha.local:8095).
* Gateway process env has `LLMCTL_DECIDE_TIMEOUT=120`.

## Reboot-survival without rebooting
* Enablement symlinks in `~/.config/systemd/user/default.target.wants/`, `Linger=yes`, `systemd-analyze --user verify`
  of the llmctl units: no findings (only an unrelated boba unit warns). See `step4-reexec-check.out`.
* Simulated tmpfs wipe: removed `/run/user/1000/llmctl/*.run` → `llmctl status` self-healed the 3 reservations.
* `systemctl --user daemon-reexec`: all 4 units kept the same MainPID and stayed active.
* What a real reboot does / could fail: user manager starts via linger, units start WantedBy=default.target; gateway may start
  before engines are registered (registry resolver re-checks, but early requests may see fewer models until the 3 hooks
  re-register, nli needs ~3 s, 4B ~3 s); `After=network-online.target` has no effect in the user manager; the llama-server
  RPATH depends on `~/llmctl-work-live` surviving; D1's env-file fix survives reboots but not a re-`enable`;
  registry rows from before the boot are stale until re-registration (they carry pid+start-time proofs); NOT proven by an
  actual reboot (forbidden).

## Resources at the end
available RAM 52 GiB, `/proc/pressure/memory` some/full avg10 = 0.00; RSS: nli 3209 MiB, decide-2b 2251 MiB, decide 4771 MiB,
gateway 22 MiB. Nothing outside llmctl was touched (the helix/boba/container units were left as they were).

Files: `PROVENANCE`, `units/` (unit copies), `state-env/` (env files with key paths redacted, gateway.conf),
`step4-reexec-check.out`, `models-plan-final.out`, `MANIFEST.sha256`. No key material is stored here.

---
## Addendum 2026-10-09 (follow-up, ~13:40–13:50 UTC)

1. **`decide` disabled** (G-157: choice/score 422 `readout_failed`): `llmctl disable decide` → `llmctl-llama@decide` is-enabled=disabled, is-active=inactive; wants-symlink removed.
2. **decide-pro and decide-max enabled.** Sanctioned path: `docs/hardware-tiers.md` states tier gating "affects recommendations and `llmctl auto`; an
   explicit `llmctl start <profile>` is allowed whenever the footprint fits" (the planner still prints them GATED; `LLMCTL_TIER` is only an internal variable,
   there is no env/config tier override, and nothing in the planner/tier code was changed). The explicit `llmctl enable decide-pro` / `decide-max` was
   accepted (footprint 5260 / 10174 MiB vs budget ~53 GiB) — a deliberate, visible use of that documented explicit-enable behaviour.
   Per-unit drop-ins (`units/dropins/`, `~/.config/systemd/user/<unit>.d/50-llmctl-limits.conf`): decide-max MemoryHigh 20G / MemoryMax 24G / TasksMax 512;
   decide-pro 9G / 12G / 512; gateway MemoryHigh 2G / MemoryMax 3G (the "2G" was given for the gateway only; the 3G ceiling and all TasksMax values are my choice) / 256.
   `systemctl --user show` confirmed the limits; gateway restarted, `LLMCTL_DECIDE_TIMEOUT=120` still in its environment.
3. **TLS names:** `llmctl decide cert renew --san dns:nezha,dns:nezha.local,dns:localhost,ip:127.0.0.1,ip:::1,ip:192.168.1.90` (documented in `llmctl decide cert` usage)
   re-issued the leaf as version 2 with the SAME CA (SHA-256 57:B2:5A:F6…B7:62:3C unchanged, `cert-show-after-reissue.out`); SANs now include nezha, nezha.local,
   localhost, 127.0.0.1, ::1, 192.168.1.90 (plus auto-added 10.152.21.129, 10.1.106.73 and an fc00 address). Gateway restarted.
   From anton with only the public CA copied: `curl --cacert ca.crt https://nezha.local:8095/healthz` and `https://192.168.1.90:8095/healthz` → `{"status":"ok"}` (hostname verified).
   Finding: the locally cross-built (CGO_ENABLED=0) `llmctl-decide` client on anton cannot reach `https://nezha.local:8095` ("unreachable"; curl can) — likely its pure-Go
   resolver not doing mDNS (UNCONFIRMED); `https://192.168.1.90:8095` works.
4. **Asks from anton over the LAN** (`asks-from-anton-lan.out`, key from nezha `.env` via a 0600 temp file, shredded afterwards, never printed): noul/choice/score all
   well-formed for decide-nli, decide-2b, decide-pro and decide-max (e.g. pro latencies 3.6–4.5 s, max 6.8–8.2 s; choice → billing in all four).
5. **State after addendum** (`addendum-state.out`): enabled+active: gateway, decide-nli, decide-2b, decide-pro, decide-max. RSS idle: nli 3.2 GiB, 2b 2.2, pro 4.5, max 9.7,
   gateway 22 MiB (peaks under load per coordinator ~7.6 / ~18 GB). available RAM 53 GiB, PSI some/full avg10 0.00; no warnings in `journalctl --user -u 'llmctl*'`.
   Still outstanding: D1 (portreg onnx health path, env-file workaround) and the missing `decide serve --enable` flag are unchanged.
