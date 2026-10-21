# Dependency layout: one source of truth

| Field | Value |
|---|---|
| Revision | 1 |
| Created | 2026-10-21 |
| Status | active |

llmctl does **not** vendor `constitution`, `submodules/containers` or `submodules/superspec`
(owner mandate 2026-10-21: reduce redundancy, one source of truth, always the latest, main
submodules live in `<root>/submodules` or `<root>/constitution/submodules`, never nested chains).
llmctl itself lives inside the constitution hub at `constitution/submodules/llmctl`; a nested
`constitution` here created a hub -> llmctl -> hub cycle, and `containers` / `superspec` duplicated
the hub's flat copies. llmctl's own real dependencies stay ordinary submodules:
`submodules/llama.cpp` and `submodules/colibri` (`git submodule update --init`).

## How a dependency is found (`lib/resolve_deps.sh`)

```bash
bash lib/resolve_deps.sh constitution   # or containers / superspec / --all
```

First match wins: 1. env override `LLMCTL_CONSTITUTION_DIR` / `LLMCTL_CONTAINERS_DIR` /
`LLMCTL_SUPERSPEC_DIR` (an invalid override is an error, never a silent fall-through);
2. the parent hub, when llmctl is at `<hub>/submodules/llmctl` (constitution = `<hub>`,
containers/superspec = `<hub>/submodules/<name>`); 3. `<root>/constitution`, `<root>/submodules/<name>`;
4. sibling directories; 5. ancestor directories (`A/constitution`, `A/submodules/<name>`);
6. host fallback for the constitution only (`/home/milosvasic/Projects/helix_code/constitution`,
override `LLMCTL_HOST_FALLBACK_DIR`). Nothing resolved: exit 1 with an actionable message.

## Fixed repo-relative paths: `scripts/link_deps.sh`

`go.mod` (`replace digital.vasic.containers => ./submodules/containers`) and the carriers'
`@constitution/CLAUDE.md` import need fixed paths. `bash scripts/link_deps.sh` creates the three
**untracked, .gitignored** symlinks (`constitution`, `submodules/containers`, `submodules/superspec`)
to whatever the resolver found (`--check` verifies only). `make deps` / `make test` run it. A real
directory in the way is never replaced. Inside the hub, `constitution` -> `../..`, so the
`@constitution/CLAUDE.md` import keeps working with no extra clone.

Outside the hub on a bare clone: clone the constitution next to llmctl, or export the
`LLMCTL_*_DIR` variables, then run `make deps`. The release preflight only verifies llmctl's own
pins (llama.cpp, colibri).
