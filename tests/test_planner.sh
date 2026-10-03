#!/usr/bin/env bash
# test_planner.sh - deterministic planner tests against the hardware fixtures.
# Expected values below are derived from the catalog sizes and the documented
# memory model (RAM budget = avail - 4GiB, VRAM budget = 85% of REAL FREE
# VRAM when measured, else 85% of total as a fallback, KV = ctx * parallel /
# 8 MiB). All fixtures here predate the free-VRAM field and so exercise the
# fallback path; hw-vram-contended.json (below) is the one fixture that
# carries a real gpu_free_vram_mb and exercises the live-measurement path.
# If the catalog or the memory model changes, these expectations must be
# updated deliberately.
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

# --- catalog_classify_tier is the SAME tier `catalog_plan_json` computes ------
# catalog_classify_tier's own doc comment says it is "exposed as its own
# function so tests can pin the rules" - until now nothing actually called
# or tested it directly (Constitution §11.4.124 investigate-before-remove:
# git history is a single squashed "Init." commit with no further trail, so
# the wiring gap could not be traced further than this; the function's own
# stated purpose is proof enough that it should be wired in, not deleted).
# It is now the single source of truth catalog_plan_json calls, closing a
# real duplication/drift-risk gap (the tier thresholds used to be hand-
# copied in two places).
assert_eq "baseline" "$(printf '%s' "$(LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json" hw_probe_json)" | catalog_classify_tier)" \
  "catalog_classify_tier: baseline fixture"
assert_eq "datacenter" "$(printf '%s' "$(LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-workstation.json" hw_probe_json)" | catalog_classify_tier)" \
  "catalog_classify_tier: workstation fixture (actually computes datacenter, matching catalog_plan_json above)"
assert_eq "workstation" "$(printf '%s' "$(LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-apple.json" hw_probe_json)" | catalog_classify_tier)" \
  "catalog_classify_tier: apple fixture"
assert_eq "baseline" "$(printf '%s' "$(LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-constrained.json" hw_probe_json)" | catalog_classify_tier)" \
  "catalog_classify_tier: constrained fixture (8 cores / 32768 MiB RAM sits exactly at the baseline threshold)"

# --- vram-contended: SAME total VRAM as "baseline" (12288 MiB) but only
# 3000 MiB is REAL FREE VRAM (simulating something else already holding
# ~9.3GiB on the same card) - root-caused 2026-10-03: the pre-fix
# total-based budget (12288*0.85=10444) let "small" (~2949 MiB real
# footprint: 1926 MiB weights + 1024 MiB KV at ctx=8192/parallel=1) report
# "fits: true" / mode "gpu" here, and it then genuinely OOM'd at launch
# time (cudaMalloc failed) because the real free budget (3000*0.85=2550)
# could never have held it. This is the exact scenario the free-VRAM fix
# targets: same card, same catalog, only the LIVE measurement differs.
plan="$(plan_for vram-contended)"
assert_eq "2550" "$(printf '%s' "${plan}" | json_stdin 'd["budgets"]["vram_mb"]')" \
  "vram-contended VRAM budget uses REAL FREE (3000*0.85), not total (12288*0.85=10444)"
# "fits" means "fits this host in SOME mode" (gpu OR cpu), not specifically
# gpu -- "small" still fits overall via the cpu-mode RAM fallback (there is
# plenty of RAM budget), so it correctly stays "true" here. The real proof
# this fix works is the MODE assertion below: it must be "cpu", never "gpu"
# (which would OOM against the real 3000 MiB free budget).
assert_eq "true" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["small"]["fits"]' | tr 'A-Z' 'a-z')" \
  "small still fits this host overall (via cpu-mode RAM fallback), just no longer via gpu mode"
assert_eq "cpu" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["small"]["mode"]')" \
  "small correctly falls through to cpu mode instead of a gpu mode that would OOM"

test_finish
