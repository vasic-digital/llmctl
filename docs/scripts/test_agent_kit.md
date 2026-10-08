## Overview

`tests/test_agent_kit.sh` tests the agent integration kit in `templates/agents/` end to end: the fail-closed
gating hook for Claude Code (`PreToolUse`, `UserPromptSubmit`), crush and a generic caller; the opencode
plugin and pi extension under a **stub agent harness** (`tests/fixtures/agents/agent_harness.mjs`, which
loads the real template and calls the hook the way the agent would); the config templates; and the
consumer-side router (`router.py`, `tests/fixtures/agents/router_driver.py`) - all against a real gateway, a
TLS stub that answers **529** (`status_stub.py`), a **wrong key (401)**, a closed port, a not-ready (503) and
a readout-failing (422) gateway, and fake decision binaries (`bad_decide.sh`: garbage output, missing
confidence, crash, hang, abstain, low confidence, unknown answer).

**70 passing** assertions (including the harness and router sub-checks, which print `harness ok:` /
`router ok:` lines).

## Prerequisites

`go`, `python3` (SKIP without them); `node` for the opencode/pi harness (honest SKIP without it).

## Usage examples

```sh
bash tests/test_agent_kit.sh
```

## Edge cases

* Assertions inside the test are never made in a `( ... )` subshell (the failure counter would be lost);
  the `sc VAR=val -- cmd` helper scopes environment variables in the current shell.
* Mutation checks run 2026-10-07 (each made the test fail, then was reverted): errors fail open; wrapper
  `exit 1` instead of `exit 2`; the confidence floor removed (caught by the `lowconf` fake); `max_labels`
  ignored; the opencode plugin never throwing; the pi extension letting a human override a DENY. One
  mutant survived as behaviourally equivalent: removing the visited-set cycle guard still ends in
  "cycle or depth limit" because the depth limit also bounds the chain.

## Internal behaviour

`python3 -c` snippets read JSON fields out of hook output; the key of the test gateway is asserted absent
from every captured stdout/stderr.
