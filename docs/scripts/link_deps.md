# `link_deps.sh`

## Overview

Source: `scripts/link_deps.sh` (script). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
link_deps.sh - materialise the (untracked, .gitignored) convenience links to llmctl's resolved dependencies.

llmctl no longer vendors `constitution`, `submodules/containers` or `submodules/superspec` as submodules
(single source of truth: the copy in the constitution hub / on the host - see lib/resolve_deps.sh). Two
things still address them by fixed repo-relative path: go.mod (`replace digital.vasic.containers =>
./submodules/containers`) and the carriers' `@constitution/CLAUDE.md` import. This script makes those paths
valid by symlinking them to whatever lib/resolve_deps.sh resolves. Nothing is copied; nothing is pinned.

Usage:
  bash scripts/link_deps.sh                       # create/refresh all three links (idempotent)
  bash scripts/link_deps.sh containers            # only the named ones (constitution|containers|superspec)
  bash scripts/link_deps.sh --check [names...]    # verify only; exit 1 if any link is missing or points elsewhere
  bash scripts/link_deps.sh --adopt-leftover [names...]   # see UPGRADE LEFTOVERS below

UPGRADE LEFTOVERS: git does not delete a populated submodule worktree when its gitlink is removed, so an
existing checkout keeps REAL directories constitution/, submodules/containers/, submodules/superspec/ (they are
.gitignored now, i.e. hidden). Such a path blocks the link (exit 1, "LEFTOVER <path>") and the script prints the
remediation: verify `git -C <path> status --porcelain` is empty, then `rm -rf <path>` and re-run. With the explicit
opt-in --adopt-leftover it converts ONLY a leftover that is (a) a gitfile-style submodule worktree (.git is a
FILE), (b) clean, and (c) at HEAD == the old recorded pin (constitution 8a60462..., containers 4a8f04e...,
superspec c20ac6c...; test hook: LLMCTL_ADOPT_PIN_<NAME>) by MOVING it to <path>.leftover-<YYYYMMDD>[-N]
(nothing is deleted, section 9.2) and linking. Anything else is refused with the reason.
Inside the hub (llmctl at <hub>/submodules/llmctl) the links are RELATIVE (constitution -> ../..,
submodules/<name> -> ../../<name>) so they survive moving the hub; elsewhere they are absolute.

Links managed (relative to the llmctl root):
  constitution -> <resolved constitution>      submodules/containers -> <resolved containers>
  submodules/superspec -> <resolved superspec>

Safety: a path that exists as a REAL directory or file is never replaced (reported and skipped, exit 1);
only missing paths and symlinks are touched. An unresolvable dependency is reported (exit 1) after the
others have still been linked - never a silent skip.
Exit codes: 0 all links correct; 1 at least one dependency unresolved / blocked by a real dir / (--check) wrong.
Side effects: creates/replaces symlinks inside the llmctl checkout. Dependencies: bash, ln, readlink.
Cross-references: lib/resolve_deps.sh, tests/test_link_deps.sh, docs/dependency-layout.md.
```

Run: `bash scripts/link_deps.sh`.
