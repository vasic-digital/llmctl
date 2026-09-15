# Service Unit Contract

**Feature**: 001-llmctl-completion
**Version**: 1.0.0
**Date**: 2025-09-15

---

## Overview

Service units represent running model instances managed by the OS service manager (systemd --user on Linux, launchd on macOS). Each service unit corresponds to a single ModelProfile instance.

---

## Service Unit Lifecycle

```
CREATED → STARTING → RUNNING → STOPPING → STOPPED
                ↓
            FAILED
```

---

## Service Configuration

### Linux (systemd --user)

**Template**: `lib/service_linux.sh` generates `llmctl-{engine}@{profile}.service`

**Unit File Structure**:
```ini
[Unit]
Description=llmctl %i (%I)
After=network.target
Wants=network.target

[Service]
Type=simple
EnvironmentFile=%h/.local/state/llmctl/services/%i.env
ExecStart=/path/to/llama-server @ENV_FILE@
Restart=always
RestartSec=5
StartLimitIntervalSec=0
MemoryHigh=%MEMORY_HIGH%
MemoryMax=%MEMORY_MAX%
StandardOutput=append:%h/.local/state/llmctl/logs/%i.log
StandardError=append:%h/.local/state/llmctl/logs/%i.log

[Install]
WantedBy=default.target
```

**Memory Limits** (computed from hardware probe):
- `MemoryHigh` = 90% of (probed RAM - 4 GiB)
- `MemoryMax` = 100% of (probed RAM - 4 GiB)

**Linger**: Enabled via `loginctl enable-linger $USER` (sudo fallback hint)

---

### macOS (launchd)

**Template**: `lib/service_macos.sh` generates `com.llmctl.{profile}.plist`

**Plist Structure**:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.llmctl.{profile}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/llama-server</string>
        <string>--config</string>
        <string>/path/to/profile.env</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>LLMCTL_PROFILE</string>
        <string>{profile}</string>
    </dict>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/Users/{user}/.local/state/llmctl/logs/{profile}.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/{user}/.local/state/llmctl/logs/{profile}.log</string>
</dict>
</plist>
```

**Install Location**: `~/Library/LaunchAgents/com.llmctl.{profile}.plist`
**Control**: `launchctl load/unload/start/stop`

---

## Environment File (profile.env)

**Location**: `~/.local/state/llmctl/services/{profile}.env` (Linux) or embedded in plist (macOS)

**Variables**:
```bash
LLMCTL_PROFILE=fast
LLMCTL_ENGINE=llama.cpp
LLMCTL_MODEL_PATH=/home/user/.local/state/llmctl/models/fast/Qwen3-30B-A3B-Instruct-Q4_K_M.gguf
LLMCTL_PORT=8080
LLMCTL_ENGINE_FLAGS=--ctx-size 4096 --n-gpu-layers 32
LLMCTL_RAM_RESERVATION_MIB=2048
LLMCTL_VRAM_RESERVATION_MIB=10240
LLMCTL_MODE=gpu
```

---

## State Files

### Reservation Record (`{profile}.run`)

**Location**: `$XDG_RUNTIME_DIR/llmctl/{profile}.run` (fallback: `~/.local/state/llmctl/run/`)

**Content**:
```json
{
  "profile_id": "fast",
  "pid": 12345,
  "ram_reserved_mib": 2048,
  "vram_reserved_mib": 10240,
  "port": 8080,
  "start_epoch": 1699999999,
  "engine": "llama.cpp",
  "mode": "gpu"
}
```

### Logs

**Location**: `~/.local/state/llmctl/logs/{profile}.log`

**Content**: Combined stdout/stderr from service process

---

## Dry-Run Mode

**Environment Variable**: `LLMCTL_DRY_RUN=1`

**Behavior**:
- Service files generated for real
- systemd/launchd calls printed instead of executed
- State files (reservations, env files, unit/plist) still created
- No actual process started

**Use Case**: Testing, CI/CD, validation without side effects

---

## Health Checks

### llama.cpp (llama-server)

**Endpoint**: `GET /health`
**Expected**: `{"status": "ok"}`

**Startup Probe**:
```bash
# Poll until healthy (max 30s)
for i in {1..30}; do
  if curl -sf http://127.0.0.1:8080/health >/dev/null; then break; fi
  sleep 1
done
```

### colibri (coli serve)

**Endpoint**: `GET /health`
**Expected**: `{"status": "ok"}`

---

## Smoke Test

**Trigger**: After model download, before accepting profile

**llama.cpp**:
```bash
# Start server with minimal config
llama-server --model <path> --ctx-size 512 --n-gpu-layers 0 --port 8080 &
SERVER_PID=$!

# Wait for health
sleep 2

# Send deterministic prompt
curl -s -X POST http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"local","messages":[{"role":"user","content":"Reply with exactly: OK"}],"temperature":0}' \
  | jq -r '.choices[0].message.content'

# Must return exactly: OK
kill $SERVER_PID
```

**colibri**:
```bash
coli doctor
# Must return success
```

---

## Log Rotation

**Policy**: No automatic rotation (user-managed)
**Location**: `~/.local/state/llmctl/logs/{profile}.log`
**Max Size**: Unlimited (user responsibility)

---

## Cleanup on Stop

1. Process terminated (SIGTERM → SIGKILL after 5s)
2. Reservation record deleted (`{profile}.run`)
3. Port released
4. Memory/VRAM budgets updated in SchedulerState

---

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Service fails to start | systemd/launchd Restart=always, logs captured |
| Port already in use | Start fails, evidence logged |
| Memory limit exceeded | OOM kill, systemd restarts |
| Model file missing | Start fails, evidence logged |
| sha256 mismatch on load | Hard failure, never reaches final path |

---

*End of Service Unit Contract*
