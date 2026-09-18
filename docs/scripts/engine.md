## Overview

`lib/engine.sh` builds llmctl's two inference engines — `llama.cpp` (via
`cmake`) and `colibri` (via `make`, plus an optional Python launcher
`pip install`) — from their pinned git submodules under `submodules/`. It
auto-detects the best available GPU backend on the current host (CUDA on
Linux with `nvcc`, Metal on macOS by default, ROCm on Linux with `rocm-smi`/
`/opt/rocm`, or a CPU-native fallback) and passes the corresponding cmake
flags, so a single `llmctl build` command produces a correctly-configured
binary regardless of which backend is present. It exists so engine builds
are reproducible from source rather than requiring the operator to hand-run
cmake/make invocations, and so the backend choice is made dynamically rather
than hardcoded per host.

## Prerequisites

* Sources `lib/common.sh` and `lib/os_detect.sh` from its own directory
  (`_eng_dir`).
* `git` — for `engine_ensure_submodules` (checks/initializes
  `submodules/llama.cpp` and `submodules/colibri`).
* For the llama.cpp build: `cmake` (`need_cmd` with a package-manager-
  specific install hint via `llmctl_pkg_hint`).
* For the colibri build: `make`, and at least one C compiler among `gcc`,
  `clang`, or `cc` (`die`s with an install hint if none are found).
* Optionally `pip3`/`pip` for the colibri Python launcher install (soft-skip
  if neither is present).
* Backend auto-detection reads `nvcc` on `PATH` or `/usr/local/cuda/bin/nvcc`
  (CUDA), `rocm-smi` on `PATH` or `/opt/rocm` (ROCm), or `llmctl_os` ==
  `macos` (Metal) — no environment variable forces a specific backend.
* The submodules `submodules/llama.cpp` and `submodules/colibri` must be
  registered in `.gitmodules` at the project root — `engine_ensure_submodules`
  runs `git submodule update --init --recursive` if either is missing its
  `.git` marker.

## Usage examples

```sh
source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/os_detect.sh"
source "${LLMCTL_ROOT}/lib/engine.sh"

engine_detect_backend           # -> cuda | rocm | metal | cpu
engine_llama_server_bin         # -> the expected llama-server binary path
engine_ensure_submodules        # git submodule update --init --recursive if needed

engine_build_llama               # configure + build llama-server, verify --version
engine_build_colibri              # build default targets (colibri, qwen36) + optional pip install
engine_build_colibri qwen36       # build only the qwen36 colibri target

engine_build llama               # same as engine_build_llama
engine_build colibri qwen36       # same as engine_build_colibri qwen36 (target args forwarded)
engine_build all                  # llama.cpp then colibri (default)
engine_build                      # same as "all" (default argument)

# via the CLI:
bin/llmctl build all
bin/llmctl build llama
bin/llmctl build colibri qwen36

# dry-run: print the cmake/make commands instead of running them
LLMCTL_DRY_RUN=1 bin/llmctl build all

# override the built binary the rest of llmctl resolves to
LLMCTL_LLAMA_SERVER=/custom/path/llama-server bin/llmctl models download fast
```

## Edge cases

* **Submodule initialization is conditional, not unconditional**:
  `engine_ensure_submodules` only runs `git submodule update --init
  --recursive` if at least one of `submodules/llama.cpp/.git` or
  `submodules/colibri/.git` is missing — an already-initialized submodule
  is left untouched (no re-fetch, no re-checkout) on every subsequent build.
* **Backend detection order matters and macOS always wins first**: the
  `case`-like `if`/`elif` chain in `engine_detect_backend` checks `macos`
  before CUDA/ROCm, so even a Linux-only backend probe (`nvcc`/`rocm-smi`)
  is never reached on macOS — Metal is always selected there regardless of
  what else might theoretically be present.
* **CUDA detection accepts either a `PATH`-resolved `nvcc` OR a hardcoded
  fallback path** (`/usr/local/cuda/bin/nvcc`) — a CUDA toolkit installed
  but not added to `PATH` at that exact conventional location is still
  detected; any other non-standard install location is not.
* **A build with no detected GPU backend is not an error** — the `cpu`
  branch is a legitimate, expected outcome (not a warning-then-die), adding
  `-DGGML_NATIVE=ON` for host-native CPU optimization; the file's header
  comment explicitly documents this as "the default, kept explicitly for
  clarity."
* **`LLMCTL_DRY_RUN=1` prints the exact cmake/make invocations it would run,
  then returns before ever touching the filesystem** — both
  `engine_build_llama` and `engine_build_colibri` check this flag
  immediately after resolving the backend/targets and `return 0` before any
  `cmake -S`/`cmake --build`/`make -C`/`pip install` call, so a dry run never
  creates a `build/` directory or partial artifact.
* **`engine_build_llama` verifies the resulting binary twice**: first that
  it exists and is executable (`[[ -x "${bin}" ]] || die ...`), then that it
  actually runs (`"${bin}" --version || die "${bin} --version failed"`) — a
  cmake build that "succeeds" but produces a broken binary (e.g. missing
  runtime libraries) is caught here rather than silently reported as OK.
* **`engine_build_colibri`'s default target list is `(colibri qwen36)`, not
  a single target** — passing no arguments builds both; passing any
  arguments replaces that default entirely rather than adding to it
  (`[[ "${#targets[@]}" -gt 0 ]] || targets=(colibri qwen36)`).
* **Each colibri target build is independently verified** (existence +
  executable bit) inside the loop before moving to the next target — a
  `make` invocation that reports success but doesn't actually produce the
  expected binary at `${LLMCTL_COLIBRI_SRC}/c/${t}` is caught per-target,
  not just at the very end.
* **The optional `coli` Python launcher install is a soft failure at two
  different levels**: if neither `pip3` nor `pip` is found at all, it warns
  and explicitly notes "C engines in submodules/colibri/c are unaffected"
  rather than dying; if `pip` is found but `pip install -e` itself fails, it
  also only warns ("C engines still usable directly") rather than failing
  the whole build — the C engine binaries are considered the load-bearing
  deliverable, the Python launcher a convenience.
* **`engine_build`'s dispatch on `colibri` forwards remaining arguments,
  not just a fixed set**: `colibri) shift || true; engine_build_colibri
  "$@" ;;` — the `shift || true` guards against `engine_build` being called
  with `colibri` as the *only* argument (nothing left to shift), so
  `engine_build colibri` alone still works and falls through to
  `engine_build_colibri`'s own default-target logic.
* **An unrecognized top-level build target is a hard error naming the valid
  choices**: `engine_build`'s `*)` branch dies with
  `"unknown build target: ${what} (expected llama|colibri|all)"`.

## Internal behaviour

1. **`engine_llama_server_bin()`**: a one-line function returning the
   expected llama-server binary path under
   `${LLMCTL_LLAMA_SRC}/build/bin/llama-server` — purely a path convention,
   does not check existence itself.
2. **`engine_ensure_submodules()`**: checks both submodules' `.git` markers,
   warns per-missing-submodule, and runs a single
   `git submodule update --init --recursive` if at least one was missing.
3. **`engine_detect_backend()`**: OS/tool-probing `if`/`elif` chain (see
   Edge cases for exact ordering) echoing one of `metal`/`cuda`/`rocm`/`cpu`.
4. **`engine_build_llama()`**: ensures submodules, requires `cmake`/`git`,
   detects the backend and builds the matching `cmake_args` array,
   determines job count via `llmctl_nproc`, short-circuits under
   `LLMCTL_DRY_RUN` (logging the would-be commands), otherwise runs
   `cmake -S ... -B .../build "${cmake_args[@]}"` then
   `cmake --build .../build --config Release --target llama-server -j
   "${jobs}"`, and finally verifies the resulting binary (existence +
   `--version`).
5. **`engine_build_colibri([target...])`**: ensures submodules, defaults the
   target list to `(colibri qwen36)` if none given, requires `make` and at
   least one C compiler, short-circuits per-target under `LLMCTL_DRY_RUN`,
   otherwise runs `make -C .../c "${t}"` per target and verifies each
   resulting binary; after all targets, attempts (soft-fail) an
   editable `pip install -e` of the colibri Python launcher if `pip3`/`pip`
   is available (also short-circuited under `LLMCTL_DRY_RUN`, logged only).
6. **`engine_build([what])`**: the single public dispatch entry point — a
   `case` over `llama`/`colibri`/`all` (default `all`) delegating to
   `engine_build_llama`/`engine_build_colibri` (forwarding extra args for
   `colibri`) or building both in sequence for `all`; an unrecognized value
   dies naming the valid choices.

## 005-cuda-gpu-inference addendum: real CUDA build confirmed, no compiler flag needed, LD_LIBRARY_PATH required at runtime

**No code change to this file was needed for this feature.**
`research.md`'s R2 concern — that CUDA 12.4's `nvcc` would reject this
host's `gcc 15.2.0` as an unsupported host compiler (per CUDA 12.4's
published `gcc <= 13.x` support matrix) and require a
`-DCMAKE_CUDA_FLAGS=-allow-unsupported-compiler` addition to the `cuda)`
branch — was investigated with a real, unmodified `engine_build_llama`
rebuild and did NOT materialize: the full CUDA compile (every
`ggml-cuda/*.cu` object file) and link succeeded with zero
compiler-compatibility errors or warnings. `engine_build_llama`'s `cuda)`
branch remains exactly `cmake_args+=(-DGGML_CUDA=ON)`, unchanged. See
`docs/qa/005-cuda-gpu-inference/T004_T005_skip_rationale.txt` and
`build_attempt_1_unmodified.log` for the full real evidence.

**Runtime gotcha confirmed for a CUDA-enabled build (not new to this
build system, but newly relevant once GPU builds exist): invoking the
built `llama-server` binary directly (bypassing `lib/scheduler.sh`'s
`sched_build_launch`, which already sets `LD_LIBRARY_PATH` correctly via
`svc_write_env`) without `LD_LIBRARY_PATH` pointed at
`submodules/llama.cpp/build/bin` silently loads the stale, CPU-only,
dpkg-owned system package `libggml0`'s
`/usr/lib/x86_64-linux-gnu/libggml.so.0` instead of the freshly-built
one sitting right next to the binary, and `--list-devices` reports
`Available devices: (none)` even on a genuinely CUDA-capable build —
exactly the same SONAME-collision class already root-caused in
`lib/download.sh`'s `_dl_smoke_test_gguf()` and
`lib/service_linux.sh`'s `svc_write_env()`. Confirmed directly this
session:

```sh
# WITHOUT LD_LIBRARY_PATH -> stale system libggml.so.0 -> no CUDA device
./submodules/llama.cpp/build/bin/llama-server --list-devices
# Available devices:
#   (none)

# WITH LD_LIBRARY_PATH -> the real, freshly-built libggml.so.0 -> CUDA found
LD_LIBRARY_PATH="$(pwd)/submodules/llama.cpp/build/bin" \
  ./submodules/llama.cpp/build/bin/llama-server --list-devices
# Available devices:
#   CUDA0: NVIDIA GeForce RTX 3060 (11909 MiB, 11000 MiB free)
```

Any new call site that launches `llama-server` directly (outside
`lib/scheduler.sh`'s existing, already-correct launch path) MUST set
`LD_LIBRARY_PATH` to the binary's own directory first — see
`tests/test_gpu_vram_delta.sh` and `tests/test_gpu_throughput_ratio.sh`
for the pattern.

**Real, measured GPU offload evidence** (profile `small`, this host,
RTX 3060): a real chat-completion request produced a 2343 MiB VRAM delta
(SC-002 threshold 500 MiB) and a 56.6x throughput ratio versus the same
build forced to `--n-gpu-layers 0` (SC-003 threshold 2x). Full evidence:
`docs/qa/005-cuda-gpu-inference/`.

## Related scripts

* Sources `lib/common.sh` and `lib/os_detect.sh`.
* Called by `bin/llmctl`'s `build` command (`engine_build "${@:-all}"`) and
  by `cmd_setup()` (`engine_build all`, as part of the one-shot
  `llmctl setup` flow).
* `lib/download.sh` depends on this file's build output indirectly (not by
  sourcing it): `_dl_llama_server_bin` looks for the exact binary path
  `engine_llama_server_bin` describes, and `_dl_validate_colibri` looks for
  the `coli` launcher this file's `engine_build_colibri` installs.
* Builds from the `submodules/llama.cpp` and `submodules/colibri` git
  submodules declared in `.gitmodules` (out of scope for this
  documentation pass, but the direct build target of this file).
* Exercised by `tests/test_engine.sh` (backend detection, dry-run build
  command shape), `tests/test_engine_cpu_regression.sh` (005-cuda-gpu-
  inference: permanent CPU-only-path regression guard), and end-to-end
  via `tests/test_setup_e2e.sh` (the `llmctl setup` flow, which calls
  `engine_build all`). `tests/test_gpu_vram_delta.sh` and
  `tests/test_gpu_throughput_ratio.sh` (005-cuda-gpu-inference) exercise
  this file's build OUTPUT (the built `llama-server` binary) directly,
  rather than sourcing this file.

## Last verified date

2026-09-18
