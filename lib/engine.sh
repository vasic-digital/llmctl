#!/usr/bin/env bash
# engine.sh - build llama.cpp and colibri from the pinned vendor/ submodules.
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

LLMCTL_LLAMA_SRC="${LLMCTL_ROOT}/vendor/llama.cpp"
LLMCTL_COLIBRI_SRC="${LLMCTL_ROOT}/vendor/colibri"

engine_llama_server_bin() {
  echo "${LLMCTL_LLAMA_SRC}/build/bin/llama-server"
}

engine_ensure_submodules() {
  need_cmd git
  local missing=0 m
  for m in vendor/llama.cpp vendor/colibri; do
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

  local jobs; jobs="$(llmctl_nproc)"
  log "configuring llama.cpp (${backend} backend)"
  cmake -S "${LLMCTL_LLAMA_SRC}" -B "${LLMCTL_LLAMA_SRC}/build" "${cmake_args[@]}"
  log "building llama-server with ${jobs} jobs"
  cmake --build "${LLMCTL_LLAMA_SRC}/build" --config Release --target llama-server -j "${jobs}"

  local bin; bin="$(engine_llama_server_bin)"
  [[ -x "${bin}" ]] || die "build finished but ${bin} is missing"
  log "verifying built binary"
  "${bin}" --version || die "${bin} --version failed"
  info "llama.cpp build OK: ${bin}"
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
    log "building colibri engine target: ${t}"
    make -C "${LLMCTL_COLIBRI_SRC}/c" "${t}"
    bin="${LLMCTL_COLIBRI_SRC}/c/${t}"
    [[ -x "${bin}" ]] || die "colibri build finished but ${bin} is missing"
    info "colibri engine built: ${bin}"
  done

  # Optional Python launcher (`coli`). Clear skip when pip is unavailable.
  if have_cmd pip3 || have_cmd pip; then
    local pip; pip="$(command -v pip3 || command -v pip)"
    log "installing colibri Python launcher (pip install -e vendor/colibri)"
    if "${pip}" install -e "${LLMCTL_COLIBRI_SRC}"; then
      info "coli launcher installed"
    else
      warn "pip install -e vendor/colibri failed; C engines still usable directly"
    fi
  else
    warn "pip not found - skipping 'coli' launcher install (C engines in vendor/colibri/c are unaffected)"
  fi
}

# engine_build [llama|colibri|all] - default all.
engine_build() {
  local what="${1:-all}"
  case "${what}" in
    llama)   engine_build_llama ;;
    colibri) shift || true; engine_build_colibri "$@" ;;
    all)     engine_build_llama; engine_build_colibri ;;
    *)       die "unknown build target: ${what} (expected llama|colibri|all)" ;;
  esac
}
