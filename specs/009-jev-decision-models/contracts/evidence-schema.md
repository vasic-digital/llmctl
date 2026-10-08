# Evidence schema

**Status**: draft contract (FR-042, FR-043, SC-003, SC-005, SC-007, SC-013).

Every check that supports a claim appends **one JSON object per line** (JSONL) to `docs/qa/009-jev-decision-models/<run-id>/evidence.jsonl`; the run directory also contains the raw output files and `SHA256SUMS` over all of them. Summaries, pass counts and documentation numbers are **generated** from the JSONL by a script – never typed.

## Record

```json
{
  "id": "EV-<run>-<seq>",
  "ts": "2026-10-07T13:21:00Z",
  "requirement": ["FR-066", "SC-013"],
  "command": "curl --cacert … https://127.0.0.1:8095/v1/models",
  "cwd": "/home/…/llmctl",
  "env_digest": "sha256:<hash of the sorted names of variables that influenced the run; values excluded>",
  "exit_code": 0,
  "stdout_sha256": "…", "stderr_sha256": "…",
  "artifact_paths": ["raw/EV-…-stdout.txt"],
  "duration_ms": 41,
  "class": "real-model | real-component | stand-in | not-exercised",
  "vantage": "host | podman-bridge | slirp4netns | second-machine | none",
  "client": "curl | python-urllib | python-requests | node-fetch | go-nethttp | chromium | llmctl-cli | typesafe-sdk-py | typesafe-sdk-js | agent:<name>",
  "result": "pass | fail | not-exercised",
  "reason": "required when result=not-exercised or fail"
}
```

## Rules

1. `result=pass` requires captured output; metadata-only, config-only and absence-of-error passes are not accepted. A test that **skips** its heavy step records `not-exercised` with the reason – never `pass`.
2. `class=stand-in` (stub backends, fake logits) is allowed only for the unit tier and is **excluded** from every summary that claims real behaviour (profile verification, accuracy, agent calls, matrix cells).
3. The matrix runner emits one record per (case_id from `endpoint-inventory.tsv`) × client × vantage; the completeness check fails if any (case, client) cell is missing – a missing cell is a failure, not a skip.
4. The leak scanner (SC-005) records its **control needle** result: a planted decoy key must be found by the same scan path, otherwise the scan is blind and the run fails.
5. No record, log, or artefact contains the access key, the internal backend key, the CA/leaf private key, or state text from the golden sets beyond what the golden file itself contains (golden files are public fixtures).
6. Agent passes (SC-007) carry two records: the agent's own transcript (class `real-component`) and the gateway's independent request-log entry that matches it (id, time window, path, status). The second is the proof; the first alone is not.
7. `SHA256SUMS` is verified at the end of a run and again before release packaging; a mismatch fails the release.
8. Optional hash chain: each record includes `prev_sha256` (hash of the previous line) so truncation or reordering is detectable (Helix §11.4.268 stance, applied locally).
