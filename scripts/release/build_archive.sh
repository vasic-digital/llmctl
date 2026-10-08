#!/usr/bin/env bash
# build_archive.sh - produces <output>.tar.gz and <output>.zip containing
# the TRACKED working tree of a source directory (main repo + every submodule
# recursively, arbitrary nesting depth), plus a SANITISED .git (see below),
# excluding build-output directories and NEVER untracked/ignored files (so a
# planted .env, cert/ or *.key cannot enter a release - spec 009 FR-087 / D-30).
# An independent post-scan (scripts/release/scan_archive.py, a different
# implementation) of the produced archives fails the build (no archive left
# behind) if any secret-looking path, private-key block or unreleased git state
# is present.
#
# The shipped .git is NOT a copy of the source repo's .git (that would ship
# stashes - `git stash -u` stores untracked .env files as blobs -, unpushed
# local branches, reflogs, hooks and a config that can hold an
# https://user:token@ remote). For the main repo and every submodule it is
# rebuilt from `git bundle create HEAD`: ONLY the objects reachable from the
# release commit, one branch ref, no remotes, no hooks, no reflogs, no stash,
# a minimal config; the index is rebuilt (git read-tree) so the extracted tree
# reports a clean `git status`.
#
# Honest limits (stated, not hidden):
#   * the shipped .git holds the FULL history reachable from HEAD (a bundle of HEAD). Every historical
#     PATH is judged with the deny-list (_ba_check_history, C2-05/C3-04: a path walk of `git log --name-only -z`,
#     so each path ever touched is judged, not each blob once; a historical path containing a newline is refused,
#     C3-03); a secret committed under a benign name and deleted again is NOT detected - there is no content scan
#     of history. An allow entry matching no tracked or historical path is reported as unused.
#   * only COMMITTED content is released: a dirty tree is refused unless --allow-dirty, and the shipped
#     .git/llmctl-release-manifest.json records dirty=true/false (C2-15).
#   * submodules are shipped ACTIVE (submodule.<name>.url/.active in the shipped config, C2-01) and a
#     gitlink that yields zero files fails the build.
#
# Purpose:
#   spec.md FR-014/Clarification 4: a release archive must be a fully
#   self-contained, buildable tree - `git archive` cannot satisfy this,
#   because it is fundamentally submodule-blind: it emits an EMPTY
#   directory for every submodule (verified empirically this session -
#   `git archive HEAD | tar -tf - | grep submodules/` shows each submodule
#   as a single directory entry with zero of its actual file content). A
#   plain filesystem-level archive of the checked-out tree has no such gap,
#   but archiving EVERYTHING on disk leaks untracked secrets. So the file
#   list is `git ls-files --recurse-submodules` (tracked content of the main
#   repo and all nested submodules) plus each submodule's `.git` pointer and
#   the `.git` directory, keeping the extracted tree a self-contained repo.
#   A non-git source falls back to a filesystem walk with the deny-list
#   applied at collection time.
#
# Usage:
#   source scripts/release/build_archive.sh   # for unit-testing build_archive
#   build_archive [--allow-dirty] <source-root> <output-basename>
#     writes <output-basename>.tar.gz and <output-basename>.zip
#
# Inputs:
#   <source-root> - path to the working tree to archive (must be a real,
#   already-checked-out directory - this script does not run
#   `git submodule update`; run that first if submodules aren't populated).
#   <output-basename> - path (without extension) for the two archives.
#
# Outputs:
#   Two real archive files. Exits non-zero if either tool fails.
#
# Side-effects: reads <source-root> recursively; writes exactly the two
# named archive files. Never modifies <source-root>.
#
# Dependencies: bash, git, GNU tar, zip, python3.
#
# Cross-references:
#   Makefile                              - `make archive` calls this script
#   tests/test_archive_completeness.sh    - RED/GREEN proof against a small
#                                            real-submodule fixture
#   docs/release-process.md               - documents this as part of the
#                                            release procedure
#   specs/001-llmctl-completion/spec.md   - FR-014, Clarification 4
set -euo pipefail

_BA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_BA_REPO_ROOT="$(cd "${_BA_DIR}/../.." && pwd)"

# Exemption manifests: EXACT repo-relative paths, one per line ('#' comments).
#   scripts/release/public_allowlist.txt   named vendored files that look like keys but are public
#   tests/fixtures/PUBLIC_FIXTURES.txt     test fixtures marked public
# Colon-separated override: BA_PUBLIC_ALLOWLIST (tests). An entry with a glob character, '..' or a
# leading '/' is refused: an exemption can never widen into a subtree (C-03).
_BA_ALLOW_LIST=""
_BA_ALLOW_LOADED=0

_ba_allow_manifests() {
  if [[ -n "${BA_PUBLIC_ALLOWLIST:-}" ]]; then
    printf '%s\n' "${BA_PUBLIC_ALLOWLIST}" | tr ':' '\n'
  else
    printf '%s\n' "${_BA_DIR}/public_allowlist.txt" "${_BA_REPO_ROOT}/tests/fixtures/PUBLIC_FIXTURES.txt"
  fi
}

_ba_load_allow() {
  [[ "${_BA_ALLOW_LOADED}" == 1 ]] && return 0
  local mf line n
  _BA_ALLOW_LIST=$'\n'
  while IFS= read -r mf; do
    [[ -n "${mf}" ]] || continue
    [[ -f "${mf}" ]] || { echo "build_archive: allow manifest missing: ${mf}" >&2; return 1; }
    n=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
      n=$((n+1))
      line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
      [[ -z "${line}" || "${line}" == \#* ]] && continue
      case "${line}" in
        *'*'*|*'?'*|*'['*|*']'*|*'\'*|/*|../*|*/../*|*/..)
          echo "build_archive: ${mf}:${n}: allow entry '${line}' must be an exact repo-relative path (no globs)" >&2
          return 1 ;;
      esac
      _BA_ALLOW_LIST+="${line}"$'\n'
    done < "${mf}"
  done < <(_ba_allow_manifests)
  _BA_ALLOW_LOADED=1
}

# _ba_is_allowed <rel> -> rc 0 only for an EXACT manifest line (quoted: no glob semantics).
_ba_is_allowed() {
  _ba_load_allow || return 1
  case "${_BA_ALLOW_LIST}" in *$'\n'"${1}"$'\n'*) return 0 ;; esac
  return 1
}

# _ba_is_secret_path <path-relative-to-source-root>
# Deny-list (spec 009 FR-087 / D-30 / C-03): credentials and key material must never be released.
# Returns 0 (true) when the path is denied. The path is judged COMPONENT BY COMPONENT with anchored
# regexes on the lower-cased path - never a case-glob, whose `*` would match across `/`:
#   .env  .env.*  (not .env.example)      *.key *.pem *.p12 *.pfx *.jks *.keystore
#   id_rsa* id_dsa* id_ecdsa* id_ed25519* .netrc  .pgpass  credentials*.json   a `cert` directory
# Paths inside a `.git` directory are never judged here (the shipped .git is generated by this
# script; scan_archive.py judges its content). The ONLY exemptions are exact manifest entries.
_ba_is_secret_path() {
  local p="${1#./}" lp
  [[ "/${p}/" == */.git/* ]] && return 1
  _ba_is_allowed "${p}" && return 1
  if (( BASH_VERSINFO[0] >= 4 )); then
    eval 'lp="${p,,}"'                                        # no fork per file (12k+ files)
  else
    lp="$(printf '%s' "${p}" | tr '[:upper:]' '[:lower:]')"   # bash 3.2 (macOS) has no ${var,,}
  fi
  local seg='[^/]*'
  [[ "${lp}" =~ (^|/)\.env(\.${seg})?(/|$) && ! "${lp}" =~ (^|/)\.env\.example$ ]] && return 0
  [[ "${lp}" =~ \.(key|pem|p12|pfx|jks|keystore)$ ]] && return 0
  [[ "${lp}" =~ (^|/)id_(rsa|dsa|ecdsa|ed25519)${seg}$ ]] && return 0
  [[ "${lp}" =~ (^|/)\.(netrc|pgpass)$ ]] && return 0
  [[ "${lp}" =~ (^|/)credentials${seg}\.json$ ]] && return 0
  [[ "${lp}" =~ (^|/)cert/ ]] && return 0
  return 1
}

# _ba_list_files <abs-src> <base> -> NUL-separated list of "<base>/<rel>" on stdout.
# Git work tree: tracked files of the main repo and of every (recursively) initialised submodule,
# plus every submodule's `.git` POINTER FILE. The `.git` directories themselves are not listed:
# they are generated sanitised by _ba_stage_git. Untracked and ignored files are NEVER listed.
# Non-git source: filesystem walk with the deny-list applied at collection time.
# `*/build/*` is excluded in both.
_ba_list_files() {
  local src="$1" base="$2" rel
  {
    if [[ -e "${src}/.git" ]] && git -C "${src}" rev-parse --git-dir >/dev/null 2>&1; then
      git -C "${src}" ls-files -z --recurse-submodules
      git -C "${src}" submodule foreach --recursive --quiet 'printf "%s\0" "$displaypath/.git"' 2>/dev/null || true
    else
      ( cd "${src}" && find . -mindepth 1 \( -type f -o -type l \) -print0 )
    fi
  } | while IFS= read -r -d '' rel; do
    rel="${rel#./}"
    [[ -n "${rel}" ]] || continue
    case "/${rel}/" in */build/*) continue ;; esac
    # gitlink dirs / deleted-but-tracked entries: only real files and links
    [[ -e "${src}/${rel}" || -L "${src}/${rel}" ]] || continue
    if [[ -d "${src}/${rel}" && ! -L "${src}/${rel}" ]]; then continue; fi
    if _ba_is_secret_path "${rel}"; then
      # tracked secret in git mode is a hard error (the post-scan names it); in walk mode it is
      # simply excluded.
      if [[ -e "${src}/.git" ]]; then printf '%s\0' "${base}/${rel}"; fi
      continue
    fi
    printf '%s\0' "${base}/${rel}"
  done
}

# _ba_sanitise_repo <repo-dir> <dest-gitdir> [core.worktree value]
# Rebuilds a minimal git dir holding ONLY what is reachable from the repo's HEAD (see header).
_ba_sanitise_repo() {
  local repo="$1" dest="$2" wt="${3:-}" tmp branch head
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ba_bundle.XXXXXX")"
  head="$(git -C "${repo}" rev-parse -q --verify HEAD 2>/dev/null)" || { rm -rf "${tmp}"; echo "build_archive: ${repo} has no commit to release" >&2; return 1; }
  git -C "${repo}" bundle create "${tmp}/b.bundle" HEAD >/dev/null 2>&1 || { rm -rf "${tmp}"; echo "build_archive: cannot bundle HEAD of ${repo}" >&2; return 1; }
  branch="$(git -C "${repo}" symbolic-ref -q --short HEAD 2>/dev/null || true)"
  mkdir -p "${dest}"
  git init -q --bare "${dest}"
  rm -rf "${dest}/hooks" "${dest}/info" "${dest}/description"
  git --git-dir="${dest}" fetch -q --no-tags "${tmp}/b.bundle" "+HEAD:refs/heads/${branch:-release}" >/dev/null 2>&1 \
    || { rm -rf "${tmp}"; echo "build_archive: cannot unpack the HEAD bundle of ${repo}" >&2; return 1; }
  if [[ -n "${branch}" ]]; then
    printf 'ref: refs/heads/%s\n' "${branch}" > "${dest}/HEAD"
  else
    printf '%s\n' "${head}" > "${dest}/HEAD"      # detached
    git --git-dir="${dest}" update-ref -d refs/heads/release
  fi
  # minimal config: no remotes, no credential helpers, no url rewrites, no hooks path
  : > "${dest}/config"
  git config --file "${dest}/config" core.repositoryformatversion 0
  git config --file "${dest}/config" core.filemode true
  git config --file "${dest}/config" core.bare false
  [[ -z "${wt}" ]] || git config --file "${dest}/config" core.worktree "${wt}"
  # C2-01: ACTIVATE the submodules. Without submodule.<name>.active/.url an extracted release reports every
  # submodule as uninitialised ('-<sha> sub'), `git ls-files --recurse-submodules` drops their files and a
  # build_archive run on the extracted tree would silently ship empty submodules. The URL comes from the
  # tracked .gitmodules (scan_archive.py already rejects userinfo in it); it is the only URL written.
  if [[ -f "${repo}/.gitmodules" ]]; then
    local key sname surl
    while IFS= read -r -d '' key; do
      sname="${key#submodule.}"; sname="${sname%.path}"
      git config --file "${dest}/config" "submodule.${sname}.active" true
      surl="$(git config --file "${repo}/.gitmodules" --get "submodule.${sname}.url" 2>/dev/null || true)"
      [[ -z "${surl}" ]] || git config --file "${dest}/config" "submodule.${sname}.url" "${surl}"
    done < <(git config --file "${repo}/.gitmodules" -z --name-only --get-regexp '^submodule\..*\.path$' 2>/dev/null || true)
  fi
  rm -rf "${dest}/logs" "${dest}/refs/stash"
  # the index, so `git status` of the extracted tree compares content (clean)
  git --git-dir="${dest}" --work-tree="${repo}" read-tree HEAD >/dev/null 2>&1 || true
  rm -rf "${tmp}"
}

# _ba_stage_git <abs-src> <base> <stage-dir>: writes the sanitised git dirs of the main repo and of
# every initialised submodule under <stage-dir>/<base>/.git[/modules/...]. Returns 0 and creates
# nothing for a non-git source.
_ba_stage_git() {
  local src="$1" base="$2" stage="$3" dp gd rel wt
  [[ -e "${src}/.git" ]] && git -C "${src}" rev-parse --git-dir >/dev/null 2>&1 || return 0
  [[ -d "${src}/.git" ]] || { echo "build_archive: ${src}/.git is not a directory (a worktree/submodule checkout cannot be archived)" >&2; return 1; }
  _ba_sanitise_repo "${src}" "${stage}/${base}/.git" || return 1
  while IFS= read -r dp; do
    [[ -n "${dp}" ]] || continue
    gd="$(git -C "${src}/${dp}" rev-parse --absolute-git-dir 2>/dev/null)" || continue
    case "${gd}" in "${src}/.git/"*) rel="${gd#"${src}"/}" ;; *)
      echo "build_archive: submodule ${dp} keeps its git dir outside ${src}/.git (${gd}); refusing" >&2; return 1 ;; esac
    wt="$(git config --file "${gd}/config" --get core.worktree 2>/dev/null || true)"
    _ba_sanitise_repo "${src}/${dp}" "${stage}/${base}/${rel}" "${wt}" || return 1
  done < <(git -C "${src}" submodule foreach --recursive --quiet 'printf "%s\n" "$displaypath"' 2>/dev/null || true)
}

# _ba_gitlinks <abs-src> -> NUL-separated display paths (relative to <abs-src>) of EVERY gitlink (mode 160000),
# initialised or not, recursively through the initialised submodules.
_ba_gitlinks() {
  local src="$1"
  _ba_gitlinks_in() { # <dir> <prefix>
    local d="$1" pre="$2" r pth
    while IFS= read -r -d '' r; do
      [[ "${r}" == 160000* ]] || continue
      pth="${r#*$'\t'}"
      printf '%s\0' "${pre}${pth}"
      if [[ -e "${d}/${pth}/.git" ]]; then _ba_gitlinks_in "${d}/${pth}" "${pre}${pth}/"; fi
    done < <(git -C "${d}" ls-files -s -z 2>/dev/null)
  }
  _ba_gitlinks_in "${src}" ""
  unset -f _ba_gitlinks_in
}

# _ba_check_gitlinks <abs-src> <base> <list-file>: C2-01 completeness. Every gitlink must have contributed at
# least one tracked file (besides its .git pointer) to the list; a gitlink yielding zero files is a submodule
# that is not checked out (or was lost by a previous release), and the archive would ship it EMPTY.
# C3-06: the match is ANCHORED - a list entry counts only when it STARTS with "<base>/<gitlink>/" (a decoy such as
# "<base>/docs/<base>/<gitlink>/readme" merely contains that string). The prefix goes through the environment, not
# `awk -v` (which would interpret backslashes in a path).
_ba_check_gitlinks() {
  local src="$1" base="$2" list="$3" dp bad=0
  [[ -e "${src}/.git" ]] || return 0
  while IFS= read -r -d '' dp; do
    if ! tr '\0' '\n' < "${list}" | BA_P="${base}/${dp}/" awk 'BEGIN { p = ENVIRON["BA_P"] } index($0, p) == 1 && $0 != p ".git" { f = 1 } END { exit !f }'; then
      echo "build_archive: gitlink '${dp}' yields zero files (submodule not checked out / not initialised?); refusing to ship it empty" >&2
      bad=1
    fi
  done < <(_ba_gitlinks "${src}")
  return "${bad}"
}

# _ba_check_history <abs-src> [<seen-file>]: C2-05 / C3-03 / C3-04. The shipped .git is a bundle of HEAD, so it carries
# EVERY path ever reachable from HEAD (a secret committed and `git rm`'d later still ships as a blob). EVERY historical
# PATH of the main repo and of every initialised submodule is judged with the deny-list, the path made repo-relative so the
# exact allow manifests apply. The walk is `git log -m --no-renames --name-only -z`: it lists the paths touched by each
# commit (merge commits against each parent, both sides of a rename), NUL-separated. `rev-list --objects` is NOT used: it
# prints each blob ONCE under the first path it meets (so a secret-named path holding content identical to another path's
# was never judged) and cuts a path at its first newline. NUL is mapped to a line end and a newline to \001 so that
# `sort -u` (portable, no `sort -z`) can de-duplicate; a historical path containing a newline (or \001) is REFUSED, since
# no deny-list can judge it reliably. Every judged repo-relative path is appended to <seen-file> (for the unused-allow
# report). Bound, stated honestly: this is a PATH check - a secret committed under a benign name and deleted again is not
# detected here.
_ba_check_history() {
  local src="$1" seen="${2:-}" bad=0 dp
  _ba_check_history_repo() { # <repo-dir> <prefix>
    local d="$1" pre="$2" path
    while IFS= read -r path; do
      [[ -n "${path}" ]] || continue
      if [[ "${path}" == *$'\001'* ]]; then
        echo "build_archive: a historical path in the shipped git HISTORY of '${pre:-.}' contains a newline (or control character); refusing (the deny-list cannot judge it)" >&2
        bad=1
        continue
      fi
      [[ -z "${seen}" ]] || printf '%s\n' "${pre}${path}" >> "${seen}"
      if _ba_is_secret_path "${pre}${path}"; then
        echo "build_archive: secret-looking path in the shipped git HISTORY: ${pre}${path} (committed once, still in the bundle); add an exact allow-manifest entry if it is public" >&2
        bad=1
      fi
    done < <(git -C "${d}" log -m --no-renames --name-only -z --format= HEAD 2>/dev/null | tr '\000\n' '\n\001' | LC_ALL=C sort -u)
  }
  [[ -e "${src}/.git" ]] || return 0
  _ba_check_history_repo "${src}" ""
  while IFS= read -r dp; do
    [[ -n "${dp}" ]] || continue
    _ba_check_history_repo "${src}/${dp}" "${dp}/"
  done < <(git -C "${src}" submodule foreach --recursive --quiet 'printf "%s\n" "$displaypath"' 2>/dev/null || true)
  unset -f _ba_check_history_repo
  return "${bad}"
}

# _ba_report_unused_allow <base> <list-file> <seen-file>: C3-04. An allow entry that names neither a tracked file (in the
# release list) nor a historical path is dead weight (it can mask nothing and hides a stale review); report it. Report
# only - never a failure (an entry may legitimately name a path inside a nested archive).
_ba_report_unused_allow() {
  local base="$1" list="$2" seen="$3" e
  while IFS= read -r e; do
    [[ -n "${e}" ]] || continue
    if grep -q -F -x -- "${e}" "${seen}" 2>/dev/null; then continue; fi
    if tr '\0' '\n' < "${list}" | grep -q -F -x -- "${base}/${e}"; then continue; fi
    echo "build_archive: unused allow entry: ${e} (names no tracked file and no path in the shipped history)" >&2
  done <<< "${_BA_ALLOW_LIST}"
}

# _ba_dirty_count <abs-src> -> number of dirty status entries (tracked edits AND untracked files, submodules included)
_ba_dirty_count() {
  [[ -e "$1/.git" ]] || { echo 0; return 0; }
  git -C "$1" status --porcelain --ignore-submodules=none 2>/dev/null | wc -l | tr -d ' '
}

# _ba_write_manifest <abs-src> <stage-git-dir> <dirty-count> <allow-dirty 0|1>: records WHAT was released inside
# the shipped .git (not in the work tree, so the extracted tree's `git status` stays clean).
_ba_write_manifest() {
  local src="$1" gd="$2" n="$3" allow="$4" head dirty=false ad=false
  head="$(git -C "${src}" rev-parse -q --verify HEAD 2>/dev/null || true)"
  [[ "${n}" -eq 0 ]] || dirty=true
  [[ "${allow}" -eq 0 ]] || ad=true
  printf '{\n  "schema": 1,\n  "source_head": "%s",\n  "dirty": %s,\n  "dirty_entries": %s,\n  "allow_dirty": %s,\n  "note": "dirty=true: the archive holds HEAD content only; uncommitted edits and untracked files are NOT in it"\n}\n' \
    "${head}" "${dirty}" "${n}" "${ad}" > "${gd}/llmctl-release-manifest.json"
}

# _ba_scan_archives <tar.gz> <zip> : fail (return 1) if the INDEPENDENT scanner finds anything.
_ba_scan_archives() {
  local -a allow=() mf
  while IFS= read -r mf; do [[ -n "${mf}" ]] && allow+=(--allow "${mf}"); done < <(_ba_allow_manifests)
  python3 -I "${_BA_DIR}/scan_archive.py" ${allow[@]+"${allow[@]}"} "$1" "$2"
}

# build_archive [--allow-dirty] <source-root> <output-basename>
# A source with uncommitted edits or untracked files is REFUSED (C2-15): the archive holds HEAD content only, so a
# dirty tree would ship something other than what is on disk (and untracked files the code depends on would be
# missing). --allow-dirty (or BA_ALLOW_DIRTY=1) overrides it, and the shipped manifest records dirty=true.
build_archive() {
  local allow_dirty=0
  [[ "${BA_ALLOW_DIRTY:-0}" == 1 ]] && allow_dirty=1
  if [[ "${1:-}" == "--allow-dirty" ]]; then allow_dirty=1; shift; fi
  local src="$1" out="$2"
  src="$(cd "${src}" && pwd)"
  local parent base
  parent="$(dirname "${src}")"
  base="$(basename "${src}")"

  # <output-basename> is resolved to an ABSOLUTE path relative to the
  # CALLER's original working directory, BEFORE any `cd` below (a relative
  # path such as "../llmctl" would otherwise be re-resolved against the
  # wrong base; real bug found earlier: `make archive` wrote llmctl.zip one
  # directory level too high).
  case "${out}" in
    /*) : ;;
    *) out="$(pwd)/${out}" ;;
  esac

  _ba_load_allow || return 1
  local ndirty
  ndirty="$(_ba_dirty_count "${src}")"
  if [[ "${ndirty}" -ne 0 && "${allow_dirty}" -eq 0 ]]; then
    echo "build_archive: ${src} has ${ndirty} uncommitted/untracked status entries; the archive would not match the tree on disk. Commit them, or pass --allow-dirty (BA_ALLOW_DIRTY=1) to release HEAD anyway." >&2
    return 1
  fi
  local list stage
  list="$(mktemp "${TMPDIR:-/tmp}/build_archive_list.XXXXXX")"
  stage="$(mktemp -d "${TMPDIR:-/tmp}/build_archive_stage.XXXXXX")"
  _ba_list_files "${src}" "${base}" > "${list}"
  local seen
  seen="$(mktemp "${TMPDIR:-/tmp}/build_archive_seen.XXXXXX")"
  if ! _ba_check_gitlinks "${src}" "${base}" "${list}" || ! _ba_check_history "${src}" "${seen}"; then
    rm -rf "${list}" "${stage}" "${seen}"
    return 1
  fi
  _ba_report_unused_allow "${base}" "${list}" "${seen}"
  rm -f "${seen}"

  # zip -@ reads newline-separated names; refuse names containing newlines.
  if [[ "$(tr -cd '\n' < "${list}" | wc -c)" -ne 0 ]]; then
    rm -rf "${list}" "${stage}"
    echo "build_archive: a file name contains a newline; refusing" >&2
    return 1
  fi
  if ! _ba_stage_git "${src}" "${base}" "${stage}"; then
    rm -rf "${list}" "${stage}"
    return 1
  fi

  [[ -d "${stage}/${base}/.git" ]] && _ba_write_manifest "${src}" "${stage}/${base}/.git" "${ndirty}" "${allow_dirty}"
  rm -f "${out}.tar.gz" "${out}.zip"
  local -a gitpart=()
  [[ -d "${stage}/${base}/.git" ]] && gitpart=(--recursion -C "${stage}" "${base}/.git")
  tar --no-recursion --null -czf "${out}.tar.gz" -C "${parent}" -T "${list}" ${gitpart[@]+"${gitpart[@]}"}
  ( cd "${parent}" && tr '\0' '\n' < "${list}" | zip -q "${out}.zip" -@ )
  [[ -d "${stage}/${base}/.git" ]] && ( cd "${stage}" && zip -q -r "${out}.zip" "${base}/.git" )
  rm -rf "${list}" "${stage}"

  # Defense in depth: scan the PRODUCED archives with the independent scanner; no secret may ship.
  if ! _ba_scan_archives "${out}.tar.gz" "${out}.zip"; then
    rm -f "${out}.tar.gz" "${out}.zip"
    echo "build_archive: aborted, secret-looking paths or unreleased git state found; no archive left behind" >&2
    return 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ "${1:-}" == "--allow-dirty" ]]; then _ba_ad=(--allow-dirty); shift; else _ba_ad=(); fi
  if [[ "$#" -ne 2 ]]; then
    echo "usage: build_archive.sh [--allow-dirty] <source-root> <output-basename>" >&2
    exit 1
  fi
  build_archive ${_ba_ad[@]+"${_ba_ad[@]}"} "$1" "$2"
fi
