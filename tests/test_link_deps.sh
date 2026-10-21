#!/usr/bin/env bash
# test_link_deps.sh - proves scripts/link_deps.sh creates the ignored convenience links from what
# lib/resolve_deps.sh resolves, is idempotent, never clobbers a real directory, and reports an unresolved
# dependency loudly (exit 1) while still linking the others. Runs the REAL script in a mktemp fixture.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/llmctl-link.XXXXXX")"
trap 'rm -rf -- "${WORK}"' EXIT
mk_llmctl() { mkdir -p "$1/lib" "$1/scripts"; cp "${LLMCTL_ROOT}/lib/resolve_deps.sh" "$1/lib/"; cp "${LLMCTL_ROOT}/scripts/link_deps.sh" "$1/scripts/"; }
run() { local d="$1"; shift; RC=0; OUT="$(env -i PATH="${PATH}" HOME="${WORK}/h" LLMCTL_HOST_FALLBACK_DIR="${WORK}/none" "$@" bash "${d}/scripts/link_deps.sh" 2>&1)" || RC=$?; }

HUB="${WORK}/hub"; mkdir -p "${HUB}/submodules/containers" "${HUB}/submodules/superspec"
: > "${HUB}/Constitution.md"; printf 'module digital.vasic.containers\n' > "${HUB}/submodules/containers/go.mod"; : > "${HUB}/submodules/superspec/extension.yml"
L="${HUB}/submodules/llmctl"; mk_llmctl "${L}"

echo "== 1. nested in a hub: all three links are created =="
run "${L}"
assert_eq "0" "${RC}" "link_deps exits 0 when everything resolves"
assert_eq "../.." "$(readlink "${L}/constitution")" "constitution -> ../.. (relative inside the hub)"
assert_eq "../../containers" "$(readlink "${L}/submodules/containers")" "submodules/containers -> ../../containers (relative inside the hub)"
assert_eq "$(cd "${HUB}" && pwd -P)" "$(cd "${L}/constitution" && pwd -P)" "the relative link really lands on the hub"
assert_eq "../../superspec" "$(readlink "${L}/submodules/superspec")" "submodules/superspec -> ../../superspec"
assert_file_exists "${L}/submodules/containers/go.mod" "the link is usable by go.mod's replace path"

echo "== 2. idempotent + --check =="
run "${L}"; assert_eq "0" "${RC}" "second run exits 0"
run "${L}" ; run "${L}" ; RC=0; OUT="$(env -i PATH="${PATH}" HOME="${WORK}/h" bash "${L}/scripts/link_deps.sh" --check 2>&1)" || RC=$?
assert_eq "0" "${RC}" "--check passes on a correct layout"

echo "== 3. --check detects a wrong link and a missing one =="
ln -sfn "${WORK}" "${L}/submodules/superspec"; rm -f "${L}/submodules/containers"
RC=0; OUT="$(env -i PATH="${PATH}" HOME="${WORK}/h" bash "${L}/scripts/link_deps.sh" --check 2>&1)" || RC=$?
assert_eq "1" "${RC}" "--check fails on wrong/missing links"
assert_contains "${OUT}" "WRONG submodules/superspec" "wrong link named"
assert_contains "${OUT}" "MISSING submodules/containers" "missing link named"
run "${L}"; assert_eq "0" "${RC}" "a normal run repairs both"

echo "== 4. a real directory is never clobbered =="
rm -f "${L}/submodules/superspec"; mkdir -p "${L}/submodules/superspec"; : > "${L}/submodules/superspec/keep"
run "${L}"
assert_eq "1" "${RC}" "real dir in the way: exit 1"
assert_contains "${OUT}" "LEFTOVER submodules/superspec" "reported as a leftover with its remediation"
assert_file_exists "${L}/submodules/superspec/keep" "the real directory content is untouched"

echo "== 5. NEGATIVE CONTROL: unresolvable dependency -> exit 1, others still linked =="
N="${WORK}/alone/llmctl"; mk_llmctl "${N}"; mkdir -p "${WORK}/alone/containers"; printf 'module digital.vasic.containers\n' > "${WORK}/alone/containers/go.mod"
run "${N}"
assert_eq "1" "${RC}" "constitution + superspec unresolved: exit 1"
assert_contains "${OUT}" "cannot resolve constitution" "message names the unresolved dependency"
assert_eq "${WORK}/alone/containers" "$(readlink "${N}/submodules/containers")" "the resolvable one was still linked"
assert_eq "no" "$([[ -e "${N}/constitution" || -L "${N}/constitution" ]] && echo yes || echo no)" "no dangling link made for the unresolved one"

echo "== 6. REGRESSION: a run without the env override must not turn an env-made link into a self-loop =="
# root cause (found live 2026-10-21): the resolver's <root>/constitution candidate IS the link made earlier, so
# link_deps resolved "constitution" to the link's own path and `ln -sfn` replaced it with a link to itself.
V="${WORK}/v6"; mk_llmctl "${V}/llmctl"; mkdir -p "${V}/real/c" "${V}/real/k" "${V}/real/s"
: > "${V}/real/c/Constitution.md"; printf 'module digital.vasic.containers\n' > "${V}/real/k/go.mod"; : > "${V}/real/s/extension.yml"
run "${V}/llmctl" LLMCTL_CONSTITUTION_DIR="${V}/real/c" LLMCTL_CONTAINERS_DIR="${V}/real/k" LLMCTL_SUPERSPEC_DIR="${V}/real/s"
assert_eq "0" "${RC}" "first run with env overrides links the three"
run "${V}/llmctl"
assert_eq "0" "${RC}" "second run WITHOUT env overrides exits 0"
assert_eq "${V}/real/c" "$(readlink "${V}/llmctl/constitution")" "constitution link still points at the real tree (no self-loop)"
assert_file_exists "${V}/llmctl/submodules/containers/go.mod" "containers link still resolves to a real go.mod"
assert_file_exists "${V}/llmctl/submodules/superspec/extension.yml" "superspec link still resolves to a real extension.yml"

echo "== 7. named dependency only (used by the build path) =="
Q="${WORK}/q7/llmctl"; mk_llmctl "${Q}"; mkdir -p "${WORK}/q7/containers"; printf 'module digital.vasic.containers\n' > "${WORK}/q7/containers/go.mod"
RC=0; OUT="$(env -i PATH="${PATH}" HOME="${WORK}/h" bash "${Q}/scripts/link_deps.sh" containers 2>&1)" || RC=$?
assert_eq "0" "${RC}" "link_deps containers exits 0 although constitution/superspec are unresolved"
assert_eq "yes" "$([[ -L "${Q}/submodules/containers" && ! -e "${Q}/constitution" && ! -L "${Q}/constitution" ]] && echo yes || echo no)" "only containers was linked"

test_finish
