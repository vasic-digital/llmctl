## Overview

`tests/test_regression_defects.sh` holds the permanent regression guards for the defects
that spec 009's P1 reproduction register (`specs/009-jev-decision-models/evidence/p1-red-register.json`,
66 ids D-01..D-32 / N-01..N-29) found in the second team's candidate. Each assertion group
drives the REAL current code (the built Go `llmctl-decide` binary, the bash libraries, `bin/llmctl`,
the shipped `models/catalog.json`, the docs) and asserts that the OLD defect is gone. Each group was a
RED test against the candidate (original results archived under
`specs/009-jev-decision-models/evidence/p1-red-original/`, with the old harness that could no longer run
because it drove removed seams) and is the GREEN regression test now. Defects whose guard already exists
elsewhere (a Go unit test, the encoder runtime contract, an endpoint-inventory row) are not duplicated:
the complete id -> guard map, with zero unmapped ids, is
`specs/009-jev-decision-models/evidence/red-to-green-map.json`. Captured 2026-10-07: **43 passing
assertions, RESULT: PASS**. N-27 also proves (G-084), on a scratch tree, that host-dependent branches bracketed with
`hostdep_begin`/`hostdep_end` are excluded from the documented count: the same suite yields the same `ok=` on a host
taking either branch, a matching page is `match` on both, and a wrong claim is `stale` even where a SKIP occurs.

## Prerequisites

* `tests/helpers.sh`; `go` (builds `cmd/llmctl-decide`; without it the suite prints SKIP and exits 0).
* `python3` (catalog parsing), `git` (ignore-rule checks), `bin/llmctl` and the libs under `lib/`.
* `scripts/doc_counts.sh` (the N-27 group runs it on four suites).

## Usage examples

* Standalone: `bash tests/test_regression_defects.sh`; via `bash tests/run_tests.sh` / `make test`.
* Groups (one per defect id; the id leads every message):
  `D-03` no `--api-key` flag on `serve`; `D-11/D-29` no production file reads a retired seam variable;
  `D-13` every decide-profile catalog file is hash-pinned; `D-22` no unused `tokenizer.json`; `D-24` stale CLI text;
  `D-25` `__pycache__` ignored and untracked; `D-19b` the gateway has a service unit body; `N-05/N-16` a malformed
  numeric variable is rc 2 with its name and no traceback; `N-06` end of input at a prompt is rc 2 and the calling shell survives
  (the check prints `AFTER rc=$?` via `|| echo AFTER rc=$?`, the form the original harness lacked under `set -e`);
  `N-07` misspelt flags are rc 2; `N-08` every function the doc names exists; `N-09` prompts reach stderr on piped stdin;
  `N-25` no fixed `PORT=<literal>` in the download tests; `N-26` no SUCCESS assertion in a skipped-smoke context;
  `N-27` documented counts equal measured ones; `N-28` no CONFIRMED hash claim rests on a mirror alone.

## Edge cases

* Scans carry a control needle (the N-08 scan must see `decide_ask`; the N-26 scan must see `assert_file_contains`)
  so a blind instrument cannot report a clean zero.
* The binary runs with an isolated `LLMCTL_HOME` / `LLMCTL_ENV_FILE`: nothing touches the operator's real key or certificates.
* Negative checks name the retired variables (`LLMCTL_DECIDE_API_KEY`, `LLMCTL_ONNX_FAKE`, ...) only to prove they are gone.

## Internal behaviour

1. Builds the binary; exports an isolated installation environment.
2. Runs the Go-binary groups (D-03, N-05/N-16), the catalog/CLI/repository groups, then sources the bash libs for the front-end groups.
3. `test_finish` prints the count and sets the exit status.

## Related scripts

* `tests/test_decide.sh`, `tests/test_decide_download.sh`, `tests/test_gateway_endpoints.sh`, `tests/test_onnx_*.sh` hold the
  other guards named in the map. `scripts/doc_counts.sh` generates the counts.

## Last verified date

2026-10-07
