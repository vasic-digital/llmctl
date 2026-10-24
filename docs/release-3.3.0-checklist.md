# llmctl v3.3.0 release checklist

| Field | Value |
|---|---|
| Revision | 1 |
| Created | 2026-10-24 |
| Status | prepared on branch `release/3.3.0` (see "Commits"); **nothing in this list has been executed against a remote** (no push, no tag, no forge release) |
| Base | `main` at `d9d15a2`; latest tag `v3.2.2` (published, immutable) |
| Version | `3.2.2` -> `3.3.0` (minor). Tag: `v3.3.0` |
| Companion | `docs/release-process.md`, `docs/release-3.2.2-checklist.md` (procedure this one copies), `scripts/release/bump_version.sh` |

Wording note: this file avoids the literal "llmctl" + space + digits pattern that `tests/test_version_consistency.sh` rejects in `docs/*.md`.

## Commits

Release tree: branch `release/3.3.0` = `main` (`d9d15a2`) + one test-fix commit + the documentation commit that adds this file. `main` itself is `2875a61` (release: 3.3.0, the 78-entry release layer) + `d9d15a2` (lint fix). The branch `release/3.3.0-prep` was created by another process in the same checkout during this preparation; it additionally commits 24 generated `.docx/.html/.pdf` exports (decision recorded: HEAD tracks none, so they are **not** part of this release; the files are present, untracked, in the working tree). It is not part of the release and was not modified.

## Test results (what was run, on which tree, what it proves)

Hosts and bounds: real host, `bounded-run -m 12G` scope, `nice -n 10`, memory pressure checked first (`some avg10=0.00`). Logs: `~/llmctl-release-3.3.0/logs/`.

| Run | Tree | Result |
|---|---|---|
| `make validate`, first attempt | `2875a61` | stopped at `lint`: 5 shellcheck `-S warning` findings in tests (also present at `f42bad6`). Fixed in `d9d15a2`. |
| `make validate`, second attempt (timeout 7200 s) | `d9d15a2` | json-check OK, lint OK, `make test`: 166 suites completed = **157 PASS / 9 FAIL**; the harness was killed by its own 7200 s timeout inside `test_validation_mutants.sh`, so 11 suites never started. |
| Re-runs with `TMPDIR=/var/tmp/rel330`, `LLMCTL_*_DIR` unset | `d9d15a2` + test fixes | all 9 failures and the 12 unrun suites individually: **all PASS** (see classification). |
| `make llmctld-test` | `release/3.3.0` | 12 packages `ok`; `llmctld/test/integration` **FAIL** (2 tests), identical failures on the unmodified `v3.2.2` tree. |
| constitution `run_verification.sh`, `meta_test_verification.sh` | `/home/milosvasic/Projects/constitution` | **UNDETERMINED**: all 15 required submodule directories are empty (not initialised); exit 1, 0 verifications actually ran. Needs `git submodule update --init` there (network, operator). |

**There is no single green `make validate` run on the final tree.** The suites were run in two parts (the first on `d9d15a2`, the rest and the fixed ones on the final test tree). The only differences between `d9d15a2` and the final tree are test files, `CHANGELOG.md`, `README.md`, `lib/scheduler.sh` (comment), `docs/live-test-protocol.md` and this checklist; the final state of those was checked by the specific suites below, not by a full re-run.

Classification of the 9 failures of the second attempt (each investigated, root cause shown):

1. `test_engine_deps`, `test_leftover_deps`, `test_link_deps`, `test_resolve_deps`, `test_preflight_submodules` - **environment, not a defect**. Their "nothing resolves" fixture lives under `$TMPDIR`; the resolver's ancestor walk found `~/.cache/submodules` (a symlink to a populated directory on this host). With `TMPDIR=/var/tmp/rel330` all five pass (13, 55, 26, 45, 20 assertions). Hermeticity gap worth fixing later: these fixtures are not isolated from a `submodules/` directory in an ancestor of `$TMPDIR`.
2. `test_hostsafety` - exit 1 with no `FAIL` line in the harness run; **re-run alone: 382 ok, exit 0**. Cause of the single failing harness run UNKNOWN (it ran concurrently with other heavy sessions on the host).
3. `test_no_pipe_grep_q` - **real defect in the new `test_decide_validate_model_alias.sh`** (`echo | grep -q` under pipefail). Fixed; the test was also rewritten with a positive control after review.
4. `test_service_ops_hardening` - **real, deterministic, red already on `f42bad6`**: fixture profiles `eng`/`g129` are not in the catalog and since review 3 finding 9 an unknown profile is consumer-facing, so "profile eng is not validated; not starting". Fixed with a fixture catalog; 81 ok. Why the `g129` assertions passed before the fix is UNKNOWN.
5. `test_livetest_watchdog` - **race in the test (S2)**: the setsid watchdog is still alive for under 3 s when the driver exits after a double signal (failed 2 of 5 runs; 0 of 6 after the fix). Also one `llama-server present` failure while another process on the host had a real `llama-server`. Full suite after the fix: 346 passed, 0 failed.
6. `test_agent_containment` - the two FAILs seen once earlier ("the scope is gone afterwards", "timeout: its scope is stopped and gone") **did not reproduce**: 3 PASS runs (43 ok each), one of them with an isolated `HOME`. Scope teardown is asynchronous (measured: gone at 0.04 s idle; still active at 0.08 s and gone at 0.27 s under CPU load), so one check after `sleep 1` is a race; the checks now poll up to 15 s. Root cause of the earlier two FAILs: UNCONFIRMED.

Unrun-by-harness suites, run individually: `test_validation_quarantine_env` 46 ok, `test_validation_r2_small` 10, `test_validation_record_integrity`, `test_validation_served_identity`, `test_validation_served_launch` 5, `test_validation_suites` 68, `test_vantage_classifier` 7, `test_vantage` 40, `test_version_consistency` 27, `test_vision_golden_fixtures` 14, `test_vision_validate` 103, `test_validation_mutants` 102 ok (1192 s). All rc 0 (see `logs/rerun2/summary.txt`).

`llmctld/test/integration` (2 failures, **not caused by this release**: `llmctld/` has no diff against `v3.2.2` and the same two tests fail on a `git archive v3.2.2` tree): `TestClusterPlacement_ConcurrentStarts_NeverDoubleBookANode` - the real `bin/llmctl start moe-fast` is refused by the memory-pressure gate (18969 MiB available, needs 15644 + 4096) - host-memory dependent; `TestFailoverState_KVCacheSurvivesPrimaryKill` - `POST /v1/replication/append` times out (`Client.Timeout`), cause UNKNOWN. Both stay open as pre-existing.

## Independent review (T128)

A fresh reviewer that did not write the diff reviewed `f42bad6..release/3.3.0` read-only: verdict **GO-WITH-FIXES**, 2 MAJOR, 12 MINOR/NIT. Addressed in this release: the new alias test (runner-incompatible, no positive control) rewritten; the hard-coded developer path in `test_no_lock_fd_leak.sh` removed; `test_docs_gate_not_advisory.sh` default notes path moved to 3.3.0; README "arrived in 3.1.0"; scheduler lock documentation; CHANGELOG additions (scheduler lock timeout, `smoke` model name, two extra guard tests, corrected trap claim, counts/date caveat). **Not addressed (open, listed in the CHANGELOG known limitations or here):** `pin_reverify.py` keeps `Authorization` on a same-host https to http redirect; the redirect/TLS-off guard tests are pattern scans with blind spots (`tests/matrix/clients/python_urllib.py` is not covered); no behavioural test of `_NoRedirect`/`_StripAuthCrossHost`; `docs/limitations.md` got the version in its title but not the 3.3.0 limitations; evidence scripts under `specs/009-*/evidence` were edited after their recorded outputs; `test_validate_interrupt.sh:78` lock-timeout path; the diagrams' SVGs are not checked for freshness against their `.mmd`. The reviewer did not review the 68 earlier commits in depth, runtime behaviour, or the long docs.

## Release notes

`~/llmctl-release-3.3.0/RELEASE_NOTES.md` (hand-written, outside the tree). Do not regenerate it from the CHANGELOG.

## Open items to report in the release notes

* Manual QA (11.4.185) not performed; no profile has a fresh validation record; live model evidence predates the judge rewrite.
* Constitution `run_verification`/`meta_test_verification` could not run here (submodules uninitialised).
* `helix-deps.yaml` records the dependency layout; the previous pins of the three removed gitlinks are in the CHANGELOG.

## Exact release commands (operator gates; run from the release tree on `main`, submodules initialised, `git status --short` empty)

```bash
set -euo pipefail
cd /home/milosvasic/Projects/llmctl && git switch main && git merge --ff-only release/3.3.0   # GATE: local main d9d15a2 -> release commit; run `pwd` and `git rev-parse HEAD`, show both
B=/home/milosvasic/Projects/llmctl/scripts/hostsafety/bounded-run
REMOTES="codeberg gitflic github gitlab gitverse"
git fetch --all --prune
# 1. fast-forward check: every remote main must be an ancestor of HEAD (otherwise STOP and merge that main; never rebase, never force)
for r in $REMOTES; do
  m="$(git ls-remote "$r" refs/heads/main | cut -f1)"
  if [ -n "$m" ] && git merge-base --is-ancestor "$m" HEAD; then echo "$r ff-ok ($m)"; else echo "$r NOT-FF-OR-UNREADABLE ($m)"; fi
done
# 2. push-size check (gitflic accepts at most 100 MiB per push; above 90 MiB STOP and ask)
for r in $REMOTES; do
  m="$(git ls-remote "$r" refs/heads/main | cut -f1)"
  [ -n "$m" ] || { echo "$r: remote main unreadable, STOP"; continue; }
  printf '%-9s %s bytes\n' "$r" "$(git rev-list --objects "^$m" HEAD | git pack-objects --stdout 2>/dev/null | wc -c)"
done
# 3. GATE (operator confirms in this session): push main, ff-only, per remote; the first failure aborts
for r in $REMOTES; do echo "== push main -> $r"; git push "$r" main; done
REL="$(git rev-parse HEAD)"
for r in $REMOTES; do
  m="$(git ls-remote "$r" refs/heads/main | cut -f1)"
  [ "$m" = "$REL" ] || { echo "ABORT: $r main=$m != $REL (no tag pushed)"; exit 1; }
done
# 4. annotated tag on exactly the pushed commit
git tag -a v3.3.0 -m "llmctl v3.3.0" HEAD
[ "$(git cat-file -t refs/tags/v3.3.0)" = tag ] && [ "$(git rev-parse 'v3.3.0^{commit}')" = "$REL" ] && echo tag-ok
# 5. GATE: push the tag to all five and verify the peel per remote
for r in $REMOTES; do git push "$r" refs/tags/v3.3.0; done
TAGOBJ="$(git rev-parse refs/tags/v3.3.0)"
for r in $REMOTES; do
  m="$(git ls-remote "$r" refs/heads/main | cut -f1)"
  t="$(git ls-remote "$r" refs/tags/v3.3.0 | cut -f1)"
  p="$(git ls-remote "$r" 'refs/tags/v3.3.0^{}' | cut -f1)"
  printf '%-9s main=%s tag=%s peeled=%s  ' "$r" "${m:0:9}" "${t:0:9}" "${p:0:9}"
  [[ "$m" == "$REL" && "$t" == "$TAGOBJ" && "$p" == "$REL" ]] && echo OK || echo MISMATCH
done
# 6. assets under $HOME (the snap-confined glab cannot read /tmp); the hand-written RELEASE_NOTES.md already lives there: DO NOT regenerate it from the CHANGELOG
OUT="$HOME/llmctl-release-3.3.0"; mkdir -p "$OUT"
$B -q -m 3G -t 600 -T 1500 -- bash scripts/release.sh --out "$OUT" --tag v3.3.0 all
$B -q -m 3G -t 600 -T 120  -- bash scripts/release.sh --out "$OUT" --tag v3.3.0 checksums --verify
$B -q -m 3G -t 600 -T 120  -- bash scripts/release.sh --out "$OUT" --tag v3.3.0 assets     # every line "present"
python3 -I scripts/release/scan_archive.py --allow scripts/release/public_allowlist.txt "$OUT/llmctl-v3.3.0.tar.gz"   # exit 0
test -s "$OUT/RELEASE_NOTES.md" && head -3 "$OUT/RELEASE_NOTES.md"
# 7. preview of what release.sh would publish (prints only; LLMCTL_RELEASE_PUBLISH unset). Note its glab line has no --repo/--no-update: use the explicit commands in step 9.
bash scripts/release.sh --out "$OUT" --tag v3.3.0 --publish all
# 8. prove the tag is on gitlab and is the release commit (glab release create would CREATE a missing tag)
git ls-remote gitlab refs/tags/v3.3.0 | grep -q . || { echo "ABORT: gitlab has no v3.3.0 tag"; exit 1; }
git ls-remote gitlab 'refs/tags/v3.3.0^{}' | cut -f1 | grep -qx "$REL" || { echo "ABORT: gitlab v3.3.0 is not the release commit"; exit 1; }
# 9. GATE (public, partly reversible; operator confirms in this session): forge releases, run from $HOME
cd "$OUT"
gh release create v3.3.0 llmctl-v3.3.0.tar.gz llmctl-v3.3.0.sbom.cdx.json NOTICE-THIRD-PARTY.txt SHA256SUMS \
  --repo vasic-digital/llmctl --verify-tag --title v3.3.0 --notes-file RELEASE_NOTES.md
glab release create v3.3.0 llmctl-v3.3.0.tar.gz llmctl-v3.3.0.sbom.cdx.json NOTICE-THIRD-PARTY.txt SHA256SUMS \
  --repo vasic-digital/llmctl --name v3.3.0 --notes-file RELEASE_NOTES.md --no-update
# (alternative to step 9, same effect through the script, no --repo/--no-update:
#  cd <release tree> && LLMCTL_RELEASE_PUBLISH=1 bash scripts/release.sh --out "$OUT" --tag v3.3.0 --publish all)
# 10. post-release verification
gh release view v3.3.0 --repo vasic-digital/llmctl --json tagName,name,isPrerelease,assets --jq '{tagName,name,isPrerelease,assets:[.assets[]|{name,size}]}'
glab release view v3.3.0 --repo vasic-digital/llmctl
```

Notes: forge releases for codeberg, gitflic and gitverse are created through their APIs afterwards (see "After the tag is published"). `create_release.sh` is not used (it attaches no assets; if ever used, pass `v3.3.0` with the leading `v`).


## After the tag is published (operator gates; not done here)

1. Bump consumers (`helix_code`, `catalogizer`, the constitution hub's `submodules/llmctl` pin) to `v3.3.0`, one at a time, each with its own gate run.
2. Create the codeberg, gitflic and gitverse releases through their APIs with tokens read from environment variables (never written to a file).
3. Reinstall the units (`llmctl install`) and re-validate every served profile on the operator's hosts.
