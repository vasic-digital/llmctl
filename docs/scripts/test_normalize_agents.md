## Overview

`tests/test_normalize_agents.sh` proves that each of the 7 per-CLI-agent
output normalization filters shipped at
`docs/integrations/normalize_<agent>.sh` (one each for `opencode`, `pi`,
`crush`, `claude_code`, `aider`, `continue`, `cline`) turns two runs that
differ *only* in the documented non-deterministic output fields
(timestamps, temp paths, session UUIDs, elapsed durations) into
byte-identical, checked-in-expected output. It exists because
`docs/quickstart.md`'s release-gating live-challenge procedure needs a
mechanical way to compare two live-agent runs for equivalence despite
each agent stamping its own transcript with a fresh timestamp, a fresh
`/tmp/...` scratch path, a fresh session UUID, and a fresh wall-clock
duration on every invocation — without those cosmetic differences making
an otherwise-identical run look like a regression. This is the project's
own spec traceability: Phase 5 T030, `spec.md` FR-047/FR-048/SC-008,
Clarification 17.

## Prerequisites

* Sources `tests/helpers.sh` (assertion helpers, `test_setup_env` /
  `test_finish`) — same convention as every other `test_*.sh` in this
  suite.
* Requires `bash` (the normalization filters are invoked via `bash
  "${script}"`, and each is also syntax-checked with `bash -n` before use).
* Reads, for every agent name in its `for agent in opencode pi crush
  claude_code aider continue cline` loop:
  * `${LLMCTL_ROOT}/docs/integrations/normalize_<agent>.sh` — the filter
    under test.
  * `${LLMCTL_ROOT}/tests/fixtures/agent_output/<agent>/run1.txt` and
    `run2.txt` — two synthetic captured-shaped transcripts differing only
    in the documented non-deterministic field classes.
  * `${LLMCTL_ROOT}/tests/fixtures/agent_output/<agent>/expected_normalized.txt`
    — the checked-in expected output both runs must normalize to.
* No environment variables are set or read beyond what `test_setup_env`
  exports (isolated `LLMCTL_*` state/config/log directories under a fresh
  `mktemp -d`); the script does not touch scheduler/service state at all.
* The file's own header states an explicit honest boundary (Constitution
  §11.4.6): the fixtures are *synthetic*, constructed to exercise the
  documented non-deterministic field classes, not captured from a real
  live agent run against a live `llmctl` server — that capture is a
  separate, release-gating, real-GPU procedure documented in
  `docs/quickstart.md`.

## Usage examples

```bash
bash tests/test_normalize_agents.sh
```

Also runs automatically as part of the full suite:

```bash
bash tests/run_tests.sh
```

or via `make test` (see the Makefile target that invokes `tests/run_tests.sh`).

## Edge cases

* Asserts, for **every one of the 7 agents**, that the normalize script
  file exists (`assert_file_exists`) and is syntactically valid bash
  (`bash -n "${script}"`, asserted via `assert_eq 0 "${rc}"`).
* Asserts all three fixture files (`run1.txt`, `run2.txt`,
  `expected_normalized.txt`) exist for every agent before attempting to
  use them, so a missing fixture fails with a specific, actionable
  message rather than a generic later error.
* The core determinism property (spec.md FR-047/SC-008): running the
  filter over `run1.txt` and over `run2.txt` — two inputs that differ only
  in timestamp/temp-path/UUID/duration-shaped substrings — must produce
  **byte-identical** normalized output (`assert_eq "${norm1}" "${norm2}"`).
* A second, independent check that the normalized output also matches the
  project's own checked-in expectation file
  (`assert_eq "${expected}" "${norm1}"`), so a filter that happens to
  agree with itself across two runs but drifts from the documented
  expected shape is still caught.
* This loop structure means a single broken filter for any one of the 7
  agents is reported by name (the assertion messages are prefixed
  `"${agent}: ..."`), not lost in an aggregate pass/fail.

## Internal behaviour

1. `set -euo pipefail`; source `tests/helpers.sh`; call `test_setup_env`
   to get an isolated `TEST_TMP`/`LLMCTL_*` environment.
2. Compute `INTEG="${LLMCTL_ROOT}/docs/integrations"` and
   `FIXDIR="${LLMCTL_ROOT}/tests/fixtures/agent_output"`.
3. Loop over the fixed list `opencode pi crush claude_code aider continue
   cline`. For each `agent`:
   a. Build `script="${INTEG}/normalize_${agent}.sh"` and
      `fdir="${FIXDIR}/${agent}"`.
   b. Assert the script exists and is `bash -n`-clean.
   c. Assert `run1.txt`, `run2.txt`, and `expected_normalized.txt` all
      exist under `fdir`.
   d. Run `norm1="$(bash "${script}" < "${fdir}/run1.txt")"` and
      `norm2="$(bash "${script}" < "${fdir}/run2.txt")"`, and load
      `expected="$(cat "${fdir}/expected_normalized.txt")"`.
   e. Assert `norm1 == norm2` (the determinism property) and
      `expected == norm1` (matches the checked-in fixture).
4. After the loop, call `test_finish`, which tears down the temp
   environment and exits non-zero iff any assertion above failed.

## Related scripts

* Sources `tests/helpers.sh` for `test_setup_env`/`assert_*`/`test_finish`
  (documented separately, sibling script).
* Exercises the 7 filters under `docs/integrations/normalize_*.sh`
  (`normalize_opencode.sh`, `normalize_pi.sh`, `normalize_crush.sh`,
  `normalize_claude_code.sh`, `normalize_aider.sh`, `normalize_continue.sh`,
  `normalize_cline.sh`).
* Reads fixtures under `tests/fixtures/agent_output/<agent>/`.
* Sibling test `tests/test_normalize_common.sh` documents and exercises
  `docs/integrations/lib_normalize_common.sh`, the shared transform
  primitives (`norm_strip_timestamps`, `norm_strip_temp_paths`,
  `norm_strip_uuids`, `norm_strip_durations`) that the per-agent
  `normalize_<agent>.sh` scripts are expected to be built from.
* Discovered and run automatically by `tests/run_tests.sh` (glob
  `test_*.sh`); also covered by `tests/test_syntax.sh`'s `bash -n` +
  shebang + strict-mode sweep since it lives under `tests/*.sh`.

## Last verified date

2026-09-17
