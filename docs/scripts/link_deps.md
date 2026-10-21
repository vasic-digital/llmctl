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
