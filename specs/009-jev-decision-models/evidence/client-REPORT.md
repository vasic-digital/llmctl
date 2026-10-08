# Client follow-ups report (agent CLIENT): calibrated-answer fields, calibrate input, golden runner, matrix

Uncommitted tree; nothing staged/committed/pushed. Not touched: catalog, lib/*.sh, gateway/readout/contract/server/audit, llmctld, templates/agents, docs/agents, README/CHANGELOG.

## Finding that changes the premise of item 1

`Annotate` never re-rendered the gateway body: a single `ask`/`batch` call ALREADY passed `confidence_raw` / `calibration` (and `models --json` the new model fields) through byte for byte (characterisation test GREEN before any change). The real drops were: (a) `--permute` merge (rebuilt `confidence` from the averaged probabilities and dropped both fields), (b) `--explain` probabilities line, (c) the `models` table, (d) the abstention gate's shaped-scale cap applied a second time to a calibrated flagged answer. `probe-order` prints flip rates only (no confidence), so it has nothing to pass through.

## Item 1: client output + `--min-confidence`

* `internal/client/output.go`: `answerView` decodes `confidence_raw`/`calibration`; `Calibrated()` = calibration is a JSON object (`"mixed"`/null/absent = not calibrated). `AnswerConfidence`: a calibrated answer uses its calibrated `confidence` (probability scale, chance 1/n); the shaped-scale cap is not applied again (the gateway already caps a flagged answer at the winner's worst-case share); an answer with no LISTED option still scores 0. New `AnyCalibrated`; `Annotation.Calibrated`; `evidence.calibrated` is ALWAYS emitted (`true|false`).
* `internal/client/permute.go`: every averaged call carries the identical calibration object -> kept, `confidence` = mean of the calls' calibrated confidences, `confidence_raw` = shaped value from the averaged raw probabilities. Differing object, or only some calls calibrated -> `"calibration":"mixed"`, `confidence`=`confidence_raw`=shaped, not counted calibrated. No calibration anywhere -> output unchanged (no new fields).
* `cmd_ask.go`: evidence.calibrated wiring, `--explain` prints `confidence_raw` and `calibrated(method, n=..)`, `models` table gains `calibration` + `template` (12 hex) columns (JSON untouched), `--min-confidence` help states the semantics.
* RED: `undefined: AnyCalibrated / unknown field Calibrated` (compile), then behavioural: `identical calibration metadata is kept: {...,"confidence":0}`, `want calibration "mixed"`; cmd: `evidence.calibrated must be true: {...,"calibrated":false}`, `--explain ... confidence=0.8` (no raw), `models table lacks "calibration"`. GREEN: `go test -race` client/calibrate/cmd ok.

## Item 2: `calibrate` input

* `internal/calibrate/labels.go`: `Options{AssumeUncalibrated}`, `LoadOpts/ParseCSVOpts/ParseJSONOpts`, `ErrCalibratedLabels`. Probability precedence `p_pred` > `confidence_raw` > `confidence` (CSV: `confidence` is now its own column kind, so `p_pred`+`confidence` may coexist; JSON gains the same fallback). A well-formed row with a calibration marker (CSV non-empty/not 0/false/no/none/-/null; JSON object or `"mixed"`) whose probability could only come from `confidence` -> refused, exit 2, message names line/record, `confidence_raw`, `--assume-uncalibrated`. `Loaded` carries `CalibratedRows`, `RawFromCalibrated`, `AssumedUncalibrated`; report fields `calibrated_rows`, `raw_source_rows`, `assumed_uncalibrated` + notes. Malformed rows never trigger a refusal.
* `cmd_calibrate.go`: `--assume-uncalibrated` flag + help.
* RED: `undefined: ErrCalibratedLabels` (compile); cmd: `flag provided but not defined: -assume-uncalibrated`, report `{CalibratedRows:0 RawSource:0}`. Honest note: `confidence_raw` is the SHAPED confidence (chance 0), not a probability of being right; documented, `p_pred` preferred.

## Item 3: golden runner/stats

`run_golden.py`: `p_pred` was ALREADY the winner's raw probability (`probs[c]`, `max(v,1-v)`), independent of calibration, so ECE was never fed the served confidence; records now also keep `confidence` (served), `confidence_raw`, `calibration` via defensive `answer_confidence`. `stats.py`: unchanged maths (p_pred), now states it (`calibration_input`), counts `calibrated_records`, render prints `calibrated gateway: N records ... served confidence is not used`. Tests: StandIn `calibrated` switch; RED `AttributeError: no attribute 'answer_confidence'`, `KeyError: 'confidence'`, `KeyError: 'calibrated_records'`; the anti-flattery test (served 0.6 vs raw 0.9, ECE must be 0.30) is a characterisation that now also pins the mutation M8.

## Item 4: matrix

`tests/matrix/cases.py` asserted exact key sets. Now accepts the optional FR-080 answer fields only together and well-formed (`confidence_raw` in [0,1] + `calibration{method,n,profile_id}`), and `/v1/models` `template_hash` (64 lowercase hex) + `calibration` ({applied:true,method,n,profile_id} | {applied:false,reason in closed set}); everything else is still rejected. New `tests/py/test_matrix_calibration_fields.py` (new file; the existing units file is not in my ownership). RED: `model entry keys [...'calibration'...'template_hash']`. The reference server (`refserver`) does not emit these fields (unchanged).

## Mutation proof (each applied, test run, file restored; all KILLED)

M1 `Calibrated()` always false; M2 shaped cap re-applied to calibrated; M3 permute never "mixed"; M4 permute confidence not the calibrated mean; M5a/M5b CSV/JSON refusal removed; M6 JSON prefers confidence over p_pred; M6b CSV ignores confidence_raw; M7 matrix half-present calibration accepted; M8 stats ECE from served confidence; M9 runner drops the confidences; M10 evidence.calibrated not set; M11 `--assume-uncalibrated` ignored; M12 models table drops the reason.

## Gates run

`gofmt -l cmd internal` empty; `go vet ./...` ok; `go test -race -count=1 ./internal/client/ ./internal/calibrate/ ./cmd/llmctl-decide/` ok; `python3 -B -m unittest tests.py.test_golden_stats test_golden_runner test_golden_manifest test_matrix_calibration_fields test_matrix_harness_units` 73 tests OK; `tests/test_decide_cli.sh` PASS; `PATH=$HOME/.local/bin:$PATH make lint` rc 0; `tests/test_matrix_harness.sh`: everything PASS except ONE pre-existing, not mine: `FAIL: bytecode written into the work tree` = `tests/evidence/__pycache__` created 10:57 by another agent (I ran python with `-B` and did not create it; I left it, not my path). `scripts/golden/__pycache__` also pre-exists.

## Doc updates needed elsewhere

* Done by me: `specs/009-jev-decision-models/contracts/cli.md` (evidence.calibrated, min-confidence semantics, permute+calibration, models columns, calibrate flag + label-file rules), `docs/golden-set.md`.
* Not mine: `docs/scripts/decide.md` (calibrate options/label schema, `--assume-uncalibrated`, evidence.calibrated), `docs/scripts/stats.md` (new `calibrated_records`/`calibration_input`, record fields), `docs/decide-gateway.md`/`docs/decision-models.md` (min-confidence scale shift when a profile starts applying), `contracts/openapi.yaml` is unaffected (client-only), README/CHANGELOG (`--assume-uncalibrated`, `evidence.calibrated`), gaps register, `tasks.md`.

## Limits

* Calibrated confidence (chance 1/n) and shaped confidence (chance 0) are different scales; a threshold does not carry over when a profile starts/stops being applied (documented, `evidence.calibrated` shows which).
* Permuted calibrated confidence is the mean of per-call calibrated confidences of possibly different winners (flip_rate reports the disagreement); not a re-fit.
* JSON `confidence` as a fallback probability is a new behaviour for hand-made files that previously yielded accuracy-only; calibrated-marker rows without a raw source are now refused.
* No real-gateway run: fake gateways/stand-ins only; no calibration-quality claim.
* Full `make test` not run (as instructed).
