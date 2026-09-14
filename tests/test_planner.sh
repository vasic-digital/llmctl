#!/usr/bin/env bash
# test_planner.sh - deterministic planner tests against the 3 hardware fixtures.
# Expected values below are derived from the catalog sizes and the documented
# memory model (RAM budget = avail - 4GiB, VRAM budget = total * 0.85,
# KV = ctx * parallel / 8 MiB). If the catalog or the memory model changes,
# these expectations must be updated deliberately.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/os_detect.sh"
source "${LLMCTL_ROOT}/lib/hardware.sh"
source "${LLMCTL_ROOT}/lib/catalog.sh"

plan_for() {
  LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-$1.json" hw_probe_json | catalog_plan_json
}

# --- baseline: Ryzen 7 2700X / 32GB / RTX 3060 12GB / NVMe -------------------
plan="$(plan_for baseline)"
assert_eq "baseline" "$(printf '%s' "${plan}" | json_stdin 'd["tier"]')" "baseline tier"
assert_eq "25904" "$(printf '%s' "${plan}" | json_stdin 'd["budgets"]["ram_mb"]')" "baseline RAM budget (30000-4096)"
assert_eq "10444" "$(printf '%s' "${plan}" | json_stdin 'd["budgets"]["vram_mb"]')" "baseline VRAM budget (12288*0.85)"
assert_eq "fast coder vision moe-fast small" \
  "$(printf '%s' "${plan}" | json_stdin '" ".join(d["recommended"])')" \
  "baseline recommended set"
assert_eq "gpu"  "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["fast"]["mode"]')"  "baseline fast mode"
assert_eq "cpu"  "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["coder"]["mode"]')" "baseline coder mode (17.7GiB > 10444MiB VRAM)"
assert_eq "5716" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["fast"]["vram_mb"]')" "baseline fast VRAM footprint (4692 model + 1024 KV)"
assert_eq "21793" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["coder"]["ram_mb"]')" "baseline coder RAM footprint (17697 + 4096 KV)"
assert_eq "False" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["ws-dense-32b"]["tier_ok"]')" "baseline gates ws-dense-32b by tier"
assert_eq "fast coder vision|moe-fast small" \
  "$(printf '%s' "${plan}" | json_stdin '"|".join(" ".join(g["profiles"]) for g in d["coresidency_groups"])')" \
  "baseline co-residency groups"

# --- workstation: Threadripper 64c / 256GB / 32GB VRAM / 2TB NVMe ------------
plan="$(plan_for workstation)"
assert_eq "datacenter" "$(printf '%s' "${plan}" | json_stdin 'd["tier"]')" "workstation fixture tier"
assert_eq "fast coder vision vision-pro moe-fast small ws-dense-32b ws-moe-30b colibri-glm colibri-qwen36" \
  "$(printf '%s' "${plan}" | json_stdin '" ".join(d["recommended"])')" \
  "workstation recommended set (all 10 profiles)"
assert_eq "gpu" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["ws-dense-32b"]["mode"]')" "ws-dense-32b fully offloaded"
assert_eq "colibri" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["colibri-glm"]["mode"]')" "colibri-glm mode"
assert_eq "fast coder|vision vision-pro|moe-fast small|ws-dense-32b|ws-moe-30b colibri-glm colibri-qwen36" \
  "$(printf '%s' "${plan}" | json_stdin '"|".join(" ".join(g["profiles"]) for g in d["coresidency_groups"])')" \
  "workstation co-residency groups"

# --- apple: M4 Max 64GB unified ----------------------------------------------
plan="$(plan_for apple)"
assert_eq "workstation" "$(printf '%s' "${plan}" | json_stdin 'd["tier"]')" "apple tier (64GB unified RAM)"
assert_eq "fast coder vision vision-pro moe-fast small ws-dense-32b ws-moe-30b colibri-qwen36" \
  "$(printf '%s' "${plan}" | json_stdin '" ".join(d["recommended"])')" \
  "apple recommended set (colibri-glm gated to datacenter)"
assert_eq "False" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["colibri-glm"]["tier_ok"]')" "apple gates colibri-glm"
assert_eq "gpu" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["fast"]["mode"]')" "apple fast uses unified-memory GPU"

# --- plan human rendering does not crash -------------------------------------
human="$(plan_for baseline | catalog_plan_human)"
assert_contains "${human}" "Host tier:   baseline" "human plan header"
assert_contains "${human}" "Co-residency groups" "human plan groups"

test_finish
