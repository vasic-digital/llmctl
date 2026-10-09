# G-013 design: `llmctl admit <repo> --real-run` (G9 live sweep + G10 real-run executor)

| Field | Value |
|---|---|
| Date (UTC) | 2026-10-09 |
| Status | DESIGN ONLY (read-only assessment; nothing implemented, no code or catalog edited) |
| Gap | G-013 (`evidence/gaps-register.md` row 19): "no real-run executor; G10 PENDING for 13 candidates; G9 not live; non-HF names not probed" -> T094 + T091b |
| Inputs read | `lib/admit.sh`, `docs/scripts/admit.md`, `tests/test_admit.sh`, `evidence/admission/{SUMMARY.md,candidates.tsv,paper-checks-2026-10-09.md,byo-encoder/README.md}`, `evidence/live/run_live.sh`, `evidence/live-models/INDEX.md` + nezha runner (`launch.sh`, `watchdog.sh`), `lib/scheduler.sh` (`_sched_start_impl`), `scripts/golden/run_golden.py`, `docs/golden-set.md`, `scripts/hostsafety/bounded-run`, spec FR-007/FR-008/FR-085/SC-003, research RD-10/RD-11 |
| Labels | VERIFIED = read in this tree today; UNCONFIRMED = not checked or not knowable from here |

## 1. What G9 and G10 require (quoted)

Gate definitions (`research/web-candidate-models.md` section 4 via RD-10, `lib/admit.sh` header, `docs/scripts/admit.md`):

* RD-10: "Admission gate G1-G10 (... known-issues sweep, real run on this host ...)". Data model: "A verdict of `ADMITTED` requires G10 evidence from a real run on this host." (`data-model.md:129`)
* **G9** `known-issue sweep`: "register column `block:` (FAIL), `none-verified:` (PASS, attested live sweep), `note:` or empty (PENDING: tracker not queried by the driver)". Today the driver never queries anything (`lib/admit.sh` G9 block); 39 of 48 records are G9-PENDING, 13 ADMIT-CANDIDATEs carry only `note:`/empty.
* **G10** `real run`: "loadability, smoke answer, determinism repeats, option-order sensitivity, measured memory (`g10_subchecks`)"; failure = "executor reports failure (or a PASS with a non-PASS sub-check)". Driver rule: G10 is attempted "only for an ADMIT-CANDIDATE and only when not `--paper-only` and `LLMCTL_ADMIT_REAL_RUN` names an executable"; otherwise PENDING, "never a fabricated PASS". Executor contract today: called `<exe> <repo> <record.json>`, prints one JSON object `{"status","evidence","subchecks":[{check,status,evidence}...]}`; the driver re-evaluates it and demotes a PASS with a non-PASS sub-check.
* **FR-007**: "Each candidate that fully passes the admission gate (permitted licence, verifiable source and checksum, supported format and runtime, and a real run on this host that meets the same evidence bar as the six candidate profiles) MUST be added to the shipped catalog in this release; no candidate may be added that has not passed every check, and the release scope therefore follows the evidence."
* **FR-085**: models needing the newer engine are admitted "only after that gate passes and their real run succeeds".
* **SC-003** (the "same evidence bar"): 100% of the golden set (>= 30 questions across the three types) yields a well-formed typed answer from the real model; accuracy published with sample size, confidence interval and the trivial baseline from the same tool; a profile whose Wilson lower bound does not exceed the baseline "is not shipped, or ships labelled experimental with its measured numbers"; no ECE claimed under 200 labelled items.
* Constitution anchors that bind the executor: SS11.4.5/.69 (captured sink-side evidence), SS11.4.201 (guards assert the real condition; false positives are FAIL-bluffs), SS11.4.273 (control-needle every decision-bearing census), SS11.4.270 (existence verdicts), host safety SS12 / `docs/host-safety.md` (bounded-run, PSI watchdog).

Open point that the text does NOT settle (UNCONFIRMED, needs an operator decision, see section 10): there is no numeric pass threshold for "option-order sensitivity" (flip rate) and none for "memory fit" beyond G5's budget; SC-003 explicitly allows a below-baseline model to ship as `experimental`, so accuracy must NOT be a G10 pass/fail criterion, only a recorded `maturity`.

## 2. Findings that shape the design (from reading the tree)

1. **The seam exists, the executor does not.** `lib/admit.sh` already calls `LLMCTL_ADMIT_REAL_RUN <repo> <record.json>` and second-pass-evaluates the JSON. `--real-run` is therefore thin CLI sugar plus a real script; the gate logic need not be rewritten.
2. **Eight of the 13 ADMIT-CANDIDATEs have no catalog profile** (Mapika/decider-2b, APUS-OpenJev-4B, Julia-1, Kev-0.8B/4B/9B, Laya, lev - the table in SUMMARY.md `pinned=no`; note tasks T094 says "decide-2b is in models/catalog.json", UNCONFIRMED whether that is the same artifact as `Mapika/decider-2b-GGUF`, `candidates.tsv` maps `decide-2b+max` to `alibiserikbay/JevK5-GGUF`). The other five (`decide-tiny`, `decide`, `decide-pro`, `decide-nli`, JevK5 `decide-2b`/`decide-max`) are catalogued. The scheduler/downloader only know catalog profiles, so the executor must synthesize an **overlay catalog** (`LLMCTL_CATALOG`) from the admission record. That seam is proven: `evidence/byo-encoder/README.md` ("The overlay seam itself (`LLMCTL_CATALOG`) needed no code change"; a copied profile MUST have a unique port in both `profiles.<n>.port` and top-level `ports`).
3. **"Start through the scheduler in a scratch state" is only partly achievable on Linux.** Same README, Finding 1: `llmctl start/enable` cannot be isolated with a scratch `LLMCTL_STATE_DIR` because the systemd user unit template hard-codes `EnvironmentFile=<real state>/services/%i.env`; the unit fails (`Result: resources`) and restart-loops. The proven workaround: `LLMCTL_DRY_RUN=1 llmctl start <profile>` writes the env file/argv the scheduler would use, and the engine is launched with exactly that argv under `bounded-run`. So the executor uses the scheduler for **admission and argv generation** (numbers, mode, ctx, ngl, port allocation via the registry), but the service-manager leg (unit MemoryHigh/Max, Restart=always) is NOT exercised by G10. That leg is covered by the persistent-services evidence, not by admission; the design states this limit in every record (`service_manager_exercised:false`).
4. **The live-run recipe already exists**, as an unparameterized script: `evidence/live/run_live.sh` (verify -> start -> health -> smoke -> CLI ask -> golden questions + probes through the HTTPS gateway -> 8x determinism -> memory samples -> edge cases -> manifest) and the nezha runner (`launch.sh` pre-start PSI/swap refusal, `watchdog.sh` PSI-full>=10 or swap-free<30% aborts the scope, `systemd-run --scope -p MemoryMax=... timeout T`). The executor is a refactor of these into one tested script, not new research.
5. **Provenance is the recurring weakness** of the existing live evidence: `live-models/INDEX.md` marks most runs "mid-dev / unpinned" (uncommitted trees, no recorded binary). The current working tree is dirty (git status shows ~35 modified files). The executor must record tree identity and refuse to produce a ship-grade PASS from an unrecorded tree.
6. **The host that answered most questions (anton) is not the factory**: `nvidia-smi` here reports RTX 3060, 12288 MiB; `anton-decide-max-not-exercised` shows the 10G bounded-run cap and ~23 GB MemAvailable were the limit. The factory (RTX 5090 32 GB, 251 GiB per the task) is not reachable from this session: auto-memory says "ask for SSH user for 10.6.100.221", so the user is UNCONFIRMED.

## 3. CLI surface

```
llmctl admit <repo> --real-run [--host H] [--cap-mem 12G] [--wall 5400] [--allow-dirty]
                     [--evidence-out DIR] [--no-gateway] [--g9-only | --g10-only] [--offline]
llmctl admit --all --real-run [--host H]          # sequential, one model at a time, candidates in section 9 order
```

* `--real-run` = `mode=full` (already exists) + `LLMCTL_ADMIT_REAL_RUN=$LLMCTL_ROOT/scripts/admit/real_run.sh` (exported by `cmd_admit` unless the operator already set it) + a pre-flight that prints what will be downloaded (names, sizes, sha256 from G3) and the bounded-run caps. Refuses to combine with `--paper-only`. `--g9-only` runs only the live issue sweep (no download); `--g10-only` is for re-runs.
* Exit codes unchanged (0 ADMITTED/ADMIT-CANDIDATE, 10 USER-ONLY, 11 REJECTED, 12 HOLD, 13 NOT-FOUND, 2 usage/runtime). New: executor infrastructure failure maps to G10 `FAIL` with evidence `executor error: ...` (existing behavior for a non-zero executor), never to a silent PENDING; a **refusal because the host is unsafe or too small** maps to G10 `PENDING` with reason (not FAIL - the model was not judged), which needs a new executor status `SKIP/PENDING` path (the driver already accepts PENDING/SKIP statuses from the executor JSON).
* `--host H`: see section 7.

## 4. The executor `scripts/admit/real_run.sh <repo> <record.json>`

Implemented as a bash driver (host-safety, process control) calling a Python helper `scripts/admit/real_run_eval.py` (JSON/stat logic), mirroring the `admit.sh`/`python3 -I` split. Stdout = exactly one JSON object (contract above) extended backward-compatibly (the driver ignores unknown keys today; it must additionally copy them into the record - small driver change T091b-2):

```json
{"status":"PASS|FAIL|PENDING|SKIP","evidence":"...",
 "subchecks":[{"check":"loadability|smoke_answer|determinism_repeats|option_order_sensitivity|memory_fit_measured","status":"...","evidence":"..."}],
 "run":{"id":"...","host":"...","hostname_gpu":"...","tree_commit":"...","tree_dirty":false,"tree_diff_sha256":null,
        "binary_sha256":"...","engine_build":"b11379","evidence_class":"real-model","service_manager_exercised":false,
        "dir":"specs/009-jev-decision-models/evidence/admission/real-run/<slug>-<UTC>/","manifest_sha256":"...",
        "maturity":"supported|experimental|unmeasured","golden":{"n":132,"well_formed":132,"limit_refusals":0,"acc":{...},"baseline":{...}}}}
```

### 4.1 Steps (each step's outcome is captured to the run dir; any step failing short-circuits with a recorded reason)

0. **Pre-flight (refuse, do not guess)**: record `git rev-parse HEAD`, `git status --porcelain` hash, `git diff` sha256; dirty tree -> `status=PENDING`, reason "tree not committed; use --allow-dirty to run as `provenance:dirty` (record is then NOT ship-grade)". Check `/proc/pressure/memory` full avg10 < 5 and swap free > 50% (the nezha `launch.sh` thresholds, VERIFIED present there; promote to a shared `scripts/hostsafety` function), no foreign engine running (`pgrep` replaced by `/proc/<pid>/cmdline` read, SS11.4.196(D)/.263), disk space for the pin + 2x, `MemAvailable` >= G5 estimate + 3 GB (evidence-based rule from the anton data: VmHWM ~ model + 3 GB; `anton-decide-max-not-exercised`). Any miss -> `PENDING` + numbers, never FAIL.
1. **Verified download**: write the overlay catalog (section 5), then `llmctl models download <profile>` under `bounded-run -m 4G` (network only); sha256 + size must equal the G3 pins from the record; a mismatch is `FAIL` for loadability with both hashes. Non-LFS aux files (G3 PENDING cases such as `decider_config.json`) get their sha256 computed here and written back as `computed_at_pin_time` evidence - this is also what lets G3 move from PENDING to PASS in the second-pass evaluation (driver change: accept `pins[].sha256_computed`).
2. **Plan/admission with numbers**: `llmctl plan --json` against the overlay -> record `fits/ram_mb/vram_mb/mode/ctx/ngl` and the scheduler's budgets. If the scheduler says it does not fit, record its refusal verbatim and return `PENDING` (host too small), not FAIL.
3. **Start**: `LLMCTL_DRY_RUN=1 llmctl start <profile>` (scratch `LLMCTL_STATE_DIR`/`LLMCTL_RUNTIME_DIR`/`LLMCTL_ENV_FILE`, port from the registry allocator, never the live 8095/8096/8104/8082) to obtain the exact argv + per-run engine key file (0600, never in argv/evidence); launch under `bounded-run -m <model+3G> -t 2000 -T <wall>` with the PSI watchdog (promote `watchdog.sh` into `scripts/hostsafety/` with its own test: it must be seen to fire, and a watchdog that died early - cf. `nezha-pinned-decide-2b-run0-watchdog-died` - fails the run closed). Wait for `/health` (or `portreg_health_path`) with a bound; capture `/proc/<pid>/cmdline` (key path redacted), `/proc/<pid>/maps` libs, engine `--version`.
4. **loadability**: engine ready within bound, sha256 of the file the process actually opened matches the pin (`/proc/<pid>/fd` readlink + the verified download), `engine_build` equals the pinned submodule `describe`; for `systemone-native` additionally `POST /v1/systemone` returns HTTP 200 on a 2-option request (G4 on paper -> real).
5. **smoke_answer**: the built-in `llmctl decide smoke --protocol <p> --options 2` and `--options 4` plus a 3-question `run_golden.py --limit 6 --types noul,choice` (the same smoke that found `decide` 1/3 `readout_failed`). PASS only if every answer is well-formed and typed; a typed 422 `readout_failed` is FAIL (a model/readout failure), a 422 `validation_failed` over `max_options` is a recorded limit refusal (G-160 semantics, `--max-options` passed from the overlay profile), not malformed.
6. **Gateway + golden set**: start `llmctl decide serve --foreground` bound to 127.0.0.1 on a scratch port with scratch certs/key (BYO demo recipe; the gateway default 8 s deadline is used - `LLMCTL_DECIDE_TIMEOUT` is NOT inflated, because `live-models/INDEX.md` shows 300 s runs are "not representative of the product default"; if the model needs more, record the deadline_exceeded count rather than hide it, and offer `--gw-timeout` as an explicit, recorded override). Then `run_golden.py --profile <p> --permute-groups --evidence-class real-model --max-options <n>` for `questions` and `--set probes`, `stats.py` on both.
7. **determinism_repeats**: 8 identical requests to engine and gateway (code lifted from `run_live.sh` section 5); PASS = 8/8 HTTP 200 and byte-identical bodies at the engine; the gateway body differs only in request-id fields (the live script already compares gateway bodies - normalise fields it documents; UNCONFIRMED which fields vary).
8. **option_order_sensitivity**: flip rate from the `--permute-groups` pass (`stats.py` already reports it). Record rate with Wilson interval; PASS criterion = measured on >= the choice items with `perm_group` and rate <= `LLMCTL_ADMIT_MAX_FLIP` (default UNCONFIRMED, operator decision section 10); until decided, status `PASS` requires only "measured and reported" and the record carries `threshold:"undecided"`; this is stated, not hidden (SS11.4.201(8): a metric not validated against the definition of done must not silently gate).
9. **memory_fit_measured**: peak `VmHWM`, cgroup `MemoryPeak`, VRAM via `nvidia-smi --query-compute-apps` for the engine pid (+ whole-GPU used), sampled idle / after golden / after probes (the `mem()` function in `run_live.sh`). PASS = peak <= G5 host budget (60% MemTotal, Constitution SS12.6) AND the measured peak is recorded next to the G5 ESTIMATE with the ratio (feeds G-159 RAM/VRAM overhead design; `est_memory_bytes` already in the record). Estimate-vs-measured error beyond a factor is a finding, not a FAIL.
10. **Teardown** (always, trap-based): stop gateway and engine by terminating the bounded-run scope (cgroup stop, never pid/pgid signalling - SS11.4.263), release the registry port, verify no listener remains on the scratch ports and the live ports are untouched, delete the scratch key/cert/env, keep the model cache only if `--keep-model`.
11. **Seal**: `tests/evidence/manifest.py build <run dir>` (MANIFEST.json + SHA256SUMS); `manifest_sha256` into the JSON; secret scan of the run dir for the engine/gateway key (a hit = FAIL-closed, run dir quarantined).

### 4.2 Verdict mapping

`status=PASS` only if all five sub-checks PASS **and** `evidence_class=real-model` **and** tree provenance is clean (or the record says `provenance:dirty` and the driver refuses to move such a record to ADMITTED: new driver rule, ADMITTED requires `run.tree_dirty==false`). Golden accuracy never fails G10; it sets `maturity` per SC-003 (`supported` iff Wilson lower bound of each family > its baseline for the type, else `experimental`, `unmeasured` if the set did not complete). A stand-in engine (tests) yields `evidence_class=stand-in`, which the driver treats as `FAIL` ("stand-in evidence cannot admit") unless `LLMCTL_ADMIT_ALLOW_STANDIN=1` (test-only) - this closes the PASS-bluff where the test fixture is mistaken for a real run (SS11.4.27).

## 5. Overlay profile synthesis (`scripts/admit/make_overlay.py`)

Inputs: the admission record (`pins[]` with sha256/size, `protocol.class`, `api.sha` as `hf_revision`, `tier`, `est_memory_bytes`, `candidate.name`), the base `models/catalog.json` (to copy engine defaults of the nearest same-protocol profile) and a free port.

* Output: a copy of the catalog with one added profile `admit-<slug>` (USER-ONLY, `min_tier: below-minimum`), `engine` = `llama` for GGUF / `onnx` for nli-onnx, `files` = pins, `decision.protocol` = record class, `decision.max_options` = 16 for the first run (UNCONFIRMED: G-160 notes decide-2b/max were lowered to 16 "on a different basis"; the golden set has 20-option items, so the first real run records limit refusals and the evidence feeds T064), `mass_threshold` copied from the nearest letter-logit profile and **recorded** (the `decide` profile fails at 0.5 on diffuse first-token mass, so a catalog threshold is part of the measured result, not a free parameter).
* If the candidate IS already catalogued (`pinned=yes` rows), the executor uses the shipped profile unchanged and records `profile_source:"catalog"`; running the shipped profile is the point (that is what would ship).
* Uniqueness: choose a port in a scratch range outside 8000-8199 live ports; write it in both `profiles.<n>.port` and `ports` (byo-encoder Finding 2).
* The overlay lives in the scratch dir and is copied into the evidence dir; it never touches `models/catalog.json` (G-013 is not allowed to ship a model; adding to the catalog is T094 and needs the PASS first - and `tests/test_catalog_json.sh` has a shipped-profile "pin evidence cross-check" that an overlay legitimately fails).

## 6. G9 - live known-issue sweep (outbound queries, safely)

Goal: replace "PENDING: tracker not queried" with a recorded, reproducible sweep that can only upgrade a candidate when it is demonstrably complete, and can only FAIL on a *known* blocking issue (no keyword-match auto-FAIL: an automatic FAIL from a text match would be a SS11.4.201(1) false-positive refusal).

**Sources (read-only, public)**

1. Engine tracker: `gh api -X GET search/issues -f q='repo:ggml-org/llama.cpp is:issue <arch-or-model-term>' -f per_page=30` and `gh api repos/ggml-org/llama.cpp/issues/<n>` for every number already in `candidates.tsv` (`#30073`, `#30064`). Terms: GGUF `architecture` from the record, repo name, `systemone`, `decision_type`. State/labels/`updated_at`/title only.
2. Model-repo discussions: HF `GET /api/models/<repo>/discussions` (UNCONFIRMED endpoint shape for public models; verify on first run, and treat 404/401 as "not available", never as "no issues"). Open discussions' titles only.
3. Upstream project tracker named in the model card, only if the card links a GitHub repo (parsed from the API's `cardData`/README link; UNCONFIRMED how many of the 13 do).
4. Non-HF names (GitHub/PyPI harnesses, candidates with `repo=-`): `gh api repos/<owner>/<repo>` and PyPI JSON `https://pypi.org/pypi/<name>/json` as **existence probes** (SS11.4.270) to turn their `UNVERIFIED` into `VERIFIED/AMBIGUOUS`; this is the "non-HF names not probed" half of G-013.

**Safety rules**

* Allow-list of hosts (`api.github.com`, `huggingface.co`, `pypi.org`) and only `GET`; implemented through `gh api` (uses the user's existing keyring login, VERIFIED present as `milos85vasic`; no token handled by llmctl code, nothing in argv/evidence) with `HF_TOKEN` NEVER forwarded to GitHub and the HF token still passed only via the curl `--config` pipe (existing `_admit_fetch` pattern).
* Rate limits: first call `gh api rate_limit`; search API budget is separate and small (UNCONFIRMED exact numbers for this account - read them from the response, do not assume); sleep/stop when `remaining < 5`; conditional requests with ETag cache under the scratch dir; hard cap on queries per candidate (e.g. 8) and per run; 403/429 with `Retry-After` honoured with a bound (existing 429 x3 logic).
* Issue text is untrusted data: store `number,title(<=200 chars),state,labels,updated_at,html_url` only; strip control characters; never `eval`/pass to a shell; never pass bodies to an LLM unreviewed (prompt-injection surface); titles are rendered in the record as data fields.
* **Offline / no auth / rate-limited**: `--offline` or any network failure => G9 stays `PENDING` with a machine reason (`offline`, `gh_unauthenticated`, `rate_limited`), the sweep file records which queries could not run. Never PASS on a failed query; never FAIL on a failed query.
* **Control needle (SS11.4.273)**: every sweep includes a positive control (re-fetch issue `#30073`, which the register knows exists, and require it to be returned by the *same* search path) and a negative control (a fabricated impossible term must return zero). If the positive control is not found the instrument is blind and G9 = `PENDING instrument_blind`, not "no issues".
* Privacy: queries reveal candidate names to GitHub/HF only; they are public repos. No local paths, hostnames or state text are ever sent.

**Verdict rule (deterministic, conservative)**

* `FAIL` (-> HOLD): a register `block:` issue is still `open` at sweep time, or a newly found open issue carries a label/title matched by an operator-maintained deny pattern file (`evidence/admission/g9-blocking-patterns.tsv`, starts empty). If a `block:` issue is now closed, the record says so and the row needs a human to flip the register (the sweep proposes, it does not edit `candidates.tsv`).
* `PASS`: all sources reachable, controls passed, and **zero** open matches, OR every open match is listed in an operator-reviewed `g9-triaged.tsv` as non-blocking (`issue,repo,reviewed_by,date,reason`) - attested triage is how today's `none-verified:` text is produced; the sweep makes it reproducible.
* `PENDING`: any open match not yet triaged (the llama.cpp #30073 note-class issue lands here until a human triages it), or any source unreachable.
This means the sweep will not by itself turn the 6 `systemone-native` candidates G9-PASS (they all carry the open #30073 note); that is correct behavior, it needs a one-line triage entry whose truth depends on the G10 `-b`/ubatch result (the executor passes a prompt longer than 512 tokens through the engine; UNCONFIRMED whether the catalog already sets `-b >= prompt length`).

Output: `evidence/admission/g9-sweeps/<slug>-<UTC>.json` (queries, counts, controls, rate-limit snapshot) + the gate evidence line. Driver change: `_admit_eval` reads an optional `g9_sweep.json` (env `LLMCTL_ADMIT_G9_SWEEP`/default dir) when `known_issue` is not a hard `block:`/`none-verified:`.

## 7. Composing with host safety and with `--host H`

* Every engine, gateway and the executor itself run inside `bounded-run` (`-m` = model + 3 GB, `-t 2000`, `-T` wall, disk `TMPDIR`, no `/tmp`), so the 2026-10-08 host-hang cannot recur from admission; the memory-pressure guard (ships in DRY-RUN, VERIFIED in CHANGELOG) is untouched. One model at a time per host (also required by single-resource-owner partitioning of the GPU).
* Containment is by cgroup scope stop only, never `kill`/pgid (SS11.4.263: `bounded-run` header documents this; the executor must not add `kill` calls - a gate: `grep -n 'kill ' scripts/admit/*` must be empty or whitelisted).
* The PSI watchdog is a precondition, not an option: it is started *before* the engine and the run FAILS CLOSED if the watchdog is not alive at teardown (the nezha run0 incident). Add a hostsafety test where a synthetic PSI value above the threshold stops a sleeping scope.
* No GPU contention: refuse if another process holds > a configured share of VRAM, so mixed workloads do not contaminate the latency/memory evidence.
* `--host H`: run the *same* executor on H over SSH, never a different code path. Procedure: (1) require H to have the repo at the **same commit** (`ssh H git -C <repo> rev-parse HEAD` equality, else refuse), the pinned llama.cpp build with the recorded `engine_build`, `bounded-run` installed, and a venv for ONNX; (2) `ssh H bounded-run ... llmctl admit <repo> --real-run --json --no-write --evidence-out <dir>` with the record piped via stdin (not argv); (3) `scp` the run dir back, verify `SHA256SUMS` locally, re-seal into the local evidence tree with `host` recorded; (4) no keys or tokens cross the wire; `HF_TOKEN` stays local unless the operator names it. Auth: key-based SSH only (OD-26 context in the register; password handling excluded by G-024). **Blocked for the factory host: SSH user for 10.6.100.221 is UNCONFIRMED (auto-memory: ask)**; `nezha` is a different machine and must not be mistaken for it.

## 8. Failure modes and the intended record

| Failure | Detected by | Record |
|---|---|---|
| Dirty/unrecorded tree | pre-flight | `PENDING` or `provenance:dirty`, never ADMITTED |
| Host too small/pressured | pre-flight, scheduler `fits` | `PENDING` + numbers |
| Download mismatch / truncated | sha256+size vs G3 pin | loadability `FAIL` with both hashes; file quarantined |
| Engine won't load / arch missing in build | `/health` bound, engine log tail (redacted) | loadability `FAIL` |
| `readout_failed` (diffuse first-token mass, e.g. `decide`) | smoke / golden | smoke `FAIL`; recorded as model result, not wiring (INDEX.md / anton-decide README precedent) |
| Limit refusals (>max_options) | `--max-options` | counted separately, not malformed |
| Gateway deadline_exceeded at default 8 s | golden log | counted; maturity limited; override must be explicit and recorded |
| Non-determinism | 8x repeat | determinism `FAIL` with distinct-hash count |
| OOM / cgroup kill / watchdog abort | exit 124/9, MemoryPeak | G10 `FAIL` (or `PENDING` if the abort was host pressure from others) with the abort reason |
| Network loss during download | curl rc | `PENDING`, resumable download |
| Key leakage | post-run scan | run quarantined, `FAIL` |
| Port collision with live services | registry allocator + bind test | refuse before starting |
| Interrupted run (Ctrl-C, SSH drop) | trap + scope stop | partial dir marked `INCOMPLETE`, never summarised as a result |
| Executor emits PASS but a sub-check isn't | existing driver rule | demoted to FAIL (kept) |

## 9. Which candidates first (factory host: RTX 5090 32 GB, 251 GiB RAM; sizes from `paper-checks-2026-10-09.md`)

Order is by (information gained) / (risk), pipeline shake-out first, then the ones with the most shipping value, with the expected negatives early so the FAIL path is exercised by real data:

| # | Candidate (profile) | Size | Why here | Prior evidence (INDEX.md) |
|---|---|---|---|---|
| 1 | ggml-org/Julia-1-GGUF (decide-julia) | 0.17 GB | tiniest, native, fast; validates the whole executor | anton 132/132 well-formed, none beats baseline -> expect `experimental` |
| 2 | ggml-org/Laya-GGUF | 0.45 GB | native, small | anton valid |
| 3 | ggml-org/Kev-0.8B-GGUF | 0.81 GB | native; first G9 #30073 interaction | anton valid |
| 4 | ggml-org/lev-GGUF | 3.01 GB | best-looking native (choice 0.976) | anton + nezha valid |
| 5 | ggml-org/Kev-4B-GGUF | 3.03 GB | choice 1.000 | anton + nezha valid |
| 6 | Mapika/decider-2b-GGUF (letter-logit) | 1.27 GB | new letter-logit, needs T094 catalog work | none for this exact repo (UNCONFIRMED) |
| 7 | apus-ailab/APUS-OpenJev-v1-4B-GGUF (letter-logit) | 4.48 GB | T094 other half; not in catalog | none |
| 8 | ggml-org/Kev-9B-GGUF | 6.36 GB | anton could not start it (NOT-STARTED); fits the 5090 comfortably | nezha valid (score 0.710) |
| 9 | rizzoaiacademy/rizzo-flow (decide-pro) | 4.38 GB | catalogued; default-8 s control showed 45 x 502 | nezha valid, anton valid |
| 10 | alibiserikbay/JevK5-GGUF (decide-2b + decide-max) | 9.53 GB (2 pins) | decide-max has no anton result (G-158); 5090 resolves it | nezha valid |
| 11 | MoritzLaurer/deberta-v3-large-zeroshot-v2.0 (decide-nli) | 1.74 GB | ONNX path (needs the hash-locked venv) | valid, weak accuracy |
| 12 | chaoliangUNSW/Jev-Style-0.8B-Decision-v3 (decide-tiny) | 0.53 GB | known mis-catalogued as letter-logit (ROOTCAUSE.md) -> expected FAIL: gives a real negative | note only |
| 13 | Mapika/decider-4b-GGUF (decide) | 2.71 GB | known diffuse first-token mass, `readout_failed` -> expected FAIL | anton smoke 1/3, nezha 13/132 |

Rows 12-13 are the golden-bad cases for the *executor on real data*: a pipeline that cannot FAIL them is unvalidated (SS11.4.115(F)).

## 10. Test plan (RED first; stand-in engine for unit tests)

Principle: the executor's own correctness is proven offline with a **stand-in engine**, clearly labelled `evidence_class=stand-in`; real-model runs are separate evidence and are the only thing that can admit.

**Fixtures** (extend `tests/fixtures/admission/`): `standin_engine.py` - a stdlib HTTP server speaking `/health`, `POST /v1/systemone` (native contract) and a minimal llama-server-like `/v1/chat/completions` with `logprobs` for letter-logit, with fault switches via env: `MODE=ok|nondeterministic|order_flip|readout_fail|slow|crash_after_N|oom_sim|badjson|wrong_sha_file`; `standin_gh.py` - a local server for `LLMCTL_GH_API`/`GH_HOST` (mock `gh`: a shim script on `PATH` that returns fixture JSON and records its argv to prove GET-only and no token) with controls and rate-limit headers; a fake `models/` pin set small enough to hash.

**RED-first list** (each written and observed failing against a missing executor, then green; a paired mutation per gate):

1. `--real-run` without executor present -> usage error rc 2 (currently: no flag); `--real-run --paper-only` rejected.
2. Executor not executable / non-zero -> G10 FAIL (exists today; keep as regression).
3. Golden-good: stand-in `MODE=ok` -> all five sub-checks PASS **but disposition must NOT be ADMITTED** because `evidence_class=stand-in` (this is the key anti-bluff test); with `LLMCTL_ADMIT_ALLOW_STANDIN=1` -> G10 PASS, ADMITTED only if the paper gates pass.
4. Golden-bad per sub-check: `nondeterministic` -> determinism FAIL; `order_flip` -> sensitivity recorded and, with a threshold set, FAIL; `readout_fail` -> smoke FAIL; `crash_after_N` -> loadability/golden FAIL with scope stopped; sha mismatch fixture -> loadability FAIL before any start.
5. Mutation: executor reports PASS with one sub-check FAIL -> driver demotes (exists); executor omits a sub-check -> FAIL (exists).
6. Pre-flight refusals (inject PSI/swap/MemAvailable via env-pointed fake `/proc` files): each refusal is PENDING with numbers, none starts an engine (assert no listener, no scope created).
7. Teardown: after success, failure and a simulated SIGINT, no process, scope, listener, scratch key or scratch cert remains; live-port set unchanged; `grep` of the run dir for the generated key returns nothing (with a positive control that the key *was* in the engine environment).
8. Overlay: synthesized profile has unique port in both maps; catalog JSON valid; `llmctl models list` shows it; shipped `models/catalog.json` byte-identical afterwards.
9. G9: online fixture with controls -> PASS only with attested triage, PENDING with an untriaged open match, FAIL when a `block:` issue is still open; offline/403/429 -> PENDING with the right reason; blind-instrument case (positive control missing) -> PENDING; shim records only GET and no Authorization-bearing argv.
10. Watchdog test (hostsafety): synthetic PSI over threshold stops a sleeping scope; dead watchdog fails the run closed.
11. Provenance: dirty tree -> not ADMITTED; the record carries commit, diff hash, binary sha256.
12. `--host`: SSH replaced by a local shim; same-commit equality enforced; returned `SHA256SUMS` verified; tampered artifact rejected.
13. Constitution gates the repo already runs (`make test`, `make lint` shellcheck, `make validate`, `constitution/scripts/validation/run_verification.sh`, meta-test) stay green; `docs/scripts/admit.md`, a new `docs/scripts/admit_real_run.md`, `docs/decision-models.md` admission section, FAQ and the `llmctl help` text updated (project doc-sync rule); every new script gets its `docs/scripts/*.md`.

## 11. Effort estimate (tasks, agent-hours; real-run wall time excluded)

| Task | Content | Est. |
|---|---|---|
| T091b-1 | stand-in engine + gh/curl shims + RED tests (items 1-8, 11) | 5 h |
| T091b-2 | driver changes: `--real-run`, pass-through of `run` block, stand-in/dirty-tree rules, G3 `sha256_computed` | 3 h |
| T091b-3 | `real_run.sh` + helpers: pre-flight, overlay, download, start/teardown, smoke, golden (lift from `run_live.sh`), determinism, memory, seal | 10 h |
| T091b-4 | promote PSI watchdog + pre-start refusal into `scripts/hostsafety/` with tests (item 10) | 3 h |
| T091b-5 | G9 sweeper (`gh api`, controls, rate limit, triage file) + tests (item 9) + non-HF existence probes | 6 h |
| T091b-6 | `--host` remote mode + test (item 12) | 4 h |
| T091b-7 | docs (`admit.md`, new script docs, decision-models admission section, FAQ, SUMMARY generator reads real-run evidence) + review fixes | 4 h |
| T091b-8 | independent review + constitution/meta gates iterations | 4 h |
| T091c | real runs per candidate on anton (small ones) and factory (rest): each ~0.5-2 h wall incl. download, mostly unattended | 13 runs, ~15 h wall, ~4 h agent |
| T094 | catalog entries for Mapika decider-2b + APUS-4B after PASS (separate, depends on T091c) | 3 h |
| **Total** | build 39 h, runs ~4 h agent + ~15 h wall, T094 3 h | |

## 12. Can this be implemented autonomously?

**Yes for the tooling** (T091b-1..8): everything is deterministic, offline-testable with the stand-in engine, and touches only the repo; no operator input is needed. The gateway (Go `llmctl-decide`) is a real component in these tests; only the engine is a stand-in, labelled as such.

**Partially for real runs on this host (anton, RTX 3060 12 GB, ~23 GB available, 10G bounded-run cap used previously)**: Julia, Laya, Kev-0.8B, decider-2b, decide-tiny, decide-nli, lev, Kev-4B, decide (<= ~7 GB peak) are within reach; decide-pro/APUS-4B (peak ~7.4 GB observed for pro) probably; Kev-9B and JevK5 9.5 GB are not (previously refused/NOT-STARTED).

**Blocked / needs the operator:**
1. Factory host access: SSH user for 10.6.100.221 is UNCONFIRMED (auto-memory instruction: ask; `nezha` is not the factory). Needed for rows 8-10 and for the "RTX 5090" evidence.
2. Thresholds not defined by the spec: option-order flip-rate limit, `max_options` default for unseen models, `mass_threshold` for new letter-logit profiles, and how `maturity` maps to shipping (SC-003 allows `experimental`). These are SS11.4.66-style decisions; the design records "undecided" rather than inventing numbers.
3. Whether admission may run from a dirty tree (`--allow-dirty` is provenance-labelled only) - the working tree is currently dirty and should be committed and quiescent before any ship-grade run (also T124 requires it).
4. Triage entries for G9 (`g9-triaged.tsv`) are human/agent judgments about upstream issues (#30073 class); the sweeper cannot decide them.
5. Network/auth: `gh` login exists on this host (VERIFIED), but the exact search-API rate limit and the HF discussions endpoint behavior are UNCONFIRMED until first use.
6. macOS: out of scope (no Mac, G-009/G-124); the executor is Linux-only and says so.

**Not claimed by this document:** nothing was run, no candidate status changes, G-013 stays OPEN until T091b lands and the real-run records exist.
