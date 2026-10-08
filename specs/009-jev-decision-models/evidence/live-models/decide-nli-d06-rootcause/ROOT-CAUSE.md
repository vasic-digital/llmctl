# D-06 root cause: decide-nli refused by the gateway (live 2026-10-08)

Captured 2026-10-08 on host anton, CPU only (`CUDA_VISIBLE_DEVICES=` , 4 threads), runtime on 127.0.0.1:8096,
MemAvailable 18377 MB before start; runtime stopped afterwards (pid checked via /proc cmdline, port 8096 free).

## 1. The pinned model is a binary NLI head

`config.json` of the downloaded pinned revision (MoritzLaurer/deberta-v3-large-zeroshot-v2.0 @
cf44676c28ba7312e5c5f8f8d2c22b3e0c9cdae2), sha256 `3b0a2a3fb311037ba72670d87cbd16f920581985178547a76936dfdb292e5271`
(= the catalog pin):

```
"id2label": {"0": "entailment", "1": "not_entailment"}
```

Runtime log: `{"event": "smoke", "ok": true, "detail": "labels=2", "label_source": "config:config.json"}`.

Real `/v1/score` answer (byte-exact, deterministic over two calls; also `internal/gateway/testdata/decide_nli_live_score_2026-10-08.json`):

```
{"labels": ["entailment", "not_entailment"], "label_source": "config:config.json", "scores": [[0.8834913130240478, 0.11650868697595226], [5.636262038702702e-05, 0.9999436373796129]], "truncated": [false, false], "model": "llmctl-decide-nli", "max_tokens": 512}
```

## 2. Where the 3-label assumption lived

`internal/gateway/nli.go` `resolveColumns`: required both `entailment` and `contradiction` by name, otherwise a
`labelConfigError` ("do not name both entailment and contradiction"). `Decide` then answered 502, marked the
instance degraded for 30 s, so `Router.Ready()` was false (decide-nli was the only served profile) and every
request - golden, probes, unknown model, 20/21 options - got `503 {"error_type":"not_ready"}` (golden
well_formed 0/132, probes 0/23; `live_checks.log` edges all 503). The decoder only ever uses P(entailment);
contradiction/neutral were validated but never entered the score.

## 3. Fix

A binary head whose labels are exactly {entailment, not_entailment} is served: the score is P(entailment) and
not_entailment is its exact complement - no split, nothing invented. not_entailment beside any other label is
refused. Unit RED->GREEN: `TestNLIBinaryEntailmentNotEntailmentHeadFromTheRealPinnedModel` (real fixture),
`TestNLIBinaryHeadAcceptanceIsNarrow` (8 refusal cases, incl. generic/none sources, third label).

## 4. Fixed decoder against the real runtime (temporary live Go test, removed after the run)

```
noul "the printer is on fire / Is it urgent?"                       -> 0.888170793 degraded=false
noul "deploy failed twice, database down / Is the system unhealthy?" -> 0.998982827
noul "everything green, all checks pass / Is the system unhealthy?"  -> 0.002265323
choice "invoice overdue / Which team? billing|support|sales"         -> billing 0.946026266
score  "great product / Rate it bad|ok|good"                         -> 1.997529157
```

This is the decoder only (NLIBackend.Decide over HTTP to the real runtime), NOT the full HTTPS gateway +
golden run; D-06 stays open until `run_live_nli.sh` is re-run through `llmctl decide serve`.
