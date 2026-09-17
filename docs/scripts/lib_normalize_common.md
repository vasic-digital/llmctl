## Overview

`docs/integrations/lib_normalize_common.sh` provides the four shared
text-normalization primitives used by all 7 per-agent CLI-output
normalization filters (`docs/integrations/normalize_<agent>.sh`). It exists
to satisfy spec.md FR-047/FR-048/SC-008/Clarification 17: live-challenge
determinism is measured at the *full CLI-agent-output* layer (the complete
transcript/diff/edited-files artifact each of the 7 supported agents
produces), not the raw model API response — so two runs of the same
deterministic prompt against the same seeded server (see
`lib/scheduler.sh`'s `LLMCTL_SEED`) must be compared *after* stripping
known non-deterministic fields that vary between runs for reasons that
have nothing to do with the model's actual answer: wall-clock timestamps,
per-run temp-directory/session-id paths, UUID-shaped session/request
identifiers, and elapsed-time/token-usage duration reporting. This file
holds the transformation *primitives*; each `normalize_<agent>.sh` applies
the subset relevant to that agent's real output shape.

## Prerequisites

* `bash`, `sed` (specifically GNU/BSD-compatible extended regex via
  `sed -E`).
* No llmctl `lib/` sourcing and no environment variables are read —
  standalone by design, exactly like the sibling `install_<agent>.sh`
  scripts.
* Consumed by `source`ing it, never executed directly for its own effect
  (it defines functions only; there is no entrypoint or argument parsing).

## Usage examples

Source it and pipe raw agent output through the transforms relevant to the
non-deterministic fields present:

```bash
source "$(dirname "${BASH_SOURCE[0]}")/lib_normalize_common.sh"
norm_strip_timestamps <<<"${raw}" | norm_strip_temp_paths | norm_strip_uuids | norm_strip_durations
```

Comparing two raw runs after normalization (the actual determinism check
each `normalize_<agent>.sh` and `tests/test_normalize_agents.sh` perform):

```bash
source docs/integrations/lib_normalize_common.sh
norm1="$(norm_strip_timestamps <<<"${run1}" | norm_strip_temp_paths | norm_strip_uuids | norm_strip_durations)"
norm2="$(norm_strip_timestamps <<<"${run2}" | norm_strip_temp_paths | norm_strip_uuids | norm_strip_durations)"
[[ "${norm1}" == "${norm2}" ]] && echo "determinism holds"
```

Each function reads its input on stdin and writes the transformed text to
stdout — they compose in any order via a pipeline, as shown above.

## Edge cases

* **ISO 8601 timestamps with optional fractional seconds and timezone
  offset**: `norm_strip_timestamps`'s first pattern matches
  `YYYY-MM-DDTHH:MM:SS` with an optional `.fraction` and an optional `Z` or
  `±HH:MM` suffix — e.g. `2026-09-15T12:34:56.123456+02:00` and
  `2026-09-15T12:34:56Z` both collapse to `<TIMESTAMP>`.
* **Human-readable log timestamps**: `norm_strip_timestamps` also matches
  `Sep 15 12:34:56`-style (`[A-Z][a-z]{2} [0-9]{1,2} HH:MM:SS`) and
  12-hour `12:34:56 PM`/`12:34:56AM`-style timestamps (the third pattern
  allows an optional space before AM/PM).
* **Cross-platform temp paths**: `norm_strip_temp_paths` handles three
  distinct shapes in one pass — POSIX `/tmp/...`, macOS's
  `/var/folders/.../T/...`, and Windows-style
  `C:\Users\...\AppData\Local\Temp\...` — each collapsing to `<TMPPATH>`,
  since several supported agents run on any of these platforms.
* **UUID v4-shaped identifiers**: `norm_strip_uuids` matches the standard
  8-4-4-4-12 hex-digit-group shape case-insensitively
  (`[0-9a-fA-F]{8}-...`), which several agents embed in per-run temp paths,
  log lines, or trace IDs — collapsing to `<UUID>`.
* **Duration reporting in two distinct shapes**: `norm_strip_durations`
  handles both a trailing-parenthesis style (e.g. `(12,345 tokens, 3.2s)` →
  the `3.2s)` portion becomes `<DURATION>s)`) and a `Took 0.87s` style
  (→ `Took <DURATION>s`) — two separate `sed -E` expressions in the same
  function.
* **Idempotent placeholder tokens**: every function replaces its matched
  field class with the *same* stable, greppable placeholder every time
  (`<TIMESTAMP>`, `<TMPPATH>`, `<UUID>`, `<DURATION>`) — this uniformity is
  precisely what makes two independent runs comparable byte-for-byte after
  filtering, since two different real timestamps both become the identical
  literal string `<TIMESTAMP>`.
* **`set -euo pipefail`**: present at the top of the file even though the
  functions themselves are pure `sed` pipelines with no failure-prone
  external calls — inherited by any caller that sources this file directly
  into its own shell rather than a subshell.

**Honest boundary (Constitution §11.4.6)**, stated in the script's own
header: these primitives strip the three non-deterministic field *classes*
spec.md Clarification 17 names by name (timestamps, temp paths, ordering —
though line-ordering normalization is not addressed by any current
function; see `docs/integrations.md`'s "ordering" note). They are
deliberately generic patterns, not reverse-engineered from a captured real
run of any of the 7 agents against a live llmctl server — that capture is
release-gating, real-GPU work per Clarification 1's hybrid approach, and is
not claimed done by this file. Each per-agent filter's header states
plainly that its exact regex set is expected to be refined once a real
captured transcript is available.

## Internal behaviour

The file defines four independent, stateless functions and nothing else
(no entrypoint, no argument parsing, no `main`):

1. **`norm_strip_timestamps`**: three `sed -E` substitutions in sequence
   (ISO 8601, `Mon DD HH:MM:SS`, `HH:MM:SS AM/PM`), each replacing every
   match with `<TIMESTAMP>` globally (`/g`).
2. **`norm_strip_temp_paths`**: three `sed -E` substitutions (POSIX
   `/tmp/...`, macOS `/var/folders/...`, Windows
   `C:\Users\...\AppData\Local\Temp\...`), each replacing matches with
   `<TMPPATH>`.
3. **`norm_strip_uuids`**: one `sed -E` substitution matching the
   8-4-4-4-12 hex UUID shape, replacing with `<UUID>`.
4. **`norm_strip_durations`**: two `sed -E` substitutions (trailing-paren
   duration, `Took Ns` duration), each replacing the numeric portion with
   `<DURATION>`.

Callers compose these via a shell pipeline in whatever order/subset suits
the agent's actual output shape; the file itself performs no composition.

## Related scripts

* `docs/integrations/normalize_aider.sh`, `normalize_claude_code.sh`,
  `normalize_cline.sh`, `normalize_continue.sh`, `normalize_crush.sh`,
  `normalize_opencode.sh`, `normalize_pi.sh` — the 7 per-agent filters that
  `source` this file and apply the subset of primitives relevant to each
  agent's real output shape (documented by another agent in this same
  batch).
* `tests/test_normalize_common.sh` — the RED/GREEN proof that each
  primitive normalizes two genuinely different real values (two different
  timestamps, two different temp paths, etc.) to the *same* placeholder,
  and that a full pipeline of all four normalizes two runs differing only
  in those fields to byte-identical output.
* `tests/test_normalize_agents.sh` — exercises each of the 7
  `normalize_<agent>.sh` scripts (which depend on this file) against fixture
  pairs under `tests/fixtures/agent_output/<agent>/`.
* `docs/integrations.md` — documents the live-challenge determinism
  mechanism this file is the shared foundation of, including the exact
  `diff run1.txt run2.txt` usage pattern.
* `lib/scheduler.sh` — its `LLMCTL_SEED` environment variable is the
  server-side determinism mechanism this file's *client-output-side*
  normalization complements.

## Last verified date

2026-09-17
