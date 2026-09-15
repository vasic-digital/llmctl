# API Compatibility Contract

**Feature**: 001-llmctl-completion
**Version**: 1.0.0
**Date**: 2025-09-15

---

## Overview

All llmctl profiles serve APIs on `127.0.0.1` at fixed ports. This contract defines the API compatibility for each engine.

---

## Engine API Matrix

| Engine | Profiles | Ports | OpenAI API | Anthropic API |
|--------|----------|-------|------------|---------------|
| llama.cpp | fast, coder, vision, vision-pro, moe-fast, small, ws-dense-32b, ws-moe-30b | 8080-8087 | ✅ Full | ❌ |
| colibri | colibri-glm, colibri-qwen36 | 8090, 8091 | ✅ Full | ✅ Native |

---

## llama.cpp API (OpenAI-Compatible)

**Base URL**: `http://127.0.0.1:{port}/v1`

### Endpoints

#### `GET /v1/models`
**Description**: List available models

**Response**:
```json
{
  "object": "list",
  "data": [
    {
      "id": "local",
      "object": "model",
      "created": 1699999999,
      "owned_by": "llmctl"
    }
  ]
}
```

**Note**: llama.cpp's server accepts any model string and serves the loaded model. The model ID in client config can be any string (e.g., `"local"`).

---

#### `POST /v1/chat/completions`
**Description**: Chat completions (OpenAI format)

**Request**:
```json
{
  "model": "local",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "Hello!"}
  ],
  "temperature": 0.7,
  "max_tokens": 100,
  "top_p": 1.0,
  "seed": 42,
  "stream": false
}
```

**Response** (non-streaming):
```json
{
  "id": "chatcmpl-123",
  "object": "chat.completion",
  "created": 1699999999,
  "model": "local",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Hello! How can I help you?"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 10,
    "completion_tokens": 20,
    "total_tokens": 30
  }
}
```

**Streaming Response** (when `stream: true`):
```
data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1699999999,"model":"local","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"},"finish_reason":null}]}

data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1699999999,"model":"local","choices":[{"index":0,"delta":{"content":"!"},"finish_reason":null}]}

data: [DONE]
```

**Supported Parameters**:
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `model` | string | ✅ | Any string (serves loaded model) |
| `messages` | array | ✅ | Chat messages array |
| `temperature` | number | ❌ | Sampling temperature (0-2) |
| `max_tokens` | integer | ❌ | Max completion tokens |
| `top_p` | number | ❌ | Nucleus sampling |
| `seed` | integer | ❌ | Fixed seed for determinism |
| `stream` | boolean | ❌ | Enable streaming |

---

#### `GET /health`
**Description**: Health check endpoint

**Response**:
```json
{
  "status": "ok"
}
```

---

## colibri API (OpenAI + Anthropic)

**Base URL**: `http://127.0.0.1:{port}/v1`

### OpenAI Endpoints (Same as llama.cpp)

- `GET /v1/models`
- `POST /v1/chat/completions`
- `GET /health`

### Anthropic Endpoints (Native)

**Base URL**: `http://127.0.0.1:{port}/v1`

#### `POST /v1/messages`
**Description**: Anthropic Messages API

**Request**:
```json
{
  "model": "local",
  "max_tokens": 100,
  "messages": [
    {"role": "user", "content": "Hello!"}
  ],
  "temperature": 0.7,
  "stream": false
}
```

**Response**:
```json
{
  "id": "msg_123",
  "type": "message",
  "role": "assistant",
  "content": [
    {"type": "text", "text": "Hello! How can I help you?"}
  ],
  "stop_reason": "end_turn",
  "stop_sequence": null,
  "usage": {
    "input_tokens": 10,
    "output_tokens": 20
  }
}
```

**Streaming**: Supported via `stream: true` (Server-Sent Events)

**Supported Parameters**:
| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `model` | string | ✅ | Any string |
| `messages` | array | ✅ | Messages array |
| `max_tokens` | integer | ✅ | Max completion tokens |
| `temperature` | number | ❌ | Sampling temperature |
| `stream` | boolean | ❌ | Enable streaming |

---

## Model ID Handling

### llama.cpp
- Accepts any model string in requests
- Serves the loaded model regardless of requested model ID
- Practical usage: `"model": "local"` works for any loaded model
- `/v1/models` returns the loaded model's filename as `id`

### colibri
- Same behavior for OpenAI endpoints
- Anthropic endpoints: model ID used for routing if multiple models loaded
- Single model per colibri instance (per profile)

---

## Error Responses

### OpenAI Format (both engines)
```json
{
  "error": {
    "message": "Error description",
    "type": "invalid_request_error",
    "param": "parameter_name",
    "code": 400
  }
}
```

### Anthropic Format (colibri only)
```json
{
  "type": "error",
  "error": {
    "type": "invalid_request_error",
    "message": "Error description"
  }
}
```

---

## Common Error Codes

| Code | HTTP Status | Description |
|------|-------------|-------------|
| `model_not_found` | 404 | Model not loaded |
| `invalid_request` | 400 | Invalid request parameters |
| `context_length_exceeded` | 400 | Context window exceeded |
| `rate_limit` | 429 | Rate limit exceeded |
| `server_error` | 500 | Internal server error |

---

## Authentication

**All endpoints**: No authentication required (local-only per Constitution §11.4.10)

**Headers**:
- `Authorization: Bearer local` (accepted but not required)
- `Content-Type: application/json` (required for POST)

---

## Rate Limiting

**No built-in rate limiting** (local-only, single-user)

---

## CORS

**Not applicable** (local-only, no browser clients)

---

## Versioning

**API Version**: v1 (stable)

**Backwards Compatibility**: Maintained within v1

---

## Testing Endpoints

### Health Check
```bash
curl -s http://127.0.0.1:8080/health
# Expected: {"status":"ok"}
```

### Models List
```bash
curl -s http://127.0.0.1:8080/v1/models | jq .
```

### Chat Completion (OpenAI)
```bash
curl -s -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"local","messages":[{"role":"user","content":"Hello"}],"temperature":0}' \
  | jq .
```

### Messages (Anthropic - colibri only)
```bash
curl -s -X POST http://127.0.0.1:8090/v1/messages \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"local","max_tokens":100,"messages":[{"role":"user","content":"Hello"}]}' \
  | jq .
```

---

*End of API Compatibility Contract*
