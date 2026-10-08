#!/usr/bin/env bash
# install_agents.sh - install (user-local, idempotent) the three coding agents llmctl's integration
# kit exercises but that are not on a stock host: aider, Continue CLI (`cn`), Cline CLI (`cline`),
# and report the headless capability of every supported agent.
#
# Purpose : OD-5 / T100 (specs/009-jev-decision-models). Official installers only, never as root,
#           every download recorded with package, version, source URL and a verified checksum.
# Usage   : scripts/install_agents.sh [--check] [--dry-run] [--only a,b] [--prefix DIR] [--bin DIR] [--log FILE]
#                                     [--lock FILE] [--write-lock]
#             (no flag)   install what is missing
#             --check     report installed / version / headless form for all seven agents; exit 1 when
#                         any selected agent is missing (read-only: runs only `--version` and `--help`)
#             --dry-run   print what would be done; no network, no writes
#             --only      comma list of: aider,cn,cline (install) or any of the seven (check)
#             --prefix    install root (default ~/.local/share/llmctl/agents)
#             --bin       shim directory (default ~/.local/bin)
#             --log       JSONL download record (default ~/.local/state/llmctl/agents-install.jsonl; pass
#                         specs/009-jev-decision-models/evidence/agents-install.jsonl to refresh the tracked evidence)
#             --lock      pin file (default scripts/agents.lock): "npm <pkg> <version> sha512-<b64>" and
#                         "pypi aider-chat <version> <wheel sha256>" lines; a pinned agent installs EXACTLY that
#                         version and the downloaded artifact must match the pinned digest
#             --write-lock  after a verified install, append the pin line for it to the lock file
# Env     : LLMCTL_AGENTS_NPM / LLMCTL_AGENTS_UV override the npm / uv executables (tests);
#           LLMCTL_AGENTS_PYPI_BASE the PyPI JSON base (default https://pypi.org/pypi, tests use file://);
#           LLMCTL_AGENTS_ALLOW_SCRIPTS=1 lets npm run lifecycle scripts (default: --ignore-scripts);
#           LLMCTL_AGENTS_ALLOW_UNVERIFIED=1 accepts an UNVERIFIED unpinned aider install (see Methods).
# Outputs : human lines on stdout; one JSON object per real install appended to the log.
# Exit    : 0 ok, 1 an agent missing (--check) or an install/verification failed, 2 usage.
# Methods : aider    the wheel PyPI publishes for the resolved version is downloaded, its sha256 compared with
#                    PyPI's digest (or the lock pin), and THAT SAME FILE is installed with
#                    `uv tool install --python 3.12 --with pip <wheel>` (aider.chat/docs/install.html) into
#                    UV_TOOL_DIR=<prefix>/aider. When no verified wheel can be had: a PINNED aider FAILS (exit 1, no
#                    fallback, nothing recorded); an unpinned one is refused too unless
#                    LLMCTL_AGENTS_ALLOW_UNVERIFIED=1, which installs `aider-chat@latest` and records
#                    method "...(UNVERIFIED...)", integrity_verified=false, integrity_source=none, pinned=false.
#           cn       `npm pack @continuedev/cli@<ver>` -> sha512 of the packed tarball compared with the
#                    registry integrity (or the lock pin) -> `npm install --ignore-scripts <that tarball>`
#           cline    the same for `cline`
#           LIMIT (C2-18): npm runs with --ignore-scripts (LLMCTL_AGENTS_ALLOW_SCRIPTS=1 lifts it). That skips
#           cline's postinstall, which only builds a startup-speed hard-link cache (bin/.cline); the platform
#           binary arrives as an optional dependency and works without it. The smoke after install is
#           `<bin> --version` AND `<bin> --help` (recorded as runtime_smoke "version+help"): this proves the
#           binary starts and parses arguments, NOT that a native module loaded lazily at first real use
#           (sqlite, pty, keytar) works. A headless run against the local gateway is the stronger check and
#           needs a live model, so it is not done here (see docs/scripts/install_agents.md).
#           A mismatch aborts that agent (no shim is written). integrity_verified=true therefore means: the
#           artifact that was INSTALLED is the one whose digest matched. The transitive dependency tree is
#           resolved by npm / uv at install time and is NOT pinned (dependency_tree_pinned=false in the record).
# Docs    : docs/scripts/install_agents.md, docs/agents/*.md
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${HOME}/.local/share/llmctl/agents"
BINDIR="${HOME}/.local/bin"
LOG="${XDG_STATE_HOME:-${HOME}/.local/state}/llmctl/agents-install.jsonl"
LOCK="${ROOT}/scripts/agents.lock"
WRITE_LOCK=0
PYPI_BASE="${LLMCTL_AGENTS_PYPI_BASE:-https://pypi.org/pypi}"
NPM="${LLMCTL_AGENTS_NPM:-npm}"
UV="${LLMCTL_AGENTS_UV:-uv}"
MODE=install DRY=0 ONLY=""
INSTALLABLE=(aider cn cline)
ALL=(opencode pi crush claude aider cn cline)

usage() { sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; /^set -uo/d' >&2; }
die2() { echo "install_agents: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE=check ;;
    --dry-run) DRY=1 ;;
    --only) [[ $# -ge 2 ]] || die2 "--only needs a value"; ONLY="$2"; shift ;;
    --prefix) [[ $# -ge 2 ]] || die2 "--prefix needs a value"; PREFIX="$2"; shift ;;
    --bin) [[ $# -ge 2 ]] || die2 "--bin needs a value"; BINDIR="$2"; shift ;;
    --log) [[ $# -ge 2 ]] || die2 "--log needs a value"; LOG="$2"; shift ;;
    --lock) [[ $# -ge 2 ]] || die2 "--lock needs a value"; LOCK="$2"; shift ;;
    --write-lock) WRITE_LOCK=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die2 "unknown argument: $1" ;;
  esac
  shift
done
[[ "$(id -u)" != 0 ]] || die2 "refusing to run as root (user-local installs only)"

selected=()
if [[ -n "${ONLY}" ]]; then
  IFS=, read -r -a want <<<"${ONLY}"
  pool=("${INSTALLABLE[@]}"); [[ "${MODE}" == check ]] && pool=("${ALL[@]}")
  for w in "${want[@]}"; do
    ok=0; for a in "${pool[@]}"; do [[ "${a}" == "${w}" ]] && ok=1; done
    [[ ${ok} == 1 ]] || die2 "unknown agent '${w}' (known: ${pool[*]})"
    selected+=("${w}")
  done
elif [[ "${MODE}" == check ]]; then selected=("${ALL[@]}"); else selected=("${INSTALLABLE[@]}"); fi

# _timeout <seconds> <cmd...>: C3-10. GNU `timeout` is not on a stock macOS: use it, else `gtimeout` (coreutils from
# Homebrew), else a perl alarm (perl ships with macOS and every Linux); with none of them the probe runs UNBOUNDED and
# that is said once, up front - never a silent "timeout: command not found" that turns into an empty version or a
# misleading "lifecycle scripts were skipped" refusal. The mode is chosen once here (not inside a $(...) subshell).
if command -v timeout >/dev/null 2>&1; then TIMEOUT_MODE=timeout
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_MODE=gtimeout
elif command -v perl >/dev/null 2>&1; then TIMEOUT_MODE=perl
else
  TIMEOUT_MODE=none
  echo "install_agents: no timeout, gtimeout or perl on PATH: version/help probes run WITHOUT a time limit" >&2
fi
_timeout() {
  local secs="$1"; shift
  case "${TIMEOUT_MODE}" in
    timeout) timeout "${secs}" "$@" ;;
    gtimeout) gtimeout "${secs}" "$@" ;;
    # perl: fork + alarm in the PARENT, so a timeout is an ordinary exit 124 (an exec'd child killed by SIGALRM would make
    # the shell print "Alarm clock" into the captured output); the child leads its own process group, which is the
    # group killed, so a probe's own children cannot keep the output pipe open
    perl) perl -e 'my $s = shift @ARGV; my $pid = fork(); defined $pid or exit 127; if (!$pid) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV; exit 127 }
                   $SIG{ALRM} = sub { kill "KILL", -$pid; kill "KILL", $pid; waitpid($pid, 0); exit 124 }; alarm $s; waitpid($pid, 0);
                   exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "${secs}" "$@" ;;
    *) "$@" ;;
  esac
}
CHECK_TIMEOUT="${LLMCTL_AGENTS_CHECK_TIMEOUT:-20}"

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

# agent_cmd <name>: the executable to run for an agent (the shim dir first, then PATH).
agent_cmd() {
  if [[ -x "${BINDIR}/$1" ]]; then echo "${BINDIR}/$1"; elif command -v "$1" >/dev/null 2>&1; then command -v "$1"; fi
}

# headless_form <name> <help-text>: the non-interactive form found in --help, else "unknown".
headless_form() {
  local n="$1" h="$2"
  case "${n}" in
    aider) grep -q -- '--message' <<<"${h}" && echo "aider --message TEXT --yes-always" || echo unknown ;;
    cn) if grep -q -- '--print\|-p,' <<<"${h}"; then echo "cn -p TEXT"; else echo unknown; fi ;;
    cline) if grep -q -- '--yolo\|-y,' <<<"${h}"; then echo "cline -y TEXT"; else echo unknown; fi ;;
    opencode) grep -q '^ *opencode run\|run \[message' <<<"${h}" && echo "opencode run TEXT" || echo unknown ;;
    pi) grep -q -- '--print\|-p,' <<<"${h}" && echo "pi -p TEXT" || echo unknown ;;
    crush) grep -q ' run' <<<"${h}" && echo "crush run TEXT" || echo unknown ;;
    claude) grep -q -- '--print\|-p,' <<<"${h}" && echo "claude -p TEXT" || echo unknown ;;
  esac
}

do_check() {
  local missing=0 a cmd ver help hl
  for a in "${selected[@]}"; do
    cmd="$(agent_cmd "${a}")"
    if [[ -z "${cmd}" ]]; then echo "${a} installed=no version=- headless=-"; missing=1; continue; fi
    ver="$(_timeout "${CHECK_TIMEOUT}" "${cmd}" --version 2>&1 </dev/null | head -n1 | tr -d '\r')"
    help="$(_timeout "${CHECK_TIMEOUT}" "${cmd}" --help 2>&1 </dev/null || true)"
    hl="$(headless_form "${a}" "${help}")"
    echo "${a} installed=yes version=${ver:--} headless=${hl} path=${cmd}"
  done
  return ${missing}
}

record() { # record <json-object>
  mkdir -p "$(dirname "${LOG}")" && printf '%s\n' "$1" >>"${LOG}"
}

write_shim() { # write_shim <name> <target>
  mkdir -p "${BINDIR}"
  printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$2" >"${BINDIR}/$1.tmp.$$" && chmod +x "${BINDIR}/$1.tmp.$$" && mv -f "${BINDIR}/$1.tmp.$$" "${BINDIR}/$1"
}

# b64() - portable one-line base64 of stdin (the GNU-only wrap flag of base64 does not exist on macOS).
b64() { openssl base64 -A; }

# lock_get <kind> <package> -> "<version> <digest>" from the lock file, or nothing.
lock_get() {
  [[ -f "${LOCK}" ]] || return 0
  awk -v k="$1" -v p="$2" '$1==k && $2==p && $1 !~ /^#/ {print $3, $4; exit}' "${LOCK}"
}

lock_put() { # lock_put <kind> <package> <version> <digest>
  [[ ${WRITE_LOCK} == 1 ]] || return 0
  [[ -n "$(lock_get "$1" "$2")" ]] && return 0
  mkdir -p "$(dirname "${LOCK}")" && printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >>"${LOCK}"
  echo "$2: pinned $3 in ${LOCK}"
}

install_npm() { # install_npm <name> <package> <bin>
  local name="$1" pkg="$2" bin="$3" dir ver tar integ got ok=false pinned=false pk pd tmp tgz smoke_help smoke_rc scripts_flag="--ignore-scripts"
  dir="${PREFIX}/${name}"
  if [[ -x "${BINDIR}/${bin}" ]]; then echo "${name}: already installed (${BINDIR}/${bin})"; return 0; fi
  if [[ ${DRY} == 1 ]]; then echo "${name}: would install ${pkg} with npm into ${dir} and write shim ${BINDIR}/${bin}"; return 0; fi
  [[ "${LLMCTL_AGENTS_ALLOW_SCRIPTS:-0}" == 1 ]] && scripts_flag="--ignore-scripts=false"
  read -r pk pd <<<"$(lock_get npm "${pkg}")"
  if [[ -n "${pk}" ]]; then
    ver="${pk}"; integ="${pd}"; pinned=true
    [[ "${integ}" == sha512-* ]] || { echo "${name}: ${LOCK}: the pin for ${pkg} carries no sha512 digest" >&2; return 1; }
  else
    ver="$("${NPM}" view "${pkg}" version 2>/dev/null)" || { echo "${name}: cannot resolve ${pkg} version" >&2; return 1; }
    integ="$("${NPM}" view "${pkg}@${ver}" dist.integrity 2>/dev/null)"
    if [[ "${integ}" != sha512-* ]]; then
      echo "${name}: the registry published no sha512 integrity for ${pkg}@${ver}; refusing to install unverified" >&2; return 1
    fi
  fi
  tar="$("${NPM}" view "${pkg}@${ver}" dist.tarball 2>/dev/null || true)"
  # Download the tarball ONCE (npm pack), verify THAT file, install THAT file: the digest then
  # describes the artifact that is actually installed (a second independent download proved
  # nothing about what npm installed).
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctl-agent.XXXXXX")" || return 1
  if ! "${NPM}" pack "${pkg}@${ver}" --pack-destination "${tmp}" >"${tmp}/pack.out" 2>&1; then
    echo "${name}: npm pack ${pkg}@${ver} failed" >&2; rm -rf "${tmp}"; return 1
  fi
  tgz="${tmp}/$(tail -n1 "${tmp}/pack.out" | tr -d '\r')"
  [[ -f "${tgz}" ]] || { echo "${name}: npm pack produced no tarball" >&2; rm -rf "${tmp}"; return 1; }
  got="sha512-$(openssl dgst -sha512 -binary "${tgz}" | b64)"
  if [[ "${got}" != "${integ}" ]]; then
    echo "${name}: integrity mismatch for ${pkg}@${ver} ($([[ ${pinned} == true ]] && echo "lock pin" || echo registry) ${integ:0:24}..., downloaded ${got:0:24}...); not installing" >&2
    rm -rf "${tmp}"; return 1
  fi
  ok=true
  mkdir -p "${dir}"
  "${NPM}" install --prefix "${dir}" --no-audit --no-fund "${scripts_flag}" "${tgz}" >"${dir}/install.log" 2>&1 \
    || { echo "${name}: npm install failed (see ${dir}/install.log)" >&2; rm -rf "${tmp}"; return 1; }
  rm -rf "${tmp}"
  [[ -x "${dir}/node_modules/.bin/${bin}" ]] || { echo "${name}: ${bin} missing after install" >&2; return 1; }
  if ! _timeout 30 "${dir}/node_modules/.bin/${bin}" --version >/dev/null 2>&1 </dev/null; then
    echo "${name}: the installed ${bin} does not start ($( [[ "${scripts_flag}" == "--ignore-scripts" ]] && echo "lifecycle scripts were skipped; retry with LLMCTL_AGENTS_ALLOW_SCRIPTS=1" || echo "see ${dir}/install.log"))" >&2
    return 1
  fi
  # second smoke: --help must also run (argument parsing + module graph load), offline. C3-09: it must EXIT 0 and print
  # something on STDOUT. Judging merged stderr (and ignoring the status) accepted a crash such as "Error: Cannot find
  # module better-sqlite3" - exactly the lazily-loaded-native-module failure this smoke exists to catch.
  smoke_rc=0
  smoke_help="$(_timeout 30 "${dir}/node_modules/.bin/${bin}" --help 2>/dev/null </dev/null)" || smoke_rc=$?
  if [[ ${smoke_rc} -ne 0 ]]; then
    echo "${name}: the installed ${bin} --help exited ${smoke_rc} (it crashed or timed out); not writing a shim" >&2
    return 1
  fi
  if [[ -z "${smoke_help}" ]]; then
    echo "${name}: the installed ${bin} printed nothing for --help; not writing a shim" >&2
    return 1
  fi
  write_shim "${bin}" "${dir}/node_modules/.bin/${bin}"
  record "{\"ts\":\"$(date -u +%FT%TZ)\",\"agent\":\"${name}\",\"method\":\"npm pack + install of the verified tarball\",\"package\":$(json_escape "${pkg}"),\"version\":\"${ver}\",\"source_url\":$(json_escape "${tar}"),\"sha512_integrity\":$(json_escape "${integ}"),\"integrity_verified\":${ok},\"integrity_source\":\"$([[ ${pinned} == true ]] && echo lock || echo registry)\",\"pinned\":${pinned},\"dependency_tree_pinned\":false,\"lifecycle_scripts\":$([[ "${scripts_flag}" == "--ignore-scripts" ]] && echo '"skipped"' || echo '"run"'),\"runtime_smoke\":\"version+help (exit 0, non-empty stdout)\",\"prefix\":$(json_escape "${dir}")}"
  lock_put npm "${pkg}" "${ver}" "${integ}"
  echo "${name}: installed ${pkg}@${ver} (tarball integrity verified$([[ ${pinned} == true ]] && echo ", pinned"), dependency tree not pinned)"
}

install_aider() {
  local dir="${PREFIX}/aider" ver="" url="" sha="" ok=false pinned=false pk pd tmp wheel got js jsurl
  local method="uv tool install of the verified wheel" src_label=""
  if [[ -x "${BINDIR}/aider" ]]; then echo "aider: already installed (${BINDIR}/aider)"; return 0; fi
  if [[ ${DRY} == 1 ]]; then echo "aider: would install aider-chat with uv (python 3.12) into ${dir} and write shim ${BINDIR}/aider"; return 0; fi
  mkdir -p "${dir}/tools" "${dir}/bin"
  read -r pk pd <<<"$(lock_get pypi aider-chat)"
  if [[ -n "${pk}" ]]; then jsurl="${PYPI_BASE}/aider-chat/${pk}/json"; pinned=true; else jsurl="${PYPI_BASE}/aider-chat/json"; fi
  js="$(curl -fsSL "${jsurl}" 2>/dev/null || true)"
  if [[ -n "${js}" ]]; then
    # the wheel PyPI publishes for the resolved version: url + its sha256 digest + version
    read -r ver url sha < <(python3 -c '
import json, sys
d = json.load(sys.stdin)
v = d["info"]["version"]
w = [u for u in d["urls"] if u["packagetype"] == "bdist_wheel" and u["filename"].endswith("py3-none-any.whl")] \
    or [u for u in d["urls"] if u["packagetype"] == "bdist_wheel"]
print(v, w[0]["url"], w[0]["digests"]["sha256"])' <<<"${js}" 2>/dev/null) || true
  fi
  [[ ${pinned} == true && -n "${ver}" && "${ver}" != "${pk}" ]] && { echo "aider: the pinned version ${pk} resolved to ${ver}; refusing" >&2; return 1; }
  if [[ -n "${url}" && -n "${sha}" ]]; then
    [[ ${pinned} == true && "${pd}" != "${sha}" ]] && { echo "aider: the lock pin digest ${pd:0:16} differs from PyPI's ${sha:0:16} for ${ver}; refusing" >&2; return 1; }
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctl-agent.XXXXXX")" || return 1
    wheel="${tmp}/$(basename "${url%%\?*}")"
    if ! curl -fsSL -o "${wheel}" "${url}" 2>/dev/null; then echo "aider: cannot download ${url}" >&2; rm -rf "${tmp}"; return 1; fi
    got="$(openssl dgst -sha256 "${wheel}" | awk '{print $NF}')"
    if [[ "${got}" != "${sha}" ]]; then echo "aider: wheel sha256 mismatch (pypi ${sha:0:16}, downloaded ${got:0:16}); not installing" >&2; rm -rf "${tmp}"; return 1; fi
    ok=true
    # install THE verified file (not a name uv resolves for itself)
    UV_TOOL_DIR="${dir}/tools" UV_TOOL_BIN_DIR="${dir}/bin" "${UV}" tool install --force --python 3.12 --with pip "${wheel}" \
      >"${dir}/install.log" 2>&1 || { echo "aider: uv tool install failed (see ${dir}/install.log)" >&2; rm -rf "${tmp}"; return 1; }
    rm -rf "${tmp}"
  elif [[ ${pinned} == true ]]; then
    # C2-02: a pin is a promise. If its verified wheel cannot be had, FAIL CLOSED - never fall back to latest.
    echo "aider: the pinned aider-chat ${pk} cannot be verified (PyPI metadata/wheel unavailable or unparseable); refusing to install - a pinned install never falls back to aider-chat@latest" >&2
    return 1
  elif [[ "${LLMCTL_AGENTS_ALLOW_UNVERIFIED:-0}" != 1 ]]; then
    echo "aider: no verifiable wheel (PyPI metadata unreachable); refusing to install aider-chat@latest unverified. Set LLMCTL_AGENTS_ALLOW_UNVERIFIED=1 to accept an UNVERIFIED install (recorded as such)." >&2
    return 1
  else
    method="uv tool install aider-chat@latest (UNVERIFIED: no wheel digest was checked)"
    src_label=none
    echo "aider: no verifiable wheel (PyPI metadata unreachable); installing aider-chat@latest UNVERIFIED (LLMCTL_AGENTS_ALLOW_UNVERIFIED=1)" >&2
    UV_TOOL_DIR="${dir}/tools" UV_TOOL_BIN_DIR="${dir}/bin" "${UV}" tool install --force --python 3.12 --with pip aider-chat@latest \
      >"${dir}/install.log" 2>&1 || { echo "aider: uv tool install failed (see ${dir}/install.log)" >&2; return 1; }
  fi
  [[ -x "${dir}/bin/aider" ]] || { echo "aider: binary missing after install" >&2; return 1; }
  # C3-09: the smoke runs on EVERY path (verified wheel and unverified alike): --version must exit 0 with stdout.
  local avout arc=0
  avout="$(_timeout 30 "${dir}/bin/aider" --version 2>/dev/null </dev/null)" || arc=$?
  if [[ ${arc} -ne 0 || -z "${avout}" ]]; then
    echo "aider: the installed aider --version failed (exit ${arc}$([[ -z "${avout}" ]] && echo ", no output")); not writing a shim" >&2
    return 1
  fi
  [[ -n "${ver}" ]] || ver="$(printf '%s\n' "${avout}" | grep -Eo '[0-9]+(\.[0-9]+)+' | head -n1)"
  write_shim aider "${dir}/bin/aider"
  record "{\"ts\":\"$(date -u +%FT%TZ)\",\"agent\":\"aider\",\"method\":$(json_escape "${method}"),\"package\":\"aider-chat\",\"version\":$(json_escape "${ver}"),\"python\":\"managed 3.12 (uv may download it)\",\"source_url\":$(json_escape "${url}"),\"sha256\":$(json_escape "${sha}"),\"integrity_verified\":${ok},\"integrity_source\":\"${src_label:-$([[ ${pinned} == true ]] && echo lock || echo pypi)}\",\"pinned\":${pinned},\"dependency_tree_pinned\":false,\"runtime_smoke\":\"version (aider --version, exit 0, non-empty stdout)\",\"prefix\":$(json_escape "${dir}")}"
  [[ ${ok} == true ]] && lock_put pypi aider-chat "${ver}" "${sha}"
  echo "aider: installed ${ver} (wheel sha256 verified=${ok}, dependency tree not pinned)"
}

if [[ "${MODE}" == check ]]; then do_check; exit $?; fi

rc=0
for a in "${selected[@]}"; do
  case "${a}" in
    aider) install_aider || rc=1 ;;
    cn) install_npm cn @continuedev/cli cn || rc=1 ;;
    cline) install_npm cline cline cline || rc=1 ;;
  esac
done
exit ${rc}
