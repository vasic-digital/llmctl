#!/usr/bin/env bash
# common.sh - shared logging, colors, die(), XDG-aware paths for llmctl.
# This file is sourced by bin/llmctl and other libs; it must stay POSIX-bash
# portable (Linux + macOS, bash >= 3.2).
set -euo pipefail

# ---------------------------------------------------------------------------
# Root of the llmctl installation (directory containing bin/ and lib/).
# ---------------------------------------------------------------------------
if [[ -z "${LLMCTL_ROOT:-}" ]]; then
  _llmctl_common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LLMCTL_ROOT="$(cd "${_llmctl_common_dir}/.." && pwd)"
  unset _llmctl_common_dir
fi
export LLMCTL_ROOT

# ---------------------------------------------------------------------------
# XDG-aware directories. All overridable for tests.
# ---------------------------------------------------------------------------
: "${XDG_CONFIG_HOME:=${HOME}/.config}"
: "${XDG_DATA_HOME:=${HOME}/.local/share}"
: "${XDG_STATE_HOME:=${HOME}/.local/state}"

LLMCTL_CONFIG_DIR="${LLMCTL_CONFIG_DIR:-${XDG_CONFIG_HOME}/llmctl}"
LLMCTL_DATA_DIR="${LLMCTL_DATA_DIR:-${XDG_DATA_HOME}/llmctl}"
LLMCTL_STATE_DIR="${LLMCTL_STATE_DIR:-${XDG_STATE_HOME}/llmctl}"
# Runtime dir for reservations/pids; fall back to state dir when
# XDG_RUNTIME_DIR is unset (macOS, containers).
if [[ -n "${XDG_RUNTIME_DIR:-}" && -d "${XDG_RUNTIME_DIR}" ]]; then
  LLMCTL_RUNTIME_DIR="${LLMCTL_RUNTIME_DIR:-${XDG_RUNTIME_DIR}/llmctl}"
else
  LLMCTL_RUNTIME_DIR="${LLMCTL_RUNTIME_DIR:-${LLMCTL_STATE_DIR}/run}"
fi
LLMCTL_MODELS_DIR="${LLMCTL_MODELS_DIR:-${LLMCTL_DATA_DIR}/models}"
LLMCTL_LOG_DIR="${LLMCTL_LOG_DIR:-${LLMCTL_STATE_DIR}/logs}"
LLMCTL_VERIFY_DIR="${LLMCTL_VERIFY_DIR:-${LLMCTL_STATE_DIR}/verify}"
LLMCTL_SERVICES_DIR="${LLMCTL_SERVICES_DIR:-${LLMCTL_STATE_DIR}/services}"

export LLMCTL_CONFIG_DIR LLMCTL_DATA_DIR LLMCTL_STATE_DIR LLMCTL_RUNTIME_DIR
export LLMCTL_MODELS_DIR LLMCTL_LOG_DIR LLMCTL_VERIFY_DIR LLMCTL_SERVICES_DIR

# Catalog location.
LLMCTL_CATALOG="${LLMCTL_CATALOG:-${LLMCTL_ROOT}/models/catalog.json}"

# Dry-run switch: service/scheduler side effects are printed, not executed.
LLMCTL_DRY_RUN="${LLMCTL_DRY_RUN:-0}"

# Engine bind host (opt-in override, ${VAR:-default}-style, same convention
# as LLMCTL_LLAMA_SERVER / LLMCTL_COLI_BIN / LLMCTL_DRY_RUN). Consumed by
# lib/catalog.sh's catalog_bind_host() - see that file's header comment for
# the per-profile override mechanism (LLMCTL_BIND_HOST_<PROFILE>).
#
# Defaults to 0.0.0.0 (LAN-accessible) per explicit operator mandate
# ("Everything must be fully accessible from local network") - NOT the
# conservative localhost-only choice a security-first default would pick.
# HONEST TRADE-OFF (Constitution anti-bluff covenant - this MUST be stated,
# never silently shipped): llama-server's OpenAI-compatible API has no
# built-in authentication. Binding to 0.0.0.0 means ANY device that can
# reach this host's LAN interface can call the API - consume GPU/model
# resources, read chat completions, or exhaust context/VRAM - with ZERO
# auth. This is safe on a trusted home/office LAN behind a NAT/firewall
# with no untrusted peers; it is NOT safe on a shared, guest, corporate, or
# otherwise untrusted network segment. Operators on such a network MUST
# either set LLMCTL_BIND_HOST=127.0.0.1 (reverts to localhost-only,
# globally) or LLMCTL_BIND_HOST_<PROFILE>=127.0.0.1 (per-profile, e.g.
# LLMCTL_BIND_HOST_FAST=127.0.0.1) BEFORE enabling/starting a profile, or
# scope reachability at the firewall/VLAN layer instead. See README.md
# "Safety guarantees" for the full disclosure.
#
# lib/download.sh's one-shot smoke-test launch is DELIBERATELY exempt from
# this variable - it is an ephemeral, localhost-only verification step
# during model download that never needs to be LAN-reachable, and stays
# hardcoded to 127.0.0.1 regardless of this setting.
LLMCTL_BIND_HOST="${LLMCTL_BIND_HOST:-0.0.0.0}"

# ---------------------------------------------------------------------------
# Colors (disabled when not a tty or NO_COLOR is set).
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  LLMCTL_C_RESET=$'\033[0m'
  LLMCTL_C_RED=$'\033[31m'
  LLMCTL_C_GREEN=$'\033[32m'
  LLMCTL_C_YELLOW=$'\033[33m'
  LLMCTL_C_BLUE=$'\033[34m'
  LLMCTL_C_BOLD=$'\033[1m'
else
  LLMCTL_C_RESET="" LLMCTL_C_RED="" LLMCTL_C_GREEN=""
  LLMCTL_C_YELLOW="" LLMCTL_C_BLUE="" LLMCTL_C_BOLD=""
fi

log()  { printf '%s[llmctl]%s %s\n' "${LLMCTL_C_BLUE}" "${LLMCTL_C_RESET}" "$*"; }
info() { printf '%s%s%s\n' "${LLMCTL_C_GREEN}" "$*" "${LLMCTL_C_RESET}"; }
warn() { printf '%sWARN:%s %s\n' "${LLMCTL_C_YELLOW}" "${LLMCTL_C_RESET}" "$*" >&2; }
err()  { printf '%sERROR:%s %s\n' "${LLMCTL_C_RED}" "${LLMCTL_C_RESET}" "$*" >&2; }
die()  { err "$*"; exit 1; }

bold() { printf '%s%s%s\n' "${LLMCTL_C_BOLD}" "$*" "${LLMCTL_C_RESET}"; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
need_cmd() {
  # need_cmd <cmd> [hint]
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found.${2:+ Install hint: $2}"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_dir() { mkdir -p "$1"; }

ensure_state_dirs() {
  ensure_dir "${LLMCTL_STATE_DIR}"
  ensure_dir "${LLMCTL_RUNTIME_DIR}"
  ensure_dir "${LLMCTL_LOG_DIR}"
  ensure_dir "${LLMCTL_VERIFY_DIR}"
  ensure_dir "${LLMCTL_SERVICES_DIR}"
  ensure_dir "${LLMCTL_MODELS_DIR}"
}

# json_query <json-file> <python-expression-over-data> ...
# Thin, auditable wrapper around python3 for JSON work. The expression gets
# the parsed document as `d`. Exits non-zero on any JSON error.
json_query() {
  local file="$1"; shift
  need_cmd python3 "install python3 via your package manager"
  python3 - "$file" "$@" <<'PYEOF'
import json, sys
path = sys.argv[1]
expr = sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as fh:
        d = json.load(fh)
except Exception as exc:  # noqa: BLE001 - report any parse/io failure
    sys.stderr.write("json_query: cannot parse %s: %s\n" % (path, exc))
    sys.exit(2)
try:
    result = eval(expr, {"__builtins__": __builtins__}, {"d": d})  # noqa: S307 - trusted local expr
except Exception as exc:  # noqa: BLE001
    sys.stderr.write("json_query: expression failed on %s: %s\n" % (path, exc))
    sys.exit(3)
if isinstance(result, bool):
    print("True" if result else "False")
    sys.exit(0 if result else 1)
if result is None:
    sys.exit(0)
if isinstance(result, (list, tuple)):
    for item in result:
        print(item)
else:
    print(result)
PYEOF
}

# json_body <key=value> [key=value ...] [key[]=value ...]
# 006-cli-daemon-wiring: safely builds a single-level JSON object from
# key=value pairs for the seven newly-wired cluster/tenant/apikey
# subcommands' request bodies, via the SAME auditable python3 wrapper
# json_query/json_stdin already use for JSON work in this codebase -
# never raw string interpolation into a JSON literal, so a value
# containing a quote or backslash (a peer address, a tenant name, ...)
# can never break out of its JSON string context or inject a sibling
# field. A value matching a bare integer or float is encoded as a JSON
# number (the daemon's tenancy.Limits fields are numeric, per
# data-model.md's wire shape); every other value is encoded as a JSON
# string. A key written as "key[]" (e.g. "scopes[]=admin") is always
# encoded as a JSON array, appending one element per occurrence - the
# daemon's []string-typed fields (e.g. createAPIKeyRequest.Scopes)
# reject a bare string, so a single-element array still needs the "[]"
# marker even with only one value.
json_body() {
  need_cmd python3 "install python3 via your package manager"
  python3 - "$@" <<'PYEOF'
import json, re, sys

_num_re = re.compile(r'^-?[0-9]+(\.[0-9]+)?$')

def coerce(value):
    if _num_re.match(value):
        return float(value) if "." in value else int(value)
    return value

out = {}
for arg in sys.argv[1:]:
    key, sep, value = arg.partition("=")
    if not sep:
        sys.stderr.write("json_body: argument %r is not key=value\n" % arg)
        sys.exit(2)
    if key.endswith("[]"):
        key = key[:-2]
        out.setdefault(key, [])
        if not isinstance(out[key], list):
            sys.stderr.write("json_body: key %r used both as a scalar and as an array\n" % key)
            sys.exit(2)
        out[key].append(coerce(value))
    else:
        out[key] = coerce(value)
print(json.dumps(out))
PYEOF
}

# json_stdin <python-expression>  -- read JSON document from stdin as `d`.
json_stdin() {
  need_cmd python3 "install python3 via your package manager"
  python3 -c '
import json, sys
expr = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception as exc:
    sys.stderr.write("json_stdin: cannot parse stdin JSON: %s\n" % exc)
    sys.exit(2)
result = eval(expr, {"__builtins__": __builtins__}, {"d": d})
if isinstance(result, bool):
    print("True" if result else "False")
    sys.exit(0 if result else 1)
if result is None:
    sys.exit(0)
if isinstance(result, (list, tuple)):
    for item in result:
        print(item)
else:
    print(result)
' "$1"
}

# mib <bytes> -> whole MiB
mib() { echo $(( $1 / 1048576 )); }

# ceil_div <a> <b>
ceil_div() { echo $(( ($1 + $2 - 1) / $2 )); }
