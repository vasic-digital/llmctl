# nezha pinned-tree live run - decide-pro-default8s-control (2026-10-09)

- Host nezha.local (i7-1165G7, 8 threads, 62 GiB, no GPU; CPU engine `-ngl 0`). Model `spark-x2.5-4b-rizzo-flow-lora-q8_0.gguf`, sha256 verified against `models/catalog.json` pins (`../nezha-pinned-provenance-2026-10-09/pins.txt`, sha256sum -c: all OK) before use; files hardlinked from the earlier ~/llmctl-work download, not re-downloaded.
- Tree: PINNED, see `PROVENANCE.txt` (= `../nezha-pinned-provenance-2026-10-09/`): git HEAD c5301defb73a949536fe741b597d3bd089df4109 + uncommitted diff (sha256 of `git diff HEAD` recorded, full diff saved as `tree.diff`), 1082-file snapshot with a per-file sha256 manifest and an aggregate hash that was re-verified on nezha after the copy. `llmctl-decide` built locally (go1.26.0, CGO off; building on nezha was impossible: submodules/containers was not in the snapshot), sha256 2da8d639...8922. llama-server: ~/llmctl-work-live build, `0.5.0-dev (build 1, commit 1537a0a)`.
- Gateway deadline: gateway default (8 s), golden client timeout 120 s. Engine args: see `engine-cmdline.txt`. Wired as in `run_live_nli.sh` / `anton-runner/run_letter.sh` (LLMCTL_DECIDE_ENDPOINT_<PROFILE>, LLMCTL_DECIDE_PORT, readiness preflight). Runner scripts: `../nezha-pinned-provenance-2026-10-09/runner/` (outside the llmctl tree; `golden_hdr.py` wraps `run_golden.post_json` only to log status + `x-llmctl-*` headers per HTTP attempt into `hdr-*.jsonl`, no keys).
- Safety: whole run in `systemd-run --user --scope -p MemoryMax=44G -p MemorySwapMax=2G -p TasksMax=2000 timeout <N>`, one engine at a time, pre-start check (PSI full avg10 < 5, swap free >= 50%, no other engine), watchdog every 10 s (`psi-samples.txt`): abort if memory PSI full avg10 >= 10 or swap free < 30%; it never fired. VmHWM 7.11 GB; PSI max full10 0.00.
- Everything started was stopped afterwards (no llama-server / onnx_server / llmctl-decide / scope / service left; verified). Other users' services were not touched. No permanent service enabled. Nothing committed.

## Outcome
```
records=173 orig=132 perm=41 well_formed=98/132
noul   n=60 acc=0.833 CI95=[0.720,0.907] baseline=0.667 (majority) lower>baseline=True
choice n=41 acc=0.634 CI95=[0.481,0.764] baseline=0.235 (chance) lower>baseline=True
score  n=31 acc=0.387 CI95=[0.237,0.562] baseline=0.290 (majority) lower>baseline=False
-- probes
records=23 orig=23 perm=0 well_formed=18/23
noul   n=12 acc=0.917 CI95=[0.646,0.985] baseline=0.583 (majority) lower>baseline=True
choice n=6 acc=0.167 CI95=[0.030,0.564] baseline=0.500 (majority) lower>baseline=False
```
```
== nezha-pinned-decide-pro-default8s-control-2026-10-09
golden records 173 status {200: 128, 502: 45}
  non200 by (status,option_count): {(502, None): 21, (502, 2): 1, (502, 3): 5, (502, 12): 10, (502, 20): 8}
  200 latency ms: n=128 median=7605 p95=16933 max=26929
  non200 latency ms: min=27013 median=27020 max=27028
  http attempts (status,reason-header,error_type): {'(200, None, None)': 128, "(502, 'deadline_exceeded', 'backend_failed')": 171}
probes records 23 status {502: 5, 200: 18}
  non200 by (status,option_count): {(502, 3): 3, (502, None): 1, (502, 4): 1}
  200 latency ms: n=18 median=7114 p95=26817 max=26949
  non200 latency ms: min=27014 median=27016 max=27024
  http attempts (status,reason-header,error_type): {"(502, 'deadline_exceeded', 'backend_failed')": 26, '(200, None, None)': 18}
  mem: ['VmHWM:\t 7110184 kB']
  PSI max full10=0.0 some10=0.0 min swap_free%=100.0 min MemAvailable MiB=56929 samples=286 abort=False
```
Files: `golden/ probes/ smoke/` (results.json, raw/responses.jsonl, MANIFEST.json, SHA256SUMS), `*-stats.txt`, `hdr-*.jsonl` (status + x-llmctl-decide-reason per HTTP attempt), `*-first3-failure-records.json` / `*-first3-failure-attempts.json` (first 3 failing requests / HTTP attempts incl. bodies), `engine.log` (Bearer tokens redacted), `psi-samples.txt`, `SHA256SUMS` (all files in this directory).

## Provenance caveat (added 2026-10-09 after independent review)

- The "pinned" snapshot (git HEAD c5301de + `git diff HEAD` with sha256 `4019682088fa...24bb`, 1082 files) is a MID-DEVELOPMENT working tree. It equals NO single commit.
- Relative to later commits: the gateway files `letter.go`, `letter_test.go`, `resolver.go`, `resolver_test.go` and `models/catalog.json` equal those committed in `5184565`. But `internal/server/handlers.go`, `internal/server/server_test.go`, `scripts/golden/run_golden.py`, the `contracts/*` files and the hostsafety files DIFFER from `5184565`, `c00da7b` and HEAD. In particular the `handlers.go` that ran is the earlier inline 502 marker, and that `run_golden.py` retried `deadline_exceeded` 502 responses.
- The binary `llmctl-decide` (sha256 `2da8d639...8922`) was cross-compiled locally; its equivalence to the snapshot is UNCONFIRMED.
- This run is the 8 s product-default CONTROL: the gateway deadline was left at its default. It is the representative one; the other letter-logit runs (`LLMCTL_DECIDE_TIMEOUT=300`) are not. Same-host contrast: 98/132 well-formed with 45 x 502 `deadline_exceeded` here vs 131/132 at 300 s in `../nezha-pinned-decide-pro-2026-10-09`.
- Anton-vs-nezha comparisons are confounded: different host, different engine and gateway builds, different timeout settings. Do not read a score difference between the two hosts as a model difference.
