# Data Model: llmctl Full Production Completion

**Feature**: 001-llmctl-completion
**Date**: 2025-09-15
**Status**: Complete

---

## Entities

### ModelProfile
Represents a downloadable model with all metadata needed for download, verification, and serving.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | ✅ | Unique identifier (e.g., `fast`, `coder`, `colibri-qwen36`) |
| `engine` | enum | ✅ | `llama.cpp` \| `colibri` |
| `size_bytes` | integer | ✅ | Model file size in bytes |
| `min_tier` | enum | ✅ | `below-minimum` \| `baseline` \| `workstation` \| `datacenter` |
| `port` | integer | ✅ | API port (8080-8091) |
| `sha256` | string | ✅ | SHA256 checksum (64 hex chars) |
| `repo_id` | string | ✅ | Hugging Face repo ID (e.g., `Qwen/Qwen3-Coder-30B-A3B-Instruct-GGUF`) |
| `filename` | string | ✅ | Model filename (e.g., `Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf`) |
| `engine_flags` | object | ❌ | Engine-specific flags (e.g., `{"ngl": 32, "ctx": 4096}`) |
| `description` | string | ❌ | Human-readable description |

**Validation Rules**:
- `sha256`: Must be 64 lowercase hex characters
- `port`: Unique across all profiles (8080-8091)
- `size_bytes`: Must match actual file size after download
- `min_tier`: Must be valid tier enum

**State Transitions**:
```
NOT_DOWNLOADED → DOWNLOADING → VERIFYING → DOWNLOADED
                    ↓
              VERIFY_FAILED (sha256 mismatch)
```

---

### HardwareProfile
Represents the host's detected hardware capabilities.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `cpu` | object | ✅ | CPU information |
| `cpu.cores` | integer | ✅ | Logical core count |
| `cpu.model` | string | ✅ | CPU model name |
| `cpu.simd` | string[] | ✅ | SIMD extensions (e.g., `["avx2", "avx512"]`) |
| `ram` | object | ✅ | RAM information |
| `ram.total_gib` | integer | ✅ | Total RAM in GiB |
| `ram.available_gib` | integer | ✅ | Available RAM in GiB (after 4GiB headroom) |
| `gpus` | array | ✅ | GPU array (empty if none) |
| `gpus[].vendor` | enum | ✅ | `nvidia` \| `amd` \| `intel` \| `apple` |
| `gpus[].vram_gib` | integer | ✅ | VRAM in GiB |
| `gpus[].compute` | enum | ✅ | `cuda` \| `rocm` \| `metal` \| `opencl` |
| `storage` | object | ✅ | Storage information |
| `storage.type` | enum | ✅ | `nvme` \| `ssd` \| `hdd` |
| `storage.free_gib` | integer | ✅ | Free space in GiB |
| `tier` | enum | ✅ | `below-minimum` \| `baseline` \| `workstation` \| `datacenter` |

**Tier Classification Rules** (computed from above):
- `datacenter`: cores ≥ 32 AND ram ≥ 96 GiB AND free storage ≥ 400 GiB
- `workstation`: cores ≥ 24 OR ram ≥ 64 GiB OR total VRAM ≥ 20 GiB
- `baseline`: cores ≥ 8 AND ram ≥ 32 GiB
- `below-minimum`: anything smaller

**Derived Fields** (computed at runtime):
- `ram_budget_mib = ram.available_gib * 1024 - 4096` (4 GiB headroom)
- `vram_budget_mib = gpu.vram_gib * 1024 * 0.85` (15% headroom)

---

### ModelFootprint
Represents the resource footprint of a model profile on a given hardware profile.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `profile_id` | string | ✅ | ModelProfile.id |
| `mode` | enum | ✅ | `gpu` \| `cpu` |
| `ram_mib` | integer | ✅ | RAM reservation in MiB |
| `vram_mib` | integer | ✅ | VRAM reservation in MiB (0 for CPU mode) |
| `fits` | boolean | ✅ | Whether footprint fits within budgets |

**Computation Rules** (per docs/architecture.md):
- **GGUF profiles** (llama.cpp):
  - `gpu` mode: `model_size + kv_cache ≤ vram_budget` → `ram = 2048 MiB` (2 GiB host)
  - `cpu` mode: `model_size + kv_cache ≤ ram_budget` → `vram = 0`
- **Colibri profiles**:
  - `vram = 0` (memory-mapped from NVMe)
  - `ram = 8192` MiB (< 100 GiB repo) or `24576` MiB (larger)
  - Storage must fit repo + 10%

**KV Cache Estimate**: `ctx_tokens × parallel_slots / 8` MiB (f16 upper bound)

---

### ServiceUnit
Represents a running model instance (systemd --user or launchd).

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `profile_id` | string | ✅ | ModelProfile.id |
| `pid` | integer | ❌ | Process ID (when running) |
| `ram_reserved_mib` | integer | ✅ | RAM reservation in MiB |
| `vram_reserved_mib` | integer | ✅ | VRAM reservation in MiB |
| `port` | integer | ✅ | API port (from ModelProfile) |
| `start_epoch` | integer | ✅ | Start timestamp (Unix epoch) |
| `engine` | enum | ✅ | `llama.cpp` \| `colibri` |
| `mode` | enum | ✅ | `gpu` \| `cpu` |
| `status` | enum | ✅ | `starting` \| `running` \| `stopping` \| `failed` |

**File Locations**:
- Linux: `~/.config/systemd/user/llmctl-{engine}@{profile}.service`
- Linux state: `$XDG_RUNTIME_DIR/llmctl/{profile}.run` or `~/.local/state/llmctl/run/`
- macOS: `~/Library/LaunchAgents/com.llmctl.{profile}.plist`
- macOS state: `~/Library/Application Support/llmctl/run/`
- Logs: `~/.local/state/llmctl/logs/{profile}.log`

---

### SchedulerState
Represents the global scheduling state for co-residency management.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `ram_budget_mib` | integer | ✅ | Total RAM budget (from hardware probe) |
| `vram_budget_mib` | integer | ✅ | Total VRAM budget (from hardware probe) |
| `ram_used_mib` | integer | ✅ | Currently reserved RAM |
| `vram_used_mib` | integer | ✅ | Currently reserved VRAM |
| `running_units` | array | ✅ | Active ServiceUnit[] |
| `co_residency_groups` | array | ❌ | Pre-computed co-residency groups |
| `eviction_order` | array | ❌ | LRU-ordered non-enabled service IDs |

**Operations**:
- `can_start(profile, mode)`: Returns boolean + footprint if fits
- `start(profile, mode)`: Adds reservation, updates budgets, starts service
- `evict(profile)`: Stops service, releases reservation, LRU non-enabled first
- `switch(profile)`: Evicts all, starts single profile

**Co-residency Algorithm** (greedy bin-packing, port order):
1. Sort recommended profiles by port (8080 → 8091)
2. For each profile: if `footprint.fits(current_budgets)`, add to group
3. Return all groups that fit

---

### CLIAgentConfig
Represents integration configuration for a supported CLI agent.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `agent_name` | enum | ✅ | `opencode` \| `pi` \| `crush` \| `claude-code` \| `aider` \| `continue` \| `cline` |
| `base_url` | string | ✅ | API base URL (e.g., `http://127.0.0.1:8081/v1`) |
| `api_key` | string | ✅ | API key (typically `local` for llmctl) |
| `model_id` | string | ✅ | Model ID as reported by `/v1/models` |
| `config_path` | string | ❌ | Agent config file path |
| `install_method` | enum | ❌ | `curl` \| `npm` \| `pipx` \| `vscode-extension` |
| `verification_prompt` | string | ❌ | Test prompt for verification |

**Supported Agents & Default Ports**:
| Agent | Engine | Port | API Style |
|-------|--------|------|-----------|
| opencode | llama.cpp | 8081 | OpenAI |
| pi | llama.cpp | 8081 | OpenAI |
| crush | llama.cpp | 8081 | OpenAI |
| aider | llama.cpp | 8081 | OpenAI |
| continue.dev | llama.cpp | 8081 | OpenAI |
| Cline | llama.cpp | 8081 | OpenAI |
| Claude Code | colibri | 8090/8091 | Anthropic |

---

## Relationships

```
HardwareProfile (1) ──tier──> ModelProfile.min_tier (N)
ModelProfile (1) ──instance──> ServiceUnit (N)
SchedulerState (1) ──reservations──> ServiceUnit (N)
ServiceUnit (N) ──budget──> SchedulerState (1)
CLIAgentConfig (1) ──profile──> ModelProfile (1)
```

---

## JSON Schemas

### ModelProfile (catalog.json entry)
```json
{
  "id": "fast",
  "engine": "llama.cpp",
  "size_bytes": 2500000000,
  "min_tier": "baseline",
  "port": 8080,
  "sha256": "a1b2c3d4e5f6...",
  "repo_id": "Qwen/Qwen3-30B-A3B-Instruct-GGUF",
  "filename": "Qwen3-30B-A3B-Instruct-Q4_K_M.gguf",
  "engine_flags": {"ngl": 32, "ctx": 4096},
  "description": "Fast general-purpose model"
}
```

### HardwareProfile (lib/hardware.sh output)
```json
{
  "cpu": {"cores": 8, "model": "Ryzen 7 2700X", "simd": ["avx2"]},
  "ram": {"total_gib": 32, "available_gib": 28},
  "gpus": [{"vendor": "nvidia", "vram_gib": 12, "compute": "cuda"}],
  "storage": {"type": "nvme", "free_gib": 500},
  "tier": "baseline"
}
```

### ServiceUnit (state file)
```json
{
  "profile_id": "fast",
  "pid": 12345,
  "ram_reserved_mib": 2048,
  "vram_reserved_mib": 10240,
  "port": 8080,
  "start_epoch": 1699999999,
  "engine": "llama.cpp",
  "mode": "gpu",
  "status": "running"
}
```

### SchedulerState (internal)
```json
{
  "ram_budget_mib": 28672,
  "vram_budget_mib": 10444,
  "ram_used_mib": 2048,
  "vram_used_mib": 10240,
  "running_units": [
    {"profile_id": "fast", "ram_mib": 2048, "vram_mib": 10240}
  ]
}
```

---

## Validation Rules Summary

| Entity | Rule | Error Code |
|--------|------|------------|
| ModelProfile | sha256 must be 64 hex chars | `INVALID_SHA256` |
| ModelProfile | port unique across profiles | `DUPLICATE_PORT` |
| HardwareProfile | tier must be valid enum | `INVALID_TIER` |
| ModelFootprint | fits must match budget check | `BUDGET_MISMATCH` |
| ServiceUnit | port matches ModelProfile | `PORT_MISMATCH` |
| SchedulerState | budgets ≥ 0 | `INVALID_BUDGET` |

---

*End of Data Model*
