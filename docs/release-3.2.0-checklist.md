# llmctl v3.2.0 release checklist

| Field | Value |
|---|---|
| Revision | 1 |
| Created | 2026-10-12 |
| Status | prepared, **nothing in this list has been executed against a remote** (no bump, no tag, no push, no release) |
| Base | `8097ecc` (`main`, identical on codeberg, github, gitlab, gitverse and gitflic when measured 2026-10-12) |
| Content to integrate | `fix/validation-gate-complete` (model validation gate), `fix/bounded-restart-and-pressure-gates` (bounded restarts, per-profile memory caps, pressure start gate, one-engine-per-profile, registry/doctor fixes, oomd docs, eval-injection security fix), `feat/live-test-watchdog` |
| Version | `3.1.0` -> `3.2.0` (minor: new features plus fixes). Tags are un-prefixed-by-project: `vX.Y.Z` |
| Companion | `docs/release-3.1.0-checklist.md` (the model for this file), `docs/release-process.md`, `scripts/release.sh`, `scripts/release/bump_version.sh` |

Note on wording: this file avoids the literal pattern "llmctl" + space + digits on purpose, because `tests/test_version_consistency.sh`
fails on any `llmctl X.Y.Z` in `docs/*.md` that differs from `VERSION`. The historical 3.1.0 checklist was reworded to `llmctl vX.Y.Z` for the same reason.

All commands run from the repository root of the **release tree** (the tree that holds the merged result, not a feature worktree).
Anything that can exhaust memory is prefixed with the project's bounded scope, and the host is checked first (the host was force-powered-off
after a memory/IO stall on 2026-10-12):

```bash
head -2 /proc/pressure/memory        # STOP if any avg10 > 5
BOUNDED() { local t="$1"; shift; nice -n 19 ionice -c 3 systemd-run --user --scope --quiet -p TasksMax=300 -p MemoryMax=2G timeout "$t" "$@"; }
```

## 0. Measured state (2026-10-12, read-only)

| Item | Value |
|---|---|
| Local tags | `v2.0.0 v3.0.0 v3.0.1 v3.0.2 v3.1.0` (annotated; `v3.1.0` peels to `2467cc51c8dd6631062bf6121939360d68ec1ec9`) |
| `main` at base | `8097ecc20dd3a5faa50609f950c6283293039cc1`; one commit after `v3.1.0` (`Auto-commit`) |
| `git describe --tags --abbrev=0` | `v3.1.0`, so `create_release.sh` builds the changelog from `v3.1.0..HEAD` |
| Remote reachability | see the table in section 3: all five reachable over ssh; all five hold `v3.1.0` (re-checked 2026-10-13, `git ls-remote`: `f322aa0...` peeling to `2467cc5...` on every remote; gitflic earlier lacked it) |
| Repo size | `git count-objects -vH`: loose 15.50 MiB, one pack of 100.36 MiB. Largest reachable blobs: `archive/llmctl.zip` 45,950,200 B, `vendor/llama.cpp/models/ggml-vocab-gemma-4.gguf` 15,776,467 B, then 12.2 MB, 10.9 MB, 7.8 MB, 6.8 MB. **No single blob is >= 100 MiB** |
| Tools | `gh` at `/usr/bin/gh`, `glab` at `/snap/bin/glab` (snap-confined: files it reads must live under `$HOME`, not `/tmp`) |

## 1. Version pins (what "bump" means)

`tests/test_version_consistency.sh` reads `VERSION` and asserts: control needle works; `VERSION` is plain `X.Y.Z`; `bin/llmctl` `LLMCTL_VERSION="X.Y.Z"` equals it;
the **first** `## ` heading of `CHANGELOG.md` contains `X.Y.Z` and its section has `### Added`, `### Changed`, `### Fixed`, `### Security`, `### Removed`,
`### Migration notes`, `### Known limitations` and the keywords `llmctl-decide`, `decide scale`, `decide calibrate`, `probe-order`, `completions`, `maturity`,
`llmctl doctor`, `status --json`, `overhead_mb`, `LLMCTL_CTX_`, `eviction`; `README.md` contains `**Release X.Y.Z**`; **no** `llmctl X.Y.Z` in any `docs/*.md` differs from `VERSION`;
`specs/009-jev-decision-models/contracts/openapi.yaml` `info.version` is `X.Y.Z` or `X.Y.Z-draft`; `models/catalog.json` `"version"` is the integer `1`.

Pinned places measured at `8097ecc` (value `3.1.0` unless stated):

| Place | Edited by `bump_version.sh`? | Enforced by test? |
|---|---|---|
| `VERSION` | yes | yes (source of truth) |
| `bin/llmctl:7` `LLMCTL_VERSION`; `llmctl version` prints it | yes | yes, plus `tests/test_cli.sh` |
| `README.md:67` banner `**Release 3.1.0**` | yes | yes |
| `README.md:12` (llama.cpp pin sentence "3.1.0 pin") and `:75` ("Platform \| Status in 3.1.0") | **no, prose** | no |
| `docs/architecture.md:234`, `docs/faq.md:25`, `docs/limitations.md:1`, `docs/ports.md:3`, `docs/user-manual.md:722,724` (the string "llmctl", a space, then the version) | yes | yes |
| `docs/runbooks.md:237` (contains that same string) | yes (matched by the same pattern) | yes |
| `specs/009-jev-decision-models/contracts/openapi.yaml:4` `info.version` (already `3.1.0`, not `-draft`) | yes | yes |
| `docs/calibration-tool-fields.md:3,44` ("contract version", "is versioned") | yes | no |
| `CHANGELOG.md` new top section `## 3.2.0 (YYYY-MM-DD)` with all required sub-headings | **no, manual** | yes |
| `docs/*.md` prose "in 3.1.0" without the `llmctl ` prefix (`user-manual.md:226,425,702`, `validation.md:49,68`, `limitations.md:46`, `faq.md:521,537,577`, `cluster-architecture.md:24`, `cloud-exposure.md:124`, `architecture.md:344`, `qa/README.md:13`) | no | no (these describe what 3.1.0 did; review each, most stay) |
| `docs/release-3.1.0-checklist.md`, `GATES.md` (v3.1.0 gate list), `specs/009-*/` text | no | no (historical) |
| `llmctld/cmd/llmctld/main.go:179` `const version = "0.1.0"` | no | no: separate module, "tracked independently"; operator decision whether to align |
| `models/catalog.json` `"version": 1`, Go `ProfileVersion = 1`, `templateHashVersion = "llmctl-decide-template/1"`, Prometheus `version=0.0.4` | no | catalog integer only: schema/protocol numbers, not the release |
| `go.mod` (module path only), `lib/service_linux.sh`, `lib/service_macos.sh`, `templates/*` (systemd/launchd): no release version | n/a | n/a (grep for `3.1.0` finds nothing) |
| `tests/test_planner.sh:312-339` compares against git tag `v3.0.2` catalog | no | unrelated to the bump; needs tag `v3.0.2` to exist locally |
| `scripts/release/create_release.sh:139` comment mentioning a `v3.0.2` attempt | no | comment only |

`scripts/release/bump_version.sh` (new, in this commit) automates the "yes" rows. It is a dry run unless `--apply` is given, refuses a same or older version, fails
if any pin is not found, never commits, tags or pushes. Proven on a scratch copy of the tree (VERSION 3.1.0): dry run lists 12 lines, `--apply` rewrote them, with a
hand-added CHANGELOG section `tests/test_version_consistency.sh` printed `RESULT: PASS`, and a second run refused with `VERSION is already 3.2.0`.

## 2. Release-day order (every step must hold before the next)

Steps marked **GATE** need the operator's explicit go-ahead **at that moment** (see section 8). Nothing here is run by an agent on its own judgement.

1. **Integrate** the three feature branches into the release branch (merge, never rebase of shared history, never force). Resolve conflicts in the merge commit.
   Re-run `head -2 /proc/pressure/memory` first.
2. **Bump**: `bash scripts/release/bump_version.sh 3.2.0` (review), then `--apply`. Then write the `CHANGELOG.md` `## 3.2.0 (<date>)` section by hand above `## 3.1.0`
   (Added / Changed / Fixed / Security: the eval-injection fix, state exactly what it closed / Removed / Migration notes: per-profile memory caps, bounded restarts,
   one-engine-per-profile, pressure start gate / Known limitations, including anything not verified live). Update the README prose rows from section 1 and
   `docs/release-process.md` only if the process changed. Commit as `release: 3.2.0` with the trailer.
3. **Gates** (bounded, host-safe):
   ```bash
   BOUNDED 300  bash tests/test_version_consistency.sh
   BOUNDED 300  bash tests/test_release_scripts.sh
   BOUNDED 300  bash tests/test_create_release.sh
   BOUNDED 600  bash tests/test_release_no_secrets.sh
   BOUNDED 3600 make validate
   BOUNDED 1800 bash constitution/scripts/validation/run_verification.sh
   BOUNDED 1800 bash constitution/scripts/validation/meta_test_verification.sh
   ```
   Plus the feature-specific tests each branch added (list them from the merged diff; each must be named in the CHANGELOG with its result).
4. **Independent review (Helix 11.4.142)** of the merged diff, including the one-line doc edits, on a reviewer that did not write the code. Self-review does not count. Record the verdict.
5. **Submodule pins** (own-org `submodules/containers` must be on its remote; third-party pins are not checked): same commands as section 1.6 of the 3.1.0 checklist.
6. **Archive scan**: `archive/llmctl.zip` is still tracked (45,950,200 B). `public_allowlist.txt` already carries `idea-arch` entries (4 matching lines measured), so the 3.1.0 finding looks resolved;
   confirm by running `scan_archive.py` on the real archive in step 12 (exit 0). If it fails, the allowlist vs. untracking-the-zip choice is the operator's (Helix 11.4.122).
7. **Fetch and merge onto latest main** (Helix 11.4.71/11.4.113): `git fetch --all --prune`; for each of the five remotes the remote `main` must be an ancestor of `HEAD`
   (loop in section 3). If any is not, merge that remote's `main` into the release branch (no rebase, no force), re-run steps 3 and 4 on the new HEAD.
   Release branch must be `main` (or fast-forwarded into `main`) and `git status --short` empty.
8. **Push-size check (gitflic cap)**, section 4. Do this before the push.
9. **GATE: push `main`** ff-only to all five push URLs (section 5), `ls-remote` verified per remote. **No tag leaves the machine before every remote shows the release commit on `main`.**
10. **Annotated tag** `v3.2.0` on exactly the pushed commit: `git tag -a v3.2.0 -m "llmctl v3.2.0" HEAD`; `git cat-file -t refs/tags/v3.2.0` prints `tag`;
    `git rev-parse 'v3.2.0^{commit}'` equals `git rev-parse HEAD`. Creating the tag locally is not a GATE; pushing it is (next step).
11. **GATE: push the tag** to all five, verify peel per remote (section 5).
12. **Assets** (writes under `$HOME`, not the tree):
    ```bash
    OUT="$HOME/llmctl-release-3.2.0"; mkdir -p "$OUT"
    BOUNDED 600 bash scripts/release.sh --out "$OUT" --tag v3.2.0 all            # verify-tag, archive, sbom, notice, checksums
    BOUNDED 60  bash scripts/release.sh --out "$OUT" --tag v3.2.0 checksums --verify
    BOUNDED 60  bash scripts/release.sh --out "$OUT" --tag v3.2.0 assets          # every line "present"
    python3 -I scripts/release/scan_archive.py --allow scripts/release/public_allowlist.txt "$OUT/llmctl-v3.2.0.tar.gz"   # exit 0
    awk '/^## 3\.2\.0 /{f=1} f&&/^## /&&!/^## 3\.2\.0 /{exit} f' CHANGELOG.md > "$OUT/RELEASE_NOTES.md"
    test -s "$OUT/RELEASE_NOTES.md" && head -3 "$OUT/RELEASE_NOTES.md"
    ```
    `release.sh verify-tag` needs the tag to exist, be annotated, peel to HEAD and the tracked tree to be clean, so this step comes after step 10. Run from the real tree with submodules
    initialised so the SBOM reads licences (a clone prints `NOASSERTION`). `release.sh archive` is reproducible: run it twice and compare the sha256 (3.1.0 did).
13. **Dry run of the other publisher**: `bash scripts/release/create_release.sh --dry-run v3.2.0` (**pass the leading `v`**, see section 6 hazards). Read-only; nothing remote.
14. **GATE: forge releases** with `gh` and `glab` (section 6). Use `release.sh`'s assets and explicit commands, not `create_release.sh`, which uploads no assets.
15. **Post-release verification** (section 7) and write the outcome into the release notes or an evidence file.

## 3. Remote reachability and per-remote ff check

Read-only `git ls-remote` measured 2026-10-12 from this host:

| Remote (push URL) | Reachable | `refs/heads/main` | Latest tag present | Latest tag object / peeled commit |
|---|---|---|---|---|
| codeberg `ssh://git@codeberg.org/vasic-digital/llmctl.git` | yes | `8097ecc20dd3a5faa50609f950c6283293039cc1` | `v3.1.0` | `f322aa0279a310fc1c853dcd4be9802b8aa339dc` / `2467cc51c8dd6631062bf6121939360d68ec1ec9` |
| gitflic `git@gitflic.ru:vasic-digital/llmctl.git` | yes (prints an ssh post-quantum KEX warning, harmless) | `8097ecc20dd3a5faa50609f950c6283293039cc1` | `v3.1.0` (was missing on 2026-10-12; present on 2026-10-13) | `f322aa0...` / `2467cc5...` (re-checked 2026-10-13 with `git ls-remote`) |
| github `git@github.com:vasic-digital/llmctl.git` | yes | `8097ecc20dd3a5faa50609f950c6283293039cc1` | `v3.1.0` | `f322aa0...` / `2467cc5...` |
| gitlab `git@gitlab.com:vasic-digital/llmctl.git` | yes | `8097ecc20dd3a5faa50609f950c6283293039cc1` | `v3.1.0` | `f322aa0...` / `2467cc5...` |
| gitverse `git@gitverse.ru:vasic-digital/llmctl.git` | yes (the 3.1.0 `GATES.md` recorded it unreachable; it answered today) | `8097ecc20dd3a5faa50609f950c6283293039cc1` | `v3.1.0` | `f322aa0...` / `2467cc5...` |

Resolved 2026-10-13: `git ls-remote <remote> refs/tags/v3.1.0 'refs/tags/v3.1.0^{}'` shows `f322aa0279a310fc1c853dcd4be9802b8aa339dc` peeling to `2467cc51c8dd6631062bf6121939360d68ec1ec9` on **all five** remotes, gitflic included. The earlier gap (cause never established, UNKNOWN) is closed; no tag push is needed and G6 is moot. Re-run the `ls-remote` immediately before the release push, the remotes can change.

Fast-forward check, run in step 7 (re-run immediately before the push; the remote can move):

```bash
for r in codeberg gitflic github gitlab gitverse; do
  m="$(git ls-remote "$r" refs/heads/main | cut -f1)"
  if [ -n "$m" ] && git merge-base --is-ancestor "$m" HEAD; then echo "$r ff-ok ($m)"; else echo "$r NOT-FF-OR-UNREADABLE ($m)"; fi
done
```

Every line must say `ff-ok`; otherwise STOP and merge the moved remote `main` into the release branch. `git push origin` fans out to all five push URLs, but a per-remote loop (section 5) shows which one failed.

## 4. Push-size check (gitflic accepts at most 100 MiB per push)

Measured 2026-10-12: the whole local pack is 100.36 MiB, so **a full-history push (new empty repo, mirror, or re-seed) would exceed the cap**. An incremental push of `main` where the remote already
holds `8097ecc` sends only objects not reachable from it. No reachable blob is >= 100 MiB (largest 45,950,200 B), so no single object can break the cap. Measure the actual push before it happens:

```bash
for r in codeberg gitflic github gitlab gitverse; do
  m="$(git ls-remote "$r" refs/heads/main | cut -f1)"
  printf '%-9s %s bytes\n' "$r" "$(git rev-list --objects "^$m" HEAD | git pack-objects --stdout --revs 2>/dev/null </dev/null | wc -c)"
done
```

(Both this form and `git rev-list --objects ^$m HEAD | cut -d' ' -f1 | git pack-objects --stdout | wc -c` ran read-only at `HEAD == 8097ecc` and printed 32 bytes, an empty pack, which is the correct answer for "nothing to send".)
Expected: a few MiB for three feature branches of scripts, docs and Go code. If any remote's number is above 90 MiB, STOP: do not split or force; ask the operator (options: push in
several ancestor-ordered steps `git push gitflic <sha>:refs/heads/main`, each ff and each below the cap). A new large binary added by a feature branch is the thing to look for first:
`git diff --stat 8097ecc..HEAD | sort -k3 -n | tail`.

## 5. Push (ff-only, never forced) and verify per remote

> **OPERATOR GATE (interactive).** Do not start until the operator has seen: the release commit hash, the section 3 `ff-ok` lines for all five remotes, the section 4 sizes, the step 3 gate
> results and the step 4 review verdict, and has confirmed **in this session** that the push may proceed. A past approval does not carry over.

```bash
set -euo pipefail
REMOTES="codeberg gitflic github gitlab gitverse"
# 1. main first, every remote; the first failure aborts. A non-ff rejection is a STOP, never a retry with force.
for r in $REMOTES; do echo "== push main -> $r"; git push "$r" main; done
# 2. every remote must show the release commit on main BEFORE any tag leaves this machine
REL="$(git rev-parse HEAD)"
for r in $REMOTES; do
  m="$(git ls-remote "$r" refs/heads/main | cut -f1)"
  [ "$m" = "$REL" ] || { echo "ABORT: $r main=$m != $REL (no tag pushed)"; exit 1; }
done
```

Then (second operator confirmation not required if the same message approved "push main and tag", but the `ls-remote` check above must have passed) the tag:

```bash
for r in $REMOTES; do git push "$r" refs/tags/v3.2.0; done
REL="$(git rev-parse HEAD)"; TAGOBJ="$(git rev-parse refs/tags/v3.2.0)"
for r in codeberg gitflic github gitlab gitverse; do
  m="$(git ls-remote "$r" refs/heads/main | cut -f1)"
  t="$(git ls-remote "$r" refs/tags/v3.2.0 | cut -f1)"
  p="$(git ls-remote "$r" 'refs/tags/v3.2.0^{}' | cut -f1)"
  printf '%-9s main=%s tag=%s peeled=%s  ' "$r" "${m:0:9}" "${t:0:9}" "${p:0:9}"
  [[ "$m" == "$REL" && "$t" == "$TAGOBJ" && "$p" == "$REL" ]] && echo OK || echo MISMATCH
done
```

Every remote must print `OK`. A remote that rejects (non-ff, hook, size, permission): stop, report, do not force; see rollback.

## 6. Forge releases: GitHub and GitLab (assets, checksums, SBOM)

> **OPERATOR GATE (interactive).** Public and only partly reversible. Do not start until the operator has seen the section 5 `OK` lines for all five remotes, `RELEASE_NOTES.md`, and the
> asset checksums, and confirmed **in this session**. Notes must carry the CHANGELOG "Known limitations" and any operator waiver (manual QA gate) verbatim, not as a pass.

Assets from step 12 under `$OUT`: `llmctl-v3.2.0.tar.gz`, `llmctl-v3.2.0.sbom.cdx.json` (CycloneDX 1.5), `NOTICE-THIRD-PARTY.txt`, `SHA256SUMS` (+ `SHA256SUMS.asc` if `LLMCTL_RELEASE_SIGN=1` and gpg exist).
GitHub's per-asset limit is 2 GB; the 3.1.0 tracked-files archive was about 64 MB.

```bash
cd "$OUT"
# glab release create CREATES a missing tag; the tag was pushed in section 5, so prove it is there and is the release commit:
git ls-remote gitlab refs/tags/v3.2.0 | grep -q . || { echo "ABORT: gitlab has no v3.2.0 tag"; exit 1; }
git ls-remote gitlab 'refs/tags/v3.2.0^{}' | cut -f1 | grep -qx "$(git -C <release-tree> rev-parse HEAD)" || { echo "ABORT: gitlab v3.2.0 is not the release commit"; exit 1; }

gh release create v3.2.0 llmctl-v3.2.0.tar.gz llmctl-v3.2.0.sbom.cdx.json NOTICE-THIRD-PARTY.txt SHA256SUMS \
  --repo vasic-digital/llmctl --verify-tag --title v3.2.0 --notes-file RELEASE_NOTES.md
glab release create v3.2.0 llmctl-v3.2.0.tar.gz llmctl-v3.2.0.sbom.cdx.json NOTICE-THIRD-PARTY.txt SHA256SUMS \
  --repo vasic-digital/llmctl --name v3.2.0 --notes-file RELEASE_NOTES.md --no-update
```

Hazards found in the existing tooling (measured by reading and dry-running 2026-10-12):

* `create_release.sh --dry-run 3.2.0` printed `gh release create 3.2.0 ...` : **the tag is taken verbatim from the argument**. A bare `3.2.0` would publish a tag `3.2.0`, not `v3.2.0`. Always pass `v3.2.0`.
* `create_release.sh` attaches **no assets**, has no `--verify-tag`, and its dry-run text shows `glab ... --title` although the real code uses `--name` for glab. The dry run does **not** run the submodule preflight
  or `make archive` (it only prints "would run"), so a green dry run proves SemVer parsing, changelog generation and nothing else. Its changelog, for the tree measured today (`v3.1.0..HEAD`), is a single line `Auto-commit`.
* `release.sh --publish` prints a `glab` line without `--no-update`; use the commands above. `release.sh all` does not write `RELEASE_NOTES.md`.
* The notes file and assets must be under `$HOME` (snap-confined `glab` cannot read `/tmp`).
* Use one publisher, not both. If a forge fails, re-run only that forge's command (`create_release.sh` keeps per-forge state under `~/.local/state/llmctl/release/`, `release.sh` does not).
* Cautious rollout option: add `--prerelease` to `gh` (and mark GitLab manually) if the operator prefers.

## 7. Post-release verification

```bash
gh release view v3.2.0 --repo vasic-digital/llmctl --json tagName,name,isPrerelease,assets --jq '{tagName,name,isPrerelease,assets:[.assets[]|{name,size}]}'
glab release view v3.2.0 --repo vasic-digital/llmctl
V=$(mktemp -d "$HOME/llmctl-verify.XXXXXX"); cd "$V"
gh release download v3.2.0 --repo vasic-digital/llmctl && sha256sum -c SHA256SUMS            # every line OK
mkdir gh && tar -xzf llmctl-v3.2.0.tar.gz -C gh && cat gh/llmctl-v3.2.0/VERSION               # 3.2.0
mkdir gl && (cd gl && glab release download v3.2.0 --repo vasic-digital/llmctl && sha256sum -c SHA256SUMS)
cmp llmctl-v3.2.0.tar.gz gl/llmctl-v3.2.0.tar.gz && echo "github == gitlab asset"
sha256sum "$OUT"/llmctl-v3.2.0.tar.gz                                                          # equals the pre-upload sum in "$OUT/SHA256SUMS"
for r in codeberg gitflic github gitlab gitverse; do                                           # tag peels to the release commit on EVERY remote
  printf '%-9s %s\n' "$r" "$(git ls-remote "$r" 'refs/tags/v3.2.0^{}' | cut -f1)"; done      # all equal git rev-parse HEAD of the release tree
```

Expected: both `view` commands succeed with 4 assets (5 with a signature); checksums `OK` on both forges; archive identical across forges; the same peeled SHA on all five remotes. Engine-dependent suites
inside the tracked-files archive SKIP (submodule content is not in it); report SKIPs as skips.

## 8. Operator gates (anything that publishes needs an explicit go-ahead at that moment)

| # | Action | Why gated |
|---|---|---|
| G1 | Merging the three feature branches into the release branch / `main` | decides release content |
| G2 | Choosing the version number (3.2.0 is a proposal) and the CHANGELOG wording, including the eval-injection security note | public statement |
| G3 | Archive-scan decision (allowlist line vs. untracking `archive/llmctl.zip`) | removing a shipped file, Helix 11.4.122 |
| G4 | `git push <remote> main` to the five remotes | external, not undoable without force |
| G5 | `git push <remote> refs/tags/v3.2.0` | a pushed tag must never be moved |
| G6 | (moot since 2026-10-13: `v3.1.0` is present on gitflic) | - |
| G7 | `gh release create` / `glab release create` | public, partly reversible |
| G8 | Any `gh release edit/delete`, `glab release delete`, tag deletion, asset replacement | history-visible |
| G9 | Manual-QA waiver wording (constitution gate 11.4.185 was operator-waived in 3.1.0, not satisfied) | must not be described as passed |

A past "go ahead" does not carry over to a later gate. No agent runs G4 to G8 on its own judgement. `create_release.sh` without `--dry-run`, `release.sh --publish` with `LLMCTL_RELEASE_PUBLISH=1`,
and any `git push` are all inside the gated set.

## 9. Rollback and abort

* **Before step 9 (nothing pushed):** `git tag -d v3.2.0` if created; discard `$OUT`; revert the bump with a new commit (`git revert`), never a history rewrite.
* **A forge rejects the push** (non-ff, hook, size, permission): stop; `git fetch <remote>`; merge that remote's `main` into the release branch (never rebase, never force); delete the **unpushed** local tag and recreate it on the new HEAD; re-run steps 3, 4, 7, 8; push again. All remotes must hold the same `main` before any tag is pushed.
  If gitflic refuses for size, see section 4; do not use any force or `+ref`.
* **After the tag is pushed, before releases:** never delete or move the tag; if the content is wrong, fix forward as `v3.2.1`.
* **After forge releases:** hide a release without touching history: `gh release edit v3.2.0 --prerelease` or `gh release delete v3.2.0` (tag stays); `glab release delete v3.2.0`. Deleting a published tag is a G8 action.
* **Partial publish** (GitHub ok, GitLab failed): re-run only the failed forge's command with the same assets and notes; then repeat section 7.
* **Asset mismatch in section 7:** do not re-upload under the same name silently: delete the bad asset on that forge, upload the verified one, repeat section 7, and note it in the release notes.

## 10. Open items this checklist cannot close

| Item | Why |
|---|---|
| Content of the three feature branches in the CHANGELOG | not merged at preparation time; the lead writes the section after integration |
| Which feature-specific tests exist and pass | unknown until the merge; step 3 requires listing and running them |
| `challenges/scripts/*` (host-safety challenge named in the notes repo CLAUDE.md) | the directory does not exist in this repo at `8097ecc`; nothing to run |
| gitflic missing `v3.1.0` | resolved 2026-10-13 (present, same peel); the cause of the earlier gap stays UNKNOWN |
| Whether the scan is clean on the real 3.2.0 archive | only known after step 12 |
| `llmctld` version `0.1.0` alignment | operator decision |
| Reviewer identity | Helix 11.4.209 asks for the Fable model at xhigh effort; step 4 must name the reviewer and model |
