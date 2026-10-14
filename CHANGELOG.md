# Changelog

All notable changes to llmctl are documented here. Entries below `## v3.0.2`
are the full conventional-commits history since `v2.0.0`, generated
deterministically by `scripts/release/create_release.sh`'s
`release_generate_changelog` function (same function used for the actual
GitHub/GitLab release notes, so this file and the published release notes
never drift).

**Note on `v3.0.0` and `v3.0.1`**: both tags were created but never
published as a release on either forge - the release-packaging preflight
(the tool designed for exactly this) kept catching real, genuine bugs
before any artifact was built: `preflight_run()` leaking a bash trap into
its caller (masking further checks), `submodules/colibri` / `submodules/
superspec` / `submodules/llama.cpp` all pinned to local-only, never-pushed
commits (confirmed genuinely unreachable), `constitution/submodules/
design-toolkit` silently skipped by the walker entirely, and finally the
fetch timeout being too short for `llama.cpp`'s huge upstream. Rather than
delete/recreate tags each time, every fix landed as a normal follow-up
commit and `v3.0.2` is the actual published release, at the first commit
where `scripts/release/preflight_submodules.sh` reports a fully clean
`PREFLIGHT PASSED` (27/27 submodules, zero FAIL, zero UNKNOWN) AND the full
35-file test suite is green. Both `v3.0.0` and `v3.0.1` tags remain in the
repository as an honest record of that process.

## Unreleased

* **fix(validate): a validation record names its host.** `$LLMCTL_STATE_DIR/validation/<profile>.json` now carries
  `host` (`socket.gethostname()`); `require-validated` and the start hook refuse a record from another host or one
  without the field (copied state directory, shared home). Existing records written before this change lack `host`
  and are therefore refused once; `llmctl validate <profile>` writes a new one. Test-first: 5 new assertions in
  `tests/test_vision_validate.sh` (RED 4 FAIL, then GREEN).
* **docs:** `validate` / `vision validate` / `validate-all` / `require-validated` section in the user manual, a
  validation step in the tutorial and quickstart, "Vision golden screenshots" in `docs/golden-set.md` (generator,
  byte reproducibility, font handling, measured tesseract limits), and a gate flow diagram in `docs/validation.md`.
  `scripts/vision/make_golden.py` pointed at a non-existent `docs/vision-golden.md`; it now points at the real section.

## 3.2.2 (2026-10-13)

A **patch release: duplicate-engine-unit robustness, host-safety verification, governance-test and documentation corrections.** Scope since `v3.2.1`: `lib/onnx_server.py`, `lib/portreg.sh`, `lib/svc_hook.sh`, `scripts/hostsafety/` (`install.sh`, `guard.py`, `bounded-run`, new `agent-run`), comments in `lib/scheduler.sh` and `lib/service_linux.sh`, tests, carrier files (`CLAUDE.md`, `AGENTS.md`, `QWEN.md`, `GEMINI.md`), the `constitution` submodule pin, `config/covenant_propagation_exclusions.tsv`, `docs/`, and the version pins. No catalog, unit-template or CLI command-surface change.

**Release status (read first).**

- **The fixes below were proven hermetically** (fake registry, fixture files, unit text assertions, one test per fix; each in `tests/`), not on the live units of the affected host. Which of the two registry mechanisms described under Fixed occurred on that host is UNKNOWN.
- **Not live-proven:** the live-test runner extension (below) was proven with hermetic fakes only. The host-safety guard (`scripts/hostsafety/guard.py`) is still in DRY-RUN and has not been armed; its improvements below were exercised against fixtures, not against a live memory-pressure event.
- **Live evidence is unchanged in kind:** the guarded live test has now run twice, on one host, for profile `vision` only (21 pass / 0 fail / 0 undetermined each time as recorded in `docs/qa/vision-live-2026-10-13/` and `docs/qa/vision-live-2026-10-13-run2/`). Every other profile is UNKNOWN. Nothing about the validation gate changed.
- The standing caveats are unchanged: manual QA was operator-waived; macOS is verified statically only; Windows is unsupported; accuracy figures are provisional.
- Installed user units are not changed by upgrading the checkout; re-run `llmctl install` to refresh them.

### Added

- **Agent containment tooling (`scripts/hostsafety/`).** `bounded-run` gains `--agent` (profile: TasksMax=200, MemoryMax=1G, 300 s), `--tasks N`, `--mem SIZE` and `--timeout S` (long forms of `-m -t -T`; short options win; `BOUNDED_RUN_*` environment variables override the profile), invalid `-m`/`-s` values and unknown long options exit 125, and a scope systemd cannot start exits 125 with the command not run. The scope also carries `RuntimeMaxSec=timeout+10` and `TimeoutStopSec=5` as a second, independent wall-clock limit that still ends the command if the wrapper and its watchdog are both killed. New `scripts/hostsafety/agent-run` is `bounded-run --agent`. New shim self-recursion lint (`tests/lint_shim_self_recursion.py`, `tests/test_shim_no_self_recursion.sh`) flags generated PATH shims that call themselves or a sibling shim by bare name. Honest coverage on this repository: 108 shim sites recognised, 95 with a resolved name and checked, 10 with a dynamic name that cannot be resolved (counted, not checked); Go test shims (6) are not run through `PATH` and Python shebang literals (5) are counted and not checked. Tests: `tests/test_agent_containment.sh`, `tests/test_shim_no_self_recursion.sh`. See `docs/host-safety.md`.
- **Host-safety guard improvements (still DRY-RUN).** `guard.py` gains a `tasks_storm` rule (cgroup `pids.current` group size; a scope above `HOSTSAFETY_TASKS_STORM`, default 2500, while PSI full is high is tried first as the would-kill candidate, used only if its cost is at least `HOSTSAFETY_STORM_MIN_COST_FRAC` = 0.5 of the PSI-ranked pick), bounded logs (a would-kill record carries a pid count and the first and last 20 pids, not all pids), size-capped gzip rotation of `guard.log` (default 5 MiB, keep 3, floor 1 MiB, keep clamped 1..10), 0600 permissions on its log, archive and state files, and a lower walk cost (`/proc` is walked only when sustained pressure needs a victim). The guard unit sets `TimeoutStartSec=15`, and, after `llmctl install` / the hostsafety install, `Nice=19`, `IOSchedulingClass=idle`, `CPUWeight=10` and `MemoryMax=256M` (new behaviour for installed users; the guard stays dry-run). With a fixture `--proc-root` the guard refuses to signal (`refused-fixture-proc-root`; the test-only hook `HOSTSAFETY_TEST_ALLOW_FIXTURE_PROC=1` lifts this in tests). `RuntimeMaxSec` has no effect on a `Type=oneshot` unit (systemd.service(5); probed) and is deliberately not used there. Arming the guard remains an operator decision. Tests: `tests/test_hostsafety.sh`.
- **Live-test runner: profiles and dynamic switching.** `scripts/livetest/vision_live_test.sh` (name kept) now drives any catalog profile that passes a per-host allow-list, and `scripts/livetest/run_profiles.sh` runs an ordered list (or `--fitting`) one profile at a time. `scripts/livetest/lt_profiles.py` derives the allow-list from the catalog, `llmctl plan --json` (the profile must fit the current free RAM/VRAM) and `llmctl models verify` (checksums), and requires a validation suite; large profiles also need `--allow-large`. Pass criteria are suite-aware (vision, chat, coder and embedding suites; expected counts come from the suite files). Loading is dynamic switching: the driver records the resident set first (fails closed if `llmctl status --json` cannot be read), loads the profile with `llmctl switch`, and afterwards restores the prior set with pressure-gated, health-checked starts (exit 6 = restore skipped or left for the operator, exit 7 = restore failed; a machine-readable `RESTORE_STATE=` line ends the verdict). `--plan` is a dry run that prints what would be stopped, started and restored; `--no-restore` leaves the restore to the caller and prints a warning when a resident set was switched off. The 300 s restore bound (`RESTORE_BOUND`, one restore `llmctl start`; the main start limit is 120 s) is only a wait deadline (the tool stops waiting, signals nothing; the operator abort path is `systemctl --user stop <engine>@<profile>.service`). Tests: `tests/test_livetest_switch.sh`, `tests/test_livetest_profiles.sh`, `tests/test_livetest_runner.sh`, `tests/test_livetest_watchdog.sh`; protocol in `docs/live-test-protocol.md`. **Limits (read first):** hermetic fakes only; only profile `vision` has ever run live (two runs, one host); behaviour against a real `llmctl` for enabled services such as `decide-nli` is UNKNOWN; the shipped catalog has no embedding profile (that suite is exercised by a fixture profile); a run STOPS every resident llmctl service, enabled ones (e.g. the decision gateway backend) included, by design, and restores them afterwards; the roughly 80 s per-profile restore bound (`LLMCTL_START_WAIT` 20 s + `LLMCTL_READY_TIMEOUT` 60 s, plus time queued on the scheduler lock) is derived from the code, not measured; SIGKILL or power loss between the switch and the restore leaves nothing to restore the set (`RESTORE_MANUAL.txt` in the evidence directory is the recovery).
- Tests for each fix: `tests/test_onnx_eaddrinuse.sh`, `tests/test_dup_unit_registry.sh`, `tests/test_kill_waiter_pid_prefix.sh`, `tests/test_hostsafety.sh` (extended: effective-vs-installed verify), `tests/test_constitution_inheritance_worktree.sh`, `tests/test_carriers_pointer_form.sh`, `tests/test_docs_restart_policy.sh`.
- [`docs/qa/vision-live-2026-10-13-run2/`](docs/qa/vision-live-2026-10-13-run2/README.md): the second guarded live run of profile `vision` (same host), including the unit's cgroup `MemoryPeak`.
- [`docs/release-3.2.2-checklist.md`](docs/release-3.2.2-checklist.md): the release checklist of this patch (nothing in it has been executed against a remote).

### Changed

- **Measured calibration datum (no limit changed).** Unit `MemoryPeak` of `vision` was 3151007744 B (3005 MiB) on one host, in run 2 of 2. It is below the profile's `MemoryHigh` (5120 MiB) and `MemoryMax`. It is one measurement on one host; the memory-cap floors are unchanged.
- **Stale restart-policy statements corrected** in `CLAUDE.md`, `AGENTS.md`, `QWEN.md`, `GEMINI.md`, `docs/` and code comments: units use `Restart=on-failure` with a start limit (exit 98, `SIGKILL`, `SIGTERM` are not restarted), not `Restart=always`. A stale gateway memory-policy comment in `lib/service_linux.sh` was corrected the same way. Documentation and comments only.
- **Constitution pin moved** from `3e8e855` to upstream `4091798af478783bee6759c867242157a11dc735`. Deliberately not the newer constitution commit that vendors llmctl itself: the pin must not contain llmctl (cycle guard).
- **`tests/test_constitution_inheritance.sh` skips invariants 9 and 10 loudly** when the constitution's nested submodules are not initialised (one SKIP line per invariant, counted by `tests/run_tests.sh`; the summary no longer claims all invariants passed). The skip applies only when every nested submodule the harness requires is a gitlink in the pinned tree and its directory is empty; broken content, a required name missing from the pin and initialised-but-broken submodules still FAIL. `LLMCTL_REQUIRE_NESTED_SUBMODULES=1` refuses the skip. Negative controls: `tests/test_constitution_inheritance_nested.sh`. The strict run needs the nested submodules, hence network.
- **`config/covenant_propagation_exclusions.tsv`** lists three per-entry-justified carrier exclusions for vendored third-party trees (superspec examples, `submodules/superspec`, `submodules/llama.cpp`); own-org submodules are not excluded.
- **`tests/test_docs_gate_not_advisory.sh` default release-notes path** moved from `~/llmctl-release-3.2.1/RELEASE_NOTES.md` to `~/llmctl-release-3.2.2/RELEASE_NOTES.md`; set `LLMCTL_RELEASE_NOTES` to scan another file.
- **`AGENTS.md` uses the standard `## INHERITED FROM constitution/AGENTS.md` pointer heading** (checked by `tests/test_carriers_pointer_form.sh`).
- Version pins moved from 3.2.1 to 3.2.2 (`VERSION`, `bin/llmctl`, `README.md` banner and status table header, `docs/*.md` version statements, the OpenAPI `info.version`). The `llmctl-decide` gateway and its `decide scale`, `decide calibrate`, `probe-order` and `completions` commands, per-type maturity labels, `llmctl doctor`, `llmctl status --json`, the planner's `overhead_mb` term, the `LLMCTL_CTX_<PROFILE>` overrides and the scheduler's eviction rules are the 3.2.1 code (the only edits under `lib/scheduler.sh` are comments).

### Fixed

- **`lib/onnx_server.py` exits 98 on `EADDRINUSE`.** Previously the loser of a bind race exited 1, so systemd retried it into the start limit; now exit 98 is in the unit's no-restart set and the duplicate unit stops.
- **The registration waiter no longer overwrites a live engine's registry row** (`portreg_row_live_other` in `lib/portreg.sh`, used by `lib/svc_hook.sh`), and **the loser's stop no longer kills the winner's waiter**. Together these remove both candidate mechanisms for the case where `llmctl status` showed nothing while the winner answered (hermetic proof only); the exact mechanism on the affected host is UNKNOWN.
- **`_hk_kill_waiter` delimits the pid in its command-line match,** so stopping pid 123 no longer matches the waiter of pid 1234.
- **`scripts/hostsafety/install.sh verify` compares the effective limits to the installed drop-in** (not a re-derived `MemTotal`) and **fails closed** when it cannot derive the expected limits.
- **The constitution inheritance test measures the right repository in a linked git worktree** (it inspected the enclosing project instead of the submodule's own repository), and its own-repo check also rejects a symlink back to the enclosing project.

### Security

- `scripts/hostsafety/install.sh verify` now fails closed instead of passing when it cannot derive the limits it checks.
- The host-safety guard writes its log, archives, status and victim-state files with mode 0600 (existing files are chmod-ed), and caps what a would-kill record logs.
- **Incident 2026-10-13 (factual note).** A self-recursive PATH shim running in an uncapped session scope exhausted the task count and hung the host. This release adds containment (`bounded-run --agent`, `agent-run`, the scope `RuntimeMaxSec` second limit, the shim self-recursion lint) and the guard improvements above. The `helixagent` stack and the host's `oomd` settings are outside this release and unchanged by it. UNKNOWN: whether tearing down a whole enclosing session cgroup also ends a capped scope.

### Removed

- Nothing.

### Migration notes

- None required. To pick up the exit-98 behaviour on already installed engine units, run `llmctl install` (refreshes units). Duplicate enabled engine units that exist before the upgrade (known case `decide-nli`: `llmctl-llama@` and `llmctl-onnx@`) are reported by `llmctl doctor` and are **not** removed; run `llmctl disable <profile> && llmctl enable <profile>` to keep one.

### Known limitations

- **Duplicate enabled engine units remain possible** until the operator runs `llmctl disable` then `llmctl enable`; `llmctl doctor` flags them. The fix makes the loser stop cleanly and not corrupt the winner's registry row; it does not remove the duplicate.
- **Hardware-specific evidence.** Both live runs and the `MemoryPeak` datum come from one host and one profile; behaviour on other hosts and profiles is UNKNOWN.
- **Process `VmHWM` is UNKNOWN** (only the cgroup peak was captured).
- **Only profile `vision` has been live-tested** (two runs, one host); every other profile is UNKNOWN, including every profile the new live-test runner can now select.
- Everything in the 3.2.1 and 3.2.0 "Known limitations" still applies, including the waiter gap (port registry inactive means no validation on the systemd path).

## 3.2.1 (2026-10-13)

A **documentation and help-text correction release**. No script, library, unit-template or catalog behaviour changed since 3.2.0: `git diff --stat v3.2.0..` touches `CHANGELOG.md`, `bin/llmctl` (the `help` text only), `docs/`, one new test and the version pins. The only edit in `bin/llmctl` besides the `LLMCTL_VERSION` pin is in the text printed by `llmctl help`.

**Release status (read first).**

- **The 3.2.0 tag and tarball are immutable and keep the stale text.** The 3.2.0 documentation and `llmctl help` called the model validation gate advisory (a wrong answer leaving the service running, systemd-started units skipping the hook). That was wrong for the shipped code: the gate is enforced. 3.2.1 supersedes those documents; the release notes of 3.2.0 were corrected on the forges after publication, the 3.2.0 tarball was not and cannot be.
- **No new live evidence.** Everything said in the 3.2.0 section about the live test (profile `vision`, this host only, one run) stands exactly as written there and is not repeated or extended here. The livetest GPU-peak fix and the cgroup peak capture were already in 3.2.0 (no script changed after the tag; `git log v3.2.0..main -- scripts bin` lists only the help-text commit).
- The standing 3.1.0 / 3.2.0 caveats are unchanged: manual QA was operator-waived; macOS is verified statically only; Windows is unsupported; accuracy figures are provisional; restart, memory-cap and pressure-gate behaviour was tested hermetically, not under a real memory-pressure event.

### Added

- `tests/test_docs_gate_not_advisory.sh` (reference: [`docs/scripts/test_docs_gate_not_advisory.md`](docs/scripts/test_docs_gate_not_advisory.md)): proves its scanner against planted stale sentences, then fails if `README.md`, `CHANGELOG.md`, `docs/*.md`, the `llmctl help` text or the release notes (`LLMCTL_RELEASE_NOTES`, default `~/llmctl-release-3.2.1/RELEASE_NOTES.md`) call the validation gate advisory, and asserts the enforcement and the waiter gap are stated.
- [`docs/release-3.2.1-checklist.md`](docs/release-3.2.1-checklist.md): the release checklist of this patch (nothing in it has been executed against a remote).

### Changed

- **Documentation and `llmctl help` now state that the validation gate is enforced:** `start`, `switch`, `auto`, `enable`, `restart` and systemd-started units (boot, `Restart=`, `systemctl start`, through the registration waiter) run the suites once after the profile is ready; a FAIL stops the profile and exits non-zero; UNDETERMINED never stops or passes it (`LLMCTL_VALIDATE_STRICT=1` stops it). Touched: [`docs/validation.md`](docs/validation.md), [`docs/architecture.md`](docs/architecture.md), [`docs/faq.md`](docs/faq.md), [`docs/limitations.md`](docs/limitations.md), the 3.2.0 CHANGELOG entries below, and the `llmctl help` VALIDATION and ENVIRONMENT text (`LLMCTL_VALIDATE_ON_START` now lists `enable` and `restart`).
- **Documented gap, not a behaviour change: the waiter.** The systemd path validates only when the port registry is active (`LLMCTL_PORTREG`); when it is inactive the waiter does nothing and the unit starts without the gate. It reads the unit's environment, not the operator's shell, so `LLMCTL_VALIDATE_STRICT` / `LLMCTL_VALIDATE_ON_START` belong in a unit drop-in, and it validates only catalog LLM profiles. See [`docs/limitations.md`](docs/limitations.md) and [`docs/validation.md`](docs/validation.md).
- Version pins moved from 3.2.0 to 3.2.1 (`VERSION`, `bin/llmctl`, `README.md` banner and status table header, `docs/*.md` version statements, the OpenAPI `info.version`). The `llmctl-decide` gateway and its `decide scale`, `decide calibrate`, `probe-order` and `completions` commands, per-type maturity labels, `llmctl doctor`, `llmctl status --json`, the planner's `overhead_mb` term, the `LLMCTL_CTX_<PROFILE>` overrides and the scheduler's eviction rules are byte-for-byte the 3.2.0 code.

### Fixed

- The stale statements listed under Changed (advisory gate; systemd units skipping the hook; `llmctl help` naming only `start/auto/switch`). These were documentation errors; the code already enforced the gate in 3.2.0.

### Security

- No security-relevant change.

### Removed

- Nothing.

### Migration notes

- None. Replacing 3.2.0 with 3.2.1 changes no unit, drop-in, state file or exit code. Read the 3.2.0 documentation's gate statements as superseded by this release.

### Known limitations

- The 3.2.0 tarball and tag keep the stale documentation text.
- The waiter gap above (port registry inactive means no validation on the systemd path) is documented, not closed.
- Everything in the 3.2.0 "Known limitations" and "Release status" still applies, including: one real-model run (profile `vision`, this host, one run) and UNKNOWN for every other profile.

## 3.2.0 (2026-10-12)

A host-safety and model-validation release. It bounds what an llmctl service may do to the machine (memory caps, no swap, bounded stop, bounded restart, a memory-pressure start gate), adds a
deterministic **model validation gate**, and adds a guarded live-test driver with a watchdog. The three work branches (`fix/bounded-restart-and-pressure-gates`, `fix/validation-gate-complete`, `feat/live-test-watchdog`) are merged into `main` (tip `42f9a76` when this text was last revised); the release candidate adds the live-test evidence, the GPU-peak fix and the documentation updates on branch `release/3.2.0-final`. The tag, once cut, is the authority for what is in the release.

**Release status (read first).**

- **One real-model run exists, for profile `vision` only.** Every other statement about `llmctl validate` and the suites is proven against a fixture server (`tests/fixtures/validation/fake_openai.py`, an answer table, not a model). Whether any other profile passes a suite is UNKNOWN.
- **Live test result: PASS (2026-10-13, profile `vision`, THIS HOST ONLY, single run).** pass=21 fail=0 undetermined=0 (16 golden probes + 2 control-self probes + 2 discrimination controls + 1 determinism repeat, identical; judge self-test 19/19 entries ok); model `gemma-3-4b-it-Q4_K_M.gguf` sha256 `882e8d2db44dc554fb0ea5077cb7e4bc49e7342a1f0da57901c0802ea21a0863`, mmproj sha256 `8c0fb064b019a6972856aaae2c7e4792858af3ca4561be2dbf649123ba6c40cb`; ready in about 11 s; the watchdog never triggered; on this host MemAvailable never fell below 19397 MiB (start 20135), memory PSI some avg10 peaked at 1.74, GPU used peaked at 4109 MiB (baseline 277); after the stop the unit was inactive and port 8082 closed. Evidence: [`docs/qa/vision-live-2026-10-13/`](docs/qa/vision-live-2026-10-13/README.md). **UNKNOWN: the unit's `MemoryPeak` and the process `VmHWM` were not captured in this run** (the driver now records `MemoryPeak/High/Max` before the stop; the first value exists after the next run). Not tested: `vision-pro` and every other profile. The captured `verdict.txt` carries a wrong 'peak 0MiB' GPU note (driver read the wrong CSV column; fixed, see Fixed below).
- **The restart, memory-cap and pressure-gate behaviour was tested hermetically** (unit text assertions, fixture PSI and meminfo files, `LLMCTL_DRY_RUN=1`). It was not exercised against a real systemd user manager under real memory pressure. UNKNOWN: whether this systemd applies `RestartPreventExitStatus` to a failing `ExecStartPre`.
- **The standing 3.1.0 caveats are unchanged:** manual QA was operator-waived for 3.1.0 and is not satisfied; macOS is verified statically only; Windows is unsupported; accuracy figures are provisional (agent-authored labels). See [`docs/limitations.md`](docs/limitations.md).

### Added

- **Model validation gate** (`lib/validate.sh`, `lib/validate_judge.py`, `validation/suites/`; reference: [`docs/validation.md`](docs/validation.md)). `llmctl validate <profile> [--host URL] [--json] [--keep]`, `llmctl vision validate [--profile vision|vision-pro]`, `llmctl validate-all`, `llmctl require-validated <profile>` and `llmctl models verify <profile> [--live]`. Deterministic known-answer suites (`chat-v1`, `coder-v1`, `vision-golden-v1`, `embedding-v1`) judged by plain code (never an LLM); the catalog names each profile's suites in `validation.suites` (a profile with none carries a `validation.reason` and is never reported validated). Exit codes: **0** every check passed, **1** any wrong result, **2** could not determine (UNDETERMINED is never PASS; 1 outranks 2). State lives in `$LLMCTL_STATE_DIR/validation/<profile>.json`; `require-validated` accepts a record only while the model hash, file size and mtime, engine tag, launch fingerprint and suite hashes still match and the record is younger than `LLMCTL_VALIDATION_MAX_AGE` (default 604800 s). `start`, `switch`, `auto`, `enable` and `restart`, and units started by systemd (boot, `Restart=`, `systemctl start`, through the registration waiter), run the suites once after the service is ready (`LLMCTL_VALIDATE_ON_START=0` disables the hook loudly). The hook is enforced: a wrong answer (`VERDICT: FAIL`) stops the profile through the normal stop path and exits non-zero; UNDETERMINED never stops it and never counts as a pass (with `LLMCTL_VALIDATE_STRICT=1` it stops and exits non-zero). See [`docs/validation.md`](docs/validation.md#enforcement-of-the-gate-wired-settled-decisions).
- **Validation environment variables:** `LLMCTL_VALIDATE_ON_START`, `LLMCTL_VALIDATION_MAX_AGE`, `LLMCTL_VALIDATE_TIMEOUT` (overall wall-clock deadline per request, default 180 s), `LLMCTL_VALIDATE_API_KEY` and `LLMCTL_VALIDATE_API_KEY_HOSTS` (see Security).
- **The `number_equals` rule** (decided 2026-10-12): the number after the last `=` when the answer restates an equation, otherwise the first number; a thousands separator or leading dot is not a number. Its documented trade-offs (it accepts `41 because 17+25=42`, rejects `42 = 17+25`) are deliberate and stated in `docs/validation.md`.
- **Memory-pressure start gate** (`hw_pressure_gate`, `lib/hardware.sh`): `llmctl start`, `restart` (as the unit's first `ExecStartPre`, `svc_hook.sh gate`), `enable`, `switch` (before anything is stopped) and the validate path are refused with **exit 75** (EX_TEMPFAIL) when memory PSI `full avg10 > 2`, `some avg10 > 10`, or `MemAvailable < footprint + 4 GiB`. Tuning: `LLMCTL_GATE_FULL_MAX`, `LLMCTL_GATE_SOME_MAX`, `LLMCTL_GATE_RESERVE_MB`. Test seams: `LLMCTL_PSI_FILE`, `LLMCTL_MEMINFO_FILE`.
- **Per-profile service limits:** a drop-in `llmctl-<engine>@<profile>.service.d/05-memory.conf` sets `MemoryHigh` = 1.25x and `MemoryMax` = 1.5x of the plan footprint (floor 1 GiB, always under 90% of RAM); the unit template adds `MemorySwapMax=0`, `Nice=10`, `IOWeight=50`, `CPUWeight=50`, `OOMScoreAdjust=500`, `TimeoutStopSec=20`, `TimeoutStartSec=300`, `KillMode=control-group`.
- **Bounded restart policy:** `Restart=on-failure`, `RestartSec=5`, `RestartSteps=4`, `RestartMaxDelaySec=120`, `StartLimitBurst=3` per `StartLimitIntervalSec=900`, and `RestartPreventExitStatus=SIGKILL SIGTERM 98`.
- **Port-in-use refusal:** the `prestart` hook refuses fast with exit **98** when the profile's port is already listening, never loads the model and never rotates the key under a live server.
- **Guarded live-test driver** (`scripts/livetest/vision_live_test.sh`, `scripts/livetest/watchdog.sh`, hermetic suite `tests/test_livetest_watchdog.sh`; protocol: [`docs/live-test-protocol.md`](docs/live-test-protocol.md)): a pre-gate that refuses on a stressed host (exit 3), a watchdog that stops the profile through `llmctl stop vision` when a limit is crossed (exit 4), evidence under `~/.cache/llmctl-livetest/`. Exit codes 0 PASS, 1 FAIL, 2 undetermined, 3 refused, 4 aborted by the watchdog. It ran live once on 2026-10-13 for profile `vision` (PASS, see Release status).
- **`llmctl doctor` checks** for the new service model: FAIL for a profile with two enabled engine units and for a live engine process of this install with no registry row; stale installed units (weaker restart bound than 3 starts / 900 s) are reported.
- **Documentation:** Mermaid diagrams of the start path (pressure gate, admission, start, readiness, validation gate) and of the restart policy in [`docs/architecture.md`](docs/architecture.md); new FAQ entries; the systemd-oomd vendor-rule section in [`docs/host-safety.md`](docs/host-safety.md).

### Changed

- **BREAKING (by design): a service killed by `SIGKILL` (including an `oom-kill` by the kernel or by `systemd-oomd`), stopped by `SIGTERM`, or refused with exit 98 is no longer restarted automatically.** The 3.1.0 template used `Restart=always` with 5 starts per 60 s, a bound that a real model load (more than 60 s) could never trip. Other failures restart with a growing delay and stop after 3 starts in 900 s. Restart it yourself (`llmctl start <profile>`) after finding out why it was killed.
- **BREAKING: `llmctl start`, `restart`, `enable` and `switch` can now exit 75** (refused: host under memory pressure or too little available memory). Scripts that treated any non-zero exit as a hard failure should retry later, not loop. `switch` is refused before anything is stopped, so the running set is untouched.
- **BREAKING: `llmctl doctor` now FAILs on a duplicate enabled engine unit for one profile** (for example `llmctl-llama@decide-nli` plus `llmctl-onnx@decide-nli`). A host in this state now fails `llmctl doctor` until the duplicate is removed (whether 3.1.0 doctor flagged it is UNKNOWN) (Migration notes). `enable` and `disable` now keep exactly one enabled engine unit per profile.
- Unit memory limits: `MemoryHigh=MemoryMax=total RAM` (which contained nothing) is replaced by per-profile caps plus a template backstop (70% / 85% of RAM; gateway 20% / 25%, capped at 3 / 4 GiB).
- `llmctl-decide registry` rows are dropped by `unregister` only when the row's pid is dead or is the stopping unit's own pid; `unregister` is bounded (3 s plus 1 s) and the registration waiter is killed on stop.
- `llmctl models verify <profile>` states plainly when a profile names no validation suite (**NOT validated**, exit 0 for the checksum verdict; with `--live` exit 2).
- Unchanged and still documented here because the release test reads them: the `llmctl-decide` gateway and its `decide scale`, `decide calibrate`, `probe-order` and `completions` commands, per-type maturity labels, `llmctl status --json`, the planner's `overhead_mb` term, the `LLMCTL_CTX_<PROFILE>` overrides and the scheduler's eviction rules behave as in 3.1.0 except that every start they perform now passes the pressure gate.
- New environment variables, all optional: `LLMCTL_GATE_FULL_MAX`, `LLMCTL_GATE_SOME_MAX`, `LLMCTL_GATE_RESERVE_MB`, `LLMCTL_PSI_FILE`, `LLMCTL_MEMINFO_FILE` (test seams), `LLMCTL_VALIDATE_ON_START`, `LLMCTL_VALIDATION_MAX_AGE`, `LLMCTL_VALIDATE_TIMEOUT`, `LLMCTL_VALIDATE_API_KEY`, `LLMCTL_VALIDATE_API_KEY_HOSTS`.

### Fixed

- **Live-test verdict reported 'no GPU use observed, peak 0MiB' although the GPU was in use (4109 MiB)**: the driver read column 6 of `samples.csv` (`io_some_avg10`) instead of `gpu_used_mb` (column 8); the peak is now looked up by header name, the unit's `MemoryPeak`/`MemoryHigh`/`MemoryMax` are recorded before the stop (`infinity`, `[not set]`, unavailable = UNKNOWN, never 0). Regression: `tests/test_livetest_watchdog.sh` section G1/G2 with the real `samples.csv` as fixture.
- **Stop path exceeded 90 s under pressure** (observed): `TimeoutStopSec=20`, `KillMode=control-group`, bounded `unregister` (`6d717fc`).
- **Restart loop that could never trip its own limit** (`16e723c`), **unbounded memory limits** (`8a28066`), **a second unit's `ExecStopPost` dropping a live service's registry row** (`2934148`), **two enabled engine units for one profile** (`0d33bf0`, `73ec5cb`), **prestart rotating the key and loading a model when the port was already served** (`b2423d1`).
- **Validation gate defects found by independent review** (`b80b77c` through `5286032`): scaled instance keys (`profile.N`) aborting `validate_after_start`; `auto` validating every running profile instead of the ones it started; budget exhaustion reported as FAIL instead of UNDETERMINED; a future or unusable record epoch accepted as fresh; an UNDETERMINED run overwriting a prior PASS; an interrupt leaking the temp key file and the judge child; a thousands separator read as a decimal; a truncated WRONG answer excused as UNDETERMINED; malformed completion shapes ending in a traceback; `require-validated` leaking a temp file; a server that trickles bytes stalling the run (overall deadline).

### Security

- **Eval-injection fix (`320ebac`):** profile names were interpolated into JSON expressions that were evaluated; they are now allow-listed with `valid_id` and passed as data (`argv[i]`) to a restricted evaluator.
- **Validation traffic never goes through a proxy** (`000b4a5`): `http_proxy`/`HTTPS_PROXY` are ignored and redirects are never followed, so prompts and the bearer token go directly to the endpoint.
- **`LLMCTL_VALIDATE_API_KEY` is sent only to loopback hosts** (`localhost`, `127.0.0.0/8`, `::1`) or to hosts listed exactly in `LLMCTL_VALIDATE_API_KEY_HOSTS`; the host is judged the way the HTTP client connects, and a URL with a backslash or control characters is refused (`0e353b7`, `55481eb`). Any other `--host` gets no token and a printed note.
- Hardening, not a new guarantee: services now run with `MemorySwapMax=0`, lower CPU and IO weight and a higher OOM score, so a runaway model dies alone and early. `systemd-oomd` on this class of host still acts on whole cgroups (see `docs/host-safety.md`).

### Removed

- The 3.1.0 unit template's `Restart=always` with its 5-starts-per-60-s limit, and the `MemoryHigh=MemoryMax=total RAM` unit limits. No command, flag or environment variable of 3.1.0 is removed.

### Migration notes

- **`llmctl install` regenerates the unit templates but not the drop-ins that you or hostsafety wrote.** After upgrading run `llmctl install`; installed units with the old restart bound are reported stale by `llmctl doctor` and `start`/`enable` refuse them until regenerated.
- **Restarts are needed for the caps to apply to running units.** Regenerated limits take effect on the next start: `llmctl restart <profile>` (it passes the pressure gate) or stop and start.
- **Per-profile caps come from `05-memory.conf`; your own `10-hostsafety.conf` (for example the gateway unit's `llmctl-decide-gateway.service.d/10-hostsafety.conf`) is read later and wins.** Drop-ins apply in file-name order, the last assignment wins. Remove or raise a cap by writing your own later drop-in, never by editing the generated file.
- **Duplicate enabled engine units are an operator action.** The known case is `decide-nli` enabled under both the `llama` and `onnx` engine templates. 3.2.0 `doctor` FAILs on it and prevents new ones, but does not remove an existing one. Inspect with `systemctl --user list-unit-files 'llmctl-*@decide-nli*'`, then `llmctl disable decide-nli` and `llmctl enable decide-nli` so only the right engine unit remains.
- **Expect exit 75 under memory pressure** from `start`, `restart`, `enable` and `switch`; retry once `/proc/pressure/memory` is quiet. Do not lower `LLMCTL_GATE_*` to get past it on a host that is actually stressed.
- **Do not rely on automatic recovery after an OOM kill.** Monitor for a unit in the `failed` state (`llmctl status`, `llmctl doctor`) and restart deliberately.
- **Run the validation suites yourself** (`llmctl validate <profile>`) before trusting a profile; no model has been validated on your behalf.
- `systemd-oomd` is not changed by llmctl. Its vendor rule on `user@.service` (kill at 50% pressure for 20 s) can still kill a whole cgroup; see `docs/host-safety.md`.

### Known limitations

Reconciled with [`docs/limitations.md`](docs/limitations.md), which is the full list and the authority.

- **One real-model run exists** (profile `vision`, this host only, 2026-10-13: PASS, 21/0/0). Every other profile is not validated; the gate is otherwise proven against a fixture server only. `MemoryPeak`/`VmHWM` of that run: UNKNOWN (not captured).
- **The validation gate is enforced, with gaps.** A wrong answer stops the profile on every start path; UNDETERMINED does not stop it (unless `LLMCTL_VALIDATE_STRICT=1`). The systemd waiter reads the unit's environment, not the operator's shell, so `LLMCTL_VALIDATE_STRICT`/`LLMCTL_VALIDATE_ON_START` must be set in a unit drop-in; it validates only catalog LLM profiles, and it does nothing (the unit is NOT validated) when there is no `MAINPID` or the port registry is inactive (`LLMCTL_PORTREG=0|off|no`, no portreg binary, `LLMCTL_DRY_RUN=1`). The pressure gate checks memory PSI and `MemAvailable`, not IO pressure. The vision suite has 13 probes without a canned PASS and/or FAIL control (each is still shown to discriminate by `tests/test_validation_suites.sh`).
- **The pressure gate reads host-wide memory PSI and `MemAvailable`** at one instant; it cannot know what another process will allocate a second later, and it does not look at IO pressure.
- **Restart policy: UNKNOWN** whether this systemd applies `RestartPreventExitStatus` to a failing `ExecStartPre`; the `StartLimit` bound applies either way. `ManagedOOMPreference=avoid` is asked for, and UNKNOWN whether the user manager honours it for an unprivileged unit.
- **`systemd-oomd` can still kill llmctl services** (259 units in one measured event on 2026-10-12, including `llmctl-llama@vision.service`); the operator owns that configuration.
- **The live-test driver has run live once** (2026-10-13, `vision`). It checks the `llmctl vision validate --json` capture against the golden suite (counts and verdicts), not the answers beyond what the judge decided.
- Everything in the 3.1.0 limitations list still applies (decision answers are not a safety guardrail, confidence is not calibrated, macOS statically verified only, Windows unsupported, manual QA operator-waived for 3.1.0).

## 3.1.0 (2026-10-10)

The local **typed-decision** feature (Jev-class `noul` / `choice` / `score` answers from small
decision models) as a secured, discoverable service. The wording is final only when the tag is cut;
every statement below is backed by a test or a document named next to it. What was and was not verified live, and every
known limit: [`docs/limitations.md`](docs/limitations.md); every known gap: `specs/009-jev-decision-models/evidence/gaps-register.md`.

**Release status.**

- **Manual QA waived by the operator, 2026-10-08; the constitution gate is operator-waived, not satisfied.** No person ran the live manual-QA pass the project's constitution (section 11.4.185) requires before a tag; this release rests on the automated gates, the independent reviews and the full test suite.
- **macOS: verified statically only.** Linux is the live-verified platform; Windows is unsupported.
- **Version.** The `VERSION` file and `llmctl version` now both read `3.1.0` (`llmctl version` printed a stale `0.1.0` before; `tests/test_cli.sh` now also asserts it equals `VERSION`). The catalog's own `version` field is the schema version (still `1`) and is unchanged. The separate `llmctld` cluster daemon module keeps its own build version (`0.1.0`, `llmctld/cmd/llmctld/main.go`; its comment says it is tracked independently), so `llmctld --version` does not read `3.1.0`.
- **Accuracy figures are provisional** (agent-authored labels, human review pending). Every decision profile carries a per-question-type **maturity** (`measured` / `experimental` / `unmeasured`, derived from its golden run by `scripts/maturity_from_golden.py`): a type whose measured Wilson lower bound does not clear the majority/chance baseline, or that has no live golden run yet, is labelled experimental in `GET /v1/models` (`experimental_types`), in `llmctl plan` and on the answer itself (`maturity: "experimental"`). Every admitted profile still ships and nothing is hidden. Per-profile table: `docs/hardware-tiers.md`.
- **Release mechanics** (tag, ff-only pushes, forge releases, re-download verification, rollback): [`docs/release-3.1.0-checklist.md`](docs/release-3.1.0-checklist.md).
- **Second host.** Portability runs used `nezha.local` (ALT Linux, CPU only). **The llmctl tree on nezha was an uncommitted snapshot with no `.git`; its exact source commit is UNCONFIRMED** (an informal diff put it between `339cb6c` and `f1a22ea`), so every nezha number below is *not pinned to a repository commit* and predates later fixes. Re-run on the tagged tree before treating them as release figures.
- **What is live-verified, and on which host** (golden set: 132 originals + 41 option-order permutations, 23 probes; agent-authored labels; single runs; n below the 200 needed for calibration; Wilson 95% intervals; `lower>baseline` is each profile's own stats line). Evidence: `specs/009-jev-decision-models/evidence/live-models/`.

  | Profile (protocol) | Host / engine / tree | Golden well-formed | Result (accuracy [95% CI] vs baseline) | Status in 3.1.0 |
  |---|---|---|---|---|
  | `decide-kev-9b` (native) | nezha, CPU, unpinned snapshot (`nezha-decide-kev-9b-2026-10-08`) | 132/132 | noul 0.967 [0.886,0.991] (0.667); choice 1.000 [0.914,1.000] (0.235); score 0.710 [0.534,0.839] (0.290); all three beat their baseline | verified on nezha only; **not** run to completion on a commit-pinned tree (on the dev host the scheduler admitted it and the engine then hit a real CUDA OOM at start: `evidence/live-models.jsonl` line 6 (`result: FAIL-START`), commit `0197297`) |
  | `decide-kev-4b`, `decide-lev` (native) | anton (dev host, RTX 3060 12 GB), real scheduler start -> HTTPS gateway :8095, engine build 11379 (`1537a0a8b`); evidence committed in `0197297` (`evidence/live-models.jsonl` lines 4-5: `result: RAN`; `evidence/live-models/decide-lev/`, `decide-kev-4b/`, each `RESULT.txt` = COMPLETED). Earlier on the same host the scheduler had refused both for RAM (`evidence/live/NATIVE-REPORT.md`); the later run succeeded after the host's memory state changed. Also run on nezha (CPU, unpinned snapshot), `docs/decision-models.md` "Live results (nezha, CPU)" | 132/132 each | `decide-lev` (gpu mode): noul 0.967 [0.886,0.991] (0.667), choice 0.976 [0.874,0.996] (0.235), score 0.516 [0.348,0.680] (0.290); `decide-kev-4b`: noul 0.950 [0.863,0.983], choice 1.000 [0.914,1.000], score 0.613 [0.438,0.763]; all six beat their baselines. Measured VRAM: `decide-lev` 6994 MiB reserved / 3926 MiB engine peak, `decide-kev-4b` 7328 MiB engine peak | verified on the dev host (single runs, agent-authored labels, provisional); the `anton` figure and the nezha figure agree on the weak group (score 0.52 to 0.61) |
  | `decide-julia`, `decide-laya`, `decide-kev-08b` (native) | dev host, real scheduler + HTTPS gateway, commit-pinned tree | see `evidence/live/NATIVE-REPORT.md` | per-type maturity: `decide-julia` is experimental on all three types; `score` is experimental on `decide-kev-08b` and `decide-laya` (`docs/hardware-tiers.md`) | run through the real scheduler and HTTPS gateway on the dev host |
  | `decide-nli` (encoder, `onnx`) | anton, CPU, HEAD `c5301de` + the live-run harness fix, since committed as `c00da7b` (`decide-nli-main-wiredfix`) | 132/132 (probes 23/23) | **choice only**: 0.829 [0.687,0.915] (0.235). noul 0.533 (0.667) and score 0.226 (0.290) do **not** beat the majority baseline | usable for `choice`; do not rely on its `noul` / `score` |
  | `decide-2b` (letter-logit) | anton, CPU, HEAD `c5301de` + the thinking fix, since committed as `5184565` (`anton-decide-2b-thinkingfix-run2-2026-10-09`) | 128/132 (probes 23/23); before the fix 0/132 | noul 0.883 [0.778,0.942] (0.667) and choice 0.732 [0.581,0.843] (0.235) beat; score 0.290 [0.161,0.466] (0.290) does **not** | works for `noul` / `choice` only. The 4 malformed originals account for 8 x HTTP 422 on 20-option items against `max_options` 16 (the 4 originals plus their 4 option-order permutations, 4 + 4 = 8 refused requests) (reason code UNCONFIRMED: body not captured, G-160) |
  | `decide-pro` (letter-logit) | anton, CPU, same tree (`anton-decide-pro-thinkingfix-2026-10-09`) | 112/132 (probes 22/23); before the fix 68/132 on nezha | noul 0.867 [0.758,0.931], choice 0.659 [0.505,0.784], score 0.645 [0.469,0.789]: all three beat | works, but 29 x HTTP 502 `backend_failed` (about 27 s each) on a CPU engine, G-156 (below) |
  | `decide` (letter-logit, decider-4b) | anton, CPU (`anton-decide-thinkingfix-2026-10-09`) | smoke 1/3; golden and probes **not run** | none | **not usable at the current `mass_threshold` (0.5)**: the option-letter mass after the fix is 0.44 to 0.47, so a 2-option question is refused with 422 `readout_failed` (G-157). No accuracy figure exists |
  | `decide-max` (letter-logit, 9B Q8_0) | none | not exercised | none | **no live result**: expected peak 12 to 13 GB exceeds the 10 G bounded-run cap used for the run (G-158, `anton-decide-max-not-exercised-2026-10-09.md`); it ships catalogued and hash-pinned, unverified |
  | `decide-tiny` | none | not servable | none | catalogued only: a verdict-readout model the gateway refuses clearly (`d856e69`); not recommended anywhere |

  Every figure above is single-run, CPU-only (no GPU), uncalibrated and from agent-authored labels (human review pending). They are not accuracy guarantees.

### Added

- **`llmctl decide serve --enable [--now]` / `--disable`**: install, enable and start (or stop, disable and remove) the decision gateway as a boot-time user service (systemd user unit on Linux, launchd agent on macOS); idempotent, refuses while an installed engine unit is stale (`llmctl install`). Verified with a stubbed `systemctl` (`tests/test_decide_serve_enable.sh`); macOS dry-run only (no Mac: its idempotence, boot-out before bootstrap, is UNCONFIRMED on real launchd). A re-enable over a changed unit file does `systemctl --user try-restart`; `--enable` under a dry run writes no unit. Fix: the onnx encoder runtime is now registered and awaited at its truthful `/readyz` (it was `/health`, so `decide-nli` was never registered by the unit's waiter, or was removed after the reconciler grace; now `/readyz`, the truthful readiness probe, because `/healthz` is liveness only and stays 200 when the load-time smoke failed), single source `portreg_health_path` (`tests/test_health_path_engines.sh`).
- **Release archive post-scan (`scripts/release.sh`, `scan_archive_or_refuse`)**: the archive is independently scanned with `scripts/release/scan_archive.py` after it is built; a scanner finding, a nonzero scanner exit or a missing scanner REFUSES the archive and deletes it so no later step (checksums, publish) can ship it. Nested archives (for example `archive/llmctl.zip`) are scanned too, and a nested allowlist entry is written `outer!inner` (chain `a!b!c` for deeper nesting); an entry applies to a nested path only in that exact form. Page: `docs/scripts/scan_archive.md`.
- **`scripts/bench/jevbench_adapter.py`**: JevBench public-tier adapter (spec 009 T065). Fail-closed provenance (harness commit and dataset sha256), refusals tallied apart from wrong answers, Wilson interval, calibration only at 200+ licence-clean answered items; every run is labelled public-tier, contamination possible, not an official score. Page: `docs/scripts/jevbench_adapter.md`.
- **New pages**: `docs/persistent-services.md` (persistent engines and gateway, linger, `gateway.conf`, the CPU-adaptive timeout, drain grace) and `docs/lan-exposure.md` (serving the gateway on a LAN: bind address, certificate SANs, firewall); per-script pages `docs/scripts/decide_timeout.md` and `docs/scripts/jevbench_adapter.md`.
- **Governance mirrors**: `QWEN.md` and `GEMINI.md` added next to `CLAUDE.md`/`AGENTS.md` (project instructions kept in lockstep for the other agent platforms).

- **Go decision binary `llmctl-decide`** (`cmd/llmctl-decide`, `internal/{gateway,server,contract,readout,client,keyring,certs,registry,schema,mcpserver,vantage}`;
  built by `llmctl build decide`, path overridable with `LLMCTL_DECIDE_BIN`): the HTTPS decision gateway
  (`serve`), the client (`ask`, `batch`, `models`), access-key (`key`) and certificate (`cert`) management,
  the service `registry` / `port` / `discover` commands, `schema`, `mcp`, `vantage` and the one-question
  engine `smoke`. Reference: `docs/decide-gateway.md`, `docs/decision-models.md`, `docs/registry-discovery.md`.
- **Decision gateway over HTTPS** (default port 8095): `POST /v1/systemone` in the Jev / TypeSafe-SDK wire shape,
  `GET /v1/models` (with the SDKs' `models` listing), `/healthz`, `/readyz`, `/metrics`; a mandatory access key
  (`LLMCTL_API_KEY`, generated on first start, mode 0600, never on a command line), a local CA + leaf certificate under
  `$LLMCTL_HOME/cert`, bounded concurrency/queue/connection caps, failed-auth throttling, deterministic mode
  (fixed seed, one slot per instance), structured request log with a keyed state hash. Endpoint contract:
  `specs/009-jev-decision-models/contracts/`; evidence: `tests/test_gateway_endpoints.sh`.
- **`llmctl decide smoke`** (`--url URL --protocol letter-logit|nli-onnx|systemone-native [--key-file F] [--options N]
  [--expect-choice KEY] [--json]`): one deterministic question through the production driver; exit 0 only for a valid
  typed answer, 1 backend failure, 2 usage, 6 unreachable. The post-download smoke of decision GGUF profiles runs on it.
- **New decision profiles** (all hash-pinned): `decide-tiny` 8092, `decide` 8093, `decide-pro` 8094, `decide-nli` 8096
  (`onnx` engine, CPU), `decide-2b` 8098, `decide-max` **8097** (see "Changed": it was 8099 in the first candidate). Catalog
  `decision` blocks carry the protocol, option/level caps and the letter-logit readout parameters.
- **Six native-protocol decision profiles** (llama.cpp >= b11379, `POST /v1/systemone`; hash-pinned from the admission
  records): `decide-julia` 8103, `decide-kev-08b` 8104, `decide-kev-4b` 8105, `decide-kev-9b` 8106, `decide-laya` 8107,
  `decide-lev` 8108. Launched with `--batch-size 4096 --ubatch-size 4096 --no-cache-prompt` (upstream #30073); the gateway
  serves them only with `LLMCTL_DECIDE_NATIVE=1`, answers the profile name (never the engine's file path in `model`), maps
  the engine's "input is too large" 500 to `422` and its 501 "not a decision model" to the non-retryable 500. A profile may
  declare a measured `defaults.overhead_mb` (planner term for activation buffers). Live on the dev host: `decide-julia`,
  `decide-laya` and `decide-kev-08b` were run through the real scheduler + HTTPS gateway with the golden set (agent-authored,
  human review pending; Wilson intervals in `docs/decision-models.md`); `decide-kev-4b` and `decide-lev` were first refused by the scheduler for RAM on that host (`evidence/live/NATIVE-REPORT.md`, an earlier
  record) and **later ran to completion** through the scheduler and the HTTPS gateway (`evidence/live-models.jsonl` lines 4-5, commit `0197297`,
  status table above); `decide-kev-9b` was admitted by the scheduler and then hit a real CUDA OOM at start (`live-models.jsonl` line 6, commit `0197297`)
  and was run only on `nezha` (CPU, unpinned snapshot). Evidence: `specs/009-jev-decision-models/evidence/live/NATIVE-REPORT.md`, `evidence/live-models/nezha-decide-*-2026-10-08/`.
- **`llmctl decide scale <profile> <N>`**: starts or stops instances of one decision profile until N run, bounded by the same admission control as `start`
  (instance keys `<profile>`, `<profile>.2`, ...; registry-allocated ports; refusal exit 3 with the exact numbers; `LLMCTL_DECIDE_MODE=throughput` marks multi-instance use).
  Scale-down stops the highest-numbered instance first; a failed `llmctl switch` restores the same instance **count** of a scaled profile, not necessarily the same keys.
  If an instance fails to start, every instance that this call started is rolled back (stopped, registry row withdrawn, reservation, port hold and service env removed);
  with `SCHED_SCALE_BESTEFFORT=1` the instances that did start are kept instead and the failures are reported. Logic: `lib/scheduler.sh` `sched_decision_scale`; suite: `tests/test_decide_scale.sh`.
- **`llmctl decide calibrate | probe-order | completions`**: `calibrate` fits a confidence calibration (temperature, Platt or isotonic; accuracy with an interval, baseline,
  ECE / MCE / Brier) from a label file and writes a profile bound to the model hash and the prompt-template hash (refuses a claim below 200 labels; the gateway applies a
  matching profile to `confidence` only, never to `probabilities`); `probe-order` measures how often the answer changes when the options are re-ordered; `completions bash|zsh`
  prints shell completion. `docs/calibration-tool-fields.md` lists which response fields an external calibration tool may rely on.
- **Per-profile x question-type maturity labels** end to end: catalog `maturity` object per profile (evidence-referenced), `experimental_types` on `GET /v1/models`, a "Maturity" block in `llmctl plan`,
  and `maturity: "experimental"` on answers of an unmeasured type (see the status note above). Tests: `internal/gateway/maturity_test.go`, `internal/server/maturity_test.go`, `tests/test_planner.sh`.
- **`llmctl doctor` decision checks** (every line prefixed `decide:`; skipped silently when `llmctl-decide` is not built): access key present and mode 0600, the gateway certificate (checked by `llmctl-decide cert doctor`),
  the private `onnx` venv, engine HTTPS support (`--ssl-key-file`), gateway port free or served by this gateway, and a loopback-only versus network-reachable bind note (`docs/cloud-exposure.md`). Suite: `tests/test_doctor_decide.sh`.
- **Gateway stress scenario** `tests/test_gateway_stress.sh` (real `llmctl-decide serve` in front of an in-repo fake engine, loopback only): a fixed burst against concurrency 1 / queue 1 is answered `200` or
  `529` + `Retry-After` (never a hang, `/healthz` stays answerable); `serve --stop` during an in-flight request flips `/readyz` first, lets the request finish with `200`, then exits; resident memory stays small.
- **`llmctl status --json`**: machine-readable running state (LLMCTL-F1); a `switch` whose rollback also failed exits 75 (LLMCTL-F2).
- **Per-profile context-size and KV-cache-type overrides**: `LLMCTL_CTX_<PROFILE>` and `LLMCTL_KVTYPE_<PROFILE>` (validated; a context below 512 is refused because `--ctx-size 0` means the model's native window and would be
  estimated at about 0 MiB); the planner's KV estimate is now KV-type-aware (`KV_TYPE_RATIO`, block-size ratios derived from llama.cpp's `ggml-common.h`; only `q4_0` has a live measurement, the other ratios are derived,
  not measured) and a non-f16 type reaches the real `llama-server` command line (`--cache-type-k/-v`). Documented in `docs/scripts/catalog.md` and `docs/architecture.md`.
- **`run-engine` library path (G-129)**: `lib/svc_hook.sh run-engine` prepends the engine's own directory to
  `LD_LIBRARY_PATH` (`DYLD_LIBRARY_PATH` on macOS) when it ships `libggml*`, so a caller's system `libggml` cannot shadow it.
- **`onnx` engine**: the internal encoder scoring runtime `lib/onnx_server.py` (loopback only, key from a 0600 file,
  `POST /v1/score`), installed through a hash-locked private venv (`llmctl build onnx`, `lib/lock/requirements-onnx.lock`).
- **Dynamic ports and a service registry** (`LLMCTL_PORT_STRATEGY=dynamic`, `LLMCTL_PORT_<PROFILE>`, `LLMCTL_PORT_GATEWAY`,
  bind-tested per-user ranges) with the gateway discovering engines through it (`docs/registry-discovery.md`); the gateway
  runs as a boot-time user service (`llmctl-decide-gateway.service` / launchd agent).
- **`llmctl admit`** (candidate-model admission gates G1-G10), **`llmctl decide vantage`** (second-network-location
  probes through the Containers submodule), a typed-question **schema / MCP** surface for coding agents, and the
  **agent installer** (`scripts/install_agents.sh`, `docs/agents/`).
- **Host-safety tooling** (`scripts/hostsafety/`, `docs/host-safety.md`, `tests/test_hostsafety.sh`; added after the 2026-10-08 runaway-hook incident that exhausted memory and swap on the development host and forced a power-cycle). User-level only: systemd slice drop-ins for `app` / `background` / `user` with memory, swap and task limits sized from the host; `bounded-run` (run a command in a transient cgroup scope with memory / task / CPU / time limits; containment by cgroup, never by signalling a pid or process group); a memory-pressure guard timer that ranks and stops the costliest eligible user process groups under `app.slice` / `background.slice`; a podman memory-limit audit (report-only); and a tracker-exclude helper. **The guard ships in DRY-RUN.** The root-level steps (`root-steps.sh`: `earlyoom` protection list, journald rate limit, `vm.swappiness`, `user-1000.slice`) are written but **not applied**; `sudo bash scripts/hostsafety/root-steps.sh --apply` is the operator's decision. This is operator tooling for the development host; it is not part of the `llmctl` runtime path.
- **`tests/test_regression_defects.sh`**: permanent regression guards for the 66 defects of the P1 reproduction register
  (id -> guard map: `specs/009-jev-decision-models/evidence/red-to-green-map.json`; original RED results archived in
  `specs/009-jev-decision-models/evidence/p1-red-original/`). `scripts/doc_counts.sh` generates documented assertion counts
  from a real run instead of hand-typing them.

### Changed

- **BREAKING: a bare `llmctl build` no longer builds anything** - it prints `usage: llmctl build <llama|colibri|onnx|decide|all>`
  and exits 2 (it used to start compiling everything). Use `llmctl build all`, which now also builds `decide`
  (llama + colibri + onnx + decide). (G-078, C-25)
- Release archives (`make archive`) ship a **sanitised `.git`** (only the release commit's history; no stash,
  local-only branches, reflogs, hooks or remote URLs), judge secrets with an exact-path deny-list extended to
  `id_rsa*`, `.netrc`, `*.p12`, `*.pfx`, `*.jks`, `.pgpass`, ... and an independent Python post-scan
  (`scripts/release/scan_archive.py`); exemptions are exact paths in `scripts/release/public_allowlist.txt`. (C-02, C-03)
- `llmctl-decide registry`: liveness binds to the specific process (start time + argv hash recorded at registration, a path
  argument no longer counts as the service), `reconcile --prune-unknown-after D` (default off), `--port-grace` defaults to
  600 s (at least `LLMCTL_REGISTER_WAIT`), `registry ack-corrupt`. (C-01, C-11, C-24, G-074)
- Post-download smoke tests use a free ephemeral port by default (`LLMCTL_SMOKE_PORT=auto`) and require the launched process
  to hold the listening socket. (C-06)
- `scripts/install_agents.sh`: the verified artifact is the installed artifact (`npm pack` + `--ignore-scripts`, the verified
  wheel), `scripts/agents.lock` pins, default `--log` moved to `~/.local/state/llmctl/agents-install.jsonl`. (C-08)
- `tests/run_tests.sh` reports a skipped suite as `SKIP` (`SKIP-SUITE: <reason>`), never `PASS`. (C-20)
- Systemd units quote paths with spaces / `%` / quotes; `llmctl install` regenerates stale units and `llmctl doctor` WARNs
  about them. (C-18, G-067)
- **`llmctl decide status --json` has a new shape**: `{"profiles":[...], "gateway":{"available","running","detail"}, "registry":...}`
  (it was a bare list of profile rows). The human table is unchanged and now followed by the gateway and registry state.
- **`decide-max` moved from port 8099 to 8097** (8099 is commonly taken by another service); `LLMCTL_PORT_DECIDE_MAX` still overrides.
- `llmctl decide ask` is an HTTPS client of the gateway (CA-verified, key resolved by the client); the state travels via
  `--state-file` / `--stdin`, never as an argument. Exit codes: 0 ok, 1 backend/readout failure, 2 usage, 3 admission refusal,
  4 access-key problem, 5 certificate/TLS problem, 6 gateway not ready or unreachable, 10 abstained.
- **Behaviour versus the first candidate**: the response `model` is the served profile id; an over-budget state is rejected
  (`422`) unless `LLMCTL_DECIDE_TRUNCATE=1` (then shortened with `x-llmctl-decide-truncated: true`); `decide serve --stop` with no
  pidfile is a clean no-op; the gateway never starts an engine on demand (`503 not_ready` instead).
- **Go toolchain requirement**: building the decision binary needs Go >= 1.25 (`go.mod`); without Go the shell front end says
  exactly what to run. The rest of llmctl still needs only bash/python3/curl; `make test` suites that exercise the Go binary
  SKIP with a reason when `go` is absent.
- **Catalog defaults of `small` and `vision` raised** to `ctx` 55000 and 24000 with `q4_0` KV quantization (they were 8192 / f16). Re-checked live on real hardware with a 50045-token and an 18022-token prompt
  (both far past the old ceiling), the server still rejecting an over-long prompt with its own error; VRAM growth +4040 MiB (`small`) and +3760 MiB (`vision`) over idle (`docs/qa/`). Override with `LLMCTL_CTX_<PROFILE>` / `LLMCTL_KVTYPE_<PROFILE>`.
- **Planner books VRAM for CPU-mode placements on a CUDA host (G-138).** A CUDA build offloads large-batch operations even at `-ngl 0` (`--op-offload`); the planner used to book 0 VRAM for such a placement. It now books, in order of authority: a **measured** cpu-mode VRAM (`memory.vram`), a recorded compute-buffer **floor**, the profile's measured gpu-mode peak as a **ceiling** (cpu-mode offload was below the gpu-mode peak in all four profiles measured in both modes; not a measurement), else 0 with the profile still reported UNKNOWN. `llmctl plan` marks the row `(cpu-mode VRAM <provenance>)` and `plan --json` carries `cpu_vram_provenance`. Measured so far: `decide-kev-4b` 4460 MiB (`nvidia-smi` sample taken 20 s after start with no request sent, so not a peak under load; `evidence/live/decide-kev-4b/cpu-mode-vram-live-2026-10-08.txt`), `decide-kev-08b` 2382 MiB, `decide-julia` 176 MiB, `decide-laya` 232 MiB. Tests: `tests/test_planner.sh`.
- **`LLMCTL_PORT_<PROFILE>` is honoured by the gateway** when it discovers an engine without a registry row or explicit endpoint: a valid override (1 to 65535) beats the catalog port, an invalid one (`auto`, `0`, non-numeric, out of range) is ignored, and a profile with no catalog port and no valid override resolves to no endpoint (never `http://127.0.0.1:0`). Same rule as the shell side. Tests: `internal/gateway/resolver_test.go`.
- **New submodule** `submodules/containers` (vasic-digital/Containers, rootless container runtime), declared in `helix-deps.yaml`.

- **Engine pin advance: llama.cpp `b10969` -> `b11379`** (commit `1537a0a8b`, first tag with the native `/v1/systemone` and the abort fix needed for newer decision models). Evidence: `specs/009-jev-decision-models/evidence/engine-advance*`
  (second Linux host, CPU: old pin answers 404 on `/v1/systemone` and cannot load the newest models; new pin 8/8 byte-identical). **Not covered:** CUDA, MoE, vision, colibri and performance after a 392-commit jump (G-118).
  The build is now shared-library with an RPATH into `build/bin`; a copied `llama-server` does not run without its libraries (G-117).
  `llmctl build llama` passes `-DLLAMA_OPENSSL=ON` when OpenSSL headers exist and reports whether the finished build really has HTTPS (CMake cache and linked `libssl`; `--help` listing `--ssl-*` flags proves nothing).
- Tenant ids may not contain `--` or end in `-` (the registry names a tenant's rows `<tenant>--<profile>`); `lib/service_linux.sh` and `llmctld` apply the same rule.
- `scripts/install_agents.sh`: an **unpinned** `aider` install while PyPI metadata is unreachable (offline) is now refused unless `LLMCTL_AGENTS_ALLOW_UNVERIFIED=1` (the install is then recorded as UNVERIFIED).
- `llmctl disable <profile>` also withdraws the profile from the service registry.
- Documentation: new `docs/ports.md` (every port, generated from the catalog; the `LLMCTL_PORT_<PROFILE>` override), `docs/cloud-exposure.md`, `docs/runbooks.md`, `docs/limitations.md`, `docs/glossary.md`, `docs/related-tools.md`, per-script pages for the new scripts and suites, an index of every doc reachable from the README
  (`scripts/check_doc_reachability.sh`, enforced by `tests/test_doc_reachability.sh`), and Mermaid diagrams of the decision subsystem in `docs/architecture.md`. Corrected: engine pin and bind-address statements in `docs/architecture.md`.

### Fixed

- **Client name-resolution failures reported accurately; static decide builds warned (da76694).** A `.local` (mDNS) or otherwise unresolvable host name used to surface as a misleading "unreachable"; the client now says the host name did not resolve. `engine_build_decide` (`llmctl build decide`) warns when the binary is built static (`CGO_ENABLED=0`), because a static Go binary cannot use nss-mdns and so cannot resolve `.local` names (root cause confirmed on anton). Test: `internal/client/dnsfail_test.go`.
- **Matrix harness fixes (5f303b0).** `tests/matrix`: Node client stdout truncation, model injection into the SDK client cases, additive response keys no longer treated as a contract break, and failed-auth limiter ordering. Regression tests: `tests/py/test_matrix_harness_fixes.py`, `tests/test_matrix_harness.sh`.
- **Letter-logit decision profiles returned no answer on thinking-mode models (G-155).** `decide`, `decide-2b` and `decide-pro` use the first-token option-letter readout. Their engines' chat templates open with a reasoning token delivered in `reasoning_content`, so the first-token alternatives never contained an option letter and every request was refused with 422 `readout_failed` / `option_missing`: on nezha `decide` 0/132, `decide-2b` 0/132 and `decide-pro` 68/132 requests were well-formed (root cause shown live: `evidence/live-models/nezha-decide-2026-10-08/root-cause-first-tok.txt`). The gateway now sends `chat_template_kwargs: {"enable_thinking": false}` with the readout request (`internal/gateway/letter.go`; ignored by templates that do not use it). After the change, on anton (CPU): `decide-2b` 128/132 and `decide-pro` 112/132 well-formed (table above). **It does not fix `decide`** (diffuse first token, G-157). A mutation test pins it (`tests/test_gateway_mutation.sh`: dropping the key must fail). *Status: the change and its tests are committed as `5184565`. The failing-first run of `TestLetterRequestDisablesThinking` is **CONFIRMED** (`specs/009-jev-decision-models/evidence/g155/failing-first-2026-10-09.txt`): RED against the pre-fix `letter.go` (`5184565~1`: `request must carry chat_template_kwargs.enable_thinking=false, got <nil>`), GREEN against `5184565`. Live proof covers `decide-2b` and `decide-pro` only; `decide` and `decide-max` are not fixed or not exercised, so G-155 itself stays OPEN until G-156..G-158 close.*
- **Cluster CLI over HTTP/3 (G-106).** The opt-in `llmctld` cluster CLI now has a complete trust path for HTTP/3 with mutual TLS. Daemon certificates carry SANs (127.0.0.1, ::1, localhost, the hostname, the `-api-bind` host and the new `-advertise`);
  `llmctld cluster bootstrap|join` write `ca.crt`, `client.crt`, `client.key` into a 0700 directory (files 0600; default `cli/` next to the CA, `-cli-cert-dir` overrides) and print `CLI_CERT_DIR=`; new `llmctld cluster issue-cli-cert`;
  `lib/cluster.sh` passes `--cacert/--cert/--key` (config: `LLMCTL_CLUSTER_CERT_DIR`, per item `LLMCTL_CLUSTER_CACERT/CERT/KEY`, or `CURL_CA_BUNDLE`) and never `-k`; the bearer token is no longer on the curl command line (needs curl >= 7.55).
  The host `curl` must list the `HTTP3` feature, otherwise `llmctl cluster|tenant|apikey` report "llmctld unreachable" and the suites SKIP. CLI client certificates are valid 365 days and stop being trusted after a finalised CA rotation (re-run `issue-cli-cert`).
  Verified (2026-10-08) with a real curl 8.22.0 built with ngtcp2 1.25.0 / nghttp3 1.18.0 against the system OpenSSL 3.5.5 in a private test prefix: a direct `--http3-only` request returned `HTTP/3 200`, and the cluster-args, join/leave, apikey (15 checks) and tenant (18 checks) suites passed on their success path;
  the same suite with the system curl skipped it. The build is a private test prefix, not packaged by llmctl; loopback and one node only. How to get such a curl and the reproduce commands: [`docs/llmctld-cluster-tls.md`](docs/llmctld-cluster-tls.md#getting-a-curl-that-lists-http3).
- Candidate defects reproduced and closed by the P1 pass (ids from `specs/009-jev-decision-models/source-findings.md`): secrets on
  command lines (D-03), `decide serve --stop` killing unrelated processes (D-05), the encoder runtime dropping connections on bad
  input / label-count mismatch / NaN (D-07, D-08, N-24), mis-parsed keep-alive after errors (N-12), upstream 401 collapsed into 502
  (N-13), trust-on-first-use catalog files (D-13), orphaned smoke runtimes (D-14), "downloaded and verified" printed after a skipped
  smoke (D-12), option-forging text in the state (D-28), lower-case article read as option A (N-03), silent zero / NaN readouts (N-04),
  and the documentation/test-hygiene items D-24, D-25, D-26, N-08, N-25, N-26, N-27, N-28.
- **Planner and scheduler (admission control)**: admission no longer double-counts already-running profiles against a live budget; the auto-eviction loop now converges against the live budget, credits freed memory only
  when `svc_stop` really succeeded, and reports non-convergence instead of falling through unverified or retrying the same failed stop up to 16 times; the VRAM budget uses real free VRAM, not the card's static total.
- **`llmctl start` / `switch`**: success is reported only after the model answers its readiness probe; a `wait_ready` timeout caused by an external port conflict says so; `switch` can no longer strand the host with
  zero running services (restores the previous set, exit 75 when the restore also fails); the readiness wait no longer blocks 60 s on a dry-run start; a colibri profile that would crash-loop on the LAN-bind guard is warned about first.
- **Cluster**: `ForwardModelStart`'s retry loop could never retry and its per-attempt timeout was too tight (both fixed, with a test that waits for real per-node FSM catch-up).
- **Release scripts**: the release-notes file must live under `$HOME` (snap-confined `glab` cannot read `/tmp`); `release_publish_forge` no longer passes `gh`'s `--title` to `glab`.
- Release archives can no longer contain untracked secrets (`.env`, `cert/**`, `*.key`; D-30, `tests/test_release_no_secrets.sh`).

### Security

- One access key for the decision layer, compared in constant time, never printed except by `decide key show --yes-print`, never on a
  command line; the key llmctl presents to engines travels in a 0600 file, never the environment; engines bind loopback only and are reached with a separate per-profile key file.
- Trust is the local CA only: no option or variable disables certificate verification; TLS >= 1.2.
- A pidfile is never trusted blindly: `--stop`/`--status` act only on a process verified to be this gateway (Helix 11.4.263).
- The first-candidate Python gateway served plain HTTP with an optional key; that path no longer exists.
- **Connection admission cannot be starved (FR-022, review A-01).** Connections start unauthenticated; at most
  `LLMCTL_DECIDE_MAX_UNAUTH_CONNS` (32 of 64) may be, the rest is reserved for authenticated connections; a full pool evicts the
  oldest unauthenticated connection of the heaviest source instead of refusing a newcomer; a connection that has not authenticated
  within `LLMCTL_DECIDE_PREAUTH_TIMEOUT` (3 s) is reset; an IPv6 `/48` shares one unauthenticated budget. New tunables are validated
  (`contracts/env-vars.md`); limits and the volumetric-attacker boundary are in `docs/decide-gateway.md`.
- **Access keys need entropy, failures are slowed, revocation is real.** An operator-supplied key is refused when weak (repeated
  characters, short repeated block, under about 128 estimated bits); generated keys are unaffected. Failed authentications are
  progressively delayed (never the valid key); throttle-table eviction can no longer reset a throttled source; key comparison uses
  fixed-length digests; `key rotate --grace` no longer re-arms a key that an environment `LLMCTL_API_KEY` had shadowed; when the key
  source becomes unreadable, unsafe or empty the gateway fails closed after 5 s with a stderr message and
  `llmctl_decide_key_source_errors_total`.
- **One fail-closed placement guard** (`internal/placement`) for the access key, the certificate directory and the request-log key
  (`log.key` was unguarded): a git error, timeout, "dubious ownership" or corrupt repository refuses instead of allowing.
- **Private-key files are checked at start**: `leaf.key` / BYO `key.pem` must be owner-only regular files (no symlink, no foreign owner);
  weak BYO keys are refused and CA/EKU mismatches warned; `.env` and `log.key` are opened `O_NOFOLLOW|O_NONBLOCK` and judged on the
  descriptor; the offline CA key export never overwrites or follows a symlink (`--force-overwrite-ca-export` to replace).
- A TLS config supplied through `GetConfigForClient` can no longer bypass the TLS 1.2 floor, ALPN and no-tickets; request-log write
  failures are counted (`llmctl_decide_audit_write_failures_total`) and reported once; the detached gateway no longer carries the legacy
  internal-key variable in its environment and `serve --foreground` removes only a pidfile that still names itself.
  See `docs/tls-and-keys.md` (including the loopback port-squatting caveat on multi-user hosts).

### Removed

- **`lib/decide_gateway.py`** (the Python gateway), `tests/test_decide_gateway.sh`, `tests/fixtures/decide_server.py`,
  `tests/fixtures/onnx_decide_server.py`, `docs/scripts/decide_gateway.md`, `docs/scripts/test_decide_gateway.md` and the five shell
  helpers of `lib/decide.sh` that depended on it (options derivation, prompt building, logprob query, response shaping, options-part
  re-serialiser). **History note:** none of these was ever committed or part of any tag (`git log --all` has no commit touching them;
  `v3.0.2` carries none), so no released behaviour was removed; they were retired only after assertion-by-assertion parity with the Go
  gateway was shown (`specs/009-jev-decision-models/evidence/python-gateway-parity.json`) and are archived with their hashes in
  `specs/009-jev-decision-models/evidence/python-gateway-retired/` (Helix 11.4.122/11.4.124).
- Test seams `LLMCTL_ONNX_FAKE`, `LLMCTL_DECIDE_BACKEND_HOST`, `LLMCTL_DECIDE_BACKEND_PORT` (see "Migration").
- The `tests/red/` reproduction harness (moved, results intact, to `specs/009-jev-decision-models/evidence/p1-red-original/`; it drove the removed seams and cannot run).

### Deprecated

- Nothing is deprecated; the retired names above were never released.

### Migration notes

**Upgrade note: re-run `llmctl enable <profile>` for already-enabled ONNX profiles.** The ONNX encoder runtime (`decide-nli`) is now registered and awaited at its real readiness path (`/readyz`, from `portreg_health_path`). An instance that was enabled before the upgrade keeps the old `LLMCTL_REG_HEALTH=/health` in its instance env record (`$LLMCTL_STATE_DIR/services/<instance>.env`) until the record is rewritten, so it is still probed at a path the encoder does not serve and may stay unregistered or be removed by the registry reconciler after its grace. After upgrading, re-run `llmctl enable <profile>` (for example `llmctl enable decide-nli`); `llmctl start` or `llmctl decide scale` also rewrite the record. See `docs/runbooks.md` (Upgrade and rollback).

| If you used (first candidate / pre-release builds) | Now |
|---|---|
| a retryable `502 backend_failed` for an engine that said "context exceeded" / "400" | `422 validation_failed` for a request the model cannot fit (state over the engine context, empty state for an encoder, hypothesis too long, over the pair budget); a deterministic server-side fault (bad readout setting, an engine refusing the gateway's request shape) is the new non-retryable `500 backend_failed` (STATUS TABLE row added); `502` stays for transient failures only |
| a missing option letter reported as an exact `0` | the answer carries `flags:["option_missing"]` + `upper_bounds`; probabilities are conservative; `--min-confidence` / MCP `min_confidence` cap a flagged answer at `1 - max(upper_bounds)` |
| `LLMCTL_DECIDE_SLOTS>1` with the default mode | refused at start (exit 2): add `LLMCTL_DECIDE_MODE=throughput`; invalid `LLMCTL_DECIDE_TEMPERATURE` / `_MASS_THRESHOLD` / `LLMCTL_SEED` are refused at start instead of failing every request |
| `GET /v1/models` `limits{max_options,score_levels}` | additive `max_state_chars`, `max_context_tokens` (and `max_pairs` for encoders); every decision answers `x-llmctl-decide-mode` |
| NLI requests of any size | at most `LLMCTL_DECIDE_MAX_PAIRS` (default 64) pairs per request, refused with 422 before the first pass |
| `serve --stop` matching any process whose command line mentions `llmctl-decide serve` | the pid must be the very executable (device+inode) with the very start time the pidfile recorded, `serve` positional, signalled through a pidfd |
| `LLMCTL_DECIDE_API_KEY` / `decide serve --api-key K` | `LLMCTL_API_KEY` (environment, else the installation `.env`, else generated on first `decide serve`); `llmctl decide key show --yes-print` to read it |
| `LLMCTL_DECIDE_BACKEND_HOST` / `_PORT` (point `ask` at another backend) | removed; use `--endpoint URL` / `LLMCTL_ENDPOINT` to choose a gateway, `LLMCTL_DECIDE_ENDPOINT_<PROFILE>` to choose engines |
| `LLMCTL_ONNX_FAKE=1` (fake model) | removed from production; tests inject stub model modules through `PYTHONPATH` only |
| plain `http://127.0.0.1:8095` | `https://127.0.0.1:8095` with the local CA (`$LLMCTL_HOME/cert/ca/ca.crt`); set `TYPESAFE_BASE_URL` and `SSL_CERT_FILE` accordingly |
| `decide serve --backend-engine ...` | no flag; the engine follows the catalog profile's `decision.protocol` |
| `llmctl decide status --json` as a list | read `.profiles`; gateway and registry are `.gateway` and `.registry` |
| `decide-max` on 8099 | 8097 |
| an operator-supplied `LLMCTL_API_KEY` of any strength | keys must match `[A-Za-z0-9_-]{32,512}` **and** pass an entropy floor (repeated characters, repeated blocks, under about 128 estimated bits are refused). A weak key already in `.env` makes the gateway refuse to start (exit 4, rule named, never the value): run `llmctl decide key rotate` |
| `LLMCTL_API_KEY` exported in a service unit, then `key rotate` | the rotation changes the key file only and prints a `scope:` line saying so; change the variable where the gateway gets it and restart (`docs/runbooks.md`) |
| tenant ids such as `a--b` or `team-` | refused; choose ids without `--` and not ending in `-` |
| unpinned offline `aider` install | refused; set `LLMCTL_AGENTS_ALLOW_UNVERIFIED=1` to accept an UNVERIFIED install |
| llama.cpp pin `b10969`, a copied `llama-server` binary | pin `b11379`; the engine is built shared with RPATH, run it in place (or keep its libraries beside it); a shell `LD_LIBRARY_PATH` pointing at a system `libggml` can shadow the engine's libraries (`docs/runbooks.md`) |
| the Python decision gateway (`lib/decide_gateway.py`) | removed (it was never released); the gateway is the Go binary `llmctl-decide serve` (Go + Gin, `internal/server`) |
| nothing needed Go | install Go >= 1.25 (or copy a prebuilt `llmctl-decide` to `build/llmctl-decide`) before using any `decide` command |

### Known limitations

Reconciled with [`docs/limitations.md`](docs/limitations.md), which is the full list and the authority.

- A decision answer is not a safety guardrail; `confidence` is not a calibrated probability (the 132-item golden set is too small for calibration); the golden set is English only and its labels are agent-authored.
- Release gate: manual QA waived by the operator (above). macOS verified statically only; Windows unsupported.
- Native decision profiles: `decide-lev` and `decide-kev-4b` were first refused by the scheduler for RAM on the development host, then ran to completion there through the scheduler and HTTPS gateway (`evidence/live-models.jsonl` lines 4-5, commit `0197297`; single runs, provisional); `decide-kev-9b` was admitted by the scheduler and then hit a real CUDA OOM at start (`live-models.jsonl` line 6) and was run only on `nezha` (CPU, unpinned snapshot, numbers not pinned to a commit). The planner now books a CPU-mode VRAM figure on a CUDA host (see "Changed"), but for a profile with no measurement it is a ceiling or 0, not a measurement. Windows are 1024 tokens (`decide-julia`, `decide-laya`) and 2048 (`decide-kev-08b`) and longer states answer `422`; option-order flip rates are large for some (Julia-1 41.5%, provisional).
- The engine advance (llama.cpp b10969 to b11379) was verified on CPU with one model; CUDA, MoE, vision, colibri and performance after the 392-commit jump are not covered (G-118).
- **Planner overhead is unmeasured for most profiles.** `defaults.overhead_mb` (activation / compute buffers above weights + KV) is measured for `decide-julia`, `decide-laya`, `decide-kev-08b` and `decide-lev` (reported `partial`: its VRAM half was only measured on a CPU-only host);
  in this tree 18 of the 22 catalog profiles carry none, among them the decision profiles `decide-tiny`, `decide`, `decide-pro`, `decide-nli`, `decide-2b`, `decide-max`, `decide-kev-4b`, `decide-kev-9b`. For those the planner books 0 (a floor, not a measurement):
  `llmctl plan --json` reports `memory_status` and `unknown_overhead`, and the human plan marks the row `overhead UNKNOWN`. A recommendation for such a profile is not evidence that it fits (T139, G-137, G-138).
- **Maturity labels are mostly `unmeasured` in the shipped catalog**: `docs/hardware-tiers.md` (copied from `models/catalog.json`) still lists `decide-tiny`, `decide`, `decide-pro`, `decide-nli`, `decide-2b`, `decide-max` and `decide-kev-9b` as `unmeasured`, although live golden runs now exist for `decide-pro`, `decide-nli` (choice only), `decide-2b` and `decide-kev-9b` (nezha) (status table above); only `decide-tiny` (readout failure, 0/132 well-formed), `decide` (not exercised) and `decide-max` (never run) have no usable golden result. The recorded runs have not all been folded into the catalog labels, so unmeasured here means "not yet derived into the catalog", not "never run";
  `decide-julia` is experimental on all three types, and `score` is experimental on `decide-kev-08b` and `decide-laya`. Golden labels are agent-authored (human review pending).
- **Open at the time of writing** (`specs/009-jev-decision-models/tasks.md`, `evidence/sc004-closure.md`, `evidence/gaps-register.md`): the thinking fix (G-155) is committed (`5184565`, failing-first confirmed) but the G-155 row stays OPEN for its sub-issues; `decide` is unusable at its `mass_threshold` (G-157); `decide-max` was never run (G-158); the planner RAM-vs-VRAM overhead wiring decision for the letter-logit profiles (G-159); the golden harness counts a gateway `max_options` refusal as malformed (G-160); live runs of the six originally pinned models (T061, T068) beyond the nezha runs above, option-order / options-vs-accuracy run (T064), JevBench adapter run (T065),
  two high-severity source-findings rows needing the real encoder model (D-01, T129), the final independent review (T128), the candidate-fingerprinted readiness verdict (T124), and the tag, forge publication and re-download verification (T127). The release scripts (`scripts/release.sh`: reproducible archive, CycloneDX SBOM, third-party notice, `SHA256SUMS`, optional signature) exist and are covered by `tests/test_release_scripts.sh`; they have been dry-run only. None of the open items is claimed done here.
- **Gateway deadline on CPU engines (G-156).** The gateway end-to-end budget `LLMCTL_DECIDE_TIMEOUT` defaults to 8 s (kept below the hosted SDK's 10 s; the Go default and the contract are unchanged). **Cause CONFIRMED by a same-host control** (nezha.local, CPU, `decide-pro`, pinned tree): default 8 s -> 98/132 golden well-formed, 45 x HTTP 502, every one with `x-llmctl-decide-reason: deadline_exceeded` and `x-llmctl-decide-deadline-ms: 8000`; `LLMCTL_DECIDE_TIMEOUT=300` -> 131/132, 0 x 502 (`specs/009-jev-decision-models/evidence/live-models/nezha-pinned-decide-pro-default8s-control-2026-10-09/` vs `nezha-pinned-decide-pro-2026-10-09/`). CPU 200-latency: `decide-pro` median 7.6 s / max 21.0 s, `decide-max` median 13.3 s / max 22.0 s. **Change (launcher-side, status FIXED-PENDING-VERIFY):** the boot-service wrapper (`lib/svc_hook.sh run-gateway`) and `llmctl decide serve` now export `LLMCTL_DECIDE_TIMEOUT=120` when no `LLMCTL_DECIDE_TIMEOUT` is set explicitly and a running or enabled decision instance is a CPU-only llama placement (`--n-gpu-layers`/`--gpu-layers`/`-ngl` with value 0; the onnx NLI encoder does not count, measured median 433 ms) (`lib/decide_timeout.sh`); an explicit value always wins; a GPU-only host keeps 8 s; the gateway banner prints the effective timeout and its source (`default` / `cpu-adaptive` / `env`). The deadline is one global value (a CPU llama instance raises it for all profiles) and a graceful stop cuts requests still running after `LLMCTL_DECIDE_DRAIN_GRACE` (15 s), see G-161. Tests: `tests/test_decide_timeout_adapt.sh` (both launch paths, explicit-wins, GPU, onnx-does-not-adapt, chat-CPU, stale record, scale suffix and its markers, flag spellings, inherited SOURCE; mutations caught) and `TestBannerPrintsEffectiveTimeoutAndSource`. **Not closed:** no live run yet with the adaptive default on a CPU host (the control used an explicit 300); the client-side 30 s default of `llmctl decide ask` and the hosted SDK's 10 s are unchanged; whether 120 s is the right value for hosts slower than the one measured is open. The golden runner records `x-llmctl-decide-reason` per request, so a re-run confirms it.
- **Letter-logit profiles by status**: `decide-2b` works for `noul` and `choice` only; `decide-pro` works with the 502 caveat above; `decide` is not usable at the current `mass_threshold` and no accuracy figure exists for it; `decide-max` has never been run. Use `decide-nli` for `choice`, or a native profile, until these are resolved.
- **`decide scale`** is admission-bounded on the host it runs on; instances beyond what the host can hold are refused with numbers, and throughput mode gives up byte-identical answers across instances (identity is promised per instance only).
- The cluster daemon is exercised with real processes on one machine only; quota enforcement on inference traffic, drain on a minority partition, OIDC and automatic restart of a failed node's models are not wired ([faq](docs/faq.md)). The cluster CLI needs a curl with HTTP3.
- A minimal live exercise of the seven coding agents, an authenticated call from a second machine and behaviour behind an active firewall are not verified.

### Superseded first candidate (historical)

The first candidate of this feature (2026-10-06, never released) described itself as: three `decide*` profiles, a stdlib Python HTTP
gateway (`lib/decide_gateway.py`, `--backend-engine llama|onnx`, optional Bearer key, `LLMCTL_ONNX_FAKE` test seam) and a
`lib/onnx_server.py` serving the Jev wire shape natively. Its test suites then counted 55 / 36 / 9 assertions
(`test_decide.sh` / `test_decide_gateway.sh` / `test_decide_download.sh`). All of that is replaced as described above; the old
validation evidence under `docs/qa/decision-models-validation/` is kept as history.

## v3.0.2 (2026-09-22)

### Highlights

- **New distributed cluster subsystem (`llmctld`)**: Raft-based multi-node
  clustering, auto-placement scheduling, cross-node KV-cache replication with
  warm-restore, mTLS certificate issuance/rotation with zero-downtime
  renewal and live revocation, and full multi-tenancy (per-tenant quotas,
  RBAC, cgroup isolation, encryption at rest). This is the largest addition
  since `v2.0.0` — see the `### Features` section below for the complete,
  chronological build-out (features `002-cluster-model-scheduler`,
  `003-kv-cache-replication`, `004-mtls-cert-rotation`).
- **Reboot-survival fix**: `bin/llmctl status` (and the scheduler's own
  RAM/VRAM overcommit-safety accounting) previously went blind after a host
  reboot, because its sole source of truth was an ephemeral tmpfs marker
  file systemd never repopulates on its own. It now reconciles against real
  `systemctl --user` state and self-heals the missing record.
- **One-command install/bootstrap script** (`scripts/install.sh`): chains
  `setup` → `models download` → `install` → `enable` → a real
  `loginctl`-lingering check → `status`, closing the gap between "the
  systemd/lingering machinery already works" and "there's a single command
  a new user can run." Also fixed a real, independently-discovered bug: the
  on-disk systemd unit *template* can go missing while systemd still has
  units loaded from a prior install, silently breaking any future `enable`
  until `install` is re-run — the new script always re-runs `install`
  first.
- **LAN-accessible by default**: `llama-server`/`colibri serve` previously
  bound to `127.0.0.1` unconditionally, making every profile unreachable
  from any other device on the local network even though the service itself
  was healthy. The bind host is now `LLMCTL_BIND_HOST` (default `0.0.0.0`),
  overridable globally or per-profile (`LLMCTL_BIND_HOST_<PROFILE>`) to lock
  a profile back to loopback-only. **Security note**: llama-server's
  OpenAI-compatible API has no built-in authentication — binding it to
  `0.0.0.0` means any device on the local network can use it with no auth.
  Scope your network/firewall accordingly if that's not acceptable for your
  environment. `colibri` profiles keep their own independent fail-closed
  guard and require `COLI_ALLOW_INSECURE_BIND=1` to bind non-loopback.
- **Full test-type coverage classification** (`008-full-test-coverage`):
  honest classification of the project against the 14-class test taxonomy
  (unit/integration/e2e/full-automation/security/DDoS/scaling/chaos/stress/
  performance/benchmarking/UI/UX/Challenges), closing every real,
  applicable gap with genuine, non-mocked tests.
- **CUDA GPU inference** (`005-cuda-gpu-inference`): real GPU offload
  verified with a live throughput ratio and VRAM delta against actual
  hardware.

### Full conventional-commits history since v2.0.0


### Features
- one-command install/bootstrap script for systemd --user persistence
- wire cluster join/leave, apikey create/rotate, tenant create/list/quota (T006-T011, T016-T020)
- add GET /v1/tenants and GET+PUT /v1/tenants/:id/quota routes (T012-T015)
- add Registry.List + Enforcer.GetLimits accessors (T002-T005)
- wire cluster.Monitor's resource heartbeat + health-driven replication-role failover (T072-FU6/FU7)
- Phase 6 (Polish) — architecture docs, full verification, review (T026/T028/T029)
- Phase 5 (User Story 3) coordinated CA rotation without outage
- Phase 5 (User Story 3) replication-lag visibility (T018-T020)
- Phase 5 (US3) concurrency-safety + audit-reconstructability integration tests (T026-T028)
- real engine cache warm-restore (User Story 2, T012-T017)
- Phase 4 (US2) name-only status/stop + cluster-wide running_profiles (T020-T025)
- Feature 004 Phase 4 (User Story 2) - zero-downtime mTLS cert renewal (T014-T017)
- T013/T014 real multi-process cluster-placement tests + fix two genuine races found by them
- implement US1 auto-placement start dispatch T015 T016 T017 T018 T019
- populate cluster.Node.APIAddr via Join/RegisterSelf (T017 prereq)
- add Node-level RecordRunningProfile/ClearRunningProfile T016 T017
- add per-profile resource-footprint lookup for placement T012-T019
- complete Feature 004 Phase 3 (User Story 1) - cert revocation with real-cluster verification (T007-T013)
- wire Forwarder + node-registration into the real join/bootstrap/HTTP path (003-kv-cache-replication T008 wiring)
- add resource-freshness heartbeat to health.Monitor T008
- make Join/Leave genuinely reach the FSM with real resources T004 T005 T006
- add raft.Node replication-role Apply wrappers + Forwarder (003-kv-cache-replication T008/T009 part 1)
- wire health-detected unhealthy primary to replication-role reassignment (003-kv-cache-replication T004)
- add CommandAssignReplicationRole/CommandReassignReplicationRole FSM commands (003-kv-cache-replication T003 part 2)
- implement TrustStore for live cert revocation/rotation (T003)
- add RunningProfile index and reservation-safe FSM commands T007 T009 T010
- add per-tenant ReplicationRole to ClusterState (003-kv-cache-replication T003 part 1)
- wire LocalExecutor into a live model-lifecycle dispatch API (T072-FU4)
- wire per-tenant encryption at rest into StoreRegistry (T072-FU3)
- wire TenantStateDir into internal/replication's Store (T072-FU2)
- wire per-tenant cgroup isolation into service-spawn path (T072-FU1)
- complete Phases 9-11 (distributed cluster, state persistence/recovery, auth/tenancy) with security fixes

### Fixes
- preflight fetch timeout too short for llama.cpp's huge upstream
- llama.cpp submodule pin + preflight design-toolkit omission + inheritance test
- colibri/superspec submodule pins pointed at never-pushed local commits
- preflight_run() leaked a RETURN trap into its caller, crashing mid-walk
- engine bind host hardcoded to 127.0.0.1, defeating LAN accessibility
- sched_running() never reconciled state after a reboot wiped *.run
- small profile's --parallel 2 silently halved its usable context
- bin/llmctl PATH-symlink resolution (needed for claude_toolkit's llmctl provider detection)
- bin/llmctl breaks when invoked through a PATH symlink
- propagate the LD_LIBRARY_PATH SONAME fix to the Go engine-cache test harness + close a real lint finding
- code-review remediation (C1 CRITICAL + I1-I7) + per-profile port override
- real-hardware anti-bluff bugs found while booting every fitting catalog profile as a genuine running service
- reissue forward-client mTLS identity on renew (T072-FU9 follow-up)
- forward the X-Tenant-ID header on cross-node replication forwards (003-kv-cache-replication T011)
- close a real cross-tenant data-access gap found by independent review (T072-FU5)

### Documentation
- v3.0.1 (v3.0.0 tag never published - preflight bug caught first)
- add CHANGELOG.md + VERSION for v3.0.0 release
- capture 007 closure evidence + CONTINUATION.md §10q (claude_toolkit test fixes)
- add SpecKit spec/plan/research/tasks for features 005-007
- fix stale/non-reproducible citations found by regression-verification
- T028 update with the completed third claude_toolkit attempt (20/74 files, 491 PASS/0 FAIL, bounded timeout)
- T003-T012/T028/T029 honest 14-class classification document + regression evidence + README linking
- add spec/plan/research/tasks for the honest test-type classification feature
- update llmctl.md for real cluster/tenant/apikey commands (T021)
- record honest FAIL verdict for larger-context Superpowers-TUI challenge
- record T072-FU10 closure — genuinely zero disclosed open items remain across 002/003/004
- record T072-FU9 closure — zero disclosed open items remain across 002/003/004
- consolidate 002/003/004 Phase 6 follow-up work into shared 001-llmctl-completion tracking
- honestly update §3 KV-cache replication status for 003 Phases 1-5 (T021)
- document 002-cluster-model-scheduler node-registry, resource-heartbeat, reservation flow, running-profile index (T029)
- correct stale ClientAuth doc comments after T018's RequireAnyClientCert fix
- check off T001-T011 - Phase 1/2/3 complete (003-kv-cache-replication)
- check off T003/T007/T009/T010 as verified complete
- add kv-cache-replication spec set + T001/T002 scaffolding
- add commit-fully integration documentation

### Other
- evidence: refresh CUDA throughput/VRAM proof from this session's live run
- evidence: capture fresh re-run outputs from independent verification pass
- build+docs(llmctld): T020-T023 consolidated bench-all target + documented baseline
- security fix: PUT /v1/tenants/:id/quota must require tenant:manage, not self-ownership (post-review fix, T014/T015)
- docs+fix: resolve the 3 remaining audit gaps + retract a false-negative test claim
- Merge follow-up: reissue forward-client mTLS identity on renew (closes the last disclosed gap from T072-FU9)
- Merge follow-up: wire cluster.Monitor's resource heartbeat + health-driven replication-role failover (closes T072-FU6/FU7's disclosed gaps)
- Merge 004 follow-up: FR-010 live per-voter trust confirmation (closes T072-FU8's disclosed gap)
- WIP: T072-FU8 live-trust-confirmation follow-up (fix + tests, pre-RED-verification)
- Merge 004-mtls-cert-rotation Phase 6 (Polish): architecture docs + full verification + independent review
- Merge 003-kv-cache-replication Phase 6 (Polish): architecture docs + full verification + independent review
- Merge 002-cluster-model-scheduler Phase 6 (Polish): architecture docs + full verification + independent review
- Merge 004-mtls-cert-rotation Phase 5 (User Story 3): coordinated CA rotation without an outage
- Merge 003-kv-cache-replication Phase 5 (User Story 3): replication lag visibility
- Merge 002-cluster-model-scheduler Phase 5 (User Story 3): concurrency-safety + audit-reconstructability
- Merge 004-mtls-cert-rotation Phase 4 (User Story 2): zero-downtime certificate renewal
- Merge 003-kv-cache-replication Phase 4 (User Story 2): real engine cache warm-restore
- Merge 002-cluster-model-scheduler Phase 4 (User Story 2): name-only status/stop + cluster-wide running_profiles
- Merge feature 004-mtls-cert-rotation (Phase 1-3, User Story 1 MVP)
- Merge feature 003-kv-cache-replication (Phase 1-3, User Story 1 MVP)
- Merge feature 002-cluster-model-scheduler (Phase 1-3, User Story 1 MVP)
