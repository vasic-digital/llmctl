# CLI Command Contract: llmctl

**Feature**: 001-llmctl-completion
**Version**: 1.0.0
**Date**: 2025-09-15

---

## Overview

The `llmctl` CLI is the single entrypoint for all llmctl operations. It dispatches to internal libraries for hardware probing, model management, scheduling, and service control.

---

## Command Schema

### Global Options
| Flag | Description |
|------|-------------|
| `--json` | Output machine-readable JSON |
| `--help` | Show help for command |
| `--version` | Show version |

### Commands

#### `llmctl setup`
**Description**: Complete setup flow (doctor → build engines → hardware plan)

**Exit Codes**:
- `0`: Success
- `1`: Error (engine build, hardware probe, or catalog validation failed)

**Output** (JSON):
```json
{
  "engines": {"llama.cpp": "built", "colibri": "built"},
  "hardware": {"tier": "baseline", "ram_budget_mib": 25904, "vram_budget_mib": 10444},
  "plan": {"recommended": ["fast", "coder", "vision", "moe-fast", "small"]}
}
```

#### `llmctl doctor`
**Description**: Environment self-diagnosis

**Exit Codes**:
- `0`: PASS (all checks pass)
- `1`: WARN (non-critical issues)
- `2`: FAIL (critical issues)

**Output** (JSON):
```json
{
  "status": "PASS|WARN|FAIL",
  "checks": [
    {"name": "engines", "status": "PASS", "evidence": "llama.cpp v0.4.0, colibri v1.11.0"},
    {"name": "hardware", "status": "PASS", "evidence": "tier: baseline"},
    {"name": "models", "status": "WARN", "evidence": "3/10 profiles downloaded"}
  ]
}
```

#### `llmctl hw [--json]`
**Description**: Dynamic hardware probe

**Options**: `--json` - Machine-readable output

**Exit Codes**: `0` success, `1` probe failed

**Output** (JSON):
```json
{
  "cpu": {"cores": 8, "model": "Ryzen 7 2700X", "simd": ["avx2"]},
  "ram": {"total_gib": 32, "available_gib": 28},
  "gpus": [{"vendor": "nvidia", "vram_gib": 12, "compute": "cuda"}],
  "storage": {"type": "nvme", "free_gib": 500},
  "tier": "baseline"
}
```

#### `llmctl plan [--json]`
**Description**: Which profiles fit, launch flags, co-residency groups

**Options**: `--json` - Machine-readable output

**Exit Codes**: `0` success

**Output** (JSON):
```json
{
  "tier": "baseline",
  "ram_budget_mib": 25904,
  "vram_budget_mib": 10444,
  "profiles": [
    {"id": "fast", "fits": true, "mode": "gpu", "ram_mib": 2048, "vram_mib": 10240},
    {"id": "coder", "fits": true, "mode": "cpu", "ram_mib": 18000, "vram_mib": 0}
  ],
  "co_residency": [
    ["fast", "coder", "vision"],
    ["moe-fast", "small"]
  ]
}
```

#### `llmctl models list`
**Description**: Catalog overview

**Output** (JSON):
```json
[
  {"id": "fast", "engine": "llama.cpp", "size_gib": 2.5, "min_tier": "baseline", "port": 8080},
  {"id": "coder", "engine": "llama.cpp", "size_gib": 17.7, "min_tier": "baseline", "port": 8081}
]
```

#### `llmctl models download <profile>`
**Description**: Resumable download + sha256 verify + smoke test

**Arguments**: `<profile>` - Profile ID from catalog

**Exit Codes**:
- `0`: Success (downloaded + verified + smoke test passed)
- `1`: Download failed
- `2`: SHA256 mismatch
- `3`: Smoke test failed

**Evidence Log**: Appends to `~/.local/state/llmctl/verify/<profile>.log`:
```
COMMAND: curl -L --continue-at - -o file.part URL
EXIT_CODE: 0
SHA256_VERIFIED: true
SMOKE_TEST: PASS (llama-server responded OK)
```

#### `llmctl models verify <profile>`
**Description**: Re-verify checksums of downloaded profile

**Exit Codes**: `0` verified, `1` mismatch, `2` not downloaded

#### `llmctl build [llama|colibri|all]`
**Description**: Build engines from pinned submodules

**Arguments**: Engine name (default: all)

**Exit Codes**: `0` success, `1` build failed

#### `llmctl start <profile> [more...]`
**Description**: Start profiles iff combined footprint fits

**Arguments**: One or more profile IDs

**Exit Codes**:
- `0`: All started
- `1`: Budget exceeded (refuses with exact numbers)
- `2`: Service start failed

#### `llmctl stop <profile|all>`
**Description**: Stop services

**Arguments**: Profile ID or `all`

**Exit Codes**: `0` success, `1` not running, `2` stop failed

#### `llmctl switch <profile>`
**Description**: Stop all, start exactly one profile

**Arguments**: `<profile>` - Profile ID

**Exit Codes**: `0` success, `1` start failed

#### `llmctl auto <capability>...`
**Description**: Best set that fits now, LRU-evicting non-enabled services

**Arguments**: Capabilities (e.g., `coder vision`)

**Exit Codes**: `0` success, `1` no fitting profile

#### `llmctl status` / `logs <profile>`
**Description**: Running services / log tail

**Exit Codes**: `0` success

#### `llmctl install`
**Description**: Install service templates (systemd units / launchd dir)

**Exit Codes**: `0` success, `1` install failed

#### `llmctl enable/disable <profile>`
**Description**: Autostart at login (linger enabled on Linux)

#### `llmctl restart <profile>`
**Description**: Restart a service

---

## JSON Output Schema

All commands with `--json` output follow this schema:

```json
{
  "status": "success|error",
  "data": {},
  "evidence": {
    "command": "exact command run",
    "exit_code": 0,
    "raw_output": "full raw output"
  }
}
```

On error:
```json
{
  "status": "error",
  "error": {
    "code": "ERROR_CODE",
    "message": "Human-readable message",
    "evidence": {}
  }
}
```

---

## Exit Code Conventions

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 2 | Invalid arguments |
| 3 | Budget exceeded / budget refusal |
| 4 | Verification failed (sha256, smoke test) |
| 5 | Service operation failed |
| 6 | Submodule/git error |

---

## Determinism Guarantees

- Same input → same output (for `--json`)
- `LLMCTL_FAKE_HW` fixture override for deterministic hardware
- `LLMCTL_DRY_RUN=1` for service action dry-runs
- `LLMCTL_HF_BASE` for local HTTP test server
- All state dirs relocatable via `LLMCTL_STATE_DIR`

---

*End of CLI Command Contract*
