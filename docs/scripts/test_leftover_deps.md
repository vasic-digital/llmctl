# `test_leftover_deps.sh`

## Overview

Source: `tests/test_leftover_deps.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_leftover_deps.sh - UPGRADE LEFTOVERS (detect + warn + manual remediation ONLY), the opt-in Go-suite guard and dry-run.

git does not delete a populated submodule worktree when its gitlink is removed, so an existing checkout keeps REAL
directories constitution/, submodules/containers/ and submodules/superspec/ (now .gitignored, i.e. hidden). Proven here,
against throw-away fixtures only:
  1. link_deps names the leftover and prints a MANUAL remediation: when the leftover is the ONLY copy it says set
     LLMCTL_<DEP>_DIR / move it aside (never "rm -rf" first); when a shared copy exists it says verify clean, then rm -rf;
  2. NO code moves, renames or deletes a user directory; the old "adopt" convenience is gone;
  3. the resolver warns for every dependency, also when the hub copy wins over a real <root>/<name>;
  4. engine_ensure_containers builds from a leftover ONLY when it is the resolver's own answer and clean; never when a
     different copy resolves, never when dirty;
  5. require_containers_or_skip is OPT-IN: sourcing helpers.sh probes/links/skips nothing, a suite that merely mentions
     llmctl-decide still runs, a genuine FAIL stays a FAIL; an opted-in suite SKIPs loudly when containers is unresolvable;
  6. dry-run: resolver message, no link, and NO go invocation (a fake go on PATH fails the test if called).
```

Run: `bash tests/test_leftover_deps.sh`.
