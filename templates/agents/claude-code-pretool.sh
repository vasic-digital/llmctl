#!/usr/bin/env bash
# claude-code-pretool.sh - entry point for the claude-code hook: the agent's hook config names this single path, no arguments needed.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/llmctl-gate-hook.sh" --agent claude-code
