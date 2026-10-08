## Overview

`tests/test_task_coverage.sh` (T121) proves that every requirement (`FR-*`, `SC-*`) in `spec.md` is cited by a task in `tasks.md`, and that every `ADOPT` / `ADOPT-AFTER-VERIFICATION` idea in `research/ideas-closure.md` is cited too. The instruments are `tests/py/task_coverage.py` (`fr-sc`) and `tests/coverage_rows.sh`. Measured with `scripts/doc_counts.sh --check task_coverage`: **23 passing assertions** (no failures, no skips).

## Prerequisites

* `python3`; `tests/helpers.sh`; both instruments must exist (asserted). Fixture trees are generated in a temp dir; the final section reads `specs/009-jev-decision-models`.

## Usage

* Standalone: `bash tests/test_task_coverage.sh`; also run by `make test`.
* Check the documented count: `bash scripts/doc_counts.sh --check task_coverage`.

## What it proves

* Golden-good: 0 gaps, and the instrument reports that it examined 4 definitions (FR/SC) and 3 ADOPT ids (`ADOPT-LATER` is excluded, a split `ADOPT / ADOPT-LATER` row is kept).
* Golden-bad fixtures each name exactly the planted gap: an uncited `FR-010`, `SC-001`, `FR-087` behind a range that stops early (`FR-066..068`), an uncited `1-I10`, and a newly added uncited `9-I99` row. No false gaps are reported.
* Prefix collisions do not credit a citation: `FR-001` does not cover `FR-010`, `1-I100` does not cover `1-I10`.
* An empty tree, and a spec with no definitions, are BLIND (exit 2), never clean.
* Real tree: both instruments saw definitions, and the real spec has no uncited FR/SC and no uncited ADOPT idea (a real gap would be printed and fail the suite).

## Mutations / control needles

The planted-gap fixtures are the control needles: an instrument that cannot see a planted gap would make the real-tree zero meaningless. The "examined defined=N cited=N" assertions prove the instrument actually read the definitions before its zero is trusted.

## What it does NOT prove

* That a task which cites a requirement actually implements or tests it; only that the citation exists.
* Coverage of specs other than `009-jev-decision-models`.

## Related

[test_docs_audit](test_docs_audit.md), [spec_closure_audit](spec_closure_audit.md).
