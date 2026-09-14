# Integrations: pointing coding agents at llmctl

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

## pi

`~/.pi/agent/models.json` — add a provider entry; reference it from
`~/.pi/agent/settings.json`:

```json
// models.json
{
  "providers": [
    {
      "name": "llmctl",
      "type": "openai",
      "baseUrl": "http://127.0.0.1:8081/v1",
      "apiKey": "local",
      "models": [{ "id": "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf", "name": "Qwen3 Coder (local)" }]
    }
  ]
}
```

```json
// settings.json
{ "model": "llmctl/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf" }
```

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

## Which port for which job?

* Coding agent default: **8081** (`coder`).
* Lightweight autocomplete / quick chat: **8080** (`fast`) or **8085** (`small`).
* Image inputs (screenshots, diagrams): **8082/8083** (`vision`, `vision-pro`).
* Huge-context refactors on workstations: **8086/8087** (`ws-*`, 32k ctx).
* Anthropic-API tools (Claude Code): **8090/8091** (colibri, native `/v1/messages`).
