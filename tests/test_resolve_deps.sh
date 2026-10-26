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
  OUT="$(env -i PATH="${PATH}" HOME="${WORK}/home" LLMCTL_RESOLVE_STOP_AT="${WORK}" LLMCTL_HOST_FALLBACK_DIR="${WORK}/no-such-host-fallback" "$@" \
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
RC=0; OUT="$(env -i PATH="${PATH}" HOME="${WORK}/home" LLMCTL_RESOLVE_STOP_AT="${WORK}" bash "${N7}/llmctl/lib/resolve_deps.sh" constitution 2>/dev/null)" || RC=$?
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

echo "== 15. decoy: the ancestor walk never reaches into a .cache directory, and honours LLMCTL_RESOLVE_STOP_AT / HOME =="
# A stray copy under ~/.cache/submodules (a cache, not a source) must not satisfy resolution for a checkout that lives
# below the same .cache directory (the 3.3.0 review finding: five suites failed whenever TMPDIR was under ~/.cache).
D15="${WORK}/fakehome/.cache"; mk_llmctl "${D15}/work/llmctl"
mk_constitution "${D15}/submodules/constitution"; mk_containers "${D15}/submodules/containers"
resolve "${D15}/work/llmctl" constitution
assert_eq "1" "${RC}" "decoy constitution under a .cache ancestor is NOT picked up (rc)"
assert_eq "" "${OUT}" "decoy: nothing printed on stdout"
resolve "${D15}/work/llmctl" containers
assert_eq "1" "${RC}" "decoy containers under a .cache ancestor is NOT picked up (rc)"
# positive control: the SAME layout without the .cache component resolves (so rc 1 above is the boundary, not a broken fixture)
P15="${WORK}/plain15"; mk_llmctl "${P15}/work/llmctl"; mk_constitution "${P15}/submodules/constitution"
resolve "${P15}/work/llmctl" constitution
assert_eq "${P15}/submodules/constitution" "${OUT}" "positive control: same layout without .cache resolves"
# explicit boundary: a decoy above LLMCTL_RESOLVE_STOP_AT is ignored, one at the boundary is used
S15="${WORK}/stop15"; mk_llmctl "${S15}/inner/x/llmctl"; mk_constitution "${S15}/submodules/constitution"
resolve "${S15}/inner/x/llmctl" constitution
assert_eq "${S15}/submodules/constitution" "${OUT}" "without a boundary the ancestor above is used (control)"
resolve "${S15}/inner/x/llmctl" constitution LLMCTL_RESOLVE_STOP_AT="${S15}/inner"
assert_eq "1" "${RC}" "LLMCTL_RESOLVE_STOP_AT stops the walk below the decoy"
mk_constitution "${S15}/inner/submodules/constitution"
resolve "${S15}/inner/x/llmctl" constitution LLMCTL_RESOLVE_STOP_AT="${S15}/inner"
assert_eq "${S15}/inner/submodules/constitution" "${OUT}" "the boundary directory itself is still examined"
# HOME is a boundary: nothing above $HOME is examined
H15="${WORK}/home15"; mk_llmctl "${H15}/home/u/llmctl"; mk_constitution "${H15}/submodules/constitution"
resolve "${H15}/home/u/llmctl" constitution HOME="${H15}/home"
assert_eq "1" "${RC}" "the walk stops at HOME (a copy above HOME is ignored)"

echo "== 16. HOME is an inclusive bound for the ANCESTOR WALK, with and without a trailing slash =="
# Layout: the root is R16/x/llmctl, so R16/submodules/containers and R16/constitution are reachable ONLY by the walk
# (not step 3 = <root>/..., not step 4 = the root's sibling dirs). HOME == R16 is the boundary directory itself.
R16="${WORK}/root16"; mk_llmctl "${R16}/x/llmctl"; mk_constitution "${R16}/constitution"; mk_containers "${R16}/submodules/containers"
resolve "${R16}/x/llmctl" constitution HOME="${R16}"
assert_eq "${R16}/constitution" "${OUT}" "HOME == boundary: <boundary>/constitution is found by the walk (HOME is inclusive)"
resolve "${R16}/x/llmctl" containers HOME="${R16}"
assert_eq "${R16}/submodules/containers" "${OUT}" "HOME == boundary: <boundary>/submodules/containers is found by the walk (HOME is inclusive)"
resolve "${R16}/x/llmctl" constitution HOME="${R16}/"
assert_eq "${R16}/constitution" "${OUT}" "HOME with a trailing slash == boundary still resolves"
resolve "${R16}/x/llmctl" containers HOME="${R16}/x"
assert_eq "1" "${RC}" "HOME one level BELOW the boundary: the walk stops before it, so containers is NOT found (the bound is real)"
# trailing slash must still STOP the walk at HOME (a copy above HOME stays ignored)
T16="${WORK}/trail16"; mk_llmctl "${T16}/home/u/llmctl"; mk_constitution "${T16}/submodules/constitution"
resolve "${T16}/home/u/llmctl" constitution HOME="${T16}/home/"
assert_eq "1" "${RC}" "HOME with a trailing slash still stops the walk (copy above HOME ignored)"
resolve "${T16}/home/u/llmctl" constitution LLMCTL_RESOLVE_STOP_AT="${T16}/home/"
assert_eq "1" "${RC}" "LLMCTL_RESOLVE_STOP_AT with a trailing slash still stops the walk"

echo "== 18. a bound that is the llmctl root itself, or lies below it, means NO ancestor is walked =="
# 3.3.0 review round 3: the walk starts at the root's parent, so such a bound was never met and a copy ABOVE it still resolved.
B18="${WORK}/b18"; mk_llmctl "${B18}/a/b/llmctl"
mk_constitution "${B18}/submodules/constitution"; mk_containers "${B18}/submodules/containers"; mk_superspec "${B18}/submodules/superspec"
R18="${B18}/a/b/llmctl"
for _n in constitution containers superspec; do
  resolve "${R18}" "${_n}" HOME="${R18}" LLMCTL_RESOLVE_STOP_AT=/
  assert_eq "1" "${RC}" "HOME == root: ${_n} planted above the root is NOT resolved"
  resolve "${R18}" "${_n}" HOME="${R18}/"
  assert_eq "1" "${RC}" "HOME == root (trailing slash): ${_n} planted above is NOT resolved"
  resolve "${R18}" "${_n}" HOME=/ LLMCTL_RESOLVE_STOP_AT="${R18}"
  assert_eq "1" "${RC}" "STOP_AT == root: ${_n} planted above the root is NOT resolved"
  resolve "${R18}" "${_n}" HOME=/ LLMCTL_RESOLVE_STOP_AT="${R18}/lib"
  assert_eq "1" "${RC}" "STOP_AT below the root: ${_n} planted above is NOT resolved"
done
# control: with a bound ABOVE the root the same layout does resolve (the planted copies are valid and findable)
resolve "${R18}" constitution HOME="${B18}"
assert_eq "${B18}/submodules/constitution" "${OUT}" "control: HOME above the root DOES find the planted constitution (the fixture is valid)"
# a bound at the root must not disable the non-walk steps: <root>/constitution still resolves
mk_constitution "${R18}/constitution"
resolve "${R18}" constitution HOME="${R18}" LLMCTL_RESOLVE_STOP_AT=/
assert_eq "${R18}/constitution" "${OUT}" "HOME == root: step 3 (<root>/constitution) still resolves"

echo "== 19. containment is physical, and an unprovable bound fails closed (symlinked spelling, relative, empty) =="
B19="${WORK}/b19"; mk_llmctl "${B19}/a/b/llmctl"
mk_constitution "${B19}/submodules/constitution"; mk_containers "${B19}/submodules/containers"; mk_superspec "${B19}/submodules/superspec"
R19="${B19}/a/b/llmctl"; ln -s "${R19}" "${B19}/rootlink"; ln -s "${R19}" "${B19}/boundlink"
for _n in constitution containers superspec; do
  resolve "${B19}/rootlink" "${_n}" HOME="${R19}" LLMCTL_RESOLVE_STOP_AT=/
  assert_eq "1" "${RC}" "root reached through a symlink, HOME == physical root: ${_n} planted above is NOT resolved"
  resolve "${R19}" "${_n}" HOME="${B19}/boundlink" LLMCTL_RESOLVE_STOP_AT=/
  assert_eq "1" "${RC}" "HOME is a symlink spelling of the root: ${_n} planted above is NOT resolved"
  resolve "${R19}" "${_n}" HOME=/ LLMCTL_RESOLVE_STOP_AT="${B19}/boundlink"
  assert_eq "1" "${RC}" "STOP_AT is a symlink spelling of the root: ${_n} planted above is NOT resolved"
  resolve "${R19}" "${_n}" HOME="a/b/llmctl" LLMCTL_RESOLVE_STOP_AT=/
  assert_eq "1" "${RC}" "relative HOME fails closed: ${_n} planted above is NOT resolved"
  resolve "${R19}" "${_n}" HOME=/ LLMCTL_RESOLVE_STOP_AT="a/b"
  assert_eq "1" "${RC}" "relative STOP_AT fails closed: ${_n} planted above is NOT resolved"
  resolve "${R19}" "${_n}" HOME= LLMCTL_RESOLVE_STOP_AT=/
  assert_eq "1" "${RC}" "empty HOME fails closed: ${_n} planted above is NOT resolved"
done
resolve "${R19}" constitution HOME="${B19}"
assert_eq "${B19}/submodules/constitution" "${OUT}" "control: an absolute HOME above the root still finds the planted constitution"

echo "== 17. host isolation: a submodules/<dep> planted in an ancestor of TMPDIR (outside any .cache) must not change the result =="
# The class behind the 3.3.0 review finding: the suite's own negative controls must not depend on what sits above TMPDIR.
if [[ -z "${LLMCTL_RD_CHILD:-}" ]]; then
  POISON="${WORK}/poison17"
  mk_constitution "${POISON}/submodules/constitution"; mk_containers "${POISON}/submodules/containers"; mk_superspec "${POISON}/submodules/superspec"
  mkdir -p "${POISON}/tmp"
  CH_RC=0
  CH_OUT="$(env LLMCTL_RD_CHILD=1 TMPDIR="${POISON}/tmp" bash "${BASH_SOURCE[0]}" 2>&1)" || CH_RC=$?
  assert_eq "0" "${CH_RC}" "this suite passes when TMPDIR sits below a directory holding submodules/{constitution,containers,superspec}"
  [[ "${CH_RC}" -eq 0 ]] || printf '%s\n' "${CH_OUT}" | grep -E 'FAIL' | head -5 >&2
fi

test_finish
