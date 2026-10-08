# Cline CLI and the decision gateway

**Installed by this project (T100):** `cline` 3.0.69 (official npm package, tarball sha512 checked against
the registry integrity; record in `specs/009-jev-decision-models/evidence/agents-install.jsonl`); shim
`~/.local/bin/cline`, install under `~/.local/share/llmctl/agents/cline`.

## Base URL, CA trust, key
The decision call goes through `llmctl-decide` ([README](README.md#shared-setup)). Cline's own provider is set
with `cline auth` / `-P/--provider`, `-m/--model` (key by Cline's own store or environment; `-k/--key` puts a
secret on the command line and is therefore **not** used in any llmctl example).

## One decision call, non-interactively
`cline [prompt]` runs a task headless; `-y/--yolo` auto-approves a limited tool set ("DANGEROUS: use only in
sandboxed environments"), `--json` prints messages as JSON, `--auto-approve <boolean>` (default true) sets
approval for all tools, `-t/--timeout` bounds the run (all **verified** from `cline --help`):
```sh
cline -y --json -t 120 -P PROVIDER -m MODEL \
  "Run exactly this shell command and show its JSON output: printf '%s' 'The disk is 97% full.' | llmctl-decide ask --stdin --type noul --instructions 'Is cleanup needed?' --json"
```
Whether `-y` includes shell execution is **not verified**; the live exercise records the result or
"not exercised". MCP servers: `cline mcp add <name> [targetArgs...]` opens an add wizard
(**verified** from `cline mcp --help`); the stdio command is `llmctl-decide mcp`.

## Gating hook
`cline hook` ("Handle a hook payload from stdin") and `--hooks-dir` exist (**verified** in `cline --help`), but
their payload and exit-code protocol is not documented on this host, so **no gating template is shipped**
(inventing one would be guessing). Revisit when the protocol is read from Cline's docs.

## What proves it
Request-log recipe in the [README](README.md#what-proves-a-call-happened).
