# llmctl Architecture Map — Reference for Implementers

> **Header note (added 2026-10-06):** this brief was the implementation
> reference for the decision-models feature (`lib/decide.sh`,
> `lib/decide_gateway.py` (HISTORICAL: that Python gateway was never released and was
> retired in favour of the Go gateway, `cmd/llmctl-decide`), the `decide` catalog profiles, and the
> planner's `decision_instances` subtree). Where this map and the shipped
> code differ, the code wins — see `docs/decision-models.md` and
> `docs/decide-gateway.md` for what actually exists.

Repo: https://github.com/vasic-digital/llmctl (branch `main`, tree sha `a9ebefe…`).
Scope: everything needed to add new "decision model" profiles (small classifier-style models) without re-reading the repo.

---

## 1. Top-level layout & lib/ responsibilities

```
bin/llmctl            CLI entrypoint (bash, 277 lines) — sources all lib/*.sh, dispatches commands
lib/                  all bash libraries (sourced, not exec'd)
  common.sh           logging/colors, die()/need_cmd()/have_cmd(), XDG-aware state dirs,
                      LLMCTL_* env vars, JSON helpers json_query()/json_stdin()/json_body() (python3 wrappers)
  os_detect.sh        llmctl_os()/llmctl_arch()/llmctl_nproc()/llmctl_pkg_hint(), is_apple_silicon
  hardware.sh         hw_probe_json()/hw_probe_human() — live probe of CPU/SIMD/RAM/GPUs/storage;
                      LLMCTL_FAKE_HW fixture override seam
  catalog.sh          catalog query fns (catalog_profiles/catalog_field/catalog_port/catalog_engine/
                      catalog_files/catalog_total_size_mb/catalog_bind_host...), tier classification
                      (catalog_classify_tier), THE PLANNER: catalog_plan_json()/catalog_plan_human()
  download.sh         verified downloads: download_profile()/verify_profile(), sha256/git-blob
                      checksums, smoke test, evidence logs
  engine.sh           engine_build [llama|colibri|all] — cmake builds of submodules, backend
                      autodetect (cuda/metal/rocm/cpu) via engine_detect_backend()
  scheduler.sh        co-residency engine: sched_start/stop/switch/auto/enable/status, admission
                      control (budget refusal), reservations, launch-arg construction
                      (sched_build_launch), flock-based lock (scheduler::with_lock)
  service_linux.sh    systemd --user template units: svc_install/svc_write_env/svc_enable/svc_start/
                      svc_stop/svc_logs/svc_is_active, MemoryHigh/MemoryMax limits
  service_macos.sh    launchd LaunchAgents equivalent of the svc_* API
  doctor.sh           doctor_run() — environment self-diagnosis, PASS/WARN/FAIL + evidence
  cluster.sh          thin HTTP(S/HTTP3) client to llmctld: cluster::require_daemon, cluster::request,
                      cluster::request_checked — hard-fails if daemon unreachable
models/catalog.json   THE model catalog (all profiles)
tests/                custom bash harness (no bats): run_tests.sh, helpers.sh, test_*.sh, fixtures/
llmctld/              Go cluster daemon (opt-in; single-host never depends on it)
  cmd/llmctld/main.go daemon entrypoint + hardware_probe.go
  internal/{api,auth,authz,audit,cluster,executor,isolation,mtls,raft,replication,tenancy}
  test/integration/   Go integration tests
scripts/install.sh, scripts/release/{build_archive,create_release,preflight_submodules}.sh
docs/                 see §7
specs/                001..008 feature specs (speckit-style: spec/plan/tasks/research/quickstart/contracts)
submodules/           git submodules: llama.cpp, colibri, superspec (plus constitution/ at repo root)
Makefile              make test/lint/validate/json-check/llmctld-*/bench-all/archive/install
VERSION, CHANGELOG.md, README.md, AGENTS.md, CLAUDE.md
```

`bin/llmctl` command surface (function `main`, case-dispatch): `setup, doctor, hw|probe, plan,
models {list,download,verify}, build, install, enable, disable, start, stop, restart, switch,
auto, status, logs, cluster {join,leave,status}, tenant {create,list,quota}, apikey
{create,rotate}, version, help`. Adding a command = add a `case` arm + a `cmd_*` function or a
lib function; usage text in `usage()`.

---

## 2. Model catalog format

**File: `models/catalog.json`** (queried by `lib/catalog.sh`; `LLMCTL_CATALOG` env var overrides the path — used by tests).

Top-level keys: `version` (int), `notes`, `ports` (display map), `profiles` (object keyed by profile name).

Profile schema:
- `engine`: `"llama"` | `"colibri"` (dispatch in `sched_build_launch` and `download_profile`; any new engine value needs arms in both, plus `sched_rank_for_capability` if used by `auto`)
- `capability`: array, e.g. `["chat"]`, `["vision","chat"]`, `["coder","chat"]` — consumed by `llmctl auto <cap>` via `sched_rank_for_capability()` in scheduler.sh
- `min_tier`: `below-minimum|baseline|workstation|datacenter` (default `baseline` via `catalog_min_tier`)
- `port`: int — fixed per profile; host-local override via env `LLMCTL_PORT_<PROFILE>` (name uppercased, `-`→`_`; see `catalog_port_override_env_name`)
- `hf_repo`: e.g. `"unsloth/Llama-3.1-8B-Instruct-GGUF"`; `hf_revision`: usually `"main"`
- `desc`: free text (project convention: includes live-verification evidence + override hints)
- `defaults`: `{ctx, ngl, parallel, flash_attn, kv_cache_type?}` — `ctx` default 8192; `kv_cache_type` in {f32,f16,bf16,q8_0,q5_1,q5_0,q4_1,q4_0,iq4_nl}; overrides: `LLMCTL_CTX_<PROFILE>`, `LLMCTL_KVTYPE_<PROFILE>`
- `files`: array of `{name, size (bytes int), sha256 (hex or null), role ("model"|"mmproj")}` — null sha256 = fetch from HF API at download time (allowed only for small non-LFS config files, per the anti-bluff contract)

Verbatim example 1 (single-file GGUF, `fast`):
```json
"fast": {
  "capability": [
    "chat"
  ],
  "min_tier": "baseline",
  "port": 8080,
  "defaults": {
    "ctx": 8192,
    "ngl": 99,
    "parallel": 1,
    "flash_attn": "auto"
  },
  "desc": "Llama 3.1 8B Instruct Q4_K_M - fast general chat",
  "engine": "llama",
  "hf_repo": "unsloth/Llama-3.1-8B-Instruct-GGUF",
  "hf_revision": "main",
  "files": [
    {
      "name": "Llama-3.1-8B-Instruct-Q4_K_M.gguf",
      "size": 4920739200,
      "sha256": "b3bdbf23b47d7e6bb791c99b206deb169cd5a96362a9e3399028df2faacdc506",
      "role": "model"
    }
  ]
}
```

Verbatim example 2 (multi-file with mmproj, `vision`):
```json
"vision": {
  "capability": [
    "vision",
    "chat"
  ],
  "min_tier": "baseline",
  "port": 8082,
  "defaults": {
    "ctx": 24000,
    "ngl": 99,
    "parallel": 1,
    "flash_attn": "auto",
    "kv_cache_type": "q4_0"
  },
  "desc": "Gemma 3 4B IT Q4_K_M + mmproj - lightweight vision. ...",
  "engine": "llama",
  "hf_repo": "ggml-org/gemma-3-4b-it-GGUF",
  "hf_revision": "main",
  "files": [
    {"name": "gemma-3-4b-it-Q4_K_M.gguf", "size": 2489757856, "sha256": "882e8d2db44dc554fb0ea5077cb7e4bc49e7342a1f0da57901c0802ea21a0863", "role": "model"},
    {"name": "mmproj-model-f16.gguf", "size": 851251104, "sha256": "8c0fb064b019a6972856aaae2c7e4792858af3ca4561be2dbf649123ba6c40cb", "role": "mmproj"}
  ]
}
```

Catalog contract enforced by `tests/test_catalog_json.sh` (see docs/scripts/test_catalog_json.md): valid JSON, unique ports, required fields, real sha256s. Existing profile names: fast, coder, vision, vision-pro, moe-fast, small, ws-dense-32b, ws-moe-30b, colibri-glm, colibri-qwen36 (ports 8080–8091).

**To add a "decision model" profile:** add entry here, add port to `ports` map, extend `sched_rank_for_capability()` in scheduler.sh if `auto` should pick it (e.g. a new capability word needs a new case arm), extend port-map docs in `.specify/memory/constitution.md` appendix + README, and add planner expectations in `tests/test_planner.sh`.

---

## 3. Memory model (all in `lib/catalog.sh`, function `catalog_plan_json`'s embedded Python)

- **RAM budget:** `ram_budget = max(0, ram_avail - 4096)` — `hw["memory"]["available_mb"]` (LIVE measurement, no fallback) minus **4 GiB headroom** (line ~268).
- **VRAM budget:** `vram_budget = int((vram_free if vram_free is not None else vram_total) * 0.85)` — **15% headroom** off REAL FREE VRAM when `gpu_free_vram_mb` was measured (flag `vram_live=True` emitted in budgets), else off total VRAM as fallback.
- **KV cache:** `kv_mb(ctx, parallel, kv_type) = ceil(ctx * parallel * KV_TYPE_RATIO[kv_type] / 8.0)` MiB; f16 base = 1/8 MiB per token-slot. `KV_TYPE_RATIO`: f32 2.0, f16/bf16 1.0, q8_0 0.53125, q5_1 0.375, q5_0 0.34375, q4_1 0.3125, q4_0 0.28125, iq4_nl 0.28125.
- **Footprint decision (function `footprint(name, p)`):**
  - colibri: `ram_need = 24576 if size_mb >= 102400 else 8192`, vram 0, storage = size (+10% must be free).
  - llama gpu mode: if `size_mb + kv <= vram_budget and 2048 <= ram_budget` → `{mode: gpu, ram_mb: 2048, vram_mb: size+kv, ngl: defaults.ngl}`.
  - llama cpu mode: elif `size_mb + kv <= ram_budget` → `{mode: cpu, ram_mb: size+kv, ngl: 0}`.
  - else `{mode: none, fits: False}`.
- **Tier gate:** `tier_ok = tier_rank[host_tier] >= tier_rank[min_tier]`; `recommended = fits and tier_ok`.
- **Co-residency groups:** greedy bin-packing of recommended profiles in port order against both budgets (in `catalog_plan_json`, output key `coresidency_groups`).
- **Runtime admission control / refusal** (`lib/scheduler.sh`):
  - `_sched_initial_used <plan_file>` — starting used-RAM/VRAM accumulator: 0 for RAM (budget already live), `sched_reserved_field vram_mb` only when `vram_live` is False (avoids double-subtracting); honors `_sched_auto_{ram,vram}_credit` from the auto-eviction loop.
  - `_sched_start_impl` (~line 526): for each requested profile checks `used_ram + ram > ram_budget || used_vram + vram > vram_budget` → refusal message: `err "cannot start '${p}': needs ${ram} MiB RAM + ${vram} MiB VRAM, but only ... remain"` and suggests an alternative fitting profile for the same capability.
  - `_enable_impl` (~line 663): same budget check for persistent enable (`cannot enable ... remain within the host budget`).
  - `_sched_auto_impl` (~line 817): LRU-evicts non-enabled services (oldest `started_epoch` first) until the pick fits.
  - Reservations: `$LLMCTL_RUNTIME_DIR/<profile>.run` files (mode/port/ram_mb/vram_mb/started_epoch) written by `_sched_write_reservation`; summed by `sched_reserved_field`; self-healed post-reboot by `_sched_reconcile_reservations`.
  - Locking: `scheduler::with_lock` (flock on `${LLMCTL_RUNTIME_DIR}/.scheduler.lock`) wraps start/stop/auto/enable/switch.

---

## 4. Download + verify + smoke-test pipeline (`lib/download.sh`)

- Entry: `download_profile <profile>` (CLI: `llmctl models download`), `verify_profile <profile>`.
- Per-file loop over `catalog_files` ("name|size|sha256|role") → `_dl_download_file`:
  1. `_dl_resolve_sha` — catalog sha256, else `_dl_fetch_sha256_from_api` (`GET $LLMCTL_HF_BASE/api/models/<repo>?blobs=true`, takes `lfs.sha256`, or `blobId` prefixed `gitblob1:` for non-LFS config files). Hard-fail if none.
  2. Skip if existing file passes `_dl_verify_file` (size + checksum; `gitblob1:` uses `llmctl_git_blob_sha1` = `git hash-object --no-filters`).
  3. `curl -fL --continue-at - --retry 3` into `<file>.part` (exit 33 = no Range support → discard .part, full re-download); verify `.part` BEFORE atomic `mv -f` into place. Mismatch never lands at final path.
- **Smoke test** `_dl_smoke_test_gguf` (llama engine): launches real `llama-server --model <m> --ctx-size 512 --n-gpu-layers 0 --host 127.0.0.1 --port $LLMCTL_SMOKE_PORT (18090)`, polls `/health` up to `$LLMCTL_SMOKE_TIMEOUT` (120s), then POSTs `/v1/chat/completions` with payload:
  ```json
  {"messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":64,"temperature":0}
  ```
  Pass requires parsed `choices[0].message.content` containing `OK` **and** `finish_reason == "stop"` (never a raw-body grep). Disabled via `LLMCTL_SMOKE=0`; skipped (warn) if llama-server not built.
- colibri engine: `_dl_validate_colibri` — `coli doctor` (`COLI_MODEL=<dir>`), else structural check (≥1 non-empty `.safetensors` + `config*.json`).
- **Evidence logs:** every step appends `RUN/EXIT/OUT` lines to `${LLMCTL_VERIFY_DIR}/<profile>.log` (default `~/.local/state/llmctl/verify/`) via `_dl_log`/`_dl_evidence_run`; smoke server output → `${LLMCTL_LOG_DIR}/smoke-<profile>.log`.
- Download URL base overridable via `LLMCTL_HF_BASE` (test seam). `LLMCTL_DRY_RUN=1` prints instead of downloading.

---

## 5. Planner: `llmctl hw` and `llmctl plan`

- `llmctl hw [--json]` → `hw_probe_json` / `hw_probe_human` (lib/hardware.sh). Probe reads `/proc`, `sysctl`, `nvidia-smi` (memory.total+memory.free), `rocm-smi`/amdgpu sysfs, Apple unified memory (0.7×RAM), `df`+rotational flag for storage type. `LLMCTL_FAKE_HW=<file.json>` returns a fixture verbatim (validity-checked).
- `llmctl plan [--json]` → `hw_probe_json | catalog_plan_json [| catalog_plan_human]` (bin/llmctl case `plan`).
- **Tier classification** — `catalog_classify_tier()` in lib/catalog.sh (single source of truth, called by `catalog_plan_json`), verbatim thresholds:
  ```python
  if cores >= 32 and ram >= 98304 and free >= 409600:
      print("datacenter")
  elif cores >= 24 or ram >= 65536 or vram >= 20480:
      print("workstation")
  elif cores >= 8 and ram >= 32768:
      print("baseline")
  else:
      print("below-minimum")
  ```
  (ram/free in MiB; free = storage free at models dir; vram = total VRAM.) Rank map: below-minimum 0, baseline 1, workstation 2, datacenter 3 (`catalog_tier_rank`).

---

## 6. Test harness

- Runner: `tests/run_tests.sh`, invoked by `make test`. **Custom bash harness, NOT bats.** It loops `tests/test_*.sh`, runs each as a real subprocess, prints exact command + raw output + exit code, builds a PASS/FAIL summary from actual exit codes, exits 1 on any failure.
- Shared helpers: `tests/helpers.sh` — `test_setup_env` (mktemp-isolated LLMCTL_* state dirs, `NO_COLOR=1`, `LLMCTL_READY_TIMEOUT=0`), `assert_eq/assert_contains/assert_file_contains/assert_rc/assert_file_exists/assert_file_absent/assert_skip`, `test_finish`, plus `llmctld_build`/`llmctld_bootstrap` for Go-daemon tests.
- Determinism seams: `LLMCTL_FAKE_HW` (fixtures `tests/fixtures/hw-*.json`: baseline, workstation, apple, constrained, cpu-heavy, tiny, small-exact, vram-contended, vram-contended-coresident, ram-contended-auto-eviction), `LLMCTL_DRY_RUN=1`, `LLMCTL_HF_BASE` pointed at a local `python3 -m http.server` (see `tests/test_download.sh`; also `tests/fixtures/range_server.py` for Range-request resume tests), fake systemctl fixtures in scheduler tests, `tests/fixtures/agent_output/*` for normalize tests.
- Representative test (verbatim excerpt, `tests/test_download.sh` core section):
  ```bash
  # --- 1. fresh download + verify ----------------------------------------------
  LLMCTL_CATALOG="$(make_catalog "${SHA}")"
  export LLMCTL_CATALOG
  out="$(download_profile toy 2>&1)" && rc=0 || rc=$?
  assert_eq 0 "${rc}" "download_profile toy exit code"
  printf '%s\n' "${out}" | sed 's/^/  /'
  assert_file_exists "${LLMCTL_MODELS_DIR}/toy/model.bin" "model.bin exists after download"
  assert_eq "${SHA}" "$(llmctl_sha256 "${LLMCTL_MODELS_DIR}/toy/model.bin")" "downloaded file sha256 matches"
  assert_file_contains "${LLMCTL_VERIFY_DIR}/toy.log" "RUN: _dl_verify_file" "evidence log records verification"
  assert_file_contains "${LLMCTL_VERIFY_DIR}/toy.log" "EXIT: 0" "evidence log records exit code"
  ```
  (Test convention: `source helpers.sh` → `test_setup_env` → assertions → `test_finish`. Its `make_catalog` helper shows a minimal valid toy catalog with `LLMCTL_CATALOG` override — the exact pattern to reuse for testing a new profile type.)
- Every new lib file also gets a generated doc under `docs/scripts/<name>.md` and a matching `tests/test_*.sh` + `docs/scripts/test_<name>.md` (see §7 no-orphan rule).

---

## 7. Docs conventions & Constitution

docs/ files: `architecture.md, api-reference.md, quickstart.md, tutorial.md, user-manual.md, faq.md,
hardware-tiers.md, integrations.md, validation.md, validation_and_verification.md, release-process.md,
commit-fully-integration.md, cluster-architecture.md, CONTINUATION.md (huge running state log),
llmctl_plan.md, llmctl_progress_status.md, llmctl_initial_request.md`, plus subdirs:
- `docs/scripts/` — one auto-generated doc per script/test (catalog.md, scheduler.md, download.md, hardware.md, engine.md, common.md, doctor.md, cluster.md, helpers.md, install.md, os_detect.md, service_linux.md, service_macos.md, run_tests.md, test_*.md, install_*/normalize_*.md, preflight_submodules.md, build_archive.md, create_release.md, test_archive_completeness.md, llmctl.md, lib_normalize_common.md)
- `docs/integrations/` — install/normalize scripts per coding agent
- `docs/qa/` — per-feature evidence logs (005..008, phase12-final-validation)
- `docs/testing/` — BENCHMARK_BASELINE.md, TEST_TYPE_CLASSIFICATION.md, bench_runs/

**No-orphan-docs rule** (Constitution §IX): "README.md is canonical entry point — all docs reachable/linked from main README (no orphan docs)". Also: generated docs must be regenerated from source-of-truth in the same commit; CONTINUATION.md kept in sync with every non-trivial state change (§12.10); CHANGELOG.md updated with conventional-commit prefixes (§X).

**Constitution** = `.specify/memory/constitution.md` (llmctl Constitution v2.0.0) inheriting `constitution/Constitution.md` (Helix Universal Constitution, a git submodule — never weaken it). Most binding rules for a contributor adding profiles:
1. **Deterministic validation (§I, NON-NEGOTIABLE):** every behavior claim needs command + exit code + raw output in test-harness output or per-profile evidence logs. "Absence-of-error" PASS is a defect.
2. **Test-first / anti-bluff (§III, NON-NEGOTIABLE):** TDD red-green-refactor; four-layer coverage per change (pre-build syntax/schema gate, post-build gate, runtime test with captured evidence, paired mutation meta-test).
3. **No guessing (§11.4.6):** forbidden words `likely/probably/maybe/might/appears/seems` in reports; use captured evidence or `UNCONFIRMED:`.
4. **Real environment (§IV):** no harness-level mocking — real subprocesses, real exit codes; fixtures only for hardware/download determinism. SKIP-with-reason allowed, silent skip or fabricated PASS forbidden (§11.4.3, enforced via `assert_skip`).
5. **Safety (§VI/§VII):** credentials never tracked; 60% max host RAM usage; abort on failed pre-flight; bounded loops.
6. **Docs (§IX)** and **changelog (§X)** discipline above.
7. Deployment gates: `make test`, `make lint` (shellcheck -S warning), `make validate` (adds `python3 -m json.tool`-style catalog check via `make json-check`), constitution harness + meta-test, docs in sync.

---

## 8. Interactive (prompt-the-user) patterns

**None.** Grep of bin/llmctl + lib/*.sh finds no `read`-based prompting of any kind. The CLI is strictly non-interactive: all configuration flows through positional args, flags, and opt-in env vars (`LLMCTL_*`, `COLI_*`) following a consistent `${VAR:-default}` convention documented in each lib's header comment (e.g. `LLMCTL_PORT_<PROFILE>`, `LLMCTX_CTX_<PROFILE>`, `LLMCTL_KVTYPE_<PROFILE>`, `LLMCTL_BIND_HOST[_<PROFILE>]`, `LLMCTL_DRY_RUN`, `LLMCTL_FAKE_HW`, `LLMCTL_SMOKE`, `LLMCTL_HF_BASE`, `LLMCTL_SEED`, `LLMCTL_SLOT_SAVE_PATH`). Any new "ask the user" UX would be a new pattern; the established alternative is an explicit subcommand + env-var overrides.

---

## 9. Language split: Bash vs Go; what llmctld is

- **Bash (the product's single-host core):** bin/llmctl + all lib/*.sh + tests + scripts/install.sh + scripts/release/*.sh + docs/integrations/*.sh. Portable bash ≥3.2 (Linux + macOS); python3 used only as a JSON engine via `json_query`/`json_stdin`/`json_body`.
- **Go (`llmctld/`):** the opt-in cluster daemon — HTTP/3+HTTP/2 API (`internal/api`, routes for models/cluster/tenants/auth/mtls/replication/audit), Raft consensus (`internal/raft`), auth (JWT/OIDC/API keys/RBAC), multi-tenancy + quotas, cgroup isolation, mTLS, KV-cache replication, local executor. Entry: `llmctld/cmd/llmctld/main.go` (has `cluster bootstrap` subcommand; tests use `llmctld_bootstrap` in helpers.sh). Built/tested via `make llmctld-build/llmctld-test` or `make validate LLMCTL_CLUSTER_MODE=1`.
- **Relationship:** single-host llmctl never depends on llmctld. When cluster mode is used, `lib/cluster.sh` is the only client path and **hard-fails** when the daemon is unreachable (never silently falls back to single-host scheduling). Cluster commands: `llmctl cluster/tenant/apikey …` → `cluster::request` to `LLMCTL_CLUSTER_ENDPOINT` (default `https://127.0.0.1:9443`) with `LLMCTL_CLUSTER_TOKEN` bearer.

---

## Quick checklist for adding a "decision model" profile

1. Add entry to `models/catalog.json` `profiles` + `ports` (choose unused port; unique-port contract test).
2. If a new capability word: extend `sched_rank_for_capability()` (lib/scheduler.sh) — else `llmctl auto` can't rank it.
3. If a new engine value: extend `sched_build_launch` case (scheduler.sh), `download_profile` validation case (download.sh), `_dl_validate_*` as needed.
4. Extend `tests/test_planner.sh` expectations (recommended sets per fixture may change!) and `tests/test_catalog_json.sh` if schema grows; add hw fixture if new hardware shape matters.
5. Update docs: README port map/profile list, `.specify/memory/constitution.md` appendix port map, `docs/architecture.md`, `docs/hardware-tiers.md`, CHANGELOG.md, CONTINUATION.md — same commit (no orphan docs / sync mandates).
6. Run `make validate` (json-check + shellcheck + full harness). Real sha256+size from HF API `?blobs=true`; live-verified ctx/kv_cache_type claims in `desc` per project convention.
