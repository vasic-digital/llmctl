# Release Process

**Revision:** 1
**Last modified:** 2026-09-15T00:00:00Z

llmctl releases are created on **both GitHub and GitLab** as one atomic
operation (spec.md FR-013/FR-050, Clarification 19): if either forge fails,
the whole release is treated as not-published, and re-running the script is
idempotent — it retries only the forge that failed, never re-creating the
one that already succeeded.

> **Mandatory human checkpoint (Constitution's irreversible-action
> discipline):** creating a public GitHub/GitLab release is a hard-to-reverse,
> externally-visible action. `scripts/release/create_release.sh` NEVER runs
> in real (non-dry-run) mode unattended, automatically, or as part of `make
> test`/CI. **Always run `--dry-run` first, review its output, and only then
> — as a deliberate, explicit, operator-initiated action — run the script
> again without `--dry-run`.**

## The three scripts

| Script | What it does |
|---|---|
| [`scripts/release/preflight_submodules.sh`](../scripts/release/preflight_submodules.sh) | Verifies every pinned submodule ref (this repo's own: llama.cpp, colibri) is genuinely fetchable, before anything else runs, and prints the commit of each resolved dependency (constitution, containers, superspec) for the release evidence |
| [`scripts/release/build_archive.sh`](../scripts/release/build_archive.sh) | Builds `llmctl.tar.gz`/`llmctl.zip` as a full tree of what llmctl pins (working tree + `.git` + llama.cpp and colibri content). It does not contain `containers`/`constitution`/`superspec` (resolved, not vendored): the Go decision binary needs them from the hub or `LLMCTL_CONTAINERS_DIR` |
| [`scripts/release/create_release.sh`](../scripts/release/create_release.sh) | Orchestrates the above plus SemVer validation, changelog generation, and the actual `gh release create` + `glab release create` calls |

## Step-by-step procedure

### 1. Dry-run (always do this first)

```bash
bash scripts/release/create_release.sh --dry-run v1.2.3
```

What it really does: SemVer validation, and changelog generation from the
conventional-commit history since the newest release tag (`git describe --tags
--match 'v[0-9]*'`, so a non-release tag such as `helixconstitution-v70` never
becomes the label), plus the `### Migration notes` of the matching `CHANGELOG.md`
section when there is one. What it does **not** do: the submodule preflight
(step 1 of the script) and the asset build (`make archive`, step 3) are only
**announced** ("would run"); neither is executed, and no `git fetch` is made.
It makes zero calls to `gh`/`glab`. Run
`bash scripts/release/preflight_submodules.sh` and `make archive` yourself
if you want those two checked before the real run.

### 2. Real release (only after reviewing the dry-run output)

```bash
bash scripts/release/create_release.sh v1.2.3
```

This runs the submodule preflight and `make archive`, then calls
`gh release create` and `glab release create` with the generated notes. It does
**not** create or push a git tag and does **not** attach the built archives as
release assets (no asset arguments are passed). Push the annotated tag first
(`git tag -a v1.2.3 ...`, push to every remote), otherwise the forges create the
tag on their default branch instead of on the release commit, and upload the
archives separately. For the 3.3.0 release the path is
[`release-3.3.0-checklist.md`](release-3.3.0-checklist.md), which does this by hand.

### 3. If either forge fails

Per Clarification 19, the whole release is not considered published. Fix
whatever caused the failure (rate limit, auth, network), then **re-run the
exact same command**:

```bash
bash scripts/release/create_release.sh v1.2.3
```

The script's per-forge state (recorded under
`~/.local/state/llmctl/release/` by default, or `LLMCTL_RELEASE_STATE_DIR`
if set) means the forge that already succeeded is skipped — only the failed
one is retried. This is proven by `tests/test_create_release.sh`'s
fail-then-retry scenario (a fake `gh`/`glab` pair standing in for the real
binaries, so the test never touches the real GitHub/GitLab).

## Version numbering (Clarification 5)

SemVer `MAJOR.MINOR.PATCH`, with an optional pre-release suffix, e.g.:

- `v1.0.0` — a stable release
- `v1.0.0-rc.1` — a release candidate
- `v1.0.0-beta.2` — a beta

Both a leading `v` and a bare `1.0.0` form are accepted by
`release_validate_semver`.

## Submodule preflight (Clarification 21)

Before anything is built, every pinned submodule ref — this repo's own
(`submodules/llama.cpp`, `submodules/colibri`) — is checked for genuine
reachability from its configured remote. Since 2026-10-21 `constitution`,
`containers` and `superspec` are resolved from the hub (`lib/resolve_deps.sh`),
not pinned by llmctl, so the preflight no longer walks the hub's nested set.

The check is a real `git fetch` into a throwaway scratch repository (never
mutating any of this repo's own submodule checkouts), bounded by a 30s
timeout (`PREFLIGHT_FETCH_TIMEOUT`, overridable), followed by a
`merge-base --is-ancestor` reachability check — this works against any git
host, since it never depends on a server supporting fetch-by-arbitrary-SHA
(many hosts, including GitHub by default, restrict that).

**Three honest outcomes, never conflated** (Constitution §11.4.201 — a
guard must assert the real condition):

- **reachable** — the pinned commit is genuinely present upstream.
- **confirmed unreachable** — the fetch succeeded (we genuinely reached the
  remote) but the pinned commit is genuinely absent from everything it
  advertised. This is the real FR-052 case (upstream deleted/rebased away
  the commit) and hard-fails the release, naming the exact submodule + ref.
- **could not verify** — the fetch itself failed (network/auth/DNS/host
  problem, or the bounded timeout elapsed). This is **not** evidence the
  ref is unreachable — only that this check could not run to completion —
  and is reported honestly as `UNKNOWN`, not misreported as a confirmed
  failure. (This distinction was a real bug found and fixed during this
  phase's own development: this sandbox has no outbound SSH access to
  GitHub, and the first implementation silently reported that as "ref
  unreachable" instead of "could not verify".) Both `FAIL` and `UNKNOWN`
  block the release — an unproven submodule never ships either way — but
  they are reported as the distinct findings they are.

## Release archive completeness (Clarification 4)

`git archive` (the mechanism the old `make archive` target used) is
fundamentally submodule-blind — verified empirically this session: it
emits an empty directory for every submodule, zero of any submodule's
actual file content, at any nesting depth. `build_archive.sh` instead does
a real filesystem-level `tar`/`zip` of the already-checked-out working
tree, which naturally includes every submodule's real content recursively
(a nested submodule is a git-level concept with no special filesystem
representation — it is just more files in more directories) plus the real
`.git` directory itself, so extracting the archive anywhere produces a
git repo that holds every pinned submodule (llama.cpp, colibri) — but NOT the resolved `containers`/`constitution`/`superspec` dependencies, so it is no longer buildable for the Go decision binary on its own (`docs/dependency-layout.md`) — proven by
`tests/test_archive_completeness.sh` against a real (small) fixture
submodule, including the decisive check that a relocated submodule's
relative `.git` gitdir pointer survives being extracted to a brand-new
path and that `git status`/`git log` work cleanly there. Build-output
directories (`*/build/*`) are excluded from both archive formats.

## Manual QA before tagging (Constitution §11.4.185)

Per this project's standing hybrid CI-fixture/release-gating pattern (see
`docs/quickstart.md`), every release additionally requires the manual live
verification procedure in `docs/quickstart.md` §2 and §4 to have been run
and recorded — an automated `--dry-run` GREEN is necessary, never
sufficient, for a release to actually ship.
