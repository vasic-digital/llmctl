## Overview

`tests/test_hardware_probe.sh` tests `lib/hardware.sh` — the module that
dynamically probes CPU/SIMD capabilities, RAM, GPUs, and storage type on
whichever host llmctl is running on. It verifies both the real, live probe
(which naturally works on any Linux/macOS host, since that is the probe's
entire job) and the `LLMCTL_FAKE_HW` fixture-override mechanism that lets
the rest of the test suite (and CI) exercise hardware-dependent code paths
deterministically without depending on the actual test-runner machine's
real hardware. It also verifies the override mechanism's error handling:
a missing or malformed fixture file must fail loudly, for the real,
specific, correct reason — never silently or generically.

## Prerequisites

* `tests/helpers.sh` (sourced for `test_setup_env`/`test_finish`/assertion
  helpers).
* `lib/common.sh`, `lib/os_detect.sh`, `lib/hardware.sh` — all three
  sourced directly so the test can call `hw_probe_json`/`hw_probe_human`
  as in-process functions.
* `lib/common.sh`'s `json_stdin` helper (a small python3-backed function
  documented in that library's own companion doc) — used repeatedly here
  to pull specific fields out of captured JSON probe output.
* `python3` (transitively, via `json_stdin`).
* `tests/fixtures/hw-baseline.json` — the fixture read via `LLMCTL_FAKE_HW`
  for the override-path assertions (the same fixture
  `tests/test_cli.sh`/`tests/test_determinism.sh` use).
* `LLMCTL_FAKE_HW` — the environment variable this test both exercises
  (pointing at a real, valid fixture) and deliberately breaks (pointing at
  a nonexistent path, and at a syntactically invalid JSON file written to
  `${TEST_TMP}/broken.json`) to test the probe's error-reporting behavior.
* Runs on whichever real host executes the test — the "real probe" block
  (item 1 below) is not itself parameterized by any fixture and reflects
  the actual test-runner machine's CPU/RAM/storage.

## Usage examples

* Standalone: `bash tests/test_hardware_probe.sh`
* Via the harness: `bash tests/run_tests.sh`
* Via `make test` / `make validate`.
* The real function-level invocation shape this test exercises (after
  sourcing `lib/common.sh`/`lib/os_detect.sh`/`lib/hardware.sh`):
  ```bash
  hw_probe_json                                          # real probe
  hw_probe_human                                         # real probe, human-readable
  LLMCTL_FAKE_HW=tests/fixtures/hw-baseline.json hw_probe_json  # fixture override
  ```

## Edge cases

* **Real probe on the actual host produces valid JSON with the exact
  required top-level keys**: asserts exit code 0 and that the sorted set
  of top-level keys is exactly `arch cpu gpu_total_vram_mb gpus memory os
  storage` (via `json_stdin '" ".join(sorted(d.keys()))'`) — an
  unexpected extra or missing top-level key would fail this immediately.
* **Real probe reports a sane CPU core count**: asserts `cpu.cores` is a
  non-negative integer string matching `^[0-9]+$` and `>= 1` (a probe
  reporting 0 cores, a negative number, or a non-numeric value would be
  nonsensical and is treated as a probe defect).
* **Real probe reports total memory**: asserts `memory.total_mb` is a
  numeric string `> 0`.
* **Human-rendering mode produces the expected labeled lines**: asserts
  `hw_probe_human`'s output contains the literal substrings `CPU:`, `RAM:`,
  and `Storage:` — the three section headers a human operator running
  `llmctl hw` (without `--json`) expects to see.
* **Fixture override returns the fixture's content verbatim (not blended
  with the real host's hardware)**: with `LLMCTL_FAKE_HW` pointing at
  `tests/fixtures/hw-baseline.json`, asserts `cpu.model` equals exactly
  `"AMD Ryzen 7 2700X Eight-Core Processor"` and `gpu_total_vram_mb`
  equals exactly `12288` — both fixture-authored values almost certainly
  distinct from the real test-runner host's actual hardware, so a passing
  assertion here proves the override path, not the real-probe path, was
  taken.
* **A missing/unreadable `LLMCTL_FAKE_HW` file fails loudly, for the
  real, specific reason**: sets `LLMCTL_FAKE_HW="/nonexistent.json"` and
  captures **only stderr** (`2>&1 1>/dev/null`, run inside a subshell so
  the probe's internal `die()` call's exit code is contained rather than
  aborting the test file itself), asserting exit code 1 **and** that the
  captured stderr contains the exact substring `"LLMCTL_FAKE_HW is set but
  unreadable"` — the in-file comment is explicit about why this matters
  (Constitution §11.4/§11.4.1): an exit-code-only check would pass even if
  the probe crashed for some unrelated reason having nothing to do with
  the missing-file scenario the test claims to exercise; capturing and
  asserting on the real error text is what proves the failure is the
  *right* failure.
* **A syntactically invalid `LLMCTL_FAKE_HW` file likewise fails loudly,
  for the real, specific reason**: writes a deliberately unterminated
  JSON object (`{"not": "closed"`) to `${TEST_TMP}/broken.json`, points
  `LLMCTL_FAKE_HW` at it, and asserts exit code 1 and the exact substring
  `"LLMCTL_FAKE_HW fixture is not valid JSON"` in stderr — a distinct
  error path and message from the missing-file case above.

## Internal behaviour

1. Sources `tests/helpers.sh`, calls `test_setup_env`; sources
   `lib/common.sh`, `lib/os_detect.sh`, `lib/hardware.sh`.
2. **Real-probe block**: calls `hw_probe_json` (against the actual host,
   no fixture override active), asserts exit 0; pipes the captured JSON
   through `json_stdin` twice more to extract and validate the sorted
   top-level key set, the `cpu.cores` value, and the `memory.total_mb`
   value.
3. **Human-rendering block**: calls `hw_probe_human` and asserts the
   `CPU:`/`RAM:`/`Storage:` substrings are present.
4. **Fixture-override block**: calls `hw_probe_json` with
   `LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"` set
   inline for that one invocation, extracts `cpu.model` and
   `gpu_total_vram_mb` via `json_stdin`, asserts both equal the fixture's
   known authored values.
5. **Missing-fixture-file error block**: runs `( LLMCTL_FAKE_HW=/nonexistent.json
   hw_probe_json ) 2>&1 1>/dev/null` inside a subshell (redirecting stdout
   to `/dev/null` and capturing only stderr into `errout`), tolerating the
   real non-zero exit via `|| rc=$?`; asserts `rc == 1` and the stated
   error substring is present in `errout`.
6. **Malformed-fixture-JSON error block**: writes an unterminated JSON
   object to `${TEST_TMP}/broken.json`, repeats the same subshell/capture
   pattern with `LLMCTL_FAKE_HW` pointing at it, and asserts `rc == 1` and
   the distinct "not valid JSON" error substring.
7. Calls `test_finish`.

## Related scripts

* Exercises `lib/hardware.sh`'s `hw_probe_json`/`hw_probe_human` functions
  directly (sourced).
* Sources `lib/common.sh` (for its `json_stdin` helper, already documented
  separately) and `lib/os_detect.sh` (a dependency of `lib/hardware.sh`,
  also documented separately) as prerequisites.
* Reads `tests/fixtures/hw-baseline.json` via `LLMCTL_FAKE_HW`.
* Sources `tests/helpers.sh` for `test_setup_env`/`test_finish`/assertion
  helpers.
* Discovered and run by `tests/run_tests.sh`.
* Sibling test `tests/test_cli.sh` (documented in this same set) exercises
  the same `hw`/`hw --json` behavior indirectly, through the real
  `bin/llmctl` CLI dispatcher rather than by sourcing `lib/hardware.sh`
  directly.
* Sibling test `tests/test_determinism.sh` (documented in this same set)
  proves `hw --json`'s (and `plan --json`'s) byte-identical repeatability
  across repeated CLI invocations against the same fixture, a property
  this test does not itself check.

## Last verified date

2026-09-17
