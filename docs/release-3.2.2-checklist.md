# llmctl v3.2.2 release checklist

| Field | Value |
|---|---|
| Revision | 3 |
| Created | 2026-10-13 |
| Status | prepared on branch `integration/llmctl-3.2.2-final` (on top of `release/3.2.2-notes`, which sits on `integration/llmctl-3.2.2`; merged: agent containment, guard cost, constitution pin 4091798, nested-submodule inheritance test, covenant exclusions); the version bump to `3.2.2` and the CHANGELOG section `## 3.2.2 (2026-10-13)` are applied; **nothing in this list has been executed against a remote** (no push, no tag, no release) |
| Base | `main` at `db07bd5` (release 3.2.1); tag `v3.2.1` is published and immutable |
| Content | fix: engine unit loses a port race with exit 98 and is not restarted into the start limit (`fix/onnx-eaddrinuse-exit98`); fix: a stop kills only its own registration waiter, now with a delimited pid match; baselined test fixes (`fix/baselined-tests`); carrier headings (`AGENTS.md` uses the standard `## INHERITED FROM constitution/AGENTS.md` form); stale restart-policy and gateway-memory statements corrected; second live `vision` run recorded as tracked evidence (`docs/qa/vision-live-2026-10-13-run2/`); host-safety agent containment and guard improvements (guard still dry-run); constitution pin moved to upstream `4091798`; loud-skip inheritance test; live-test profile work only if the lead merges `feat/livetest-profiles` |
| Version | `3.2.1` -> `3.2.2` (patch). Tag: `vX.Y.Z` |
| Companion | `docs/release-3.2.1-checklist.md`, `docs/release-3.2.0-checklist.md` (the full procedure; the steps below only list what differs), `docs/release-process.md`, `scripts/release/bump_version.sh` |

Wording note: like the earlier checklists, this file avoids the literal "llmctl" + space + digits pattern that `tests/test_version_consistency.sh` rejects in `docs/*.md`.

## What differs from the 3.2.1 procedure

1. **Scope proof, run against the release branch AFTER the version bump** (`git diff --stat v3.2.1..<release branch tip>`, not against the pre-bump integration branch). It lists only the paths of the content above (`lib/`, `scripts/hostsafety/`, `tests/`, `docs/`, `config/covenant_propagation_exclusions.tsv`, the `constitution` gitlink, the carrier files, `CHANGELOG.md`, `VERSION` and its pins). Any unexpected path stops the release.
2. **Bump** is applied (`scripts/release/bump_version.sh 3.2.2 --apply`, its own commit), plus the pins the script does not edit (README status table header, the default release-notes path in `tests/test_docs_gate_not_advisory.sh`, the `docs/limitations.md` duplicate-unit entry). The CHANGELOG section `## 3.2.2 (2026-10-13)` is written and does not mention the live-test runner extension (see "After the live-test extension is merged").
3. **Gates** (bounded, host checked first with `head -2 /proc/pressure/memory`): `tests/test_version_consistency.sh`, `tests/test_docs_audit.sh`, `tests/test_doc_reachability.sh`, `tests/test_docs_no_literal_keys.sh`, `tests/test_docs_gate_not_advisory.sh` (with `LLMCTL_RELEASE_NOTES=$HOME/llmctl-release-3.2.2/RELEASE_NOTES.md`), `tests/test_cli.sh`, `tests/test_syntax.sh`, `make lint`, and the new or changed tests: `tests/test_kill_waiter_pid_prefix.sh`, `tests/test_carriers_pointer_form.sh`, `tests/test_docs_restart_policy.sh`, `tests/test_onnx_eaddrinuse.sh`, `tests/test_dup_unit_registry.sh`, `tests/test_hostsafety.sh`, `tests/test_agent_containment.sh`, `tests/test_shim_no_self_recursion.sh`, `tests/test_constitution_inheritance.sh`, `tests/test_constitution_inheritance_nested.sh`, `tests/test_constitution_inheritance_worktree.sh`. `make lint` runs bounded with `-m 3G -t 600 -T 900`. Additional gate: a run with `LLMCTL_REQUIRE_NESTED_SUBMODULES=1 tests/test_constitution_inheritance.sh` (refuses the loud skip of invariants 9/10); it needs the constitution's nested submodules checked out, so it **needs network** and is an operator step. Then ONE full suite run by the lead.
4. **Independent review** of the diff (a reviewer that did not write it); record the verdict.
5. **Release notes** are written by hand (`RELEASE_NOTES.md` in the release directory, outside the tree). They must not restate the live-test claims as more than they are: two runs, one host, profile `vision` only.
6. **Fetch, merge onto latest main, push size check, push (ff-only, never forced), annotated tag `v3.2.2` (name exactly `v3.2.2`), tag push, assets, forge release**: the same steps as in section 2 of the 3.2.0 checklist with `3.2.2` substituted. Each push and the tag push remain operator gates.
7. **Post-release (operator action, not done by this branch):** the installed user units are not changed by merging; reinstalling the units and the `llmctl` binary is a separate operator step.

## Open items to report in the release notes

* `helix-deps.yaml` pins the constitution as `ref: main` (unpinned); the exact submodule commit is what binds. Not changed by this release.
* The superspec example template under `.specify/extensions/superspec/examples/` is third-party-style and intentionally not converted; the constitution excludes it through its exclusions table.
* UNKNOWN: process `VmHWM`; behaviour on other hosts and other profiles.

## After the live-test extension is merged (lead action; confirm each item at merge time)

The live-test runner extension lives on `feat/livetest-profiles` and is merged by the lead later. The 3.2.2 CHANGELOG and the release notes deliberately make no claim about it. Confirm at merge what the branch actually contains, then:

1. **Section to confirm: "Live-test runner: profiles and dynamic switching".** Verify against the merged code and its tests which profiles the runner accepts and how it switches between them; describe only what the merged tests exercise. Record which parts were run on a real host (UNKNOWN until a run is captured).
2. **CHANGELOG line to add after merge** (under `### Added` of `## 3.2.2`, adjusted to the merged reality before it is written): `- **Live-test runner: profiles and dynamic switching.** <one sentence naming exactly the profiles and the switching behaviour the merged tests cover; state that only profile vision has a recorded real-host run unless more were captured>.` Re-run `tests/test_version_consistency.sh` and `tests/test_docs_gate_not_advisory.sh` after editing, and update the release notes to match.
3. Re-run the scope proof (step 1) so the merged paths are accounted for.

## After the tag is published (operator gates; not done by this branch)

1. **Constitution pin.** Bump the constitution submodule pin to the 3.2.2 tag in this repository (and note that `helix-deps.yaml` stays `ref: main`).
2. **Forge-API releases for codeberg, gitflic and gitverse.** Create each release through its API with the token read from an environment variable (never written to a file, a command line shown in logs, or this repository); attach the assets (tarball, `SHA256SUMS`, SBOM, `NOTICE-THIRD-PARTY.txt`) and the release notes. Confirm on each forge that the notes link the CHANGELOG.
3. **Consumers.** Move the pins in `helix_code`, `catalogizer` and `llmctl` itself (where it consumes llmctl) to the new tag, one consumer at a time, each with its own gate run.
