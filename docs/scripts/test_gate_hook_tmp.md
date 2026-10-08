## Overview

`tests/test_gate_hook_tmp.sh` proves `templates/agents/llmctl-gate-hook.sh` no longer writes through a
predictable `/tmp` name (review-2 C-17). The old wrapper redirected the gate's stderr to
`${TMPDIR}/llmctl-gate.$$.err`; with a symlink planted at that name it truncated the symlink's victim file.
The test plants exactly that symlink (the pid is knowable: the plant and the hook run in the same process
via `exec`), runs the real hook and asserts the victim is intact, the hook still fails closed (`ask`) with the
gateway unreachable, no stray temp file is left, and that an unusable `TMPDIR` blocks (exit 2) rather than
allows.

## Prerequisites

`python3`, `bash`.

## Usage examples

```sh
bash tests/test_gate_hook_tmp.sh
```

## Edge cases

Only temp files under the test's own temp dir are created; the victim file is a fixture.

## Internal behaviour

The hook now captures stderr into a `mktemp` file (random name, 0600, `O_EXCL`); failing to create one is the
same fail-closed "unexpected outcome" as a crash of the gate logic (exit 2, or `ask`/`ESCALATE` per
`LLMCTL_HOOK_ON_ERROR`).

## Related scripts

`templates/agents/llmctl-gate-hook.sh`, `templates/agents/llmctl_gate.py`, `tests/test_agent_kit.sh`.

## Last verified date

2026-10-07
