## Overview

`tests/test_syntax.sh` is the project's blanket static-hygiene sweep over
every shipped shell script: a `bash -n` (parse-only, no execution) syntax
check, plus a check that every shipped script declares the bash shebang
(`#!/usr/bin/env bash`) and strict mode (`set -euo pipefail`). It exists
as the cheapest, fastest possible gate against a script that would fail
merely for being malformed bash — before any of the slower, more
specific behavioral tests in this suite even run — and as the mechanism
that keeps the whole project's scripts uniformly disciplined about
failing loudly on error (`set -e`), unset variables (`set -u`), and
pipeline failures (`set -o pipefail`).

## Prerequisites

* Sources `tests/helpers.sh` for assertion helpers and
  `test_setup_env`/`test_finish`.
* Requires `bash` (for `bash -n`), `head`, and `grep`.
* Enables `shopt -s nullglob` before globbing, so a glob that matches
  nothing (e.g. if a directory were empty) silently contributes zero
  entries rather than a literal unexpanded glob string.
* Enumerates its own target list via glob expansion — no fixture files
  are read; the *entire shipped tree* is the input:
  * `${LLMCTL_ROOT}/bin/llmctl`
  * `${LLMCTL_ROOT}/lib/*.sh`
  * `${LLMCTL_ROOT}/tests/*.sh` (this means the sweep includes itself,
    and every other file in this batch and its sibling's batch)
  * `${LLMCTL_ROOT}/docs/integrations/*.sh`
  * `${LLMCTL_ROOT}/scripts/release/*.sh`

## Usage examples

```bash
bash tests/test_syntax.sh
```

Also runs as part of the full suite via `tests/run_tests.sh` or
`make test` (and is effectively the fastest test in the suite, since it
never executes any of the scripts it checks — only parses them).

## Edge cases

* Builds the `scripts` array from the five glob patterns above and
  prints the total count (`"checking N scripts with bash -n"`) before
  asserting anything, so a silently-shrinking script count (e.g. from a
  broken glob) is visible in the raw test output even before any
  assertion runs.
* For **every** script in that array: runs `bash -n "${s}"` and asserts
  the exit code is `0`, with the assertion message using the script's
  path *relative to* `LLMCTL_ROOT` (stripped via `"${s#"${LLMCTL_ROOT}/"}"`)
  so failures are reported with a short, readable path rather than the
  full absolute temp-independent path.
* For **every** script in the same array, in a second pass: asserts the
  first line of the file matches `^#!/usr/bin/env bash` exactly (via
  `head -1 | grep -q`), and asserts the file contains the literal string
  `set -euo pipefail` anywhere in its body (via `grep -q`). Both checks
  use the "success and failure paths both call `assert_eq`" idiom (
  `... && assert_eq 0 0 "..." || assert_eq 0 1 "..."`) rather than a
  helper like `assert_contains`, so either outcome is explicitly recorded
  as a pass or fail line in the test's output, never silently skipped.
* Because the `tests/*.sh` glob includes this file and every sibling
  `test_*.sh` (both in this batch and the sibling agent's batch, plus
  `helpers.sh` and `run_tests.sh`), a missing shebang or strict-mode
  declaration in *any* test file in the suite — not just library or CLI
  code — is caught here.

## Internal behaviour

1. `set -euo pipefail`; source `tests/helpers.sh`; `test_setup_env`.
2. `shopt -s nullglob`; build the `scripts` array from the five glob
   patterns listed in "Prerequisites".
3. Print the total script count.
4. First loop: for each script, run `bash -n` and assert `rc == 0`.
5. Second loop: for each script, assert its first line is exactly the
   bash shebang, and assert it contains `set -euo pipefail` somewhere in
   its body.
6. `test_finish` tears down the temp environment (created but essentially
   unused by this file's assertions, beyond the standard isolation
   convention) and exits non-zero iff any assertion failed.

## Related scripts

* Sources `tests/helpers.sh` (sibling, documented separately).
* Statically checks (via `bash -n`, not by sourcing or executing) every
  script this batch and the sibling batch document, plus `bin/llmctl`,
  every `lib/*.sh` library, every `docs/integrations/*.sh` script
  (install + normalize scripts for all 7 CLI agents), and every
  `scripts/release/*.sh` script.
* Discovered and run automatically by `tests/run_tests.sh` (and, being a
  `test_*.sh` file itself, is subject to its own shebang/strict-mode
  check when the harness — or this very test — enumerates `tests/*.sh`).

## Last verified date

2026-09-17
