# aider and the decision gateway

**Installed by this project (T100):** aider 0.86.2, via `scripts/install_agents.sh` (official method:
`uv tool install --python 3.12 --with pip aider-chat`, aider.chat/docs/install.html; wheel sha256 checked
against PyPI; record in `specs/009-jev-decision-models/evidence/agents-install.jsonl`). The shim is
`~/.local/bin/aider`; the install lives under `~/.local/share/llmctl/agents/aider`. `scripts/install_agents.sh --check` reports it.

## Base URL, CA trust, key
aider has **no CA option** for its own provider connection and **no tool or hook system**, so it cannot call
an HTTPS gateway itself. Its driving model is configured with `--openai-api-base`/`OPENAI_API_BASE` and
`OPENAI_API_KEY` (see [`../integrations.md`](../integrations.md#aider)); write the key as an environment
reference.

## One decision call, non-interactively
aider can only run shell commands in two ways, both documented: a model-*suggested* shell command that aider
executes after confirmation (`--suggest-shell-commands`, default on; `--yes-always` answers yes), and the
operator-typed `/run` chat command. `--message TEXT` (alias `-m`) processes one message and exits (**verified**
from `aider --help`). The attempt therefore is:
```sh
aider --message "Show me the shell command that runs: printf '%s' 'The disk is 97% full.' | llmctl-decide ask --stdin --type noul --instructions 'Is cleanup needed?' --json" \
  --yes-always --suggest-shell-commands --no-auto-commits --no-check-update --analytics-disable
```
This depends on the driving model producing a fenced shell block, which a weak local model often will not do.
The honest outcome in that case is **"not exercised: the model produced no shell command"**, recorded with
the transcript - never a pass. An operator-driven `aider --message "/run printf '%s' ... | llmctl-decide ask ..."`
works but is not the agent deciding anything.

## Gating hook
None (aider has no hook mechanism). Use `llmctl-decide ask` from a wrapper script or pre-commit step instead.

## What proves it
Request-log recipe in the [README](README.md#what-proves-a-call-happened).
