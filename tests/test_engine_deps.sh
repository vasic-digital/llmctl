#!/usr/bin/env bash
# test_engine_deps.sh - B1 (review round 2): the RUNTIME build path (`llmctl setup`, `llmctl build decide|all`,
# and through them scripts/install.sh) must make the go.mod replace target (submodules/containers) exist, or STOP with
# the resolver's actionable message - never fall through to a misleading "Go toolchain / module cache" error.
# Every case runs the REAL bin/llmctl or lib/engine.sh from a throw-away fresh-clone FIXTURE (no link, no go build).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/llmctl-engdeps.XXXXXX")"
trap 'rm -rf -- "${WORK}"' EXIT
# mk_clone <dir>: a fresh llmctl checkout (no constitution / containers / superspec links)
mk_clone() { mkdir -p "$1/bin" "$1/scripts"; cp -r "${LLMCTL_ROOT}/lib" "$1/"; cp "${LLMCTL_ROOT}/bin/llmctl" "$1/bin/"; cp "${LLMCTL_ROOT}/scripts/link_deps.sh" "$1/scripts/"; rm -rf "$1/lib/__pycache__"; }
mk_hub() { mkdir -p "$1/submodules/containers" "$1/submodules/superspec"; : > "$1/Constitution.md"
           printf 'module digital.vasic.containers\n' > "$1/submodules/containers/go.mod"; : > "$1/submodules/superspec/extension.yml"; }
run() { local d="$1"; shift; RC=0; OUT="$(env -i PATH="${PATH}" HOME="${WORK}/h" XDG_CONFIG_HOME="${WORK}/h/c" XDG_DATA_HOME="${WORK}/h/d" XDG_STATE_HOME="${WORK}/h/s" LLMCTL_ROOT="${d}" LLMCTL_HOST_FALLBACK_DIR="${WORK}/none" "$@" 2>&1)" || RC=$?; }

echo "== 1. fresh clone nested in a hub: engine_ensure_containers creates the link =="
mk_hub "${WORK}/hub"; mk_clone "${WORK}/hub/submodules/llmctl"
L="${WORK}/hub/submodules/llmctl"
run "${L}" bash -c "source '${L}/lib/engine.sh'; engine_ensure_containers"
assert_eq "0" "${RC}" "ensure succeeds when the hub provides containers"
assert_file_exists "${L}/submodules/containers/go.mod" "go.mod replace target now exists"

echo "== 2. NEGATIVE: nothing resolves: build decide stops with the resolver message, before any go work =="
mk_clone "${WORK}/lone/llmctl"; L2="${WORK}/lone/llmctl"
run "${L2}" bash -c "source '${L2}/lib/engine.sh'; engine_build decide"
assert_eq "1" "${RC}" "build decide exits 1"
assert_contains "${OUT}" "cannot resolve containers" "message is the resolver's"
assert_contains "${OUT}" "LLMCTL_CONTAINERS_DIR" "message names the override"
case "${OUT}" in *"Go toolchain"*|*"module cache"*) TEST_FAILS=$((TEST_FAILS+1)); echo "  FAIL: misleading go message: ${OUT}" >&2;; *) echo "  ok: no misleading 'Go toolchain / module cache' message";; esac

echo "== 3. build all fails BEFORE the long engine builds =="
run "${L2}" bash -c "source '${L2}/lib/engine.sh'; engine_ensure_submodules(){ :; }; engine_build_llama(){ echo STARTED-LLAMA; }; engine_build_colibri(){ :; }; engine_build_onnx(){ :; }; engine_build all"
assert_eq "1" "${RC}" "build all exits 1"
case "${OUT}" in *STARTED-LLAMA*) TEST_FAILS=$((TEST_FAILS+1)); echo "  FAIL: llama build started first" >&2;; *) echo "  ok: nothing was built before the dependency check";; esac

echo "== 4. llmctl setup stops first with the resolver message =="
run "${L2}" bash "${L2}/bin/llmctl" setup
assert_eq "1" "${RC}" "setup exits 1"
assert_contains "${OUT}" "cannot resolve containers" "setup prints the resolver message"
case "${OUT}" in *"environment self-diagnosis"*) TEST_FAILS=$((TEST_FAILS+1)); echo "  FAIL: doctor ran before the dependency check" >&2;; *) echo "  ok: the dependency check runs before doctor";; esac

echo "== 5. already-linked clone: ensure is a no-op =="
run "${L}" bash -c "source '${L}/lib/engine.sh'; engine_ensure_containers; engine_ensure_containers"
assert_eq "0" "${RC}" "idempotent"

echo "== 6. dry-run does not die on an unresolved dependency =="
run "${L2}" env LLMCTL_DRY_RUN=1 bash -c "source '${L2}/lib/engine.sh'; engine_ensure_containers"
assert_eq "0" "${RC}" "dry-run: warns, exits 0"

test_finish
