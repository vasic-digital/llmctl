# Three-way merge plan: second team's candidate onto HEAD (FR-044)

**Created**: 2026-10-07 | **Status**: Draft (input to planning) | **Spec**: [../spec.md](../spec.md)
**Candidate**: `/home/milosvasic/Projects/jev/llmctl/llmctl` (no `.git`, VERSION 3.0.2)
**Real repo**: `/home/milosvasic/Projects/llmctl`, branch `main`, HEAD `a9ebefe` (2026-10-04)
**Inputs**: [jev-llmctl-inventory.tsv](jev-llmctl-inventory.tsv) (26 MODIFIED, 33 NEW-IN-JEV incl. 4 generated `__pycache__`/`.pyc`, 455 IDENTICAL, 5 SYMLINK)
**Method**: read-only. Nothing under the real repo or under `jev/` was modified. All merges and test runs were done in scratch clones under `/tmp/claude-1000/.../scratchpad/{wt,wt2,m}` (git clone `-s` of the real repo, so it cannot write back).

Facts below are measured in this session unless marked **INFERRED**.

## 1. Snapshot point (STEP 1)

**Result: the candidate was branched at `b09a79a` (2026-10-03, "docs(catalog): fix self-contradiction + wrong cancellation explanation (round-5 review)"). HEAD `a9ebefe` is exactly one commit later, and that one commit touches only the two `docs/qa/005-cuda-gpu-inference/*.txt` evidence files.** `b09a79a` and `a9ebefe` are otherwise tree-identical for every file the candidate carries, so the choice of base between them does not change any other file.

Evidence (all measured):

1. `git diff --name-only <X> HEAD` intersected with the 455 IDENTICAL files (candidate == HEAD) must be empty for X to be a valid snapshot (a file that changed after X but is byte-identical to HEAD proves the candidate is newer than X). Result:

   | X | files changed X..HEAD | IDENTICAL files among them (violators) |
   |---|---|---|
   | `a9ebefe` | 0 | 0 |
   | `b09a79a` | 2 (the two qa `.txt`) | 0 |
   | `48dbf5e` | 3 (+ `lib/catalog.sh`) | 0 |
   | `55ddbec` | 3 | 0 |
   | `7f65f76` | 3 | 0 |
   | `326c2c8` | 4 | **1** (`docs/qa/005.../ctx_kvtype_override_live_verification.txt`) |
   | `c2b3458` / `f094b2f` | 7 | 4 |
   | `d00757c` | 9 | 5 |
   | `54a9ca0` (constitution ff) | 16 | 8 |
   | `4dcecb3` | 32 | 21 |

   So the candidate is at or after `7f65f76`; it cannot be earlier.
2. `lib/catalog.sh` discriminates between `7f65f76`, `55ddbec`, `48dbf5e` and `b09a79a`. Line-diff counts (`diff <rev>:lib/catalog.sh candidate | grep -c '^[<>]'`): `7f65f76` 191, `55ddbec` 188, `48dbf5e` 132, `b09a79a` 104, `a9ebefe` 104. The minimum (104) is reached at `b09a79a`, and the HEAD-to-candidate diff has **zero `<` lines** in `lib/catalog.sh` beyond edits listed in section 3, i.e. the candidate already contains the round-3/4/5 review fixes (`55ddbec`, `48dbf5e`, `b09a79a`). It is not older than `b09a79a`.
3. Per-file closest revision (minimum of `diff <rev>:F candidate | grep -c '^[<>]'` over `git log --follow -- F`; ties resolved newest-first). In every one of the 26 files the minimum is reached at the **latest commit that touched the file**, and that count equals the HEAD-vs-candidate count, which is what "candidate = HEAD plus additions" looks like. `Δ` is the number of differing lines (HEAD `<` + candidate `>`), HEAD-removed = lines present at the base but changed/removed by the candidate:

   | File | Closest rev (last touch) | Δ lines | Notes |
   |---|---|---|---|
   | `.specify/memory/constitution.md` | `0718f5d` 2026-09-14 | 8 | additions only |
   | `CHANGELOG.md` | `d206466` 2026-09-22 | 68 | additions only |
   | `README.md` | `4dcecb3` 2026-09-22 | 42 | 7 HEAD lines edited |
   | `bin/llmctl` | `2874db7` 2026-10-03 | 14 | additions only |
   | `docs/CONTINUATION.md` | `0a0855f` 2026-09-18 | 126 | 2 header lines + 122 appended |
   | `docs/architecture.md` | `f094b2f` 2026-10-03 | 38 | 7 HEAD lines edited |
   | `docs/faq.md` | `f7cf4e5` | 145 | additions only |
   | `docs/hardware-tiers.md` | `4fead5f` | 62 | additions only |
   | `docs/qa/005.../throughput_ratio.txt` | `a9ebefe` | 2 | see section 4 (candidate is a test-run artefact) |
   | `docs/qa/005.../vram_delta.txt` | `a9ebefe` | 2 | same |
   | `docs/scripts/doctor.md` | `7f120cc` | 7 | additions only |
   | `docs/scripts/download.md` | `7f120cc` | 22 | 4 HEAD lines edited |
   | `docs/scripts/engine.md` | `1ada1cc` | 18 | 6 HEAD lines edited |
   | `docs/scripts/scheduler.md` | `4dcecb3` | 14 | 3 edited |
   | `docs/scripts/service_linux.md` | `7f120cc` | 6 | 2 edited |
   | `docs/user-manual.md` | `f7cf4e5` | 174 | 1 edited |
   | `lib/catalog.sh` | `b09a79a` | 104 | additions only |
   | `lib/doctor.sh` | `f7cf4e5` | 15 | additions only |
   | `lib/download.sh` | `e131b8d` | 296 | 2 HEAD lines replaced |
   | `lib/engine.sh` | `f7cf4e5` | 20 | 3 edited |
   | `lib/scheduler.sh` | `875f5e1` 2026-10-03 | 35 | 1 edited |
   | `lib/service_linux.sh` | `39a1f0e` 2026-10-03 | 26 | additions only |
   | `models/catalog.json` | `158bf17` 2026-10-03 | 187 | 1 edited |
   | `tests/test_catalog_json.sh` | `4fead5f` | 116 | 2 edited |
   | `tests/test_planner.sh` | `3926468` 2026-10-03 | 196 | 10 HEAD assertion lines rewritten |
   | `tests/test_scheduler.sh` | `d00757c` 2026-10-03 | 22 | additions only |

   Caveat (honest): "closest rev" by line count is a heuristic. The decisive evidence is item 1 (zero violators) and item 2.
4. Cross-check by 3-way merge: with `b09a79a` as base, HEAD hunks per file are **0** for 24 files and **1** for the two qa files (section 4); so base-to-HEAD changed nothing the candidate also touched, other than those two files.
5. Candidate omits submodule content and `constitution/` (as expected for an archive); the 24 files under `.specify/extensions/superspec/` and `.github` dotfiles that the inventory did not list are in HEAD and unaffected. No HEAD-tracked source file is missing from the candidate.

**Overall snapshot point: single commit `b09a79a`** (one commit exists; no per-file split is needed). The README claim "post-3.0.2 main snapshot" is consistent: VERSION is 3.0.2 in both trees; v3.0.2 was tagged 2026-09-22 and ~30 commits (2026-09-22 to 2026-10-03) sit between it and the snapshot, all of which the candidate contains.

## 2. Hunk classification (STEP 2)

Classes: **CANDIDATE-ONLY** (apply), **HEAD-ONLY** (keep; must not be lost), **BOTH-SAME**, **CONFLICT**.
Because base == HEAD for all but the two qa files, there are no HEAD-only text hunks in the 24 non-qa files. Counts below are `diff base candidate` hunks (a = pure addition, c = replaces existing HEAD lines).

Totals over the 24 non-qa files: **75 CANDIDATE-ONLY hunks (33 pure additions, 42 that replace existing HEAD lines), 0 HEAD-ONLY, 0 BOTH-SAME, 0 CONFLICT.** The two qa files: 1 HEAD-ONLY hunk each (HEAD changed them in `a9ebefe`) and 1 candidate hunk each, i.e. 2 textual CONFLICTS (`git merge-file` reported 1 each), resolved by discarding the candidate version (section 4).

| File | Hunks (a / c) | HEAD line ranges touched by candidate | HEAD-ONLY | Conflicts |
|---|---|---|---|---|
| `.specify/memory/constitution.md` | 2 (2/0) | after 215, after 227 | 0 | 0 |
| `CHANGELOG.md` | 1 (1/0) | after 25 (new "Unreleased" section) | 0 | 0 |
| `README.md` | 8 (3/5) | 9, 15, 72, 76, 99, 113, 125, 224 | 0 | 0 |
| `bin/llmctl` | 3 (3/0) | after 31, 76, 188 | 0 | 0 |
| `docs/CONTINUATION.md` | 2 (1/1) | 3-4 (Revision 21->22), after 1539 (+122 lines) | 0 | 0 |
| `docs/architecture.md` | 9 (5/4) | 3-4, 15, 19, 59, 86, 127-128, 155, 170, 189 | 0 | 0 |
| `docs/faq.md` | 1 (1/0) | after 468 | 0 | 0 |
| `docs/hardware-tiers.md` | 1 (1/0) | after 42 | 0 | 0 |
| `docs/qa/005-cuda-gpu-inference/throughput_ratio.txt` | 1 | whole file | **1** | **1** |
| `docs/qa/005-cuda-gpu-inference/vram_delta.txt` | 1 | whole file | **1** | **1** |
| `docs/scripts/doctor.md` | 1 (1/0) | after 159 | 0 | 0 |
| `docs/scripts/download.md` | 3 (0/3) | 203, 205-206, 225 | 0 | 0 |
| `docs/scripts/engine.md` | 4 (0/4) | 3-5, 52, 78, 123 | 0 | 0 |
| `docs/scripts/scheduler.md` | 3 (0/3) | 220, 238, 240 | 0 | 0 |
| `docs/scripts/service_linux.md` | 1 (0/1) | 6-7 | 0 | 0 |
| `docs/user-manual.md` | 5 (4/1) | 38, after 46, 243, 391, 544 | 0 | 0 |
| `lib/catalog.sh` | 4 (4/0) | after 469, 531, 536, 583 | 0 | 0 |
| `lib/doctor.sh` | 1 (1/0) | after 112 | 0 | 0 |
| `lib/download.sh` | 3 (2/1) | after 388 (+279 lines), 458-459 (replaced), after 463 | 0 | 0 |
| `lib/engine.sh` | 2 (0/2) | 144, 150-151 | 0 | 0 |
| `lib/scheduler.sh` | 3 (2/1) | after 47, after 397, 818 | 0 | 0 |
| `lib/service_linux.sh` | 1 (1/0) | after 183 | 0 | 0 |
| `models/catalog.json` | 2 (1/1) | 14 (ports map), after 1407 (+179 lines) | 0 | 0 |
| `tests/test_catalog_json.sh` | 3 (1/2) | 24, 26, after 71 | 0 | 0 |
| `tests/test_planner.sh` | 11 (1/10) | 29, 31, 37, 39, 44, 46, 49, 51, 56, 58, after 106 | 0 | 0 |
| `tests/test_scheduler.sh` | 1 (1/0) | after 345 | 0 | 0 |

### 2.1 CONFLICTs (precise)

Only two, both the qa evidence files:

| File | Lines | HEAD (`a9ebefe`) | Candidate | Resolution |
|---|---|---|---|---|
| `docs/qa/005-cuda-gpu-inference/throughput_ratio.txt` | 1 (whole file; base was 20 lines of real benchmark data from `55ddbec`) | `SKIPPED: model not downloaded for profile small: /home/milos/.local/share/llmctl/models/small/...` | `SKIPPED: nvidia-smi not present on this host` | **Keep HEAD. Discard the candidate file.** |
| `docs/qa/005-cuda-gpu-inference/vram_delta.txt` | 1 (whole file; base 9 lines) | same `SKIPPED: model not downloaded ...` | `SKIPPED: nvidia-smi not present on this host` | **Keep HEAD. Discard the candidate file.** |

### 2.2 HEAD-ONLY hunks that touch the same functions as candidate hunks (semantic-conflict risk)

**None.** There are no HEAD-only hunks in any file the candidate changes (apart from the two qa files, which no candidate code reads). The relevant HEAD features nearest to candidate edits, all of which are already inside the base the candidate was built on, and so are not lost:
- `lib/catalog.sh`: the per-profile ctx/kv-type override resolvers (`resolve_ctx`, `resolve_kv_type`, `kv_mb`; commits `875f5e1`, `55ddbec`, `48dbf5e`, `b09a79a`) are reused by the candidate's new onnx footprint branch and `decision_instances` block (candidate `lib/catalog.sh:470-483, 546-614`).
- `lib/scheduler.sh`: round-2/3/4 eviction-loop fixes (`f6febd8`, `39a1f0e`, `aa38ebb`) and `875f5e1` live around the candidate hunks (candidate `lib/scheduler.sh:48-56, 407-430, 851`) but are untouched by them.
- `lib/service_linux.sh`: the `39a1f0e` fix sits next to the new `llmctl-onnx@.service` template (candidate `lib/service_linux.sh:184-209`).

### 2.3 Stale-versus-HEAD verdicts requested

- `docs/qa/005-cuda-gpu-inference/throughput_ratio.txt` and `vram_delta.txt`: **candidate is NOT a stale older snapshot; it is a regenerated test-run artefact**, and HEAD must win. Cause is measured: `tests/test_gpu_throughput_ratio.sh:49-50` and `tests/test_gpu_vram_delta.sh:48-49` overwrite these files with `SKIPPED: nvidia-smi not present on this host` whenever the suite runs on a host with no GPU. The string "nvidia-smi not present" appears in **no** revision of either file in git history. HEAD (`a9ebefe`, RTX 5090 factory-host retest) is newer and is the evidence the project wants. Discard the candidate's versions. Note: the candidate's test run also means any other evidence file the suites rewrite should be re-checked after porting (none other differs in the inventory).
- `docs/CONTINUATION.md`: **not stale relative to HEAD** in the git sense: base == HEAD content, last touched `0a0855f` (2026-09-18, Revision 21). The candidate bumps Revision 21 -> 22 (`Last modified` 2026-10-06T00:00:00Z) and appends §10r (122 lines at HEAD line 1539). It merges cleanly. Caveats: (a) HEAD's CONTINUATION.md has not been updated since 2026-09-18 despite ~30 later commits, so the candidate's §10r would be the newest section while not describing those commits (**INFERRED**: documentation gap, not a merge defect); (b) §10r states the feature is "fully implemented and tested", which conflicts with the defect register (source-findings D-06, D-29) and the zero-real-model-evidence fact, so the text should be rewritten after the feature work, not applied verbatim. Recommendation: apply the diff mechanically in the scratch merge, then replace §10r with a post-implementation entry and set Revision/Last-modified at that time.

## 3. Real merge measurement (STEP 3, measured)

Procedure: for each of the 26 MODIFIED files, `git merge-file -p <HEAD:F> <b09a79a:F> <candidate F>` (base `b09a79a`), then the 29 non-generated NEW-IN-JEV files copied, applied to a clone of HEAD (`wt2`); baseline clone (`wt`) is untouched HEAD. `constitution/` was copied into both clones with its gitfile removed (the real repo's submodules are not initialised in a clone). HOME was redirected to an empty directory.

- 3-way conflicts: **24 of 26 files conflict-free, 2 conflicts (the qa files)**; 0 conflict markers in any other output.
- Scratch tree after applying (qa files left as HEAD): 24 modified files, 1,710 insertions, 51 deletions, plus the 29 new files.
- `bash tests/run_tests.sh`, baseline HEAD (38 test files): **36 PASS / 2 FAIL**. Merged tree (43 test files = 38 + 5 new): **41 PASS / 2 FAIL**. The same 2 fail in both and are environmental in this scratch setup, not merge effects: `test_constitution_inheritance.sh` ("Insufficient upstream remotes or constitution/ directory missing": the clone has one remote and no submodule gitdir) and `test_engine_cpu_regression.sh` ("linger is NOT confirmed enabled for milosvasic": host systemd linger, plus no `llama.cpp` submodule content in the clone). The five new suites (`test_decide.sh`, `test_decide_gateway.sh`, `test_decide_download.sh`, `test_onnx_server.sh`, `test_onnx_download.sh`) all PASS. Note: HEAD has **38** `tests/test_*.sh` files, not 41 as the brief states; 41 is the merged PASS count. `shellcheck` is not installed here, so `make lint` was **not** run (UNCONFIRMED).
- No function-name collisions across `lib/*.sh` and `bin/llmctl` after merge (the only duplicates are the pre-existing `svc_*` pairs, Linux vs macOS files, selected by OS).

## 4. Recommended apply order and method

Because base == HEAD, a text-level port is trivial; the work is review, defect remediation and evidence, not conflict resolution. Recommended order (each step on a scratch branch off `a9ebefe`, outside the main working tree, with independent review per constitution §11.4.142 before any commit):

1. **Re-verify the base immediately before applying.** `git rev-parse HEAD`; if HEAD has moved past `a9ebefe`, re-run section 1 item 1 for the new commits (any new commit touching one of the 24 files makes it a real 3-way merge).
2. **Generate the per-file patches from the base**, not from HEAD, to keep an audit trail:
   `git archive b09a79a <files> | tar -x -C /tmp/base`, then `git diff --no-index --binary /tmp/base/<F> <candidate>/<F>` per file, rewriting paths to `a/<F> b/<F>`.
3. **Apply with `git apply --3way`** (preferred over copying, so any future HEAD movement surfaces as a conflict). Expect zero conflicts today.
4. **Add the 29 new files verbatim** (list: NEW-IN-JEV in the inventory except the 4 `__pycache__`/`.pyc` generated files, which must never be imported or tracked, D-25): `lib/decide.sh`, `lib/decide_gateway.py`, `lib/onnx_server.py`, five `tests/test_*`, two `tests/fixtures/*.py`, the `docs/` set, `docs/qa/decision-models-validation/*` (after correction per source-findings Section C), `docs/research/*` (after Section D corrections).
5. **Do NOT import**: the two qa `.txt` files (HEAD wins), the `.pyc` files, `llmctl.tar.gz`/`.zip`.
6. **Order of semantic review (regression-sensitive first)**, one commit each: (a) `models/catalog.json` + `lib/catalog.sh` + `tests/test_planner.sh` + `tests/test_catalog_json.sh` (the planner behaviour change, SC-012); (b) `lib/scheduler.sh` + `tests/test_scheduler.sh`; (c) `lib/download.sh`; (d) `lib/service_linux.sh` + `lib/engine.sh` + `lib/doctor.sh`; (e) `bin/llmctl` + `lib/decide.sh` + gateway/runtime + new tests; (f) docs and CHANGELOG; (g) `.specify/memory/constitution.md` last (governance document, needs its own review and its amendment/version rules; **INFERRED** that the 8 added lines require a Revision decision, not checked).
7. **Gate on the full existing suite after each step** (`bash tests/run_tests.sh`, plus `make lint` where shellcheck exists, plus the constitution verification harness named in CLAUDE.md). Baseline to beat in a properly provisioned environment: all 38 existing files pass at HEAD (the 2 failures here are scratch-environment only).
8. Remediation of source-findings defects (D-01..D-31) is **separate work on top of the ported baseline**, so the port commits stay a faithful, reviewable image of the candidate.

## 5. Behaviour changes to existing code paths: regression risks for existing chat profiles (STEP 4)

Line numbers are in the **candidate** tree (`.../jev/llmctl/llmctl`); HEAD line = candidate line minus the preceding added lines in the same file.

| # | Risk | Where | What changes for existing users | Evidence |
|---|---|---|---|---|
| R1 | **Planner `recommended` set grows** (D-18, SC-012) | `models/catalog.json:1414-1592` (six `decide*` profiles, capability `["decide"]`, `min_tier` incl. new value `below-minimum`); `lib/catalog.sh:537` builds `recommended` unchanged | `llmctl plan` and `plan --json` now list 4 decision profiles on a baseline host, 6 on workstation/apple. Any consumer that treats `recommended` as "chat-capable" breaks. The candidate rewrote the existing HEAD assertions in `tests/test_planner.sh:29-35, 37, 43-49, 51-68, 73, 75, 78-85, 87, 92, 94` to match | measured: diff above; tests pass only because the expectations were rewritten |
| R2 | **Eviction-alternative suggestion can now name a decision profile** | `lib/scheduler.sh:590` iterates `d["recommended"]` (unchanged code) | when `llmctl start <chat profile>` is refused for budget, the "suggested alternative that fits now" is the first not-running recommended profile that fits; decide profiles are appended after chat ones in catalog order, so they surface only when no chat profile fits, but then the hint is `llmctl start decide-tiny` (not a chat model) | read from code; behaviour **INFERRED** from ordering (planner test shows insertion order) |
| R3 | **Co-residency groups change** | `lib/catalog.sh:508-530` bin-packing over `recommended`; `tests/test_planner.sh:51-68, 78-85` | group 2 on baseline now includes `decide-tiny decide decide-nli` and spills `decide-2b` into a new group 3; the workstation host gains a group 6 of five decide profiles. Existing group numbering and "none fits" output unchanged for chat profiles | measured via candidate test expectations |
| R4 | **`auto` ranking and error text** | `lib/scheduler.sh:56` new `decide)` arm (ladder `decide-tiny decide-nli decide-2b decide decide-pro decide-max`); `lib/scheduler.sh:851` usage now `chat|coder|vision|decide`; `auto chat/coder/vision` code path itself is untouched. D-24: line `scheduler.sh:870` text still says `(chat|coder|vision)` | `llmctl auto decide` is new; `_sched_auto_impl`'s unknown-capability error text at HEAD `scheduler.sh:837` is **not** updated | read from code |
| R5 | **`sched_build_launch` new engine arm** | `lib/scheduler.sh:407-430` (`onnx)` arm), uses `LLMCTL_DECIDE_API_KEY` at `:427-428` | adds an arm to the existing `case`; llama/colibri arms unchanged. Credential on argv (D-03) and variable-name conflict with clarification 1 (D-29, `LLMCTL_API_KEY`) | read from code; D-02/D-03/D-29 are open |
| R6 | **`llmctl build` semantics** | `lib/engine.sh:144-165`: `all` now also runs `engine_build_onnx`; `build onnx` accepted; error text now `llama|colibri|onnx|all` | `llmctl build` / `llmctl setup` (which calls build) now print onnx notes; any script that asserts the exact output of `build all` or the old error string would change. `README.md:72` and usage text updated to match | measured: diff; `test_engine.sh` still passes |
| R7 | **`llmctl doctor` gains 2 WARN lines** | `lib/doctor.sh:113-127` (`onnxruntime`, `sentencepiece` import probes via `python3`) | WARN, not FAIL, so exit code unchanged; output differs on hosts lacking the packages (most) and doctor now depends on `python3` being callable (it already is used elsewhere, **INFERRED**) | read from code |
| R8 | **`llmctl download` smoke dispatch changed for ALL llama profiles** | `lib/download.sh:737-747`: the single `_dl_smoke_test_gguf` call became an `if capability contains decide` / `else` (chat unchanged) and `:752-755` adds an `onnx)` engine arm | chat profiles take the `else` branch calling the same function with the same arguments; a bug in `catalog_capability` parsing would now affect every download. Candidate also adds ~279 lines of new helpers at `:389-667`. D-12: onnx download can report success with the smoke test skipped; D-13: three `sha256: null` files in `decide-nli` | read from code; D-12/D-13 open |
| R9 | **New systemd unit template written on every `llmctl install`** | `lib/service_linux.sh:184-209` (`llmctl-onnx@.service`, `MemoryHigh/MemoryMax` taken from the same `${memhigh}/${memmax}` variables, D-15). `_svc_unit_for` (`service_linux.sh:320-327`) picks `llmctl-<engine>@` from the env file, so llama/colibri selection is unchanged | `install` rewrites one additional unit; existing units unchanged. `lib/service_macos.sh` is byte-identical to HEAD, so there is **no launchd arm for `onnx`** (D-27); **INFERRED** that `decide-nli` cannot be supervised on macOS | measured: `diff` of service_macos.sh |
| R10 | **`bin/llmctl` sources `lib/decide.sh` on every invocation** | `bin/llmctl:32-33` (source), `:79-89` (usage text), `:202` (`decide)` dispatch) | every CLI command now parses 40 KB more bash and sets `LLMCTL_DECIDE_*` defaults at load; a top-level error in `decide.sh` would break all commands, including chat. Usage text gains a DECISION MODELS block | measured |
| R11 | **`catalog.sh` plan JSON gains keys and an onnx branch in `footprint()`** | `lib/catalog.sh:470-483` (onnx branch, RAM = size*1.5 + 512 MiB, VRAM 0), `:546-614` (`decision_instances`), `:620` (new top-level key in the plan JSON), `:668-687` (new "Decision capacity" section in `llmctl plan` text) | plan JSON consumers see a new top-level `decision_instances` key and the text plan gains a section; existing keys unchanged | read from code |
| R12 | **Catalog schema widened** | `models/catalog.json:14-20` (ports map +6), `tests/test_catalog_json.sh:24-29` (engine enum + `onnx`; `min_tier` + `below-minimum`) | the existing schema test no longer rejects `onnx`/`below-minimum`; ports 8092-8099 are new (no clash in HEAD: grep found no existing use). `LLMCTL_PORT_<PROFILE>` override naming now includes `DECIDE_2B`, `DECIDE_TINY`, etc. | measured |
| R13 | **Docs and governance text edits** | `README.md` (5 replaced HEAD lines: 9, 72, 76, 99, 113, 125, 224 areas), `docs/architecture.md` (4 replaced: 127-128, 155, 170, 189 incl. the Mermaid line `ALL["127.0.0.1 only ..."]` at HEAD 189), `docs/scripts/*.md`, `.specify/memory/constitution.md:216, 229-235` | doc claims "All services bind to 127.0.0.1" are rewritten; I-09 shows the real default is `0.0.0.0` (`lib/common.sh:74`), so HEAD's CLAUDE.md/README statement is itself inaccurate and must be reconciled once, not twice | read from diff |
| R14 | **Test-harness side effects on tracked evidence** | `tests/test_gpu_*.sh` overwrite `docs/qa/005-cuda-gpu-inference/*.txt` | running the full suite on a GPU-less host dirties two tracked evidence files (this is how the candidate acquired its `nvidia-smi not present` versions). Run the suite in a scratch clone, or restore the files before committing | measured |

Not found (checked, absent): HEAD-only changes to any function the candidate edits; changes to `lib/service_macos.sh`, `lib/hardware.sh`, `lib/common.sh`, `llmctld/`, `scripts/`, `upstreams/`; any new use of ports already used by HEAD.

## 6. Open items and honest limits

- The candidate tree is a snapshot of one moment; if HEAD moves before the port, section 4 step 1 must be repeated. The classification here is for `a9ebefe` only.
- Test results are from a scratch clone without submodule content and without systemd linger, so 2 existing suites fail identically with and without the candidate; the result is a **differential** (no new failure introduced, +5 new passing suites), not a full-environment green. `make lint` and the constitution verification harness were not run (shellcheck absent; harness out of scope for this read-only task).
- The candidate's test passes are stand-in based (source-findings Section C); that this port is textually clean says nothing about the feature being correct (D-01..D-31 remain).
