# Vision validation on nezha (CPU-only) — 2026-10-14

Recovered after a host hang killed the agent that ran it before it could report. The raw files in this directory are
unchanged copies from the validation host; this README adds only provenance.

| Item | Value (from the raw files) |
|---|---|
| Command | `llmctl vision validate` against a capped, isolated llama-server on 127.0.0.1:8182 |
| Model | gemma-3-4b-it Q4_K_M (+ mmproj), sha256 checked in `01_download_verify.txt` |
| Verdict | `VERDICT: PASS pass=21 fail=0 undetermined=0`, exit 0 |
| Elapsed | 1552 s on CPU only (no GPU on this host) |
| Golden-bad controls | both correctly flagged (blank image -> "NO TEXT"; wrong-content image -> "PURPLE HORSE\n17") |
| Determinism probe | repeated request byte-identical: PASS |
| Resource cap | systemd user unit, MemoryMax 20 GiB, CPU quota 400%; memory PSI 0.00 before launch |

Files: `00_resources.txt` (host resources before), `01_download_verify.txt`, `02_launch.txt`, `03_samples_during_run.txt`,
`vision_validate.txt` (the run), `validate-vision.log` (the validator's own log), `download.log`.

Honest limits: this is one host and one run; the word PASSWORD in the logs is the on-screen label of the golden login
screenshot, not a credential; the isolated state directory on the validation host was left in place (models included).
