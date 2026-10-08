## Overview

`tests/test_decide_cli.sh` drives llmctl's own decision **client** end to end:
the real `llmctl-decide` binary and a real gateway process (`internal/server`
behind a throw-away CA made by the production certificate code) are built into
a temp directory — nothing lands in the repository tree — and exercised through
the Go CLI and through the thin bash front end `lib/decide.sh`.

## Prerequisites

`go` (the test prints `SKIP` and exits 0 when it is missing), `python3`,
`/proc` (the command-line scan reads `/proc/*/cmdline`; Linux).

## Environment variables

The test unsets every `LLMCTL_*` client variable at the start and builds its own
(`LLMCTL_HOME`, `LLMCTL_ENV_FILE`, `LLMCTL_ENDPOINT`, `LLMCTL_CACERT`,
`LLMCTL_DECIDE_BIN`) per case; nothing from the operator's shell leaks in.

## Usage examples

```sh
bash tests/test_decide_cli.sh
make test            # runs it with the rest of tests/test_*.sh
```

## Edge cases

* The test gateway helper is `internal/client/internal/clienttest`; modes
  `uniform`, `slow:MS`, `readout` (422 readout_failed) and `notready` (503).
* The "no secret on any command line" check has a **control needle**: a process
  that really carries the key on its argv must be detected first, or the
  all-clear would prove nothing. The scanner's own argv cannot match itself (the
  needle travels in the environment, the program on stdin).
* The wrong-CA case issues a second, unrelated CA with `llmctl-decide cert` and
  points the client at it: the right gateway with the wrong trust anchor is
  exit 5.

## Internal behaviour

Sections: success shapes and evidence; question file / `--explain` / `--dry-run`;
5 MB state from file, stdin and the front end (N-01); command-line scan during a
slow request (D-03); exit codes 4/5/6/1/10; usage errors 2 (N-07, N-16); batch;
models; the front end (exit-code pass-through, binary lookup errors, retired
variables absent from `lib/decide.sh`); strict `capacity`/`status` arguments;
wizard end-of-input and prompt visibility (N-06, N-09).

## Related scripts

`lib/decide.sh` ([decide.md](decide.md)), `tests/test_decide.sh`
([test_decide.md](test_decide.md)), `cmd/llmctl-decide/cmd_ask.go`,
`internal/client`.

## Last verified date

2026-10-07
