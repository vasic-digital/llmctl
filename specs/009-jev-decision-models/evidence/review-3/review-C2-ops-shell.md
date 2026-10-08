# Review 3 — Scope C2: ops / shell layer (round 2, re-verification of C-01..C-25 + new defects)

| Field | Value |
|---|---|
| Reviewer | independent adversarial reviewer, round 2. I did not write this code and did not do round 1. Read-only on the repo. |
| Date | 2026-10-07 |
| Tree | uncommitted work tree on `main`, HEAD a9ebefe |
| Inputs | evidence/review-2/review-C-ops-shell.md, including its "Fix status" section |
| Model/effort | Opus. Effort is not settable on this dispatch path, so it is recorded honestly as `?` (§11.4.231(F.2)). |

## What was run (evidence from this session)

**Timing.** Static review was done first. Every dynamic step ran only after `p4-make-test.done` appeared at 22:50; it reads `FINISHED rc=0`, and the log ends with `PASS: 74  FAIL: 0  SKIP: 0`.

**Dynamic steps** (each ran alone; nothing touched systemd or podman):
1. `git` reads over the real repo:
   - the history of deny-listed paths;
   - the largest blobs reachable from HEAD;
   - the nested archives `archive/llmctl.{zip,tar.gz}`, checked by name only.
2. A small real-git release fixture: a superproject plus one submodule, with a secret committed in one commit and deleted in the next. It was archived with `build_archive`, extracted, and checked with `git status`, `git submodule status`, `git ls-files --recurse-submodules` and `git fsck`. The extracted tree was then re-archived, and a dirty-tree archive was built.
3. A copy of the Go module plus `lib`/`scripts`/`tests` in a scratch directory. The baseline was `go test ./internal/registry ./internal/vantage`, green. Then six reviewer-authored mutations ran on that copy (see the Mutations section).
4. `scripts/install_agents.sh` was run against a fake `uv`, with a lock pin and an unreachable PyPI base (C2-02).
5. A real `llmctl-decide registry diff` was run against a shared state dir that held two tenants' rows (C2-03).

All scratch directories were created with `mktemp -d` and removed by their exact names. The repository was not modified, apart from this report.

## Round-1 findings — re-verification

| ID | Verdict | Evidence (file:line) |
|---|---|---|
| C-01 | FIXED, with a residual gap (C2-07, C2-08) | `internal/registry/process.go:35-78` matches argv[0], interpreter+script, an exact marker, or `--flag=token`; it no longer matches a path argument's basename. `ProcFingerprint` (`process.go:86-116`) is recorded at `Register` (`registry.go:296-298`) and compared in `alive` (`registry.go:167-175`). Mutations M-G1 (start time dropped) and M-G2 (no fingerprint at Register) were both KILLED by `TestC01RecycledPidOfSameProgramIsNotAlive`. |
| C-02 | FIXED for stash, branches, remotes, hooks and config. New defects introduced: C2-01, C2-05. | `scripts/release/build_archive.sh:165-196`. Reproduced in this session: the extracted fixture holds no stash, remote or hook, and its config holds only `[core]`. |
| C-03 | FIXED | Anchored regexes at `build_archive.sh:121-136`. Exact-path manifests at `build_archive.sh:72-109` and `scan_archive.py:52-68`. |
| C-04 | FIXED | `lib/engine.sh:160-213`. Covers absolute paths, `/`, symlinks, and ancestors of HOME, the data dir and the root. A marker must name the physical path. Mutation M-S4 (symlink guard removed) was KILLED, though only by a message assertion: behaviour is still protected by the marker check. |
| C-05 | PARTIALLY FIXED, see C2-03 | `lib/service_linux.sh:477-488` and `lib/portreg.sh:155-173` now list only this tenant's profiles. `registry diff` still compares against every tenant's rows (`internal/registry/registry.go:617-647`). Reproduced: `registry row without a live service: other--small`, rc=1. |
| C-06 | FIXED | `lib/download.sh:259-325`: the port is `auto` (ephemeral), and the pid must be alive AND own the LISTEN socket (`/proc/net/tcp` inode compared with `/proc/<pid>/fd`; lsof/ss fallbacks; an undecidable case fails closed). |
| C-07 | FIXED in the library. The CLI wiring of `--all` is untested (C2-09). | `internal/vantage/vantage.go:452-481`. Mutation M-G3 (DownAll restricted to own owner) KILLED. Mutation M-G4 (CLI `--all` ignored) SURVIVED. |
| C-08 | FIXED for npm. aider regressed under a pin, see C2-02. | `scripts/install_agents.sh:145-191` (npm pack → sha512 → install of that tarball, plus a `--version` smoke). |
| C-09 / C-10 | FIXED (tests) | Taken from the round-1 fix log; not re-mutated by me. |
| C-11 | FIXED | `registry.go:404-408` (`DefaultPortGrace` = 600 s). CLI at `cli.go:438-443`; gateway at `serve_resolver.go:100-105`. |
| C-12 | FIXED | `lib/service_macos.sh:298-305` and the Linux equivalent (dry-run guard). |
| C-13 | FIXED on the default paths only, see C2-04 | The plist wraps `svc_hook.sh run-engine` (`service_macos.sh:91-103`; `svc_hook.sh:168-176`). |
| C-14 | FIXED | `lib/svc_hook.sh:59-77` |
| C-15 | FIXED | `vantage.go:483-508` |
| C-16 | FIXED | `vantage.go:347-399`: a 0600 `req-*.json` file, `O_EXCL`; the container runs as `0:0`, so the host-owned file is readable. |
| C-17 | FIXED | `templates/agents/llmctl-gate-hook.sh:20-29` |
| C-18 | FIXED, with a residual `$` gap (C2-12) | `service_linux.sh:150-168` |
| C-19 | FIXED | `lib/admit.sh:567-578`. `die` in the subshell gives rc 1, which `admit --all` treats as an evaluation error (`admit.sh:697`). |
| C-20 | FIXED for the stated contract. New escape hatches: C2-06, C2-10. | `tests/run_tests.sh:36-61`. Mutation M-S1 (SKIP-SUITE accepted with rc≠0) KILLED. |
| C-21 | FIXED | Mutation M-S2 (a tracked secret is silently dropped instead of shipped-and-caught) KILLED by 4 assertions in `test_release_no_secrets.sh`. |
| C-22 | FIXED | `tests/test_catalog_json.sh:322-340` scans every `.md`, with a planted-line control. |
| C-23 | FIXED, with a residual semantic gap (C2-13) | `cmd/llmctl-decide/serve_resolver.go:121-130` |
| C-24 | FIXED | `registry.go:96-128`; `cli.go:425-455` and `cli.go:509-516`. |
| C-25 | FIXED | `lib/engine.sh` `engine_build all` = llama + colibri + onnx + decide. |
| G-067 | FIXED, with a narrow detector (C2-11) | `service_linux.sh:237-247` |
| G-074 | FIXED, with a port-release caveat (C2-14) | `registry.go:479-500` |
| G-078 | FIXED | `bin/llmctl:185-192` exits 2 with usage. |

## New findings

### C2-01 · IMPORTANT · scripts/release/build_archive.sh:183-191 (`_ba_sanitise_repo` minimal config) — submodules ship INACTIVE, so re-archiving a release silently drops all submodule content
- **The fix.** The shipped `.git/config` is cut down to `[core]` only, with no `submodule.<name>.url` and no `submodule.<name>.active`.
- **Measured on the extracted fixture:**
  - `git submodule status` prints `-645cf24… sub` (uninitialised).
  - `git ls-files --recurse-submodules` lists only `.gitmodules`, `m.txt` and `sub`; the submodule's files are missing.
  - Running `build_archive` on the extracted tree exits 0 (`BUILD2_OK`), but the new archive holds `sup/.gitmodules`, `sup/m.txt` and `sup/sub/.git`, and NOT `sup/sub/s.txt`.
- **Why it matters.** This is exactly the FR-014 "git archive is submodule-blind" gap the script exists to close. It is reintroduced for anyone who builds a release from a release, and it fails silently with exit 0.
- **Fix.**
  - Write `submodule.<name>.active=true` into the shipped config, plus `submodule.<name>.url` taken from `.gitmodules`; that URL is already scanned for userinfo.
  - Add a completeness check: every gitlink that `ls-files` lists must have its tracked files listed. Fail when a gitlink path yields zero files.
  - Assert `git submodule status` has no `-` prefix in `test_archive_completeness.sh`.
- **finding_layer:** source-defect

### C2-02 · IMPORTANT · scripts/install_agents.sh:199,223-227,232 — a PINNED aider silently installs `aider-chat@latest`, unverified, rc 0, and the record says `pinned:true`
- **Scenario.** `scripts/agents.lock` pins `pypi aider-chat 0.86.2 <sha>`. If the PyPI JSON fetch fails (offline, a proxy, an index mirror, a parse error, or a MITM that breaks only the JSON), `url` is empty and the else branch installs `aider-chat@latest`.
- **Reproduced in this session** (fake `uv`, `LLMCTL_AGENTS_PYPI_BASE=file://<missing>`):
  - `UV ARGS: tool install --force --python 3.12 --with pip aider-chat@latest`, with rc=0.
  - The installed version is 9.9.9, not the pinned 0.86.2.
  - The JSONL record reads `"method":"uv tool install of the verified wheel"`, `"integrity_verified":false`, `"integrity_source":"lock"`, `"pinned":true`.
- **Why it matters.** The pin is bypassed. The record claims both a lock source and a "verified wheel" method for an unverified latest install, which is a §11.4 record-layer bluff. It is also a downgrade channel: making one HTTP fetch fail turns off verification.
- **Fix.**
  - When `pinned=true` and no verified wheel can be had: exit non-zero, never fall back.
  - Make the unpinned fallback opt-in, e.g. `LLMCTL_AGENTS_ALLOW_UNVERIFIED=1`.
  - Set `method`, `integrity_source` and `pinned` truthfully on the fallback path: `pinned:false`, `integrity_source:"none"`, `method:"uv tool install aider-chat@latest (UNVERIFIED)"`.
  - Add a test: pin plus unreachable PyPI must fail.
- **finding_layer:** source-defect

### C2-03 · IMPORTANT · lib/portreg.sh:155-173 + internal/registry/registry.go:617-647 — false doctor FAIL whenever another tenant (or a non-tenant service) is registered in the same state dir (C-05 only half fixed; §11.4.201(1))
- **Scenario.** The live set is now this tenant's only, but `registry diff` compares it with EVERY row.
- **Reproduced:** rows `acme--small` and `other--small`, live set `acme--small=<pid>`, gives `registry row without a live service: other--small` with rc=1. `llmctl doctor` in tenant `acme` therefore FAILs because tenant `other` exists.
- **Shared state dir.** The tenant test fixture itself puts `other--small.env` next to `acme--*` in one services dir (`tests/test_service_ops_hardening.sh:53`), so the shared state dir is the modelled layout. The test registers only `acme--small`, so it cannot see the defect.
- **Fix.** Scope the diff by tenant: either `registry diff --prefix "${tid}--"`, or `--scope-names` holding the names this backend owns. Under a tenant, ignore rows outside the prefix. Without a tenant, ignore `*--*` rows of other tenants, or use a `tenant` label. Add a second-tenant row to the test.
- **finding_layer:** source-defect

### C2-04 · IMPORTANT · lib/service_macos.sh:79-118 (engine plist) vs :247-256 (gateway plist) — the new run-engine wrapper loses the operator's state dirs, so it neither rotates the key nor registers when `LLMCTL_STATE_DIR` / `LLMCTL_SERVICES_DIR` / `LLMCTL_LOG_DIR` / `XDG_STATE_HOME` are overridden
- **The cause.** The gateway plist carries an `EnvironmentVariables` dict for exactly this reason, and Linux puts `Environment=` lines in every unit (`service_linux.sh:189-193`). The engine plist has no such dict. `svc_hook.sh run-engine` sources `common.sh`, which falls back to the default directories, so `_hk_envfile` points to a file that does not exist there:
  - `hk_prestart` returns 0 without rotating;
  - `hk__wait_register` returns 1, so the service is never registered;
  - meanwhile `svc_start` no longer rotates (`service_macos.sh:137-144`).
- **Result.** The C-13 fix works only with default dirs. With an override, the macOS registry is always empty for engines (doctor FAILs: "live service without a registry row"), and per-start key rotation is silently lost (G-028).
- **Test gap.** The tests source the hook with the overrides already exported, so they mask this.
- **Fix.** Emit the same `EnvironmentVariables` dict (ROOT, STATE, LOG, SERVICES, CONFIG, DATA, RUNTIME, DECIDE_BIN) in the engine plist. Add a test that runs the wrapper with `env -i` plus only the plist's environment.
- **finding_layer:** source-defect

### C2-05 · MINOR · scripts/release/build_archive.sh:12-19,165-169 + scan_archive.py — the shipped `.git` carries the whole HEAD history, and nothing scans it
- **Reproduced.** A file committed in one commit and `git rm`'d in the next keeps its content in the extracted archive: `git log -p --all -- old.txt` shows `+SECRETLINE`.
- **Scope.** `scan_archive.py` judges only working-tree paths and the `.git` config/refs/hooks/logs, never history. Today this is benign:
  - HEAD == origin/main, so there are 0 unpushed commits;
  - the only deny-list path ever added in history is the public `idea-arch.key` deck;
  - but `archive/llmctl.zip`, a 46 MB blob, is tracked in HEAD and ships again inside every release.
- **Risk.** A secret committed and then deleted in an UNPUSHED commit ships.
- **Fix.** Either refuse unless HEAD is reachable from a remote-tracking ref or a release tag, or run the deny predicate over `git log --diff-filter=A --name-only` for the bundled range. Also state the property honestly in the header.
- **finding_layer:** source-defect

### C2-06 · MINOR · tests/test_vantage.sh:57-71 — a suite can hide assertion FAILs behind `SKIP-SUITE`
- **Scenario.** Four classifier assertions run first (lines 57-63). Then `SKIP-SUITE: …; exit 0` (lines 68 and 71) exits 0 regardless of `TEST_FAILS`. If one of those assertions failed on a host where `vantage up` is unavailable, the harness reports SKIP, not FAIL.
- **Harness gap.** `tests/run_tests.sh` never cross-checks `  FAIL:` lines when rc is 0 (lines 38-60).
- **Fix.**
  - Add a helper `skip_suite <reason>` that exits 1 when `TEST_FAILS > 0`.
  - Make the harness classify `rc==0` plus any `^  FAIL:` line as FAIL. This also catches the subshell-lost-counter trap generally.
- **finding_layer:** test-instrumentation

### C2-07 · MINOR · internal/registry/registry.go:296-298 + lib/scheduler.sh:316-345,726-735 — the fingerprint is taken without proving identity first, so an early publish pins a wrong fingerprint
- **Scenario.** `Register` records `ProcFingerprint(pid)` but never checks `OSIdentity(pid, token)`. `_sched_wait_ready` returns 0 at once when `LLMCTL_READY_TIMEOUT=0` or curl is absent; `_sched_registry_publish` then registers the systemd MainPID.
- **Effect.** If that pid has not yet `exec`'d from `/bin/bash -c` into the engine, the argv hash is bash's. The next reconcile removes the row as "not llama-server", and doctor FAILs until a later re-registration.
- **Fix.** In `Register`, refuse (usage error) or defer when `OSIdentity(pid, token)` is false. Fingerprint only a pid that already proves its identity.
- **finding_layer:** source-defect

### C2-08 · MINOR · internal/registry/process.go:96-110 + registry.go:171-173 — the fingerprint fails open
- **Scenario.** When `/proc/<pid>/stat` is unreadable but cmdline is readable (for example `hidepid`, or a race), `ProcFingerprint` returns "". `Register` stores an empty `proc_fp`, and `alive()` then skips the start-time check for that row forever. That silently drops back to the pre-C-01 guarantee.
- **Fix.** Treat a fingerprint that cannot be determined at Register as a refusal, or record `proc_fp=unavailable` and have reconcile retry. Do not equate it with "no fingerprint recorded".
- **finding_layer:** source-defect

### C2-09 · MINOR · internal/vantage/cli.go:135-138 — `vantage down --all` CLI wiring is not covered by any test
- Mutation M-G4 replaced `down = m.DownAll` with a no-op. Every vantage, probecore and cmd test stayed green; `tests/test_vantage.sh` never calls `--all`.
- **Fix.** Add a CLI test with a fake runtime: two owners plus `down --all` must remove both.
- **finding_layer:** test-instrumentation

### C2-10 · MINOR · scripts/doc_counts.sh:57-71 — a suite that prints `  FAIL:` lines but exits 0 is counted without error
- `fail=` is computed but never fails the run. Together with C2-06, a lost-counter bluff is visible in the record yet never acted on.
- **Fix.** `fail>0 && rc==0` should be `status=inconsistent` and exit 2.
- **finding_layer:** test-instrumentation

### C2-11 · MINOR · lib/service_linux.sh:237-247 (`svc_stale_units`) — the stale detector knows exactly one historical defect
- Only `StartLimit*` inside `[Service]` is flagged. A unit from before the registry hooks or the C-18 quoting is not reported as stale. It then shows up as a doctor FAIL ("live service without a registry row") whose remedy, "registry reconcile", cannot fix it.
- **Fix.** Compare the installed body with the current generator output (`diff` against a fresh render) and WARN on any difference.
- **finding_layer:** source-defect

### C2-12 · MINOR · lib/service_linux.sh:166-168 (`_svc_hook_cmd`) — `$` is not escaped in ExecStart= words
- systemd expands `$VAR`/`${VAR}` in ExecStart arguments, even inside double quotes; a literal `$` must be written `$$`. `_svc_q` doubles `%` and escapes `\` and `"`, but not `$`.
- **Effect.** An `LLMCTL_ROOT` containing `$` (pathological, but C-18 explicitly targeted special characters) breaks the hook path.
- **Fix.** Double `$` in a `_svc_q` variant used for exec lines. Do not double it for `Environment=`, where `$` is literal.
- **finding_layer:** source-defect

### C2-13 · MINOR · cmd/llmctl-decide/serve_resolver.go:121-130 — auto mode is decided once, at startup
- A gateway started in `auto` mode before any decision engine has registered picks static mode and never re-evaluates. Engines take up to 600 s to register (cold load). Before the fix, any row switched it to registry mode.
- The unit wrapper forces `registry` (`svc_hook.sh:192`), so this affects only manual `serve`.
- **Fix.** Use a resolver that re-checks `Resolve(kind=decide)` on each refresh in auto mode, or document the startup-snapshot semantics.
- **finding_layer:** source-defect

### C2-14 · MINOR · internal/registry/registry.go:486-492,538-541 — `--prune-unknown-after` also releases the port hold of a LIVE process
- An "unknown" row is alive by definition: it passed `r.alive`; there is just no CA. Pruning it calls `releaseIf(name, port)`, which hands the port back to the pool while the service still listens on it.
- The next allocation is protected only if the allocator bind-tests. That is UNCONFIRMED here; I did not read Allocate's bind-test path for this case.
- **Fix.** Prune the row but keep the hold, or release it only when the process is gone.
- **finding_layer:** source-defect

### C2-15 · MINOR · scripts/release/build_archive.sh:146-160 — a dirty or partially committed tree is archived silently
- **Reproduced.** Modify a tracked file and add an untracked file. The archive builds with rc 0 and ships the modified file, while the untracked one is omitted. The extracted tree shows ` M m.txt` against the shipped HEAD.
- **Today's tree.** It has 157 dirty paths, and the new code depends on untracked `lib/portreg.sh`, `lib/svc_hook.sh`, `cmd/`, `internal/` and `scripts/release/scan_archive.py`. A `make archive` now would produce an archive that cannot run: build_archive inside it would die with "allow manifest missing".
- **Fix.** Refuse when `git status --porcelain --ignore-submodules=none` is non-empty, unless `BA_ALLOW_DIRTY=1` is set and the override is recorded in the archive.
- **finding_layer:** source-defect

### C2-16 · MINOR · scripts/release/scan_archive.py — the "independent post-scan" does not descend into nested archives
- Tracked `archive/llmctl.zip` and `archive/llmctl.tar.gz` ship inside every release, and the scanner treats them as opaque bytes.
- **Today.** They are clean: I listed them by name, and they hold no `.git`, stash or key paths apart from the public `idea-arch.key` / `.env.example`. A secret inside a nested archive would still pass.
- **Fix.** Either recurse into `.zip` / `.tar*` / `.tgz` members, or refuse nested archives that are not allow-listed. Also consider dropping the stale tracked `archive/` blobs, after operator confirmation per §11.4.122.
- **finding_layer:** source-defect

### C2-17 · MINOR · scripts/release/build_archive.sh:264-266 — bash < 4.4 incompatibility
- `"${gitpart[@]}"` with an empty array under `set -u` raises "unbound variable" on bash 3.2/4.0-4.3. That covers the non-git-source path on macOS `/bin/bash`.
- **Fix.** `${gitpart[@]+"${gitpart[@]}"}`.
- This is the only bash-3.2 defect my sweep found in the new or changed code; see the portability statement below.
- **finding_layer:** source-defect

### C2-18 · MINOR · install_agents `--ignore-scripts` — the `--version` smoke is a weak oracle
- **What I checked.** In the already-installed tree, `cline@3.0.69` has `postinstall: node ./postinstall.mjs || true`. Its comment says it only creates a hard-link cache (`bin/.cline`) for fast startup, and the platform binary comes from an optional dependency, which npm installs even with `--ignore-scripts`. `protobufjs`'s postinstall is a version check. `@continuedev/cli` has no install scripts in node_modules to depth 3.
- **Conclusion.** `--ignore-scripts` very probably does NOT break cn/cline. That is UNCONFIRMED: no reinstall was done, because there is no network.
- **The weakness.** A native module that is only loaded at run time (sqlite, pty, keytar) could still pass `--version` and fail on first real use.
- **Fix.** Add a headless smoke (`cn -p` / `cline -y` against the local gateway) to `--check`, or record `runtime_smoke:"version-only"`.
- **finding_layer:** process-doc

### Observed flake (UNCONFIRMED root cause)
- `TestFixedAllocationBlocksDynamicOnSamePort` (`internal/registry/ports_test.go:243`) failed once in six full-package runs on my copy. That run carried mutation M-G1, which touches only the fingerprint and not ports.
- It passed in the other five runs and in 3× isolated runs.
- A free-port race via `freePortBlock` is plausible but NOT proven.
- Track it under §11.4.248; I did not capture the failure message.

## Bash 3.2 portability (new and changed shell)
- **Searched** in `bin/llmctl`, `lib/*.sh`, `scripts/*.sh`, `scripts/release/*.sh` and `templates/agents/*.sh` for: `${x,,}`/`${x^^}`, `declare/local -A`, `mapfile`/`readarray`, `|&`, `&>>`, `coproc`, `@Q`, `declare/local -n`, `[-1]`, `wait -n`, `;;&`, `EPOCH*` and `globstar`.
- **Found:** only `build_archive.sh:126`, which is correctly fenced behind `BASH_VERSINFO >= 4` inside `eval`, plus Python code inside heredocs.
- **Empty-array expansions under `set -u`:** only C2-17 is reachable while empty.
- **Not proven:** that every construct behaves the same on 3.2 (no Mac, G-009).

## Test-bluff hunt (assertions in subshells)
- I ran a heuristic subshell tracker over all new and modified `tests/test_*.sh` files. Every hit I opened turned out to be a false positive: a multi-line `$( … )` closed before the assertion, or a one-line `( … ) || rc=$?`.
- `test_admit.sh:171-181`, `test_agent_kit.sh`, `test_registry_discovery.sh:224-246`, `test_gateway_endpoints.sh:121-126`, `test_decide_cli.sh:228-239` and `test_mcp_stdio.sh:120-130` keep their counters in the parent shell.
- No proven lost-counter bluff. The harness-level guard is still missing (C2-06 / C2-10).

## Mutations (reviewer-authored, on a copy in a `mktemp -d` scratch dir, removed by exact name)

| ID | Mutation | Result |
|---|---|---|
| M-G1 | `ProcFingerprint`: drop the start-time field (boot id + argv hash only) | KILLED (`TestC01RecycledPidOfSameProgramIsNotAlive`) |
| M-G2 | `Register`: never compute `ProcFP` | KILLED (same test) |
| M-G3 | `DownAll`: sweep only own owner | KILLED (`TestC07DownRemovesOnlyItsOwnStateDirsContainers`) |
| M-G4 | `vantage down --all` CLI: `down = m.DownAll` → no-op | **SURVIVED** → C2-09 |
| M-S1 | `run_tests.sh`: SKIP-SUITE accepted even when rc≠0 | KILLED (`test_run_tests_format.sh`, 2 assertions) |
| M-S2 | `build_archive`: a tracked secret is silently dropped instead of shipped-and-caught | KILLED (`test_release_no_secrets.sh`, 4 assertions) |
| M-S4 | `engine_venv_prepare`: symlink guard removed | KILLED, but only by the message assertion; behaviour stays protected by the marker check |
| (demo) | C2-02 reproduced directly on the unmodified script (fake `uv`) | defect confirmed |

- **Environment note.** `test_release_no_secrets.sh` fails the same 2 assertions on a non-git copy, with and without the mutation (the D-30 RED scenario needs a git checkout). This is identical to round 1, and it passes in the real tree (p4 log).

## Could not verify (honest gaps, §11.4.6)
- Live systemd and launchd behaviour, real podman, and real `npm` / `uv` installs: I was instructed not to touch them, and there is no network.
- macOS: C2-04 and C2-17 come from static reasoning only.
- C2-14's allocator bind-test behaviour.
- The root cause of the observed registry flake.
- A full `make archive` of this 2 GB tree: only the small fixture was archived.

## Verdict
- **SOURCE: NO-GO.**
  - Most of round 1 is genuinely fixed: C-01 through C-25 are FIXED or FIXED-with-residual, and the claims I re-mutated held.
  - But four new IMPORTANT source findings block GO under §11.4.134:
    - C2-01: release archives ship inactive submodules, and a re-archive silently loses submodule content, a regression introduced by the C-02 fix.
    - C2-02: a pinned aider falls back to an unverified `@latest`, and the record claims `pinned:true` and "verified wheel".
    - C2-03: the tenant-mode doctor still false-FAILs; C-05 is only half fixed.
    - C2-04: the macOS run-engine wrapper loses overridden state dirs, a regression of the C-13 fix plus a loss of key rotation.
- **TESTS: NO-GO, minor.**
  - Survivor M-G4 (C2-09).
  - The SKIP-SUITE-after-failure escape (C2-06) and the unacted `FAIL:` lines in the harness and doc_counts (C2-10).
  - Missing restore assertions in the archive tests (part of C2-01).
  - No pin-plus-offline test (C2-02).
  - No second-tenant row in the C-05 test (C2-03).
  - No env-isolated macOS wrapper test (C2-04).
  - The make-test run itself is green: 74/0/0.
- **DOCS: GO with minor fixes.** The `build_archive.sh` header overclaims "clean git status" and "only the objects reachable" (C2-05, C2-15). C2-18 should be recorded honestly.
