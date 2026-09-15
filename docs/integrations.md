# Integrations: pointing coding agents at llmctl

**Revision:** 2
**Last modified:** 2026-09-15T00:00:00Z

See also: [`docs/tutorial.md`](tutorial.md) for a worked first walkthrough
using one of these agents end-to-end, [`docs/user-manual.md`](user-manual.md)
for the full `bin/llmctl` command reference, [`docs/faq.md`](faq.md) for
troubleshooting an invalid agent config, and [`docs/api-reference.md`](api-reference.md)
for the exact HTTP endpoints each profile serves.

All llmctl profiles serve an OpenAI-compatible API on `127.0.0.1`:

| profile | port |
|---|---|
| fast | 8080 |
| coder | 8081 |
| vision | 8082 |
| vision-pro | 8083 |
| moe-fast | 8084 |
| small | 8085 |
| ws-dense-32b | 8086 |
| ws-moe-30b | 8087 |
| colibri-glm | 8090 |
| colibri-qwen36 | 8091 |

Endpoints per engine:

* **llama.cpp** (`llama-server`): `GET /v1/models`, `POST /v1/chat/completions`,
  `GET /health`. Speaks the **OpenAI** API only.
* **colibri** (`coli serve`): the OpenAI endpoints **plus** a native
  **Anthropic** `POST /v1/messages`.

The model id to use in client configs is whatever `GET /v1/models` reports
(typically the GGUF filename). llama.cpp's server accepts any model string and
serves the loaded model, so `"model": "local"` works in practice.

> Config formats evolve; the snippets below follow each tool's documented
> configuration schema at the time of writing. When in doubt, check the tool's
> own docs.

## Installing the CLI agents

Every one of the 7 supported CLI agents can be installed and verified with
`docs/integrations/install_<agent>.sh` (FR-011: "Both automated installation
scripts AND documented manual installation steps with verification
required"). Each script is standalone (fetchable/runnable on its own, no
dependency on this repository's `lib/`), checks whether the agent is already
on `PATH` first, installs via the agent's own real official mechanism only
if absent, then verifies with real captured command output — never a bare
"assumed success". None of these scripts are invoked automatically by
`llmctl setup` or `make test`; installing developer tooling onto a host is a
deliberate, manual step (the same hybrid CI-fixture/release-gating pattern
documented in `docs/quickstart.md`).

Manual install instructions for each agent are given alongside its config in
the sections below.

## Live-challenge determinism: per-agent normalization filters

Per spec.md FR-012/SC-008, a live challenge run through `llmctl start
<profile>` MUST be deterministic — the same fixed prompt against the same
seeded server produces the same answer. `lib/scheduler.sh`'s `LLMCTL_SEED`
environment variable makes the *server* side of that deterministic: setting
it appends `--seed <value> --temp 0` to a llama.cpp profile's launch
arguments (opt-in — it is not baked into every default launch, since an
always-fixed seed would make every everyday interactive coding session
identically non-creative; FR-012 scopes determinism to live-challenge
testing specifically, not routine use).

But per FR-047/Clarification 17, determinism is *measured* one layer up —
at the full CLI-agent-output artifact each of the 7 agents produces (its
transcript, diff, or edited files), not the raw model API response. Two
runs of the same deterministic prompt through the same agent can still
differ byte-for-byte in fields that have nothing to do with the model's
actual answer: wall-clock timestamps, per-run temp-directory/session-id
paths, and elapsed-time/token-usage reporting. FR-048 requires a
documented, versioned normalization filter per agent that strips exactly
those known non-deterministic field classes before the byte-identical
comparison.

Each agent has its own filter at `docs/integrations/normalize_<agent>.sh`
(`opencode`, `pi`, `crush`, `claude_code`, `aider`, `continue`, `cline`),
built on the shared primitives in
[`docs/integrations/lib_normalize_common.sh`](integrations/lib_normalize_common.sh)
(`norm_strip_timestamps`, `norm_strip_temp_paths`, `norm_strip_uuids`,
`norm_strip_durations`). Usage:

```bash
<agent-command> "<fixed prompt>" | bash docs/integrations/normalize_<agent>.sh > run1.txt
<agent-command> "<fixed prompt>" | bash docs/integrations/normalize_<agent>.sh > run2.txt
diff run1.txt run2.txt   # empty diff = determinism holds for this agent
```

Each filter is proven correct by a fixture pair under
`tests/fixtures/agent_output/<agent>/` (`run1.txt`/`run2.txt`, two synthetic
raw outputs differing only in timestamp/temp-path/UUID/duration, plus the
checked-in `expected_normalized.txt` both must reduce to) and exercised by
`tests/test_normalize_agents.sh`, part of `make test`.

**Honest boundary (Constitution §11.4.6):** the fixture pairs are
synthetic — they exercise the documented field classes generically, not
reverse-engineered from a real captured run of any of the 7 agents against
a live llmctl server. That capture, and the live end-to-end proof that "two
runs of the same fixed prompt through the real agent produce byte-identical
output after normalization," is release-gating, real-GPU work per
Clarification 1's hybrid approach — see `docs/quickstart.md`'s live-challenge
determinism section. This filter machinery is the mechanism that capture
will run through, not a substitute for having run it. The "ordering"
non-deterministic field class FR-048/Clarification 17 also names is not yet
addressed by any of the 7 filters: no real captured transcript exists yet
to reveal whether, or how, a given agent's output needs deterministic
re-ordering — each filter's header tracks this honestly as a release-gating
follow-up rather than guessing at a fix with no evidence to check it against.

## opencode

`~/.config/opencode/opencode.json` — custom provider with an
OpenAI-compatible base URL:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "llmctl": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llmctl local",
      "options": { "baseURL": "http://127.0.0.1:8081/v1" },
      "models": {
        "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf": { "name": "Qwen3 Coder (local)" }
      }
    }
  },
  "model": "llmctl/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
}
```

**Installing opencode:** script [`docs/integrations/install_opencode.sh`](integrations/install_opencode.sh)
checks for an existing `opencode` on `PATH`; if absent, runs opencode's
official curl install script and re-verifies; always ends by printing a
PASS/FAIL line carrying the real `opencode --version` output.

Manual install (verbatim, from https://opencode.ai/docs/, verified 2026-09-15):

```bash
curl -fsSL https://opencode.ai/install | bash
```

Alternative package managers (all documented at the same source): `npm
install -g opencode-ai`, `bun install -g opencode-ai`, `pnpm install -g
opencode-ai`, `yarn global add opencode-ai`, `brew install
anomalyco/tap/opencode` (Homebrew), `pacman -S opencode` (Arch), `paru -S
opencode-bin` (Arch AUR), `choco install opencode` (Chocolatey), `scoop
install opencode` (Scoop), `mise use -g github:anomalyco/opencode`, or
`docker run -it --rm ghcr.io/anomalyco/opencode`.

Verify: `opencode --version` — successful output is a bare version string
(e.g. `1.18.30`). If not found immediately after the curl installer runs,
open a new shell or `export PATH="$HOME/.opencode/bin:$PATH"`.

## pi

**pi** is the Pi Coding Agent (`@earendil-works/pi-coding-agent` on npm,
binary `pi`; https://github.com/earendil-works/pi, https://pi.dev — not to
be confused with any Raspberry Pi or math-constant tooling of the same
name). `~/.pi/agent/models.json` — add a provider entry; reference it from
`~/.pi/agent/settings.json`. Corrected 2026-09-15 against pi's real, current
schema (verified live against an installed instance and its upstream docs —
the `providers` value is an object keyed by provider name with an `"api"`
field, not an array with `"type"`):

```json
// models.json
{
  "providers": {
    "llmctl": {
      "baseUrl": "http://127.0.0.1:8081/v1",
      "api": "openai-completions",
      "apiKey": "local",
      "models": [{ "id": "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf", "name": "Qwen3 Coder (local)" }]
    }
  }
}
```

```json
// settings.json
{ "model": "llmctl/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf" }
```

**Installing pi:** script [`docs/integrations/install_pi.sh`](integrations/install_pi.sh)
installs pi via its official curl installer if absent and verifies with
`pi --version`, printing real PASS/FAIL evidence.

Manual install (verified against https://github.com/earendil-works/pi#readme
and https://www.npmjs.com/package/@earendil-works/pi-coding-agent, 2026-09-15):

```bash
curl -fsSL https://pi.dev/install.sh | sh
```

npm alternative: `npm install -g --ignore-scripts @earendil-works/pi-coding-agent`

Verify: `pi --version` — expected output is a version string (e.g. `0.85.1`).

## crush

`~/.config/crush/crush.json` — `openai-compat` provider type:

```json
{
  "providers": {
    "llmctl": {
      "type": "openai-compat",
      "base_url": "http://127.0.0.1:8081/v1",
      "api_key": "local",
      "models": [
        { "id": "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf", "name": "Qwen3 Coder (local)" }
      ]
    }
  },
  "model": { "provider": "llmctl", "model": "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf" }
}
```

**Installing crush:** script [`docs/integrations/install_crush.sh`](integrations/install_crush.sh)
installs crush (via npm/brew/go, whichever is available) if absent, then
verifies via `crush --version`.

Manual install (verified against https://github.com/charmbracelet/crush,
README "Installation" section, 2026-09-15) — pick one:

```bash
npm install -g @charmland/crush
# or
brew install charmbracelet/tap/crush
# or
go install github.com/charmbracelet/crush@latest
```

Other supported methods: `yay -S crush-bin` (Arch AUR), `nix run
github:numtide/nix-ai-tools#crush`, `pkg install crush` (FreeBSD), `winget
install charmbracelet.crush` / Scoop (Windows), and a signed apt/yum
repository for Debian/Ubuntu/Fedora/RHEL (see the script header for the full
apt-repo commands). crush has **no** `curl | bash` one-liner installer.

Verify: `crush --version` — expected output shape `crush version vX.Y.Z`.

## Claude Code

Claude Code speaks the **Anthropic** API. Two options:

1. **Colibri native** (no proxy): colibri serves `/v1/messages` directly.

   ```bash
   llmctl start colibri-qwen36   # port 8090
   export ANTHROPIC_BASE_URL="http://127.0.0.1:8090"
   export ANTHROPIC_AUTH_TOKEN="local"
   claude
   ```

2. **llama.cpp profiles**: llama-server speaks the OpenAI API, so you need a
   small OpenAI→Anthropic proxy in between (e.g. a local
   `litellm --model openai/... --api_base http://127.0.0.1:8081/v1` style
   shim) and point `ANTHROPIC_BASE_URL` at the proxy instead. Option 1 is the
   simpler path.

**Installing Claude Code:** script [`docs/integrations/install_claude_code.sh`](integrations/install_claude_code.sh)
installs Claude Code if absent (native installer, with npm fallback) and
verifies with real captured `claude --version` output.

Manual install (verified against https://code.claude.com/docs/en/setup,
2026-09-15) — native installer (macOS, Linux, WSL):

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

Alternative (npm, requires Node.js 22+): `npm install -g @anthropic-ai/claude-code`

Verify: `claude --version` — expected output shape `X.Y.Z (Claude Code)`.

## aider

Environment variables or `.aider.conf.yml`:

```bash
export OPENAI_API_BASE="http://127.0.0.1:8081/v1"
export OPENAI_API_KEY="local"
aider --model openai/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf
```

```yaml
# .aider.conf.yml
openai-api-base: http://127.0.0.1:8081/v1
openai-api-key: local
model: openai/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf
```

**Installing aider:** script [`docs/integrations/install_aider.sh`](integrations/install_aider.sh)
installs aider via its official curl setup script if absent, then verifies
with `aider --version`.

Manual install (official curl one-liner, verified against
https://aider.chat/docs/install.html, 2026-09-15):

```bash
curl -LsSf https://aider.chat/install.sh | sh
```

Windows (PowerShell): `powershell -ExecutionPolicy ByPass -c "irm https://aider.chat/install.ps1 | iex"`

Other current official methods: `python -m pip install aider-install &&
aider-install` (primary-recommended bootstrapper), `uv tool install --force
--python python3.12 --with pip aider-chat@latest`, `pipx install
aider-chat`, or `pip install -U --upgrade-strategy only-if-needed
aider-chat`.

Verify: `aider --version` — expected output shape `aider <version>` (e.g.
`aider 0.86.1`).

## continue.dev

`~/.continue/config.yaml`:

```yaml
models:
  - name: llmctl coder
    provider: openai
    model: Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf
    apiBase: http://127.0.0.1:8081/v1
    apiKey: local
    roles: [chat, edit, autocomplete]
```

> **Note (verified 2026-09-15):** Continue Dev, Inc. was acquired by Cursor
> in June 2026; its final release (2.0.0) shipped 2026-06-19 and the
> upstream `continuedev/continue` repository is now read-only/archived. Its
> standalone CLI (`cn`) and install script remain fully functional and
> installable — the 2.0.0 release removed the hosted-account requirement, so
> `cn` works standalone against llmctl's OpenAI-compatible API with no
> Continue account needed. It is simply no longer under active upstream
> development.

**Installing continue.dev:** script [`docs/integrations/install_continue.sh`](integrations/install_continue.sh)
checks for `cn` on `PATH`, and if absent, runs Continue's official curl
installer (which bootstraps Node.js via `fnm` if needed and installs the
`@continuedev/cli` npm package), then verifies with `cn --help` (there is no
documented `--version` flag upstream, so `--help`'s exit code + usage output
is the documented verification method Continue's own installer uses).

Manual install (verified against https://docs.continue.dev/cli/install and
https://raw.githubusercontent.com/continuedev/continue/main/extensions/cli/scripts/install.sh,
2026-09-15) — macOS/Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/continuedev/continue/main/extensions/cli/scripts/install.sh | bash
```

Windows (PowerShell): `irm https://raw.githubusercontent.com/continuedev/continue/main/extensions/cli/scripts/install.ps1 | iex`

npm (Node.js 20+, cross-platform): `npm i -g @continuedev/cli`

Verify: `cn --help` — expected exit 0 with usage/help text.

## Cline

Cline stores its provider settings in VS Code `globalState.json`
(`cline_globalState`). Use the "OpenAI Compatible" provider keys:

```json
{
  "actModeApiProvider": "openai-compatible",
  "openAiCompatibleBaseUrl": "http://127.0.0.1:8081/v1",
  "openAiCompatibleApiKey": "local",
  "openAiCompatibleModelId": "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
}
```

In practice it is easier to pick "OpenAI Compatible" in Cline's settings UI
and fill in the same values; both write to the same keys.

**Installing Cline:** as of 2026-09-15, Cline ships three surfaces: the IDE
extension documented above, a standalone CLI (`npm install -g cline`), and
an embeddable `@cline/sdk`. Script [`docs/integrations/install_cline.sh`](integrations/install_cline.sh)
automates the standalone CLI (the one with a real automatable install and
version check) — it does not touch the separate IDE extension.

Manual install — CLI (recommended for automation/testing against llmctl,
verified against https://docs.cline.bot/cline-cli/installation, 2026-09-15):

```bash
npm install -g cline
```

Requires Node.js 20+ (22 recommended). Configure it against an llmctl
profile with:

```bash
cline auth --provider openai-native --apikey local --modelid Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf --baseurl http://127.0.0.1:8081/v1
```

IDE extension (VS Code Marketplace id `saoudrizwan.claude-dev`; also on
Cursor/Windsurf/VSCodium marketplaces and JetBrains plugin id 28247) — search
"Cline" in your IDE's extension panel and install; uses the
`globalState.json` config shown above.

Verify: `cline --version` — expected a version string, exit code 0.

## Which port for which job?

* Coding agent default: **8081** (`coder`).
* Lightweight autocomplete / quick chat: **8080** (`fast`) or **8085** (`small`).
* Image inputs (screenshots, diagrams): **8082/8083** (`vision`, `vision-pro`).
* Huge-context refactors on workstations: **8086/8087** (`ws-*`, 32k ctx).
* Anthropic-API tools (Claude Code): **8090/8091** (colibri, native `/v1/messages`).
