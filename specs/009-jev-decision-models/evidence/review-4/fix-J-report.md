# FIX-J report - round-3 ops/shell review findings (review-C3-ops-shell.md)

Uncommitted tree on `main`; nothing staged, committed or pushed. Discipline: RED observed first (quoted), fix, GREEN, then mutation proof on a scratch copy (shell) or on the tree with exact restore (Go, `cmp`-verified).

Final targeted gates (this session): `go vet ./internal/registry/ ./internal/vantage/` clean; `go test -race -count=1 ./internal/registry/ ./internal/vantage/` ok; `tests/test_syntax.sh` PASS; `PATH=$HOME/.local/bin:$PATH make lint` rc=0 (this includes the coordinator-reported SC2218 in `tests/test_vantage_classifier.sh`, fixed with a justified `# shellcheck disable=SC2218`: the function is defined in the sourced file, the later redefinitions are deliberate mutants); suites PASS: release_no_secrets (166 ok), archive_completeness (34), install_agents (101), macos_plist (13), run_tests_format (43), service_ops_hardening (74), no_retired_vars (10), no_stray_binaries, vantage_classifier; `llmctld` isolation `go test -run WrapCommand` ok. `doc_counts --check`: install_agents page updated 78 -> 101 (match).
Not run: full `make test`, `tests/test_vantage.sh` (needs podman; only its sourced classifier and syntax were checked), engine suites (lib/engine.sh, lib/doctor.sh untouched).

## Per finding

### C3-02 unavailable fingerprint routable between Register and Reconcile
- Files: `internal/registry/registry.go`, new `internal/registry/fixj_test.go`.
- RED: `TestC302UnavailableFingerprintIsNotRoutableRightAfterRegister` -> `a row with an unavailable fingerprint must not be routable between Register and the first Reconcile: [{Name:svc ... Healthy:true ... ProcFP:unavailable}]`; `TestC302ResolveNeverReturnsAnUnavailableFingerprintRow...` failed the same way.
- Fix: Register stores `Healthy=false, UnknownSince=now` when `ProcFP==FPUnavailable`; `Resolve` also refuses the marker on its own (legacy rows). Control: a later Reconcile adopts the fingerprint and the row becomes routable; a normal registration is routable at once.
- Mutation: C3-02a (drop Register change) KILLED by `TestC302Unavailable...`; C3-02b (drop Resolve guard) KILLED by `TestC302ResolveNever...`.

### C3-03 newline-named history path hides a key
- Files: `scripts/release/build_archive.sh`, `tests/test_release_no_secrets.sh`.
- RED: `FAIL: C3-03: a newline-named key committed then deleted fails the build` (+ 2 more).
- Fix: `_ba_check_history` now walks `git log -m --no-renames --name-only -z --format= HEAD` (NUL-safe), maps NUL->line end and newline->`\001` so portable `sort -u` de-duplicates, and REFUSES any historical path holding a newline/control byte.
- Mutation: reverting to `rev-list --objects` KILLED (3 assertions).

### C3-04 "every historical path judged" was false; dead allow entry
- Same files + `docs/scripts/build_archive.md`, header comment, `fix-G-report.md` errata.
- RED: `FAIL: C3-04: a deleted secret PATH whose blob is identical to another path's is still judged` (+ 2: `b.key` not named; `unused allow entry` not reported).
- Fix: the path walk above (every path touched is judged, allow entries are consulted); new `_ba_report_unused_allow` reports `unused allow entry: <p>` (report only) for entries naming no tracked file and no historical path. Doc wording corrected.
- Real tree (this session): history check rc 0 in ~7 s, 20,520 distinct paths, no unused entries; with `submodules/llama.cpp/docs/llama-star/idea-arch.key` REMOVED from the allow list the check now FAILS naming that path (it was rc 0 before, as the reviewer measured) - the entry is live now.
- Mutation: same as C3-03.

### C3-05 nested-archive scanner
- Files: `scripts/release/scan_archive.py`, `tests/test_release_no_secrets.sh` (section 6c).
- RED: 7 failures: single-top `.env/` and `cert/` (tgz and zip) passed; plain allow entry exempted the nested path; bomb not refused.
- Fix: (a) for a nested archive the UNSTRIPPED name is judged as well as the stripped one; (b) allow entries apply only to the scanned archive's own paths; nested paths need `<outer-path>!<inner-path>` (chain `a!b!c`); (c) decompressed bytes of all nested archives share one budget (`SCAN_ARCHIVE_MAX_NEST_DECOMPRESSED`, default 512 MiB) enforced while streaming (`BudgetStream` over gzip/bz2/xz, zip by declared size, reads bounded by it); exceeding it is a finding.
- Evidence: a real 4 GiB-of-zeros nested tgz (18.7 MB compressed at gzip level 1; the reviewer's was 4.17 MB) is refused in 0.31 s: `NESTED ARCHIVE too large once decompressed ... exceeds the 536870912-byte budget`. The tracked `archive/llmctl.zip` + `.tar.gz` still scan clean (rc 0, 1.4 s). In the suite the bomb is 64 MiB with a 1 MiB budget and a < 10 s bound; control: the same archive passes under the default budget.
- Mutation: always-strip (S2) KILLED; drop unstripped judgement KILLED; allow key without ctx KILLED; budget check disabled KILLED. (One mutant, "budget add no-op", was a bad edit - not applied; the "check disabled" mutant covers it.)

### C3-06 unanchored gitlink match
- Files: `scripts/release/build_archive.sh`, `tests/test_archive_completeness.sh`.
- RED: 3 failures (decoy `docs/proj/sub/readme` let an uninitialised `sub` ship with rc 0).
- Fix: anchored match (`index($0,p)==1` via ENVIRON, excluding the exact `.git` pointer). Uninitialised submodule fails with `gitlink 'sub' yields zero files`.
- Mutation: `index == 1` -> `> 0` KILLED.

### C3-07 plist XML escaping on bash >= 5.2
- Files: `lib/service_macos.sh`, `tests/test_macos_plist.sh` (log dir now `lo<g>s &q`).
- RED: 5 failures (plist not well-formed on bash 5.3.9).
- Fix: `_svc_plist_xml` uses POSIX `sed` (escapes `& < > " '`, `&` first, `x` sentinel); `_svc_plist_str` calls it. No bash-version-dependent replacement semantics, no GNU-only flags.
- Mutation: unescaped `&` in the `<` rule KILLED. Not proven on a real bash 3.2 or by launchd.

### C3-08 tenant prefix ambiguity
- Grammar: row names are `<tenant>--<profile>`; the first `--` is the separator; tenant ids must not contain `--` or end in `-`; profile names must not contain `--` (and must not start with `-` for tenant rows).
- Files: `internal/registry/registry.go` (`rowNameKind`, `validRowName` used by `Register` and `Ports.Allocate`; `DiffScope.keep`: a `--`-suffixed prefix scope owns only well-formed rows, `NoTenantRows` drops only well-formed tenant rows so ambiguous rows stay visible), `internal/registry/ports.go`, `lib/service_linux.sh` (`_svc_validate_tenant_id`, `_svc_instance_key`), `lib/portreg.sh` (comment), `llmctld/internal/isolation/cgroup.go` + `cgroup_test.go` (same two rules so the Go and bash validators stay in step; OUTSIDE my ownership list but unowned, small, tested - flag if you want it reverted), tests `fixj_test.go`, `tests/test_service_ops_hardening.sh`.
- RED (Go): `name "acme---small" must be refused as ambiguous ... got <nil>` (6 names); `tenant acme's diff must not report neighbouring tenants' rows: {RegistryOnly:[acme---small acme--eu--small]}`; `a non-tenant scope ... the malformed row must be reported: {RegistryOnly:[]}`. RED (shell): 5 failing tenant-id assertions.
- Mutation: Go C3-08a/b/c KILLED by `TestC308TenantScopeNever...`, `TestC308RegisterRefuses...`, `TestC308NoTenantScope...`; shell tenant-id rule disabled KILLED; llmctld rule disabled KILLED (`double-dash-C3-08`, `trailing-dash-C3-08`).
- Behaviour change: tenant ids such as `acme--eu` / `acme-` and registry names like `a--b--c` are now refused. 205 catalog ids contain no `--`.

### C3-09 npm `--help` smoke and aider record
- Files: `scripts/install_agents.sh`, fixtures `fake_npm.sh` / `fake_uv.sh` (new knobs `FAKE_NPM_HELP_CRASH|EMPTY|RC1`, `FAKE_UV_VERSION_CRASH`), `tests/test_install_agents.sh`, docs page.
- RED: 12 failures incl. `a bin whose --help crashes (stderr text, exit 1) fails the install`.
- Fix: `--help` must EXIT 0 and print on STDOUT (stderr not merged); records say `"runtime_smoke":"version+help (exit 0, non-empty stdout)"`. aider now runs `aider --version` on EVERY path (verified or unverified), same rule, record `"version (aider --version, exit 0, non-empty stdout)"`.
- Mutation: status check off KILLED only after adding the `RC1` fixture (it first SURVIVED: the crash fixture also had empty stdout - fixed); empty-stdout check off (S3) KILLED; aider smoke off KILLED.

### C3-10 unguarded `timeout`
- Files: `scripts/install_agents.sh`, tests.
- RED: with PATH lacking timeout the `--check` output lost version/headless (`version=-`, `headless=unknown`).
- Fix: `_timeout` = `timeout` | `gtimeout` | perl (fork + alarm in the parent, own process group killed, exit 124) | none (probes run unbounded, one warning `no timeout, gtimeout or perl`). Mode chosen once at start. `LLMCTL_AGENTS_CHECK_TIMEOUT` (default 20) added so the fallback can be tested: a hung `--version` is cut off in < 5 s under perl.
- Mutation: perl branch disabled KILLED; none-branch made to fail KILLED.
- `scripts/release/preflight_submodules.sh:95` (pre-existing, unchanged) still uses bare `timeout`: NOT fixed (not in the finding's scope).

### C3-11 harness
- Files: `tests/run_tests.sh`, `tests/test_run_tests_format.sh`, and the four legacy suites that printed no `  ok:` line (`test_go_unit.sh`, `test_py_unit.sh` - its "no python unit tests present" is now an honest `SKIP-SUITE`, `test_constitution_inheritance.sh`, `test_matrix_harness.sh`) which now print one summary `  ok:` on success.
- RED: 8 failures (silent suite PASS, `RESULT: FAIL`+exit 0 PASS, assertions after SKIP-SUITE SKIP, tab/ANSI/`FAIL:x` unseen).
- Fix: FAIL for exit-0 + no `  ok:` and no SKIP ("asserted nothing"), exit-0 + `RESULT: FAIL`, any assertion after `SKIP-SUITE`; FAIL lines recognised with any indentation, ANSI stripped, no space required.
- Mutation: both new rules disabled KILLED. Risk: the full `make test` was not run; a suite printing an indented `FAIL:` from nested output would now FAIL (none found in the suites I ran).

### C3-12 stray binaries
- Files: `tests/test_no_stray_binaries.sh` (rewritten), new `tests/fixtures/TRACKED_BINARIES_ALLOWLIST.txt`.
- Chosen scope: untracked non-ignored files of the main repo AND every submodule, plus TRACKED native executables > 1 MiB not in the allow-list. Formats: ELF, Mach-O thin, fat Mach-O (`cafebabe` with arch count < 20, so Java class files are not flagged), PE (MZ + `PE\0\0` at e_lfanew), wasm.
- Control now runs the SAME `scan_strays` function on a scratch git repo + scratch submodule (untracked ELF/Mach-O/fat/wasm/PE, ignored ELF, `.class`, `MZ` text, tracked big/small/allow-listed).
- Real tree: two tracked >1 MiB binaries found in the constitution submodule (`constitution/scripts/workable-items/bin/workable-items`, `-linux`) - allow-listed with the reason. Everything else clean; ~12 s.
- Mutation: enumeration narrowed (the surviving S8) KILLED; wasm magic disabled KILLED.
- An earlier per-file `stat` version took minutes on 20k tracked files; replaced by one `find -size` pass.

### C3-13 retired-vars exclusion
- Files: `tests/test_no_retired_vars.sh`, `scripts/doc_counts.sh` (`\s` -> `[[:space:]]`, BSD-safe).
- Fix: production scan skips only TOP-LEVEL docs/tests/specs/build/submodules/constitution (+ .git/node_modules anywhere); `lib/tests/`, `scripts/build/` are scanned. `\b` replaced with a portable terminator class. Allow-list entries are `path:N` (pinned mention budget), so a new mention in an allow-listed file fails.
- Control needles: planted `lib/tests/...`, `scripts/build/...` reported; top-level docs/tests not; budget exceeded -> FAIL.
- Mutation: adding `--exclude-dir=tests --exclude-dir=build` back KILLED.
- Partial: entries are count-pinned, not line-pattern-specific.

### C3-15 surviving mutants
S1 (`.git` pointer counted), S5 (dirty submodule), S2, S3, S7 (pinned-version mismatch), G5 (live-side scope): each now has a RED-first assertion (archive_completeness: S1/S5; release_no_secrets: S2; install_agents: S3/S7; `TestC315DiffScopedFiltersTheLiveSideToo`: G5). Re-run on the scratch copy / tree: S1, S2, S3, S5, S7, G5 all KILLED. (S1, S5, S3-empty, S7 tests passed immediately against the unmutated code - they pin existing behaviour; their RED is the mutation.)

### C3-17 skip classifier
- Files: new `tests/vantage_classifier.sh` (classifier + `vantage_classifier_selfcheck`, silent), new `tests/test_vantage_classifier.sh`, `tests/test_vantage.sh` (sources it and self-checks BEFORE the skip decision; the `ok:` assertions follow `up`).
- A RED against the old layout was not possible (nothing sourceable); proof is by mutation: match-everything and match-nothing classifiers FAIL the self-check; disabling the negative-sample check KILLED.
- `tests/test_vantage.sh` itself was not run (podman); only `bash -n`.

### C3-18 FIX-G claims
Errata appended to `evidence/review-3/fix-G-report.md` (the two claims corrected, original text untouched). Doc wording fixed in `docs/scripts/build_archive.md`, `install_agents.md`, `run_tests.md`, `test_install_agents.md`.

## Honest limits / not done
- C3-01, C3-14, C3-16: FIX-I's.
- Bash 3.2 / BSD userland: not run (no Mac); I avoided `declare -A`, `mapfile`, `${x,,}`, bare empty-array expansions, `timeout` unguarded, `sed -i`, `grep -P`, `\b`/`\s`, `stat -c` without a fallback, `readlink -f`, `date -d` in new code (`sed`, `awk`, `od`, `find -size +Nc`, `tr '\000\n'` used). `tar`/`zip` GNU-tar dependency in build_archive unchanged.
- `llmctld/internal/isolation` edit is outside the stated ownership list (see C3-08).
- The empty directory `relative/` in the repo root pre-dates this work (created Oct 7 21:00); I did not create or touch it.
- Scratch copies under the session scratchpad are left in place (not in the repo).
