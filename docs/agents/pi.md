# pi and the decision gateway

**Verified on this host:** pi 0.85.1 (`@earendil-works/pi-coding-agent`).

## Install
Already installed (`npm install -g @earendil-works/pi-coding-agent`; package docs in its `docs/` directory).

## Base URL, CA trust, key
The decision call is made by the `llmctl-decide` client that pi's `bash` tool runs, so pi's TLS setup is
irrelevant ([README](README.md#shared-setup)). For pi's *own* provider, `docs/custom-provider.md` documents
`apiKey: "$ENV_VAR"` references (and `!command`); use those, never a literal.

## One decision call, non-interactively
```sh
pi -p --provider PROVIDER --model MODEL \
  "Run exactly this shell command and show its JSON output: printf '%s' 'The disk is 97% full.' | llmctl-decide ask --stdin --type noul --instructions 'Is cleanup needed?' --json"
```
`-p/--print` (non-interactive), `--provider`, `--model`, `--no-extensions` are **verified** from `pi --help`.
pi has no permission prompts by default (its security doc: no built-in sandbox, tools run with your
permissions), so no allow-list is needed. pi has no built-in MCP client; use the shell form.

## Gating hook
pi has **no command hooks**; extensions are TypeScript modules and `pi.on("tool_call", ...)` can block by
returning `{ block: true, reason }` (**verified** in `docs/extensions.md`). Use
`templates/agents/pi-extension.ts` (copy to `~/.pi/agent/extensions/llmctl-gate.ts`, or `.pi/extensions/`).
ESCALATE asks the human through `ctx.ui.confirm` when a UI exists and blocks in `-p` mode (extensions "can't
prompt" there); a DENY is never overridable by that prompt. `--no-extensions` disables the gate.

## What proves it
Request-log recipe in the [README](README.md#what-proves-a-call-happened).

## Status
Extension tested under the stub harness; live result recorded by the SC-007 exercise.
