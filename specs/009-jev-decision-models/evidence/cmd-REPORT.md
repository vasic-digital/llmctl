# CMD report: OD-23 `calibrate`, `probe-order`, `completions` (+ front-end forwarding fix)

Nothing staged or committed. `scale` untouched.

## Files
New: `internal/calibrate/{stats,fit,labels,profile}.go` + tests (incl. `crosscheck_test.go`); `internal/client/probe.go` + `probe_test.go`; `cmd/llmctl-decide/cmd_{calibrate,probeorder,completions}.go` + tests.
Edited: `cmd/llmctl-decide/cmd_ask.go` (3 lines: `flagCapture` hook in `askNewFlagSet`, needed so completions read the live flag sets), `cmd_b2_test.go` (expects exactly `scale` planned; new three must be documented, not planned), `contracts/cli.md`, `lib/decide.sh`, `docs/scripts/decide.md`, `tests/test_decide_cli.sh`. `main.go` unchanged: each file registers itself in `init()`.

## calibrate
`--profile P --labels F [--method temperature|platt|isotonic] [--catalog] [--state-dir] [--model-sha] [--template-hash] [--unbound] [--dry-run] [--json]`.
Labels: CSV (`p_pred` + `correct`, or `p_pred` + `expected` + `predicted`; optional id,type,well_formed,variant,options) or the run_golden.py JSON. Accuracy +- Wilson, majority/chance baseline (per type and pooled), ECE/MCE/Brier with reliability table, fit, in-sample and 5-fold held-out after-metrics. Profile `$STATE/decide/calibration/<P>.json`, dir 0700, file 0600, atomic temp+fsync+rename. Bound to model sha256 (catalog `files[role=model]`, exactly one) and template hash (flag or catalog `decision.template_hash`). Unresolvable binding: report printed, exit 2, no profile; `--unbound` writes `<P>.unbound.json` (never the bound name). `calibrate.LoadProfile` refuses unbound or mismatched profiles.
Refusals (report, exit 0, no profile): <200 pairs ("insufficient for ECE (n=..., need 200)", no ECE number printed or stored), isotonic <1000 (data-model rule), single-outcome labels. Exit codes: 0, 1 write failure, 2 usage/invalid labels/unresolved binding.
Methods: temperature (golden-section on convex NLL of 1/T), Platt (Newton + backtracking + ridge to identity + smoothed targets; finite on separable data), isotonic (PAV, ties pooled, knots, linear interpolation). Deterministic, stdlib only.

## probe-order
`--questions F` (one request object, JSON array, NDJSON, or `-`; bare Typed Question with `--state-file`), `--profile`, `--permute K` (0 = full cycle default, or 2..64), client flags, `--json`. Same cyclic rotation as `ask --permute`. Per question: orders used (whole cycles), answer, flips/flip rate, per-listing-position share vs 1/n, max deviation, partial-cycle marker; non-choice reported "not permutable" without a call; nothing permutable = exit 2 before any network. All documents validated locally first; a failed call aborts with the client exit code (1/4/5/6) and prints nothing partial. `internal/client/probe.go` is a new file only; existing client code untouched.

## completions {bash|zsh}
Generated, not hand-listed: commands from the registry; flags from the live FlagSets (hook) or the command's own `-h` text (smoke, serve, cert); subcommands of key/cert/port/registry/vantage from their usage text; values from code (`calibrate.Methods`, `schema.Formats()`). bash 3.2-safe (no `[[`, arrays-assoc, etc.; test greps for such constructs), also works as `llmctl decide <TAB>` (front-end words checked against lib/decide.sh case labels). Other shell/none/extra arg: exit 2. No network/key/state.

## Tests, RED / GREEN / mutation
RED observed before each implementation: `vet: internal/calibrate/fit_test.go:11:48: undefined: Pair`; `labels_test.go: undefined: ParseCSV`; `profile_test.go: undefined: Profile`; `probe_test.go: c.ProbeOrder undefined`; cmd tests: `unknown subcommand "calibrate" (known: ask, batch, cert, ...)` (calibrate), `unknown subcommand "probe-order"`, `undefined: flagCapture` (completions); contract test: `"calibrate" is now a registered subcommand: update the planned marker in cli.md`.
GREEN: `gofmt -l` clean, `go vet ./...` clean, `go test -race -count=1 ./cmd/llmctl-decide/ ./internal/calibrate/ ./internal/client/` ok (8.4s / 5.7s / 7.1s), `tests/test_decide.sh` PASS, `tests/test_decide_cli.sh` PASS, `make lint` ok.
Mutations (each made the named tests fail, then restored): MinLabels 200->100 (TestCalibrationRefusedBelow200Labels, TestBothRefuseCalibrationBelow200); Z95 1.959964->1.96 (TestGoldenMasterAgainstStatsPy, TestWilsonMatchesStatsPy, TestAccuracyRowBaselines); profile mode 0600->0644 (TestWriteProfileModeAtomic...); probe position formula (both probe tests); completions flag walk disabled (TestEveryRegisteredCommandAndFlagIsInBothScripts, TestNewlyRegisteredCommand..., TestBashCompletionBehaviour...); isotonic floor removed (TestCalibrateIsotonicNeeds1000).
Property tests: ECE of calibrated synthetic set <0.02; temperature T~1 and identity on calibrated data; softens overconfident data and lowers ECE; Platt A~1,B~0 on calibrated data; isotonic monotone, outputs in [0,1], hand-worked PAV; deterministic fits; held-out fold improves.
Real-shell test: bash sources the generated script and fakes COMP_WORDS (calibrate, --method values, cert subs, `llmctl decide`).

## Numeric cross-check vs scripts/golden/stats.py
Hand-computed fixtures in comments: Wilson 8/10 = (0.490162, 0.943318); 90/100 = (0.825634, 0.944771); 200-item set ECE 0.05, MCE 0.1, Brier 0.175. `TestGoldenMasterAgainstStatsPy` runs `python3 -I stats.py --json` on a 240-record run_golden-shaped fixture and requires equality to 1e-12 for per-type n/accuracy/Wilson/majority/chance/baseline/verdict and ECE/MCE/Brier (logged: n=240 ece=0.127916667 mce=0.246041667 brier=0.175358333). Below 200 both refuse. The first draft of my hand Wilson numbers was wrong in places (caught by the test, corrected from stats.py output and re-derived).

## Front-end forwarding fix (coordinator request)
`lib/decide.sh` did not forward `smoke`, `mcp`, `vantage`. Now one list `_DECIDE_FORWARDED` (+ `_decide_is_forwarded`) in the `*)` branch. Test in `tests/test_decide_cli.sh`: asks the REAL binary for its registered list ("known: ..."), then for each runs `cmd_decide` with a fake binary recording argv. RED: with the list reduced, 3 FAIL (mcp, smoke, vantage); GREEN: all 16 forwarded.

## Gateway consumption of the profile (FR-080) - NOT done, out of scope
Spec says a profile is "refused at load" on mismatch. Remaining for gateway/readout (other agent): (1) publish `decision.template_hash` in the catalog (or from `contract`), currently absent so every bound profile needs `--template-hash`; (2) at start/SIGHUP load `$STATE/decide/calibration/<profile>.json` via `calibrate.LoadProfile(path, liveModelSHA, liveTemplateHash)` (refuses unbound/mismatch), apply `Calibrator` to the confidence only, report applied/ignored in authenticated `/readyz` detail; (3) `internal/calibrate` has no `Calibrator` reconstruction from `Profile.Params` yet (needs a `FromProfile`); (4) opt-in decision log (FR-080) not implemented.

## Limits
- zsh is not installed here: zsh script checked structurally only, never executed. bash 3.2 not available either; 3.2 compatibility = forbidden-construct scan + bash 5.3 execution.
- Temperature/Platt operate on the binary confidence of the predicted answer, not multiclass logits; accuracy/argmax unchanged.
- In-sample after-metrics are optimistic (labelled so); held-out is 5-fold on input order.
- completions introspects commands by running `-h` in-process (pure help in every current command); per-subcommand flags of custom-parsed commands are the union of flags named in their usage text. `llmctl decide ask --interactive` and shell-only words' flags are not completed.
- Binding resolution requires exactly one model file in the catalog.

## Docs for the DOCS agent
README / docs/user-manual.md / docs/faq.md / docs/tutorial.md / docs/architecture.md / CHANGELOG: mention the three commands, the 200/1000-label rules, bound vs unbound profile, completion install lines (`eval "$(llmctl decide completions bash)"`), that `llmctl decide smoke|mcp|vantage` now forward, and the "profile not yet applied by the gateway" limit; `specs/.../traceability.md` rows FR-080/FR-081 (delivered: metrics, fit, bound profile, order probe, completions; not delivered: gateway apply, decision log). Update `docs/golden-set.md` to point at `llmctl decide calibrate` accepting run_golden JSON.
