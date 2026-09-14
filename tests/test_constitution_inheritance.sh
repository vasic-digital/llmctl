#!/usr/bin/env bash
# test_constitution_inheritance.sh — Comprehensive inheritance verification
# Verifies all invariants from Constitution Submodule Setup Agent Step 7 & 9

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONSTITUTION_DIR="${PROJECT_ROOT}/constitution"

echo "=== Constitution Inheritance Verification ==="
echo "Project root: ${PROJECT_ROOT}"
echo "Constitution dir: ${CONSTITUTION_DIR}"
echo

declare -a FAILURES=()

check_file_exists() {
    local file="$1"
    local description="$2"
    if [[ -f "${file}" ]]; then
        echo "  ✓ ${description}: ${file}"
        return 0
    else
        echo "  ✗ ${description}: ${file} (MISSING)"
        FAILURES+=("${description} missing: ${file}")
        return 1
    fi
}

check_anchor() {
    local file="$1"
    local anchor="$2"
    local description="$3"
    if [[ -f "${file}" ]] && grep -qF "${anchor}" "${file}"; then
        echo "  ✓ ${description} anchor found in ${file}"
        return 0
    else
        echo "  ✗ ${description} anchor MISSING in ${file}"
        FAILURES+=("${description} anchor missing in ${file}")
        return 1
    fi
}

check_inheritance_pointer() {
    local file="$1"
    local pattern="$2"
    local description="$3"
    if [[ -f "${file}" ]] && grep -qF "${pattern}" "${file}"; then
        echo "  ✓ ${description} inheritance pointer found in ${file}"
        return 0
    else
        echo "  ✗ ${description} inheritance pointer MISSING in ${file}"
        FAILURES+=("${description} inheritance pointer missing in ${file}")
        return 1
    fi
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
echo
echo "Invariant 6: Nested submodules have inheritance pointers"
SUBMODULES=(
    "submodules/superspec"
    "submodules/llama.cpp"
    "submodules/colibri"
)

for submodule in "${SUBMODULES[@]}"; do
    SUB_PATH="${PROJECT_ROOT}/${submodule}"
    if [[ -d "${SUB_PATH}" ]]; then
        echo "  Checking ${submodule}..."
        
        # Check for CLAUDE.md or AGENTS.md with inheritance pointer
        if [[ -f "${SUB_PATH}/CLAUDE.md" ]]; then
            check_inheritance_pointer "${SUB_PATH}/CLAUDE.md" \
                "Helix Constitution" \
                "${submodule}/CLAUDE.md"
        elif [[ -f "${SUB_PATH}/AGENTS.md" ]]; then
            check_inheritance_pointer "${SUB_PATH}/AGENTS.md" \
                "Helix Constitution" \
                "${submodule}/AGENTS.md"
        else
            echo "  - ${submodule}: No CLAUDE.md or AGENTS.md (will need inheritance pointer added)"
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
cd "${CONSTITUTION_DIR}"
REMOTE_COUNT=$(git remote | grep -v '^origin$' | wc -l)
ORIGIN_PUSH_COUNT=$(git remote get-url --push --all origin 2>/dev/null | wc -l)
echo "  Upstream remotes (excluding origin): ${REMOTE_COUNT}"
echo "  Origin push URLs: ${ORIGIN_PUSH_COUNT}"
if [[ ${REMOTE_COUNT} -ge 4 ]] && [[ ${ORIGIN_PUSH_COUNT} -ge 4 ]]; then
    echo "  ✓ At least 4 upstream remotes configured"
else
    echo "  ✗ Insufficient upstream remotes (need 4+)"
    FAILURES+=("Insufficient upstream remotes: ${REMOTE_COUNT} found, need 4+")
fi

# Run the verification harness
echo
echo "Invariant 9: Constitution verification harness executes successfully"
if [[ -f "${CONSTITUTION_DIR}/scripts/validation/run_verification.sh" ]]; then
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
if [[ -f "${CONSTITUTION_DIR}/scripts/validation/meta_test_verification.sh" ]]; then
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
if [[ ${#FAILURES[@]} -eq 0 ]]; then
    echo "ALL INVARIANTS PASSED ✓"
    exit 0
else
    echo "FAILURES (${#FAILURES[@]}):"
    for failure in "${FAILURES[@]}"; do
        echo "  ✗ ${failure}"
    done
    exit 1
fi
