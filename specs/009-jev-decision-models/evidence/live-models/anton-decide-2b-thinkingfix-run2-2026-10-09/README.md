# anton decide-2b after the thinking fix - run 2 (COMPLETE run, 2026-10-09)

- Host anton (CPU engine, `-ngl 0`, `CUDA_VISIBLE_DEVICES=''`; free VRAM was 4.5 GB, below the 5 GB threshold). Profile `decide-2b` (letter-logit), GGUF `jevk5-2b-v0.2-Q8_0.gguf`.
- Tree: HEAD `c5301defb73a949536fe741b597d3bd089df4109` plus UNCOMMITTED `internal/gateway/letter.go` (`chat_template_kwargs.enable_thinking=false`),
  UNCOMMITTED `internal/gateway/resolver.go` (partly index-staged, +19/-3) and modified `resolver_test.go`. Binary `build/llmctl-decide` rebuilt this run,
  sha256 `0c16f65ac17941bc0bdebd00194bd909caa1e092acbd1c76e3490d9ab6b2a50f` (run 1 binary was `369698ad...`: a different build).
- Commands: `go build -o build/llmctl-decide ./cmd/llmctl-decide` under bounded-run; then
  `anton-runner/run_letter.sh decide-2b <gguf> <this dir>` (engine port 8197, gateway 8195, `LLMCTL_DECIDE_ENDPOINT_DECIDE_2B`, `LLMCTL_DECIDE_PORT`;
  golden `--permute-groups`, then `--set probes`, then stats.py).
  The whole script ran under `bounded-run -m 10G -t 500 -T 5400` (scope dec2b-run2); one llama-server at a time; a PSI watchdog (stop scope if memory full avg10>=10) sampled every 10 s into `psi-samples.txt`.
- Smoke first: 3 choice questions, 3/3 well-formed (`smoke-prerun*`), then the full matrix.
- Memory/PSI: before: swap free 4391/8191 MB, PSI full avg10 0.00 (`psi-before.txt`). During: max full avg10 = 0.84, watchdog never fired. Engine VmRSS 2.27 GB, VmHWM 7.8 GB. After: `psi-after.txt`.
- Everything we started is stopped (no 8195/8197 listener, no gateway, no watchdog). Vision service on 8082 and the external llama-server were not touched.

## Outcome

| Set | accuracy (Wilson 95% CI) | baseline |
|---|---|---|
| golden noul n=60 | 0.883 [0.778,0.942] | 0.667 majority, lower>baseline True |
| golden choice n=41 | 0.732 [0.581,0.843] | 0.235 chance, lower>baseline True |
| golden score n=31 | 0.290 [0.161,0.466] | 0.290 majority, lower>baseline False |
| probes noul n=12 / choice n=6 / score n=4 | 0.750 / 0.500 / 0.500 | none beats baseline |

- Well-formed: golden **128/132** (173 records incl. 41 permutations), probes **23/23**. Run 1: 58/132; before the fix: 0/132.
- Option-order flip rate 0.081 (3 of 37 groups). Calibration: insufficient (n<200). HTTP 200 latency (golden): n=165, median 2.9 s, max 4.5 s.
- The kwarg took effect on this engine build (letters are now present in the first-token alternatives); no direct top_logprobs capture was needed because smoke passed.

## Failures

- 8 x HTTP 422 (C-038..C-041 and their permutations), each 1-2 ms, all `option_count=20`; catalog `decide-2b` has `max_options: 16` (commit 9367d90).
  Consistent with gateway-side rejection for exceeding max_options. The response BODY was not captured, so the reason code is UNCONFIRMED. These are not model errors.
- 0 x HTTP 502 in 196 requests. Run-1 502s took ~25-30 s each (87 of 88 in the 25-30 s bucket, near constant): consistent with an upstream/engine timeout while the host was thrashing,
  but ROOT CAUSE UNCONFIRMED. Not excluded: the run-1 binary differed from this one (resolver.go endpoint wiring), or an engine stall. Their absence here under no memory pressure is supporting evidence, not proof.

Caveats: score accuracy does not beat its majority baseline; small n; the 4 malformed golden items are NOT excluded from accuracy denominators: stats.py (`_acc_row`/`_correct`) counts a malformed answer as wrong (the 4 are the 20-option items the gateway refused for max_options 16; this run predates the G-160 refused-vs-malformed distinction). Nothing committed.
