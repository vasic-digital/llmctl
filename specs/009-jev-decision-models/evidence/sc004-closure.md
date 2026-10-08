# SC-004 closure: high/critical findings, verified by run + mutation (T129)

| Field | Value |
|---|---|
| Revision | 2 |
| Created | 2026-10-08 |
| Last modified | 2026-10-08T13:50Z |
| Status | active: 1 high row OPEN (D-06) |
| Supersedes | revision 1 (the script output; it now lives in [sc004-generated.md](sc004-generated.md)) |
| Tree verified | worktree at HEAD `f1a22ea` (the main checkout's staged, uncommitted changes were NOT under test) |

Scope: every row of severity H or C in [`../source-findings.md`](../source-findings.md) (D-xx) and
[`../research/jev-llmctl-new-files.md`](../research/jev-llmctl-new-files.md) (N-xx). There are 9 H rows and no C row
(the parser in `scripts/spec_closure_audit.py` matches `H|M|L|C`). Medium and low rows are covered only by the generated
table in [sc004-generated.md](sc004-generated.md); nothing here re-verifies them.

## Counts

| Severity | Rows | FIXED (RED->GREEN, run + mutation today) | DEMOTED | OPEN |
|---|---:|---:|---:|---:|
| H | 9 | 8 | 0 | **1** (D-06) |
| C | 0 | - | - | - |

`python3 scripts/spec_closure_audit.py --out evidence/sc004-generated.md --json evidence/sc004.json` agrees: H 9 / FIXED 8 /
OPEN 1, exit 1 (gate still closed by D-06). The D-01 change in the generated table comes from the new
[sc004-overrides.json](sc004-overrides.json) (every evidence path in it exists; the script refuses an override otherwise).

## Method

1. **GREEN, run today.** A scratch copy of the worktree (`rsync`, `.git` excluded, `submodules/containers` filled from the
   main checkout's submodule at the pinned commit `4a8f04e0`, the worktree has no initialised submodules) ran each guard.
   Logs: [sc004-verify/](sc004-verify/) `green-*.log`. Two copy artifacts, both checked and explained: `test_regression_defects.sh`
   D-25 and `test_release_no_secrets.sh` layer 1 need a `.git`; `git check-ignore -v lib/__pycache__/x.pyc` in the worktree
   matches `.gitignore:33`, and `test_release_no_secrets.sh` run in the worktree itself is `RESULT: PASS`
   (`green-wt-test_release_no_secrets.log`).
2. **RED.** The P1 RED captured on the candidate (`p1-red-original/*.jsonl`), or for D-01 the real-tokenizer RED of
   [realcheck/d01](realcheck/d01/) (the original candidate is no longer in this repository's git history; it exists only at
   `~/Projects/jev/llmctl/llmctl/lib/onnx_server.py`, sha256 re-checked today: `81595e3a...`, equal to the recorded value).
3. **Mutation (reverted fix) on a second scratch copy**, one at a time, restored from the pristine copy after each, anchors
   required to match exactly once: [sc004-verify/mutate.py](sc004-verify/mutate.py). Every mutation re-creates the
   finding's original behaviour, and every guard turned RED through a named assertion (`mut-*.log`). The D-05 mutation
   kept the `pid <= 1` refusal, so the only process the mutant could signal is the test's own `sleep 300` child.
4. Not run: the full suite, any engine, any model download (host-safety brief).

## Closure table (high rows)

| ID | Sev | Status | Captured RED (broken artifact) | Guard(s) run today (GREEN) | Mutation applied (reverted fix) | Guard under mutation |
|---|---|---|---|---|---|---|
| D-01 | H | **FIXED** | `realcheck/d01/red_output.txt`: candidate `encode_pair` with the pinned real DeBERTa `spm.model` (sha256 `c679fbf9...`, = catalog): 512 ids, 0 `[SEP]`, hypothesis fully absent, "DEFECT D-01 REPRODUCED". Real-tokenizer GREEN `green_output.txt` on shipped `lib/onnx_server.py` sha256 `97f48ddb...` = HEAD today | `tests/test_onnx_runtime.sh` F checks (premise-only truncation, both `[SEP]`, hypothesis intact; stub tokenizer, real runtime over real sockets) PASS. `tests/test_onnx_real_tokenizer.sh` SKIPS here (no sentencepiece, no spm.model); its PASS incl. its own end-truncation mutation is recorded in `realcheck/d01/test_output.txt` | whole-pair end-truncation (`ids = (...)[:max_tokens]`), the candidate's behaviour | FAIL: "F: [CLS] ... [SEP] hyp [SEP] special tokens survive truncation", contract driver FAIL (`mut-D-01.log`) |
| D-02 | H | **FIXED** | `p1-red-original/d01_d15.jsonl:2` | `go test ./internal/gateway -run TestPostJSONReReadsTheKeyFileOnA401AndRetriesOnce` PASS; `tests/test_gateway_endpoints.sh` "G-040: the per-profile llama key file authenticates the gateway to the engine" PASS | `internal/gateway/driver.go` postOnce no longer sets `Authorization: Bearer <key>` | FAIL: "rotation without restart failed: The decision backend failed." (`mut-D-02.log`) |
| D-03 | H | **FIXED** | `p1-red-original/d01_d15.jsonl:3` | `tests/test_scheduler.sh` "onnx arm: no --api-key <value> on argv", "key file mode is 0600" PASS; `tests/test_services.sh` "env file is mode 0600 under umask 022 (D-03)", "plist is mode 0600" PASS; `tests/test_regression_defects.sh` "serve --api-key is refused" PASS; `tests/test_onnx_runtime.sh` "key is NOT in /proc/<pid>/cmdline" PASS; `tests/test_decide_cli.sh` "no command line ever carries the key or the state" (control needle) PASS | `lib/scheduler.sh` onnx arm passes `--api-key "<value>"` instead of `--api-key-file` | FAIL: "onnx arm: --api-key-file under the state dir", "onnx arm: no --api-key <value> on argv" (`mut-D-03.log`). The 0600 env-file/plist leg was run GREEN but not mutated |
| D-04 | H | **FIXED** | `p1-red-original/d01_d15.jsonl:4` | `tests/test_onnx_server.sh` "--host {0.0.0.0, ::1, localhost, 192.168.1.5} refused" PASS | loopback check in `lib/onnx_server.py` disabled | FAIL: all four "--host ... refused" assertions (`mut-D-04.log`) |
| D-05 | H | **FIXED** | `p1-red-original/d01_d15.jsonl:5` | `go test ./cmd/llmctl-decide -run TestServeStopNeverSignalsUnrelatedProcess` PASS; `tests/test_gateway_endpoints.sh` "stop refuses a pidfile that names an unrelated process" / "the unrelated process was NOT signalled" PASS | `internal/gateway/proc.go` StopGateway skips `VerifyServeProcessInfo` (pid <= 1 guard kept) | FAIL: "stop rc=0 out=llmctl decide gateway: stopped" - the mutant signalled the unrelated process (`mut-D-05.log`) |
| D-06 | H | **OPEN** | none: P1 was SKIP (`d01_d15.jsonl:6`, no onnxruntime/sentencepiece/model offline) | n/a - the finding is missing real-model evidence, not a code defect | n/a | n/a. See OPEN list |
| D-29 | H | **FIXED** | `p1-red-original/d16_d32.jsonl:17` (files still reading the retired `LLMCTL_DECIDE_API_KEY`) | `go test ./cmd/llmctl-decide -run TestKeyIsReadFromTheEnvFileToo` PASS (runtime: env -> `.env` chain); `tests/test_onnx_runtime.sh` "auth: LLMCTL_DECIDE_API_KEY in the environment is NOT accepted as the key" PASS (runtime); `tests/test_regression_defects.sh` D-11/D-29 retired-variable scan PASS (source-class, which is the right class for a "migrate every reference" finding); `tests/test_no_retired_vars.sh` PASS | `internal/keyring/keyring.go` `KeyVar` back to `LLMCTL_DECIDE_API_KEY` | FAIL: `TestKeyIsReadFromTheEnvFileToo` rc=4 "no access key found" (`mut-D-29.log`) and the D-11/D-29 scan (`mut-D-29-regr.log`; its D-25 failure is the no-`.git` copy artifact, also present on GREEN) |
| D-30 | H | **FIXED** | `p1-red-original/d30.jsonl:1-2` (control needle found; `.env`, `cert/ca/ca.key`, `log.key` in tar.gz and zip) | `tests/test_release_no_secrets.sh` (worktree) PASS, incl. its built-in mutation "old unfiltered script leaks planted .env / cert/ca/ca.key" | (a) file list = filesystem walk instead of `git ls-files`; (b) same plus the post-build archive scan disabled | (a) the independent post-scan aborts the build ("SECRET PATH in tar.gz: .env ..."), the suite exits 1 at the fixture build (`mut-D-30.log`) - defence in depth works, but no named assertion fired; (b) FAIL: "planted untracked secret absent from both archives" x4 (`mut-D-30b.log`) |
| N-01 | H | **FIXED** | `p1-red-original/n01_n29.jsonl:1` (200 000-char state: rc 126 "Argument list too long") | `tests/test_decide_cli.sh` "5 MB state through the bash front end exits 0", 5 MB `--state-file`/`--stdin`, argv needle scan PASS; `go test ./cmd/llmctl-decide -run 'TestAskStateSources|TestAskUsageErrorsExit2AndNeverReachTheNetwork'` PASS | `lib/decide.sh` `decide_ask` rewrites `--state-file F` into `--state "<contents>"` (argv transport) | FAIL: the original symptom, "llmctl-decide: Argument list too long", "5 MB state through the bash front end exits 0 (was rc 126 ...)" (`mut-N-01.log`) |

Mutations applied: 8 rows (D-01, D-02, D-03, D-04, D-05, D-29, D-30, N-01), 9 mutants (D-30 twice). All were caught.

## OPEN

| ID | Missing evidence | Why it cannot be produced here | Cheapest way to close |
|---|---|---|---|
| D-06 | (1) a captured real-model run of the ONNX encoder path (`OnnxModel` with onnxruntime + the pinned 1.7 GB `decide-nli` model); (2) a captured live run of the logprob-letter readout on `llama-server` (the `decide`/`decide-tiny` profiles). Partly covered: the `systemone-native` llama profiles ran live through scheduler -> systemd -> HTTPS gateway ([live/NATIVE-REPORT.md](live/NATIVE-REPORT.md), 3 of 6 profiles). [realcheck/run_live_nli.sh](realcheck/run_live_nli.sh) says it ran on another host, but no output of it is in this tree, so it does not count (UNCONFIRMED). | model download and engines are out of scope for this pass (host-safety brief); no onnxruntime/sentencepiece installed | run `realcheck/run_live_nli.sh` on a host with the model and seal its OUT dir under `evidence/realcheck/`; add a live readout capture for one logprob-letter profile; then add a D-06 override citing both. This also feeds N-10 / N-11 (medium, OPEN in the generated table) |

No cheap RED test was possible for D-06: it is an evidence gap, not a defect with a reproducible symptom.

## Findings for the lead (not edited here)

1. `red-to-green-map.json` names weaker guards for D-03 (`serve --api-key` refused; the runtime cmdline check where the
   test itself chooses the argv) than the guards that actually protect the production path (`tests/test_scheduler.sh` onnx arm,
   `tests/test_services.sh` 0600, `tests/test_decide_cli.sh` needle scan). Suggest adding them to the map.
2. `../source-findings.md` row D-01 and the T129 reconciliation comment in `../tasks.md` still say D-01 is OPEN; with this
   revision only D-06 is open.
3. Previously cited in `audit-REPORT.md`: `tests/test_no_retired_vars.sh` failing. On this tree (scratch copy of HEAD) it is
   `RESULT: PASS` (`sc004-verify/green-test_no_retired_vars.log`).
4. The worktree has no initialised submodules, so Go tests and the gateway suites cannot run in it directly; the scratch-copy
   workaround is described in Method step 1.
