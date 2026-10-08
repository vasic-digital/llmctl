#!/usr/bin/env bash
# llmctl-gate-hook.sh - fail-closed wrapper around llmctl_gate.py for agent command hooks.
#
# Usage:  llmctl-gate-hook.sh --agent claude-code|claude-code-prompt|crush|generic   (hook event JSON on stdin)
# Why a wrapper: Claude Code and crush treat only exit status 2 as "block"; ANY other non-zero status
# (a crash, a missing python3, a signal) lets the tool call run. The wrapper therefore converts every
# outcome other than the logic's own 0 / 2 into exit 2 - unless the operator has chosen the documented
# fail-open setting LLMCTL_HOOK_ON_ERROR=allow. See docs/agents/ and llmctl_gate.py for the settings.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
agent=""
if [[ "${1:-}" == "--agent" ]]; then agent="${2:-}"; fi

case "${agent}" in
  claude-code|claude-code-prompt|crush|generic) ;;
  *) echo "llmctl gate: unknown or missing --agent (blocking)" >&2; exit 2 ;;
esac

# The stderr capture file is created with mktemp (random name, 0600, O_EXCL): a predictable name such as
# llmctl-gate.$$.err in a shared /tmp would let anyone pre-plant a symlink and make this hook truncate
# a victim file (C-17). If a private file cannot be created the outcome is the same fail-closed
# "unexpected" one as a crash of the gate logic.
out=""; rc=0; err=""
errf="$(mktemp "${TMPDIR:-/tmp}/llmctl-gate.XXXXXXXX" 2>/dev/null)" || errf=""
if [[ -z "${errf}" ]]; then
  rc=70; err="llmctl gate: cannot create a private temporary file in ${TMPDIR:-/tmp}"
else
  out="$(python3 "${here}/llmctl_gate.py" --agent "${agent}" 2>"${errf}")" || rc=$?
  err="$(cat "${errf}" 2>/dev/null)"; rm -f "${errf}"
fi

case "${rc}" in
  0|2)
    [[ -n "${out}" ]] && printf '%s\n' "${out}"
    [[ -n "${err}" ]] && printf '%s\n' "${err}" >&2
    exit "${rc}" ;;
esac

# unexpected outcome: crash, missing interpreter, signal ...
reason="the gate logic failed unexpectedly (status ${rc})"
[[ "${rc}" == 70 ]] && reason="${err}"
mode="${LLMCTL_HOOK_ON_ERROR:-escalate}"
if [[ "${agent}" == generic ]]; then
  case "${mode}" in allow) printf 'ALLOW\tFAIL-OPEN (LLMCTL_HOOK_ON_ERROR=allow): %s\n' "${reason}" ;;
    deny) printf 'DENY\t%s\n' "${reason}" ;; *) printf 'ESCALATE\t%s\n' "${reason}" ;; esac
  exit 0
fi
if [[ "${mode}" == allow ]]; then echo "llmctl gate: FAIL-OPEN: ${reason}" >&2; exit 0; fi
echo "llmctl gate: blocked: ${reason}" >&2
exit 2
