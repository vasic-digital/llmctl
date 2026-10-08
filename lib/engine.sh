#!/usr/bin/env bash
# engine.sh - build llama.cpp and colibri from the pinned submodules/ git
# submodules (submodules/llama.cpp, submodules/colibri - see .gitmodules).
#
# Backend auto-detection:
#   * nvcc on PATH            -> GGML_CUDA=ON  (Linux)
#   * macOS                   -> Metal is ON by default upstream, nothing to add
#   * ROCm (rocm-smi or
#     /opt/rocm present)      -> GGML_HIP=ON
#   * otherwise               -> CPU build, GGML_NATIVE=ON (host-native
#                                optimization; this is the default, kept
#                                explicitly for clarity)
set -euo pipefail

_eng_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${_eng_dir}/common.sh"
# shellcheck source=os_detect.sh
source "${_eng_dir}/os_detect.sh"

LLMCTL_LLAMA_SRC="${LLMCTL_ROOT}/submodules/llama.cpp"
LLMCTL_COLIBRI_SRC="${LLMCTL_ROOT}/submodules/colibri"

engine_llama_server_bin() {
  echo "${LLMCTL_LLAMA_SRC}/build/bin/llama-server"
}

engine_ensure_submodules() {
  need_cmd git
  local missing=0 m
  for m in submodules/llama.cpp submodules/colibri; do
    if [[ ! -e "${LLMCTL_ROOT}/${m}/.git" ]]; then
      warn "submodule ${m} not initialized"
      missing=1
    fi
  done
  if [[ "${missing}" == "1" ]]; then
    log "initializing submodules (git submodule update --init)"
    git -C "${LLMCTL_ROOT}" submodule update --init --recursive
  fi
}

# echo the llama.cpp backend that would be selected on this host.
engine_detect_backend() {
  local os; os="$(llmctl_os)"
  if [[ "${os}" == "macos" ]]; then
    echo "metal"
  elif have_cmd nvcc || [[ -x /usr/local/cuda/bin/nvcc ]]; then
    echo "cuda"
  elif have_cmd rocm-smi || [[ -d /opt/rocm ]]; then
    echo "rocm"
  else
    echo "cpu"
  fi
}

# engine_jobs_for <backend> <ncpu> <mem_available_kib|unknown> [override] - how many compile jobs are SAFE.
# A CUDA/ROCm translation unit needs ~2 GiB, a CPU one ~1 GiB; 4 GiB stay reserved for the rest of the host
# (the 60 % memory ceiling and build-concurrency rules of the constitution: cores alone are not a budget).
# Never below 1, never above the core count; an explicit override can lower the count, never raise it
# above the memory-safe one. Unknown memory (no /proc/meminfo, e.g. macOS) is capped at min(cores, 4).
engine_jobs_for() {
  local backend="$1" ncpu="$2" mem="$3" override="${4:-}"
  local per=1048576 reserve=4194304 safe
  case "${backend}" in cuda|rocm) per=2097152 ;; esac
  [[ "${ncpu}" =~ ^[0-9]+$ && "${ncpu}" -ge 1 ]] || ncpu=1
  if [[ "${mem}" =~ ^[0-9]+$ ]]; then
    if (( mem > reserve )); then safe=$(( (mem - reserve) / per )); else safe=1; fi
  else
    safe=4
  fi
  (( safe < 1 )) && safe=1
  (( safe > ncpu )) && safe="${ncpu}"
  if [[ "${override}" =~ ^[0-9]+$ && "${override}" -ge 1 && "${override}" -lt "${safe}" ]]; then safe="${override}"; fi
  echo "${safe}"
}

# engine_build_jobs <backend> - the job count for THIS host (real cores and MemAvailable; LLMCTL_BUILD_JOBS may lower it).
engine_build_jobs() {
  local mem=unknown
  if [[ -r /proc/meminfo ]]; then
    mem="$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null)"
    [[ "${mem}" =~ ^[0-9]+$ ]] || mem=unknown
  fi
  engine_jobs_for "$1" "$(llmctl_nproc)" "${mem}" "${LLMCTL_BUILD_JOBS:-}"
}

# engine_openssl_arg [include_root] - HTTPS in llama-server needs OpenSSL at BUILD time and upstream defaults
# to "on" only when it finds the headers, silently building WITHOUT https otherwise: state it explicitly.
engine_openssl_arg() {
  if [[ -f "${1:-/usr/include}/openssl/ssl.h" ]]; then echo "-DLLAMA_OPENSSL=ON"; else echo "-DLLAMA_OPENSSL=OFF"; fi
}

# engine_https_verdict <build_dir> - did THIS build get HTTPS support? Evidence comes from the build itself:
# the CMake cache AND (when binaries exist) a linked libssl. `llama-server --help` lists the --ssl-* flags
# either way, so it proves nothing. First line: yes | no | unknown; second line: the reason.
engine_https_verdict() {
  local dir="$1" cache="$1/CMakeCache.txt" val bin linked=
  if [[ ! -f "${cache}" ]]; then echo unknown; echo "no CMakeCache.txt in ${dir}"; return 0; fi
  val="$(sed -n 's/^LLAMA_OPENSSL:BOOL=//p' "${cache}" | head -1)"
  case "${val}" in
    OFF) echo no; echo "LLAMA_OPENSSL=OFF in the CMake cache"; return 0 ;;
    ON) ;;
    *) echo unknown; echo "LLAMA_OPENSSL not recorded in the CMake cache"; return 0 ;;
  esac
  bin="${dir}/bin/llama-server"
  if [[ -x "${bin}" ]] && command -v ldd >/dev/null 2>&1; then
    if ldd "${bin}" 2>/dev/null | grep -q 'libssl'; then linked=yes; else linked=no; fi
    if [[ "${linked}" == "no" ]]; then echo no; echo "cache says ON but ${bin} links no libssl"; return 0; fi
  fi
  echo yes; echo "LLAMA_OPENSSL=ON${linked:+ and libssl is linked}"
}

engine_build_llama() {
  engine_ensure_submodules
  need_cmd cmake "$(llmctl_pkg_hint | sed 's/<pkg>/cmake/')"
  need_cmd git

  local backend; backend="$(engine_detect_backend)"
  local -a cmake_args=(-DCMAKE_BUILD_TYPE=Release)
  case "${backend}" in
    cuda)
      log "CUDA toolkit detected -> GGML_CUDA=ON"
      cmake_args+=(-DGGML_CUDA=ON)
      ;;
    rocm)
      log "ROCm detected -> GGML_HIP=ON"
      cmake_args+=(-DGGML_HIP=ON)
      ;;
    metal)
      log "macOS detected -> Metal backend (ON by default upstream)"
      ;;
    cpu)
      log "no GPU toolchain detected -> CPU build (GGML_NATIVE=ON, host-native)"
      cmake_args+=(-DGGML_NATIVE=ON)
      ;;
  esac

  cmake_args+=("$(engine_openssl_arg)")
  local jobs; jobs="$(engine_build_jobs "${backend}")"
  if [[ "${LLMCTL_DRY_RUN}" == "1" ]]; then
    log "[dry-run] cmake -S ${LLMCTL_LLAMA_SRC} -B ${LLMCTL_LLAMA_SRC}/build ${cmake_args[*]}"
    log "[dry-run] cmake --build ${LLMCTL_LLAMA_SRC}/build --config Release --target llama-server -j ${jobs}"
    return 0
  fi

  log "configuring llama.cpp (${backend} backend)"
  cmake -S "${LLMCTL_LLAMA_SRC}" -B "${LLMCTL_LLAMA_SRC}/build" "${cmake_args[@]}"
  log "building llama-server with ${jobs} jobs"
  cmake --build "${LLMCTL_LLAMA_SRC}/build" --config Release --target llama-server -j "${jobs}"

  local bin; bin="$(engine_llama_server_bin)"
  [[ -x "${bin}" ]] || die "build finished but ${bin} is missing"
  log "verifying built binary"
  "${bin}" --version || die "${bin} --version failed"
  local https; https="$(engine_https_verdict "${LLMCTL_LLAMA_SRC}/build")"
  info "llama.cpp build OK: ${bin} (HTTPS support: $(printf '%s' "${https}" | head -1) - $(printf '%s' "${https}" | sed -n 2p))"
}

# engine_build_colibri [target...] - default: colibri (GLM) + qwen36 engines.
engine_build_colibri() {
  engine_ensure_submodules
  local -a targets=("$@")
  [[ "${#targets[@]}" -gt 0 ]] || targets=(colibri qwen36)

  need_cmd make "$(llmctl_pkg_hint | sed 's/<pkg>/make/')"
  if ! have_cmd gcc && ! have_cmd clang && ! have_cmd cc; then
    die "no C compiler found. $(llmctl_pkg_hint | sed 's/<pkg>/gcc/')"
  fi

  local t bin
  for t in "${targets[@]}"; do
    if [[ "${LLMCTL_DRY_RUN}" == "1" ]]; then
      log "[dry-run] make -C ${LLMCTL_COLIBRI_SRC}/c ${t}"
      continue
    fi
    log "building colibri engine target: ${t}"
    make -C "${LLMCTL_COLIBRI_SRC}/c" "${t}"
    bin="${LLMCTL_COLIBRI_SRC}/c/${t}"
    [[ -x "${bin}" ]] || die "colibri build finished but ${bin} is missing"
    info "colibri engine built: ${bin}"
  done

  if [[ "${LLMCTL_DRY_RUN}" == "1" ]]; then
    log "[dry-run] pip install -e ${LLMCTL_COLIBRI_SRC}"
    return 0
  fi

  # Optional Python launcher (`coli`). Clear skip when pip is unavailable.
  if have_cmd pip3 || have_cmd pip; then
    local pip; pip="$(command -v pip3 || command -v pip)"
    log "installing colibri Python launcher (pip install -e submodules/colibri)"
    if "${pip}" install -e "${LLMCTL_COLIBRI_SRC}"; then
      info "coli launcher installed"
    else
      warn "pip install -e submodules/colibri failed; C engines still usable directly"
    fi
  else
    warn "pip not found - skipping 'coli' launcher install (C engines in submodules/colibri/c are unaffected)"
  fi
}

# engine_build_onnx - provisions the INTERNAL encoder scoring runtime's
# python environment (lib/onnx_server.py; onnxruntime is Python-only). It
# creates a PRIVATE venv at ${LLMCTL_DATA_DIR}/venv-onnx and installs ONLY
# from the committed, hash-locked lib/lock/requirements-onnx.lock with
# `--require-hashes --no-deps --only-binary=:all:` (D-16: no unpinned pip
# installs, no resolver, no sdists). The scheduler launches the runtime with
# that venv's python. If the lock carries an UNPINNED marker (it could not
# be generated with real hashes) the build REFUSES - hashes are never made up.
# Uses `python3 -m venv` + pip, or `uv` when python3-venv/ensurepip is absent.
engine_onnx_lock() { printf '%s' "${LLMCTL_ONNX_LOCK:-${LLMCTL_ROOT}/lib/lock/requirements-onnx.lock}"; }
engine_onnx_venv() { printf '%s' "${LLMCTL_ONNX_VENV:-${LLMCTL_DATA_DIR}/venv-onnx}"; }

# The marker llmctl writes into every venv it creates. A directory is only ever deleted by
# `llmctl build onnx` when it carries this marker naming ITS OWN absolute path (C-04): the venv
# location is overridable (LLMCTL_ONNX_VENV), and an override pointing at $HOME or a project
# directory must never be wiped by a "rebuild".
ENGINE_VENV_MARKER=".llmctl-onnx-venv"

# _eng_phys <dir> -> physical absolute path of an existing directory (symlinks resolved).
_eng_phys() { ( cd -P "$1" 2>/dev/null && pwd -P ); }

# engine_venv_prepare <venv> - prints nothing; rc 0 when <venv> may be (re)created (absent, or an
# llmctl-made venv that is safe to replace); rc 1 with the refusal reason on stderr otherwise.
engine_venv_prepare() {
  local v="$1" phys home dd
  case "${v}" in
    /*) : ;;
    *)  err "refusing LLMCTL_ONNX_VENV='${v}': it must be an absolute path"; return 1 ;;
  esac
  [[ "${v}" != "/" ]] || { err "refusing LLMCTL_ONNX_VENV='/'"; return 1; }
  if [[ -L "${v}" ]]; then
    err "refusing LLMCTL_ONNX_VENV='${v}': it is a symlink (it would be followed and its target deleted)"; return 1
  fi
  [[ -e "${v}" ]] || return 0               # nothing to remove: the venv is created fresh
  [[ -d "${v}" ]] || { err "refusing LLMCTL_ONNX_VENV='${v}': it exists and is not a directory"; return 1; }
  phys="$(_eng_phys "${v}")" || { err "cannot resolve ${v}"; return 1; }
  home="$(_eng_phys "${HOME:-/nonexistent}" || true)"
  dd="$(_eng_phys "${LLMCTL_DATA_DIR}" || true)"
  # never an ancestor of (or equal to) $HOME, the data dir or the install root
  local p
  for p in "${home}" "${dd}" "$(_eng_phys "${LLMCTL_ROOT}" || true)" /; do
    [[ -n "${p}" ]] || continue
    if [[ "${p}" == "${phys}" || "${p}" == "${phys}/"* ]]; then
      err "refusing LLMCTL_ONNX_VENV='${v}': it is, or contains, ${p} (llmctl will not delete it)"; return 1
    fi
  done
  if [[ -f "${v}/${ENGINE_VENV_MARKER}" && -f "${v}/pyvenv.cfg" ]] \
     && [[ "$(sed -n 's/^path=//p' "${v}/${ENGINE_VENV_MARKER}" | head -1)" == "${phys}" ]]; then
    return 0                                 # an llmctl-made venv at exactly this path
  fi
  # a venv built by an earlier llmctl (no marker yet) at the DEFAULT location is still replaceable
  if [[ -f "${v}/pyvenv.cfg" && -n "${dd}" && "${phys}" == "${dd}/venv-onnx" ]]; then
    return 0
  fi
  err "refusing to delete '${v}': it is not an llmctl-made onnx venv (no ${ENGINE_VENV_MARKER} naming this path). Remove it yourself, or point LLMCTL_ONNX_VENV at a path that does not exist yet"
  return 1
}

engine_build_onnx() {
  local lock venv
  lock="$(engine_onnx_lock)"; venv="$(engine_onnx_venv)"
  [[ -f "${lock}" ]] || die "onnx runtime lock file missing: ${lock}"
  if grep -qE '^[[:space:]]*#?[[:space:]]*UNPINNED' "${lock}"; then
    die "refusing to build the onnx runtime: ${lock} is marked UNPINNED (no verified hashes). Regenerate it (see the header of that file) - llmctl never installs unpinned packages"
  fi
  if ! grep -qE -- '--hash=sha256:[0-9a-f]{64}' "${lock}"; then
    die "refusing to build the onnx runtime: ${lock} carries no sha256 hashes"
  fi
  local pins; pins="$(grep -oE '^(onnxruntime|numpy|sentencepiece|tokenizers)==[0-9A-Za-z.]+' "${lock}" | sort -u | tr '\n' ' ')"
  info "building the onnx encoder runtime venv at ${venv}"
  log "hash-locked pins: ${pins}(every file verified with --require-hashes; lock: ${lock})"
  need_cmd python3
  if [[ "${LLMCTL_DRY_RUN:-0}" == "1" ]]; then
    log "dry-run: would create ${venv} and install from ${lock}"
    return 0
  fi
  ensure_dir "$(dirname "${venv}")"
  engine_venv_prepare "${venv}" || die "the onnx venv location was refused (see above); nothing was deleted"
  rm -rf "${venv}"
  local py="${venv}/bin/python"
  if python3 -m venv "${venv}" >/dev/null 2>&1 && [[ -x "${py}" ]]; then
    printf 'path=%s\ncreated-by=llmctl build onnx\n' "$(_eng_phys "${venv}")" > "${venv}/${ENGINE_VENV_MARKER}"
    PIP_DISABLE_PIP_VERSION_CHECK=1 PYTHONDONTWRITEBYTECODE=1 \
      "${py}" -m pip install --quiet --require-hashes --no-deps --only-binary=:all: --no-compile -r "${lock}" \
      || { rm -rf "${venv}"; die "hash-locked pip install failed (a hash mismatch or missing wheel for this platform/python aborts the build; nothing was installed unverified)"; }
  elif have_cmd uv; then
    rm -rf "${venv}"
    uv venv --quiet "${venv}" \
      && printf 'path=%s\ncreated-by=llmctl build onnx\n' "$(_eng_phys "${venv}")" > "${venv}/${ENGINE_VENV_MARKER}" \
      && uv pip install --quiet --python "${py}" --require-hashes --no-deps --only-binary :all: --no-compile -r "${lock}" \
      || { rm -rf "${venv}"; die "hash-locked uv install failed (nothing was installed unverified)"; }
  else
    rm -rf "${venv}"
    die "cannot create a venv: python3-venv/ensurepip is missing and uv is not installed (install python3-venv, or uv)"
  fi
  "${py}" -c 'import onnxruntime, numpy, sentencepiece, tokenizers' \
    || { rm -rf "${venv}"; die "installed venv cannot import its runtime deps"; }
  log "onnx runtime venv ready: ${py}"
}

# engine_build_decide - builds the Go decision binary (gateway + decide client + key/cert
# management; Go + Gin Gonic). Output: ${LLMCTL_DECIDE_BUILD_OUT:-${LLMCTL_ROOT}/build/llmctl-decide}.
# Hermetic-ish: -mod=readonly + the committed go.sum (verified with `go mod verify`), -trimpath;
# a first build needs the module cache warm or network access (documented, not vendored).
engine_build_decide() {
  need_cmd go
  local out="${LLMCTL_DECIDE_BUILD_OUT:-${LLMCTL_ROOT}/build/llmctl-decide}"
  ensure_dir "$(dirname "${out}")"
  info "building the Go decision binary -> ${out}"
  ( cd "${LLMCTL_ROOT}" && GOFLAGS=-mod=readonly go mod verify >/dev/null && \
    GOFLAGS=-mod=readonly go build -trimpath -o "${out}" ./cmd/llmctl-decide ) \
    || die "go build of the decision binary failed (needs the Go toolchain >= 1.25 and a warm module cache or network access)"
  log "built ${out}"
}

# engine_build [llama|colibri|onnx|decide|all] - default all ('all' builds the two
# compiled engines, the onnx runtime venv and the Go decision binary - the registry, dynamic ports
# and the gateway unit all need build/llmctl-decide). `llmctl build` itself requires an explicit
# target (G-078); the all-default here is the internal API only.
engine_build() {
  local what="${1:-all}"
  case "${what}" in
    llama)   engine_build_llama ;;
    colibri) shift || true; engine_build_colibri "$@" ;;
    onnx)    engine_build_onnx ;;
    decide)  engine_build_decide ;;
    all)     engine_build_llama; engine_build_colibri; engine_build_onnx; engine_build_decide ;;
    *)       die "unknown build target: ${what} (expected llama|colibri|onnx|decide|all)" ;;
  esac
}
