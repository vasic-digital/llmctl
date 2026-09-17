## Overview

`docs/integrations/normalize_cline.sh` is the versioned normalization
filter for Cline's full CLI-output artifact (Phase 5 T030,
`specs/001-llmctl-completion/spec.md` FR-047/FR-048/SC-008,
Clarification 17). Live-challenge determinism (SC-008) is measured at the
full CLI-agent-output layer, not the raw model API response, so this
filter strips the non-deterministic field classes Clarification 17 names
by name (timestamps, temp paths, ordering) from Cline's real run output so
two runs of the same fixed, seeded prompt (see `lib/scheduler.sh`'s
`LLMCTL_SEED`) can be compared byte-for-byte after filtering.

## Prerequisites

* `bash`, `sed` — via its dependency on `lib_normalize_common.sh`.
* Sources `docs/integrations/lib_normalize_common.sh` (same directory,
  resolved via `$(dirname "${BASH_SOURCE[0]}")`) for the four `norm_*`
  transform primitives.
* No llmctl `lib/` sourcing beyond that one shared file, and no
  environment variables are read — reads only stdin.
* Expects Cline's raw stdout on stdin; per the script's own header, its
  expected real shape (not yet captured live) is "Cline's CLI transcript
  output (tool-call trace with session IDs and elapsed-time lines)." This
  filter targets Cline's standalone CLI surface (`cline`), distinct from
  its VS Code IDE extension.

## Usage examples

Pipe a live Cline run through the filter twice and diff the results — an
empty diff means determinism holds for Cline:

```bash
cline -p "<fixed prompt>" | bash docs/integrations/normalize_cline.sh > run1.txt
cline -p "<fixed prompt>" | bash docs/integrations/normalize_cline.sh > run2.txt
diff run1.txt run2.txt
```

Filtering an already-captured transcript file:

```bash
bash docs/integrations/normalize_cline.sh < captured_cline_output.txt
```

There are no flags or arguments — the script reads stdin and writes stdout
unconditionally.

## Edge cases

* **Timestamps** (ISO 8601 with optional fractional seconds/offset,
  `Mon DD HH:MM:SS`-style, and `HH:MM:SS AM/PM`-style) are all replaced with
  the literal `<TIMESTAMP>` via `norm_strip_timestamps`.
* **Temp paths** (`/tmp/...`, macOS `/var/folders/...`, Windows
  `C:\Users\...\AppData\Local\Temp\...`) become `<TMPPATH>` via
  `norm_strip_temp_paths`.
* **Session/request UUIDs** (8-4-4-4-12 hex) become `<UUID>` via
  `norm_strip_uuids`.
* **Elapsed-time/token-usage reporting** (`(12,345 tokens, 3.2s)`-style and
  `Took 0.87s`-style) has its numeric portion replaced with `<DURATION>`
  via `norm_strip_durations`.
* **Empty stdin**: `cat` on an empty pipe produces empty output; the
  `sed`-based pipeline passes it through unchanged with exit 0.
* **Line-ordering non-determinism is explicitly NOT handled**: the
  script's own honest-boundary comment states that Clarification 17's
  third named field class (ordering) is not yet addressed here — no real
  captured Cline transcript exists yet to reveal whether, or how, its
  output needs deterministic re-ordering; tracked as a release-gating
  follow-up rather than guessed at now.
* **Synthetic-not-captured field patterns**: the header states plainly
  these are generic patterns, not reverse-engineered from a real captured
  Cline run against a live llmctl server (that capture is release-gating,
  real-GPU work per `docs/quickstart.md`'s live-challenge determinism
  section) — this filter is the mechanism that capture will run through,
  not proof it has already run.

## Internal behaviour

1. `set -euo pipefail`.
2. `source "$(dirname "${BASH_SOURCE[0]}")/lib_normalize_common.sh"` —
   loads `norm_strip_timestamps`, `norm_strip_temp_paths`,
   `norm_strip_uuids`, `norm_strip_durations`.
3. Single pipeline: `cat | norm_strip_timestamps | norm_strip_temp_paths |
   norm_strip_uuids | norm_strip_durations` — reads all of stdin via `cat`
   and threads it through the four transforms in that fixed order, writing
   the final result to stdout. No `main()` function, no argument parsing;
   the pipeline itself is the entire executable body.

## Related scripts

* `docs/integrations/lib_normalize_common.sh` — the shared primitives this
  script sources and composes (`norm_strip_timestamps`,
  `norm_strip_temp_paths`, `norm_strip_uuids`, `norm_strip_durations`).
* Sibling per-agent filters with the identical shape (differing only in
  header text and pipeline usage example): `normalize_aider.sh`,
  `normalize_claude_code.sh`, `normalize_continue.sh`,
  `normalize_crush.sh`, `normalize_opencode.sh`, `normalize_pi.sh` (all
  documented in this same batch).
* `tests/test_normalize_agents.sh` — the test that runs this filter (as
  part of its `opencode pi crush claude_code aider continue cline` loop)
  against `tests/fixtures/agent_output/cline/run1.txt` and `run2.txt`,
  asserting both normalize to the same output as each other and to the
  checked-in `tests/fixtures/agent_output/cline/expected_normalized.txt`.
* `docs/integrations.md` — documents the live-challenge determinism
  mechanism this filter is part of, including the exact `diff run1.txt
  run2.txt` usage pattern, and links to Cline's install script
  (`docs/integrations/install_cline.sh`, a separate, unrelated script that
  installs the standalone `cline` CLI binary rather than filtering its
  output).
* `lib/scheduler.sh` — its `LLMCTL_SEED` environment variable is the
  server-side determinism mechanism this filter's client-output-side
  normalization complements.

## Last verified date

2026-09-17
