## Overview

`tests/test_decide.sh` proves the thin bash front end `lib/decide.sh` at unit
level. Its first block is the **post-download decision smoke path**: the real
Go binary `llmctl-decide` (built into a scratch dir) is run as
`llmctl-decide smoke` against the Go fake engine
`internal/gateway/internal/fakebackends` (a stand-in for the *model* only - HTTP,
the prompt template, the first-token readout and the answer validation are the
production code). The expected renormalised probabilities are computed *in the
test* with python3 (never hardcoded constants) and compared at 1e-8; exit codes
0 / 1 / 2 / 6 of `smoke` are asserted (valid answer, wrong expected choice,
unknown protocol, closed port). It also asserts that the five retired
shell/Python smoke helpers are no longer defined and that the retired Python
gateway file is gone (one implementation per rule). The rest: the thin
delegation to the Go binary (checked with a *recording stand-in binary* - unit
tier, so a stub is allowed: arguments pass through verbatim and every exit code
0/1/2/4/5/6/10 is returned unchanged), the interactive wizard, `decide
capacity` / `decide status`, and the catalog engine classes. The prompt
template, forged-option neutralisation and the exact shaping math have their
own Go tests (see "Related scripts"); the real client against a real TLS
gateway is `tests/test_decide_cli.sh`. Captured 2026-10-07: **71 passing
assertions, RESULT: PASS** (no network, no GPU, no real model required; needs
`go`).

## Prerequisites

* `tests/helpers.sh` (sourced for `test_setup_env`/`test_finish`/
  assertion helpers).
* `lib/common.sh`, `lib/os_detect.sh`, `lib/hardware.sh`,
  `lib/catalog.sh`, `lib/decide.sh`, `lib/scheduler.sh` - all sourced
  directly so the test can call `decide_*` functions in-process.
* `go` - builds `cmd/llmctl-decide` and the fake engine
  (`internal/gateway/internal/fakebackends`); without it the smoke block is an
  honest `assert_skip`.
* `python3` - computes the expected softmax values inside the test and the JSON
  helpers.
* `tests/fixtures/hw-baseline.json` via `LLMCTL_FAKE_HW` for the capacity
  assertions.

## Usage examples

* Standalone: `bash tests/test_decide.sh`
* Via the harness: `bash tests/run_tests.sh`; via `make test` / `make validate`.
* The real invocations this test exercises:
  ```bash
  llmctl-decide smoke --url http://127.0.0.1:$PORT --protocol letter-logit --options 2 --expect-choice billing --json
  decide_ask --type choice --state-file F --instructions "Which?" --criteria '{"billing":"..","legal":".."}' --json
  decide_interactive --interactive <<EOF ... EOF
  decide_capacity --json
  decide_status --json
  ```

## Edge cases

* **Smoke math**: the fake engine returns `A=-0.1` and `B..Z=-3.0` plus a
  non-letter ` the` token; the expected 2-option probabilities are
  `softmax([-0.1,-3.0])`, finite and summing to 1.
* **A wrong expected choice is a failure** (rc 1) - the smoke can never pass on a
  model that answers sanely-shaped but wrongly.
* **Thin delegation**: no flag parsing happens in bash; unknown flags are the client's
  exit 2. The access key is never read by `lib/decide.sh` (asserted by a source scan
  with comments excluded).
* **Unusable `LLMCTL_DECIDE_BIN`** is rc 1 naming the variable (never silently replaced).
* **Wizard**: refusal paths (non-TTY without `--interactive`, `LLMCTL_DECIDE_NO_INTERACTIVE=1`
  winning over the flag, end of input at a prompt = rc 2 with a message, N-06), prompts on
  stderr with piped stdin (N-09), a scripted heredoc through all seven steps, the client's
  exit code returned (4, 10 with JSON), and abort at `Proceed?` = rc 0 with no JSON.
* **Capacity/status**: on the baseline fixture `decide-tiny` gets
  `instances_gpu = min(10444//1592, 25904//2048) = 6` (asserted exactly); a misspelt
  `--jsno` is rc 2 (N-07); an absent binary is tolerated by `status`.

## Internal behaviour

1. Sources helpers + libs; builds the binary and the fake engine, starts the fake engine
   (ports file), reads the llama port.
2. Runs `llmctl-decide smoke` in several configurations and asserts JSON, exact math and exit codes.
3. Asserts the retired helpers/files are gone.
4. Installs a recording stand-in binary and asserts delegation, exit-code passthrough and
   the dry-run seam.
5. Asserts the wizard paths, `capacity`/`status` and the catalog engine classes, then `test_finish`.

## Related scripts

* Exercises `lib/decide.sh` (`decide_ask`, `decide_batch`, `decide_models`, `decide_key`,
  `decide_cert`, `decide_serve`, `decide_interactive`, `decide_capacity`, `decide_status`) and
  the `smoke` subcommand (`cmd/llmctl-decide/cmd_smoke.go`, `internal/gateway/smoke.go`).
* Where the retired helpers' assertions went: prompt template and forged options
  `internal/contract/prompt_test.go`; exact shaping math `internal/gateway/letter_parity_test.go`;
  readout filtering `internal/readout/readout_test.go`; the assertion-by-assertion map is
  `specs/009-jev-decision-models/evidence/python-gateway-parity.json`.
* Sibling suites: `tests/test_decide_cli.sh`, `tests/test_decide_download.sh`,
  `tests/test_gateway_endpoints.sh`, `tests/test_regression_defects.sh`.

## Last verified date

2026-10-07
