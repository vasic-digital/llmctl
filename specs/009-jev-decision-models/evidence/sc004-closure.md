# SC-004 closure: high/critical findings, verified by run + mutation (T129)

| Field | Value |
|---|---|
| Revision | 5 |
| Created | 2026-10-08 |
| Last modified | 2026-10-09 |
| Status | active: audit script shows 0 high D/N rows OPEN (D-06 DEMOTED as an evidence gap), but SC-004 is NOT met for release: the high letter-logit live defect [G-155](gaps-register.md) is OPEN (root cause confirmed, thinking-mode fix committed as `5184565` with its failing-first run confirmed in [g155/failing-first-2026-10-09.txt](g155/failing-first-2026-10-09.txt), partial live proof per profile: decide-2b works for noul/choice, decide-pro works with CPU 502 timeouts, decide not usable at the current mass_threshold, decide-max not exercised) and is outside the script's scope |
| Supersedes | revision 1 (the script output; it now lives in [sc004-generated.md](sc004-generated.md)) |
| Tree verified | Two different trees, do not conflate. Rows D-01..D-05, D-29, D-30, N-01 (the Closure table): worktree at HEAD `f1a22ea` (the main checkout's staged, uncommitted changes were NOT under test). D-06 evidence: live runs on `c5301de` plus uncommitted changes (`run_live_nli.sh`; for the anton thinking-fix run also `internal/gateway/letter.go`) and, for the nezha letter-logit runs, an uncommitted pre-HEAD snapshot whose commit is UNCONFIRMED. The fix and the runner change are committed since: `5184565` (letter.go, resolver.go, server deadline headers, golden runner) and `c00da7b` (`run_live_nli.sh`); HEAD at this revision is `c00da7b`. |

Scope: every row of severity H or C in [`../source-findings.md`](../source-findings.md) (D-xx) and
[`../research/jev-llmctl-new-files.md`](../research/jev-llmctl-new-files.md) (N-xx). There are 9 H rows and no C row
(the parser in `scripts/spec_closure_audit.py` matches `H|M|L|C`). Medium and low rows are covered only by the generated
table in [sc004-generated.md](sc004-generated.md); nothing here re-verifies them.

## Counts

| Severity | Rows | FIXED (RED->GREEN, run + mutation today) | DEMOTED | OPEN |
|---|---:|---:|---:|---:|
| H | 9 | 8 | 1 (D-06) | 0 |
| C | 0 | - | - | - |

`python3 scripts/spec_closure_audit.py --out evidence/sc004-generated.md --json evidence/sc004.json` agrees: H 9 / FIXED 8 /
DEMOTED 1 (D-06), OPEN 0, **exit 0** (re-run 2026-10-08 after the D-06 override; before it: OPEN 1, exit 1). The D-01 and D-06
changes in the generated table (re-generated 2026-10-09, exit 0 again) come from [sc004-overrides.json](sc004-overrides.json) (every evidence path in it exists; the script
refuses an override otherwise). The D-06 DEMOTED is the exit-0 reason: see the D-06 section below for exactly what it does and
does not close. **The script only parses the D-xx / N-xx rows of the two finding files; it cannot see [G-155](gaps-register.md), so exit 0 is not a release-readiness signal.**

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
| D-06 | H | **DEMOTED** (revision 3, via [override](sc004-overrides.json)): the missing real-model evidence now exists; live letter-logit failures are separate open defects, see [D-06](#d-06-what-closed-and-what-did-not) | none: P1 was SKIP (`d01_d15.jsonl:6`, no onnxruntime/sentencepiece/model offline) | n/a - the finding is missing real-model evidence, not a code defect | n/a | n/a: evidence is the live captures listed in the override |
| D-29 | H | **FIXED** | `p1-red-original/d16_d32.jsonl:17` (files still reading the retired `LLMCTL_DECIDE_API_KEY`) | `go test ./cmd/llmctl-decide -run TestKeyIsReadFromTheEnvFileToo` PASS (runtime: env -> `.env` chain); `tests/test_onnx_runtime.sh` "auth: LLMCTL_DECIDE_API_KEY in the environment is NOT accepted as the key" PASS (runtime); `tests/test_regression_defects.sh` D-11/D-29 retired-variable scan PASS (source-class, which is the right class for a "migrate every reference" finding); `tests/test_no_retired_vars.sh` PASS | `internal/keyring/keyring.go` `KeyVar` back to `LLMCTL_DECIDE_API_KEY` | FAIL: `TestKeyIsReadFromTheEnvFileToo` rc=4 "no access key found" (`mut-D-29.log`) and the D-11/D-29 scan (`mut-D-29-regr.log`; its D-25 failure is the no-`.git` copy artifact, also present on GREEN) |
| D-30 | H | **FIXED** | `p1-red-original/d30.jsonl:1-2` (control needle found; `.env`, `cert/ca/ca.key`, `log.key` in tar.gz and zip) | `tests/test_release_no_secrets.sh` (worktree) PASS, incl. its built-in mutation "old unfiltered script leaks planted .env / cert/ca/ca.key" | (a) file list = filesystem walk instead of `git ls-files`; (b) same plus the post-build archive scan disabled | (a) the independent post-scan aborts the build ("SECRET PATH in tar.gz: .env ..."), the suite exits 1 at the fixture build (`mut-D-30.log`) - defence in depth works, but no named assertion fired; (b) FAIL: "planted untracked secret absent from both archives" x4 (`mut-D-30b.log`) |
| N-01 | H | **FIXED** | `p1-red-original/n01_n29.jsonl:1` (200 000-char state: rc 126 "Argument list too long") | `tests/test_decide_cli.sh` "5 MB state through the bash front end exits 0", 5 MB `--state-file`/`--stdin`, argv needle scan PASS; `go test ./cmd/llmctl-decide -run 'TestAskStateSources|TestAskUsageErrorsExit2AndNeverReachTheNetwork'` PASS | `lib/decide.sh` `decide_ask` rewrites `--state-file F` into `--state "<contents>"` (argv transport) | FAIL: the original symptom, "llmctl-decide: Argument list too long", "5 MB state through the bash front end exits 0 (was rc 126 ...)" (`mut-N-01.log`) |

Mutations applied: 8 rows (D-01, D-02, D-03, D-04, D-05, D-29, D-30, N-01), 9 mutants (D-30 twice). All were caught.

## D-06: what closed and what did not

Revision 3 (2026-10-08). D-06 asked for (1) a captured real-model run of the ONNX encoder and (2) a captured live run of the logprob-letter
readout on `llama-server`. Both now exist; the closure below is limited to "the evidence gap is closed". It does **not** say the models work.

| D-06 ask | Evidence now in the tree | What it shows |
|---|---|---|
| (1) real ONNX encoder run | [live-models/decide-nli-main-wiredfix/](live-models/decide-nli-main-wiredfix/README.md): `decide-nli` on host `anton`, CPU, through the HTTPS gateway, tree HEAD `c5301de` plus the then-uncommitted `run_live_nli.sh` fix | 132/132 golden and 23/23 probes well-formed; `choice` 0.829 CI [0.687,0.915] beats its chance baseline 0.235; `noul` 0.533 (baseline 0.667) and `score` 0.226 (baseline 0.290) do **not** beat their majority baselines, so the NLI encoder is not good at noul/score; p50 1543 ms; determinism true; gateway edge statuses as expected (`live_checks.log`) |
| (2) live letter-logit readout on llama-server | [live-models/nezha-decide-pro-2026-10-08/](live-models/nezha-decide-pro-2026-10-08/), [nezha-decide-2b-2026-10-08/](live-models/nezha-decide-2b-2026-10-08/), [nezha-decide-2026-10-08/](live-models/nezha-decide-2026-10-08/) (nezha, CPU, an uncommitted pre-HEAD snapshot, commit UNCONFIRMED) | the readout path was exercised live and **fails**: `decide-pro` 68/132 well-formed (HTTP 422 `readout_failed` on the rest), `decide` (decider-4b) 0/132, `decide-2b` 0/132. 0.000 accuracies there are malformed-rate artefacts, not model accuracy. These nezha numbers are PRE-FIX; the post-fix anton runs (2026-10-09) are summarised below |

Superseded and not counted: [live-models/decide-nli-main-79268f5-INVALID-gateway-miswired/](live-models/decide-nli-main-79268f5-INVALID-gateway-miswired/)
(the harness did not tell the gateway the engine address: 173x 503).

**Still OPEN, not closed by this demotion:** the letter-logit profiles (`decide`, `decide-2b`, `decide-pro`) fail live as above. They are now tracked as
[G-155](gaps-register.md) (severity high, OPEN); G-018, G-075 and G-142 (the older D-06 rows) were updated to point at it. Confirmed mechanism: the
thinking-mode chat template puts the first token in `reasoning_content` (`nezha-decide-2026-10-08/root-cause-first-tok.txt`); the candidate fix
(`chat_template_kwargs.enable_thinking=false` in `internal/gateway/letter.go`, with a test in `letter_test.go`) is committed as `5184565`; its failing-first run is CONFIRMED (RED on `5184565~1`, GREEN on `5184565`, [g155/failing-first-2026-10-09.txt](g155/failing-first-2026-10-09.txt)). The thinking-template cause is CONFIRMED live. Live proof
of the fix is PARTIAL, per profile (anton, CPU, tree `c5301de` plus the then-uncommitted letter.go/resolver.go, later committed as `5184565`; the runs were not repeated on the committed tree; all single runs, n<200 uncalibrated):
`decide-2b` 0/132 -> 128/132 well-formed (noul 0.883 and choice 0.732 beat their baselines, score 0.290 does not; 8 x HTTP 422 on 20-option items vs catalog max_options 16, reason code not captured: UNCONFIRMED) [anton-decide-2b-thinkingfix-run2-2026-10-09](live-models/anton-decide-2b-thinkingfix-run2-2026-10-09/);
`decide-pro` 112/132 (noul 0.867, choice 0.659, score 0.645 all beat baselines; 29 x HTTP 502 `backend_failed` at about 27 s on a CPU engine, cause INFERRED, see [G-156](gaps-register.md)) [anton-decide-pro-thinkingfix-2026-10-09](live-models/anton-decide-pro-thinkingfix-2026-10-09/);
`decide` smoke 1/3, HTTP 422 `readout_failed` because the combined option-letter mass 0.44-0.47 is below the catalog `mass_threshold` 0.5 ([G-157](gaps-register.md)), golden/probes not run [anton-decide-thinkingfix-2026-10-09](live-models/anton-decide-thinkingfix-2026-10-09/);
`decide-max` not exercised ([G-158](gaps-register.md)) [anton-decide-max-not-exercised-2026-10-09.md](live-models/anton-decide-max-not-exercised-2026-10-09.md). Remaining sub-issues are G-156..G-160. N-10 / N-11 (medium, OPEN in the
generated table) are not closed by this either.

### Which rule applies to D-06 (SC-004 vs T129)

- SC-004 ([spec.md](../spec.md)) requires high items to be "fixed, each with a test first observed failing and then passing". T129 allows "fixed with a
  RED->GREEN pair **or demoted with captured evidence**". For a finding that is an evidence gap with no reproducible symptom (D-06), a failing-first test is
  impossible, so the T129 demotion route is the applicable one and is what the override records. spec.md SC-004 now says so explicitly.
- The code defect the new evidence exposed (G-155) is a different item: a high defect, so SC-004's fixed-with-failing-first-test rule applies to it in full.
  It is OPEN, hence **SC-004 is not met for release** even though the audit script exits 0.
- Release readiness: a release must not claim that all letter-logit profiles work. The per-profile truth today (live evidence, CPU, run on the then-uncommitted tree of the fix now committed as `5184565`): `decide-2b` works for noul/choice (score not shown better than majority); `decide-pro` works for noul/choice/score but returns 502 on long prompts on a CPU engine; `decide` is not usable at its current `mass_threshold`; `decide-max` is not exercised. Further, a release must not claim the profiles work, and must not treat audit exit 0 as closing SC-004, until G-155 is closed.
  The committed fix with a confirmed failing-first test now exists (`5184565`); still owed is a live run of `decide`, `decide-2b` and `decide-pro` on the release tree and the closing of G-156..G-160.

No cheap RED test was possible for D-06: it is an evidence gap, not a defect with a reproducible symptom.

## Findings for the lead (not edited here)

1. `red-to-green-map.json` names weaker guards for D-03 (`serve --api-key` refused; the runtime cmdline check where the
   test itself chooses the argv) than the guards that actually protect the production path (`tests/test_scheduler.sh` onnx arm,
   `tests/test_services.sh` 0600, `tests/test_decide_cli.sh` needle scan). Suggest adding them to the map.
2. `../source-findings.md` row D-01 and the T129 reconciliation comment in `../tasks.md` said D-01 was OPEN (the tasks.md comment and table row are fixed in revision 4; the source-findings.md row was not touched);
   no high D/N row is open (D-06 is DEMOTED), with the live letter-logit defects tracked as G-155.
3. Previously cited in `audit-REPORT.md`: `tests/test_no_retired_vars.sh` failing. On this tree (scratch copy of HEAD) it is
   `RESULT: PASS` (`sc004-verify/green-test_no_retired_vars.log`).
4. The worktree has no initialised submodules, so Go tests and the gateway suites cannot run in it directly; the scratch-copy
   workaround is described in Method step 1.
