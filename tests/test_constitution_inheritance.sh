#!/usr/bin/env bash
# test_constitution_inheritance.sh — Comprehensive inheritance verification
# Verifies all invariants from Constitution Submodule Setup Agent Step 7 & 9

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONSTITUTION_DIR="${PROJECT_ROOT}/constitution"
# llmctl no longer vendors the constitution as a submodule (single source of truth, owner mandate 2026-10-21):
# lib/resolve_deps.sh finds the hub copy (LLMCTL_CONSTITUTION_DIR -> parent hub -> <root>/constitution -> ...).
# Fixture projects built by the sibling tests carry no lib/, and keep the legacy <root>/constitution path.
if [[ -f "${PROJECT_ROOT}/lib/resolve_deps.sh" ]]; then
    if _resolved_const="$(bash "${PROJECT_ROOT}/lib/resolve_deps.sh" constitution 2>/dev/null)"; then
        CONSTITUTION_DIR="${_resolved_const}"
    fi
fi

# A submodule checkout carries a `.git` entry (file or dir). In a linked `git worktree`, or before
# `git submodule update --init`, constitution/ is absent or EMPTY: every `git -C constitution ...` would then
# silently resolve to the ENCLOSING project repo and measure the wrong remotes. In a linked worktree the
# submodule content lives only in the main worktree, so resolve it from there (same pinned content, read-only).
# ...and git must agree that this directory is the TOP LEVEL of its own work tree (a stray .git entry, or a
# symlink to the enclosing repo, resolves to a different toplevel and does not count).
is_own_repo() {
    [[ -e "$1/.git" && -d "$1" ]] || return 1
    local phys top
    phys="$(cd "$1" && pwd -P)"
    top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [[ "${top}" == "${phys}" ]] || return 1
    # a symlink back to the enclosing project (or its main worktree) is that project, not a submodule
    [[ "${phys}" != "$(cd "${PROJECT_ROOT}" && pwd -P)" ]] || return 1
    [[ "${phys}" != "$(git -C "${PROJECT_ROOT}" rev-parse --show-toplevel 2>/dev/null)" ]]
}
if ! is_own_repo "${CONSTITUTION_DIR}"; then
    _common="$(git -C "${PROJECT_ROOT}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    _main_root="${_common%/.git}"
    if [[ -n "${_common}" && "${_main_root}" != "${PROJECT_ROOT}" ]] && is_own_repo "${_main_root}/constitution"; then
        echo "NOTE: linked worktree - constitution/ is not checked out here; using the main worktree's: ${_main_root}/constitution"
        CONSTITUTION_DIR="${_main_root}/constitution"
    fi
fi

echo "=== Constitution Inheritance Verification ==="
echo "Project root: ${PROJECT_ROOT}"
echo "Constitution dir: ${CONSTITUTION_DIR}"
echo

declare -a FAILURES=()

# NOTE: each of these three helpers always returns 0, deliberately, even on
# a failed check. The real failure signal is the FAILURES array (read by the
# final summary), never the function's own exit status - nothing in this
# script ever consumes it (every call site below is a bare statement, not an
# `if check_...; then` condition). This is required for `set -e` (added here
# so this script complies with the project-wide strict-mode convention
# tests/test_syntax.sh checks for): under `set -e`, a bare statement
# returning nonzero aborts the WHOLE script immediately, which would make it
# stop at the FIRST failing invariant instead of collecting and reporting
# every one - exactly the audit behaviour this script exists to provide.
check_file_exists() {
    local file="$1"
    local description="$2"
    if [[ -f "${file}" ]]; then
        echo "  ✓ ${description}: ${file}"
    else
        echo "  ✗ ${description}: ${file} (MISSING)"
        FAILURES+=("${description} missing: ${file}")
    fi
    return 0
}

check_anchor() {
    local file="$1"
    local anchor="$2"
    local description="$3"
    if [[ -f "${file}" ]] && grep -qF "${anchor}" "${file}"; then
        echo "  ✓ ${description} anchor found in ${file}"
    else
        echo "  ✗ ${description} anchor MISSING in ${file}"
        FAILURES+=("${description} anchor missing in ${file}")
    fi
    return 0
}

check_inheritance_pointer() {
    local file="$1"
    local pattern="$2"
    local description="$3"
    if [[ -f "${file}" ]] && grep -qF "${pattern}" "${file}"; then
        echo "  ✓ ${description} inheritance pointer found in ${file}"
    else
        echo "  ✗ ${description} inheritance pointer MISSING in ${file}"
        FAILURES+=("${description} inheritance pointer missing in ${file}")
    fi
    return 0
}

# Invariant 1: constitution/ directory exists
echo "Invariant 1: constitution/ directory exists"
if [[ -d "${CONSTITUTION_DIR}" ]]; then
    echo "  ✓ constitution/ directory exists"
else
    echo "  ✗ constitution/ directory MISSING"
    FAILURES+=("constitution/ directory missing")
fi

# Invariant 2: constitution/Constitution.md exists and contains §11.4 anchor
echo
echo "Invariant 2: constitution/Constitution.md exists with §11.4 anchor"
check_file_exists "${CONSTITUTION_DIR}/Constitution.md" "Constitution.md"
check_anchor "${CONSTITUTION_DIR}/Constitution.md" \
    "§11.4 End-user quality guarantee — forensic anchor" \
    "§11.4 End-user quality guarantee"

# Invariant 3: constitution/CLAUDE.md exists and contains "MANDATORY ANTI-BLUFF COVENANT" anchor
echo
echo "Invariant 3: constitution/CLAUDE.md exists with MANDATORY ANTI-BLUFF COVENANT anchor"
check_file_exists "${CONSTITUTION_DIR}/CLAUDE.md" "CLAUDE.md"
check_anchor "${CONSTITUTION_DIR}/CLAUDE.md" \
    "MANDATORY ANTI-BLUFF COVENANT" \
    "MANDATORY ANTI-BLUFF COVENANT"

# Invariant 4: constitution/AGENTS.md exists and contains "Anti-bluff covenant" anchor
echo
echo "Invariant 4: constitution/AGENTS.md exists with Anti-bluff covenant anchor"
check_file_exists "${CONSTITUTION_DIR}/AGENTS.md" "AGENTS.md"
check_anchor "${CONSTITUTION_DIR}/AGENTS.md" \
    "Anti-bluff covenant" \
    "Anti-bluff covenant"

# Invariant 5: parent CLAUDE.md references the submodule
echo
echo "Invariant 5: Parent CLAUDE.md references constitution submodule"
if [[ -f "${PROJECT_ROOT}/CLAUDE.md" ]]; then
    check_file_exists "${PROJECT_ROOT}/CLAUDE.md" "Parent CLAUDE.md"
    check_inheritance_pointer "${PROJECT_ROOT}/CLAUDE.md" \
        "constitution/CLAUDE.md" \
        "CLAUDE.md"
else
    echo "  ✗ Parent CLAUDE.md MISSING - needs to be created with inheritance pointer"
    FAILURES+=("Parent CLAUDE.md missing")
fi

# Invariant 5b: parent AGENTS.md references the submodule
echo
echo "Invariant 5b: Parent AGENTS.md references constitution submodule"
if [[ -f "${PROJECT_ROOT}/AGENTS.md" ]]; then
    check_file_exists "${PROJECT_ROOT}/AGENTS.md" "Parent AGENTS.md"
    check_inheritance_pointer "${PROJECT_ROOT}/AGENTS.md" \
        "constitution/AGENTS.md" \
        "AGENTS.md"
else
    echo "  ✗ Parent AGENTS.md MISSING - needs to be created with inheritance pointer"
    FAILURES+=("Parent AGENTS.md missing")
fi

# Invariant 5c: Parent Constitution (if exists) references submodule
echo
echo "Invariant 5c: Project Constitution references submodule"
if [[ -f "${PROJECT_ROOT}/docs/validation_and_verification.md" ]]; then
    check_file_exists "${PROJECT_ROOT}/docs/validation_and_verification.md" "Project validation doc"
    # This is the project's validation doc, should be integrated
else
    echo "  - Project validation doc at docs/validation_and_verification.md (will be integrated)"
fi

# Recursive child submodule inheritance check
#
# NOTE (2026-09-22): these three submodules are all THIRD-PARTY (JustVugg/
# colibri, ggml-org/llama.cpp, WangX0111/superspec) - repos this project
# vendors but does not own and has no push access to. This invariant used
# to REQUIRE an injected "Helix Constitution" pointer inside each one's own
# CLAUDE.md/AGENTS.md - but a commit adding that pointer directly into a
# third-party submodule's tree can never be pushed anywhere reachable
# (Constitution §11.4.28(B): never inject project-specific content into a
# submodule the project doesn't own/control). All three submodules had
# EXACTLY this problem this session: their pinned commit was a local-only
# "Add Helix Constitution inheritance pointers" commit, confirmed genuinely
# unreachable from the real upstream by scripts/release/preflight_submodules.sh
# (a real, tested release-blocking check) - meaning a fresh clone running
# `git submodule update` would fail outright. All three pins were reset to
# their real, upstream-reachable base commit, which is why this invariant
# can no longer find the injected pointer text: it was never a legitimate
# thing to look for in a submodule we cannot push to. This check is now
# HONEST informational for third-party submodules (matching the existing
# "no CLAUDE.md/AGENTS.md" branch's non-failing posture below) rather than
# a hard failure - the inheritance relationship for a vendored, non-owned
# dependency is documented in THIS project's own tree (README.md, CLAUDE.md)
# instead, which we do control and can safely commit/push.
echo
echo "Invariant 6: Nested third-party submodules are documented, never modified"
# superspec is no longer a submodule of this repo: it is resolved (lib/resolve_deps.sh), like the constitution.
SUBMODULES=(
    "submodules/superspec"
    "submodules/llama.cpp"
    "submodules/colibri"
)

for submodule in "${SUBMODULES[@]}"; do
    SUB_PATH="${PROJECT_ROOT}/${submodule}"
    if [[ "${submodule}" == "submodules/superspec" && -f "${PROJECT_ROOT}/lib/resolve_deps.sh" ]]; then
        SUB_PATH="$(bash "${PROJECT_ROOT}/lib/resolve_deps.sh" superspec 2>/dev/null || echo "${SUB_PATH}")"
    fi
    if [[ -d "${SUB_PATH}" ]]; then
        echo "  Checking ${submodule}..."

        # Third-party submodule: report presence/absence of its OWN
        # (upstream-authored) CLAUDE.md/AGENTS.md honestly, but never treat
        # the absence of an injected "Helix Constitution" pointer as a
        # failure - injecting one would make the pin unpushable/unreachable.
        if [[ -f "${SUB_PATH}/CLAUDE.md" ]]; then
            echo "  - ${submodule}/CLAUDE.md: present (upstream-owned content, not modified by this project - §11.4.28(B))"
        elif [[ -f "${SUB_PATH}/AGENTS.md" ]]; then
            echo "  - ${submodule}/AGENTS.md: present (upstream-owned content, not modified by this project - §11.4.28(B))"
        else
            echo "  - ${submodule}: No CLAUDE.md or AGENTS.md upstream (nothing to report - not injected either, by design)"
        fi
    else
        echo "  - ${submodule}: Not found"
    fi
done

# Verify constitution submodule has all required files
echo
echo "Invariant 7: Constitution submodule has all required files"
REQUIRED_FILES=(
    "Constitution.md"
    "CLAUDE.md"
    "AGENTS.md"
    "install_upstreams.sh"
    "find_constitution.sh"
)
for req in "${REQUIRED_FILES[@]}"; do
    check_file_exists "${CONSTITUTION_DIR}/${req}" "constitution/${req}"
done

# Verify upstream remotes configured
echo
echo "Invariant 8: Constitution submodule has 4+ upstream remotes configured"
if is_own_repo "${CONSTITUTION_DIR}"; then
    (
        # -C on a directory that IS its own repo (checked above) - never the enclosing project repo
        REMOTE_COUNT=$(git -C "${CONSTITUTION_DIR}" remote | grep -v '^origin$' | wc -l)
        ORIGIN_PUSH_COUNT=$(git -C "${CONSTITUTION_DIR}" remote get-url --push --all origin 2>/dev/null | wc -l)
        echo "  Upstream remotes (excluding origin): ${REMOTE_COUNT}"
        echo "  Origin push URLs: ${ORIGIN_PUSH_COUNT}"
        [[ ${REMOTE_COUNT} -ge 4 ]] && [[ ${ORIGIN_PUSH_COUNT} -ge 4 ]]
    ) && echo "  ✓ At least 4 upstream remotes configured" || {
        echo "  ✗ Insufficient upstream remotes (need 4+, or constitution/ directory missing)"
        FAILURES+=("Insufficient upstream remotes or constitution/ directory missing")
    }
else
    echo "  ✗ constitution/ is not a git checkout of its own (missing, or an uninitialised submodule: git submodule update --init constitution) - cannot check upstream remotes"
    FAILURES+=("Cannot check upstream remotes: constitution/ is not an initialised submodule checkout")
fi

# Nested-submodule readiness (invariants 9 and 10).
#
# run_verification.sh REQUIRES every submodule in its REQUIRED_SUBMODULES list to be checked out under
# constitution/submodules/ (it tests `[ -f <name>/README.md ]` ...). A checkout that populated constitution/ but
# not ITS nested submodules (cloned without --recursive, offline, a linked worktree) fails that harness even though
# the pin is perfectly fine, and meta_test_verification.sh (which re-runs the harness) fails with it.
# That is an environment condition, not an inheritance defect, so invariants 9/10 are then SKIPPED - loudly (a
# `  SKIP:` line each, counted and listed by tests/run_tests.sh, the summary no longer says "ALL INVARIANTS PASSED")
# - and ONLY when all of the following hold, so that a genuinely broken constitution is never masked:
#   * the harness and the meta-test exist and parse (`bash -n`), checked unconditionally;
#   * the constitution is a git checkout of its own (invariant 8 already enforces that);
#   * EVERY name the harness requires is a gitlink (mode 160000) in the pinned tree, i.e. the pin really carries it;
#   * every required name whose directory is missing/empty is exactly an uninitialised submodule.
# A required name that is NOT a gitlink in the pin, or an initialised-but-broken submodule, still runs the real
# harness and FAILS. LLMCTL_REQUIRE_NESTED_SUBMODULES=1 refuses the skip altogether (use it for release gates).
NESTED_SKIP_REASON=""
declare -a SKIPPED=()
HARNESS="${CONSTITUTION_DIR}/scripts/validation/run_verification.sh"
META_TEST="${CONSTITUTION_DIR}/scripts/validation/meta_test_verification.sh"
if [[ -f "${HARNESS}" && -f "${META_TEST}" ]] && bash -n "${HARNESS}" 2>/dev/null && bash -n "${META_TEST}" 2>/dev/null \
   && is_own_repo "${CONSTITUTION_DIR}"; then
    mapfile -t _required < <(sed -n '/^REQUIRED_SUBMODULES=(/,/^)/p' "${HARNESS}" | grep -o '"[^"]*"' | tr -d '"')
    _uninit=(); _not_gitlink=()
    for _n in ${_required[@]+"${_required[@]}"}; do
        _entry="$(git -C "${CONSTITUTION_DIR}" ls-tree HEAD -- "submodules/${_n}" 2>/dev/null || true)"
        if [[ "${_entry}" != "160000 commit "* ]]; then
            _not_gitlink+=("${_n}")
        elif [[ ! -d "${CONSTITUTION_DIR}/submodules/${_n}" || -z "$(ls -A "${CONSTITUTION_DIR}/submodules/${_n}" 2>/dev/null)" ]]; then
            _uninit+=("${_n}")
        fi
    done
    if [[ ${#_required[@]} -gt 0 && ${#_not_gitlink[@]} -eq 0 && ${#_uninit[@]} -gt 0 && "${LLMCTL_REQUIRE_NESTED_SUBMODULES:-}" != "1" ]]; then
        NESTED_SKIP_REASON="${#_uninit[@]} of ${#_required[@]} nested submodules required by run_verification.sh are not initialised in constitution/submodules/ (${_uninit[*]}); the pin itself is consistent (all ${#_required[@]} are gitlinks in the pinned tree) - run: git submodule update --init --recursive inside the resolved constitution hub (or set LLMCTL_REQUIRE_NESTED_SUBMODULES=1 to make this a failure)"
    fi
fi

# Run the verification harness
echo
echo "Invariant 9: Constitution verification harness executes successfully"
if [[ -n "${NESTED_SKIP_REASON}" ]]; then
    echo "  - harness script present and parses; NOT executed"
    echo "  SKIP: Invariant 9 (verification harness execution) - ${NESTED_SKIP_REASON}"
    SKIPPED+=("Invariant 9")
elif [[ -f "${CONSTITUTION_DIR}/scripts/validation/run_verification.sh" ]]; then
    echo "  ✓ Verification harness exists"
    if bash "${CONSTITUTION_DIR}/scripts/validation/run_verification.sh" > /tmp/verification_output.txt 2>&1; then
        echo "  ✓ Verification harness executes successfully"
    else
        echo "  ✗ Verification harness FAILED"
        FAILURES+=("Verification harness execution failed")
        cat /tmp/verification_output.txt
    fi
else
    echo "  ✗ Verification harness MISSING"
    FAILURES+=("Verification harness missing")
fi

# Run meta-test mutation
echo
echo "Invariant 10: Meta-test mutation proves gate is not a bluff"
if [[ -n "${NESTED_SKIP_REASON}" ]]; then
    echo "  - meta-test script present and parses; NOT executed (it re-runs the harness)"
    echo "  SKIP: Invariant 10 (meta-test mutation) - ${NESTED_SKIP_REASON}"
    SKIPPED+=("Invariant 10")
elif [[ -f "${CONSTITUTION_DIR}/scripts/validation/meta_test_verification.sh" ]]; then
    echo "  ✓ Meta-test mutation script exists"
    if bash "${CONSTITUTION_DIR}/scripts/validation/meta_test_verification.sh" > /tmp/meta_test_output.txt 2>&1; then
        echo "  ✓ Meta-test mutation passes (gate catches regressions)"
    else
        echo "  ✗ Meta-test mutation FAILED"
        FAILURES+=("Meta-test mutation failed")
        cat /tmp/meta_test_output.txt
    fi
else
    echo "  ✗ Meta-test mutation script MISSING"
    FAILURES+=("Meta-test mutation script missing")
fi

# Summary
echo
echo "=== INHERITANCE VERIFICATION SUMMARY ==="
if [[ ${#FAILURES[@]} -eq 0 && ${#SKIPPED[@]} -eq 0 ]]; then
    echo "ALL INVARIANTS PASSED ✓"
    echo "  ok: all constitution inheritance invariants passed"
    exit 0
elif [[ ${#FAILURES[@]} -eq 0 ]]; then
    echo "INVARIANTS 1-8 PASSED; SKIPPED (not run, NOT passed): ${SKIPPED[*]}"
    echo "  ok: constitution inheritance invariants 1-8 passed (harness/meta-test present and parse; ${SKIPPED[*]} skipped, see SKIP lines above)"
    exit 0
else
    echo "FAILURES (${#FAILURES[@]}):"
    for failure in "${FAILURES[@]}"; do
        echo "  ✗ ${failure}"
    done
    exit 1
fi
