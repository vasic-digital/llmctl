# Vision validation on nezha (CPU-only) — 2026-10-14

Recovered after a host hang killed the agent that ran it before it could report. The raw files in this directory are
unchanged copies from the validation host; this README adds only provenance.

| Item | Value (from the raw files) |
|---|---|
| Command | `llmctl vision validate --host http://127.0.0.1:8182` against a capped, isolated llama-server started by hand on nezha (evidence only: no record) |
| Model | gemma-3-4b-it Q4_K_M (+ mmproj), sha256 checked in `01_download_verify.txt` |
| Verdict | `VERDICT: PASS pass=21 fail=0 undetermined=0`, exit 0 |
| Elapsed | 1552 s on CPU only (no GPU on this host) |
| Golden-bad controls | both correctly flagged (blank image -> "NO TEXT"; wrong-content image -> "PURPLE HORSE\n17") |
| Determinism probe | repeated request byte-identical: PASS |
| Resource cap | systemd user unit, MemoryMax 20 GiB, CPU quota 400%; memory PSI 0.00 before launch |

Files: `00_resources.txt` (host resources before), `01_download_verify.txt`, `02_launch.txt`, `03_samples_during_run.txt`,
`vision_validate.txt` (the run), `validate-vision.log` (the validator's own log), `download.log`.

## What this run is and is not (added 2026-10-14, independent review finding 12; every point read from the raw files)

* **A `--host` run.** `vision_validate.txt` line 1: `llmctl vision validate --host http://127.0.0.1:8182` (llmctl `d7def51`), against a capped
  llama-server the operator launched by hand on nezha itself (`02_launch.txt`; systemd user unit, MemoryMax 20 GiB) - NOT a profile started by
  llmctl's scheduler.
* **No validation record exists on that host.** Line 2: `--host: external endpoint ... the result is evidence only, it is NOT recorded as 'vision'
  validation state`. `llmctl require-validated vision` on nezha would refuse.
* **The engine identity of the probed server was NOT established.** The validator's KEY line in `validate-vision.log` shows
  `"engine_tag": "llama-server:not-built"` and `"launch_fingerprint": "none"`: the isolated llmctl tree had no built llama-server and no env
  record, so the key describes neither the binary nor the flags of the server that answered. The model identity check passed on the served
  model id only.
* **The resource samples do not cover the run.** `03_samples_during_run.txt` spans 12:05:38 to 12:06:28; the validation started at 12:06:58
  (`vision_validate.txt` line 1) and took 1552 s. Nothing in this directory measures memory or PSI DURING the validation.
* It used the judge of that time (one determinism repeat, no signed record). The current judge asks every probe 3 times; this run would not be
  a decision-bearing run today.

Honest limits: this is one host and one run; the word PASSWORD in the logs is the on-screen label of the golden login
screenshot, not a credential; the isolated state directory on the validation host was left in place (models included).
