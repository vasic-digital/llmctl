# llmctl v3.2.2 release checklist

| Field | Value |
|---|---|
| Revision | 1 |
| Created | 2026-10-13 |
| Status | prepared on branch `integration/llmctl-3.2.2`; **nothing in this list has been executed against a remote** (no push, no tag, no release); `VERSION` is still `3.2.1` and the CHANGELOG top heading is unchanged until the release step |
| Base | `main` at `db07bd5` (release 3.2.1); tag `v3.2.1` is published and immutable |
| Content | fix: engine unit loses a port race with exit 98 and is not restarted into the start limit (`fix/onnx-eaddrinuse-exit98`); fix: a stop kills only its own registration waiter, now with a delimited pid match; baselined test fixes (`fix/baselined-tests`); carrier headings (`AGENTS.md` uses the standard `## INHERITED FROM constitution/AGENTS.md` form); stale restart-policy and gateway-memory statements corrected; second live `vision` run recorded as tracked evidence (`docs/qa/vision-live-2026-10-13-run2/`); live-test profile work only if the lead merges `feat/livetest-profiles` |
| Version | `3.2.1` -> `3.2.2` (patch). Tag: `vX.Y.Z` |
| Companion | `docs/release-3.2.1-checklist.md`, `docs/release-3.2.0-checklist.md` (the full procedure; the steps below only list what differs), `docs/release-process.md`, `scripts/release/bump_version.sh` |

Wording note: like the earlier checklists, this file avoids the literal "llmctl" + space + digits pattern that `tests/test_version_consistency.sh` rejects in `docs/*.md`.

## What differs from the 3.2.1 procedure

1. **Scope proof.** `git diff --stat v3.2.1..integration/llmctl-3.2.2` lists only the paths of the content above (`lib/`, `tests/`, `docs/`, the carrier files, `CHANGELOG.md`, `VERSION` and its pins). Any unexpected path stops the release.
2. **Bump** (`scripts/release/bump_version.sh 3.2.2 --apply`) and the CHANGELOG section `## 3.2.2 (<date>)` are written at the release step, after independent review, not before. Add to the CHANGELOG: the exit-98 fix, the waiter pid-delimiter fix, the carrier heading change, the corrected restart-policy text, the run 2 evidence (MemoryPeak 3005 MiB on one host; cap floors unchanged).
3. **Gates** (bounded, host checked first with `head -2 /proc/pressure/memory`): `tests/test_version_consistency.sh`, `tests/test_docs_audit.sh`, `tests/test_doc_reachability.sh`, `tests/test_docs_no_literal_keys.sh`, `tests/test_syntax.sh`, `make lint`, and the new or changed tests: `tests/test_kill_waiter_pid_prefix.sh`, `tests/test_carriers_pointer_form.sh`, `tests/test_docs_restart_policy.sh`, `tests/test_onnx_eaddrinuse.sh`, `tests/test_dup_unit_registry.sh`, `tests/test_hostsafety.sh`, `tests/test_constitution_inheritance.sh`, `tests/test_constitution_inheritance_worktree.sh`. Then ONE full suite run by the lead.
4. **Independent review** of the diff (a reviewer that did not write it); record the verdict.
5. **Release notes** are written by hand (`RELEASE_NOTES.md` in the release directory, outside the tree). They must not restate the live-test claims as more than they are: two runs, one host, profile `vision` only.
6. **Fetch, merge onto latest main, push size check, push (ff-only, never forced), annotated tag `v3.2.2`, tag push, assets, forge release**: the same steps as in section 2 of the 3.2.0 checklist with `3.2.2` substituted. Each push and the tag push remain operator gates.
7. **Post-release (operator action, not done by this branch):** the installed user units are not changed by merging; reinstalling the units and the `llmctl` binary is a separate operator step.

## Open items to report in the release notes

* `helix-deps.yaml` pins the constitution as `ref: main` (unpinned); the exact submodule commit is what binds. Not changed by this release.
* The superspec example template under `.specify/extensions/superspec/examples/` is third-party-style and intentionally not converted; the constitution excludes it through its exclusions table.
* UNKNOWN: process `VmHWM`; behaviour on other hosts and other profiles.
