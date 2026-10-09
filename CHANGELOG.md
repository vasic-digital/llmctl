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

## 3.1.0 (YYYY-MM-DD (set at tag time))

The local **typed-decision** feature (Jev-class `noul` / `choice` / `score` answers from small
decision models) as a secured, discoverable service. The wording is final only when the tag is cut;
every statement below is backed by a test or a document named next to it. What was and was not verified live, and every
known limit: [`docs/limitations.md`](docs/limitations.md); every known gap: `specs/009-jev-decision-models/evidence/gaps-register.md`.

**Release status.**

- **Manual QA waived by the operator, 2026-10-08; the constitution gate is operator-waived, not satisfied.** No person ran the live manual-QA pass the project's constitution (section 11.4.185) requires before a tag; this release rests on the automated gates, the independent reviews and the full test suite.
- **macOS: verified statically only.** Linux is the live-verified platform; Windows is unsupported.
- **Version.** The `VERSION` file and `llmctl version` now both read `3.1.0` (`llmctl version` printed a stale `0.1.0` before; `tests/test_cli.sh` now also asserts it equals `VERSION`). The catalog's own `version` field is the schema version (still `1`) and is unchanged. The separate `llmctld` cluster daemon module keeps its own build version (`0.1.0`, `llmctld/cmd/llmctld/main.go`; its comment says it is tracked independently), so `llmctld --version` does not read `3.1.0`. The OpenAPI contract is `3.1.0-draft` until the tag is cut (flipped together with the tag; see the release checklist).
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
- The OpenAPI contract `specs/009-jev-decision-models/contracts/openapi.yaml` keeps `info.version: 3.1.0-draft` until the tag is cut; `tests/test_version_consistency.sh` accepts `3.1.0` or `3.1.0-draft` and the version marker is flipped together with the tag (T127).
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
