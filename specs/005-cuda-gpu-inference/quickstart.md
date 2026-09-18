# Quickstart: CUDA GPU-Accelerated Inference Enablement

**Feature**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md)

This guide validates the feature end-to-end on a real host. It assumes the
implementation tasks (tasks.md) have landed the `lib/engine.sh` change and the
three new test files.

## Prerequisites

- A Linux host with an NVIDIA GPU and driver already installed (`nvidia-smi`
  runs successfully) — confirmed on this host: RTX 3060, driver 595.84.
- `sudo` access to install the `nvidia-cuda-toolkit` package.
- This repository checked out with submodules initialized
  (`git submodule update --init --recursive`).

## Step 1 — Install the CUDA toolkit

```bash
sudo apt-get update
sudo apt-get install -y nvidia-cuda-toolkit
nvcc --version   # expect: release 12.4
```

**Expected outcome**: `nvcc` resolves on `PATH`. If it does not, check
`/usr/bin/nvcc` was installed and `PATH` includes `/usr/bin` (the distro
package installs there directly, unlike NVIDIA's own installer which uses
`/usr/local/cuda/bin`).

## Step 2 — Rebuild llama.cpp with the CUDA backend

```bash
cd /home/milosvasic/Projects/llmctl
bash -c 'source lib/engine.sh; engine_build_llama'
```

**Expected outcome**: log lines include `CUDA toolkit detected -> GGML_CUDA=ON`,
the cmake configure step succeeds, the build succeeds, and the final
`"${bin}" --version` check passes. If `nvcc` rejects the host compiler, the
build log will show the compatibility flag from research.md R2 already
applied — if the build still fails at that point, see research.md R2's
documented fallback (installing `gcc-13`/`g++-13` and setting
`CMAKE_CUDA_HOST_COMPILER`).

## Step 3 — Confirm the binary actually links a CUDA backend

```bash
./submodules/llama.cpp/build/bin/llama-server --list-devices
```

**Expected outcome**: at least one CUDA device is listed (e.g.
`CUDA0: NVIDIA GeForce RTX 3060`), not an empty list.

## Step 4 — Run the new automated test suite

```bash
bash tests/test_engine_cuda_build.sh
bash tests/test_gpu_vram_delta.sh
bash tests/test_gpu_throughput_ratio.sh
```

**Expected outcome**: all three PASS, each printing its captured evidence path
under `docs/qa/<run-id>/` (VRAM before/after readings, tok/s numbers for both
the forced-CPU and GPU-planned runs).

## Step 5 — Re-run the previously-failing Superpowers-TUI challenge

Follow the same live-session procedure already documented in
`docs/CONTINUATION.md` §10m for the `moe-fast` (or another GPU-eligible)
profile, now against the CUDA-enabled build.

**Expected outcome**: the session completes within Claude Code's own
per-request timeout — the previously-recorded FAIL verdict is superseded by a
new, dated PASS verdict with a fresh transcript, per this project's own
demotion-evidence discipline (a FAIL is never silently deleted; a new PASS
entry is added citing the old FAIL as superseded, with the new evidence).

## Step 6 — Confirm zero regression on the CPU-only path

```bash
PATH="$(echo "$PATH" | tr ':' '\n' | grep -v cuda | paste -sd:)" \
  bash -c 'source lib/engine.sh; engine_detect_backend'
```

**Expected outcome**: prints `cpu` — proving the CUDA branch is unreachable
without `nvcc` on `PATH`, satisfying FR-004/SC-005 without needing a second
physical CPU-only host.
