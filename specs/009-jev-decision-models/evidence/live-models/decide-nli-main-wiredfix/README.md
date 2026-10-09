# decide-nli live run, anton, CPU, wired gateway (2026-10-08)

| Field | Value |
|---|---|
| Date | 2026-10-08, started 17:46:05Z (`context.txt`) |
| Host | `anton` (kernel 7.0.0-38-generic), CPU only |
| Profile | `decide-nli`: `MoritzLaurer/deberta-v3-large-zeroshot-v2.0` @ `cf44676c`, `onnx/model.onnx` (fp32, 1,741,985,401 B, sha256 `beded3d7...`), tokenizer `onnx/spm.model`; `profile 'decide-nli' passed checksum verification` (`verify.txt`) |
| Stack | llmctl `decide` binary (sha256 `ce3e39c0...`) -> HTTPS gateway (`llmctl decide serve`, loopback test port 8195) -> `lib/onnx_server.py` (sha256 `97f48ddb...`, hash-locked venv: onnxruntime 1.30.0, sentencepiece 0.2.2, Python 3.12.14) on 127.0.0.1:8196, key file mode 0600 |
| Tree | HEAD `c5301de` plus the then-uncommitted fix to `evidence/realcheck/run_live_nli.sh` (the harness wiring: `wire_gateway_env`, `preflight_gateway`) |
| Command | `REPO=<tree> W=<work dir> OUT=<this dir> GW_PORT=8195 ENG_PORT=8196 bash specs/009-jev-decision-models/evidence/realcheck/run_live_nli.sh` |
| Harness verdict | `RESULT.txt` = `COMPLETED` (means "the harness finished", not "the model is good"; read the stats) |

## Outcome (from `golden-stats.txt`, `probes-stats.txt`, `latency.json`, `live_checks.log`)

| Item | Value |
|---|---|
| Golden requests | 173 = 132 originals + 41 option-order permutations; well-formed **132/132** |
| Probes | 23; well-formed **23/23** |
| `choice` accuracy | **0.829**, 95% CI [0.687, 0.915], n=41, chance baseline 0.235: lower bound beats baseline (`lower>baseline=True`) |
| `noul` accuracy | 0.533 CI [0.409, 0.654], n=60, majority baseline 0.667: does **not** beat it |
| `score` accuracy | 0.226 CI [0.114, 0.398], n=31, majority baseline 0.290: does **not** beat it |
| Option-order flip rate | 0.000 (0 of 41 groups) |
| Probes (n small) | noul 0.333, choice 0.667, score 0.250: none beats its baseline |
| Latency, golden | p50 1543 ms, p95 5552 ms, max 15800 ms, min 647 ms (n=173); probes p50 1468 ms |
| Determinism | `det gateway: True det engine: True`; batch argmax identical with max diff 0.0 |
| Gateway edge statuses | no key 401, wrong key 401, empty pairs 400 (runtime); no key 401, unknown model 422, 20 options 200, 21 options 422 (gateway); D-01 truncation check `hypothesis_visible: True` |
| Memory | engine VmHWM 2,515,064 kB (about 2.4 GiB) after start (`memory.txt`) |
| Calibration | insufficient (n=132, need 200): no number here is a calibrated probability |

Honest reading: the NLI encoder is shown to work end to end and to beat chance on `choice`. It is **not** shown to be good at `noul` or `score`
(both fail to beat their majority baselines); several per-family intervals are wide because n is small. One run, CPU only, single host.

## Integrity

`golden/SHA256SUMS` and `probes/SHA256SUMS` were re-verified in this tree on 2026-10-08 (`sha256sum -c`, 0 non-OK lines each).

## Superseded run

An earlier run on the same host, [`../decide-nli-main-79268f5-INVALID-gateway-miswired/`](../decide-nli-main-79268f5-INVALID-gateway-miswired/), is **invalid and
superseded**: the harness did not tell the gateway the engine address, so all 173 requests got 503. It says nothing about the model. This directory is the
run made after the harness wiring fix (`LLMCTL_DECIDE_ENDPOINT_DECIDE_NLI`, `LLMCTL_DECIDE_PORT`, and a readiness preflight).
