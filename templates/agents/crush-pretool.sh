#!/usr/bin/env bash
# crush-pretool.sh - entry point for the crush hook: the agent's hook config names this single path, no arguments needed.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/llmctl-gate-hook.sh" --agent crush
