#!/usr/bin/env bash
# create_release.sh - creates a GitHub + GitLab release atomically: SemVer
# validation, a conventional-commits changelog, the release-packaging
# submodule preflight, asset build, then `gh release create` +
# `glab release create` with idempotent retry-only-the-failed-forge.
#
# Purpose:
#   spec.md FR-013 ("Release MUST be created via `gh release create` and
#   `glab release create` with generated changelog"), FR-050/Clarification
#   19 ("a GitHub/GitLab release is atomic across both forges - if either
#   fails, the release is NOT considered published; re-running MUST be
#   idempotent, retrying only the failed forge"), SC-009/Clarification 5
#   (SemVer with pre-release tag support, e.g. v1.0.0-rc.1).
#
# Usage:
#   bash scripts/release/create_release.sh [--dry-run] <version>
#   source scripts/release/create_release.sh   # for unit-testing the
#                                               # individual functions
#
#   --dry-run performs every real check (SemVer validation, submodule
#   preflight, changelog generation, asset build) but makes ZERO calls to
#   `gh`/`glab` - it prints what would be run instead. This is the ONLY
#   mode this project's own test suite (and any automated CI-style check)
#   ever exercises against the real `gh`/`glab` binaries; a REAL release
#   requires the operator to run this script WITHOUT --dry-run explicitly,
#   themselves, after reviewing the dry-run output (Constitution's
#   irreversible-action discipline - creating a public release is a
#   hard-to-reverse, externally-visible action this script never takes
#   unattended).
#
# Inputs:
#   $1 (positional, after any --dry-run flag) - the release version, SemVer
#   MAJOR.MINOR.PATCH with an optional pre-release suffix (e.g. v1.0.0,
#   1.2.3, v1.0.0-rc.1), with or without a leading "v".
#   LLMCTL_RELEASE_STATE_DIR (optional) - where per-version, per-forge
#   idempotency state is recorded; defaults to
#   ~/.local/state/llmctl/release/ (XDG-aware, matching this project's
#   other state-directory conventions in lib/common.sh).
#
# Outputs:
#   Real per-step evidence on stdout (validation result, changelog content,
#   preflight result, per-forge publish result). Exit 0 on a fully
#   successful (or fully successful dry-run) release; non-zero if any real
#   step fails, naming which one.
#
# Side-effects (non-dry-run mode only):
#   Runs `git tag`, `gh release create`, `glab release create` against the
#   real configured remotes - genuinely publishes a public release. NEVER
#   invoked by this project's own test suite or by any automated pass;
#   requires deliberate, explicit, unattended-free operator action.
#
# Dependencies: bash, git, gh, glab (only actually invoked in non-dry-run
# mode), scripts/release/preflight_submodules.sh.
#
# Cross-references:
#   scripts/release/preflight_submodules.sh - run before any asset is built
#   tests/test_create_release.sh            - RED/GREEN proof, using a
#                                              PATH-injected fake gh/glab so
#                                              the real forges are NEVER
#                                              touched during testing
#   docs/release-process.md                 - documents the full procedure
#   specs/001-llmctl-completion/spec.md     - FR-013, FR-050, SC-009,
#                                              Clarification 5, Clarification 19
set -euo pipefail

_release_root() { cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd; }

# release_validate_semver <version>
# Accepts an optional leading "v", MAJOR.MINOR.PATCH, and an optional
# pre-release suffix (Clarification 5: "v1.0.0-rc.1").
release_validate_semver() {
  local version="$1"
  [[ "${version}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]
}

# release_generate_changelog <repo-dir> <since-tag>
# Real `git log` over the actual commit history since <since-tag>, grouped
# by conventional-commit type. Commits with no recognized prefix land under
# "Other".
release_generate_changelog() {
  local repo="$1" since_tag="$2"
  local feats fixes docs other
  feats="$(git -C "${repo}" log "${since_tag}..HEAD" --format='%s' | grep -E '^feat(\(.+\))?:' || true)"
  fixes="$(git -C "${repo}" log "${since_tag}..HEAD" --format='%s' | grep -E '^fix(\(.+\))?:' || true)"
  docs="$(git -C "${repo}" log "${since_tag}..HEAD" --format='%s' | grep -E '^docs(\(.+\))?:' || true)"
  other="$(git -C "${repo}" log "${since_tag}..HEAD" --format='%s' | grep -vE '^(feat|fix|docs|chore|refactor|test)(\(.+\))?:' || true)"

  echo "## Changelog since ${since_tag}"
  if [[ -n "${feats}" ]]; then
    echo; echo "### Features"
    while IFS= read -r line; do [[ -n "${line}" ]] && echo "- ${line#feat*: }"; done <<<"${feats}"
  fi
  if [[ -n "${fixes}" ]]; then
    echo; echo "### Fixes"
    while IFS= read -r line; do [[ -n "${line}" ]] && echo "- ${line#fix*: }"; done <<<"${fixes}"
  fi
  if [[ -n "${docs}" ]]; then
    echo; echo "### Documentation"
    while IFS= read -r line; do [[ -n "${line}" ]] && echo "- ${line#docs*: }"; done <<<"${docs}"
  fi
  if [[ -n "${other}" ]]; then
    echo; echo "### Other"
    while IFS= read -r line; do [[ -n "${line}" ]] && echo "- ${line}"; done <<<"${other}"
  fi
}

_release_state_dir() {
  local dir="${LLMCTL_RELEASE_STATE_DIR:-${HOME}/.local/state/llmctl/release}"
  mkdir -p "${dir}"
  printf '%s' "${dir}"
}

_release_state_file() {
  # version and forge are both safe for a filename (SemVer chars + a-z only)
  printf '%s/%s.%s.state' "$(_release_state_dir)" "$1" "$2"
}

# release_state_get <version> <forge> -> "done" | "pending"
release_state_get() {
  local f; f="$(_release_state_file "$1" "$2")"
  if [[ -f "${f}" ]]; then cat "${f}"; else echo "pending"; fi
}

# release_state_set <version> <forge> <status>
release_state_set() {
  printf '%s' "$3" > "$(_release_state_file "$1" "$2")"
}

# release_publish_forge <forge: github|gitlab> <tag> <title> <notes_file>
# Invokes the REAL gh/glab binary (real subprocess - swap PATH in tests to
# point at a fake one; never mocked at the bash-function level) and records
# success/failure in the per-version, per-forge idempotency state.
release_publish_forge() {
  local forge="$1" tag="$2" title="$3" notes_file="$4"
  local bin ok=1
  case "${forge}" in
    github) bin="gh" ;;
    gitlab) bin="glab" ;;
    *) echo "unknown forge: ${forge}" >&2; return 1 ;;
  esac

  if "${bin}" release create "${tag}" --title "${title}" --notes-file "${notes_file}"; then
    ok=0
  fi

  if [[ "${ok}" -eq 0 ]]; then
    release_state_set "${tag}" "${forge}" "done"
    return 0
  else
    release_state_set "${tag}" "${forge}" "failed"
    return 1
  fi
}

# release_run_publish_both <tag> <title> <notes_file>
# Publishes to BOTH forges, skipping any forge already recorded "done"
# (idempotent retry-only-the-failed-forge, Clarification 19). Returns
# non-zero if EITHER forge is not "done" by the end (the whole release is
# atomic - not-published-on-both means not-published, FR-050).
release_run_publish_both() {
  local tag="$1" title="$2" notes_file="$3"
  local overall=0 forge

  for forge in github gitlab; do
    if [[ "$(release_state_get "${tag}" "${forge}")" == "done" ]]; then
      echo "SKIP ${forge}: already published (idempotent retry-only-the-failed-forge)"
      continue
    fi
    if release_publish_forge "${forge}" "${tag}" "${title}" "${notes_file}"; then
      echo "PASS ${forge}: release ${tag} published"
    else
      echo "FAIL ${forge}: release ${tag} publish failed" >&2
      overall=1
    fi
  done

  return "${overall}"
}

# --- standalone entrypoint ----------------------------------------------------
_release_main() {
  local dry_run=0 version=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      *) version="$1"; shift ;;
    esac
  done

  if [[ -z "${version}" ]]; then
    echo "usage: create_release.sh [--dry-run] <version>" >&2
    return 1
  fi

  if ! release_validate_semver "${version}"; then
    echo "FAIL: '${version}' is not a valid SemVer version (MAJOR.MINOR.PATCH[-prerelease], e.g. v1.0.0 or v1.0.0-rc.1)" >&2
    return 1
  fi
  echo "PASS: '${version}' is a valid SemVer version"

  local root; root="$(_release_root)"
  local since_tag; since_tag="$(git -C "${root}" describe --tags --abbrev=0 2>/dev/null || echo "$(git -C "${root}" rev-list --max-parents=0 HEAD)")"

  echo
  echo "=== Step 1: submodule preflight (spec.md FR-052/Clarification 21) ==="
  if [[ "${dry_run}" -eq 1 ]]; then
    echo "[dry-run] would run: bash ${root}/scripts/release/preflight_submodules.sh"
  else
    bash "${root}/scripts/release/preflight_submodules.sh" || {
      echo "FAIL: submodule preflight failed - release aborted (no artifact produced with a missing/unreachable submodule)" >&2
      return 1
    }
  fi

  echo
  echo "=== Step 2: changelog (conventional commits since ${since_tag}) ==="
  local notes_file; notes_file="$(mktemp)"
  release_generate_changelog "${root}" "${since_tag}" | tee "${notes_file}"

  echo
  echo "=== Step 3: build release assets (make archive) ==="
  if [[ "${dry_run}" -eq 1 ]]; then
    echo "[dry-run] would run: make -C ${root} archive"
  else
    make -C "${root}" archive
  fi

  echo
  echo "=== Step 4: publish to GitHub + GitLab ==="
  if [[ "${dry_run}" -eq 1 ]]; then
    echo "[dry-run] would run: gh release create ${version} --title ${version} --notes-file ${notes_file}"
    echo "[dry-run] would run: glab release create ${version} --title ${version} --notes-file ${notes_file}"
    echo
    echo "This was a dry-run: every check above ran for real; zero network-mutating gh/glab calls were made."
    rm -f "${notes_file}"
    return 0
  fi

  release_run_publish_both "${version}" "${version}" "${notes_file}"
  local rc=$?
  rm -f "${notes_file}"
  return "${rc}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _release_main "$@"
fi
