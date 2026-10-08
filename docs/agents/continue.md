# Continue CLI (`cn`) and the decision gateway

**Installed by this project (T100):** `@continuedev/cli` 1.5.47 (`cn`), via `scripts/install_agents.sh`
(official npm package, tarball sha512 checked against the registry integrity; record in
`specs/009-jev-decision-models/evidence/agents-install.jsonl`); shim `~/.local/bin/cn`, install under
`~/.local/share/llmctl/agents/cn`.

## Base URL, CA trust, key
The decision call goes through `llmctl-decide` ([README](README.md#shared-setup)). `cn`'s own model is
configured in its config file (`--config <path>`); use `${{ secrets.NAME }}`/environment references per
Continue's docs, never a literal key.

## One decision call, non-interactively
`cn -p/--print` is non-interactive; `--allow <tool>` pre-approves a tool, `--auto` allows all tools,
`--readonly` is plan mode (all **verified** from `cn --help`; the exact tool name for shell execution is
**not verified** - read it from `cn`'s tool list in the live exercise):
```sh
cn -p --allow Bash \
  "Run exactly this shell command and show its JSON output: printf '%s' 'The disk is 97% full.' | llmctl-decide ask --stdin --type noul --instructions 'Is cleanup needed?' --json"
```
Tool form: `cn --mcp <slug>` adds a hub MCP server by `owner/package` slug only, so a local stdio server
is declared in the config file instead (Continue's `mcpServers`, **documented**, not run here).

## Gating hook
No hook mechanism found in `cn --help`.

## What proves it
Request-log recipe in the [README](README.md#what-proves-a-call-happened).
