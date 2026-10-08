# Coding agents and the decision gateway

**Revision:** 1 - 2026-10-07 (spec 009, T102/T103, FR-035, FR-086)

This directory shows, per supported agent, how it issues **one typed decision call** to the llmctl
decision gateway (`POST /v1/systemone`, see [`../decide-gateway.md`](../decide-gateway.md)) and how you
prove from the gateway's own request log that the call happened.

| Agent | Page | Hook / gate mechanism (verified from the agent's docs or binary) | Headless form found on this host |
|---|---|---|---|
| opencode | [opencode.md](opencode.md) | JS/TS **plugin**, `tool.execute.before` (throw = block) | `opencode run "msg" -m provider/model` |
| pi | [pi.md](pi.md) | TypeScript **extension**, `tool_call` event (`{block:true}`); no command hooks | `pi -p "msg" --provider P --model M` |
| crush | [crush.md](crush.md) | **command hook** `PreToolUse` in `crush.json` (exit 2 = block) | `crush run "prompt"` |
| Claude Code | [claude-code.md](claude-code.md) | **command hooks** `PreToolUse` / `UserPromptSubmit` in settings (exit 2 = block) | `claude -p "msg" --allowedTools ...` |
| aider | [aider.md](aider.md) | none (no tool/hook system) | `aider --message TEXT --yes-always` |
| Continue CLI | [continue.md](continue.md) | none found | `cn -p TEXT` |
| Cline CLI | [cline.md](cline.md) | `cline hook` subcommand exists; payload protocol not exercised | `cline -y TEXT` |

Nothing here claims an agent "passed": a pass needs the gateway's request record
(SC-007) and is recorded by the live-exercise task, not by these pages. Statements are marked
**verified** (read from the agent's `--help`, shipped docs or binary on this host, or run by the test
named), or **documented** (from the vendor's docs, not run here).

## Shared setup

1. **The gateway** listens on `https://127.0.0.1:${LLMCTL_DECIDE_PORT:-8095}` (TLS only). Start it with
   `llmctl decide serve` (see the gateway guide). Its CA certificate is
   `${LLMCTL_HOME:-$HOME/llmctl}/cert/ca/ca.crt`; for another machine run `llmctl decide cert export DEST` and
   copy the file.
2. **The key** is never written into a command line, config or document. `llmctl-decide` finds it by itself:
   `LLMCTL_API_KEY` from the environment, else the key file of the installation (see `llmctl decide key doctor`).
   Where an agent's own configuration needs a key, write an environment reference (`$LLMCTL_API_KEY`,
   or the agent's `env:`/`{env:NAME}` form), never the value.
3. **CA trust.** The recommended path needs **no** trust configuration inside the agent: the agent runs
   the `llmctl-decide` client (or `curl --cacert "$LLMCTL_CACERT"`), which trusts exactly one CA file and
   has no switch that disables verification. Export the file once:
   `export LLMCTL_CACERT="$HOME/llmctl/cert/ca/ca.crt"`. Installing the CA in the operating-system store
   is optional and needs root, so it is the operator's decision (not done by any llmctl script).
4. **Install the kit** (hooks, router, question):
   ```sh
   install -d ~/.config/llmctl/hooks
   cp templates/agents/{llmctl-gate-hook.sh,llmctl_gate.py,question.json,claude-code-pretool.sh,claude-code-prompt.sh,crush-pretool.sh} ~/.config/llmctl/hooks/
   chmod +x ~/.config/llmctl/hooks/*.sh
   ```
5. **Two ways for an agent to make the call**
   * *Shell form* (works with any agent that has a shell tool): the agent runs
     `printf '%s' "$STATE" | llmctl-decide ask --stdin --type choice --instructions "..." --criteria '{...}' --json`.
   * *Tool form*: `llmctl-decide mcp` is a minimal MCP server (stdio, one tool `decide`) for agents that
     speak MCP; `llmctl-decide schema --format mcp|openai-tool|json-schema` prints the tool definition.
     Failures come back as tool errors (`isError: true`), never as a default answer.

## Driving models (measured, T101)

The agent's **driving model** must be able to emit a tool call; the gateway test cannot pass without one.
Measured on 2026-10-08 against a real gateway (`specs/009-jev-decision-models/evidence/agents/AGENTS-REPORT.md`):
Claude Code driven by `--model haiku` issued the call and reported the gateway's answer (2 requests, profiles
`decide-laya` and `decide-julia`); the local chat models tried (Gemma-3-4B, Llama-3.2-3B) did not. A weak driver
either answers from its own head without calling the gateway (pi), mangles the quoting of a long pipeline
(opencode sent `printf ` and, later, `--state rm -rf ...` unquoted), loops on the resulting error, or is rejected by
the server's chat template (crush against Gemma: roles must alternate). None of those is a pass: the pass test is
the gateway's decision log, never the agent's text.

For a weak driver use the call form with the fewest quoting layers (the question lives in a file; only the state is
quoted):
```sh
llmctl-decide ask --question-file question.json --state 'rm -rf /var/lib/app' --profile decide-laya --json
```
A weak driver may still drop the quotes; give it a one-line state without spaces, or call from a wrapper script.
Always bound a headless run (`timeout 120 ...`): several agents have no step limit and retry a failing tool call
until killed.

## What proves a call happened

The gateway writes one JSON line per request to `${LLMCTL_DECIDE_LOG:-$LLMCTL_LOG_DIR/decide-requests.jsonl}`
(default `~/.local/state/llmctl/logs/decide-requests.jsonl`). The line carries `ts`, `request_id`, `method`,
`path` (`/v1/systemone`), `status`, `auth` (`ok`), `client_ip`, `profile`, `tls`, `ms` and an HMAC `state_hash`
(never the state). Count lines before and after the agent run:

```sh
LOG="${LLMCTL_DECIDE_LOG:-${LLMCTL_LOG_DIR:-$HOME/.local/state/llmctl/logs}/decide-requests.jsonl}"
before=$(wc -l < "$LOG")
# ... run the agent's headless command from its page ...
tail -n +$((before + 1)) "$LOG" | jq -c 'select(.path=="/v1/systemone") | {ts, status, auth, profile, client_ip}'
```

One new `status: 200, auth: "ok"` line per decision call is the evidence. An agent that only *says* it called
the gateway has proved nothing.

## The integration kit (`templates/agents/`)

| File | Purpose |
|---|---|
| `llmctl-gate-hook.sh`, `llmctl_gate.py`, `question.json` | the **fail-closed gating hook** (below) |
| `claude-code-pretool.sh`, `claude-code-prompt.sh`, `crush-pretool.sh` | one-path entry points for the hook configs |
| `claude-code.settings.json`, `crush.hooks.json` | hook configuration snippets |
| `opencode-plugin.js`, `pi-extension.ts` | the same gate as an opencode plugin and a pi extension |
| `router.py`, `routes.example.json` | the tested consumer-side router (replaces the two buggy snippets of the source material) |
| `AGENT-INSTRUCTIONS.md` | the "should this be a decision call?" snippet for `AGENTS.md` / `CLAUDE.md` |

### Fail-closed gating, and the one fail-open switch

The hook asks one `choice` question (`allow` / `review` / `block`) about a tool call and maps the answer:
`allow` with enough confidence lets the normal flow continue, `block` denies, everything else escalates.
**Every failure fails closed**: gateway down, TLS problem, HTTP 401/429/503/529, a timeout, a malformed or
confidence-less answer, an unknown answer, unparsable hook input, a missing `python3`, a crash of the
logic - none of them can produce an allow. The verdict then follows `LLMCTL_HOOK_ON_ERROR`:

| `LLMCTL_HOOK_ON_ERROR` | effect |
|---|---|
| `escalate` (default) | Claude Code: a permission prompt (`ask`); crush/opencode/pi: a block (they have no ask) |
| `deny` | block |
| `allow` | **fail-open**, the only way to get one; the reason is marked `FAIL-OPEN` |

Other settings: `LLMCTL_HOOK_MIN_CONFIDENCE` (default `0.7`), `LLMCTL_HOOK_ON_SAFE` (`defer` default = print
nothing so the agent's normal permission flow continues; `allow` = pre-approve), `LLMCTL_HOOK_TIMEOUT`
(default 20 s), `LLMCTL_HOOK_QUESTION_FILE`, `LLMCTL_DECIDE_BIN`. **Keep the agent's own hook timeout above
`LLMCTL_HOOK_TIMEOUT`**: Claude Code and crush treat a timed-out hook as a non-blocking error, which would
let the call through. Tested by `tests/test_agent_kit.sh` against a real gateway, a 529 stub, a wrong key
(401), a closed port and fake decision binaries ([`../scripts/test_agent_kit.md`](../scripts/test_agent_kit.md)).
