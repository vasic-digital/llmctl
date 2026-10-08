# COVERAGE agent report (T141 hygiene + T028 coverage report)

Date: 2026-10-08. Nothing staged/committed/pushed. Full numbers: `COVERAGE-REPORT.md` (same dir).

## A. T141 - tests no longer overwrite tracked QA evidence

Root cause: `writeDDoSBaselineObservation` (llmctld/internal/api/ddos_test.go) and `writeStressObservation`
(stress_test.go) wrote straight into `docs/qa/008-full-test-coverage/` on every run.

Fix: new helper `evidenceOutputDir(t)` in `llmctld/internal/api/loadtest_helpers_test.go` -> `t.TempDir()` by default,
the tracked dir only when `LLMCTL_QA_EVIDENCE=1` (same convention as tests/test_gpu_*.sh). Both writers use it; the
observation text still records host facts dynamically (`hostSummary()`), and the test log prints the temp path.
New tests `llmctld/internal/api/evidence_dir_test.go` (default is not under docs/qa; opt-in is the tracked dir).

- RED (before the change, HEAD evidence restored first): `go test -race -count=1 -run 'TestDDoS_...BaselineObservation|TestStress_...CapacityObservation' ./internal/api/` -> `ok`, then
  `git diff --stat docs/qa` -> 2 files changed, 13 insertions(+), 13 deletions(-) (tracked evidence rewritten).
- GREEN (after): restored the two files with `git checkout --`, re-ran the same tests plus `TestEvidenceOutputDir*`
  (`--- PASS` x4, `ok ... 14.2s`; logs show `observation written to /tmp/Test.../001/...txt`),
  `git diff --stat docs/qa/008-full-test-coverage` -> **empty**, `git status --short` for that dir -> empty.
- gofmt -l llmctld: clean. `go vet ./internal/api/`: ok. The two evidence files are at HEAD (restored by exact name; the diff before
  restoring was only regenerated numbers/timestamps).

## B. T028 coverage report (measure and report only, OD-15)

Deliverables: `scripts/coverage/{report.sh,bash_line_coverage.py,trace_init.sh,make_report.py,bash_suites_excluded.txt}`,
`tests/coverage_exclusions.txt`, `tests/py/test_bash_coverage.py`, `docs/scripts/coverage.md`,
`specs/009-jev-decision-models/evidence/coverage/` (report, summary json, Go -func listings, py/suite logs).

Headline (one full run, 1591 s wall, nice -n 10, <=2 parallel processes):

| language | coverage |
|---|---|
| Go | 84.3% (11208/13294 stmts): root module 89.9%, llmctld unit packages 65.4% |
| bash (line) | 71.5% (2311/3230 lines, 22 files measured) |
| python | 65.8% (1371/2083 stmts) |

Method: Go `go test -coverprofile` (+ `go tool cover -func` for per-function sizes); bash PS4 line trace via `BASH_ENV` hook ->
`BASH_XTRACEFD` -> FIFO -> collector (executed lines / executable lines per 11.4.224(E)); Python coverage.py in a scratch venv
(`uv venv` + `uv pip install coverage`; python3-venv/ensurepip is NOT installed on this host, so `python3 -m venv` fails - report.sh
prefers uv and falls back to venv+pip), with a `.pth` startup hook so python subprocesses of the bash suites are merged.

Instrument test (test-first/control needle): `tests/py/test_bash_coverage.py`, 6 tests, run via the real pipeline on a fixture script:
never-called function body MUST be uncovered, called one covered, arms flip with arguments, hook inert without FIFO. Mutation proof: with
`set -x` removed from trace_init.sh the e2e tests FAIL ("instrument saw nothing - blind"); restored -> 6/6 OK. Classifier self-check on the real
run: 22 of 2406 traced (file,line) records (0.91%) fell on lines the heuristic calls non-executable (printed in the report).
Honest note: I drafted the tool before the test (the test then exposed one bug in the test itself); the instrument validation is the mutation above,
not a literal RED-first.

Not measured / limits (all stated in the report):
- Bash: 21 suites EXCLUDED by `bash_suites_excluded.txt` with reasons (GPU x2, podman vantage, 7 systemd service suites, install/setup e2e, 3 engine-build,
  go_unit/py_unit, 3 Go mutation suites, run_tests_format). Only `scripts/install.sh` ends up with zero traced lines -> reported "not measured", not 0%.
  Line not branch coverage; set +x/traps unaccounted; only bash processes inheriting BASH_ENV are seen. `systemctl/podman/docker/launchctl/loginctl`
  were stubbed first on PATH as a safety net: 28 calls were blocked (only `systemctl --user show -p MainPID` / `list-units`, from decide-service related suites).
- Go: `llmctld/test/integration` (~400 s) NOT run, so llmctld numbers (cmd/llmctld 7.3%, internal/api 55.8%) are unit-only and under-report.
- Python: unit tier + python subprocesses of included bash suites; `scripts/coverage/make_report.py` itself is 0% (no unit test written for the renderer - follow-up).
- Exclusions (checked in, closed classes): 5 non-shipping fixture packages + llmctld/test/integration + submodules/*. No first-party shipping code excluded.
- Coverage is necessary-never-sufficient; no gate, no threshold calibration, no brownfield policy decided here.

Findings worth your attention (NOT fixed, outside my ownership):
1. `tests/test_bin_llmctl_symlink_invocation.sh` FAILS even WITHOUT the tracer (plain run rc=1: "symlinked invocation produced real plan JSON output").
2. `tests/test_onnx_server.sh` passes plain (rc=0) but failed under the coverage run (`non-integer id2label key -> clear message`: it got the
   "onnxruntime is not installed" message) because the python stage puts the scratch venv first on PATH; its python lines are still counted, the
   suite result is a measurement artifact. Both appear as rc=1 in the suite table.
3. Files below 85% and the largest uncovered functions (bash: hw_probe_json, _dl_smoke_test_onnx/_gguf, bin/llmctl main; Go: llmctld/cmd/llmctld parseClusterFlags
   and routes_*; root cmd/llmctl-decide/cmd_serve.go 67.8%) are listed in COVERAGE-REPORT.md as follow-up candidates; no tests were written.

Checks run: `gofmt -l` clean, `go vet ./internal/api/` ok, `tests/py/test_bash_coverage.py` 6/6, `bash tests/test_syntax.sh` PASS, `PATH=$HOME/.local/bin:$PATH make lint`
(shellcheck 0.11.0) clean, `shellcheck -S warning -x` on the new scripts clean, `scripts/check_doc_reachability.sh --check-links` -> reachable=181 orphans=0 broken=0.

For you to do (not my files): link `docs/scripts/coverage.md` from `docs/scripts/README.md` (it indexes the other script pages) and, if desired, add a
README/Makefile entry (`make coverage` -> `scripts/coverage/report.sh`). No stray binaries or pycache were left in the repo (python run with -B; Go outputs/profiles in the scratch work dir).
