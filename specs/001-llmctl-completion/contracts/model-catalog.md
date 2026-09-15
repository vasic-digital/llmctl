# Model Catalog Contract

**Feature**: 001-llmctl-completion
**Version**: 1.0.0
**Date**: 2025-09-15

---

## Overview

The model catalog (`models/catalog.json`) is the single source of truth for all downloadable model profiles. It contains all metadata needed for download, verification, footprint computation, and serving.

---

## Catalog Schema

**File**: `models/catalog.json`
**Format**: JSON array of ModelProfile objects

---

## ModelProfile Object

```json
{
  "id": "fast",
  "engine": "llama.cpp",
  "size_bytes": 2500000000,
  "min_tier": "baseline",
  "port": 8080,
  "sha256": "a1b2c3d4e5f6789012345678901234567890abcdef1234567890abcdef123456",
  "repo_id": "Qwen/Qwen3-30B-A3B-Instruct-GGUF",
  "filename": "Qwen3-30B-A3B-Instruct-Q4_K_M.gguf",
  "engine_flags": {
    "ngl": 32,
    "ctx": 4096
  },
  "description": "Fast general-purpose model"
}
```

---

## Field Specifications

| Field | Type | Required | Constraints | Description |
|-------|------|----------|-------------|-------------|
| `id` | string | ✅ | Unique, lowercase, hyphenated | Profile identifier (used in CLI) |
| `engine` | enum | ✅ | `llama.cpp` \| `colibri` | Inference engine |
| `size_bytes` | integer | ✅ | > 0 | File size in bytes |
| `min_tier` | enum | ✅ | `below-minimum` \| `baseline` \| `workstation` \| `datacenter` | Minimum hardware tier |
| `port` | integer | ✅ | 8080-8091, unique | API port |
| `sha256` | string | ✅ | 64 lowercase hex chars | SHA256 checksum |
| `repo_id` | string | ✅ | Valid HF repo | Hugging Face repository |
| `filename` | string | ✅ | Matches HF blob | Model filename |
| `engine_flags` | object | ❌ | Engine-specific | Runtime flags |
| `description` | string | ❌ | Human-readable | User-facing description |

---

## Engine Flags

### llama.cpp (`engine: "llama.cpp"`)
```json
{
  "ngl": 32,
  "ctx": 4096
}
```
| Flag | Type | Description |
|------|------|-------------|
| `ngl` | integer | Number of GPU layers to offload (0 = CPU) |
| `ctx` | integer | Context size in tokens |

### colibri (`engine: "colibri"`)
```json
{
  "memory_mapped": true,
  "ram_reservation_mib": 8192
}
```
| Flag | Type | Description |
|------|------|-------------|
| `memory_mapped` | boolean | Always true for colibri |
| `ram_reservation_mib` | integer | RAM reservation in MiB |

---

## Port Assignments (Fixed)

| Profile | Port | Engine |
|---------|------|--------|
| fast | 8080 | llama.cpp |
| coder | 8081 | llama.cpp |
| vision | 8082 | llama.cpp |
| vision-pro | 8083 | llama.cpp |
| moe-fast | 8084 | llama.cpp |
| small | 8085 | llama.cpp |
| ws-dense-32b | 8086 | llama.cpp |
| ws-moe-30b | 8087 | llama.cpp |
| colibri-glm | 8090 | colibri |
| colibri-qwen36 | 8091 | colibri |

**Constraint**: All ports bind to `127.0.0.1` only (local-only per Constitution §11.4.10).

---

## Tier Gating

Profiles declare `min_tier`; planner recommends only when:
1. `tier(host) >= min_tier(profile)` AND
2. Footprint fits within budgets

| Tier | min_tier Value |
|------|----------------|
| below-minimum | (no profiles) |
| baseline | fast, coder, vision, moe-fast, small |
| workstation | + vision-pro, ws-dense-32b, ws-moe-30b |
| datacenter | + colibri-glm, colibri-qwen36 |

---

## Validation Rules

| Rule | Error |
|------|-------|
| `sha256` must be 64 lowercase hex chars | `INVALID_SHA256` |
| `port` unique across all profiles | `DUPLICATE_PORT` |
| `min_tier` valid enum | `INVALID_TIER` |
| `engine` valid enum | `INVALID_ENGINE` |
| `port` in 8080-8091 range | `INVALID_PORT` |
| `repo_id` valid HF format | `INVALID_REPO_ID` |

---

## SHA256 Sourcing

- Captured from Hugging Face API at catalog-generation time: `/api/models/<repo>?blobs=true` → `lfs.sha256`
- Entries with null sha256 (non-LFS config files) fetch live at download time
- Download fails hard if live fetch fails

---

## Example Entry

```json
{
  "id": "fast",
  "engine": "llama.cpp",
  "size_bytes": 2500000000,
  "min_tier": "baseline",
  "port": 8080,
  "sha256": "a1b2c3d4e5f6789012345678901234567890abcdef1234567890abcdef123456",
  "repo_id": "Qwen/Qwen3-30B-A3B-Instruct-GGUF",
  "filename": "Qwen3-30B-A3B-Instruct-Q4_K_M.gguf",
  "engine_flags": {"ngl": 32, "ctx": 4096},
  "description": "Fast general-purpose model"
}
```

---

*End of Model Catalog Contract*
