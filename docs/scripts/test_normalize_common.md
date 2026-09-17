## Overview

`tests/test_normalize_common.sh` proves that the shared transform
primitives in `docs/integrations/lib_normalize_common.sh`
(`norm_strip_timestamps`, `norm_strip_temp_paths`, `norm_strip_uuids`,
`norm_strip_durations`) genuinely strip each documented class of
non-deterministic field from CLI-agent output, and that composing all
four together produces byte-identical output from two runs differing
only in those fields. It is the unit-level sibling of
`tests/test_normalize_agents.sh`: that test proves the 7 *per-agent*
filters behave correctly end-to-end; this test proves the *common
building blocks* those filters are meant to be built from are individually
correct (Phase 5 T030, `spec.md` FR-047/FR-048).

## Prerequisites

* Sources `tests/helpers.sh` for assertion helpers and
  `test_setup_env`/`test_finish`.
* Sources `${LLMCTL_ROOT}/docs/integrations/lib_normalize_common.sh`
  directly (not invoked as a subprocess) to get the four
  `norm_strip_*` shell functions into its own process.
* Requires `bash`, `printf`, and `sed` (the paired-mutation section
  defines a deliberately broken filter using `sed -E`).
* No project-specific environment variables are read; only
  `test_setup_env`'s isolated `LLMCTL_*` state directories are exported
  (unused by this script's actual assertions, but present for consistency
  with the rest of the suite).

## Usage examples

```bash
bash tests/test_normalize_common.sh
```

Also runs as part of the full suite via:

```bash
bash tests/run_tests.sh
```

or `make test`.

## Edge cases

* `norm_strip_timestamps`: asserts it replaces **both** ISO-8601
  (`2026-09-15T12:34:56Z`) and human-readable
  (`Sep 15 12:34:56`, `11:59:00 PM`) timestamp shapes with the single
  placeholder `<TIMESTAMP>` on three separate lines in one pass; also
  asserts two genuinely *different* real timestamps normalize to the
  *same* placeholder (the actual determinism property under test, not
  just "it changes the string").
* `norm_strip_temp_paths`: asserts a `/tmp/...` path is replaced with
  `<TMPPATH>`, and that two different temp paths (`/tmp/run1/x` vs.
  `/tmp/run2-different/x`) normalize identically.
* `norm_strip_uuids`: asserts a v4-shaped UUID
  (`550e8400-e29b-41d4-a716-446655440000`) embedded mid-sentence
  (`session <UUID> started`) is replaced with `<UUID>`.
* `norm_strip_durations`: asserts elapsed-time reporting in two different
  shapes on two lines (`(12,345 tokens, 3.2s)` and `Took 0.87s`) both
  normalize their duration figure to `<DURATION>`, while leaving the
  surrounding text (including the unrelated `12,345` token count) intact.
* **Composition case**: pipes one realistic-shaped line containing a temp
  path, a session UUID, an ISO timestamp, and a duration through all four
  filters chained (`norm_strip_timestamps | norm_strip_temp_paths |
  norm_strip_uuids | norm_strip_durations`) for two runs that differ in
  every one of those four fields simultaneously, and asserts the two
  fully-normalized outputs are byte-identical — this is the actual
  FR-047/SC-008 property the per-agent filters must inherit.
* **Paired-mutation case** (Constitution §11.4.224(C)/§1.1): defines an
  intentionally-broken `broken_strip_timestamps()` whose regex
  (`NEVER_MATCHES_ANYTHING`) can never match a real timestamp, runs it
  against a real timestamp line, and asserts the mutated output does
  **not** equal what a correct filter would produce — proving this test
  file is capable of detecting a broken/regressed filter, not merely
  agreeing with whatever the real implementation currently does.

## Internal behaviour

1. `set -euo pipefail`; source `tests/helpers.sh`; `test_setup_env`.
2. Source `lib_normalize_common.sh` to bring the four `norm_strip_*`
   functions into scope.
3. Section 1 (timestamps): pipe a 3-line fixture through
   `norm_strip_timestamps` and assert the expected 3-line output;
   separately assert two different timestamps collapse to the same
   placeholder.
4. Section 2 (temp paths): pipe one line through `norm_strip_temp_paths`
   and assert the replacement; assert two different paths collapse
   identically.
5. Section 3 (UUIDs): pipe one line through `norm_strip_uuids` and assert
   the replacement.
6. Section 4 (durations): pipe a 2-line fixture through
   `norm_strip_durations` and assert both lines' expected output.
7. Section 5 (composition): build two realistic multi-field lines
   (`run1`, `run2`) differing in all four non-deterministic classes,
   normalize each through the full four-stage pipe, and assert the two
   normalized results are equal.
8. Section 6 (paired mutation): define `broken_strip_timestamps`, run it
   against a real timestamp, and assert its output differs from the
   correct expected string (captured as `rc=1` via a bracket test, then
   `assert_eq 1 "${rc}"`).
9. Call `test_finish`, which tears down the temp environment and exits
   non-zero iff any assertion failed.

## Related scripts

* Sources `tests/helpers.sh` (documented separately, sibling script).
* Sources and directly exercises
  `docs/integrations/lib_normalize_common.sh` — the shared primitives
  layer.
* Sibling test `tests/test_normalize_agents.sh` exercises the 7 concrete
  `docs/integrations/normalize_<agent>.sh` filters that are expected to
  be composed from these same primitives, at the end-to-end fixture
  level (real captured-shaped `run1.txt`/`run2.txt` per agent) rather
  than the unit level this script tests at.
* Discovered and run automatically by `tests/run_tests.sh`; also covered
  by `tests/test_syntax.sh`'s `bash -n` + shebang + strict-mode sweep.

## Last verified date

2026-09-17
