## Overview

`tests/test_no_pipe_grep_q.sh` is a static guard against a false-null/false-fail trap: `echo`/`printf ... | grep -q` in a script that enables `pipefail`. `grep -q` exits at the first match, the writer then dies of SIGPIPE (rc 141) once its output exceeds one stdio chunk, and pipefail turns a match into a failed pipeline, so a secrecy check can miss a real leak. The accepted form is a here-string: `grep -q pattern <<<"$var"`. Measured with `scripts/doc_counts.sh --check no_pipe_grep_q`: **3 passing assertions** (no failures, no skips).

## Prerequisites

* `tests/helpers.sh`, `grep`; no network, no models. It scans every `tests/*.sh` that mentions `pipefail`.

## Usage

* Standalone: `bash tests/test_no_pipe_grep_q.sh`; also run by `make test`.
* Check the documented count: `bash scripts/doc_counts.sh --check no_pipe_grep_q`.

## What it proves

* No test script under `tests/` that enables pipefail pipes `echo`/`printf` into `grep -q` (comment lines are ignored).

## Control needle

Before the real scan, a planted file with the offending pattern must be reported by the scanner, and a clean here-string file must not be. A scanner that cannot see the pattern would make the real-tree zero meaningless.

## What it does NOT prove

* Scripts outside `tests/`, other pipeline forms (a non-echo writer feeding `grep -q`), or scripts that do not enable pipefail.

## Related

[test_syntax](test_syntax.md), [run_tests](run_tests.md).
