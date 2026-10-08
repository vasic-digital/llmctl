# Review 4 — Scope C3: ops / shell layer (round 3: re-verify C2-01..C2-18 after FIX-G, hunt new defects)

| Field | Value |
|---|---|
| Reviewer | Independent adversarial reviewer, round 3. I did not write this code, and I did not do rounds 1 or 2. I was read-only on the repository: the only file I wrote is this report. |
| Date | 2026-10-08 |
| Tree | Uncommitted work tree on `main`, HEAD `a9ebefe` |
| Inputs | `evidence/review-3/review-C2-ops-shell.md` and `evidence/review-3/fix-G-report.md`, plus the lead's later edits named in the brief |
| Model/effort | Opus. Effort cannot be set on this dispatch path, so it is recorded as `?` (§11.4.231(F.2)). |

## Method (evidence from this session)
- **Scratch copy.** All dynamic work ran on a copy in `mktemp -d` scratch (`…/scratchpad/c3.VpC7hM`). It was an rsync of the tree without `.git`, `build`, `archive`, `llama.cpp`, `colibri`, `specs` and `llmctld`, plus `specs/009-*/contracts`. A throw-away `git init` let the git-dependent suites run. Nothing touched systemd, podman or the network. The scratch directory was removed by its exact name at the end.
- **Baseline on the copy, all green:**
  - `go test ./internal/registry ./internal/gateway ./cmd/llmctl-decide`
  - suites `archive_completeness`, `release_no_secrets`, `install_agents`, `run_tests_format`, `macos_plist`, `no_stray_binaries`, `no_retired_vars` and `service_ops_hardening`: every one `RESULT: PASS`, rc=0.
  - The real tree, read-only: `test_no_stray_binaries` and `test_no_retired_vars` both PASS. `_ba_check_history` on the real tree returns rc 0 in 7 s.
- **Real-git fixtures, `build_archive`:**
  - submodule restore (status, `submodule status`, `ls-files --recurse-submodules`, fsck, re-archive, `submodule update`);
  - a detached submodule;
  - a newline-named path in history and duplicate-blob paths in history;
  - an uninitialised gitlink;
  - tracked file names with `*` / `[` (zip `-@` wildcard check).
- **`scan_archive.py` fixtures:** nested archives whose single top directory is a deny-listed directory, and a 4 MiB → 4 GiB nested gzip bomb.
- **Probes:**
  - a Go probe test in the copy, for the unavailable-fingerprint routability and the tenant-prefix ambiguity;
  - `install_agents.sh` with a fake npm whose `--help` crashes, and the C2-02 paths;
  - harness probes with fake suites.
- **Mutations:** 15 reviewer-authored, Go and shell (table below), plus a compile check of all 19 mutations in `tests/test_gateway_mutation.sh`.
- **Static checks:** `~/.local/bin/shellcheck` 0.11.0 `-S warning` on every changed script gives rc=0, no warnings (info-level only: SC1003, SC2016, SC2015, SC1091). Bash-3.2 / BSD portability grep (section below).

## Round-2 findings — re-verification

| ID | Verdict | Evidence (this session) |
|---|---|---|
| C2-01 | FIXED, with a new hole (C3-06) | Fixture with the submodule `my sub` (space in the name), plus a detached variant. The extracted tree has empty `git status`, `submodule status` ` 2b5d226… my sub`, `ls-files --recurse-submodules` lists `my sub/s.txt` and `my sub/inner/i.txt`, fsck is clean, the shipped config has `submodule."my sub".active=true` plus `.url`, and the re-archive ships the submodule files. **But** the zero-file gitlink check uses an unanchored substring match: C3-06. |
| C2-02 | FIXED | Unpinned + offline gives rc=1 and 0 `uv` calls. With `ALLOW_UNVERIFIED=1` the record is honest (`integrity_source:"none"`, `pinned:false`, `method …UNVERIFIED`). Pinned + offline, even with the opt-in, gives rc=1 and no record. |
| C2-03 | FIXED for the stated case; a new ambiguity in the same class (C3-08) | `TestC203*` passes, and G2 is KILLED. The prefix scope mis-handles tenant ids that contain `-`/`--`: C3-08. |
| C2-04 | FIXED for the reported failure; a new XML-escape defect (C3-07) | `test_macos_plist` passes. Under bash ≥ 5.2 the escaping is broken for `<` and `>`: C3-07. |
| C2-05 | PARTIALLY FIXED (C3-03, C3-04) | A committed-then-deleted `ctl.pem` is caught. A newline-named `notes\nid_rsa` holding a private-key block ships with rc 0 (C3-03). `rev-list --objects` lists each object once, so not every historical path is judged, and one allow entry is dead (C3-04). |
| C2-06 / C2-10 | FIXED; residual harness gap (C3-11) | Fake suites confirm the FAIL-line and SKIP-ordering rules. A silent exit-0 suite is still PASS (C3-11). |
| C2-07 / C2-08 | FIXED in Reconcile; a gap at Register (C3-02) | G3 and G6 are KILLED. An "unavailable" row is `Healthy=true` and routable until the first Reconcile (C3-02). |
| C2-09 | FIXED | `TestC209CLIDownAllRemovesOtherOwnersContainers` passes. My mutation G7 (`down = m.DownAll` → a no-op; it compiles) is KILLED. |
| C2-11 | FIXED | Code read (`service_linux.sh:251-284`); `service_ops_hardening` passes. |
| C2-12 | FIXED (text level) | `_svc_qx "/opt/a$HOME/${X}"` gives `"/opt/a$$HOME/$${X}"` on bash 5.3.9. Not proven on bash 3.2. |
| C2-13 | FIXED by the lead (`autoResolver`, `serve_resolver.go:233-275`) | `TestC213AutoSwitchesToRegistryWhenAnEngineRegistersLater` passes. My mutation G1 (no re-check after the first pick) is KILLED. |
| C2-14 | FIXED | `TestC214*` passes (code: `registry.go:530-538`). |
| C2-15 | FIXED; test gap (S5) | Dirty refusal works. A dirty SUBMODULE case is untested (mutation S5 survived). |
| C2-16 | PARTIALLY FIXED (C3-05) | Nested `.env` and PEM in nested archives are caught. A nested archive whose single top directory is `.env/` or `cert/` passes with rc 0. Allow entries apply at every nesting level. |
| C2-17 | FIXED | `build_archive.sh:323,381,400` use the `${a[@]+…}` idiom. No other reachable empty-array expansion under `set -u` in the changed bash (sweep below). |
| C2-18 | Documented, but the smoke is weaker than the record says (C3-09) | A crashing `--help` passes the `version+help` smoke. |
| Flake `TestFixedAllocationBlocksDynamicOnSamePort` | Not reproduced | `go test -race -count=3 ./internal/registry` is green. I did not re-run the loaded-host reproduction. |

## New findings

### C3-01 · IMPORTANT · internal/gateway/registry_resolver_publish_test.go:62 — `TestUnpublishDoesNotEvictASuccessor` fails 100% where /bin/sh is bash (Fedora, RHEL, Arch, openSUSE, macOS)
- **The cause.** This is part of the lead's later edit. The successor is `exec.Command("sh", "-c", "sleep 60", "successor")`, and the test relies on the marker `successor` (the shell's `$0`) staying in argv.
  - dash, this host's /bin/sh, keeps `sh -c sleep 60 successor`.
  - bash exec-optimises a single-command `-c` string, and the process becomes `sleep 60`.
- **Measured.** `bash -c "sleep 5" successor` gives the cmdline `sleep 5`. With `sh` replaced by `bash` (H1), the test FAILED 5/5 runs: `pid N is not (yet) running "successor": register after the process has exec'd`.
- **A second problem.** Even on dash the test registers the pid while it is still the SHELL (marker in argv), so the fingerprint is the shell's. That is exactly the "register before exec" pattern C2-07 exists to prevent, encoded as the test's premise.
- **Fix.** Use a form that cannot be exec-optimised and still carries the marker, e.g. `sh -c 'sleep 60; :' successor`. `internal/registry/registry_test.go:218` already uses `"sleep 300; : …"`. Or spawn the package's own helper binary with the token as argv[0] or an exact argument.
- **finding_layer:** test-instrumentation

### C3-02 · MINOR · internal/registry/registry.go:316,323-326 — a row whose fingerprint is `"unavailable"` is Healthy and routable from Register until the first Reconcile
- **The cause.** `Register` sets `e.Healthy = true` and stores `ProcFP = FPUnavailable`, but only `Reconcile` turns such a row "unknown / not routable". The doc comment at `registry.go:164-168` says the row is "never trusted".
- **Probe test (copy).** Right after Register: `ProcFP="unavailable" Healthy=true`, and `Resolve(kind=decide)` returns 1 row. `TestC208` checks routability only AFTER a Reconcile, so it cannot see this. The gateway's `RegistryResolver` and the auto mode (`autoResolver.pick` → `Resolve`) route on `Healthy`.
- **Scope.** The window lasts until the first reconcile pass (default 5 s in the gateway). On Linux the case arises mainly when the process dies between the identity check and the fingerprint.
- **Fix.** In `Register`, when `ProcFP == FPUnavailable`, store `Healthy=false` and `UnknownSince=now`, or refuse. Add the Resolve-right-after-Register assertion to `TestC208`.
- **finding_layer:** source-defect

### C3-03 · MINOR · scripts/release/build_archive.sh:290 (`_ba_check_history`) — a history path containing a newline evades the deny-list: a private key ships in the bundle with rc 0
- **The cause.** `git rev-list --objects` truncates a path at the first newline. The fixture `notes\nid_rsa` was listed as `notes`, so the awk/deny-list never sees `id_rsa`. The working-tree newline refusal (`:367`) runs only over the current file list, not over history.
- **Reproduced.** The `notes\nid_rsa` file held an `OPENSSH PRIVATE KEY` block, was committed, and was `git rm`'d.
  - `build_archive` gave rc=0.
  - In the extracted `.git`, `git show HEAD~1 --stat` shows `"notes\nid_rsa"`.
  - Control: a committed-then-deleted `ctl.pem` in the same fixture fails the build.
- **Fix.** Enumerate history paths NUL-safely (`git log -z --format= --name-only -m HEAD`, or `ls-tree -r -z` per commit), and refuse any historical path that contains a newline.
- **finding_layer:** source-defect

### C3-04 · MINOR · build_archive.sh:21-24,275-279 + docs/scripts/build_archive.md:176-180 + scripts/release/public_allowlist.txt:12 — "every historical PATH is judged" is false; one allow entry is dead
- **The overclaim.** `rev-list --objects` prints each blob and tree ONCE, under the first path it meets.
- **Measured on the real tree.**
  - The llama.cpp submodule's history holds the deck at `docs/llama-star/idea-arch.key` (2023-11 → 2024-07), but `rev-list --objects HEAD` prints only `docs/development/llama-star/idea-arch.key`.
  - `_ba_check_history` on the real tree with the entry `submodules/llama.cpp/docs/llama-star/idea-arch.key` REMOVED returns rc 0. The entry is never consulted, and the path is not in either nested archive (`unzip -l`, `tar -tzf`).
  - Removing the `vendor/…` entry does fail (control).
- **Fix-G's claim refuted.** FIX-G says the check "would have failed on those two paths"; that does not hold for the second entry.
- **Fixture.** `.env` with the same content as `.env.example`, and an empty `keys/server.key`, were committed and deleted; rc 0, and neither path was listed.
  - The content is identical to blobs shipped under other names, so no NEW secret content leaks this way.
  - The documented property is still not what runs.
- **Fix.** Use the NUL-safe enumeration from C3-03 (it lists every path). Remove the dead allow entry, or justify it with a measurement. Correct the header, the docs page and the FIX-G report.
- **finding_layer:** process-doc

### C3-05 · MINOR · scripts/release/scan_archive.py:137,154-157 — nested-archive scan: single-top stripping hides `.env/` and `cert/` directories; allow entries widen across nesting levels; decompressed size is unbounded
- **(a) Stripping hides deny-listed directories.**
  - `archive/envs.tgz` holds `.env/`, `.env/prod`.
  - `archive/certs.tgz` and `archive/certs.zip` hold `cert/`, `cert/README`.
  - All three are reached as `tops == {".env"}` / `{"cert"}`, the top is stripped, and the scanner judges `prod` and `README`.
  - Scanner rc=0. Control: the same files un-nested give rc=1 (`SECRET PATH … .env/prod`, `cert/README`).
  - `tar czf certs.tgz cert/` is a natural command, and the nested scan is the ONLY line of defence for nested content: `build_archive`'s bash filter never opens it.
- **(b) Allow entries widen.** `if rel in allowed: continue` matches the nested-RELATIVE path against outer repo-relative entries. Every allow entry therefore exempts that path inside ANY nested archive at any depth, and the exemption also skips the PEM content check.
- **(c) The size bound is on compressed bytes only.** `MAX_NEST_BYTES` bounds the member's compressed size. A 4,174,599-byte nested `tar.gz` holding 4 GiB of zeros took 9.3 s of CPU (rc 0, members over 2 MB are not content-scanned). A 256 MiB nested gzip implies about 10 minutes.
- **Fix.**
  - Judge both the stripped and the unstripped path, flagging if either is secret.
  - Qualify allow entries for nested content as `<outer-path>!<inner-path>`.
  - Add a decompressed-bytes budget that fails closed.
- **finding_layer:** source-defect

### C3-06 · MINOR · scripts/release/build_archive.sh:267 (`_ba_check_gitlinks`) — unanchored `grep -F` substring: an uninitialised submodule ships EMPTY with rc 0
- **The cause.** The check is `grep -q -F "${base}/${dp}/"`, which matches the string anywhere in a line.
- **Reproduced.** In repo `proj`, gitlink `sub` was deinitialised and a tracked file `docs/proj/sub/readme` was added. `build_archive` gave rc=0, and the archive holds `proj/.gitmodules`, `proj/docs/proj/sub/readme` and `proj/m.txt`, with no `sub/` content.
- **Realistic case.** A monorepo checked out as `app`, with a gitlink `lib` and a tracked file `packages/app/lib/…`.
- **Doc contradicted.** `docs/scripts/build_archive.md:174` says it is "never exiting 0 with an empty submodule".
- **Fix.** Prefix-match only: for example `awk -v p="${base}/${dp}/" 'index($0,p)==1'`, or a bash `[[ $line == "$p"* ]]` loop.
- **finding_layer:** source-defect

### C3-07 · MINOR · lib/service_macos.sh:52,59 (`_svc_plist_str`, `_svc_plist_xml`) — XML escaping is broken under bash ≥ 5.2 (`patsub_replacement`)
- **The cause.** In `${s//</&lt;}` the unquoted `&` in the replacement expands to the matched text.
- **Measured on bash 5.3.9.** `a<b>c&d` → `a<lt;b>gt;c&amp;d`; `&` is correct only by coincidence. Rendering the engine plist with `LLMCTL_LOG_DIR` set to `…/lo<g>s` gives `xml.parsers.expat.ExpatError: not well-formed (invalid token): line 23`.
- **Exposure.** On macOS this hits whoever runs llmctl with Homebrew bash first on PATH, since every script uses `#!/usr/bin/env bash`. The fix-G test proves XML validity with an `&` only, which is the one character the bug leaves intact.
- **Fix.** Escape the `&`: `${s//</\&lt;}`, `${s//>/\&gt;}`, `${s//&/\&amp;}`. Add `<` and `>` to the test's path.
- **finding_layer:** source-defect

### C3-08 · MINOR · internal/registry/registry.go:670-683 (`DiffScope.keep`) + lib/portreg.sh:204 — the tenant prefix is ambiguous
- **The cause.** Tenant ids allow `-` (`service_linux.sh:74`: `^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$`), so `acme--eu` and `acme-` are valid tenants.
- **Probe test.** Tenant `acme`'s scoped diff reports `acme---small` and `acme--eu--small` as "row without a live service". That is the C2-03 false doctor FAIL again, for neighbouring tenant names.
- **The reverse case.** `NoTenantRows` drops ANY row containing `--`: a non-tenant row `qwen--7b` with no live service is silently not reported (a false negative).
- **Fix.** Record the tenant as a label at Register (`tenant=<id>`) and scope by the label. Or forbid `--` and a trailing `-` in tenant ids, and forbid `--` in profile names.
- **finding_layer:** source-defect

### C3-09 · MINOR · scripts/install_agents.sh:198-202,258 — the npm `--help` smoke accepts a crash, and the aider record overstates its smoke
- **The npm smoke.** `smoke_help="$(timeout 30 bin --help 2>&1 | head -c 200)"` ignores the exit status and merges stderr.
  - Reproduced with a fake bin whose `--help` prints `Error: Cannot find module better-sqlite3` to stderr and exits 1.
  - The install still gives rc 0, writes the shim, and records `"runtime_smoke":"version+help"`.
  - This is exactly the lazily-loaded-native-module case C2-18 describes.
- **The aider record.** It says `"runtime_smoke":"none (aider --version only)"`. On the verified path nothing is run at all; `--version` runs only on the UNVERIFIED path, to read the version.
- **Fix.**
  - npm: require exit 0, and judge stdout only.
  - aider: run `aider --version` as a real smoke on every path, or record `"none"`.
- **finding_layer:** source-defect

### C3-10 · MINOR · scripts/install_agents.sh:122,123,193,198 — `timeout` (GNU coreutils) is used unguarded
- **The cause.** Stock macOS has no `timeout`, so `--check` and every npm install fail there with rc 127. The --version smoke at :193 then refuses with a misleading "lifecycle scripts were skipped" message.
- **Scope.** The script names no platform restriction, and llmctl supports macOS.
- **Fix.** Use a `timeout` / `gtimeout` / perl-alarm fallback, or state the dependency and refuse early with an honest message.
- **Note.** `scripts/release/preflight_submodules.sh:95` has the same unguarded `timeout`; that file is pre-existing and unchanged.
- **finding_layer:** source-defect

### C3-11 · MINOR · tests/run_tests.sh:63-71 — zero-assertion and RESULT-FAIL suites still count as PASS
- **Measured with fake suites:**
  - `exit 0` with no output → `PASS test_silent.sh`.
  - `echo "RESULT: FAIL (3)"; exit 0` → `PASS`.
  - A suite that prints `SKIP-SUITE:` first, then `  ok:` lines → SKIP, even though assertions ran.
- **Format variants.** `\tFAIL:`, an ANSI-coloured `  FAIL:` and `  FAIL:x` are not seen. Every suite in `tests/` uses the canonical format today (grep), so this matters only for future suites.
- **Fix.**
  - An exit-0 suite with zero `  ok:` lines and no SKIP marker → FAIL ("asserted nothing").
  - Cross-check `RESULT: FAIL`.
  - Once SKIP-SUITE is printed, any later assertion line → FAIL.
- **finding_layer:** test-instrumentation

### C3-12 · MINOR · tests/test_no_stray_binaries.sh:16,22-26,33 — the control needle does not cover the enumeration path, and the detector misses whole classes
- **(a) The control is incomplete.** The needle proves only `is_binary`, on a file in mktemp. Mutation S8 narrowed the `git ls-files --others` enumeration to a nonexistent path while an untracked ELF was PLANTED in the work tree. The suite still PASSED (SURVIVED), so a broken enumeration is invisible (§11.4.201(7)(b)).
- **(b) Formats not detected:**
  - Windows PE (`MZ`): `GOOS=windows go build ./cmd/...` drops `llmctl-decide.exe`;
  - fat/universal Mach-O (`cafebabe`);
  - wasm.
  - Planted `stray.exe` and `stray_fat` files gave `RESULT: PASS`.
- **(c) Places not checked.** `--others` does not recurse into submodule work trees, and binaries that are already TRACKED are not checked at all. No tracked native binary exists in the real tree today (checked).
- **Fix.**
  - Plant the needle as an untracked file in the real tree under a trap, and assert that the enumeration reports it.
  - Add `MZ`, `cafebabe`/`bebafeca` (excluding Java class files by size or name) and `\0asm`.
  - Also scan `git ls-files` (tracked) and `git submodule foreach 'git ls-files --others --exclude-standard'`.
- **finding_layer:** test-instrumentation

### C3-13 · MINOR · tests/test_no_retired_vars.sh:58-61,76-89 — `--exclude-dir` applies at ANY depth, and the allow-list exempts whole files
- **Reproduced.** Production files `lib/tests/planted.sh` (`LLMCTL_ONNX_FAKE=1`) and `scripts/build/planted.sh` (`LLMCTL_DECIDE_API_KEY`) gave `RESULT: PASS`. Control: `lib/planted2.sh` with the same line gives FAIL.
- **The allow-list.** Whole files (`tests/test_scheduler.sh`, `CHANGELOG.md`, `docs/CONTINUATION.md`, …) are exempt line-independently. `EXPLAIN` words such as `never`, `must not` and `refuse` are generic.
- **Fix.** Exclude by top-level path (scan an explicit production root list and filter `^\./(docs|tests|specs)/`). Make allow entries `file:line-pattern`.
- **finding_layer:** test-instrumentation

### C3-14 · MINOR · tests/test_gateway_mutation.sh:37,84-91 — 3 of 19 "kills" come from the COMPILER, not from a test
- **Measured.** `go vet` of each mutant. Three are compile errors, which `mutate` counts as "tests RED":
  - `NLI generic label_source accepted`: `declared and not used: src`;
  - `NLI truncation not reported to the gateway`: `"…/internal/server" imported and not used`;
  - `symlinked key file accepted`: `declared and not used: st`.
- **Re-run as compilable mutants:**
  - the first two are KILLED by real tests (`TestNLIRefusesLabelsItCannotMapAndNeverGuesses`, `TestNLITruncatedOnlyAllowedWhenOptedInAndThenReportedToTheGateway`);
  - the symlink mutant SURVIVES. It is an equivalent mutant, because `O_NOFOLLOW` at `keyfile.go:51` still refuses the symlink, but the suite reports it as a proven guard.
- **Fix.** In `mutate`, require the mutant to compile (`go vet` / `go test -run XXX`) before reading a RED. Fix the three anchors so they compile, and drop or relabel the symlink mutation.
- **finding_layer:** test-instrumentation

### C3-15 · MINOR · test gaps exposed by surviving reviewer mutations
These are behaviours the fixes added that no test pins (see the mutation table):
- S1: the `.git`-pointer exclusion in the gitlink check;
- S2: nested strip-top;
- S3: the `--help` smoke refusal;
- S5: dirty-SUBMODULE detection (`--ignore-submodules=none` → `all` survives);
- S7: pinned-version-mismatch refusal;
- G5: the live-side `DiffScope` filter (equivalent in today's shell wiring, but the API contract "both sides" is untested).

**Fix:** add one RED-first assertion per survivor.
- **finding_layer:** test-instrumentation

### C3-16 · MINOR · internal/gateway/review2_test.go:249-254 — `TestEngineDeterministicRejectionsAreNonRetryable` is not repeatable
- **The cause.** `driver.go:86`, `loggedFaults sync.Map` logs each fault once per process.
- **Measured.** `go test -count=2 -run TestEngineDeterministicRejectionsAreNonRetryable ./internal/gateway` fails deterministically; `-count=1` passes 3/3.
- **Why it matters.** It breaks `-count=N` repeatability runs (§11.4.50), which this project uses for flake hunts. FIX-G itself ran `-count=200`.
- **Fix.** Reset `loggedFaults` in the test (a test hook), or make the dedupe per-driver.
- **finding_layer:** test-instrumentation

### C3-17 · MINOR · tests/test_vantage.sh:55-69 — the skip classifier decides SKIP before it is self-checked
- FIX-G moved the classifier self-check after `up` (stated as a limit). A regressed `no_image_skip_reason` that matches every `up` failure would therefore turn any rc=1 `up` failure into SKIP on exactly the hosts that skip.
- **Fix.** Run the canned-stderr self-check silently BEFORE the skip decision, without printing `  ok:` lines (exit 1 if it is wrong). Print the assertions after `up`.
- **finding_layer:** test-instrumentation

### C3-18 · MINOR · evidence/review-3/fix-G-report.md:86,68 — two FIX-G claims are not supported
- **Line 86.** "A static scan of `tests/` found none" (`  FAIL:` lines from nested output). `tests/test_install_script_e2e.sh` echoed `FAIL: linger is NOT confirmed` with a two-space indent and had to be fixed later by the lead (`sed 's/^/  | /'`).
- **Line 68.** "It would have failed on those two paths" is refuted for `submodules/llama.cpp/docs/llama-star/idea-arch.key` (C3-04).
- **Fix.** Correct the report (§11.4.6).
- **finding_layer:** process-doc

## Reviewer-authored mutations (all on the scratch copy; every file restored and `cmp`-verified)

| ID | Mutation | Result |
|---|---|---|
| G1 | `autoResolver.pick`: never re-check after the first pick | KILLED (`TestC213…`) |
| G2 | `DiffScope.keep`: drop the `NoTenantRows` branch | KILLED (`TestC203DiffIsScopedToTheTenantsOwnRows`) |
| G3 | `liveness`: no fingerprint adoption (`return true,false,""`) | KILLED (`TestC208…`) |
| G4 | `Register`: never reap a dead same-port row | KILLED (`TestRegisterRefusesLivePortCollisionButReapsDeadHolder`) |
| G5 | `DiffScoped`: drop the live-side scope filter | **SURVIVED** → C3-15 |
| G6 | `Register`: skip the identity check | KILLED (`TestC207…`, `TestReconcileDetectsPidReuseByDifferentProgram`) |
| G7 | vantage CLI `down = m.DownAll` → a no-op that compiles | KILLED (`TestC209…`) |
| S1 | `_ba_check_gitlinks`: count the `.git` pointer as a file | **SURVIVED** → C3-15 |
| S2 | `scan_archive.py`: always strip the nested top directory | **SURVIVED** → C3-05 / C3-15 |
| S3 | `install_agents.sh`: `--help` empty check → `if false` | **SURVIVED** → C3-09 / C3-15 |
| S4 | `portreg_register`: never retry "not (yet) running" | KILLED (2 assertions in `test_service_ops_hardening`) |
| S5 | dirty check: `--ignore-submodules=none` → `all` | **SURVIVED** → C3-15 |
| S6 | `scan_archive.py`: depth bound `>=` → `>` | KILLED (`C2-16 … depth bound FAILS CLOSED`) |
| S7 | `install_agents.sh`: drop the pinned-version-mismatch refusal | **SURVIVED** → C3-15 |
| S8 | `test_no_stray_binaries.sh`: enumeration narrowed to a nonexistent path, with a planted ELF | **SURVIVED** → C3-12 |
| H1 | `registry_resolver_publish_test.go`: `sh` → `bash` (host-shell simulation, not a code mutation) | FAILS 5/5 → C3-01 |

## Bash 3.2 / BSD portability of new and changed shell

**Searched:** `declare/local -A`, `mapfile`, `readarray`, `${x,,}`, `${x^^}`, `|&`, `&>>`, `coproc`, `[[ -v`, `local/declare -n`, `@Q`, `wait -n`, `sed -i`, `date -d`, `readlink -f`, `grep -P`, `stat -c`, `sort -V`, `xargs -r`, `timeout`, `printf -v`. Files: `bin/llmctl`, `lib/*.sh`, `scripts/*.sh`, `scripts/release/*.sh`, `templates/agents/*.sh`, `tests/run_tests.sh`, `tests/helpers.sh`.

| Location | Construct | Status |
|---|---|---|
| `scripts/release/build_archive.sh:135` | `${p,,}` | GUARDED: `BASH_VERSINFO>=4` inside `eval`; `tr` fallback at :137 |
| `scripts/install_agents.sh:122,123,193,198` | `timeout` | NOT guarded → C3-10 |
| `scripts/release/preflight_submodules.sh:95` | `timeout` | NOT guarded; pre-existing, file unchanged |
| `lib/download.sh:165` | `stat -c` | GUARDED: BSD `stat -f%z` is tried first |
| `lib/hardware.sh:156` | `readlink -f` | Linux-only `/sys/class/drm` path; pre-existing |
| `lib/decide.sh:343` | `printf -v` | OK: bash ≥ 3.1 |
| `lib/service_macos.sh:52,59` | `&` in a `${//}` replacement | Not a 3.2 problem; breaks on bash ≥ 5.2 → C3-07 |
| `tests/test_no_retired_vars.sh:54` (`\b` in `grep -E`); `scripts/doc_counts.sh` (`\s` in `grep -E`) | GNU grep extensions | UNCONFIRMED on BSD grep (no Mac) |
| `build_archive.sh` `tar --null -T --no-recursion --recursion` | GNU tar options | Documented as a dependency ("GNU tar") in the header; bsdtar has no `--recursion` |

- **Empty arrays under `set -u`.** The only reachable empty ones are in `build_archive.sh`, and they are guarded (:323, :381, :400). These are always non-empty or guarded by a length check:
  - `portreg.sh:205`;
  - the `install_agents.sh` arrays;
  - `run_tests.sh:85`;
  - `test_no_stray_binaries.sh:37`.
- **Not proven on a real bash 3.2:** C2-12 `${q//\$/\$\$}` and the regex literals in `_ba_is_secret_path`. There is no Mac (G-009).

## Checked, no defect found
- **Zip `-@` wildcard expansion with tracked names `d/*` and `d/[ab].md`:** no expansion; the untracked `d/notes.txt` and `d/a.md` were not shipped.
- **Restore:** see C2-01; the submodule `update --init` of the extracted tree works.
- **`portreg_register` retry contract:** only the "is not (yet) running" refusal is retried (`portreg.sh:113-118`, S4 KILLED); other errors are reported at once.
- **C2-14 port hold:** the unknown-prune path never calls `releaseIf` (`registry.go:535-537`).
- **The `run_tests.sh` exit path:** under `set -euo pipefail` it is consistent; every `grep`/`head` in a command substitution carries `|| true`.
- **`doc_counts.sh` HOSTDEP markers:** they only re-classify `  ok:` lines for the documentation count. A FAIL inside a marker block is still counted in `fail=`, so the markers cannot hide a failure. An unbalanced BEGIN is not flagged; that is low impact and only affects doc counts.
- **The lead's `registerAfterExec` (`serve_reconcile_test.go:183`):** a bounded 5 s retry, fatal with the last error. Fine. `victim` is `exec.Command("sleep","300")`, so its argv is stable.

## Could not verify (honest gaps, §11.4.6)
- macOS and launchd: plist acceptance, real bash 3.2, BSD grep/sed/tar. There is no Mac.
- Live systemd ExecStart `$$` read-back, real podman (`test_vantage`), and real npm/uv installs. I was instructed not to run them, and there is no network.
- The registry port-allocation flake under load (FIX-G's 8,000-connection reproduction); I did not re-run it.
- A full `make test`, and a `make archive` of the 2 GB real tree; only small fixtures were archived. The history check alone was run on the real tree.
- Whether `--ignore-scripts` breaks cn or cline on a fresh install (no network).

## Verdict
- **SOURCE: NO-GO** under §11.4.134's zero-finding rule.
  - **What is fixed.** All four round-2 IMPORTANT source defects (C2-01..C2-04) are genuinely FIXED, with runtime evidence from this session. No BLOCKING or IMPORTANT source defect remains.
  - **What is open: 9 MINOR source-defects** (C3-02, C3-03, C3-05, C3-06, C3-07, C3-08, C3-09, C3-10, plus the C3-04 claim correction). Two of them are fail-open holes in the release secret guards, each reproduced with rc 0:
    - C3-03: a newline-named key in history ships;
    - C3-05: nested `.env/` and `cert/` directories pass the scanner.
  - **If the gate treats MINOR as non-blocking:** GO with these tracked as §11.4.197 items.
- **TESTS: NO-GO.**
  - C3-01 is IMPORTANT: a lead-edited Go test fails deterministically on every host whose /bin/sh is bash, which makes `make test` RED on Fedora, RHEL, Arch and macOS.
  - Also open: compiler-killed mutants presented as proven guards (C3-14), the incomplete control needle in the new stray-binary guard (C3-12), an over-broad exclusion in the retired-vars guard (C3-13), a non-repeatable gateway test (C3-16), and 6 surviving reviewer mutations (C3-15).
- **DOCS / PROCESS: NO-GO, minor.** Two overclaims need correcting:
  - "every historical path is judged" / "never exiting 0 with an empty submodule" (C3-04, C3-06);
  - two unsupported FIX-G claims (C3-18).
