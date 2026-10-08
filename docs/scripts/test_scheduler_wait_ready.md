# `test_scheduler_wait_ready.sh`

## Overview

Source: `tests/test_scheduler_wait_ready.sh` (test suite). The text below is the file's own header comment, reproduced so this page cannot drift from the code.

```text
test_scheduler_wait_ready.sh - RED-then-GREEN regression test for a real,
live-reproduced defect (2026-09-23): `llmctl switch <profile>` (and
`start`) reported SUCCESS the instant `svc_start` (systemctl start /
launchctl kickstart) returned - which for a Type=simple/exec unit fires
right after fork/exec, WELL BEFORE llama-server/colibri finishes mmapping
and loading the model weights and is actually able to answer its
OpenAI-compatible endpoint. "Started" never meant "ready".

Live symptom: running claude_toolkit's sync-all-llmctl sweep against the
real running llmctl instance, 4 of 10 catalog profiles (fast, vision,
vision-pro, colibri-qwen36) reported FAIL immediately after `llmctl
switch <profile>` itself reported success - claude_toolkit's own
verification probe (a single curl with a 3-second timeout, no retry)
raced real, multi-second model-load time and lost. `small` happened to
pass only because it loaded fast enough / was already warm - the same
race exists for EVERY caller of `llmctl switch`/`start`, not just this
one sweep, so the correct fix is llmctl's own start/switch contract:
"started" MUST mean "actually serving", checked here via
_sched_wait_ready polling http://127.0.0.1:<port>/v1/models on loopback
(readiness is always checked over loopback regardless of the configured
LLMCTL_BIND_HOST - a service bound to 0.0.0.0 or any other address always
also accepts loopback connections).

LLMCTL_READY_TIMEOUT=0 disables the wait entirely (the sanctioned
test-injection escape valve, defaulted for every OTHER hermetic test in
tests/helpers.sh's test_setup_env - none of them bind a real port) - this
file explicitly overrides it per-assertion to exercise the real behavior
against a real, deliberately-delayed local HTTP fixture (the SAME
"python3 -m http.server, no mocks" pattern already established in
test_download.sh / test_cluster_request_checked.sh).
```

Run: `bash tests/test_scheduler_wait_ready.sh`. The number of passing assertions is measured, not typed: `scripts/doc_counts.sh scheduler_wait_ready` (see [doc_counts](doc_counts.md)).
