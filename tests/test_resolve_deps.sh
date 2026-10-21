#!/usr/bin/env bash
# test_resolve_deps.sh - proves lib/resolve_deps.sh (the ONE source of truth for locating the constitution,
# containers and superspec dependencies; llmctl no longer vendors them as submodules) resolves in the
# documented order and FAILS LOUDLY when nothing resolves.
#
# Every case runs the REAL library against a throw-away fixture tree built under a mktemp dir (the library is
# copied to <fixture>/<llmctl>/lib/ so its "where am I" logic is exercised for real). Nothing in the working
# tree or in the real hub is touched.
#
# Cases: 1 env override wins; 2 nested at <hub>/submodules/llmctl finds the hub constitution + flat siblings;
# 3 standalone root layout (<root>/constitution, <root>/submodules/<name>); 4 sibling directories;
# 5 ancestor walk (<ancestor>/submodules/<name>); 6 host fallback (constitution only); 7 nothing resolves ->
# non-zero + actionable message (negative control, never a silent pass); 8 a candidate that lacks the marker
# file is rejected (no false positive on an empty dir); 9 an invalid env override is an error, not a fallthrough.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

LIB_SRC="${LLMCTL_ROOT}/lib/resolve_deps.sh"
if [[ ! -f "${LIB_SRC}" ]]; then
  printf '  FAIL: lib/resolve_deps.sh is missing (RED: the resolver does not exist yet)\n' >&2
  TEST_FAILS=$((TEST_FAILS+1))
  test_finish
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/llmctl-resolve.XXXXXX")"
trap 'rm -rf -- "${WORK}"' EXIT

# mk_constitution <dir> / mk_containers <dir> / mk_superspec <dir>: minimal valid dependency trees
mk_constitution() { mkdir -p "$1"; : > "$1/Constitution.md"; : > "$1/CLAUDE.md"; }
mk_containers()   { mkdir -p "$1"; printf 'module digital.vasic.containers\n' > "$1/go.mod"; }
mk_superspec()    { mkdir -p "$1"; : > "$1/extension.yml"; }
# mk_llmctl <llmctl-dir>: copy the real library under test into a fixture llmctl checkout
mk_llmctl()       { mkdir -p "$1/lib"; cp "${LIB_SRC}" "$1/lib/resolve_deps.sh"; }
# resolve <llmctl-dir> <name> [VAR=val...]: run the real library in a clean env; sets OUT / ERR / RC
resolve() {
  local d="$1" name="$2"; shift 2
  RC=0; ERR_FILE="${WORK}/err.$$"
  OUT="$(env -i PATH="${PATH}" HOME="${WORK}/home" LLMCTL_HOST_FALLBACK_DIR="${WORK}/no-such-host-fallback" "$@" \
        bash "${d}/lib/resolve_deps.sh" "${name}" 2>"${ERR_FILE}")" || RC=$?
  ERR="$(cat "${ERR_FILE}")"
}

echo "== 1. env override wins over every other location =="
H1="${WORK}/h1"; mk_constitution "${H1}"; mk_llmctl "${H1}/submodules/llmctl"
mk_constitution "${WORK}/override/c"
resolve "${H1}/submodules/llmctl" constitution LLMCTL_CONSTITUTION_DIR="${WORK}/override/c"
assert_eq "0" "${RC}" "env override resolves (rc)"
assert_eq "${WORK}/override/c" "${OUT}" "LLMCTL_CONSTITUTION_DIR beats the parent hub"
mk_containers "${WORK}/override/k"; mk_superspec "${WORK}/override/s"
resolve "${H1}/submodules/llmctl" containers LLMCTL_CONTAINERS_DIR="${WORK}/override/k"
assert_eq "${WORK}/override/k" "${OUT}" "LLMCTL_CONTAINERS_DIR honoured"
resolve "${H1}/submodules/llmctl" superspec LLMCTL_SUPERSPEC_DIR="${WORK}/override/s"
assert_eq "${WORK}/override/s" "${OUT}" "LLMCTL_SUPERSPEC_DIR honoured"

echo "== 2. nested at <hub>/submodules/llmctl: hub constitution + flat sibling containers/superspec =="
mk_containers "${H1}/submodules/containers"; mk_superspec "${H1}/submodules/superspec"
resolve "${H1}/submodules/llmctl" constitution
assert_eq "0" "${RC}" "nested: constitution resolves (rc)"
assert_eq "${H1}" "${OUT}" "nested: the hub (../..) IS the constitution"
resolve "${H1}/submodules/llmctl" containers
assert_eq "${H1}/submodules/containers" "${OUT}" "nested: containers resolves to ../containers"
resolve "${H1}/submodules/llmctl" superspec
assert_eq "${H1}/submodules/superspec" "${OUT}" "nested: superspec resolves to ../superspec"

echo "== 3. standalone root layout: <root>/constitution and <root>/submodules/<name> =="
R3="${WORK}/r3/llmctl"; mk_llmctl "${R3}"
mk_constitution "${R3}/constitution"; mk_containers "${R3}/submodules/containers"; mk_superspec "${R3}/submodules/superspec"
resolve "${R3}" constitution
assert_eq "${R3}/constitution" "${OUT}" "root layout: <root>/constitution"
resolve "${R3}" containers
assert_eq "${R3}/submodules/containers" "${OUT}" "root layout: <root>/submodules/containers"

echo "== 4. sibling directories =="
S4="${WORK}/s4"; mk_llmctl "${S4}/llmctl"
mk_constitution "${S4}/constitution"; mk_containers "${S4}/containers"; mk_superspec "${S4}/superspec"
resolve "${S4}/llmctl" constitution
assert_eq "${S4}/constitution" "${OUT}" "sibling constitution"
resolve "${S4}/llmctl" containers
assert_eq "${S4}/containers" "${OUT}" "sibling containers"
resolve "${S4}/llmctl" superspec
assert_eq "${S4}/superspec" "${OUT}" "sibling superspec"

echo "== 5. ancestor walk: <ancestor>/submodules/<name> and <ancestor>/constitution =="
A5="${WORK}/a5"; mk_llmctl "${A5}/deep/er/llmctl"
mk_constitution "${A5}/constitution"; mk_containers "${A5}/submodules/containers"
resolve "${A5}/deep/er/llmctl" constitution
assert_eq "${A5}/constitution" "${OUT}" "ancestor constitution found by walking up"
resolve "${A5}/deep/er/llmctl" containers
assert_eq "${A5}/submodules/containers" "${OUT}" "ancestor submodules/containers found by walking up"

echo "== 6. host fallback (constitution only) =="
F6="${WORK}/f6"; mk_llmctl "${F6}/llmctl"; mk_constitution "${WORK}/hostfb"
resolve "${F6}/llmctl" constitution LLMCTL_HOST_FALLBACK_DIR="${WORK}/hostfb"
assert_eq "0" "${RC}" "host fallback resolves (rc)"
assert_eq "${WORK}/hostfb" "${OUT}" "host fallback is the last resort for the constitution"
resolve "${F6}/llmctl" containers LLMCTL_HOST_FALLBACK_DIR="${WORK}/hostfb"
assert_eq "1" "${RC}" "containers has NO host fallback: an unresolved dependency is an error"

echo "== 7. NEGATIVE CONTROL: nothing resolves -> non-zero + actionable message, never a silent pass =="
N7="${WORK}/n7"; mk_llmctl "${N7}/llmctl"
for dep in constitution containers superspec; do
  resolve "${N7}/llmctl" "${dep}"
  assert_eq "1" "${RC}" "${dep}: unresolved exits 1"
  assert_eq "" "${OUT}" "${dep}: nothing printed on stdout when unresolved"
  assert_contains "${ERR}" "cannot resolve ${dep}" "${dep}: stderr names the dependency"
  assert_contains "${ERR}" "LLMCTL_$(printf '%s' "${dep}" | tr a-z A-Z)_DIR" "${dep}: stderr names the env override"
done

echo "== 8. a candidate lacking the marker file is rejected (empty dir is not a constitution) =="
E8="${WORK}/e8"; mk_llmctl "${E8}/llmctl"; mkdir -p "${E8}/constitution" "${E8}/containers"
: > "${E8}/containers/go.mod"   # a go.mod of some other module
printf 'module example.com/other\n' > "${E8}/containers/go.mod"
resolve "${E8}/llmctl" constitution
assert_eq "1" "${RC}" "empty constitution dir is not accepted"
resolve "${E8}/llmctl" containers
assert_eq "1" "${RC}" "a go.mod of another module is not the containers module"

echo "== 9. an invalid env override is an error, not a silent fall-through =="
resolve "${H1}/submodules/llmctl" constitution LLMCTL_CONSTITUTION_DIR="${WORK}/does-not-exist"
assert_eq "1" "${RC}" "bad override exits 1 although a valid hub exists"
assert_contains "${ERR}" "LLMCTL_CONSTITUTION_DIR" "bad override is named in the message"

echo "== 10. real nesting: this repo's library, sourced as a function library =="
# shellcheck source=/dev/null
( source "${LIB_SRC}"; type llmctl_resolve_dep >/dev/null ) && ok=yes || ok=no
assert_eq "yes" "${ok}" "llmctl_resolve_dep is exported when the library is sourced"

echo "== 11. M3: hub copy beats <root>/submodules/<name> (order pinned, reviewer mutation) =="
H11="${WORK}/h11"; mk_constitution "${H11}"; mk_llmctl "${H11}/submodules/llmctl"
mk_containers "${H11}/submodules/containers"; mk_containers "${H11}/submodules/llmctl/submodules/containers"
resolve "${H11}/submodules/llmctl" containers
assert_eq "${H11}/submodules/containers" "${OUT}" "hub-vendored containers wins over the llmctl-local copy"
# mutation: drop the hub step from a COPY of the library; the same fixture must then pick the local copy,
# proving the assertion above is sensitive to the order (a test that cannot see the swap is decoration).
sed -i '/(step-2-begin)/,/(step-2-end)/d' "${H11}/submodules/llmctl/lib/resolve_deps.sh"
resolve "${H11}/submodules/llmctl" containers
assert_eq "${H11}/submodules/llmctl/submodules/containers" "${OUT}" "MUTATION (hub step removed) changes the answer: the order fixture is load-bearing"

echo "== 12. I2: no built-in host fallback literal; nothing configured -> exit 1 =="
# host-literal needle: any absolute host/user path. Control first: the needle MUST see a planted host path.
HOST_NEEDLE='/home/|/Users/|Projects/'
printf 'x=/home/someone/Projects/y\n' > "${WORK}/needle-control.txt"
if grep -qE "${HOST_NEEDLE}" "${WORK}/needle-control.txt"; then printf '  ok: control needle: the host-literal pattern sees a planted host path\n'
else printf '  FAIL: control needle is blind\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
if grep -qE "${HOST_NEEDLE}" "${LIB_SRC}"; then
  printf '  FAIL: host-specific path literal in lib/resolve_deps.sh\n' >&2; grep -nE "${HOST_NEEDLE}" "${LIB_SRC}" >&2; TEST_FAILS=$((TEST_FAILS+1))
else printf '  ok: resolver has no host-specific path literal\n'; fi
RC=0; OUT="$(env -i PATH="${PATH}" HOME="${WORK}/home" bash "${N7}/llmctl/lib/resolve_deps.sh" constitution 2>/dev/null)" || RC=$?
assert_eq "1" "${RC}" "no LLMCTL_HOST_FALLBACK_DIR and nothing nearby: exit 1"

echo "== 13. M2/N1: relative override is made absolute; empty override is an error =="
mkdir -p "${WORK}/rel/c"; : > "${WORK}/rel/c/Constitution.md"
RC=0; OUT="$(cd "${WORK}/rel" && env -i PATH="${PATH}" HOME="${WORK}/home" CDPATH="${WORK}" LLMCTL_CONSTITUTION_DIR=c bash "${H1}/submodules/llmctl/lib/resolve_deps.sh" constitution 2>/dev/null)" || RC=$?
assert_eq "${WORK}/rel/c" "${OUT}" "relative override c -> absolute path (and a hostile CDPATH does not change it)"
RC=0; OUT="$(cd "${WORK}/rel" && env -i PATH="${PATH}" HOME="${WORK}/home" LLMCTL_CONSTITUTION_DIR=c/../c bash "${H1}/submodules/llmctl/lib/resolve_deps.sh" constitution 2>/dev/null)" || RC=$?
assert_eq "${WORK}/rel/c" "${OUT}" "a relative override with .. is normalised (no .. in the result)"
resolve "${H1}/submodules/llmctl" constitution LLMCTL_CONSTITUTION_DIR=
assert_eq "1" "${RC}" "empty-but-set override is an error"

echo "== 14. M5: a real <root>/constitution directory (old gitlink leftover) is warned about =="
W14="${WORK}/w14/llmctl"; mk_llmctl "${W14}"; mk_constitution "${W14}/constitution"
resolve "${W14}" constitution
assert_eq "${W14}/constitution" "${OUT}" "still resolves to the real directory"
assert_contains "${ERR}" "real directory" "...with a warning on stderr"

test_finish
