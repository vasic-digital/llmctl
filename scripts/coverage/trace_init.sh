#!/usr/bin/env bash
# trace_init.sh - BASH_ENV hook for the zero-tooling bash line-coverage tracer
# (Constitution 11.4.224(E)). NOT meant to be run directly: scripts/coverage/report.sh
# exports BASH_ENV=<this file> + LLMCTL_COV_FIFO=<fifo>, so every non-interactive
# bash process started by a test suite turns xtrace on and sends one
# `+COV:<cwd>:<source>:<line>:<cmd>` record per executed command to the FIFO.
# The trace goes to a private fd via BASH_XTRACEFD, so scripts that do
# `exec 2>/dev/null` cannot blind it and normal stdout/stderr are unchanged.
# Doing nothing when the FIFO variable is unset keeps stray inheritance harmless.
if [[ -n "${LLMCTL_COV_FIFO:-}" && -p "${LLMCTL_COV_FIFO}" ]]; then
  # brace-scoped so the side redirection never leaks into the caller shell (11.4.67(6))
  if { exec {LLMCTL_COV_FD}>>"${LLMCTL_COV_FIFO}"; } 2>/dev/null; then
    BASH_XTRACEFD="${LLMCTL_COV_FD}"
    PS4='+COV:${PWD}:${BASH_SOURCE[0]:-}:${LINENO}:'
    set -x
  fi
fi
