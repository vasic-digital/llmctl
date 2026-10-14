# llmctl v3.2.2 release checklist

| Field | Value |
|---|---|
| Revision | 5 |
| Created | 2026-10-13 |
| Status | prepared on branch `integration/llmctl-3.2.2-final` (on top of `release/3.2.2-notes`, which sits on `integration/llmctl-3.2.2`; merged: agent containment, guard cost, constitution pin 4091798, nested-submodule inheritance test, covenant exclusions); the version bump to `3.2.2` and the CHANGELOG section `## 3.2.2 (2026-10-13)` are applied; **nothing in this list has been executed against a remote** (no push, no tag, no release) |
| Base | `main` at `db07bd5` (release 3.2.1); tag `v3.2.1` is published and immutable |
| Content | fix: engine unit loses a port race with exit 98 and is not restarted into the start limit (`fix/onnx-eaddrinuse-exit98`); fix: a stop kills only its own registration waiter, now with a delimited pid match; baselined test fixes (`fix/baselined-tests`); carrier headings (`AGENTS.md` uses the standard `## INHERITED FROM constitution/AGENTS.md` form); stale restart-policy and gateway-memory statements corrected; second live `vision` run recorded as tracked evidence (`docs/qa/vision-live-2026-10-13-run2/`); host-safety agent containment and guard improvements (guard still dry-run); constitution pin moved to upstream `4091798`; loud-skip inheritance test; live-test runner profiles and dynamic switching (`feat/livetest-profiles` at `b6b2d3c`, merged; see the section of that name below) |
| Version | `3.2.1` -> `3.2.2` (patch). Tag: `v3.2.2` |
| Companion | `docs/release-3.2.1-checklist.md`, `docs/release-3.2.0-checklist.md` (the full procedure; the steps below only list what differs), `docs/release-process.md`, `scripts/release/bump_version.sh` |

Wording note: like the earlier checklists, this file avoids the literal "llmctl" + space + digits pattern that `tests/test_version_consistency.sh` rejects in `docs/*.md`.

## What differs from the 3.2.1 procedure

1. **Scope proof, run against the release branch AFTER the version bump** (`git diff --stat v3.2.1..<release branch tip>`, not against the pre-bump integration branch). It lists only the paths of the content above (`lib/`, `scripts/hostsafety/`, `tests/`, `docs/`, `config/covenant_propagation_exclusions.tsv`, the `constitution` gitlink, the carrier files, `CHANGELOG.md`, `VERSION` and its pins). Any unexpected path stops the release.
2. **Bump** is applied (`scripts/release/bump_version.sh 3.2.2 --apply`, its own commit), plus the pins the script does not edit (README status table header, the default release-notes path in `tests/test_docs_gate_not_advisory.sh`, the `docs/limitations.md` duplicate-unit entry). The CHANGELOG section `## 3.2.2 (2026-10-13)` is written and carries the "Live-test runner: profiles and dynamic switching" entry.
3. **Gates** (bounded, host checked first with `head -2 /proc/pressure/memory`): `tests/test_version_consistency.sh`, `tests/test_docs_audit.sh`, `tests/test_doc_reachability.sh`, `tests/test_docs_no_literal_keys.sh`, `tests/test_docs_gate_not_advisory.sh` (with `LLMCTL_RELEASE_NOTES=$HOME/llmctl-release-3.2.2/RELEASE_NOTES.md`), `tests/test_cli.sh`, `tests/test_syntax.sh`, `make lint`, and the new or changed tests: `tests/test_kill_waiter_pid_prefix.sh`, `tests/test_carriers_pointer_form.sh`, `tests/test_docs_restart_policy.sh`, `tests/test_onnx_eaddrinuse.sh`, `tests/test_dup_unit_registry.sh`, `tests/test_hostsafety.sh`, `tests/test_agent_containment.sh`, `tests/test_shim_no_self_recursion.sh`, `tests/test_constitution_inheritance.sh`, `tests/test_constitution_inheritance_nested.sh`, `tests/test_constitution_inheritance_worktree.sh`. `make lint` runs bounded with `-m 3G -t 600 -T 900`. Additional gate: a run with `LLMCTL_REQUIRE_NESTED_SUBMODULES=1 tests/test_constitution_inheritance.sh` (refuses the loud skip of invariants 9/10); it needs the constitution's nested submodules checked out, so it **needs network** and is an operator step. Then ONE full suite run by the lead.
4. **Independent review** of the diff (a reviewer that did not write it); record the verdict.
5. **Release notes** are written by hand (`RELEASE_NOTES.md` in the release directory, outside the tree). They must not restate the live-test claims as more than they are: two runs, one host, profile `vision` only (at the time of this release; a later run of `small` is recorded under docs/qa/small-live-2026-10-14/ and is not part of the 3.2.2 notes).
6. **Fetch, merge onto latest main, push size check, push (ff-only, never forced), annotated tag `v3.2.2`, tag push, assets, forge release**: the exact commands are in "Exact release commands" below (derived from section 2 and 5 of the 3.2.0 checklist and `scripts/release.sh`'s header; nothing left to substitute). Each push and the tag push remain operator gates (interactive confirmation in the session that runs them).
7. **Post-release (operator action, not done by this branch):** the installed user units are not changed by merging; reinstalling the units and the `llmctl` binary is a separate operator step.

## Exact release commands (operator gates; run from the release tree on `main`, submodules initialised, `git status --short` empty)

```bash
set -euo pipefail
cd <the release tree>                       # the checkout whose HEAD is the release commit (run `pwd` and `git rev-parse HEAD` and show both to the operator)
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
git tag -a v3.2.2 -m "llmctl v3.2.2" HEAD
[ "$(git cat-file -t refs/tags/v3.2.2)" = tag ] && [ "$(git rev-parse 'v3.2.2^{commit}')" = "$REL" ] && echo tag-ok
# 5. GATE: push the tag to all five and verify the peel per remote
for r in $REMOTES; do git push "$r" refs/tags/v3.2.2; done
TAGOBJ="$(git rev-parse refs/tags/v3.2.2)"
for r in $REMOTES; do
  m="$(git ls-remote "$r" refs/heads/main | cut -f1)"
  t="$(git ls-remote "$r" refs/tags/v3.2.2 | cut -f1)"
  p="$(git ls-remote "$r" 'refs/tags/v3.2.2^{}' | cut -f1)"
  printf '%-9s main=%s tag=%s peeled=%s  ' "$r" "${m:0:9}" "${t:0:9}" "${p:0:9}"
  [[ "$m" == "$REL" && "$t" == "$TAGOBJ" && "$p" == "$REL" ]] && echo OK || echo MISMATCH
done
# 6. assets under $HOME (the snap-confined glab cannot read /tmp); the hand-written RELEASE_NOTES.md already lives there: DO NOT regenerate it from the CHANGELOG
OUT="$HOME/llmctl-release-3.2.2"; mkdir -p "$OUT"
$B -q -m 3G -t 600 -T 1500 -- bash scripts/release.sh --out "$OUT" --tag v3.2.2 all
$B -q -m 3G -t 600 -T 120  -- bash scripts/release.sh --out "$OUT" --tag v3.2.2 checksums --verify
$B -q -m 3G -t 600 -T 120  -- bash scripts/release.sh --out "$OUT" --tag v3.2.2 assets     # every line "present"
python3 -I scripts/release/scan_archive.py --allow scripts/release/public_allowlist.txt "$OUT/llmctl-v3.2.2.tar.gz"   # exit 0
test -s "$OUT/RELEASE_NOTES.md" && head -3 "$OUT/RELEASE_NOTES.md"
# 7. preview of what release.sh would publish (prints only; LLMCTL_RELEASE_PUBLISH unset). Note its glab line has no --repo/--no-update: use the explicit commands in step 9.
bash scripts/release.sh --out "$OUT" --tag v3.2.2 --publish all
# 8. prove the tag is on gitlab and is the release commit (glab release create would CREATE a missing tag)
git ls-remote gitlab refs/tags/v3.2.2 | grep -q . || { echo "ABORT: gitlab has no v3.2.2 tag"; exit 1; }
git ls-remote gitlab 'refs/tags/v3.2.2^{}' | cut -f1 | grep -qx "$REL" || { echo "ABORT: gitlab v3.2.2 is not the release commit"; exit 1; }
# 9. GATE (public, partly reversible; operator confirms in this session): forge releases, run from $HOME
cd "$OUT"
gh release create v3.2.2 llmctl-v3.2.2.tar.gz llmctl-v3.2.2.sbom.cdx.json NOTICE-THIRD-PARTY.txt SHA256SUMS \
  --repo vasic-digital/llmctl --verify-tag --title v3.2.2 --notes-file RELEASE_NOTES.md
glab release create v3.2.2 llmctl-v3.2.2.tar.gz llmctl-v3.2.2.sbom.cdx.json NOTICE-THIRD-PARTY.txt SHA256SUMS \
  --repo vasic-digital/llmctl --name v3.2.2 --notes-file RELEASE_NOTES.md --no-update
# (alternative to step 9, same effect through the script, no --repo/--no-update:
#  cd <release tree> && LLMCTL_RELEASE_PUBLISH=1 bash scripts/release.sh --out "$OUT" --tag v3.2.2 --publish all)
# 10. post-release verification
gh release view v3.2.2 --repo vasic-digital/llmctl --json tagName,name,isPrerelease,assets --jq '{tagName,name,isPrerelease,assets:[.assets[]|{name,size}]}'
glab release view v3.2.2 --repo vasic-digital/llmctl
```

Notes: forge releases for codeberg, gitflic and gitverse are created through their APIs afterwards (see "After the tag is published"). `create_release.sh` is not used (it attaches no assets; if ever used, pass `v3.2.2` with the leading `v`).

## Open items to report in the release notes

* `helix-deps.yaml` pins the constitution as `ref: main` (unpinned); the exact submodule commit is what binds. Not changed by this release.
* The superspec example template under `.specify/extensions/superspec/examples/` is third-party-style and intentionally not converted; the constitution excludes it through its exclusions table.
* UNKNOWN: process `VmHWM`; behaviour on other hosts and other profiles.

## Live-test runner: profiles and dynamic switching (merged; `feat/livetest-profiles` at `b6b2d3c`, reviewed in 3 rounds)

The extension is in this branch (merge commit on `integration/llmctl-3.2.2-final`); the CHANGELOG 3.2.2 `### Added` entry and the release notes carry a section of the same name, with the limits stated: hermetic fakes only, only profile `vision` has run live (two runs, one host), not verified against a real `llmctl` for enabled services such as `decide-nli`, no embedding profile in the shipped catalog, a run stops resident services by design, the 80 s per-profile restore bound is derived from code and not measured, SIGKILL leaves no restore. Re-run the scope proof (step 1) so the merged paths (`scripts/livetest/`, `tests/livetest_fake_lib.sh`, `tests/test_livetest_*.sh`, `docs/live-test-protocol.md`) are accounted for, and the four `tests/test_livetest_*.sh` suites plus `tests/test_shim_no_self_recursion.sh` (findings must be 0).

### Post-release live-run plan (operator-gated; NOT part of the release gates, nothing here is executed by this branch)

1. Never before the operator has accepted that a run interrupts the enabled `decide-nli` service (the decision gateway backend) and every other resident llmctl service.
2. `scripts/livetest/run_profiles.sh --plan <profile>` (or `--fitting`) first: read what would be stopped, started and restored. It changes nothing.
3. One profile at a time, on a quiet host, inside `bounded-run`, with the operator present. Large profiles only with `--allow-large` and a separate decision.
4. After each run read `RESTORE_STATE=` and `restore.txt`; on exit 6 or 7 follow `RESTORE_MANUAL.txt`. Record the evidence directory; only then say a profile "ran live".

## After the tag is published (operator gates; not done by this branch)

1. **Constitution pin.** Bump the constitution submodule pin to the 3.2.2 tag in this repository (and note that `helix-deps.yaml` stays `ref: main`).
2. **Forge-API releases for codeberg, gitflic and gitverse.** Create each release through its API with the token read from an environment variable (never written to a file, a command line shown in logs, or this repository); attach the assets (tarball, `SHA256SUMS`, SBOM, `NOTICE-THIRD-PARTY.txt`) and the release notes. Confirm on each forge that the notes link the CHANGELOG.
3. **Consumers.** Move the pins in `helix_code`, `catalogizer` and `llmctl` itself (where it consumes llmctl) to the new tag, one consumer at a time, each with its own gate run.
