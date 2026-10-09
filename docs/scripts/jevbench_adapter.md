## Overview

`scripts/bench/jevbench_adapter.py` is a thin, stdlib-only wrapper that runs the upstream
JevBench harness against an llmctl decision gateway and post-processes its results into
`RUN/summary.json` (spec 009 T065). It does not reimplement the harness. Every run is
labelled `tier=public-tier`, `contamination=possible`, `official_score=false`: a number from
this tool is never a leaderboard score. See `docs/golden-set.md` ("JevBench public tier").

## Prerequisites

* `python3` (standard library only) and `scripts/golden/stats.py` (Wilson interval, baseline).
* A checkout of the upstream harness (`fstandhartinger/jevbench`) **outside** this repository.
* For a real run: a reachable gateway and an API key in the environment variable named by
  `--key-env` (default `LLMCTL_API_KEY`); the key is never an argument and never written.

## Usage examples

```sh
# provenance only: checks the commit and dataset hashes, runs nothing, needs no key
python3 -I scripts/bench/jevbench_adapter.py --public-tier --jevbench-dir ~/jevbench \
  --expect-commit <40-hex> --run-dir /tmp/jb-run --verify-only
# real run
LLMCTL_API_KEY=... python3 -I scripts/bench/jevbench_adapter.py --public-tier \
  --jevbench-dir ~/jevbench --expect-commit <40-hex> --run-dir /tmp/jb-run \
  --endpoint https://127.0.0.1:8095 --model decide-nli --ssl-cert-file CA.pem
```

Options: `--splits`, `--allow-licence` (repeatable, default MIT), `--cap-usd`, `--delay-s`,
`--limit`, `--evidence-dir`, `--profile`, `--harness-cmd` (tests only).
Exit: 0 ok, 1 harness failed, 2 usage / provenance refusal, 3 run incomplete (summary still written).

## Edge cases

* `--public-tier` is mandatory; without it the tool refuses.
* Fail-closed provenance: the checkout must be at `--expect-commit` with a clean tree and each
  split must hash (sha256) to the upstream `datasets/manifest.json`, otherwise exit 2 and nothing runs.
* `--run-dir` must be fresh and outside the checkout; `results.jsonl` is created exclusively.
* Refusals (422, 502, 503, 529, timeouts) are tallied separately from wrong and malformed answers.
* Calibration only with at least 200 licence-clean answered items; below that the summary says
  `insufficient: N<200` and no CSV is written.
* `--evidence-dir` writes ids and aggregates only, never item text or raw responses.

## Internal behaviour

`check_commit` / `check_datasets` verify provenance, `build_harness_cmd` launches the harness
with `PYTHONPATH` removed (and `SSL_CERT_FILE` set for the child only), `summarize` classifies
each record, `write_evidence` emits the committed aggregates.

## Related scripts

`scripts/golden/run_golden.py`, `scripts/golden/stats.py`, `docs/golden-set.md`.

## Last verified date

2026-10-09
