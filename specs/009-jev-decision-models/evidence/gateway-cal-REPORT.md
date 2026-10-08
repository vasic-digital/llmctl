# T137 report: gateway applies a calibration profile + opt-in decision log (FR-080)

Agent GATEWAY-CAL. Uncommitted tree; nothing staged, committed or pushed. `models/catalog.json`, `lib/*.sh`, `llmctld/**` untouched.

## What was built

| Item | Where |
|---|---|
| `calibrate.FromProfile` (temperature / platt / isotonic rebuilt from stored params, validated) | `internal/calibrate/fromprofile.go` |
| Template hash computed in Go, `gateway.TemplateHash(spec, temperature)`; `gateway.SingleModelSHA` shared rule; `ProfileSpec.ModelSHA256` from the catalog | `internal/gateway/templatehash.go`, `catalog.go` |
| `CalibrationSet` (load at start + SIGHUP, atomic swap, closed refusal reasons, log-once), `Apply` | `internal/gateway/calibration.go`, `router.go` |
| Additive answer fields `confidence_raw`, `calibration{method,n,profile_id}` | `internal/contract/response.go` |
| `/v1/models` additive `template_hash`, `calibration{applied,...|reason}` | `internal/server/{server,handlers}.go` |
| Decision log (record builder, sink with placement guard) | `internal/audit/decision.go`, `internal/server/decision_log.go` |
| Wiring (env, banner, SIGHUP reload) | `cmd/llmctl-decide/cmd_serve.go` |
| `calibrate` binds to the computed hash (shared resolver) | `cmd/llmctl-decide/cmd_calibrate.go` |
| Contract / docs | `contracts/{openapi.yaml,env-vars.md,cli.md,catalog-schema.md}`, `docs/decide-gateway.md`, `docs/decision-models.md` |

## Design decisions

1. **What is hashed (`decision.template_hash`)**, 64 lowercase hex SHA-256 of a canonical text:
   * letter-logit: version tag, protocol, `contract.RenderPrompt` of a fixed canonical question/state (the prompt really sent), readout `spellings` (JSON, ordered), `n_probs`, effective `LLMCTL_DECIDE_TEMPERATURE` (unset/0 = 1, `strconv 'g' -1`). `mass_threshold` / `cache_prompt` are NOT hashed (they decide whether an answer exists / speed, not its probabilities), nor the profile id (profiles sharing a template share the hash), nor the model file (bound separately by its sha256).
   * systemone-native: version tag, protocol, `nativeBody` of a fixed canonical request (noul + choice + score).
   * nli-onnx: version tag, protocol, scorer convention, `DefaultHypothesis` of the canonical question/option, premise = cleaned state.
   * Three values are pinned in `templatehash_test.go`, so a template edit (which invalidates every bound profile, by design) is a deliberate change. No catalog edit: the catalog field is read only by `calibrate` (flag > catalog value > computed), and a differing catalog value yields a warning because the gateway would refuse that profile. If you prefer a catalog field, the computed values are in `/v1/models`.
2. **Live model sha**: the catalog's single `files[role=model].sha256` (what the downloader verified), via the SAME `gateway.SingleModelSHA` that `calibrate` now uses. The gateway does NOT re-hash the multi-GB file at start (honest limit: a file corrupted after verification is not noticed here).
3. **Reload path**: the existing SIGHUP handler (certificate reload) now also reloads calibration. Catalog changes still need a restart (specs are read once). A profile is applied only if it is a regular non-symlink file, owned by the gateway uid (or gateway is root), not group/world-writable, bound, bound to the live model sha AND template hash, and `FromProfile` accepts the params. Reasons (closed set): `mismatch`, `unbound`, `invalid`, `insecure`, `model_unresolved`; logged once per change to stderr, shown on `/v1/models`. No file = silent. `<id>.unbound.json` is never read.
4. **Application rule**: calibrator input = the winner's own probability (largest `probabilities` value among options the readout LISTED; a bounded option is never the winner), matching the `p_pred` of the labels. Output clamped to [0,1], `Round9`; non-finite output = answer left untouched. `confidence` becomes the calibrated probability of being correct (0-1 probability scale, chance = 1/n, NOT the shaped scale with chance = 0), `confidence_raw` keeps the shaped value, `calibration` names method/n/profile. `probabilities`, `choice`, `score`, `flags`, `upper_bounds` are never modified. noul has no confidence: untouched.
5. **Worst-case rule (WorstAllocation interplay)**: a flagged (`option_missing`) answer already carries the conservative distribution (winner gets the smallest share). Calibration may lower its confidence but never raise it above that worst-case winner share (`v = min(v, pmax)` when flags present). Unflagged answers are not capped. Tested with a raising and a lowering calibrator.
6. **Decision log** (env names from `env-vars.md`): `LLMCTL_DECIDE_LOG` remains the request log (it already existed with a default and "never state text"), so the decision log is the separate file the spec calls for: `LLMCTL_DECIDE_LOG_STATE=1` = consent (enables it at `$LOG_DIR/decide-decisions.jsonl`; any value other than 0/1 exits 2); NEW variable `LLMCTL_DECIDE_DECISION_LOG=<path>` names the file and, alone, enables it WITHOUT text. Records: UTC ts, request id, profile, type counts, per-answer summary (type, winner **index**, noul/score value, served + raw confidence, `calibrated`, flags), latency, status, model sha256, template hash, calibration profile. With consent: also `state`, question text, question name, chosen option key. Without consent none of those strings is in the record (tested by leak search). Mode 0600, parents 0700, `O_NOFOLLOW` (reuses `audit.Sink`), created through `placement.Check` (refused in an unignored git work tree), must differ from the request log. No key/Authorization field exists. Only authenticated + parsed requests appear (failed backend decisions are logged with their status and no answers). Write failures never fail a request; counted in the existing `llmctl_decide_audit_write_failures_total`, first one reported on stderr. Banner states whether text is logged.
7. No size cap / rotation: the spec asks for none; the sink reopens after an external rotation (documented).

## Test-first evidence (RED observed, GREEN, mutation)

RED = compile failure for new symbols, or a behavioural assertion failure when the code existed; quoted where behavioural.

| Item | RED | GREEN | Mutation (each KILLED) |
|---|---|---|---|
| FromProfile | `undefined: FromProfile` | `go test -race ./internal/calibrate` ok | temperature scaled by 1.0000001 -> `point 0 ... (not bit-identical)`; isotonic monotone check removed -> `isotonic y down: accepted` |
| TemplateHash / SingleModelSHA / catalog sha | `undefined: TemplateHash`; pins `PIN` | gateway tests ok | `fmtFloat(temperature)` -> `"1"` killed |
| Answer fields | `a.ConfidenceRaw undefined` | contract ok | `ConfidenceRaw` serialised from `Confidence` killed |
| CalibrationSet / Apply / Router | `undefined: CalibrationSet` | `-race` ok | flagged cap removed, raw not saved, bounded filter removed, clamp removed, perm check removed, log-once removed, NaN guard removed, router apply removed (all killed). Equivalent mutant: removing the redundant `a.Type == noul` guard survives (noul has no probabilities, covered by the `len==0` check) |
| Decision record/sink | `undefined: audit.DecisionFields` | audit ok | consent->always (state, question) killed, hex check, placement guard killed |
| Server integration | `cfg.Decisions undefined` | server ok (`-race`) | logDecision call, answers context key, request context key, write-failure counter, consent flag, bounded-winner (after adding a unit test for the surviving mutant) killed |
| Serve wiring (real server, in-process, fake engine) | `TestServeAppliesBound...: answer not calibrated: {... Calibration:<nil>}`; `no such file ... decisions.jsonl`; refusal count 0; `/v1/models` lacked the fields | all 8 new cmd tests ok (`-race`) | SIGHUP reload removed, initial load removed, `Temperature: temp` removed, decision==request-log guard removed, consent flag forced, `case "1"` neutralised: all killed |
| calibrate binds computed hash | `undefined: gateway` in test, old test pinned old behaviour | calibrate tests ok | fallback removed, warning removed, temperature parse neutralised: killed |

Scripts run: `gofmt -l cmd internal` clean; `go vet ./...` clean; `go test -race -count=1` ok for `internal/{calibrate,audit,contract,readout,gateway,server}` and `cmd/llmctl-decide`; `tests/test_gateway_endpoints.sh` PASS; `tests/test_decide_cli.sh` PASS; `tests/test_gateway_mutation.sh` PASS (control green + 10 new T137 mutants, all RED); `PATH=$HOME/.local/bin:$PATH make lint` rc 0.

Test-script changes forced by this work (flagging because they touch shared scripts):
* `tests/test_gateway_mutation.sh`: control run was ALREADY RED before my mutants (another agent's `TestFrontEndWordsMatchLibDecideSh` reads `../../lib/decide.sh`, which the script's source copy omitted). Fixed by copying `lib/decide.sh` into the work copy; plus 10 new mutants.
* `tests/test_decide_cli.sh`: asserted the OLD behaviour "calibrate cannot bind without a template hash (catalog has none) -> 2". With the computed hash, a letter-logit catalog entry now binds (rc 0); the unresolvable case is kept using a temp catalog with an unknown protocol, and a "written profile is bound" assertion was added.
* `cmd_calibrate_test.go`: the equivalent unit test was repointed the same way.

## Honest limits

* Calibration is fitted on, and applied to, the winner's probability only (binary "was the winner right"); it is not a multiclass recalibration. Option count n enters only through that probability; a profile fitted on 2-option questions is applied to 20-option questions without distinction.
* Profiles are read at start and on SIGHUP only (not per request); the catalog is read once, so a changed catalog sha needs a restart.
* Model binding is the catalog checksum, not a re-hash of the on-disk file.
* `n < 200` profiles ARE applied (n published); the SC-003 "no ECE claim" rule is a documentation/claim rule, not a gate here.
* Fake engines only for the end-to-end serve tests (unit tier); no real-model run was done in this task, so no accuracy/calibration-quality claim is made.
* `-race` was used on the touched packages; the full `make test` was not run (as instructed).
* Reusing `llmctl_decide_audit_write_failures_total` for decision-log failures conflates the two logs in one counter (stderr line distinguishes them).

## Doc / other-agent updates needed elsewhere

* README / CHANGELOG: new env var `LLMCTL_DECIDE_DECISION_LOG`, `LLMCTL_DECIDE_LOG_STATE` semantics, additive `/v1/models` + answer fields, SIGHUP reload of calibration.
* `evidence/cmd-REPORT.md` "Remaining for gateway/readout" items (1)-(4) and gaps-register G-135 are now addressed (catalog still has no stored hash by design); G-135 can be updated by whoever owns the register. `tasks.md` T137 can be ticked after review.
* `internal/client/output.go` (ask/CLI) re-renders `confidence` only and drops `confidence_raw`/`calibration`; `--min-confidence` thresholds picked for the shaped scale shift meaning on a calibrated answer. `internal/calibrate/labels.go` accepts a `confidence` column as `p_pred`: labels collected from calibrated answers must use the winner's probability, not the (now calibrated) `confidence`. Both are outside my file ownership.
* `tests/matrix` (refserver/cases.py) was not touched; if it validates `/v1/models` or answers with `additionalProperties:false`, add the new fields.
* Candidate for the catalog owner: a stored `decision.template_hash` is NOT needed (computed); if one is ever stored it must equal `GET /v1/models` `template_hash`, otherwise `calibrate` warns and the gateway ignores it.
