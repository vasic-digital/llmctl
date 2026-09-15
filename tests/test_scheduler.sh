#!/usr/bin/env bash
# test_scheduler.sh - dry-run scheduler: co-residency start, refusal with
# alternative, LRU eviction in `auto`, enabled-service protection, switch.
# All service actions are dry-run; reservation state lives in a temp dir.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

export LLMCTL_DRY_RUN=1
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
LLMCTL="${LLMCTL_ROOT}/bin/llmctl"

# --- 1. co-resident start fits ------------------------------------------------
out="$("${LLMCTL}" start fast small 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "start fast small (co-resident) exit code"
assert_contains "${out}" "started fast" "fast started"
assert_contains "${out}" "started small" "small started"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/fast.run" "fast reservation written"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/small.run" "small reservation written"
out="$("${LLMCTL}" status)"
assert_contains "${out}" "fast" "status lists fast"
assert_contains "${out}" "small" "status lists small"

# --- 2. refusal with suggested alternative ------------------------------------
# fast+small reserve 9689/10444 MiB VRAM; vision needs 4210 -> must refuse.
sleep 1  # ensure distinct LRU epochs
out="$("${LLMCTL}" start vision 2>&1)" && rc=0 || rc=$?
assert_eq 1 "${rc}" "start vision refused (exit 1)"
assert_contains "${out}" "cannot start 'vision'" "refusal message"
assert_contains "${out}" "suggested alternative" "alternative suggested"
assert_contains "${out}" "llmctl switch vision" "switch fallback suggested"
# nothing changed
assert_file_exists "${LLMCTL_RUNTIME_DIR}/fast.run" "fast kept after refusal"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/small.run" "small kept after refusal"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/vision.run" "vision not started after refusal"

# --- 3. auto evicts the LRU non-enabled service --------------------------------
out="$("${LLMCTL}" auto vision 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "auto vision exit code"
assert_contains "${out}" "evicting 'fast'" "LRU eviction of fast announced"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/fast.run" "fast reservation removed after eviction"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/small.run" "small kept after eviction"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/vision.run" "vision running after eviction"

# --- 4. enabled services are never evicted -------------------------------------
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-constrained.json"
test_teardown_env; test_setup_env   # fresh state for the new fixture
out="$("${LLMCTL}" start fast 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "constrained: start fast"
touch "${LLMCTL_SERVICES_DIR}/fast.enabled"   # mark enabled (protected)
# VRAM budget 6963 MiB; fast holds 5716; vision needs 4210 -> only eviction of
# fast could make room, but it is enabled.
out="$("${LLMCTL}" auto vision 2>&1)" && rc=0 || rc=$?
assert_eq 1 "${rc}" "constrained: auto vision fails (exit 1)"
assert_contains "${out}" "enabled (protected)" "protection message"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/fast.run" "protected service untouched"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/vision.run" "vision not started (protected)"

# --- 5. switch always works ----------------------------------------------------
out="$("${LLMCTL}" switch moe-fast 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "switch moe-fast exit code"
running=""
for f in "${LLMCTL_RUNTIME_DIR}"/*.run; do
  [[ -e "${f}" ]] || continue
  running="${running}${running:+ }$(basename "${f}" .run)"
done
assert_eq "moe-fast" "${running}" "switch leaves exactly one service running"

# --- 6. dry-run never calls systemctl ------------------------------------------
out="$("${LLMCTL}" stop all 2>&1)"
assert_contains "${out}" "[dry-run] systemctl --user stop" "stop is a dry-run action"

# --- 7. `llmctl auto coder vision` co-residency (spec.md US1 Acceptance
# Scenario 3: "Given multiple models downloaded, When running `llmctl auto
# coder vision`, Then co-residency is computed and services start if
# budgets allow"). tests/fixtures/hw-workstation.json (64 cores / 256 GiB
# RAM / 32 GiB VRAM / 2 TiB free) classifies as "datacenter" tier per
# catalog_classify_tier's actual thresholds (cores>=32 AND ram>=96GiB AND
# free>=400GiB - all three hold here), NOT "workstation" - the filename
# predates that threshold and is left as-is (a naming nit, not a defect);
# this test verifies the REAL computed behavior against it, not an assumed
# "workstation" classification. ------------------------------------------------
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-workstation.json"
test_teardown_env; test_setup_env   # fresh state for the new fixture

out="$("${LLMCTL}" auto coder vision 2>&1)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "auto coder vision exit code (US1 Acceptance Scenario 3)"
assert_contains "${out}" "capability 'coder' -> profile" "co-residency computation: coder capability resolved to a profile"
assert_contains "${out}" "capability 'vision' -> profile" "co-residency computation: vision capability resolved to a profile"
assert_contains "${out}" "started" "at least one service started (budgets allow on this abundant fixture)"
# Ample budget on this fixture (datacenter tier: 235904 MiB RAM / 27852 MiB
# VRAM available) means BOTH resolved profiles fit without any eviction.
eviction_count="$(echo "${out}" | grep -c "evicting" || true)"
assert_eq 0 "${eviction_count}" "no eviction needed - both profiles fit the abundant budget directly"
running_count=0
for f in "${LLMCTL_RUNTIME_DIR}"/*.run; do
  [[ -e "${f}" ]] || continue
  running_count=$((running_count + 1))
done
assert_eq 2 "${running_count}" "both resolved profiles (coder + vision capabilities) ended up running"

# --- 8. LLMCTL_SEED enforces deterministic --seed/--temp 0 on llama launches
# (Phase 5 T029, spec.md FR-012/SC-008: "Live challenges MUST be deterministic
# ... Use temperature 0 AND fixed seed (--seed <fixed_value>) for llama.cpp").
# Opt-in via an env var (matching the project's existing LLMCTL_DRY_RUN
# idiom) rather than baked into every default launch: an always-on fixed
# seed would make every interactive coding-assistant session identically
# non-creative, which the spec does not ask for - FR-012 scopes determinism
# to "live challenges" (the manual release-gating procedure, US4), not
# everyday interactive use. -----------------------------------------------
source "${LLMCTL_ROOT}/lib/scheduler.sh"

# LLMCTL_DRY_RUN=1 so sched_build_launch's model-file-exists check (line 130
# of scheduler.sh) doesn't require a real downloaded model on disk.
export LLMCTL_DRY_RUN=1

sched_build_launch fast cpu 8080 8192 99 1 auto
seed_present=0
for a in "${SCHED_ARGS[@]}"; do [[ "${a}" == "--seed" ]] && seed_present=1; done
assert_eq 0 "${seed_present}" "LLMCTL_SEED unset: no --seed flag added (default interactive behavior unchanged)"

export LLMCTL_SEED=42
sched_build_launch fast cpu 8080 8192 99 1 auto
assert_contains "${SCHED_ARGS[*]}" "--seed 42" "LLMCTL_SEED=42: llama launch includes --seed 42"
assert_contains "${SCHED_ARGS[*]}" "--temp 0" "LLMCTL_SEED set: llama launch includes --temp 0 (FR-012 fixed-seed + temperature-0 pair)"
unset LLMCTL_SEED

test_finish
