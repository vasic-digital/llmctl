# llmctl v3.2.1 release checklist

| Field | Value |
|---|---|
| Revision | 1 |
| Created | 2026-10-13 |
| Status | prepared on branch `release/3.2.1`; **nothing in this list has been executed against a remote** (no push, no tag, no release) |
| Base | `main` at `66f1fed` (equal to every remote when measured); tag `v3.2.0` at `f80e55d` is published and immutable |
| Content | documentation and `llmctl help` text corrections from commits `786f65a` and `66f1fed`, the new test `tests/test_docs_gate_not_advisory.sh`, version pins; no script, library or template behaviour change |
| Version | `3.2.0` -> `3.2.1` (patch). Tag: `vX.Y.Z` |
| Companion | `docs/release-3.2.0-checklist.md` (the full procedure; the steps below only list what differs), `docs/release-process.md`, `scripts/release/bump_version.sh` |

Wording note: like the 3.2.0 checklist, this file avoids the literal "llmctl" + space + digits pattern that `tests/test_version_consistency.sh` rejects in `docs/*.md`.

## What differs from the 3.2.0 procedure

1. **Scope proof.** `git diff --stat v3.2.0..release/3.2.1` must list only `CHANGELOG.md`, `README.md`, `VERSION`, `bin/llmctl` (the `LLMCTL_VERSION` pin and `help` text), `docs/`, `specs/009-jev-decision-models/contracts/openapi.yaml` (version pin), `tests/test_docs_gate_not_advisory.sh`. Any other path stops the release.
2. **Bump** is already applied (`bump_version.sh 3.2.1 --apply`), CHANGELOG section `## 3.2.1 (2026-10-13)` written.
3. **Gates** (bounded, host checked first with `head -2 /proc/pressure/memory`): `tests/test_version_consistency.sh`, `tests/test_docs_audit.sh`, `tests/test_doc_reachability.sh`, `tests/test_docs_no_literal_keys.sh`, `tests/test_docs_gate_not_advisory.sh` (once with `LLMCTL_RELEASE_NOTES` set to the release notes file, once with the default), `tests/test_cli.sh`, `tests/test_syntax.sh`, `make lint`; then the release-script tests of the 3.2.0 checklist, step 3.
4. **Independent review** of the diff (a reviewer that did not write it); record the verdict.
5. **Release notes** are written by hand (`RELEASE_NOTES.md` in the release directory, outside the tree): they must say the 3.2.0 tarball documentation is stale and 3.2.1 supersedes it, and must not restate the 3.2.0 live-test claims as new.
6. **Fetch, merge onto latest main, push size check, push (ff-only, never forced), annotated tag `v3.2.1`, tag push, assets, forge release**: the same steps as in section 2 of the 3.2.0 checklist (fetch and merge through assets) with `3.2.1` substituted. Each push and the tag push remain operator gates.
7. After publication, confirm on each forge that the 3.2.1 release notes link the CHANGELOG and that the 3.2.0 release notes carry the correction.

## Not in this release

No new live test, no new profile validated, no change to the waiter (the port-registry gap is documented, not closed).
