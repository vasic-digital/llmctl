# opencode and the decision gateway

**Verified on this host:** opencode 1.18.30.

## Install
Already installed. Official: `curl -fsSL https://opencode.ai/install | bash` (see
[`../integrations.md`](../integrations.md#opencode)).

## Base URL, CA trust, key
For the *decision call* nothing is configured in opencode: its bash tool runs `llmctl-decide ask ...`
(TLS and key handled by that client, [README](README.md#shared-setup)). opencode's own driving model is
configured separately (provider block in `opencode.json`, see `integrations.md`); a key there is written as
`{env:NAME}` style references per opencode's config docs, never as a literal.

## One decision call, non-interactively
Allow just the command pattern, then run headless (permission syntax **documented**, last matching rule wins):
```json
{ "$schema": "https://opencode.ai/config.json",
  "permission": { "bash": { "*": "ask", "llmctl-decide *": "allow" } } }
```
```sh
opencode run -m PROVIDER/MODEL --format json \
  "Run exactly this shell command and show its JSON output: printf '%s' 'The disk is 97% full.' | llmctl-decide ask --stdin --type noul --instructions 'Is cleanup needed?' --json"
```
`opencode run [message..]`, `-m provider/model`, `--format json`, `--auto` (auto-approve everything not
denied - dangerous) are **verified** from `opencode run --help`. Tool form (opencode.json, **documented**):
```json
{ "mcp": { "llmctl-decide": { "type": "local", "command": ["llmctl-decide", "mcp"], "enabled": true } } }
```

## Gating hook
opencode has no shell-command hook; it has **plugins** (JS/TS, `.opencode/plugins/` or
`~/.config/opencode/plugins/`) whose `tool.execute.before(input, output)` can throw to block (**documented**).
Use `templates/agents/opencode-plugin.js` (copy to `.opencode/plugins/llmctl-gate.js`). It calls the kit hook
with `--agent generic`; DENY and ESCALATE both throw (opencode has no "ask" outcome here). `opencode run
--pure` runs *without* plugins - a gate is not a sandbox. The plugin file must export only the plugin
function (opencode treats every named export as a plugin); the stub-agent harness checks that.

## Live-exercise facts (measured 2026-10-08)
* `opencode run` loads every skill under `$HOME/.agents/skills` and `$HOME/.claude/skills` into the system prompt:
  on this host a trivial prompt became a **~105,000-token request**, rejected by a 24k-context local driver with
  `exceeds the available context size`, and opencode **retried it in an unbounded loop** (tens of requests per
  minute, no step limit). Run it with an isolated HOME and XDG directories
  (`HOME=$SCRATCH XDG_CONFIG_HOME=$SCRATCH/cfg XDG_DATA_HOME=$SCRATCH/data opencode run ...`) and always under
  `timeout 120`. With the isolated HOME the request was ~3k tokens.
* Without `--print-logs`, `opencode run` with stdout redirected to a file hung until killed in both runs made without it
  (cause not established, UNCONFIRMED); `--print-logs` (logs on stderr) and stdin from `/dev/null` completed.
* Per-invocation provider without touching the operator's config: a scratch `opencode.json` with an
  `@ai-sdk/openai-compatible` provider under `$XDG_CONFIG_HOME/opencode/`, `permission.bash` allowing `llmctl-decide *`.

## What proves it
Request-log recipe in the [README](README.md#what-proves-a-call-happened).

## Status
Plugin tested under the stub harness (`tests/fixtures/agents/agent_harness.mjs`); the live result is
recorded by the SC-007 exercise.
