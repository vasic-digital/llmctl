# Claude Code and the decision gateway

**Verified on this host:** Claude Code 2.1.292 (`claude --version`).

## Install
Already installed here. Anthropic's installer: <https://docs.claude.com/en/docs/claude-code/setup>.
`claude -p`/`--print`, `--allowedTools`, `--output-format` exist (read from `claude --help`).

## Base URL, CA trust, key
The decision call does not go through Claude's own provider connection, so nothing about Claude's
TLS settings matters for it: Claude's Bash tool runs `llmctl-decide ask ...`, which uses
`LLMCTL_ENDPOINT` (default `https://127.0.0.1:8095`), `LLMCTL_CACERT` and the key from the environment
(see [README](README.md#shared-setup)). Claude's own model/provider (what *drives* the agent) is separate
and is chosen by the operator; the live-exercise record names it.

## One decision call, non-interactively
```sh
claude -p "Run exactly this shell command and print its JSON output, nothing else: printf '%s' 'The disk is 97% full.' | llmctl-decide ask --stdin --type noul --instructions 'Is cleanup needed?' --json" \
  --allowedTools "Bash(llmctl-decide *)" --output-format json
```
`--allowedTools "Bash(llmctl-decide *)"` pre-approves only that command pattern (permission-rule syntax
from the hooks reference, **documented**). Tool form: `claude mcp add decide -- llmctl-decide mcp` registers
the stdio server (`claude mcp add <name> <command> [args...]`, **verified** against `claude mcp add --help`);
the tool then appears as `mcp__decide__decide`.

## Gating hook
`PreToolUse` and `UserPromptSubmit` command hooks (**verified** from the hooks reference and the
shipped binary: the `UserPromptSubmit` payload carries `prompt`, not `prompt_text` as one summary of the
docs claimed). Exit 2 blocks; **any other non-zero status lets the call through** - that is why the kit's
wrapper converts every unexpected outcome into exit 2. Install `templates/agents/claude-code.settings.json`
into `.claude/settings.json` (project) or `~/.claude/settings.json` (user). The `UserPromptSubmit` variant
(`claude-code-prompt.sh`) holds a prompt back when the model says `block` or is unsure; it is optional and
not in the default snippet.
`claude --bare` skips hooks entirely - a gate is not a sandbox.

## Live-exercise form (measured 2026-10-08)
Cheapest model, bounded turns, no MCP or slash commands, only the two command patterns the pipeline needs:
```sh
claude -p "$PROMPT" --model haiku --allowedTools 'Bash(llmctl-decide *)' 'Bash(printf *)' \
  --output-format json --max-turns 4 --strict-mcp-config --disable-slash-commands
```
A pipeline is checked part by part, so `Bash(printf *)` is needed next to `Bash(llmctl-decide *)`. The run used
2 model requests (`num_turns` in the JSON result) and one gateway request.

## What proves it
The request-log recipe in the [README](README.md#what-proves-a-call-happened): one new `/v1/systemone`
line with `status: 200` per call. The transcript (`--output-format json`) is supporting evidence only.

## Status
Documented and unit-tested through the stub harness (`tests/test_agent_kit.sh`); the **live** result is
recorded by the SC-007 exercise.
