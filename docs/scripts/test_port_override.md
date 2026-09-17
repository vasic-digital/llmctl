## Overview

`tests/test_port_override.sh` proves the `LLMCTL_PORT_<PROFILE>`
per-profile port override mechanism works correctly against the real
catalog code, end-to-end. It exists because `models/catalog.json`'s
`"port"` field is a fixed, host-independent value with no override
anywhere in the pre-fix codebase (the script's header notes a grep for
`PORT_OVERRIDE`/`LLMCTL_PORT` found nothing before this feature landed),
so a host whose catalog port for some profile collides with an unrelated
already-running process (the concrete case cited: port 8080 for profile
`fast` taken by a sibling project's process) could never start that
profile as a persistent service without editing the shared, portable
catalog file or patching code. The override is exercised at *both* places
a profile's port is actually resolved — `catalog_port()` (the
display-only getter used by `models list`) and `catalog_plan_json()` (the
functional path every real launch — `start`/`enable`/`switch`/`auto` —
resolves its bind port through, via `sched_build_launch`'s `--port`) —
because a fix touching only the display getter would look complete while
never changing what the scheduler actually binds to.

## Prerequisites

* Sources `tests/helpers.sh` for assertion helpers and
  `test_setup_env`/`test_finish`.
* Sources, directly, `lib/common.sh`, `lib/os_detect.sh`,
  `lib/hardware.sh`, `lib/catalog.sh` — the real library code under test.
* Uses `LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"`
  to drive `catalog_plan_json` off a deterministic fixture rather than
  the real host, for the plan-level assertions.
* Uses the override variable family itself as the object under test:
  `LLMCTL_PORT_FAST`, `LLMCTL_PORT_WS_DENSE_32B` (and, generically,
  `LLMCTL_PORT_<PROFILE>` derived by
  `catalog_port_override_env_name()` — hyphens in a profile name become
  underscores and the result is upper-cased).
* Invokes the real `bin/llmctl` CLI entrypoint as a subprocess in its
  final section (`LLMCTL="${LLMCTL_ROOT}/bin/llmctl"`), so `bash` and the
  full `bin/llmctl`/`lib/*.sh` stack must be runnable.
* Writes and removes one scratch file directly under `/tmp` (not under
  the test's isolated `TEST_TMP`):
  `/tmp/llmctl_port_override_test_stderr.$$` — used to capture stderr
  from a failing invalid-override invocation, and explicitly `rm -f`'d at
  the end of that section.
* Does not require `LLMCTL_DRY_RUN` — all assertions in this file are
  about the planner/display layer, not the scheduler's actual
  process-management side effects.

## Usage examples

```bash
bash tests/test_port_override.sh
```

Also runs as part of the full suite via `tests/run_tests.sh` or
`make test`.

Ad hoc, reproducing what this test proves:

```bash
LLMCTL_PORT_FAST=18080 ./bin/llmctl models list
LLMCTL_PORT_FAST=18080 ./bin/llmctl plan --json
```

## Edge cases

* **Name-derivation helper**: asserts
  `catalog_port_override_env_name fast` → `LLMCTL_PORT_FAST`, and asserts
  two hyphenated profile names (`ws-dense-32b`, `colibri-glm`) correctly
  become `LLMCTL_PORT_WS_DENSE_32B` / `LLMCTL_PORT_COLIBRI_GLM`
  (hyphens → underscores, upper-cased).
* **No override**: `catalog_port fast` with no override set still returns
  the catalog's fixed `8080`.
* **Scoped override**: `LLMCTL_PORT_FAST=18080 catalog_port fast` returns
  `18080`, while `LLMCTL_PORT_FAST=18080 catalog_port small` (an
  unrelated profile) is unaffected and still returns `8085` — proving no
  cross-profile leakage.
* **Override does not bypass profile validation**: an override set for
  an unknown profile name (`LLMCTL_PORT_FAST=18080 catalog_port
  does-not-exist`) still dies with exit code `1` and the exact same
  `"unknown profile: does-not-exist"` message the no-override path
  produces — proving the override cannot be used to silently smuggle a
  bogus profile name through.
* **Functional path (`catalog_plan_json`) with no override**: `fast`'s
  planned port is still the catalog default `8080` (an explicit
  regression guard against the override accidentally always firing).
* **Functional path with override**: `LLMCTL_PORT_FAST=18080` plumbs all
  the way into `catalog_plan_json`'s `profiles.fast.port` — the actual
  port the scheduler would bind to — while `small` and `coder` in the
  *same* plan keep their catalog defaults (`8085`, `8081`), proving
  per-profile scoping survives the full planner computation.
* **Hyphenated profile override in the plan**: `LLMCTL_PORT_WS_DENSE_32B=19999`
  correctly overrides `ws-dense-32b`'s planned port (present in every
  plan regardless of `tier_ok`, so the baseline fixture suffices here).
* **Invalid override value fails loudly**: `LLMCTL_PORT_FAST=not-a-port`
  fed into the planner causes the plan to exit `1` (not merely produce
  garbage), with stderr captured to a scratch file and asserted to
  contain `"not a valid port number"` naming the bad value.
* **Full-stack CLI check**: invokes the real `bin/llmctl models list`
  with `LLMCTL_PORT_FAST=18080` set and asserts the rendered row for
  `fast` shows the overridden port, using a prefix built with the *exact
  same* `printf` format string `cmd_models_list` itself uses (so this
  assertion cannot silently drift from a real column-width change in the
  renderer). Separately invokes the real `bin/llmctl plan --json` with
  and without the override and asserts the `port` field for `fast`
  reflects, respectively, the catalog default and the override — this is
  asserted to be "the exact value `llmctl start/enable fast` would bind
  to."

## Internal behaviour

1. `set -euo pipefail`; source `tests/helpers.sh`; `test_setup_env`.
2. Source `common.sh`, `os_detect.sh`, `hardware.sh`, `catalog.sh` into
   the test's own shell.
3. Section 1: assert `catalog_port_override_env_name` for three profile
   names.
4. Section 2: assert `catalog_port fast` with no override.
5. Section 3: assert scoped override behavior for `catalog_port`.
6. Section 4: assert an override for an unknown profile still dies with
   the expected exit code and message (captured via a `rc=0; ... || rc=$?`
   subshell command-substitution pattern, since `die()` calls `exit 1`
   directly and would otherwise abort the whole test script).
7. Section 5: define `plan_for()` (baseline-fixture-driven
   `hw_probe_json | catalog_plan_json`), then assert the functional plan
   path with no override, with `LLMCTL_PORT_FAST` set, and with
   `LLMCTL_PORT_WS_DENSE_32B` set — each time checking both the
   overridden profile and at least one unrelated profile in the same
   plan.
8. Section 6: assert an invalid (non-integer) override value fails the
   plan with exit `1` and a clear stderr message (written to and read
   back from a `/tmp` scratch file, then removed).
9. Section 7: export `LLMCTL_FAKE_HW` and invoke the real `bin/llmctl`
   binary as a subprocess for `models list` and `plan --json`, with and
   without the override, asserting the CLI-level output reflects the same
   behavior proven at the library level above.
10. `test_finish` tears down the temp environment and exits non-zero iff
    any assertion failed.

## Related scripts

* Sources `tests/helpers.sh` (sibling, documented separately).
* Exercises `lib/catalog.sh` (`catalog_port`,
  `catalog_port_override_env_name`, `catalog_plan_json`) and its
  dependencies `lib/common.sh`, `lib/os_detect.sh`, `lib/hardware.sh`.
* Invokes `bin/llmctl` as a real subprocess (`models list`, `plan --json`
  subcommands).
* Reads `tests/fixtures/hw-baseline.json`.
* Sibling test `tests/test_planner.sh` covers the same
  `catalog_plan_json` machinery without the port-override dimension.
* Discovered and run automatically by `tests/run_tests.sh`; syntax and
  shebang/strict-mode covered by `tests/test_syntax.sh`.

## Last verified date

2026-09-17
