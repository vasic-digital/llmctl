# `resolve_deps.sh`

## Overview

Source: `lib/resolve_deps.sh` (script). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
resolve_deps.sh - the ONE place that locates llmctl's non-vendored dependencies:
  constitution  (the Helix Constitution hub),
  containers    (vasic-digital/Containers, Go module digital.vasic.containers),
  superspec     (WangX0111/superspec Spec Kit extension).

Why this exists (owner mandate 2026-10-21, "one source of truth, always the latest"): llmctl used to carry
its own pinned `constitution`, `submodules/containers` and `submodules/superspec` submodules. llmctl lives
INSIDE the constitution hub (constitution/submodules/llmctl), so its nested `constitution` created a
mutual-reference cycle (hub -> llmctl -> hub). The hub now vendors `containers` and `superspec` flat at
<hub>/submodules/<name> (owner decision 2026-10-21), so llmctl no longer pins private copies: it resolves
them. llmctl's own real dependencies (submodules/llama.cpp, submodules/colibri) are still ordinary submodules.

Usage:
  bash lib/resolve_deps.sh <constitution|containers|superspec>   # prints the absolute path, exit 0
  bash lib/resolve_deps.sh --all                                 # prints name=path lines; exit 1 if any unresolved
  source lib/resolve_deps.sh; llmctl_resolve_dep containers      # function form (no shell options are changed)

Resolution order (first candidate that passes its marker check wins):
  1. env override  LLMCTL_CONSTITUTION_DIR / LLMCTL_CONTAINERS_DIR / LLMCTL_SUPERSPEC_DIR. A relative value is
     made absolute. An override that is empty or does not pass the marker check is an ERROR (exit 1), never a
     silent fall-through to another location.
  2. the parent hub, when llmctl is nested at <hub>/submodules/llmctl (hub = ../.. and holds Constitution.md):
     constitution = <hub>; containers/superspec = <hub>/submodules/<name> (= ../<name>, vendored by the hub).
     This step comes BEFORE step 3 (pinned by a fixture in tests/test_resolve_deps.sh).
  3. <root>/constitution and <root>/submodules/<name>  (root = this llmctl checkout: a consumer's own copy,
     Constitution section 11.4.76, or the symlinks made by scripts/link_deps.sh).
  4. sibling clones  <root>/../constitution, <root>/../containers, <root>/../superspec  (standalone use).
  5. ancestor walk: for every ancestor A of <root>: A/constitution, A/submodules/constitution (constitution
     - the semantics of the hub's find_constitution.sh), A/submodules/<name>, A/constitution/submodules/<name>.
  6. host fallback (constitution ONLY) - OPT-IN: only when LLMCTL_HOST_FALLBACK_DIR is set. There is no
     built-in host path (a host-specific literal does not belong in a shared library).

Marker checks (so an empty directory or a different project is never accepted):
  constitution: Constitution.md exists;  containers: go.mod declares `module digital.vasic.containers`;
  superspec: extension.yml exists.

Exit codes: 0 resolved (path on stdout); 1 not resolved / bad override (actionable message on stderr, stdout
empty); 2 usage error.

Side effects: none (read-only). Dependencies: bash >= 3.2 (macOS-compatible), grep, dirname.
Cross-references: scripts/link_deps.sh (creates the ignored symlinks used by go.mod and the carriers'
`@constitution/CLAUDE.md` import), tests/test_resolve_deps.sh (the proof), docs/dependency-layout.md.
```

Run: `bash lib/resolve_deps.sh`.
