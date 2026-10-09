# nezha pinned-tree live run - decide-nli (2026-10-09)

- Host nezha.local (i7-1165G7, 8 threads, 62 GiB, no GPU; CPU engine `-ngl 0`). Model `onnx/model.onnx (DeBERTa-v3-large NLI)`, sha256 verified against `models/catalog.json` pins (`../nezha-pinned-provenance-2026-10-09/pins.txt`, sha256sum -c: all OK) before use; files hardlinked from the earlier ~/llmctl-work download, not re-downloaded.
- Tree: PINNED, see `PROVENANCE.txt` (= `../nezha-pinned-provenance-2026-10-09/`): git HEAD c5301defb73a949536fe741b597d3bd089df4109 + uncommitted diff (sha256 of `git diff HEAD` recorded, full diff saved as `tree.diff`), 1082-file snapshot with a per-file sha256 manifest and an aggregate hash that was re-verified on nezha after the copy. `llmctl-decide` built locally (go1.26.0, CGO off; building on nezha was impossible: submodules/containers was not in the snapshot), sha256 2da8d639...8922. llama-server: ~/llmctl-work-live build, `0.5.0-dev (build 1, commit 1537a0a)`.
- Gateway deadline: gateway default (run_live_nli.sh path). Engine args: see `engine-cmdline.txt`. Wired as in `run_live_nli.sh` / `anton-runner/run_letter.sh` (LLMCTL_DECIDE_ENDPOINT_<PROFILE>, LLMCTL_DECIDE_PORT, readiness preflight). Runner scripts: `../nezha-pinned-provenance-2026-10-09/runner/` (outside the llmctl tree; `golden_hdr.py` wraps `run_golden.post_json` only to log status + `x-llmctl-*` headers per HTTP attempt into `hdr-*.jsonl`, no keys).
- Safety: whole run in `systemd-run --user --scope -p MemoryMax=44G -p MemorySwapMax=2G -p TasksMax=2000 timeout <N>`, one engine at a time, pre-start check (PSI full avg10 < 5, swap free >= 50%, no other engine), watchdog every 10 s (`psi-samples.txt`): abort if memory PSI full avg10 >= 10 or swap free < 30%; it never fired. engine VmHWM 3.49 GB; PSI max full10 0.00.
- Everything started was stopped afterwards (no llama-server / onnx_server / llmctl-decide / scope / service left; verified). Other users' services were not touched. No permanent service enabled. Nothing committed.

## Outcome
```
records=173 orig=132 perm=41 well_formed=132/132
noul   n=60 acc=0.533 CI95=[0.409,0.654] baseline=0.667 (majority) lower>baseline=False
choice n=41 acc=0.829 CI95=[0.687,0.915] baseline=0.235 (chance) lower>baseline=True
score  n=31 acc=0.226 CI95=[0.114,0.398] baseline=0.290 (majority) lower>baseline=False
-- probes
records=23 orig=23 perm=0 well_formed=23/23
noul   n=12 acc=0.333 CI95=[0.138,0.609] baseline=0.583 (majority) lower>baseline=False
choice n=6 acc=0.667 CI95=[0.300,0.903] baseline=0.500 (majority) lower>baseline=False
```
```
== nezha-pinned-decide-nli-2026-10-09
golden records 173 status {200: 173}
  non200 by (status,option_count): {}
  200 latency ms: n=173 median=433 p95=1585 max=2837
probes records 23 status {200: 23}
  non200 by (status,option_count): {}
  200 latency ms: n=23 median=406 p95=699 max=841
  mem: []
  PSI max full10=0.0 some10=0.0 min swap_free%=100.0 min MemAvailable MiB=56351 samples=17 abort=False
```
Files: `golden/ probes/ smoke/` (results.json, raw/responses.jsonl, MANIFEST.json, SHA256SUMS), `*-stats.txt`, `hdr-*.jsonl` (status + x-llmctl-decide-reason per HTTP attempt), `*-first3-failure-records.json` / `*-first3-failure-attempts.json` (first 3 failing requests / HTTP attempts incl. bodies), `engine.log` (Bearer tokens redacted), `psi-samples.txt`, `SHA256SUMS` (all files in this directory).

## Provenance caveat (added 2026-10-09 after independent review)

- The "pinned" snapshot (git HEAD c5301de + `git diff HEAD` with sha256 `4019682088fa...24bb`, 1082 files) is a MID-DEVELOPMENT working tree. It equals NO single commit.
- Relative to later commits: the gateway files `letter.go`, `letter_test.go`, `resolver.go`, `resolver_test.go` and `models/catalog.json` equal those committed in `5184565`. But `internal/server/handlers.go`, `internal/server/server_test.go`, `scripts/golden/run_golden.py`, the `contracts/*` files and the hostsafety files DIFFER from `5184565`, `c00da7b` and HEAD. In particular the `handlers.go` that ran is the earlier inline 502 marker, and that `run_golden.py` retried `deadline_exceeded` 502 responses.
- The binary `llmctl-decide` (sha256 `2da8d639...8922`) was cross-compiled locally; its equivalence to the snapshot is UNCONFIRMED.
- This NLI run used the gateway default deadline (no `LLMCTL_DECIDE_TIMEOUT` override) and the NLI path, not the letter-logit path; the 300 s caveat of the letter-logit runs does not apply to it.
- Anton-vs-nezha comparisons are confounded: different host, different engine and gateway builds, different timeout settings. Do not read a score difference between the two hosts as a model difference.
