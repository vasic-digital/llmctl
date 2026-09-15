#!/usr/bin/env bash
# test_create_release.sh - proves create_release.sh's SemVer validation,
# conventional-commit changelog generation, per-forge idempotent retry, and
# --dry-run's zero-network-mutating-call guarantee, all against REAL git
# history and REAL (fake, PATH-injected) gh/glab binaries - never the real
# GitHub/GitLab (Phase 8 T045/T046, spec.md FR-013/FR-050/SC-009,
# Clarification 5/19).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

source "${LLMCTL_ROOT}/scripts/release/create_release.sh"

# --- 1. SemVer validation (Clarification 5: MAJOR.MINOR.PATCH + pre-release) -
rc=0; release_validate_semver "v1.0.0" || rc=$?
assert_eq 0 "${rc}" "v1.0.0 is valid SemVer"
rc=0; release_validate_semver "v1.0.0-rc.1" || rc=$?
assert_eq 0 "${rc}" "v1.0.0-rc.1 (pre-release) is valid SemVer"
rc=0; release_validate_semver "1.2.3" || rc=$?
assert_eq 0 "${rc}" "1.2.3 (no leading v) is valid SemVer"
rc=0; release_validate_semver "v1.0" || rc=$?
assert_eq 1 "${rc}" "v1.0 (missing PATCH) is rejected"
rc=0; release_validate_semver "not-a-version" || rc=$?
assert_eq 1 "${rc}" "garbage string is rejected"

# --- 2. Changelog generation from real conventional-commit history -----------
REPO="${TEST_TMP}/release_repo"
git init -q "${REPO}"
(
  cd "${REPO}"
  git config user.email test@example.com; git config user.name test
  echo a > a.txt; git add a.txt; git commit -qm "chore: init"
  git tag v1.0.0
  echo b > b.txt; git add b.txt; git commit -qm "feat: add widget support"
  echo c > c.txt; git add c.txt; git commit -qm "fix: correct widget off-by-one"
  echo d > d.txt; git add d.txt; git commit -qm "docs: document widgets"
  echo e > e.txt; git add e.txt; git commit -qm "unrelated commit with no prefix"
)
changelog="$(release_generate_changelog "${REPO}" "v1.0.0")"
assert_contains "${changelog}" "add widget support" "changelog includes the real feat commit"
assert_contains "${changelog}" "correct widget off-by-one" "changelog includes the real fix commit"
assert_contains "${changelog}" "document widgets" "changelog includes the real docs commit"
assert_contains "${changelog}" "Features" "changelog groups feat: commits under a Features heading"
assert_contains "${changelog}" "Fixes" "changelog groups fix: commits under a Fixes heading"

# --- 3. Idempotent per-forge state tracking -----------------------------------
STATE_DIR="${TEST_TMP}/release_state"
mkdir -p "${STATE_DIR}"
export LLMCTL_RELEASE_STATE_DIR="${STATE_DIR}"
assert_eq "pending" "$(release_state_get "v1.0.0" "github")" "a forge with no recorded state defaults to pending"
release_state_set "v1.0.0" "github" "done"
assert_eq "done" "$(release_state_get "v1.0.0" "github")" "release_state_set persists real state, read back correctly"
assert_eq "pending" "$(release_state_get "v1.0.0" "gitlab")" "a DIFFERENT forge's state is independent (not accidentally shared)"

# --- 4. release_publish_forge invokes the REAL (PATH-injected fake) gh/glab
# binary with the expected arguments, and records success/failure state -----
FAKE_BIN="${TEST_TMP}/fake_bin"
mkdir -p "${FAKE_BIN}"
cat > "${FAKE_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "${FAKE_GH_LOG}"
exit "${FAKE_GH_EXIT:-0}"
EOF
chmod +x "${FAKE_BIN}/gh"
cat > "${FAKE_BIN}/glab" <<'EOF'
#!/usr/bin/env bash
echo "glab $*" >> "${FAKE_GLAB_LOG}"
exit "${FAKE_GLAB_EXIT:-0}"
EOF
chmod +x "${FAKE_BIN}/glab"

export FAKE_GH_LOG="${TEST_TMP}/gh.log"
export FAKE_GLAB_LOG="${TEST_TMP}/glab.log"
: > "${FAKE_GH_LOG}"; : > "${FAKE_GLAB_LOG}"
NOTES="${TEST_TMP}/notes.md"; echo "release notes" > "${NOTES}"

PATH="${FAKE_BIN}:${PATH}" FAKE_GH_EXIT=0 release_publish_forge "github" "v9.9.9" "v9.9.9" "${NOTES}"
assert_file_contains "${FAKE_GH_LOG}" "release create" "release_publish_forge github invoked the real gh binary with 'release create'"
assert_eq "done" "$(release_state_get "v9.9.9" "github")" "successful github publish is recorded as done"

# --- 5. one forge fails -> whole release treated as failed, retry hits ONLY
# the failed forge (Clarification 19). Uses a FRESH tag (v9.9.10, not
# v9.9.9 from step 4) so both forges genuinely start "pending" - reusing
# v9.9.9 would let github's already-"done" state from step 4 silently skip
# the FAKE_GH_EXIT=1 failure path entirely, making this scenario a no-op. --
: > "${FAKE_GH_LOG}"; : > "${FAKE_GLAB_LOG}"
assert_eq "pending" "$(release_state_get "v9.9.10" "github")" "fresh tag v9.9.10: github genuinely starts pending (sanity - proves the next failure is real)"
rc=0
FAKE_GH_EXIT=1 PATH="${FAKE_BIN}:${PATH}" release_run_publish_both "v9.9.10" "v9.9.10" "${NOTES}" 2>/dev/null || rc=$?
assert_eq 1 "${rc}" "whole release is treated as failed when github fails (even if gitlab succeeds)"
assert_eq "failed" "$(release_state_get "v9.9.10" "github")" "failed github publish is recorded as failed, not done"
assert_eq "done" "$(release_state_get "v9.9.10" "gitlab")" "gitlab's independent success is still recorded as done despite github's failure"

# Re-run (simulating the underlying GitHub issue now fixed): github (state
# "failed", not "done") MUST be retried; gitlab (already "done") must NOT.
: > "${FAKE_GLAB_LOG}"
FAKE_GH_EXIT=0 PATH="${FAKE_BIN}:${PATH}" release_run_publish_both "v9.9.10" "v9.9.10" "${NOTES}"
gh_call_count_retry="$(grep -c "release create" "${FAKE_GH_LOG}")"
glab_call_count="$(grep -c "release create" "${FAKE_GLAB_LOG}" || true)"
assert_eq 2 "${gh_call_count_retry}" "github IS retried on re-run (1 failed attempt + 1 retry attempt = 2 real invocations total)"
assert_eq 0 "${glab_call_count}" "retry after a github-only failure does NOT re-invoke glab (already succeeded, idempotent retry-only-the-failed-forge)"
assert_eq "done" "$(release_state_get "v9.9.10" "github")" "retried github publish now recorded as done"

# --- 6. --dry-run performs real checks but makes ZERO calls to gh/glab -------
: > "${FAKE_GH_LOG}"; : > "${FAKE_GLAB_LOG}"
STATE_DIR2="${TEST_TMP}/release_state_dryrun"; mkdir -p "${STATE_DIR2}"
out="$(LLMCTL_RELEASE_STATE_DIR="${STATE_DIR2}" PATH="${FAKE_BIN}:${PATH}" \
  bash "${LLMCTL_ROOT}/scripts/release/create_release.sh" --dry-run "v1.0.0" 2>&1)" && rc=0 || rc=$?
assert_eq "" "$(cat "${FAKE_GH_LOG}")" "dry-run makes ZERO calls to gh"
assert_eq "" "$(cat "${FAKE_GLAB_LOG}")" "dry-run makes ZERO calls to glab"
assert_contains "${out}" "dry-run" "dry-run output announces itself as a dry run"

test_finish
