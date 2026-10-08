# `run_golden.py`

## Overview

Source: `scripts/golden/run_golden.py` (script). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
Run the golden question set through POST /v1/systemone and measure it (stdlib only).

Spec 009 SC-003 / FR-080 / plan P4. Every item is sent as its own request carrying ONE
question named "q"; the answer is checked for a well-formed typed shape, compared with the
labelled expectation, and the results are passed to stats.py (Wilson interval, baselines,
per-class accuracy, option-order flip rate, accuracy-vs-option-count, gated calibration).

Safety rules enforced here:
  * the access key is read from an environment variable NAME (default LLMCTL_API_KEY) or a
    key file; it is never accepted as a literal argument, never printed, never written;
  * logs and stdout carry item ids, status codes and latency only - never state text;
  * raw responses are saved with their request ids; a response containing the key is redacted;
  * evidence is written with tests/evidence/writer.py (hash chain) and sealed with
    tests/evidence/manifest.py (MANIFEST.json + SHA256SUMS).

Typical use (real model):
  LLMCTL_API_KEY=... python3 scripts/golden/run_golden.py       --base-url https://127.0.0.1:8095 --cacert ~/.config/llmctl/ca.pem --profile llmctl-default       --permute-groups
Smoke run: add --limit 6 --types noul,choice.   Shape check without network: --dry-run.
```

Usage and options: see the header above and run the script with `--help` where it supports it.
