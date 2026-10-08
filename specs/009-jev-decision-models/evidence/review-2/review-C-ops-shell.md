# Review 2 — Scope C: registry / vantage / resolver + shell & ops layer

| Field | Value |
|---|---|
| Reviewer | independent adversarial reviewer (did not author this code), read-only |
| Date | 2026-10-07 |
| Tree | uncommitted work tree on `main`, HEAD a9ebefe |
| Scope | internal/registry, internal/vantage, cmd/llmctl-decide/{cmd_registry,serve_resolver,cmd_vantage}.go, lib/{scheduler,service_linux,service_macos,portreg,svc_hook,catalog,download,doctor,engine,decide,admit}.sh, scripts/{install_agents,doc_counts}.sh, scripts/release/build_archive.sh, bin/llmctl, models/catalog.json, .gitignore, go.mod, helix-deps.yaml, templates/agents/* |
| Model/effort | Opus (this review) — effort not settable on this dispatch path, recorded honestly as `?` (§11.4.231(F.2)) |

## What was run in this session (evidence)

- `go test -count=1 ./internal/registry/` on the real tree: `ok ... 11.793s`.
- Four reviewer-authored Go mutations and one shell mutation, each on a copy in a scratch directory (deleted afterwards by exact name; the repository was not modified). Results are in the Mutations section below.
- Ran `_ba_is_secret_path` against a set of probe paths (output quoted in C-03).
- Ran `_svc_unit_for` in tenant mode in dry-run with a throwaway services dir (output quoted in C-05).
- Ran `git stash list`, checked the stash for a third parent, and counted `.git/config` URL credentials. Only names and counts were printed, never values.

## Findings

### C-01 · IMPORTANT · internal/registry/process.go:20-46 (OSIdentity) — liveness cannot tell profiles apart, and pid reuse is not detected
- **Failure scenario.** The rule is "some argv element equals the token, or its basename equals it". Every llama profile registers the same token, `llama-server`.
  - Profile A's engine dies and the kernel hands its pid to a new `llama-server` of profile B. This is plausible on a busy host, and pids also recycle after a restart.
  - The reconciler then treats A's row as alive. A's port gets probed. If anything answers there, A stays routable.
  - The same rule passes plain carriers: `tail -f /var/log/llama-server` and `vim ~/llama-server`, because the basename of an argument equals the token.
  - `Entry.Started` is recorded but never compared with the process start time.
- **Fix.** At registration, record the process start time: `/proc/<pid>/stat` field 22, or `ps -o lstart=` on macOS. Require that it is unchanged. Also make the token profile-specific, for example require argv to contain `--port <entry.Port>`, or match argv[0] only.
- **finding_layer:** source-defect

### C-02 · IMPORTANT · scripts/release/build_archive.sh:91 (`find .git ...`) + header lines 1-6 — release archive ships the whole `.git`, so untracked or unreleased material can leak
- **Failure scenario.** The archive includes every file under `.git`, and `_ba_is_secret_path` never judges `.git/*`. That pulls in:
  - stashes, including `git stash -u`, which stores untracked files such as `.env` as blobs;
  - every local branch and unpushed WIP commit;
  - reflogs and hooks;
  - `.git/config`, where an `https://user:token@` remote or a credential helper would live;
  - `.git/modules/*`.

  This contradicts the header's guarantee "NEVER untracked/ignored files ... a planted .env ... cannot enter a release".
- **Today:** this repo holds 1 stash (`stash@{0}`, WIP on bin/llmctl + lib/catalog.sh). It has no untracked-files parent, and `.git/config` has 0 URL credentials. So nothing secret is exposed today, but the operator's unreleased WIP would ship in the next `make archive`.
- **Fix.** Build the archive's `.git` from a fresh clone of the release ref: `git clone --no-local --single-branch` plus `git submodule update`. Or omit `.git` and ship `git bundle` files. Either way, scan `.git/config` and refuse a URL with userinfo.
- **finding_layer:** source-defect

### C-03 · IMPORTANT · scripts/release/build_archive.sh:62-71 — deny-list exemptions are a bypass, and the list is thin
- **Measured in this session** (`_ba_is_secret_path`):
  - ALLOW `submodules/a/b/docs/x.pem`
  - ALLOW `submodules/llama.cpp/vendor/docs/.env`
  - ALLOW `tests/fixtures/real/.env`
  - ALLOW `tests/fixtures/cert/ca.key`
  - ALLOW `id_rsa`
  - ALLOW `.ENV`
  - ALLOW `secrets/creds.p12`
  - ALLOW `home/.netrc`
- **Why.** In a `case` pattern, `*` matches `/`. So `submodules/*/docs/*` exempts every path that has a `docs` segment anywhere under `submodules/`, and `tests/fixtures/*` exempts the whole subtree.
- **Not independent.** The post-scan uses the same predicate, so it is not a second, independent check.
- **Fix.**
  - Anchor the exemptions to exact segments: `submodules/[^/]*/docs/`, done with a `[[ =~ ]]` regex.
  - Exempt only explicitly listed fixture files, never subtrees.
  - Add `id_rsa*`, `id_ed25519*`, `*.p12`, `*.pfx`, `*.jks`, `*.keystore`, `.netrc`, and `credentials*.json`, all case-insensitive.
  - Add an independent post-scan of content for PEM `PRIVATE KEY` headers.
- **finding_layer:** source-defect

### C-04 · IMPORTANT · lib/engine.sh:175-191 — `rm -rf "${venv}"` on an unbounded, undocumented override
- **Failure scenario.** `venv="${LLMCTL_ONNX_VENV:-${LLMCTL_DATA_DIR}/venv-onnx}"`, and `llmctl build onnx` (or `build all`) runs `rm -rf` on it unconditionally. With `LLMCTL_ONNX_VENV=$HOME`, or any existing project directory, that tree is wiped (§9).
- `LLMCTL_ONNX_VENV` is not documented in contracts/env-vars.md.
- **Fix.** Delete only a directory that either does not exist yet, or contains `pyvenv.cfg` plus an llmctl marker file created at venv build time. Refuse everything else with a message. Document the variable.
- **finding_layer:** source-defect

### C-05 · IMPORTANT · lib/portreg.sh:150-166 (portreg_live_set) with lib/service_linux.sh:341-349,453 — false doctor FAIL in tenant mode (§11.4.201(1) FAIL-bluff)
- **Failure scenario.** `svc_known_profiles` returns instance keys, because the env files are named by `_svc_instance_key`. `svc_is_active` and `svc_main_pid` then prefix the tenant again.
- **Measured in this session:** `known=acme--small unit=llmctl-llama@acme--acme--small.service`.
- **Effect.** With `LLMCTL_TENANT_ID` set, the live set is always empty. Every registered row then reads as "registry row without a live service" and `llmctl doctor` FAILs. Another tenant's env files would also be enumerated.
- **Fix.** Iterate profiles rather than instance keys: strip a `${LLMCTL_TENANT_ID}--` prefix and skip other tenants' files. Or add instance-key-aware variants. Add a tenant-mode case to test_registry_discovery.
- **finding_layer:** source-defect

### C-06 · IMPORTANT · lib/download.sh:25,434-466 (new `_dl_smoke_test_decision`; same pattern as the existing gguf smoke) — readiness is proven against a port, not against the launched process
- **Failure scenario.** The smoke port is fixed (18090). If anything else already listens there, `curl /health` succeeds on the first iteration and the probes run against that foreign server, while the launched child dies on bind. A concurrent `llmctl models download` of another profile is the obvious way this happens. The decision verdict (`choice == billing`) is then recorded for the wrong model: a possible false PASS (§11.4.201 / §11.4.199).
- **Fix.**
  - Allocate the smoke port dynamically: bind-test it, or use `llmctl-decide port allocate`.
  - Check `kill -0 $pid` BEFORE trusting `/health`.
  - Verify the port's owner is `$pid` (`ss -ltnp` / `lsof`), or check `/props` or the model path reported by `/v1/models`.
- **finding_layer:** source-defect

### C-07 · IMPORTANT · internal/vantage/vantage.go:358-373 (Down sweep) — removes OTHER instances' vantage containers
- **Failure scenario.** `Down` lists every container labelled `llmctl.vantage=1` with prefix `llmctl-vantage-` and removes it, not only the one recorded in this state dir. Two concurrent runs (two state dirs, two test runs, or the matrix plus a manual run) kill each other's vantage. It plausibly contributes to G-079 flakiness (UNCONFIRMED). The "only objects it created" rule is not met per instance.
- **Fix.** Label each container with a state-dir-derived id, e.g. `llmctl.vantage.owner=<sha256(stateDir)[:12]>`, and sweep only that label. Leave the sweep of unlabelled-owner stragglers to an explicit `--all` flag.
- **finding_layer:** source-defect

### C-08 · IMPORTANT · scripts/install_agents.sh:110-160 — "integrity_verified": true overclaims
- **npm.** A second, independent download of the top-level tarball is compared with the same registry's integrity value. `npm install` then fetches again, and it verifies the same integrity on its own. The check therefore proves nothing about the installed tree, which includes hundreds of dependencies and runs install scripts (`--ignore-scripts=false`). The version is resolved to "latest" at install time and is not pinned.
- **aider.** `uv tool install aider-chat@latest` is unpinned. The "verified" sha256 is taken from `urls[0]` of PyPI's JSON, which may not be the wheel uv chose, and that wheel is downloaded separately again. The JSONL record then states `integrity_verified: true`.
- **macOS.** `base64 -w0` is GNU-only, so on macOS the check always mismatches.
- **Fix.**
  - Pin versions.
  - Rename the field to e.g. `registry_tarball_matches_integrity`.
  - For aider, use `uv pip install --require-hashes` from a lock file.
  - Use `openssl base64 -A`.
  - Default `--log` should not append to a tracked evidence file during user runs.
- **finding_layer:** source-defect (claim honesty: process-doc)

### C-09 · MINOR · internal/registry/registry.go:308-312 — the stale-snapshot guard in Reconcile is not covered by any test
- Mutation M2 (below) deleted the "re-registered since the snapshot" check and all registry, cmd and gateway tests stayed green.
- **Failure scenario.** A service re-registers (new pid) while a pass is probing. The old pass then removes the fresh row.
- **Fix.** Add a test with a slow Identity/Prober stub during which Register replaces the entry; then assert the row survives.
- **finding_layer:** test-instrumentation

### C-10 · MINOR · internal/registry/registry.go:529-560 (Watch) — the file-identity change detector is not covered by any test
- Mutation M4 (identity reduced to size only) survived.
- **Failure scenario.** A same-size rewrite goes unnoticed; a pid 5-digit to 5-digit change is one example. The gateway keeps routing to the old snapshot until something else changes the size.
- **Fix.** Add a test that changes only same-width fields and asserts a new snapshot.
- **finding_layer:** test-instrumentation

### C-11 · MINOR · internal/registry/ports.go:368-378 + lib/onnx_server.py:567-578 — the hold Prune races slow engines
- The gateway's in-process reconciler prunes, every 5 s, any hold older than 60 s whose port is not bound.
- `onnx_server.py` loads the 1.7 GB fp32 model and runs an inference smoke BEFORE it binds. On a slow CPU host that can exceed 60 s.
- **Effect.** Under the dynamic strategy, the hold can be pruned and the port handed to another allocator, so the engine then fails to bind.
- **Fix.** Before pruning, consult the registry/units: never prune a hold whose unit is activating. Alternatively make PortGrace ≥ LLMCTL_REGISTER_WAIT (600 s), or bind early in `onnx_server.py`.
- **finding_layer:** source-defect

### C-12 · MINOR · lib/service_linux.sh:547 / lib/service_macos.sh:288 (decide_service_disable) — deletes the real unit even in dry-run
- `rm -f` of the unit/plist is not guarded by `LLMCTL_DRY_RUN`, unlike `svc_disable` (line 363).
- **Effect.** `llmctl --dry-run decide serve --disable`, once G-069 wires it, deletes the live unit file while the service keeps running.
- **Fix.** Guard the `rm` with the same dry-run check.
- **finding_layer:** source-defect

### C-13 · MINOR · lib/service_macos.sh:130-139 — no re-registration after a launchd KeepAlive respawn
- Linux re-registers through ExecStartPost on every restart; launchd has no equivalent.
- **Effect.** After a crash-respawn on macOS, the reconciler removes the stale row, nothing re-registers, and `llmctl doctor` FAILs ("live service without a registry row") until the next `llmctl start`.
- Only key rotation is documented as a gap; registration is not.
- **Fix.** Wrap ProgramArguments in `svc_hook.sh run-engine` (prestart, then a background register, then exec). Otherwise document it as a gap under G-009.
- **finding_layer:** source-defect

### C-14 · MINOR · lib/svc_hook.sh:55-60 (`_hk_new_key`) — chmods the parent of a user-supplied key path
- The hook runs `chmod 700 "$(dirname keyfile)"`, and the key path can come from `LLMCTL_ONNX_KEY_FILE`.
- **Effect.** An override such as `~/onnx.key` chmods `$HOME` to 0700.
- **Fix.** Only create and chmod a directory that llmctl owns (under `LLMCTL_STATE_DIR/keys`). Otherwise just verify the existing mode.
- **finding_layer:** source-defect

### C-15 · MINOR · internal/vantage/vantage.go:376 — Down runs `RemoveAll(<state>/vantage)` without proving ownership
- `RemoveAll` runs even when no state.json exists. With `--state-dir ~`, it removes `~/vantage`.
- **Fix.** Remove only `state.json`, `state.json.tmp` and `probe/vantage-probe`, then rmdir.
- **finding_layer:** source-defect

### C-16 · MINOR · internal/vantage/vantage.go:262-301 — headers and body travel on argv
- Probe headers and body are passed as argv to `podman exec`, which is visible in `ps` to other host users.
- **Latent:** the probe is not wired to the matrix yet (G-043). Once it is, an `Authorization: Bearer` header would leak (§11.4.10).
- **Fix.** Pass headers through `exec` stdin or a 0600 file inside the bind mount.
- **finding_layer:** source-defect

### C-17 · MINOR · templates/agents/llmctl-gate-hook.sh:21-22 — predictable temp path
- The hook writes to the predictable path `${TMPDIR:-/tmp}/llmctl-gate.$$.err`.
- On a shared /tmp without fs.protected_symlinks, a pre-planted symlink would make it truncate a victim file.
- **Fix.** Use `mktemp`, or capture stderr with `2>&1` into a variable through a FIFO.
- **finding_layer:** source-defect

### C-18 · MINOR · lib/service_linux.sh:174-181 (`Environment=LLMCTL_ROOT=${...}` unquoted) + `_svc_hook_cmd` %q
- A path with a space or a `%` breaks the unit:
  - systemd `Environment=` splits on whitespace and expands `%` specifiers;
  - bash `%q` escaping is not systemd's quoting.
- **Fix.** Quote as `Environment="K=V"`, double each `%`, and use systemd C-style quoting.
- **finding_layer:** source-defect

### C-19 · MINOR · lib/admit.sh:566-569 — temp dir leaks when `die` fires
- `trap ... RETURN` does not fire when `die` exits from inside `_admit_one`, so the temp dir leaks.
- The trap string also embeds the path in single quotes, which breaks if TMPDIR contains `'`.
- **finding_layer:** source-defect

### C-20 · MINOR · tests/run_tests.sh:24-33 — a SKIP is counted as PASS in the summary
- Suites that SKIP exit 0 and are tallied as `PASS`: test_vantage (no podman) and test_registry_discovery (no go). The summary table cannot distinguish them.
- **Fix.** Make the harness detect a `SKIP` line and list it separately.
- **finding_layer:** test-instrumentation

### C-21 · MINOR · tests/test_release_no_secrets.sh — the deny-list entries are not each mutation-proven
- Mutation S1 (drop `*.pem` from the deny-list) survived. The only tracked-secret case is `leak.key`; the planted `.pem` is untracked, so `ls-files` excludes it regardless of the deny-list.
- Two assertions also fail when the test runs outside a real checkout. The RED scenario copies via git; observed identically on the baseline and the mutant copy, so this is environment-dependent, not a mutation effect.
- **Fix.** Add one tracked file per deny class (`.env.x`, `*.pem`, `cert/`) and one per exemption-escape path (see C-03).
- **finding_layer:** test-instrumentation

### C-22 · MINOR · tests/test_catalog_json.sh:326-330 — the "no stale 8099" check uses a fixed file list
- The check covers only six files.
- docs/qa/decision-models-validation/README.md:54 still says "decide-max (8099)". As an iteration-2 history line this is arguably acceptable, but it is unmarked as historical.
- **Fix.** Grep all tracked `*.md` and allow explicitly marked historical lines.
- **finding_layer:** process-doc

### C-23 · MINOR · cmd/llmctl-decide/serve_resolver.go:117-122 — auto resolver picks registry mode on stale rows
- Auto mode switches to registry mode when the registry holds ANY entry, including only a stale `decide-gateway` row from a previous run.
- **Effect.** The gateway then has zero decision backends while static endpoints would have worked.
- **Fix.** Require ≥1 healthy `kind=decide` entry.
- **finding_layer:** source-defect

### C-24 · MINOR · internal/registry/registry.go:62-75 — "corrupt registry" is surfaced only once
- The submodule moves the corrupt file aside, so the first operation errors.
- Every later operation silently sees an empty registry, which is the "looks like no services" outcome the comment says must not happen.
- A second corruption overwrites `services.json.corrupt` (UNCONFIRMED: submodule behaviour not read).
- **Fix.** Keep a sticky `.corrupt-detected` marker that later operations report until it is acknowledged.
- **finding_layer:** source-defect

### C-25 · MINOR · lib/engine.sh:211-221 — `build all` omits `decide`
- `llmctl build all` builds llama + colibri + onnx but NOT `decide`, although the registry, dynamic ports and the gateway unit all need `build/llmctl-decide`.
- **Fix.** Include `decide` in `all`, or document why it is left out.
- **finding_layer:** process-doc

## Mutations (reviewer-authored, on a copy; scratch dirs deleted by exact name)

| ID | Mutation | Result |
|---|---|---|
| M1 | `matchToken`: exact/basename match → `strings.Contains` | KILLED (TestOSIdentityRejectsCarriers, matchToken table) |
| M2 | Reconcile: delete the stale-snapshot `continue` | SURVIVED (registry, cmd/llmctl-decide, gateway tests green) → C-09 |
| M3 | Ports.Allocate claim: delete the `holderOf` check | KILLED (TestFixedPortHeldByOtherNameIsRefused) |
| M4 | Watch: file identity reduced to size only | SURVIVED → C-10 |
| S1 | build_archive: drop `*.pem` from the deny-list | SURVIVED (the mutation-relevant assertions stayed green; 2 env-caused failures identical on baseline) → C-21 |

## Checked and found sound (no finding)

- **Locking and state files.**
  - flock with an EINTR loop.
  - Shared locks for readers.
  - `ports.json` written temp → fsync → rename; it fails closed when corrupt.
  - Reconciler single owner via `LOCK_NB` flock, released on close, with standby takeover.
- **Liveness guards.**
  - `pid <= 1` is refused at registration and in the identity check (no pgid signalling anywhere in scope; §11.4.263 not engaged).
  - A zombie (empty cmdline) reads as not alive.
  - TLS probe: a nil pool never verifies; a ca_file label must be owned by the user and not world-writable.
- **Key and env-file handling.**
  - Env record and plist are created 0600 before any write.
  - Smoke key comes from a umask-077 `mktemp`.
  - The key reaches curl through `-K -` / `--config <(...)`, never argv.
- **Hash-locked builds.** The onnx venv uses `--require-hashes --no-deps --only-binary`, and an UNPINNED marker is refused.
- **Hook gate.** The gate hook fails closed on unexpected status.
- **Catalog.**
  - Ports are unique: 8080-8087, 8090-8094, 8096-8098; 8095 is the gateway.
  - Port map in catalog.json and `.specify/memory/constitution.md`: decide-max = 8097.
  - All decide profiles carry a 40-hex `hf_revision`, per-file sha256/size and a licence. The licence values were not verified against huggingface.co (no network).
- **Dependencies.**
  - The Containers gitlink equals helix-deps `pinned` (4a8f04e), with a clean submodule tree.
  - `go.mod` replaces it with `./submodules/containers` (§11.4.76 respected; vantage uses `runtime.ContainerRuntime` only).
- **Unit generation.** StartLimit* sit in `[Unit]`; ExecStartPost/ExecStopPost carry `-`; the memory policy follows OD-14 (MemoryHigh=MemoryMax=total).

## Could not verify (honest gaps, §11.4.6)

- Live systemd/launchd behaviour of the new units (instructed not to touch user units), including whether `RestrictAddressFamilies`/`ProtectSystem` break the ExecStartPost waiter in practice.
- The macOS paths: `ps -o args=` liveness, plists, `base64` (no Mac).
- Podman vantage at runtime (instructed not to run podman).
- `shellcheck` cleanliness (G-012/G-036 already OPEN; not re-run).
- macOS bash 3.2 portability of the new bash code was not systematically checked. Spot check: lib/portreg.sh uses `${!v}` and `local -a`, which are fine on 3.2. scripts/install_agents.sh uses `read -r -a` and `<<<`, which are also fine. I did not prove the absence of 4.x-only features such as `declare -A`, `${x,,}`, `mapfile` and `|&` across every changed file.
- The submodule's corrupt-file move semantics (C-24).
- The licence values against the live HF API.

## Verdict

- **SOURCE: NO-GO.** No BLOCKING finding, but 8 IMPORTANT source findings must be fixed and re-reviewed before acceptance: C-01, C-02, C-03, C-04, C-05, C-06, C-07, C-08. Under §11.4.134 an IMPORTANT finding blocks GO. C-02/C-03/C-04 are §9/§11.4.10 class; C-05/C-06 are §11.4.201 false-verdict class.
- **TESTS: NO-GO.** Two reviewer mutations on the registry (M2, M4) and one on the archive deny-list (S1) survive (C-09, C-10, C-21). The harness counts SKIP as PASS (C-20). None of these is a bluff of an existing assertion; they are coverage holes.
- **DOCS: GO with minor fixes** (C-22, C-25, plus documenting `LLMCTL_ONNX_VENV`).

## Fix status

Date 2026-10-07, fixer FIX-C. Test-first: each fix has a test that was observed to FAIL when that fix is reverted (mutation run recorded per row), then GREEN. Go: `go test -race ./internal/registry/... ./internal/vantage/... ./cmd/...` green; `gofmt`/`go vet` clean; `make lint` rc 0.

- **C-01** FIXED - `OSIdentity` matches argv[0] (or interpreter + argv[1] script, an exact marker argument, or a `--flag=token` form), no longer a path ARGUMENT's basename (`tail -f .../llama-server`); `ProcFingerprint` (boot id + `/proc/<pid>/stat` field 22 + argv hash; `ps -o lstart=` without procfs) is recorded at `Register` (`proc_fp`) and compared in every liveness proof (`Registry.alive`). Tests: `TestC01TailAndEditorCarriersAreNotTheService`, `TestC01InterpreterScriptMatches`, `TestC01RecycledPidOfSameProgramIsNotAlive` (two real processes with identical argv, the second owning the "reused" pid), `TestC01FingerprintShape`, `TestMatchToken` (extended table). Mutations: any-arg basename match -> `C01Tail` fails; fingerprint compare removed -> `C01Recycled` fails.
- **C-02** FIXED - the archive's `.git` is generated (`git bundle HEAD` -> single ref, no remote/hook/reflog/stash/credential config, rebuilt index) for the main repo and every submodule; the source `.git` is never copied. Tests (`tests/test_release_no_secrets.sh` section 7): a repo with a `git stash -u` holding an untracked `.env` blob, a local-only branch commit, a token-bearing remote, a credential helper and an executable hook, plus the same in the submodule: after extracting BOTH the tar.gz and the zip no stash/ref/blob/commit/remote/hook/reflog/token is present while the release commit is (control). Mutation: bundle `--all` -> 8 assertions fail.
- **C-03** FIXED - `_ba_is_secret_path` rewritten with anchored regexes on the lower-cased path, extended deny-list (`id_rsa*`, `id_ed25519*`..., `.netrc`, `.pgpass`, `*.p12/pfx/jks/keystore`, `credentials*.json`, `cert/`, case-insensitive `.env*`); exemptions are EXACT paths from `scripts/release/public_allowlist.txt` and `tests/fixtures/PUBLIC_FIXTURES.txt` (glob / `..` / `/` entries refused); independent post-scan `scripts/release/scan_archive.py` (tarfile/zipfile, PEM private-key block content scan, shipped-`.git` state). The real tree's tracked files (12,805) judged: none denied (the Containers `tests/configs/.env.*` templates, which made `make archive` abort before, are now named exemptions). Tests: deny table incl. every old exemption escape, manifest glob refusal, scanner on one archive per class, quoted-header control.
- **C-04** FIXED - `engine_venv_prepare`: absolute path only; refuses `/`, symlinks, `$HOME`/data dir/install root and any ancestor, and an existing directory lacking `.llmctl-onnx-venv` naming exactly that path (legacy marker-less venv at the default location stays replaceable); every created venv gets the marker; `LLMCTL_ONNX_VENV` documented in `contracts/env-vars.md`. Tests (`tests/test_engine_build_onnx.sh`): HOME / ancestor / data dir / unmarked dir / symlink / foreign marker refused with nothing deleted, `/`, relative, install root via the pure predicate. Mutation: guard call removed -> 8 assertions fail.
- **C-05** FIXED - `svc_known_profiles` yields this tenant's PROFILE names (skips other tenants); `portreg_live_set` reports the registry row name (instance key). Tests (`tests/test_service_ops_hardening.sh`, fake `systemctl` + real registry): profiles `fast,small`, unit `llmctl-llama@acme--small.service`, no `acme--acme--` in any call, `registry == live set` in tenant mode and the reverse discrepancy still reported. Mutations (old known_profiles / name mapping removed) fail 4 assertions each.
- **C-06** FIXED - smoke port default `auto` (free ephemeral per test; a pinned port in use is refused); `_dl_smoke_wait` requires the launched pid alive, holding the LISTENING socket (`/proc/net/tcp` inode vs `/proc/<pid>/fd`; lsof/ss fallbacks; unresolvable = fail closed) and the path answering; applied to the gguf, decision and onnx smoke. Tests (`tests/test_decide_download.sh` section 4): a foreign server answering `/health` is not accepted (reason named), the real owner is, a dead pid never is, auto picks a non-18090 port, a pinned in-use port refused, end-to-end download with a foreign server elsewhere. Mutations: ownership check removed / old 18090 default / in-use refusal removed each fail.
- **C-07** FIXED - containers carry `llmctl.vantage.owner=<sha256(state dir)[:12]>`; `Down` sweeps only its own owner (plus its recorded container); `vantage down --all` is the explicit host-wide recovery. Tests: `TestC07DownRemovesOnlyItsOwnStateDirsContainers` (two state dirs), `TestC07ForeignOwnerAndUnownedAreLeftAlone`; the real-podman `tests/test_vantage.sh` passes. Mutation: owner label dropped from the sweep fails both.
- **C-08** FIXED - `npm pack` -> sha512 of the packed tarball vs registry integrity (or `scripts/agents.lock` pin) -> `npm install --ignore-scripts <that tarball>` -> installed bin must answer `--version`; aider: PyPI's wheel downloaded, sha256 vs PyPI digest / pin, `uv tool install <that wheel>`; offline falls back to `aider-chat@latest` recorded `integrity_verified:false` and printed UNVERIFIED; records add `integrity_source`, `pinned`, `dependency_tree_pinned:false`; portable `openssl base64 -A`; default `--log` moved off the tracked evidence file; `--lock`/`--write-lock`. Tests (`tests/test_install_agents.sh`, fakes extended with `npm pack`/tampering): installed arg is the tarball file, tampered pack refused (the old second-download check would have passed it), tampered wheel refused, offline unverified, pins used / wrong pin refused / `--write-lock`, no GNU-only `base64 -w0`, default log location. Mutations (install by name, skip compare, wheel compare off, `ok=true` offline, tracked default log) each fail.
- **C-09** FIXED (test) - `TestC09ReconcileDoesNotRemoveRowReRegisteredDuringProbe` (slow identity stub, re-register while probing); mutation M2 (guard deleted) now fails it.
- **C-10** FIXED (test) - `TestC10WatchDetectsSameSizeRewrite` (pid 12345 -> 54321, same file size); mutation M4 (size-only identity) now fails it.
- **C-11** FIXED - `DefaultPortGrace` = 600 s (>= `LLMCTL_REGISTER_WAIT` default), `registry reconcile --port-grace` defaults to it and to a larger `LLMCTL_REGISTER_WAIT`, the gateway's in-process reconciler does the same. Tests: `TestC11PortHoldSurvivesDefaultGraceButNotForever`, `TestC11CLIPortGraceFollowsRegisterWait`, `TestC11GatewayPortGraceFollowsRegisterWait`; mutations (60 s default, CLI/gateway wait ignored) fail.
- **C-12** FIXED - Linux and macOS `decide_service_disable` print `[dry-run] rm -f ...` and keep the real unit/plist under `LLMCTL_DRY_RUN=1`. Tests: `tests/test_service_ops_hardening.sh` (C-12), `tests/test_decide_service.sh` (previously asserted the buggy deletion; now asserts survival in dry run and removal in a real disable). Mutations (guards removed) fail.
- **C-13** FIXED - macOS engine plists run `svc_hook.sh run-engine <profile> -- <engine>`: key rotation + detached registration waiter for its own pid + `exec` (pid preserved), `nohup` where there is no `setsid`; `svc_start` no longer double-rotates. Tests: wrapper really registers the exec'd engine, row survives `reconcile` (fingerprint holds across exec), a kill -9 + respawn re-registers under the new pid; plist structure in `test_decide_service.sh` / `test_service_ops_hardening.sh`. Mutations (plist unwrapped, `hk_register` removed) fail. launchd itself is still not exercised (no Mac, G-009).
- **C-14** FIXED - `_hk_new_key` chmods 0700 only a directory under `$LLMCTL_STATE_DIR/keys` or one it created. Test: operator-supplied key path in a 0755 directory keeps 0755; created and llmctl-owned directories are 0700. Mutation (always chmod) fails.
- **C-15** FIXED - `Down` deletes only `state.json`, `state.json.tmp`, the staged probe and `req-*.json`, then removes the directories only if empty. Test `TestC15DownDeletesOnlyFilesItWrote` (pre-existing unrelated `<state>/vantage/my-notes.txt` survives); mutation (RemoveAll) fails.
- **C-16** FIXED - probe headers/body go through a 0600 `req-<random>.json` in the bind-mounted probe dir (`vantage-probe http --request-file`), removed after the call. Tests: `TestC16ProbeHeadersAndBodyNeverOnArgv`, `TestC16RequestFileIs0600`, `TestMainRequestFileCarriesHeadersAndBody` (probecore, real HTTP server); mutations fail.
- **C-17** FIXED - the stderr capture uses `mktemp`; failure to create it is the fail-closed path (exit 2). Test `tests/test_gate_hook_tmp.sh` (symlink planted at `llmctl-gate.$$.err`, victim intact; unusable TMPDIR blocks); mutation (predictable name) fails.
- **C-18** FIXED - `Environment="K=V"` with `\\`/`\"` escaped and `%` doubled, `%`-doubled `EnvironmentFile=`/`StandardOutput=append:` paths, the hook path quoted. Tests: textual assertions with a state dir containing space, `%` and `"`; a live transient systemd unit reads the quoted value back byte for byte (skipped honestly without a user manager); `systemd-analyze verify` accepts the unit; `tests/test_services.sh` / `test_decide_service.sh` updated to the quoted form. Mutations (unquoted env, no `%` doubling) fail.
- **C-19** FIXED - `_admit_one` runs in a subshell with an EXIT trap referencing a variable (plus a parent `rm -rf`). Test `tests/test_admit.sh` C-19 (dying evaluation, TMPDIR containing `'`); the old RETURN-trap form fails it.
- **C-20** FIXED - `tests/run_tests.sh`: `SKIP-SUITE: <reason>` (exit 0) -> `SKIP`, separate counter and `NOT RUN` list; asserted-nothing-but-skipped -> SKIP; partially skipped -> `PASS (n skipped assertion(s))`; final line `PASS: N  FAIL: N  SKIP: N`; ~20 suites converted to the marker; `scripts/doc_counts.sh` knows `skipped-suite`. Tests in `tests/test_run_tests_format.sh`; mutation (skip counted as PASS) fails. Documented in `docs/scripts/run_tests.md`.
- **C-21** FIXED - S1 killed: dropping `*.pem` from the bash predicate fails 4 assertions of the new deny table, dropping it from the Python scanner fails 2 (one archive per deny class); stash/branch/remote fixture added (see C-02).
- **C-22** FIXED - the stale-8099 check scans every tracked/unignored `*.md` (vendored trees, `specs/`, `docs/research/` excluded; a line mentioning 8097 or `<!-- historical -->` is a statement about the move) and has a planted-line control; it found a real stale line in `docs/CONTINUATION.md` (fixed) and the iteration-2 QA README line (reworded).
- **C-23** FIXED - auto resolver switches to the registry only with >= 1 healthy `kind=decide` entry. Test `TestC23AutoIgnoresStaleGatewayRowAndUnhealthyEngines`; mutation (`List()`) fails.
- **C-24** FIXED - sticky `<state>/registry/.corrupt-detected` note + dated copies of the aside file; reported by `list` (stderr), every `reconcile` (`--strict` exit 1) and `diff` (exit 1) until `registry ack-corrupt`. Test `TestC24CorruptRegistryIsReportedUntilAcknowledged`; mutation (note not written) fails.
- **C-25** FIXED - `engine_build all` = llama + colibri + onnx + decide. Test in `tests/test_engine_build_decide.sh`; README/CHANGELOG/help updated.
- **G-074** FIXED - `registry reconcile --prune-unknown-after D` (default off; `unknown_since` recorded on the row), doctor WARN naming the rows and the remedy. Tests: `TestG074PruneUnknownAfter`, `tests/test_service_ops_hardening.sh` (G-074). Mutations fail.
- **G-067** FIXED - `svc_install` regenerates the engine templates and an installed gateway unit; `svc_stale_units` + doctor WARN `stale service unit(s)`. Test in `tests/test_service_ops_hardening.sh` (stale -> WARN -> `llmctl install` -> clean). Mutations fail.
- **G-078** FIXED (breaking, in CHANGELOG) - bare `llmctl build` prints usage and exits 2. Test in `tests/test_engine_build_decide.sh`.

Other fixes made on the way: `tests/test_vantage.sh` compared the whole host network list (flaky on a shared host, G-079): it now asserts that the vantage left no NEW network; `tests/fixtures/release_secrets/scenario.py` copies the archive tooling's new data files so the D-30 RED scenario also works on an uncommitted tree.

Not fixed / honest limits: launchd behaviour of the wrapped plists and macOS `ps -o lstart=` fingerprints are fixture-tested only (no Mac, G-009); `make archive` was exercised on small real-git fixtures (stash/branch/remote/submodule) and the deny-list judged on the real tree's 12,805 tracked files, but a full archive of this 2 GB tree was not produced in this session; the `--ignore-scripts` default of `install_agents.sh` is verified against fakes only (the real `cn`/`cline` packages were not re-installed here; `LLMCTL_AGENTS_ALLOW_SCRIPTS=1` is the documented escape and the post-install `--version` smoke names it when a binary does not start).
