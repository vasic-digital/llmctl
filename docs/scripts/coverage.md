## Overview

`scripts/coverage/` measures and **reports** code coverage for llmctl (Constitution
§11.4.224; operator decision OD-15: measure and report only, there is no gate).

| File | Role |
|---|---|
| `report.sh` | orchestrator: runs the Go, bash and Python coverage stages and renders the report |
| `bash_line_coverage.py` | zero-tooling bash line-coverage engine (`executable`, `collect`, `report` subcommands) |
| `trace_init.sh` | `BASH_ENV` hook that turns xtrace on and streams records to a FIFO |
| `make_report.py` | renders `COVERAGE-REPORT.md` + `coverage-summary.json` from the raw stage outputs |
| `bash_suites_excluded.txt` | bash suites that are NOT run (podman / systemd / GPU / engine build / Go mutation), with reasons |
| `../../tests/coverage_exclusions.txt` | checked-in coverage-corpus exclusion list (closed class set + reason) |

## Prerequisites

* `bash`, `python3` (stdlib only for the bash engine), `go` (Go stage).
* Python stage: network access once, to install `coverage` (via `uv`, else `venv`+`pip`) into a scratch venv
  created under the work directory (approved by OD-3); nothing is installed globally.
* Heavy work runs under `nice -n 10`, at most two parallel processes. Do not run it on
  a host that is already saturated.

## Usage examples

```bash
# everything (Go + bash + Python), default output dir specs/009-jev-decision-models/evidence/coverage
scripts/coverage/report.sh

# only the bash stage, only two suites, custom dirs (smoke test of the instrument)
scripts/coverage/report.sh --stages bash --only-suites 'test_hardware_probe|test_scheduler_lock' \
    --out "$(mktemp -d)" --work "$(mktemp -d)"

# inspect what the classifier counts as executable lines of a file
python3 scripts/coverage/bash_line_coverage.py executable --lines lib/common.sh
```

Options: `--out DIR`, `--work DIR`, `--stages go,bash,python`, `--budget SECONDS`
(default 2400; remaining suites are listed as NOT-RUN), `--suite-timeout SECONDS`
(default 600), `--only-suites REGEX`.

## How the bash measurement works

`report.sh` exports `BASH_ENV=scripts/coverage/trace_init.sh` and a FIFO path. Every
non-interactive bash a suite starts sources the hook, which sets
`PS4='+COV:${PWD}:${BASH_SOURCE[0]}:${LINENO}:'`, points `BASH_XTRACEFD` at the FIFO and
runs `set -x`. A collector process reads the FIFO, keeps only files under the repo that
are coverage targets, and writes `{file: [executed lines]}`. The report divides executed
lines by executable lines (non-blank, non-comment lines bash can trace; keyword-only lines,
case patterns, function headers, heredoc bodies and continuation lines are excluded). A
safety directory of stub `systemctl`/`podman`/`docker`/`launchctl`/`loginctl` commands is
put first on `PATH`; every call to one is logged to `bash-blocked-calls.log` and fails.

Honest limits: **line, not branch** coverage; `set +x` regions and traps are unaccounted;
only bash processes that inherit `BASH_ENV` are seen (`env -i`, `sh`/`dash` are invisible);
the executable-line set is a heuristic whose disagreement with real traces is printed in the
report (classifier self-check). A coverage number never proves correctness.

## Tests

`tests/py/test_bash_coverage.py` traces a fixture script with known covered/uncovered
lines through the real pipeline (control needle: a never-called function must be reported
uncovered, and an instrument that saw nothing must fail the test).

## Exit codes

`0` report written; `2` bad arguments, missing toolchain, or malformed
`tests/coverage_exclusions.txt`. A failing package or suite does not abort the run: it is
reported in the log and in the report's suite table.
