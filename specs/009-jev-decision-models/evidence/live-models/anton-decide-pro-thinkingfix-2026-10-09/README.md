# anton decide-pro after the thinking fix - COMPLETE run (2026-10-09)

- Host anton, CPU engine (`-ngl 0`, `CUDA_VISIBLE_DEVICES=''`; free VRAM 4.4 GB < 8 GB). Profile `decide-pro`, GGUF `spark-x2.5-4b-rizzo-flow-lora-q8_0.gguf` (downloaded this run with `bin/llmctl models download decide-pro`, size+sha256 verified, the built-in download smoke passed).
- Tree: HEAD `c5301defb73a949536fe741b597d3bd089df4109` plus UNCOMMITTED `internal/gateway/letter.go` (`chat_template_kwargs.enable_thinking=false`) and UNCOMMITTED `internal/gateway/resolver.go` / `resolver_test.go`. `build/llmctl-decide` rebuilt, sha256 `0c16f65ac17941bc0bdebd00194bd909caa1e092acbd1c76e3490d9ab6b2a50f` (identical to the decide-2b run 2 binary).
- Commands: `go build -o build/llmctl-decide ./cmd/llmctl-decide` (bounded-run); then `anton-runner/run_letter.sh decide-pro <gguf> <this dir>` (engine 8197, gateway 8195, `LLMCTL_DECIDE_ENDPOINT_DECIDE_PRO`, `LLMCTL_DECIDE_PORT`; golden `--permute-groups`, then `--set probes`, then stats.py), under `bounded-run -m 10G -t 500 -T 5400` (scope `live-decide-pro`). One engine at a time. PSI watchdog every 10 s (abort if memory full avg10>=10 or swap free<25%) in `psi-samples.txt`; it never fired.
- Smoke first (separate pre-run, `smoke-prerun*`): 3/3 well-formed, 3/3 correct. Then the full matrix.
- Memory/PSI: before swap free 53%, PSI full 0.00. During: max full avg10 = 0.59, swap free constant 53%. Engine VmRSS 4.67 GB, **VmHWM 7.36 GB** (4.4 GB model). After: `psi-after.txt`.
- Everything we started is stopped (no 8195/8197/8199 listener, no gateway, no watchdog). Vision 8082 and the external llama-server were not touched.

## Outcome

| Set | accuracy (Wilson 95% CI) | baseline |
|---|---|---|
| golden noul n=60 | 0.867 [0.758,0.931] | 0.667 majority, lower>baseline True |
| golden choice n=41 | 0.659 [0.505,0.784] | 0.235 chance, lower>baseline True |
| golden score n=31 | 0.645 [0.469,0.789] | 0.290 majority, lower>baseline True |
| probes noul n=12 / choice n=6 / score n=4 | 0.917 / 0.500 / 0.500 | only noul beats baseline |

- Well-formed: golden **112/132** (173 records incl. 41 permutations: 143 x 200, 29 x 502, 1 x 422), probes **22/23**.
- Option-order flip rate 0.034 (1 of 29 groups). Calibration: insufficient (n<200). HTTP 200 latency (golden): n=143, median 6.6 s.
- Accuracy by option count (label is wrong, see Caveats: malformed counted as wrong): 2 -> 1.00, 3 -> 0.71, 4 -> 0.86, 5 -> 0.83, 8 -> 0.83, 12 -> 0.00 (n=5), 20 -> 0.00 (n=4).

## Failures (bodies of the first 3: `golden-first3-failure-bodies.json`, `probes-first3-failure-bodies.json`)

- 29 x HTTP 502 `backend_failed` (golden) + 1 (probes), each ~27.0 s, `attempts: 3`. By option count: 12 -> 10, 20 -> 8, 3 -> 3 (golden) + 1 (probes), 8 -> 1, no option count (noul/score) -> 7. NOT max_options refusals (those would be 422 and fast).
  Evidence for the cause: engine.log shows prompt processing at ~21.6 tokens/s on CPU (168-token prompt = 7.8 s) and `srv stop: cancel task` entries, i.e. the gateway closed the connection mid-request; 27 s = 3 attempts x ~9 s. So the gateway's per-attempt upstream deadline (~9 s, inferred from timing, the constant was NOT located in source) is shorter than the CPU engine needs for long prompts. This is a CPU-engine speed problem, not a model-quality failure. Not re-run on GPU.
- 1 x HTTP 422 `readout_failed` (letter mass below the 0.5 threshold; model-side).
- 0 x 422 caused by max_options.

Caveats: small n; the 20 malformed golden items are NOT excluded from the accuracy denominators: stats.py (`_acc_row`/`_correct`) counts a malformed answer as wrong, so the per-type accuracies above are lower bounds that include those 20 failures. The "(well-formed only)" label on the per-option-count line above is likewise wrong: those rows also count malformed answers as wrong, so the 12 -> 0.00 (n=5) and 20 -> 0.00 (n=4) rows mix wrong answers with answers that never finished; this README does not separate them (UNCONFIRMED which dominates). Nothing committed.
