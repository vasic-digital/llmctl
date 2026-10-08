# P1 RED archive (historical record)

Original results of the P1 reproduction pass (tasks T010-T013) against the second team's
**unmodified candidate** (`lib/decide_gateway.py`, `lib/onnx_server.py` with `LLMCTL_ONNX_FAKE`, bash
front end with backend host/port seams). Kept verbatim as evidence of what the candidate got wrong.

* `d01_d15.jsonl`, `d16_d32.jsonl`, `d30.jsonl`, `n01_n29.jsonl` - the raw per-id results
  (`RED` = defect reproduced through the real entry point; `NOT-REPRODUCED`; `SKIP`; `HARDENING`;
  `ERROR` = the harness itself failed because the seam it drives was removed by the rewrite).
  The register built from them is `../p1-red-register.json` (66 ids).
* `harness/` - the Python/bash reproduction suite that produced them (formerly `tests/red/`). **It
  can no longer run**: it drives seams that the rewrite removed on purpose (the Python gateway
  `lib/decide_gateway.py`, the `LLMCTL_ONNX_FAKE` runtime seam, `tests/fixtures/decide_server.py`,
  `LLMCTL_DECIDE_BACKEND_HOST/PORT`, `LLMCTL_DECIDE_API_KEY`). It is NOT part of `make test`; it stays
  here only as the historical reproduction record (Helix 11.4.124: history is kept, not deleted).

Where each id went now: `../red-to-green-map.json` (every id -> a regression guard, an existing test,
or an explicit `N/A` reason; zero unmapped). The ported guards live in `tests/test_regression_defects.sh`.
Known harness defect recorded for G-052: the N-06 check could not pass under `set -e` (it needs
`|| echo AFTER rc=$?`); the ported group in `tests/test_regression_defects.sh` uses exactly that form.
