## Overview

`tests/test_setup_e2e.sh` is a fresh-clone simulation of `llmctl setup`
(FR-001, US1 Acceptance Scenario 1: "Given a fresh clone of llmctl, When
running `./bin/llmctl setup`, Then all engines build, hardware is probed,
and the model catalog is validated"). It exists because a genuinely
fresh clone doesn't have gigabytes of already-built engine source ready
to compile in seconds, so a real end-to-end test can't simply `cd` into
the real repo and run `setup` for real (a real build takes multiple
minutes and is a separate, documented, release-gating manual procedure —
see `docs/quickstart.md`, T015). Instead this test constructs a
genuinely structurally-fresh `LLMCTL_ROOT` — `bin/` and `lib/` symlinked
**read-only** from the real repo (i.e. the actual code under test, not a
copy), plus fake `submodules/*/.git` marker files simulating a clone that
ran `git submodule update --init` but hasn't built anything yet — and
runs the real `bin/llmctl setup` entrypoint as a genuine subprocess
against that fresh root, with `LLMCTL_DRY_RUN=1` standing in for the real
multi-minute compiles.

## Prerequisites

* Sources `tests/helpers.sh` for assertion helpers and
  `test_setup_env`/`test_finish`.
* Requires `ln -s`, `mkdir -p`, `touch` to construct the fresh-clone
  fixture tree.
* Constructs `FRESH_ROOT="${TEST_TMP}/fresh-clone"` with:
  * `bin/llmctl` symlinked to the real `${LLMCTL_ROOT}/bin/llmctl`.
  * `lib` symlinked to the real `${LLMCTL_ROOT}/lib`.
  * `models/catalog.json` symlinked to the real
    `${LLMCTL_ROOT}/models/catalog.json`.
  * `submodules/llama.cpp/.git` and `submodules/colibri/.git` created as
    empty marker files (simulating a fresh, uninitialized-but-cloned
    submodule state) — the real, removed `vendor/` path is explicitly
    *not* used, matching the current `submodules/` layout.
* Sets `LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"`
  and `LLMCTL_DRY_RUN=1` before invoking `setup`.
* Invokes `"${FRESH_ROOT}/bin/llmctl" setup` as a real subprocess (via the
  symlinked entrypoint), so the whole `bin/llmctl` dispatch + every
  sourced `lib/*.sh` must genuinely run against this synthetic root.

## Usage examples

```bash
bash tests/test_setup_e2e.sh
```

Also runs as part of the full suite via `tests/run_tests.sh` or
`make test`.

## Edge cases

* Asserts `llmctl setup`'s exit code is `0` against the synthetic
  fresh-clone tree.
* Asserts the setup output announces its own orchestration sequence:
  `"llmctl setup: doctor -> build -> plan"`.
* **Doctor phase**: asserts `"PASS OS:"` appears (hardware/OS probe ran
  against the deterministic baseline fixture, not the real host);
  asserts both submodule-initialization checks report against the *real,
  current* `submodules/llama.cpp` and `submodules/colibri` paths — the
  assertion messages explicitly note this proves the check targets the
  current path convention, not a stale, already-removed `vendor/` path;
  asserts `"catalog valid JSON"` appears (the model catalog was
  validated).
* **Build phase**: asserts dry-run build invocations for both engines —
  `"[dry-run] cmake -S"` (llama.cpp) and `"[dry-run] make -C"`
  (colibri) — appear in the output, i.e. both engine builds were
  genuinely *invoked* (in dry-run form) rather than skipped.
* **Plan phase**: asserts the output mentions `"fast"` — i.e. the plan
  phase ran against the same probed (fixture) hardware using the real,
  unmodified model catalog, and considered at least one real catalog
  profile.
* Asserts the final `"setup complete"` message appears.
* The captured combined output is also echoed (indented) to the test's
  own stdout before assertions run, purely as human-readable diagnostic
  context if the test is run interactively.

## Internal behaviour

1. `set -euo pipefail`; source `tests/helpers.sh`; `test_setup_env`.
2. Build the `FRESH_ROOT` directory tree (`bin/`, `models/`,
   `submodules/llama.cpp`, `submodules/colibri`).
3. Symlink `bin/llmctl`, `lib`, and `models/catalog.json` from the real
   repo into `FRESH_ROOT`.
4. `touch` the two fake submodule `.git` marker files.
5. Export `LLMCTL_FAKE_HW` (baseline fixture) and `LLMCTL_DRY_RUN=1`.
6. Invoke `"${FRESH_ROOT}/bin/llmctl" setup` as a real subprocess,
   capturing combined stdout+stderr and the exit code.
7. Echo the captured output (indented) for human readability.
8. Run the assertion sequence described in "Edge cases" above, in order:
   overall exit code and orchestration announcement, doctor-phase
   evidence, build-phase evidence, plan-phase evidence, completion
   message.
9. `test_finish` tears down the temp environment (including the
   synthetic fresh-clone tree) and exits non-zero iff any assertion
   failed.

## Related scripts

* Sources `tests/helpers.sh` (sibling, documented separately).
* Invokes the real `bin/llmctl` entrypoint (via a symlink) as a genuine
  subprocess, exercising its full `setup` orchestration path
  (`doctor` → `build` → `plan`), which in turn touches every library
  under `lib/` (`common.sh`, `os_detect.sh`, `hardware.sh`, `catalog.sh`,
  `engine.sh`, `doctor.sh`) and the real `models/catalog.json`.
* Reads `tests/fixtures/hw-baseline.json`.
* Complements `docs/quickstart.md`'s documented real (non-dry-run),
  release-gating fresh-clone verification procedure, which this test
  explicitly does not attempt to replace.
* Discovered and run automatically by `tests/run_tests.sh`; syntax and
  shebang/strict-mode covered by `tests/test_syntax.sh`.

## Last verified date

2026-09-17
