## Overview

`scripts/doc_counts.sh` measures how many assertions a test suite really
passes (lines starting `  ok:`) by running it, and with `--check` compares
the number with the `**<N> passing` claim in the matching
`docs/scripts/test_<suite>.md`. It exists because hand-typed counts went
stale (N-27: documented 55/36 vs actual 71/45); the documentation audit uses
measured numbers.

## Prerequisites

`bash`, the suites under `tests/test_*.sh`.

## Usage examples

```bash
scripts/doc_counts.sh planner catalog_json          # print measured counts
scripts/doc_counts.sh --check decide_gateway        # compare with the doc page
scripts/doc_counts.sh --all --check                 # every suite
```

Record format: `<suite> ok=N fail=N skip=N rc=R [hostdep=N] [doc=N] [status=match|stale|env-dependent|no-doc-count|skipped-suite]`.

## Edge cases

* Exit 0 all fine / 1 a documented count is stale / 2 a suite errored or is unknown.
* A suite that prints SKIP lines is `env-dependent` rather than `stale` (its
  count varies by host); a page without a `**N passing` claim is `no-doc-count`.

## Host-dependent assertions (G-084)

A suite whose assertion count legitimately varies by host (a branch taken only when llama-server is
built, a section that needs `go`) brackets those assertions with `hostdep_begin "<reason>"` ... `hostdep_end`
(`tests/helpers.sh`; they print `HOSTDEP-BEGIN: <reason>` / `HOSTDEP-END`). `ok=` then counts only the
host-independent `  ok:` lines, `hostdep=N` reports the bracketed ones, and `doc=` is compared with `ok=`
strictly: a SKIP no longer turns a mismatch into `env-dependent`. Suites without markers keep the old
rule. The env var `DOC_COUNTS_ROOT` points the script at a scratch tree (used by the N-27 test).

## Internal behaviour

Runs each suite once with `bash`, counts `^  ok:`, `^  FAIL:` and `^\s+SKIP:`
lines. It never edits documentation.

## Related scripts

`tests/helpers.sh` (the assertion output format), `tests/red/py/n_tests.py` (N-27).

## Last verified date

2026-10-07

## Skipped suites

A suite that prints `SKIP-SUITE: <reason>` (the `tests/run_tests.sh` skip
contract) ran nothing. With `--check` it is reported `status=skipped-suite` and
its page is not called stale. Proof: `tests/test_run_tests_format.sh`.

## Inconsistent suites (C2-10)

A suite that exits 0 while printing `  FAIL:` lines (an assertion that ran in a subshell, whose failure counter was lost)
or that prints `SKIP-SUITE:` after an assertion line is reported `status=inconsistent` (with or without `--check`)
and the script exits 2. `tests/run_tests.sh` applies the same rule (see its page).
