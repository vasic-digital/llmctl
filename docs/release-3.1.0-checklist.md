# llmctl 3.1.0 release checklist

| Field | Value |
|---|---|
| Revision | 3 |
| Created | 2026-10-09 |
| Status | prepared, **nothing in this list has been executed against a remote** (no tag, no push, no release) |
| Tasks | T123 (versions), T126 (release scripts), T127 (tag, push, forge releases), T136, T139, T142 |
| Companion | `CHANGELOG.md` section `3.1.0` (date placeholder `YYYY-MM-DD (set at tag time)`) |

Every command below runs from the repository root unless stated. Anything that can exhaust memory is
prefixed with the project's bounded scope (`systemd-run --user --scope --quiet -p TasksMax=300 -p MemoryMax=2G timeout N`,
abbreviated here as `BOUNDED N`):

```bash
BOUNDED() { local t="$1"; shift; systemd-run --user --scope --quiet -p TasksMax=300 -p MemoryMax=2G timeout "$t" "$@"; }
```

A step marked **(measured 2026-10-09)** carries output that was produced while preparing this file; the
others are instructions that have not been run.

## 0. State at preparation time (measured 2026-10-09)

| Item | Value |
|---|---|
| HEAD at preparation | `c5301defb73a949536fe741b597d3bd089df4109` (`main`, 2026-10-08T18:45:52+02:00) |
| Working tree | At preparation: 54 uncommitted entries. Since then batches 1-6 below are committed (`2f6cd1f` evidence, `5184565` gateway + server stream + golden runner, `6eb2e0c` planner, `c2f0c91` host safety, `c00da7b` live-NLI runner). What remains uncommitted is batch 7 (docs, closure and release bookkeeping, this checklist, `evidence/g155/`); recount with `git status --short` |
| Tags | `v2.0.0 v3.0.0 v3.0.1 v3.0.2` locally; **no `v3.1.0`** |
| Remote `main` (all five push remotes) | `f1a22eab816dcb1af5d2ba52e9e5b69a65f15c3f` (`git ls-remote <remote> refs/heads/main`, identical on codeberg, gitflic, github, gitlab, gitverse) |
| Fast-forward possible? | yes: `git merge-base --is-ancestor f1a22ea HEAD` is true; HEAD is **16 commits ahead** of every remote |
| `origin` | fetch `github`, push URLs: codeberg, gitflic, github, gitlab, gitverse (one `git push origin` fans out to all five) |
| `gh auth status` | authenticated to github.com (account `milos85vasic`, ssh protocol, token scopes `admin:public_key gist read:org repo`) |
| `glab auth status` | authenticated to gitlab.com (user `milos85vasic`, ssh for git, https API) |
| codeberg / gitflic / gitverse | git push over ssh only; no forge-release step is planned for them (T127 names `gh` and `glab` only) |

### Submodule state (own-org: `submodules/containers`; `constitution` is HelixDevelopment's)

| Submodule | Pinned commit | Evidence |
|---|---|---|
| `submodules/containers` (vasic-digital/Containers) | `4a8f04e05f3535d77c48f69b89687f9fcc896fbf` | `git -C submodules/containers status -sb` prints `## main...origin/main` (clean, not ahead); `git ls-remote git@github.com:vasic-digital/Containers.git` lists the pinned commit (2 matching refs) |
| `constitution` (HelixDevelopment/HelixConstitution) | `3e8e85556b14d7c5f3ea3f8f5551213c34ddf8ce` | detached HEAD at the pin; the pin is contained in the local remote-tracking `origin/main` and the other five constitution remotes' `main` **as last fetched**; `git ls-remote` shows the remote `main` has since moved to `853fa64f1a9e1bb362924dff3e342c36da13c426`, an object not present locally, so ancestry against the live tip is **UNCONFIRMED** (see step 1.6) |
| `submodules/llama.cpp` (ggml-org), `colibri` (JustVugg), `superspec` (WangX0111) | `1537a0a8b` (= tag `b11379`, `git describe --contains`), `f028d26b4`, `c20ac6c1b` | third-party; not checked against their remotes |

## 1. Preconditions (all must hold before step 3)

1. **Commit the working tree as reviewed commits.** Batches 1-6 are committed; batch 7 is the remainder (each batch must pass the independent review the
   project requires, Helix 11.4.142, before it is accepted):
   1. **Live-model evidence**: committed in `2f6cd1f` (anton and nezha runs, `anton-runner/`, `evidence/live/decide-kev-4b/cpu-mode-vram-live-2026-10-08.txt`).
   2. **Gateway letter-logit and resolver (G-155, port override), deadline / server stream (G-156, G-160)**: committed in `5184565`
      (`letter.go` + `letter_test.go`, `resolver.go` + `resolver_test.go`, `internal/server/handlers.go` + `server_test.go`, `scripts/golden/run_golden.py` +
      `tests/py/test_golden_runner.py`, `docs/decide-gateway.md`, `contracts/openapi.yaml`, `contracts/env-vars.md`, mutation rows in `tests/test_gateway_mutation.sh`).
      The G-155 failing-first run is **CONFIRMED** in `specs/009-jev-decision-models/evidence/g155/failing-first-2026-10-09.txt`: `TestLetterRequestDisablesThinking`
      FAILS against `letter.go` from `5184565~1` and passes against `5184565`.
   3. **Planner / catalog (G-138)**: committed in `6eb2e0c` (`lib/catalog.sh`, `models/catalog.json`, `scripts/overhead_from_memory.py`,
      `tests/py/test_overhead_from_memory.py`, `tests/test_planner.sh`, `docs/hardware-tiers.md`, `evidence/memory-wiring-proposal.md`).
   4. **Host safety**: committed in `c2f0c91` (`scripts/hostsafety/`, `docs/host-safety.md`, `tests/test_hostsafety.sh`, `tests/hostsafety_guard_fixtures.py`).
   5. **Live-NLI runner**: committed in `c00da7b` (`evidence/realcheck/run_live_nli.sh`, `tests/test_run_live_nli.sh`).
   6. (merged into batch 2 above; kept as a number so earlier references stay valid.)
   7. **Docs, closure and release bookkeeping (still to commit)**: `README.md`, `docs/decision-models.md`, `docs/faq.md`,
      `specs/009-jev-decision-models/**` bookkeeping (gaps register, sc004 files, tasks, spec, quickstart, `evidence/g155/`), `CHANGELOG.md` and this checklist.
   `git status --short` must then be empty (the release script refuses a dirty tracked tree, and untracked files are **not** in the archive).
   **Stale-wording sweep before tagging** (CHANGELOG and docs must not carry text that was true only while the tree was dirty):
   `grep -rn -e '<COMMIT-SHA>' -e 'uncommitted' -e 'not yet committed' CHANGELOG.md docs README.md specs/009-jev-decision-models/*.md specs/009-jev-decision-models/evidence/*.md`
   must list no line that describes the *current* tree as uncommitted or still carries the `<COMMIT-SHA>` placeholder (as of the batch-7 edit there is no
   placeholder). Remaining hits are historical and correct: runs made on "HEAD `c5301de` + uncommitted" trees, the nezha snapshot sentence, and this paragraph.
2. **Residual draft markers.** `grep -rn "3.1.0-draft" --exclude-dir=.git --exclude-dir=submodules --exclude-dir=constitution --exclude=release-3.1.0-checklist.md .` lists exactly
   `contracts/openapi.yaml:4`, `docs/calibration-tool-fields.md` (two lines) and the two CHANGELOG sentences handled by step 2.
3. **Gates** (the CHANGELOG lists them; none was run by this preparation except where marked):
   ```bash
   BOUNDED 3600 make validate                                   # json-check + lint + test (+ llmctld targets when LLMCTL_CLUSTER_MODE=1)
   BOUNDED 1800 bash constitution/scripts/validation/run_verification.sh
   BOUNDED 1800 bash constitution/scripts/validation/meta_test_verification.sh
   BOUNDED 300  bash tests/test_version_consistency.sh           # PASS measured 2026-10-09 on the current tree
   BOUNDED 300  bash tests/test_release_scripts.sh               # PASS measured 2026-10-09
   BOUNDED 600  bash tests/test_release_no_secrets.sh
   ```
4. **Spec closure is honest.** `specs/009-jev-decision-models/tasks.md` still lists as open: T061, T064, T065, T068 (live runs), T124 (readiness verdict),
   T126 and T127 (marked open at the last reconciliation although the release script exists and is dry-run only), T128 (final independent review), T129,
   T136, T139, T142. Do not tick any of them without the evidence named in the task. T136: the only `traceability.md` match for "not in 3.1.0" is a line that already says
   `DONE` for T132 to T135, so the markers look already reverted; re-check with `grep -rn "planned, not in 3.1.0" docs specs/009-jev-decision-models/contracts specs/009-jev-decision-models/traceability.md CHANGELOG.md`
   (measured: no remaining occurrence in `docs/`, `contracts/`, `CHANGELOG.md`) and tick T136 if that is still empty.
5. **Manual QA.** The constitution gate (section 11.4.185) is operator-waived, not satisfied (CHANGELOG "Release status"). Record the waiver in the release notes; do not describe it as passed.
6. **Submodule pins exist on their remotes** (own-org):
   ```bash
   git -C submodules/containers status -sb            # expect: ## main...origin/main   (not ahead)
   git ls-remote git@github.com:vasic-digital/Containers.git | grep 4a8f04e05f3535d77c48f69b89687f9fcc896fbf   # expect >= 1 line
   git -C constitution fetch origin
   git -C constitution merge-base --is-ancestor 3e8e85556b14d7c5f3ea3f8f5551213c34ddf8ce origin/main && echo pin-reachable
   ```
7. **Open operator decisions that change the release content** (not blockers by themselves): G-156 (default `LLMCTL_DECIDE_TIMEOUT` 8 s on CPU engines), G-157 (`decide` `mass_threshold`),
   G-158 (`decide-max` never run), G-159 (planner overhead wiring), G-160 (golden harness counts `max_options` refusals as malformed), T142 (the profiles the scheduler first refused: `decide-lev` and `decide-kev-4b` later RAN on the dev host, commit `0197297`; `decide-kev-9b` and the final-values `decide-kev-08b` run still need RAM/VRAM headroom). The CHANGELOG states each as open.
8. **Archive scan finding (measured 2026-10-09) — decide before tagging.** `scripts/release.sh archive` packs every *tracked* file, including `archive/llmctl.zip`
   (45,950,200 bytes, tracked since `f4b5754`, 72% of the 63,954,958-byte archive). The independent scanner reports a secret-looking path inside that nested zip:
   ```text
   $ python3 -I scripts/release/scan_archive.py --allow scripts/release/public_allowlist.txt $OUT/llmctl-v3.1.0.tar.gz
   build_archive: SECRET PATH in tar.gz>archive/llmctl.zip: vendor/llama.cpp/docs/development/llama-star/idea-arch.key
   scan-rc=1
   ```
   It is a Keynote file in a vendored copy of llama.cpp (not a credential), and with this exact nested exemption appended the scan is clean (`scan-rc=0`):
   `archive/llmctl.zip!vendor/llama.cpp/docs/development/llama-star/idea-arch.key` (the allowlist syntax for a path inside a nested archive is `<outer>!<inner>`).
   `scripts/release.sh` does **not** run the scanner, so the dry-run below passes while the scanner would not. Options, operator's call: (a) add that one exact line to
   `scripts/release/public_allowlist.txt`; (b) stop tracking `archive/llmctl.zip` (removing a shipped file needs the operator's explicit decision, Helix 11.4.122/11.4.124, and shrinks the asset to about 18 MB).
   Whether `make archive` (the self-contained archive) passes the same scan is **UNCONFIRMED**: building it here was killed at the `zip` stage under a 4 GiB cgroup cap (the finished `tar.gz` was 2.19 GB, above GitHub's 2 GB per-file release-asset limit), so it is not in the asset set below.

## 2. Tag-time flip of the `-draft` markers (T123)

Versions carried in the tree, measured 2026-10-09:

| Place | Value | State |
|---|---|---|
| `VERSION` | `3.1.0` | final |
| `bin/llmctl` `LLMCTL_VERSION`; `llmctl version` prints `llmctl 3.1.0` | `3.1.0` | final (asserted equal to `VERSION` by `tests/test_cli.sh` and `tests/test_version_consistency.sh`) |
| `README.md` banner `**Release 3.1.0**` | `3.1.0` | final |
| `docs/architecture.md:234`, `faq.md:25`, `limitations.md:1`, `ports.md:3`, `user-manual.md:705,707` ("llmctl 3.1.0") | `3.1.0` | final (test fails on any other `llmctl X.Y.Z` in `docs/*.md`) |
| `CHANGELOG.md` heading `## 3.1.0 (YYYY-MM-DD (set at tag time))` | `3.1.0` | **date placeholder** until step 2 |
| `specs/009-jev-decision-models/contracts/openapi.yaml:4` `info.version` | `3.1.0-draft` | **DRAFT** (not flipped; the test accepts either) |
| `docs/calibration-tool-fields.md:3,44` ("contract version `3.1.0-draft`", "is versioned `3.1.0-draft`") | `3.1.0-draft` | **DRAFT**, follows the contract |
| CHANGELOG sentences "keeps `info.version: 3.1.0-draft` until the tag is cut" (Known limitations) and "The OpenAPI contract is `3.1.0-draft` until the tag is cut" (Release status, Version bullet) | text | must be removed at the flip |
| `models/catalog.json` `"version"` | `1` | the schema number, **not** the release version (test asserts the integer) |
| `llmctld/cmd/llmctld/main.go:179` `const version` | `0.1.0` | **not 3.1.0**: separate module, source comment says "tracked independently"; `llmctld --version` prints `llmctld 0.1.0`. Operator decision whether to align; not enforced by any test |
| Go constants `ProfileVersion = 1`, `templateHashVersion = "llmctl-decide-template/1"`, `ContentType ...version=0.0.4` | | protocol/schema versions, unrelated to the release |
| systemd / launchd templates | none | no release version appears in `lib/service_linux.sh`, `lib/service_macos.sh` or `templates/` (grep for `3.1.0` / `3.0.2` finds nothing there) |
| `go.mod` | module path only | no release version |

The flip (run on the release commit's parent, **after** step 1, then commit as `release: 3.1.0`):

```bash
V="$(tr -d '[:space:]' < VERSION)"; D="$(date -u +%F)"
# 1. OpenAPI contract + the doc that quotes it
sed -i -E "s/^(  version: )${V//./\\.}-draft[[:space:]]*$/\1${V}/" specs/009-jev-decision-models/contracts/openapi.yaml
sed -i "s/contract version \`${V}-draft\`/contract version \`${V}\`/; s/is versioned \`${V}-draft\`/is versioned \`${V}\`/" docs/calibration-tool-fields.md
# 2. CHANGELOG: release date; drop the two sentences that say the contract is still a draft
sed -i "s/^## ${V//./\\.} (YYYY-MM-DD (set at tag time))\$/## ${V} (${D})/" CHANGELOG.md
sed -i '/^- The OpenAPI contract `specs\/009-jev-decision-models\/contracts\/openapi.yaml` keeps `info.version: .*-draft` until the tag is cut/d' CHANGELOG.md
sed -i "s/ The OpenAPI contract is \`${V}-draft\` until the tag is cut (flipped together with the tag; see the release checklist)\.//" CHANGELOG.md
# 3. verify
grep -rn "${V}-draft" --exclude-dir=.git --exclude-dir=submodules --exclude-dir=constitution --exclude=release-3.1.0-checklist.md . ; test $? -eq 1 && echo "no draft marker left"
grep -n "^## ${V}" CHANGELOG.md
BOUNDED 300 bash tests/test_version_consistency.sh | tail -3
```

**Measured 2026-10-09 in a scratch copy** (`VERSION bin/llmctl CHANGELOG.md README.md docs/*.md models/catalog.json tests/helpers.sh tests/test_version_consistency.sh openapi.yaml`, run under `BOUNDED 300`; date shown is the day of the run):

```text
before: 4:  version: 3.1.0-draft
after : 4:  version: 3.1.0
26:## 3.1.0 (2026-10-09)
  ok: CHANGELOG: newest release heading is 3.1.0 (got: ## 3.1.0 (2026-10-09))
  ok: openapi info.version is 3.1.0 or 3.1.0-draft (got '3.1.0')
RESULT: PASS
```

and `grep -n "draft"` over the scratch `CHANGELOG.md`, `docs/calibration-tool-fields.md` and `openapi.yaml` printed nothing.
(The test accepts both values, so it cannot catch a forgotten flip: the `grep` above is the check.)

## 3. Branch and tag (T127)

```bash
git fetch --all --prune
git status --short                                   # must be empty
git branch --show-current                            # must be main
git rev-parse HEAD                                   # note the exact release commit
# remote main must be an ancestor of HEAD on ALL FIVE push remotes (a single remote that moved makes the push non-ff)
for r in codeberg gitflic github gitlab gitverse; do
  m="$(git ls-remote "$r" refs/heads/main | cut -f1)"
  if [ -n "$m" ] && git merge-base --is-ancestor "$m" HEAD; then echo "$r ff-ok"; else echo "$r NOT-FF-OR-UNREADABLE ($m)"; fi
done                                                 # every line must say ff-ok; otherwise STOP and merge (below)
git tag -a v3.1.0 -m "llmctl 3.1.0" HEAD             # ANNOTATED, on the exact release commit
git cat-file -t refs/tags/v3.1.0                     # expect: tag
git rev-parse 'v3.1.0^{commit}'                      # expect: the HEAD printed above
```

If any remote is not fast-forwardable, integrate only by **merging the latest remote `main` into local `main`** (Helix 11.4.113: no rebase, no force,
no history rewrite), then re-run the gates of section 1.3. The merge creates a new HEAD, so a local `v3.1.0` tag created earlier now points at the
wrong commit: it was never pushed, so delete it (`git tag -d v3.1.0`) and recreate it on the new HEAD with the `git tag -a` line above, and re-run
the section 4 build on the new HEAD. Never move or recreate a tag that **has** been pushed; fix forward with 3.1.1.

## 4. Release assets dry-run (T126), measured 2026-10-09

`scripts/release.sh` is dry-run by construction: it never pushes, tags or publishes, and `--publish` only **prints** the `gh` / `glab` commands unless `LLMCTL_RELEASE_PUBLISH=1` is also exported.
It was run **in a scratch clone** of HEAD `c5301de` (`git clone --no-local --no-hardlinks`, remote removed, a scratch annotated tag `v3.1.0` placed on it), never against the real repository, with the output directory outside the tree:

```bash
BOUNDED 300 bash scripts/release.sh --root "$SCRATCH_CLONE" --out "$OUT" --tag v3.1.0 --publish all
```

Real output (`$OUT` stands for the scratch directory; `rc=0`):

```text
verify-tag: ok v3.1.0 -> c5301defb73a949536fe741b597d3bd089df4109
archive: $OUT/llmctl-v3.1.0.tar.gz
sbom: $OUT/llmctl-v3.1.0.sbom.cdx.json
notice: $OUT/NOTICE-THIRD-PARTY.txt
checksums: $OUT/SHA256SUMS
DRY-RUN (set LLMCTL_RELEASE_PUBLISH=1 to execute):
  gh release create v3.1.0 $OUT/llmctl-v3.1.0.tar.gz $OUT/llmctl-v3.1.0.sbom.cdx.json $OUT/NOTICE-THIRD-PARTY.txt $OUT/SHA256SUMS --verify-tag --title v3.1.0 --notes-file $OUT/RELEASE_NOTES.md
  glab release create v3.1.0 $OUT/llmctl-v3.1.0.tar.gz $OUT/llmctl-v3.1.0.sbom.cdx.json $OUT/NOTICE-THIRD-PARTY.txt $OUT/SHA256SUMS --name v3.1.0 --notes-file $OUT/RELEASE_NOTES.md
```

Asset list, sizes and `SHA256SUMS` (re-verified with `sha256sum -c`, all `OK`):

```text
 63954958  llmctl-v3.1.0.tar.gz
    17228  llmctl-v3.1.0.sbom.cdx.json      (CycloneDX 1.5, 37 components)
     2345  NOTICE-THIRD-PARTY.txt
      270  SHA256SUMS
a253fc6c3c916f5c6f1405fe355c06979844a790dc2b418f02e57b575d36e736  llmctl-v3.1.0.tar.gz
2fef74b5bdda7dbcdac39f16b420b42b5c573b84a1dcff282d866051c38102c9  llmctl-v3.1.0.sbom.cdx.json
d074827f7f8459519d66419546d48f35021453e0923b314f2b566f5d573c5bda  NOTICE-THIRD-PARTY.txt
```

(The `tar.gz` hash above is for the scratch commit `c5301de`; the real release commit will differ.) Also measured:

* **Reproducible**: `release.sh archive` run a second time into another directory produced the identical sha256 `a253fc6c...e736`.
* `llmctl-v3.1.0/VERSION` inside the archive reads `3.1.0`; 2265 entries; `tar -tzf | grep -cE '\.env$|\.key$|id_rsa'` printed 0 for the outer archive (the nested-zip path in 1.8 is inside `archive/llmctl.zip`).
* **SBOM caveat**: in a clone the submodules are not checked out, so their licences print `NOASSERTION`. **Run the real step from the real tree** (submodules initialised) so licences are read, not from a clone.
* `release.sh all` does **not** write `RELEASE_NOTES.md`, but `--publish` with `LLMCTL_RELEASE_PUBLISH=1` refuses without it, and the file must live under `$HOME` (a snap-confined `glab` cannot read `/tmp`).
* Finding in section 1.8 (nested `archive/llmctl.zip` fails `scan_archive.py`; `release.sh` does not run it).
* `scripts/release/create_release.sh` is a second, overlapping publisher (SemVer check, generated changelog, per-forge idempotent retry, `--dry-run`). It was **not** run. Use one publisher for the release, not both; this checklist uses `release.sh` because it produces the SBOM and checksums T126 requires.

Real run, from the real repository after step 3 (writes outside the tree):

```bash
OUT="$HOME/llmctl-release-3.1.0"; mkdir -p "$OUT"
BOUNDED 600 bash scripts/release.sh --out "$OUT" --tag v3.1.0 all            # verify-tag, archive, sbom, notice, checksums
BOUNDED 60  bash scripts/release.sh --out "$OUT" --tag v3.1.0 checksums --verify
BOUNDED 60  bash scripts/release.sh --out "$OUT" --tag v3.1.0 assets          # every line must say "present"
python3 -I scripts/release/scan_archive.py --allow scripts/release/public_allowlist.txt "$OUT/llmctl-v3.1.0.tar.gz"   # must exit 0 (see 1.8)
awk '/^## 3\.1\.0 /{f=1} f&&/^## /&&!/^## 3\.1\.0 /{exit} f' CHANGELOG.md > "$OUT/RELEASE_NOTES.md"
test -s "$OUT/RELEASE_NOTES.md" && head -3 "$OUT/RELEASE_NOTES.md"
# optional detached signature of SHA256SUMS: LLMCTL_RELEASE_SIGN=1 (needs gpg; otherwise prints "SKIPPED")
```

## 5. Push (ff-only, never forced) and verify per remote

> **OPERATOR GATE (interactive).** Do not start this section until the operator has been shown the release commit hash, the section 3
> `ff-ok` lines for all five remotes, the gate results of section 1.3 and the section 4 asset checksums, and has confirmed **in this
> session** that the push may proceed. A past approval or "go ahead" earlier in the work does not carry over. No agent runs this
> section on its own judgement.

```bash
set -euo pipefail
REMOTES="codeberg gitflic github gitlab gitverse"
# 1. main first, on every remote; the first failure aborts (set -e). A non-ff rejection is a STOP, never a retry with force.
for r in $REMOTES; do
  echo "== push main -> $r"; git push "$r" main
done
# 2. verify every remote now has the release commit on main BEFORE any tag leaves this machine
REL="$(git rev-parse HEAD)"
for r in $REMOTES; do
  m="$(git ls-remote "$r" refs/heads/main | cut -f1)"
  [ "$m" = "$REL" ] || { echo "ABORT: $r main=$m != $REL (no tag pushed)"; exit 1; }
done
# 3. only now push the tag
for r in $REMOTES; do
  git push "$r" refs/tags/v3.1.0
done
```

Verification (each remote must print the release commit for `main`, and the tag object plus its peeled commit):

```bash
REL="$(git rev-parse HEAD)"; TAGOBJ="$(git rev-parse refs/tags/v3.1.0)"
for r in codeberg gitflic github gitlab gitverse; do
  m="$(git ls-remote "$r" refs/heads/main | cut -f1)"
  t="$(git ls-remote "$r" refs/tags/v3.1.0 | cut -f1)"
  p="$(git ls-remote "$r" 'refs/tags/v3.1.0^{}' | cut -f1)"
  printf '%-9s main=%s tag=%s peeled=%s  ' "$r" "${m:0:9}" "${t:0:9}" "${p:0:9}"
  [[ "$m" == "$REL" && "$t" == "$TAGOBJ" && "$p" == "$REL" ]] && echo OK || echo MISMATCH
done
```

Own-org submodule `submodules/containers` needs no push (pin equals its remote tip, section 0). If a commit were added to it, push it **before** the superproject.

## 6. Forge releases (T127) — do not run before step 5 verifies on GitHub and GitLab

> **OPERATOR GATE (interactive).** Creating a forge release is public and only partly reversible. Do not start this section until the operator
> has confirmed **in this session**, after seeing the section 5 verification output (`OK` for all five remotes) and `RELEASE_NOTES.md`, that
> the releases may be created. Same rule as section 5: a past approval does not carry over.

Notes file and assets are under `$HOME` (section 4). Explicit `--repo` flags avoid depending on which of the five remotes the CLI picks (the `origin` fetch URL is GitHub, the GitLab remote is separate).

```bash
cd "$OUT"
# GitLab pre-check: glab release create CREATES a missing tag (from --ref or the default branch). The tag was pushed in section 5,
# so it must already exist on gitlab and point at the release commit; if this prints nothing, STOP (do not let glab invent a tag).
git ls-remote gitlab refs/tags/v3.1.0 | grep -q . || { echo "ABORT: gitlab has no v3.1.0 tag"; exit 1; }
git ls-remote gitlab 'refs/tags/v3.1.0^{}' | cut -f1 | grep -qx "$(git rev-parse HEAD)" || { echo "ABORT: gitlab v3.1.0 is not the release commit"; exit 1; }

gh release create v3.1.0 \
  llmctl-v3.1.0.tar.gz llmctl-v3.1.0.sbom.cdx.json NOTICE-THIRD-PARTY.txt SHA256SUMS \
  --repo vasic-digital/llmctl --verify-tag --title v3.1.0 --notes-file RELEASE_NOTES.md

glab release create v3.1.0 \
  llmctl-v3.1.0.tar.gz llmctl-v3.1.0.sbom.cdx.json NOTICE-THIRD-PARTY.txt SHA256SUMS \
  --repo vasic-digital/llmctl --name v3.1.0 --notes-file RELEASE_NOTES.md --no-update   # --no-update: never overwrite an existing release (checked in `glab release create --help`)
# add SHA256SUMS.asc to both when LLMCTL_RELEASE_SIGN=1 produced it
```

(`scripts/release.sh --publish` prints a `glab release create` line without `--no-update`; use the commands above, or add the flag, for the real run.)

The release notes MUST carry, near the top, the "Release status" block of the CHANGELOG (manual QA operator-waived; macOS static only;
nezha numbers unpinned; per-profile table incl. `decide` not usable, `decide-max` not exercised). If the operator prefers a cautious rollout,
add `--prerelease` (gh) / mark it afterwards with `gh release edit v3.1.0 --prerelease`.

## 7. Re-download and verify (T127)

```bash
V=$(mktemp -d "$HOME/llmctl-verify.XXXXXX"); cd "$V"
gh release download v3.1.0 --repo vasic-digital/llmctl            # all four assets
sha256sum -c SHA256SUMS                                           # every line OK
mkdir gh && tar -xzf llmctl-v3.1.0.tar.gz -C gh && cat gh/llmctl-v3.1.0/VERSION     # 3.1.0
mkdir gl && cd gl && glab release download v3.1.0 --repo vasic-digital/llmctl && sha256sum -c SHA256SUMS && cd ..
cmp llmctl-v3.1.0.tar.gz gl/llmctl-v3.1.0.tar.gz && echo "github == gitlab asset"
cd gh/llmctl-v3.1.0 && BOUNDED 1800 make test              # the archive's own tests (needs bash, python3, curl; Go suites SKIP with a reason when go is absent)
```

The tracked-files archive has no submodule content; the engine-dependent suites SKIP there. That is expected, and the SKIP must be reported as a skip, not a pass.

## 8. Rollback and abort notes

* **Before step 5** (nothing pushed): `git tag -d v3.1.0`; discard `$OUT`; the flip commit may be reverted with a new commit. Nothing remote was touched.
* **After push, before forge release**: do not delete or move the pushed tag and do not force-push. If the content is wrong, fix forward and tag `v3.1.1`.
* **After forge release**: a release page can be hidden without touching history: `gh release edit v3.1.0 --prerelease` or `gh release delete v3.1.0` (the tag stays); GitLab: `glab release delete v3.1.0`. Deleting a published tag is a history-visible, hard-to-reverse action: ask the operator first.
* **A forge rejects the push** (non-ff, hook, permissions): stop, `git fetch <remote>`, merge the remote tip into local `main` (never rebase, never force; Helix 11.4.113), delete the unpushed local `v3.1.0` tag and recreate it on the new HEAD (section 3), re-run the gates, push again ff-only. The other remotes must be brought to the same commit before the tag is pushed anywhere.
* **Partial publish** (one forge succeeded): re-run only the failed forge's command; `create_release.sh` records per-forge state for that purpose, `release.sh` does not.
* **Asset mismatch found in step 7**: do not re-upload over the same name silently; delete the bad asset on that forge, upload the verified one, repeat step 7, and note it in the release notes.

## 9. Open items that this checklist cannot close

| Item | Why |
|---|---|
| T124 candidate-fingerprinted readiness verdict | requires the full gate run in step 1.3 on the final commit |
| T128 final independent review | not done; required before accepting the commits |
| T142 re-run `kev-9b` (CUDA OOM at start) and `kev-08b` at final values (`lev` and `kev-4b` already ran, `live-models.jsonl` lines 4-5) | needs RAM/VRAM headroom on the dev host (OD-31) |
| T139 measured planner overhead for `kev-4b`, `kev-9b`, `lev`, `decide*` | needs measuring runs (CUDA host for the VRAM halves) |
| Letter-logit profiles | `decide` unusable at `mass_threshold` 0.5, `decide-max` never run, `decide-pro` 502s on CPU (G-156..G-160) |
| Root-level host-safety steps | written, not applied; operator runs `sudo bash scripts/hostsafety/root-steps.sh --apply` if wanted |
