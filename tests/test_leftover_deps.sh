#!/usr/bin/env bash
# test_leftover_deps.sh - review round 3: UPGRADE LEFTOVERS and the Go-suite guard.
#
# git does not delete a populated submodule worktree when its gitlink is removed, so after pulling the
# "single source of truth" change an existing checkout keeps REAL directories constitution/, submodules/containers/
# and submodules/superspec/ (now .gitignored, i.e. hidden). This suite proves, against throw-away fixtures only:
#   1. link_deps names the leftover and prints the exact remediation (verify clean, rm -rf), never the misleading
#      "set LLMCTL_*_DIR to it" advice; 2. engine_ensure_containers accepts a valid leftover (warn + continue);
#   3. the resolver warns for every dependency, also when the hub copy wins over a real <root>/<name>;
#   4. --adopt-leftover moves ONLY a clean gitfile-style leftover whose HEAD equals the old pin, to
#      <path>.leftover-<date> (never deleted, section 9.2) and links; dirty / wrong-pin / plain-dir leftovers are refused;
#   5. M2 helpers.sh guard: a Go-building suite SKIPs loudly (SKIP-SUITE + resolver message) when containers is
#      unresolvable; M3 dry-run prints the resolver message and creates nothing.
set -euo pipefail
export LLMCTL_TEST_NO_DEPS_GUARD=1
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/llmctl-leftover.XXXXXX")"
trap 'rm -rf -- "${WORK}"' EXIT
G() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }
mk_clone() { mkdir -p "$1/bin" "$1/scripts" "$1/tests"; cp -r "${LLMCTL_ROOT}/lib" "$1/"; cp "${LLMCTL_ROOT}/bin/llmctl" "$1/bin/"
             cp "${LLMCTL_ROOT}/scripts/link_deps.sh" "$1/scripts/"; cp "${LLMCTL_ROOT}/tests/helpers.sh" "$1/tests/"; rm -rf "$1/lib/__pycache__"; }
mk_hub() { mkdir -p "$1/submodules/containers" "$1/submodules/superspec"; : > "$1/Constitution.md"
           printf 'module digital.vasic.containers\n' > "$1/submodules/containers/go.mod"; : > "$1/submodules/superspec/extension.yml"; }
# mk_gitfile_repo <worktree> : a git worktree whose .git is a FILE pointing at a separate gitdir (submodule style)
mk_gitfile_repo() { mkdir -p "$(dirname "$1")"; G init -q --separate-git-dir="$1.gitdir" "$1"; printf 'module digital.vasic.containers\n' > "$1/go.mod"
                    G -C "$1" add go.mod; G -C "$1" commit -qm i; }
run() { local d="$1"; shift; RC=0; OUT="$(env -i PATH="${PATH}" HOME="${WORK}/h" "$@" 2>&1)" || RC=$?; }
ld() { local d="$1"; shift; run "${d}" bash "${d}/scripts/link_deps.sh" "$@"; }

echo "== 1. standalone: leftover REAL submodules/containers (plain dir) =="
S="${WORK}/s/llmctl"; mk_clone "${S}"; mkdir -p "${S}/submodules/containers"; printf 'module digital.vasic.containers\n' > "${S}/submodules/containers/go.mod"
ld "${S}" containers
assert_eq "1" "${RC}" "link_deps: a leftover real dir blocks (exit 1)"
assert_contains "${OUT}" "LEFTOVER submodules/containers" "names it a LEFTOVER"
assert_contains "${OUT}" "git -C ${S}/submodules/containers status --porcelain" "prints the verify command"
assert_contains "${OUT}" "rm -rf ${S}/submodules/containers" "prints the exact removal command"
case "${OUT}" in *"set LLMCTL_"*) TEST_FAILS=$((TEST_FAILS+1)); echo "  FAIL: misleading 'set LLMCTL_*_DIR to it' advice still printed" >&2;; *) echo "  ok: no 'set LLMCTL_*_DIR to it' advice";; esac
ld "${S}" containers   # again, with the leftover as an explicit override
run "${S}" env LLMCTL_CONTAINERS_DIR="${S}/submodules/containers" bash "${S}/scripts/link_deps.sh" containers
assert_contains "${OUT}" "LEFTOVER" "an override pointing at the leftover gets the same remediation"
run "${S}" bash -c "source '${S}/lib/engine.sh'; engine_ensure_containers"
assert_eq "0" "${RC}" "engine_ensure_containers accepts a valid leftover real dir"
assert_contains "${OUT}" "leftover" "...and warns about it"

echo "== 2. hub layout: leftover real containers while the hub provides one =="
mk_hub "${WORK}/hub"; HL="${WORK}/hub/submodules/llmctl"; mk_clone "${HL}"
mkdir -p "${HL}/submodules/containers"; printf 'module digital.vasic.containers\n' > "${HL}/submodules/containers/go.mod"
ld "${HL}" containers
assert_eq "1" "${RC}" "hub layout: leftover real dir still blocks the link"
assert_contains "${OUT}" "LEFTOVER submodules/containers" "...and is named"
RC=0; OUT="$(env -i PATH="${PATH}" HOME="${WORK}/h" bash "${HL}/lib/resolve_deps.sh" containers 2>"${WORK}/err")" || RC=$?
assert_eq "${WORK}/hub/submodules/containers" "${OUT}" "the hub copy wins (step 2)"
assert_contains "$(cat "${WORK}/err")" "real directory" "...and the shadowed real directory is warned about"

echo "== 3. hub layout: leftover real constitution =="
mkdir -p "${HL}/constitution"; : > "${HL}/constitution/Constitution.md"
RC=0; OUT="$(env -i PATH="${PATH}" HOME="${WORK}/h" bash "${HL}/lib/resolve_deps.sh" constitution 2>"${WORK}/err")" || RC=$?
assert_eq "${WORK}/hub" "${OUT}" "hub constitution wins"
assert_contains "$(cat "${WORK}/err")" "real directory" "a leftover real constitution is no longer silent"
RC=0; OUT="$(env -i PATH="${PATH}" HOME="${WORK}/h" bash "${S}/lib/resolve_deps.sh" superspec 2>&1)" || RC=$?
mkdir -p "${S}/submodules/superspec"; : > "${S}/submodules/superspec/extension.yml"
RC=0; OUT="$(env -i PATH="${PATH}" HOME="${WORK}/h" bash "${S}/lib/resolve_deps.sh" superspec 2>&1)" || RC=$?
assert_contains "${OUT}" "real directory" "a leftover real superspec is warned about too (every dependency)"

echo "== 4. --adopt-leftover =="
A="${WORK}/a/llmctl"; mk_clone "${A}"
mk_gitfile_repo "${A}/submodules/containers"; PIN="$(G -C "${A}/submodules/containers" rev-parse HEAD)"
ld "${A}" containers
assert_eq "1" "${RC}" "without the flag a clean leftover is NOT touched"
assert_eq "yes" "$([[ -d "${A}/submodules/containers" && ! -L "${A}/submodules/containers" ]] && echo yes || echo no)" "...it is still the real directory"
: > "${A}/submodules/containers/dirty.txt"
run "${A}" env LLMCTL_ADOPT_PIN_CONTAINERS="${PIN}" bash "${A}/scripts/link_deps.sh" --adopt-leftover containers
assert_eq "1" "${RC}" "dirty leftover refused"
assert_contains "${OUT}" "not clean" "...with the reason"
assert_file_exists "${A}/submodules/containers/dirty.txt" "...and nothing was moved or deleted"
rm -f "${A}/submodules/containers/dirty.txt"
run "${A}" env LLMCTL_ADOPT_PIN_CONTAINERS="0000000000000000000000000000000000000001" bash "${A}/scripts/link_deps.sh" --adopt-leftover containers
assert_eq "1" "${RC}" "HEAD != recorded pin refused"
assert_contains "${OUT}" "HEAD" "...with the reason"
P="${WORK}/p/llmctl"; mk_clone "${P}"; mkdir -p "${P}/submodules/containers"; printf 'module digital.vasic.containers\n' > "${P}/submodules/containers/go.mod"
run "${P}" env LLMCTL_ADOPT_PIN_CONTAINERS="${PIN}" bash "${P}/scripts/link_deps.sh" --adopt-leftover containers
assert_eq "1" "${RC}" "a plain (non-gitfile) directory is refused"
run "${A}" env LLMCTL_ADOPT_PIN_CONTAINERS="${PIN}" LLMCTL_CONTAINERS_DIR="${WORK}/a/real-k" bash -c "mkdir -p '${WORK}/a/real-k'; printf 'module digital.vasic.containers\n' > '${WORK}/a/real-k/go.mod'; bash '${A}/scripts/link_deps.sh' --adopt-leftover containers"
assert_eq "0" "${RC}" "clean gitfile leftover with HEAD == pin is adopted"
assert_eq "yes" "$([[ -L "${A}/submodules/containers" ]] && echo yes || echo no)" "...the path is now a link"
moved="$(ls -d "${A}"/submodules/containers.leftover-* 2>/dev/null | head -1)"
assert_eq "yes" "$([[ -n "${moved}" && -f "${moved}/go.mod" ]] && echo yes || echo no)" "...and the old tree was MOVED (nothing deleted): ${moved##*/}"

echo "== 5. M2 guard: a Go-building suite SKIPs loudly when containers is unresolvable =="
GS="${WORK}/g/llmctl"; mk_clone "${GS}"
printf '#!/usr/bin/env bash\nset -euo pipefail\nsource "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"\n# uses: go build ./cmd/llmctl-decide\nassert_eq 1 1 "suite body ran"\ntest_finish\n' > "${GS}/tests/test_gosuite.sh"
run "${GS}" bash "${GS}/tests/test_gosuite.sh"
assert_eq "0" "${RC}" "unresolvable: the suite exits 0 (a SKIP, not a FAIL)"
assert_contains "${OUT}" "SKIP-SUITE:" "...printing SKIP-SUITE"
assert_contains "${OUT}" "cannot resolve containers" "...with the resolver's message"
case "${OUT}" in *"suite body ran"*) TEST_FAILS=$((TEST_FAILS+1)); echo "  FAIL: the body ran" >&2;; *) echo "  ok: the body did not run";; esac
mk_hub "${WORK}/g2"; GH="${WORK}/g2/submodules/llmctl"; mk_clone "${GH}"; cp "${GS}/tests/test_gosuite.sh" "${GH}/tests/"
run "${GH}" bash "${GH}/tests/test_gosuite.sh"
assert_contains "${OUT}" "suite body ran" "positive control: resolvable -> the body runs"

echo "== 6. M3 dry-run: resolver message, nothing created =="
D="${WORK}/d/llmctl"; mk_clone "${D}"
run "${D}" env LLMCTL_DRY_RUN=1 bash "${D}/bin/llmctl" build decide
assert_contains "${OUT}" "cannot resolve containers" "unresolvable: the resolver message is printed in dry-run"
assert_eq "no" "$([[ -e "${D}/submodules/containers" || -L "${D}/submodules/containers" ]] && echo yes || echo no)" "no link created"
mk_hub "${WORK}/d2"; DH="${WORK}/d2/submodules/llmctl"; mk_clone "${DH}"
run "${DH}" env LLMCTL_DRY_RUN=1 bash "${DH}/bin/llmctl" build decide
assert_eq "no" "$([[ -e "${DH}/submodules/containers" || -L "${DH}/submodules/containers" ]] && echo yes || echo no)" "resolvable: still no link created in dry-run"
assert_contains "${OUT}" "[dry-run]" "...announced as a dry-run action"

test_finish
