# T092 - encoder bring-your-own example (FR-008 / idea 3-I12)

Run 2026-10-09 on host `anton` in a scratch environment (nothing shipped changed, live services untouched).

## What was demonstrated (all with captured output in this directory)

Encoder: `cross-encoder/nli-deberta-v3-xsmall` (Apache-2.0, rev `a150876415327c80daeff35ca6f68f5ed8cf5c24`), a USER-ONLY
profile `byo-nli-xsmall` that is NOT in `models/catalog.json`, added through a copy of the catalog selected with `LLMCTL_CATALOG`.

| Step | Result | File |
|---|---|---|
| copy catalog, add profile (port 18191 in `profiles.*.port` AND `ports`), `llmctl models list` | profile listed (`byo-nli-xsmall 18191 onnx 1 below-minimum decide`) | `overlay-profile-used.json` |
| `tests/test_catalog_json.sh` logic run against the overlay | every structural/port/sha check PASSES; ONLY the repo-maintenance gate "huggingface.co pin evidence cross-check" fails (`no re-verification evidence` for the 4 files) - that gate is for shipped profiles, not a user requirement | (inline, see below) |
| `llmctl models download byo-nli-xsmall` | 4 files, sha256 `verified:` each, structural validation passed, built-in onnx smoke (entail/contradict/batch) passed, rc 0 | `01-download.txt` |
| `llmctl models verify byo-nli-xsmall` | `passed checksum verification` | `02-verify-and-systemd-start-refusal.txt` |
| `llmctl start byo-nli-xsmall` with scratch dirs | **refused by systemd** (see Finding 1) | `02-verify-and-systemd-start-refusal.txt` |
| engine started with the exact argv `llmctl` generates (`LLMCTL_DRY_RUN=1 llmctl start` writes the env file) under `bounded-run -m 6G`, venv = symlink to the existing hash-locked ONNX venv | `/readyz` ready, `model_loaded`, `smoke ok labels=3`, listening 127.0.0.1:18191 | `05-engine.log` |
| `llmctl decide smoke --url http://127.0.0.1:18191 --protocol nli-onnx --key-file <scratch> --options 3` | rc 0, valid typed answer `billing` (confidence 0.84) | `03-engine-smoke.json` |
| `llmctl decide serve --foreground --bind 127.0.0.1 --port 18195` (scratch certs/key/env file) then `llmctl decide models` + `llmctl decide ask --profile byo-nli-xsmall --type choice` | gateway listed the profile (`protocol nli-onnx`, status ready); ask rc 0, choice `billing`, probabilities 0.44/0.36/0.20, `calibrated:false`, `maturity:experimental` | `04-gateway-ask.txt`, `06-gateway-startup.log` |
| teardown | gateway + engine terminated; no listener on 18100-18199, live 8095/8096/8104/8082 untouched, no `byo` systemd unit or services file in the real state dir | (see report) |

Keys are never printed: the engine key file, the gateway access key (scratch `LLMCTL_ENV_FILE`) and certificates live only under
`~/.cache/llmctl-byo-demo/`; long tokens in the captured logs are redacted.

## Findings

1. `llmctl start/enable` on Linux cannot be isolated with scratch `LLMCTL_STATE_DIR`: the systemd user unit template
   (`~/.config/systemd/user/llmctl-onnx@.service`) hard-codes `EnvironmentFile=<real state>/services/%i.env`, so the unit started
   against a profile whose env file lives in the scratch dir, failed (`Result: resources`) and auto-restart-looped until stopped
   (stopped by hand; the instance never existed in the real services dir). This is the existing design (units are generated for one
   state dir), not a defect in the overlay seam. For a real BYO profile on a normal host (default dirs) `llmctl start <profile>` works the usual way.
   The demonstration therefore started the engine with the argv llmctl itself generated.
2. The overlay seam itself (`LLMCTL_CATALOG`) needed no code change: USER-ONLY profile validation, the tier gate, port registry,
   download/verify, planner (`reserved 921 MiB RAM + 0 MiB VRAM`) and gateway discovery all accepted it. A copied profile MUST get a unique port
   in both `profiles.<name>.port` and the top-level `ports` map (the fragment cloned from `decide-nli` collided on 8096).
3. The built-in download smoke binds an ephemeral port (it used 34581) unless `LLMCTL_SMOKE_PORT` is set.

## Verified vs UNCONFIRMED

- VERIFIED (captured here): overlay accepted; verified download of 286.7 MB; engine loads the real ONNX model and answers; gateway serves it; typed choice answer returned end to end.
- NOT CLAIMED: decision accuracy. The ask above is one example, the gateway reports `maturity: experimental`, `calibrated: false`, and
  the profile's `maturity`/`memory` blocks are `unmeasured`. Measured RAM/VRAM and accuracy are UNCONFIRMED (G-137).
- UNCONFIRMED: behaviour under systemd with default dirs for this specific profile (not run, to avoid touching the real user services).
- No test was added: the seam needed no code change and `tests/test_onnx_download.sh` already covers the onnx download path with stubs; a
  real-model test would need a 287 MB network download.
