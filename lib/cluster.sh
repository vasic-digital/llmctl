#!/usr/bin/env bash
# cluster.sh - thin HTTP client for the opt-in llmctld cluster daemon.
#
# Single-host llmctl usage never sources or calls into this file's behavior.
# When cluster mode IS enabled, llmctl becomes a thin client to llmctld: this
# module owns the ONLY code path that talks to it, and it MUST hard-fail
# (never silently fall back to single-host scheduling) when the daemon is
# unreachable - a silent fallback would misrepresent which mode actually
# served the request.
set -euo pipefail

_cluster_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_cluster_dir}/common.sh"

LLMCTL_CLUSTER_ENDPOINT="${LLMCTL_CLUSTER_ENDPOINT:-https://127.0.0.1:9443}"

# Cached (per-process) result of the curl HTTP/3 capability probe, so a
# script issuing many cluster::request calls only pays for `curl --version`
# once. Values: "" (unknown/not probed yet), "1" (supported), "0" (not).
_CLUSTER_HTTP3_SUPPORTED=""

_cluster_http3_supported() {
  if [[ -z "${_CLUSTER_HTTP3_SUPPORTED}" ]]; then
    if curl --version 2>/dev/null | grep -qiE '(^| )HTTP3( |$)'; then
      _CLUSTER_HTTP3_SUPPORTED=1
    else
      _CLUSTER_HTTP3_SUPPORTED=0
    fi
  fi
  [[ "${_CLUSTER_HTTP3_SUPPORTED}" == "1" ]]
}

# cluster::request <method> <path> [json-body]
# Issues one HTTP request to llmctld's API. Opportunistically uses HTTP/3
# when the local curl build supports it (verified via _cluster_http3_supported,
# never assumed); otherwise falls back to plain HTTP/2, which llmctld always
# serves dual-stack alongside HTTP/3 for exactly this reason.
# Prints the response body on success; returns curl's exit code on failure
# (connection refused, timeout, TLS error, etc.) so callers can distinguish
# "daemon unreachable" from "daemon returned an error status".
cluster::request() {
  local method="$1" path="$2" body="${3:-}"
  local -a curl_args=(
    -sS --max-time 5
    -X "${method}" "${LLMCTL_CLUSTER_ENDPOINT}${path}"
    -H 'Content-Type: application/json'
  )
  _cluster_http3_supported && curl_args+=(--http3)
  [[ -n "${LLMCTL_CLUSTER_TOKEN:-}" ]] && curl_args+=(-H "Authorization: Bearer ${LLMCTL_CLUSTER_TOKEN}")
  [[ -n "${body}" ]] && curl_args+=(-d "${body}")
  curl "${curl_args[@]}"
}

# cluster::request_checked <method> <path> [json-body]
# Additive sibling of cluster::request (006-cli-daemon-wiring research.md
# R3): cluster::request itself is NEVER modified by this function - its
# one existing caller (`cluster status`) keeps its exact pre-existing
# output/exit-code contract, byte for byte.
#
# cluster::request_checked closes a genuine gap cluster::request leaves
# open: curl's own exit code only reflects TRANSPORT-level failure
# (connection refused, timeout, TLS error, ...) - a 4xx/5xx HTTP
# response is still curl exit 0, with the daemon's own error JSON body
# printed as if it were a success body. Every non-2xx-capable route this
# feature wires (join's peer-addr validation can 400, apikey rotate's
# ownership check can 403, tenant quota's nonexistent-tenant check can
# 404) needs its caller to tell that apart from "the daemon is
# unreachable", per spec.md's Edge Cases.
#
# Captures the HTTP status via curl's own -w trailer, splits it from the
# body, and returns three distinguishable outcomes:
#   - transport failure (connection refused/timeout/TLS error/etc.):
#     curl's own non-zero exit code passed straight through, unchanged -
#     identical to cluster::request's existing behavior, so
#     cluster::require_daemon-style reachability handling keeps working
#     unmodified.
#   - reachable, 2xx status: prints the body to stdout, returns 0.
#   - reachable, non-2xx status: prints the body (the daemon's own
#     {"error": "..."} JSON) to stdout, returns 1 - the caller reports
#     the daemon's real error message rather than guessing one.
cluster::request_checked() {
  local method="$1" path="$2" body="${3:-}"
  local -a curl_args=(
    -sS --max-time 5
    -w '\n%{http_code}'
    -X "${method}" "${LLMCTL_CLUSTER_ENDPOINT}${path}"
    -H 'Content-Type: application/json'
  )
  _cluster_http3_supported && curl_args+=(--http3)
  [[ -n "${LLMCTL_CLUSTER_TOKEN:-}" ]] && curl_args+=(-H "Authorization: Bearer ${LLMCTL_CLUSTER_TOKEN}")
  [[ -n "${body}" ]] && curl_args+=(-d "${body}")

  local raw
  raw="$(curl "${curl_args[@]}")" || return $?

  local resp_body="${raw%$'\n'*}"
  local status="${raw##*$'\n'}"
  printf '%s\n' "${resp_body}"
  [[ "${status}" =~ ^2[0-9][0-9]$ ]]
}

# cluster::require_daemon
# Hard-fails (never a silent fallback to single-host scheduling) unless
# llmctld answers its own status endpoint. Every cluster-mode subcommand
# MUST call this before doing anything else.
cluster::require_daemon() {
  if cluster::request GET /v1/cluster/status >/dev/null 2>&1; then
    return 0
  fi
  die "llmctld unreachable at ${LLMCTL_CLUSTER_ENDPOINT} - cluster mode requires the daemon to be running.
  Start it with:
    Linux:  systemctl --user start llmctld
    macOS:  launchctl load ~/Library/LaunchAgents/com.llmctl.llmctld.plist
  llmctl never falls back to single-host scheduling when cluster mode is
  configured but the daemon is unreachable (anti-bluff: a silent fallback
  would misrepresent which mode actually served the request)."
}
