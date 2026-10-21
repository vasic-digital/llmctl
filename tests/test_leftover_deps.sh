#!/usr/bin/env bash
# test_leftover_deps.sh - UPGRADE LEFTOVERS (detect + warn + manual remediation ONLY), the opt-in Go-suite guard and dry-run.
#
# git does not delete a populated submodule worktree when its gitlink is removed, so an existing checkout keeps REAL
# directories constitution/, submodules/containers/ and submodules/superspec/ (now .gitignored, i.e. hidden). Proven here,
# against throw-away fixtures only:
#   1. link_deps names the leftover and prints a MANUAL remediation: when the leftover is the ONLY copy it says clone it to a
#      directory OUTSIDE the repository and set LLMCTL_<DEP>_DIR to that clone (never "rm -rf" first, never a destination
#      inside the tree: a renamed copy stays an untracked embedded repo whose core.worktree still points here); when a shared
#      copy exists it says verify clean (status, unpushed commits, stash), then rm -rf;
#   2. NO code moves, renames or deletes a user directory; the old "adopt" convenience is gone, a flag attempting it is refused;
#   3. the resolver warns for every dependency, also when the hub copy wins over a real <root>/<name>;
#   4. engine_ensure_containers builds from a leftover ONLY when it is the resolver's own answer and clean; never when a
#      different copy resolves, never when dirty;
#   5. require_containers_or_skip is OPT-IN: sourcing helpers.sh probes/links/skips nothing, a suite that merely mentions
#      llmctl-decide still runs, a genuine FAIL stays a FAIL; an opted-in suite SKIPs loudly when containers is unresolvable;
#   6. dry-run: resolver message, no link, and NO go invocation (a fake go on PATH fails the test if called).
set -euo pipefail
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

echo "== 1. standalone: leftover REAL submodules/containers is the ONLY copy =="
S="${WORK}/s/llmctl"; mk_clone "${S}"; mkdir -p "${S}/submodules/containers"; printf 'module digital.vasic.containers\n' > "${S}/submodules/containers/go.mod"
ld "${S}" containers
assert_eq "1" "${RC}" "link_deps: a leftover real dir blocks (exit 1)"
assert_contains "${OUT}" "LEFTOVER submodules/containers" "names it a LEFTOVER"
assert_contains "${OUT}" "only copy found" "says it is the only copy"
assert_contains "${OUT}" "git clone ${S}/submodules/containers" "remediation: clone the leftover"
assert_contains "${OUT}" "OUTSIDE this repository" "...to a directory OUTSIDE the repository"
assert_contains "${OUT}" "LLMCTL_CONTAINERS_DIR=" "...and point LLMCTL_CONTAINERS_DIR at the clone"
case "${OUT}" in *"mv "*|*".old"*) TEST_FAILS=$((TEST_FAILS+1)); echo "  FAIL: an in-tree move/rename destination is advised: ${OUT}" >&2;; *) echo "  ok: no mv / .old advice";; esac
case "${OUT}" in *"rm -rf"*) TEST_FAILS=$((TEST_FAILS+1)); echo "  FAIL: rm -rf advised although the leftover is the only copy" >&2;; *) echo "  ok: no rm -rf advice for the only copy";; esac
assert_file_exists "${S}/submodules/containers/go.mod" "nothing was moved or deleted"
run "${S}" env LLMCTL_CONTAINERS_DIR="${S}/submodules/containers" bash "${S}/scripts/link_deps.sh" containers
assert_contains "${OUT}" "LEFTOVER" "an override pointing at the leftover gets the same treatment"
run "${S}" bash -c "source '${S}/lib/engine.sh'; engine_ensure_containers"
assert_eq "0" "${RC}" "engine_ensure_containers builds from a clean leftover that is the resolver's own answer"
assert_contains "${OUT}" "leftover" "...and warns about it"

echo "== 2. hub layout: leftover real containers while the hub provides one =="
mk_hub "${WORK}/hub"; HL="${WORK}/hub/submodules/llmctl"; mk_clone "${HL}"
mkdir -p "${HL}/submodules/containers"; printf 'module digital.vasic.containers\n' > "${HL}/submodules/containers/go.mod"
ld "${HL}" containers
assert_eq "1" "${RC}" "hub layout: leftover real dir still blocks the link"
assert_contains "${OUT}" "LEFTOVER submodules/containers" "...and is named"
assert_contains "${OUT}" "git -C ${HL}/submodules/containers status --porcelain" "shared copy exists: prints the verify command"
assert_contains "${OUT}" "rm -rf ${HL}/submodules/containers" "...and the removal command"
assert_contains "${OUT}" "log --branches --not --remotes --oneline" "M-2: unpushed commits must be checked too"
assert_contains "${OUT}" "stash list" "M-2: so must the stash"
RC=0; OUT="$(env -i PATH="${PATH}" HOME="${WORK}/h" bash "${HL}/lib/resolve_deps.sh" containers 2>"${WORK}/err")" || RC=$?
assert_eq "${WORK}/hub/submodules/containers" "${OUT}" "the hub copy wins (step 2)"
assert_contains "$(cat "${WORK}/err")" "real directory" "...and the shadowed real directory is warned about"
run "${HL}" bash -c "source '${HL}/lib/engine.sh'; engine_ensure_containers"
assert_eq "1" "${RC}" "I3: engine_ensure_containers REFUSES a leftover when a different (hub) copy resolves"
assert_contains "${OUT}" "LEFTOVER" "...printing the LEFTOVER remediation"
assert_contains "${OUT}" "must not be built from" "...and stopping"

echo "== 3. hub layout: leftover real constitution / superspec are warned about =="
mkdir -p "${HL}/constitution"; : > "${HL}/constitution/Constitution.md"
RC=0; OUT="$(env -i PATH="${PATH}" HOME="${WORK}/h" bash "${HL}/lib/resolve_deps.sh" constitution 2>"${WORK}/err")" || RC=$?
assert_eq "${WORK}/hub" "${OUT}" "hub constitution wins"
assert_contains "$(cat "${WORK}/err")" "real directory" "a leftover real constitution is no longer silent"
mkdir -p "${S}/submodules/superspec"; : > "${S}/submodules/superspec/extension.yml"
RC=0; OUT="$(env -i PATH="${PATH}" HOME="${WORK}/h" bash "${S}/lib/resolve_deps.sh" superspec 2>&1)" || RC=$?
assert_contains "${OUT}" "real directory" "a leftover real superspec is warned about too (every dependency)"

echo "== 4. no code moves or deletes a user directory; a dirty leftover is never built =="
A="${WORK}/a/llmctl"; mk_clone "${A}"; mk_gitfile_repo "${A}/submodules/containers"
run "${A}" bash "${A}/scripts/link_deps.sh" --adopt-leftover containers
assert_eq "yes" "$([[ "${RC}" -ne 0 && -d "${A}/submodules/containers" && ! -L "${A}/submodules/containers" ]] && echo yes || echo no)" "--adopt-leftover does not exist: refused, directory untouched"
assert_eq "none" "$(ls -d "${A}"/submodules/containers.leftover-* 2>/dev/null | head -1 || true)$([[ -z "$(ls -d "${A}"/submodules/containers.leftover-* 2>/dev/null)" ]] && echo none)" "...and nothing was moved aside"
: > "${A}/submodules/containers/dirty.txt"
run "${A}" bash -c "source '${A}/lib/engine.sh'; engine_ensure_containers"
assert_eq "1" "${RC}" "a dirty leftover that is the only copy is NEVER built from"
assert_file_exists "${A}/submodules/containers/dirty.txt" "...and is left exactly as it was"

echo "== 4b. M-1: a git status that FAILS is not 'clean' =="
B="${WORK}/b/llmctl"; mk_clone "${B}"; mkdir -p "${B}/submodules/containers"; printf 'module digital.vasic.containers\n' > "${B}/submodules/containers/go.mod"
printf 'gitdir: %s/missing-gitdir\n' "${WORK}" > "${B}/submodules/containers/.git"; : > "${B}/submodules/containers/untracked.txt"
RC=0; git -C "${B}/submodules/containers" status --porcelain >/dev/null 2>&1 || RC=$?
assert_eq "128" "${RC}" "precondition: git status itself fails (rc 128) on this leftover"
run "${B}" bash -c "source '${B}/lib/engine.sh'; engine_ensure_containers"
assert_eq "1" "${RC}" "a leftover whose git status FAILS is refused, not built from"
assert_file_exists "${B}/submodules/containers/untracked.txt" "...and left exactly as it was"

echo "== 4c. I-1 class-exhaustive: NO remediation text suggests a destination inside the tree =="
BAD_RE='(^|[^[:alnum:]_])mv [^|;]*\.(old|bak|orig|leftover)|\.leftover-|\.old([^[:alnum:]_]|$)'
printf 'or move it: mv /r/x /r/x.old and re-run\n' > "${WORK}/needle.txt"
if grep -qE "${BAD_RE}" "${WORK}/needle.txt"; then echo "  ok: control needle: the pattern sees a planted in-tree move advice"; else printf '  FAIL: control needle blind\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
printf 'git clone /r/x /elsewhere/x then LLMCTL_X_DIR=/elsewhere/x\n' > "${WORK}/clean.txt"
if grep -qE "${BAD_RE}" "${WORK}/clean.txt"; then printf '  FAIL: negative control matched\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else echo "  ok: negative control: the new advice is not flagged"; fi
hits="$(cd "${LLMCTL_ROOT}" && grep -nE "${BAD_RE}" lib/*.sh scripts/link_deps.sh docs/dependency-layout.md README.md Makefile CHANGELOG.md 2>/dev/null || true)"
assert_eq "" "${hits}" "no printed or documented remediation (lib, scripts, docs, README, Makefile, CHANGELOG) names an in-tree destination"
assert_eq "" "$(printf '%s\n' "${OUT:-}" | grep -E "${BAD_RE}" || true)" "last captured output is clean too"
run "${HL}" bash "${HL}/lib/resolve_deps.sh" containers
assert_eq "" "$(printf '%s\n' "${OUT}" | grep -E "${BAD_RE}" || true)" "resolver leftover warnings name no in-tree destination"
assert_contains "${OUT}" "real directory" "...(and still warn)"

echo "== 5. require_containers_or_skip is opt-in =="
GS="${WORK}/g/llmctl"; mk_clone "${GS}"
printf '#!/usr/bin/env bash\nset -euo pipefail\nsource "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"\nrequire_containers_or_skip\nassert_eq 1 1 "optin body ran"\ntest_finish\n' > "${GS}/tests/test_optin.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\nsource "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"\n# mentions llmctl-decide and go build ./cmd/llmctl-decide only in a comment\nfake=llmctl-decide\nassert_eq 1 1 "mention body ran"\ntest_finish\n' > "${GS}/tests/test_mention.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\nsource "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"\n# go build ./cmd/llmctl-decide\nassert_eq 1 2 "genuine failure"\ntest_finish\n' > "${GS}/tests/test_realfail.sh"
run "${GS}" bash "${GS}/tests/test_optin.sh"
assert_eq "0" "${RC}" "opted-in suite, containers unresolvable: exit 0 (a SKIP)"
assert_contains "${OUT}" "SKIP-SUITE:" "...printing SKIP-SUITE"
assert_contains "${OUT}" "cannot resolve containers" "...with the resolver's message"
case "${OUT}" in *"optin body ran"*) TEST_FAILS=$((TEST_FAILS+1)); echo "  FAIL: the body ran" >&2;; *) echo "  ok: the body did not run";; esac
run "${GS}" bash "${GS}/tests/test_mention.sh"
assert_contains "${OUT}" "mention body ran" "NEGATIVE: a suite that only MENTIONS llmctl-decide still runs (not skipped wholesale)"
run "${GS}" bash "${GS}/tests/test_realfail.sh"
assert_eq "1" "${RC}" "NEGATIVE: a real FAIL stays a FAIL when containers is unresolvable"
assert_eq "no" "$([[ -e "${GS}/submodules/containers" || -L "${GS}/submodules/containers" || -e "${GS}/constitution" ]] && echo yes || echo no)" "sourcing helpers.sh created no links in the checkout"
mk_hub "${WORK}/g2"; GH="${WORK}/g2/submodules/llmctl"; mk_clone "${GH}"; cp "${GS}/tests/test_optin.sh" "${GH}/tests/"
run "${GH}" bash "${GH}/tests/test_optin.sh"
assert_contains "${OUT}" "optin body ran" "positive control: resolvable -> the opted-in body runs"

echo "== 6. dry-run: resolver message, no link, NO go invocation =="
D="${WORK}/d/llmctl"; mk_clone "${D}"
run "${D}" env LLMCTL_DRY_RUN=1 bash "${D}/bin/llmctl" build decide
assert_eq "0" "${RC}" "unresolvable + dry-run: exit 0"
assert_contains "${OUT}" "cannot resolve containers" "the resolver message is printed in dry-run"
assert_eq "no" "$([[ -e "${D}/submodules/containers" || -L "${D}/submodules/containers" ]] && echo yes || echo no)" "no link created"
mk_hub "${WORK}/d2"; DH="${WORK}/d2/submodules/llmctl"; mk_clone "${DH}"
FAKEBIN="${WORK}/fakebin"; mkdir -p "${FAKEBIN}"; printf '#!/bin/sh\necho CALLED > "%s/go-called"\nexit 99\n' "${WORK}" > "${FAKEBIN}/go"; chmod +x "${FAKEBIN}/go"
run "${DH}" env PATH="${FAKEBIN}:${PATH}" LLMCTL_DRY_RUN=1 bash "${DH}/bin/llmctl" build decide
assert_eq "0" "${RC}" "resolvable + dry-run: exit 0"
assert_contains "${OUT}" "[dry-run] would build" "the build step is only announced"
assert_eq "no" "$([[ -e "${WORK}/go-called" ]] && echo yes || echo no)" "the go toolchain was NOT invoked (fake go on PATH)"
assert_eq "no" "$([[ -e "${DH}/submodules/containers" || -L "${DH}/submodules/containers" ]] && echo yes || echo no)" "no link created"
run "${DH}" env PATH="${FAKEBIN}:${PATH}" bash -c "source '${DH}/lib/engine.sh'; LLMCTL_DRY_RUN=1 engine_build_decide"
assert_eq "no" "$([[ -e "${WORK}/go-called" ]] && echo yes || echo no)" "engine_build_decide directly: still no go call"

test_finish
