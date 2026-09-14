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
