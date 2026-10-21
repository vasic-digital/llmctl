# `test_leftover_deps.sh`

## Overview

Source: `tests/test_leftover_deps.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_leftover_deps.sh - review round 3: UPGRADE LEFTOVERS and the Go-suite guard.

git does not delete a populated submodule worktree when its gitlink is removed, so after pulling the
"single source of truth" change an existing checkout keeps REAL directories constitution/, submodules/containers/
and submodules/superspec/ (now .gitignored, i.e. hidden). This suite proves, against throw-away fixtures only:
  1. link_deps names the leftover and prints the exact remediation (verify clean, rm -rf), never the misleading
     "set LLMCTL_*_DIR to it" advice; 2. engine_ensure_containers accepts a valid leftover (warn + continue);
  3. the resolver warns for every dependency, also when the hub copy wins over a real <root>/<name>;
  4. --adopt-leftover moves ONLY a clean gitfile-style leftover whose HEAD equals the old pin, to
     <path>.leftover-<date> (never deleted, section 9.2) and links; dirty / wrong-pin / plain-dir leftovers are refused;
  5. M2 helpers.sh guard: a Go-building suite SKIPs loudly (SKIP-SUITE + resolver message) when containers is
     unresolvable; M3 dry-run prints the resolver message and creates nothing.
```

Run: `bash tests/test_leftover_deps.sh`.
