# Dependency layout: one source of truth

| Field | Value |
|---|---|
| Revision | 2 |
| Created | 2026-10-21 |
| Last modified | 2026-10-21 |
| Status | active |

llmctl does **not** vendor `constitution`, `submodules/containers` or `submodules/superspec`
(owner mandate 2026-10-21: reduce redundancy, one source of truth, always the latest, main
submodules live in `<root>/submodules` or `<root>/constitution/submodules`, never nested chains).
llmctl itself lives inside the constitution hub at `constitution/submodules/llmctl`; a nested
`constitution` here created a hub -> llmctl -> hub cycle. The hub now vendors `containers` and
`superspec` under `<hub>/submodules/<name>` (owner decision 2026-10-21), so llmctl resolves them
instead of pinning private copies. llmctl's own real dependencies stay ordinary submodules:
`submodules/llama.cpp` and `submodules/colibri` (`git submodule update --init`).

## How a dependency is found (`lib/resolve_deps.sh`)

```bash
bash lib/resolve_deps.sh constitution   # or containers / superspec / --all
```

First match wins: 1. env override `LLMCTL_CONSTITUTION_DIR` / `LLMCTL_CONTAINERS_DIR` /
`LLMCTL_SUPERSPEC_DIR` (a relative value is made absolute; an empty or invalid override is an error, never a
silent fall-through); 2. the parent hub, when llmctl is at `<hub>/submodules/llmctl` (constitution = `<hub>`,
containers/superspec = `<hub>/submodules/<name>`, vendored by the hub); 3. `<root>/constitution`,
`<root>/submodules/<name>` (a consumer's own copy, Constitution section 11.4.76); 4. sibling clones for
standalone use; 5. ancestor directories (`A/constitution`, `A/submodules/<name>`); 6. host fallback for the
constitution only, **opt-in**: used only when `LLMCTL_HOST_FALLBACK_DIR` is set (there is no built-in host
path). Nothing resolved: exit 1 with an actionable message. A real `<root>/constitution` directory (leftover
of the old gitlink) is used but warned about.

## Fixed repo-relative paths: `scripts/link_deps.sh`

`go.mod` (`replace digital.vasic.containers => ./submodules/containers`) and the carriers'
`@constitution/CLAUDE.md` import need fixed paths. `bash scripts/link_deps.sh` creates the three
**untracked, .gitignored** symlinks (`constitution`, `submodules/containers`, `submodules/superspec`)
to whatever the resolver found (`--check` verifies only; `link_deps.sh containers` links just that one).
`make deps` / `make test` run it, and `llmctl setup` / `llmctl build decide|all` link `containers` themselves
(and stop with the resolver's message if it cannot be found). A real directory in the way is never replaced.
Inside the hub the links are relative (`constitution` -> `../..`, `submodules/<name>` -> `../../<name>`), so the
`@constitution/CLAUDE.md` import keeps working with no extra clone; elsewhere they are absolute.

**Symlink cycle inside the hub.** `<hub>/submodules/llmctl/constitution` -> `<hub>` makes the hub contain itself.
Tools that follow symlinks (`find -L`, `grep -R`, indexers, archivers) will loop or double-count: exclude
`submodules/llmctl/constitution`, `submodules/llmctl/submodules/containers` and `submodules/llmctl/submodules/superspec`
from code indexes and scans (the links are gitignored and never archived; do not edit canon for this).

Outside the hub on a bare clone: clone the constitution next to llmctl, or export the
`LLMCTL_*_DIR` variables, then run `make deps`. The release preflight only verifies llmctl's own
pins (llama.cpp, colibri) and prints the commits of the resolved dependencies so the release evidence records them.

## Upgrading an existing checkout (leftovers)

git does not delete a populated submodule worktree when its gitlink is removed. After pulling, an old checkout
keeps REAL directories `constitution/`, `submodules/containers/`, `submodules/superspec/` (gitignored, so hidden).
`scripts/link_deps.sh` reports each as `LEFTOVER <path>` and exits 1 (so `make deps` fails) until you either

1. verify `git -C <path> status --porcelain` prints nothing, then `rm -rf <path>`, and re-run; or
2. opt in: `bash scripts/link_deps.sh --adopt-leftover [name]` moves a leftover that is a clean submodule-style worktree
   at the old pinned commit to `<path>.leftover-<YYYYMMDD>` (nothing is deleted) and links; a dirty, wrong-commit or
   plain-directory leftover is refused with the reason.

Until then the resolver warns (for every dependency, also when the hub copy wins over the leftover) and
`llmctl setup` / `llmctl build decide|all` use a valid leftover `containers` with a warning. Go-building test suites
SKIP loudly (SKIP-SUITE with the resolver message) when containers is unresolvable (`tests/helpers.sh`).
