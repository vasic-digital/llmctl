# crush and the decision gateway

**Verified on this host:** crush v0.91.2 (`@charmland/crush`).

## Install
Already installed (`npm install -g @charmland/crush`).

## Base URL, CA trust, key
The decision call is made by `llmctl-decide` inside crush's `bash` tool ([README](README.md#shared-setup)).
crush's own provider uses `crush.json` (`$ENV` references for keys, per the crush README); `crush dirs` shows
the config directories (global: `~/.config/crush`; the binary reads `crush.json` / `.crush.json`).

## One decision call, non-interactively
```sh
crush run -q -m PROVIDER/MODEL \
  "Run exactly this shell command and show its JSON output: printf '%s' 'The disk is 97% full.' | llmctl-decide ask --stdin --type noul --instructions 'Is cleanup needed?' --json"
```
`crush run [prompt...]`, `-q/--quiet`, `-m provider/model` are **verified** from `crush run --help`. Whether a
non-interactive `run` auto-answers the bash permission prompt is **not verified** (the global `--yolo` flag
accepts everything - dangerous); the live exercise decides, and records "not exercised" if the tool is
refused. Tool form (**documented**, crush README): `{"mcp": {"llmctl-decide": {"type": "stdio", "command": "llmctl-decide", "args": ["mcp"]}}}`.

## Gating hook
crush has command hooks: `PreToolUse` in `crush.json` (shell scripts, event JSON on stdin and `CRUSH_*`
variables, exit 2 = block with stderr as the reason, `decision` JSON on exit 0; **documented** in the crush
hooks guide - the binary contains `CRUSH_TOOL_*`/`CRUSH_SESSION_ID`). Only the top-level agent is intercepted
(sub-agents are not). Use `templates/agents/crush.hooks.json` + `crush-pretool.sh`. crush has no "ask"
outcome, and an omitted decision falls through to the normal permission flow which `--yolo` auto-approves,
so the kit turns ESCALATE into a deny.

## Live-exercise facts (measured 2026-10-08)
* `crush run -q -m provider/model` with a scratch `HOME`/`XDG_CONFIG_HOME`/`XDG_DATA_HOME` and a `crush.json`
  (`providers.<name>.type = "openai-compat"`, `models` list, `permissions.allowed_tools`) runs without touching the
  operator's config.
* Against a Gemma-3 llama.cpp server, crush's first request was rejected (`Conversation roles must alternate
  user/assistant`): the chat template does not accept crush's message sequence. Against Llama-3.2-3B it ran but
  failed to parse a response (`Message content is shorter than read bytes`). Neither produced the decision call.

## What proves it
Request-log recipe in the [README](README.md#what-proves-a-call-happened).

## Status
Hook tested with crush-shaped events against a real gateway (`tests/test_agent_kit.sh`); not yet run inside
crush itself; the live result is recorded by the SC-007 exercise.
