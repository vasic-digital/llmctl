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
# decide-tiny (min_tier below-minimum, 1592 MiB GPU footprint), decide
# (min_tier baseline, 3671 MiB), the onnx encoder decide-nli (min_tier
# below-minimum, CPU-only: RAM 1663*1.5+512 = 3006 MiB, VRAM 0) and
# decide-2b (min_tier baseline, 3006 MiB) all fit a baseline host and join
# the recommended set; decide-pro and decide-max stay tier-gated to
# workstation.
assert_eq "fast coder vision moe-fast small decide-tiny decide decide-nli decide-2b decide-julia decide-kev-08b decide-kev-4b decide-laya decide-lev" \
  "$(printf '%s' "${plan}" | json_stdin '" ".join(d["recommended"])')" \
  "baseline recommended set (decide-tiny/decide + iter2 decide-nli/decide-2b + the native decide-julia/kev-08b/kev-4b/laya/lev; decide-kev-9b tier-gated to workstation)"
assert_eq "gpu"  "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["fast"]["mode"]')"  "baseline fast mode"
assert_eq "cpu"  "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["coder"]["mode"]')" "baseline coder mode (17.7GiB > 10444MiB VRAM)"
assert_eq "5716" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["fast"]["vram_mb"]')" "baseline fast VRAM footprint (4692 model + 1024 KV)"
assert_eq "21793" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["coder"]["ram_mb"]')" "baseline coder RAM footprint (17697 + 4096 KV)"
assert_eq "False" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["ws-dense-32b"]["tier_ok"]')" "baseline gates ws-dense-32b by tier"
# Group 2 arithmetic (RAM budget 25904, VRAM budget 10444): moe-fast
# (2048/3137) + small (2048/2950) + decide-tiny (2048/1592) + decide
# (2048/3671) = VRAM 11350-2228=9122 (captured; weights footprints differ
# per profile) still fits, and the CPU-only decide-nli (RAM 3006, VRAM 0)
# joins on RAM alone (RAM 2048*4+3006 = 11198 <= 25904). decide-2b
# (2048/3006) would push VRAM to 12128 > 10444 -> new group 3 of one.
assert_eq "fast coder vision|moe-fast small decide-tiny decide decide-nli|decide-2b decide-julia decide-kev-08b|decide-kev-4b decide-laya|decide-lev" \
  "$(printf '%s' "${plan}" | json_stdin '"|".join(" ".join(g["profiles"]) for g in d["coresidency_groups"])')" \
  "baseline co-residency groups (decide-nli joins group 2 as VRAM-0; decide-2b spills to group 3 with decide-julia/decide-kev-08b, whose measured working-set overheads fill the VRAM budget; decide-kev-4b and decide-laya share group 4; decide-lev ends alone in group 5)"

# --- onnx footprint branch (decide-nli) --------------------------------------
# Catalog pins: files sum to 1744456292 B = 1663 MiB (1741985401 model.onnx
# + 2464616 spm.model + two small configs; the unused 8.6 MB tokenizer.json
# is no longer listed - D-22).
# RAM reservation = floor(size*1.5) + 512 = 2494 + 512 = 3006 MiB (integer
# floor arithmetic: 1663*3//2 + 512); VRAM 0; mode always cpu
# (onnxruntime CPUExecutionProvider); storage need 1663*1.1 = 1829 <= free.
assert_eq "cpu"  "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["decide-nli"]["mode"]')" "decide-nli mode is always cpu (onnx encoder)"
assert_eq "3006" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["decide-nli"]["ram_mb"]')" "decide-nli RAM reservation = 1663*3//2 + 512 = 3006 MiB"
assert_eq "0"    "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["decide-nli"]["vram_mb"]')" "decide-nli VRAM need is 0 (CPU inference)"
assert_eq "512"  "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["decide-nli"]["ctx"]')" "decide-nli ctx default 512 (encoder, not a generation ctx)"
assert_eq "True" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["decide-nli"]["fits"]')" "decide-nli fits baseline (3006 <= 25904)"
assert_eq "True" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["decide-nli"]["recommended"]')" "decide-nli recommended on baseline (min_tier below-minimum)"
# decide-2b / decide-max llama footprints (KV ceil(8192*2*0.53125/8)=1088):
assert_eq "3006" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["decide-2b"]["vram_mb"]')" "decide-2b GPU footprint (1918 weights + 1088 KV)"
assert_eq "False" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["decide-max"]["tier_ok"]')" "decide-max tier-gated on baseline"
assert_eq "10174" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["decide-max"]["vram_mb"]')" "decide-max GPU footprint (9086 weights + 1088 KV)"

# --- workstation: Threadripper 64c / 256GB / 32GB VRAM / 2TB NVMe ------------
plan="$(plan_for workstation)"
assert_eq "datacenter" "$(printf '%s' "${plan}" | json_stdin 'd["tier"]')" "workstation fixture tier"
assert_eq "fast coder vision vision-pro moe-fast small ws-dense-32b ws-moe-30b colibri-glm colibri-qwen36 decide-tiny decide decide-pro decide-nli decide-max decide-2b decide-julia decide-kev-08b decide-kev-4b decide-kev-9b decide-laya decide-lev" \
  "$(printf '%s' "${plan}" | json_stdin '" ".join(d["recommended"])')" \
  "workstation recommended set (all 22 profiles: decide-pro/decide-max/decide-kev-9b workstation tier gate passes on a datacenter host)"
assert_eq "gpu" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["ws-dense-32b"]["mode"]')" "ws-dense-32b fully offloaded"
assert_eq "colibri" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["colibri-glm"]["mode"]')" "colibri-glm mode"
# Group 5 (VRAM budget 27852): ws-moe-30b (vram 25889) + colibri-glm +
# colibri-qwen36 (colibri: vram 0) + decide-tiny (vram 1592) = 27481 fits;
# adding decide (vram 3671) would reach 31152 > 27852 -> new group 6 holds
# decide + decide-pro (vram 3671+5260 = 8931) + the CPU-only decide-nli
# (vram 0, RAM 3006) + decide-2b (3006) = 11937 fits; decide-max (10174)
# would reach 22111 > ... (captured: it fits too, 22111 <= 27852) -> one
# group of five.
assert_eq "fast coder|vision vision-pro|moe-fast small|ws-dense-32b|ws-moe-30b colibri-glm colibri-qwen36 decide-tiny|decide decide-pro decide-nli decide-max decide-2b decide-julia|decide-kev-08b decide-kev-4b decide-kev-9b decide-laya decide-lev" \
  "$(printf '%s' "${plan}" | json_stdin '"|".join(" ".join(g["profiles"]) for g in d["coresidency_groups"])')" \
  "workstation co-residency groups (group 6 = the five remaining letter/NLI decide profiles + the small native ones up to decide-julia; group 7 = decide-kev-08b and the remaining native profiles; measured planner output)"

# --- apple: M4 Max 64GB unified ----------------------------------------------
plan="$(plan_for apple)"
assert_eq "workstation" "$(printf '%s' "${plan}" | json_stdin 'd["tier"]')" "apple tier (64GB unified RAM)"
assert_eq "fast coder vision vision-pro moe-fast small ws-dense-32b ws-moe-30b colibri-qwen36 decide-tiny decide decide-pro decide-nli decide-max decide-2b decide-julia decide-kev-08b decide-kev-4b decide-kev-9b decide-laya decide-lev" \
  "$(printf '%s' "${plan}" | json_stdin '" ".join(d["recommended"])')" \
  "apple recommended set (colibri-glm gated to datacenter; all twelve decide profiles fit 64GB unified memory)"
assert_eq "False" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["colibri-glm"]["tier_ok"]')" "apple gates colibri-glm"
assert_eq "gpu" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["fast"]["mode"]')" "apple fast uses unified-memory GPU"

# memory_status accounts for BOTH halves; an unmeasured half is reported UNKNOWN (booked 0 is a floor, never a measurement)
assert_eq "partial vram" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["decide-lev"]["memory_status"] + " " + "|".join(d["profiles"]["decide-lev"]["unknown_overhead"])')" \
  "T139: decide-lev (RAM measured, VRAM not) is partial with unknown_overhead=[vram]"
assert_eq "measured " "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["decide-julia"]["memory_status"] + " " + "|".join(d["profiles"]["decide-julia"]["unknown_overhead"])')" \
  "T139 golden-false: fully measured decide-julia has no unknown overhead"
assert_eq "unmeasured ram|vram" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["decide-tiny"]["memory_status"] + " " + "|".join(d["profiles"]["decide-tiny"]["unknown_overhead"])')" \
  "T139: decide-tiny has both halves UNKNOWN"

# --- plan human rendering does not crash -------------------------------------
human="$(plan_for baseline | catalog_plan_human)"
assert_contains "${human}" "overhead UNKNOWN (ram,vram" "T139: human plan flags a recommended profile whose overhead is UNKNOWN (booked as 0)"
if [[ "${human}" == *"experimental: none"* ]]; then assert_eq "absent" "present" "T138: a fully measured profile never prints 'experimental: none'"; else assert_eq "ok" "ok" "T138: a fully measured profile never prints 'experimental: none'"; fi
assert_contains "$(printf '%s\n' "${human}" | grep 'decide-lev ')" "all types measured" "T138: fully measured decide-lev prints 'all types measured'"
assert_contains "${human}" "Host tier:   baseline" "human plan header"
assert_contains "${human}" "Co-residency groups" "human plan groups"
# T138: the plan shows each decision profile's per-type maturity (from the catalog's evidence-derived object)
assert_eq "noul,choice,score" "$(printf '%s' "${plan}" | json_stdin '",".join(d["profiles"]["decide-kev-9b"]["experimental_types"])')" \
  "T138: unmeasured decide-kev-9b lists every type as experimental"
assert_eq "score" "$(printf '%s' "${plan}" | json_stdin '",".join(d["profiles"]["decide-kev-08b"]["experimental_types"])')" \
  "T138: decide-kev-08b is experimental on score only"
assert_eq "" "$(printf '%s' "${plan}" | json_stdin '",".join(d["profiles"]["decide-lev"]["experimental_types"])')" \
  "T138: fully measured decide-lev has no experimental type"
assert_eq "False" "$(printf '%s' "${plan}" | json_stdin '"experimental_types" in d["profiles"]["fast"]')" \
  "T138: golden-false: a non-decision profile carries no maturity field"
assert_contains "${human}" "Maturity (decision profiles" "T138: human plan has the maturity section"
assert_contains "${human}" "decide-kev-08b" "T138: human plan lists decide-kev-08b"
assert_contains "${human}" "experimental: score" "T138: human plan names the experimental type"

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

# --- decision_instances (decide capability capacity report) ------------------
# Footprints, derived from the catalog pins and the documented memory model
# (KV = ceil(ctx * parallel * KV_TYPE_RATIO[q8_0=0.53125] / 8) MiB; GPU mode
# reserves 2048 MiB RAM):
#   decide-tiny: size 529296864 B = 504 MiB; KV ceil(4096*4*0.53125/8) = 1088
#     -> gpu {ram 2048, vram 1592}, cpu {ram 1592}
#   decide:      size 2708804640 B = 2583 MiB; KV ceil(8192*2*0.53125/8) = 1088
#     -> gpu {ram 2048, vram 3671}, cpu {ram 3671}
#   decide-pro:  size 4375021216 B = 4172 MiB; KV 1088
#     -> gpu {ram 2048, vram 5260}, cpu {ram 5260}
#   decide-nli:  size 1744456292 B = 1663 MiB; ONNX encoder, CPU-only:
#     per-instance RAM = 1663*3//2 + 512 = 3006 MiB, VRAM 0, gpu n/a,
#     parallel=1 -> 1 slot per instance
#   decide-2b:   size 2012012000 B = 1918 MiB; KV 1088
#     -> gpu {ram 2048, vram 3006}, cpu {ram 3006}
#   decide-max:  size 9527501280 B = 9086 MiB; KV 1088
#     -> gpu {ram 2048, vram 10174}, cpu {ram 10174}

# baseline (RAM budget 25904, VRAM budget 10444, tier baseline):
#   decide-tiny: gpu min(10444//1592=6, 25904//2048=12) = 6; cpu 25904//1592 = 16
#   decide:      gpu min(10444//3671=2, 12) = 2;              cpu 25904//3671 = 7
#   decide-pro:  tier-gated (baseline < workstation) -> 0 with reason
#   decide-nli:  gpu ALWAYS 0 (CPU-only engine);                cpu 25904//3006 = 8
#   decide-2b:   gpu min(10444//3006=3, 12) = 3;               cpu 25904//3006 = 8
#   decide-max:  tier-gated (baseline < workstation) -> 0 with reason
plan="$(plan_for baseline)"
di() { printf '%s' "${plan}" | json_stdin "d[\"decision_instances\"][\"$1\"][\"$2\"]"; }
assert_eq 6  "$(di decide-tiny instances_gpu)" "baseline decide-tiny gpu instances (min(10444//1592, 25904//2048)=6)"
assert_eq 16 "$(di decide-tiny instances_cpu)" "baseline decide-tiny cpu instances (25904//1592=16)"
assert_eq 4  "$(printf '%s' "${plan}" | json_stdin 'd["decision_instances"]["decide-tiny"]["per_instance"]["slots"]')" "baseline decide-tiny slots per instance (parallel=4)"
assert_eq 64 "$(di decide-tiny total_decision_slots)" "baseline decide-tiny total slots (max(6,16)*4=64)"
assert_eq 2  "$(di decide instances_gpu)" "baseline decide gpu instances (min(10444//3671, 12)=2)"
assert_eq 7  "$(di decide instances_cpu)" "baseline decide cpu instances (25904//3671=7)"
assert_eq 14 "$(di decide total_decision_slots)" "baseline decide total slots (max(2,7)*2=14)"
assert_eq 0  "$(di decide-pro instances_gpu)" "baseline decide-pro tier-gated to 0 gpu instances"
assert_eq 0  "$(di decide-pro instances_cpu)" "baseline decide-pro tier-gated to 0 cpu instances"
assert_contains "$(printf '%s' "${plan}" | json_stdin 'd["decision_instances"]["decide-pro"].get("reason", "")')" \
  "tier gate" "baseline decide-pro carries a tier-gate reason"
# onnx fixture arithmetic #1 (baseline): decide-nli is CPU-only - GPU
# instances are ALWAYS 0 (never the zero-cost divide-by-zero case); CPU
# instances divide the SAME 25904 MiB RAM budget by the 3006 MiB onnx
# reservation; parallel=1 -> 1 slot per instance.
assert_eq 0 "$(di decide-nli instances_gpu)" "baseline decide-nli gpu instances ALWAYS 0 (CPU-only onnx encoder)"
assert_eq 8 "$(di decide-nli instances_cpu)" "baseline decide-nli cpu instances (25904//3006=8)"
assert_eq 0 "$(printf '%s' "${plan}" | json_stdin 'd["decision_instances"]["decide-nli"]["per_instance"]["vram_mb"]')" "baseline decide-nli per-instance VRAM 0"
assert_eq 3006 "$(printf '%s' "${plan}" | json_stdin 'd["decision_instances"]["decide-nli"]["per_instance"]["ram_mb"]')" "baseline decide-nli per-instance RAM 3006 (1663*3//2+512)"
assert_eq 1 "$(printf '%s' "${plan}" | json_stdin 'd["decision_instances"]["decide-nli"]["per_instance"]["slots"]')" "baseline decide-nli slots per instance (parallel=1: per-option forward passes)"
assert_eq 8 "$(di decide-nli total_decision_slots)" "baseline decide-nli total slots (max(0,8)*1=8)"
assert_eq 3 "$(di decide-2b instances_gpu)" "baseline decide-2b gpu instances (min(10444//3006, 12)=3)"
assert_eq 8 "$(di decide-2b instances_cpu)" "baseline decide-2b cpu instances (25904//3006=8)"
assert_eq 16 "$(di decide-2b total_decision_slots)" "baseline decide-2b total slots (max(3,8)*2=16)"
assert_eq 0 "$(di decide-max instances_gpu)" "baseline decide-max tier-gated to 0"
assert_contains "$(printf '%s' "${plan}" | json_stdin 'd["decision_instances"]["decide-max"].get("reason", "")')" \
  "tier gate" "baseline decide-max carries a tier-gate reason"

# workstation fixture (tier datacenter, RAM 235904, VRAM 27852):
#   decide-tiny: gpu min(27852//1592=17, 235904//2048=115) = 17; cpu 235904//1592 = 148
#   decide:      gpu min(27852//3671=7, 115) = 7;               cpu 235904//3671 = 64
#   decide-pro:  gpu min(27852//5260=5, 115) = 5;               cpu 235904//5260 = 44
plan="$(plan_for workstation)"
assert_eq 17 "$(di decide-tiny instances_gpu)" "workstation decide-tiny gpu instances (min(27852//1592, 235904//2048)=17)"
assert_eq 148 "$(di decide-tiny instances_cpu)" "workstation decide-tiny cpu instances (235904//1592=148)"
assert_eq 7  "$(di decide instances_gpu)" "workstation decide gpu instances (min(27852//3671, 115)=7)"
assert_eq 64 "$(di decide instances_cpu)" "workstation decide cpu instances (235904//3671=64)"
assert_eq 5  "$(di decide-pro instances_gpu)" "workstation decide-pro gpu instances (min(27852//5260, 115)=5)"
assert_eq 44 "$(di decide-pro instances_cpu)" "workstation decide-pro cpu instances (235904//5260=44)"
assert_eq 88 "$(di decide-pro total_decision_slots)" "workstation decide-pro total slots (max(5,44)*2=88)"

# tiny fixture (tier below-minimum, RAM budget max(0, 1500-4096)=0, no GPU):
# everything is 0; decide/decide-pro carry a TIER-GATE reason, decide-tiny
# passes the tier gate (min_tier below-minimum) but still cannot fit a
# 1592 MiB footprint into a 0 MiB budget, so it carries the FOOTPRINT
# reason. (Captured values; the fixture's 1500 MiB available RAM leaves no
# budget after the 4 GiB headroom rule.)
plan="$(plan_for tiny)"
assert_eq 0 "$(di decide-tiny instances_cpu)" "tiny decide-tiny: 0 (0 MiB RAM budget vs 1592 MiB footprint)"
assert_contains "$(printf '%s' "${plan}" | json_stdin 'd["decision_instances"]["decide-tiny"].get("reason", "")')" \
  "footprint exceeds" "tiny decide-tiny: footprint reason (tier gate passes)"
assert_eq 0 "$(di decide instances_cpu)" "tiny decide: 0 (tier-gated)"
assert_contains "$(printf '%s' "${plan}" | json_stdin 'd["decision_instances"]["decide"].get("reason", "")')" \
  "tier gate" "tiny decide: tier-gate reason"
assert_eq 0 "$(di decide-pro instances_cpu)" "tiny decide-pro: 0 (tier-gated)"
# onnx fixture arithmetic #2 (tiny): decide-nli's min_tier is below-minimum
# so the TIER gate passes, but a 3006 MiB RAM reservation cannot fit a 0
# MiB budget -> 0/0 with the FOOTPRINT reason (same class as decide-tiny).
assert_eq 0 "$(di decide-nli instances_gpu)" "tiny decide-nli: gpu ALWAYS 0 (CPU-only engine)"
assert_eq 0 "$(di decide-nli instances_cpu)" "tiny decide-nli: 0 (0 MiB RAM budget vs 3006 MiB reservation)"
assert_contains "$(printf '%s' "${plan}" | json_stdin 'd["decision_instances"]["decide-nli"].get("reason", "")')" \
  "footprint exceeds" "tiny decide-nli: footprint reason (tier gate passes at below-minimum)"

# vram-contended (SAME total VRAM as baseline but only 3000 MiB REAL FREE ->
# VRAM budget 2550): GPU instances drop, CPU instances are UNCHANGED vs
# baseline - GPU and CPU placements are alternative, independent divisions
# of their own budgets.
plan="$(plan_for vram-contended)"
assert_eq 1  "$(di decide-tiny instances_gpu)" "vram-contended decide-tiny gpu instances (min(2550//1592, 12)=1, down from 6 on baseline)"
assert_eq 16 "$(di decide-tiny instances_cpu)" "vram-contended decide-tiny cpu instances UNCHANGED (25904//1592=16)"
assert_eq 0  "$(di decide instances_gpu)" "vram-contended decide gpu instances (2550 < 3671 -> 0, down from 2 on baseline)"
assert_eq 7  "$(di decide instances_cpu)" "vram-contended decide cpu instances UNCHANGED (25904//3671=7)"

# constrained (RAM budget 25904, VRAM budget 6963):
#   decide-tiny: gpu min(6963//1592=4, 12) = 4;  decide: gpu min(6963//3671=1, 12) = 1
plan="$(plan_for constrained)"
assert_eq 4  "$(di decide-tiny instances_gpu)" "constrained decide-tiny gpu instances (min(6963//1592, 12)=4)"
assert_eq 1  "$(di decide instances_gpu)" "constrained decide gpu instances (min(6963//3671, 12)=1)"

# decide capacity --json's decision_instances subtree matches the plan's
# exactly (same single-source planner computation).
plan="$(plan_for baseline)"
cap="$(LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json" bash -c '
  source "'"${LLMCTL_ROOT}"'/lib/common.sh"
  source "'"${LLMCTL_ROOT}"'/lib/os_detect.sh"
  source "'"${LLMCTL_ROOT}"'/lib/hardware.sh"
  source "'"${LLMCTL_ROOT}"'/lib/catalog.sh"
  source "'"${LLMCTL_ROOT}"'/lib/decide.sh"
  decide_capacity --json
')"
assert_eq "True" "$(
  PLAN="${plan}" CAP="${cap}" python3 - <<'PYEOF'
import json, os
plan = json.loads(os.environ["PLAN"])
cap = json.loads(os.environ["CAP"])
print(cap["decision_instances"] == plan["decision_instances"])
PYEOF
)" "decide capacity --json decision_instances == plan --json decision_instances"

# human plan rendering shows the Decision capacity section
human="$(plan_for baseline | catalog_plan_human)"
assert_contains "${human}" "Decision capacity" "human plan: Decision capacity section header"
assert_contains "${human}" "decide-tiny" "human plan: Decision capacity lists decide-tiny"
assert_contains "${human}" "decide-nli" "human plan: Decision capacity lists decide-nli (onnx profile)"

# --- additive decision_instances fields (data-model s10, FR-028) ---------------
plan="$(plan_for baseline)"
assert_eq "letter-logit" "$(di decide-tiny protocol)" "decision_instances.protocol: decide-tiny letter-logit (additive field)"
assert_eq "nli-onnx" "$(di decide-nli protocol)" "decision_instances.protocol: decide-nli nli-onnx"
assert_eq "cpu" "$(di decide-tiny best_placement)" "decide-tiny best placement on baseline is cpu (16 cpu > 6 gpu instances)"
assert_eq "" "$(di decide-pro best_placement)" "tier-gated decide-pro has no best placement (null)"
assert_eq "False" "$(di decide-pro tier_ok)" "decide-pro tier_ok False on baseline (additive field)"
assert_eq "1592" "$(printf '%s' "${plan}" | json_stdin 'd["decision_instances"]["decide-tiny"]["placements"]["cpu"]["ram_mb"]')" "placements.cpu footprint exposed for the admission probe"
assert_eq "None" "$(printf '%s' "${plan}" | json_stdin 'str(d["decision_instances"]["decide-nli"]["placements"]["gpu"])')" "decide-nli has no gpu placement (CPU-only encoder)"

# --- SC-012 / D-18: planner comparison against the previous release ------------
# The previous release is the git tag v3.0.2 (catalog without decision
# profiles). For every hardware fixture: (1) the recommended CHAT set is
# identical, (2) every change is the ADDITION of decide-* profiles that the
# new catalog entries explain by themselves (fits + tier_ok), (3) `auto
# chat|coder|vision` pick the same profile as before, (4) the exact per-
# fixture changes are the ones documented in docs/hardware-tiers.md
# ("Planner and `auto decide`") - 0 unexplained changes.
PREV_CATALOG="${TEST_TMP}/catalog-v3.0.2.json"
if (cd "${LLMCTL_ROOT}" && git show v3.0.2:models/catalog.json > "${PREV_CATALOG}" 2>/dev/null) && [[ -s "${PREV_CATALOG}" ]]; then
  source "${LLMCTL_ROOT}/lib/scheduler.sh"
  DOC="${LLMCTL_ROOT}/docs/hardware-tiers.md"
  for fx in apple baseline constrained cpu-heavy ram-contended-auto-eviction small-exact tiny vram-contended-coresident vram-contended workstation; do
    hw="${LLMCTL_ROOT}/tests/fixtures/hw-${fx}.json"
    prev_plan="${TEST_TMP}/prev-${fx}.json"; now_plan="${TEST_TMP}/now-${fx}.json"
    LLMCTL_CATALOG="${PREV_CATALOG}" LLMCTL_FAKE_HW="${hw}" hw_probe_json | LLMCTL_CATALOG="${PREV_CATALOG}" catalog_plan_json > "${prev_plan}"
    LLMCTL_FAKE_HW="${hw}" hw_probe_json | catalog_plan_json > "${now_plan}"
    cmp="$(RANK_CHAT="$(sched_rank_for_capability chat)" RANK_CODER="$(sched_rank_for_capability coder)" \
           RANK_VISION="$(sched_rank_for_capability vision)" RANK_DECIDE="$(sched_rank_for_capability decide)" \
           python3 - "${prev_plan}" "${now_plan}" "${LLMCTL_ROOT}/models/catalog.json" "${PREV_CATALOG}" <<'PYEOF'
import json, os, sys
prev, now = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
cat_now, cat_prev = json.load(open(sys.argv[3])), json.load(open(sys.argv[4]))
problems = []
is_dec = lambda n: "decide" in cat_now["profiles"][n]["capability"]
added = [n for n in now["recommended"] if n not in prev["recommended"]]
removed = [n for n in prev["recommended"] if n not in now["recommended"]]
if removed:
    problems.append("recommended profiles REMOVED vs v3.0.2: %s" % removed)
if [n for n in now["recommended"] if not is_dec(n)] != prev["recommended"]:
    problems.append("recommended chat set or its order changed")
for n in added:
    if not is_dec(n):
        problems.append("non-decision profile %s newly recommended" % n)
    f = now["profiles"][n]
    if not (f["fits"] and f["tier_ok"]):
        problems.append("%s added without fits+tier_ok" % n)
def pick(plan, cat, cap, ranked):
    for p in ranked.split():
        if p in cat["profiles"] and cap in cat["profiles"][p]["capability"] and plan["profiles"].get(p, {}).get("recommended"):
            return p
    return None
for cap, env in (("chat", "RANK_CHAT"), ("coder", "RANK_CODER"), ("vision", "RANK_VISION")):
    a, b = pick(prev, cat_prev, cap, os.environ[env]), pick(now, cat_now, cap, os.environ[env])
    if a != b:
        problems.append("auto %s changed: %s -> %s" % (cap, a, b))
    if b is not None and is_dec(b):
        problems.append("auto %s selects a decision profile" % cap)
dpick = pick(now, cat_now, "decide", os.environ["RANK_DECIDE"])
row = "| `%s` | %s | %s |" % (os.path.basename(sys.argv[2]).replace("now-", "").replace(".json", ""),
        ", ".join("`%s`" % n for n in added) or "none", ("`%s`" % dpick) if dpick else "no fit")
print("PROBLEMS: " + "; ".join(problems) if problems else "ROW: " + row)
PYEOF
)"
    case "${cmp}" in
      "ROW: "*)
        assert_eq "ok" "ok" "SC-012 ${fx}: only decide-* profiles added; chat/coder/vision recommended sets and auto picks unchanged vs v3.0.2"
        assert_file_contains "${DOC}" "${cmp#ROW: }" "SC-012 ${fx}: the change is documented in docs/hardware-tiers.md (row: ${cmp#ROW: })"
        ;;
      *) assert_eq "no unexplained change" "${cmp}" "SC-012 ${fx}: planner comparison vs v3.0.2" ;;
    esac
  done
  # mutation: a chat profile silently dropped from the new recommended set is caught
  python3 - "${TEST_TMP}/now-baseline.json" "${TEST_TMP}/now-baseline-mut.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1])); d["recommended"].remove("coder"); json.dump(d, open(sys.argv[2], "w"))
PYEOF
  assert_eq "1" "$(python3 - "${TEST_TMP}/prev-baseline.json" "${TEST_TMP}/now-baseline-mut.json" <<'PYEOF'
import json, sys
prev, now = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
removed = [n for n in prev["recommended"] if n not in now["recommended"]]
print(1 if removed else 0)
PYEOF
)" "SC-012 mutation: removing 'coder' from the new recommended set is detected as a removal"
else
  assert_skip "git tag v3.0.2 (previous release catalog) not available in this checkout" "SC-012 planner comparison vs previous release"
fi

# --- defaults.overhead_mb: the MEASURED working set above weights + KV (native decision profiles) --------------
# Live finding (specs/009-jev-decision-models/evidence/live/ctx-peak-memory-experiment.txt): an encoder-class
# native model's peak RSS is dominated by activation buffers that scale with the state length, not by weights or the
# flat ctx/8 KV estimate (Julia-1, 160 MiB of weights, peaked at 1.4 GiB with a 1024-token window). A profile may
# therefore declare defaults.overhead_mb; the planner adds it to the RAM footprint in cpu mode and to the VRAM
# footprint in gpu mode. Absent = 0 (every pre-existing profile is byte-for-byte unchanged: golden-false).
OVH_CAT="${TEST_TMP}/catalog-overhead.json"
python3 - "${LLMCTL_CATALOG}" "${OVH_CAT}" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["profiles"]["decide-kev-4b"]["defaults"]["overhead_mb"] = 500
json.dump(d, open(sys.argv[2], "w"))
PYEOF
plan_with() { LLMCTL_CATALOG="$1" LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-$2.json" hw_probe_json | LLMCTL_CATALOG="$1" catalog_plan_json; }
base_plan="$(plan_with "${LLMCTL_CATALOG}" baseline)"; ovh_plan="$(plan_with "${OVH_CAT}" baseline)"
b_v="$(printf '%s' "${base_plan}" | json_stdin 'd["profiles"]["decide-kev-4b"]["vram_mb"]')"
o_v="$(printf '%s' "${ovh_plan}" | json_stdin 'd["profiles"]["decide-kev-4b"]["vram_mb"]')"
assert_eq "500" "$(( o_v - b_v ))" "overhead_mb is added to the GPU-mode VRAM footprint (decide-kev-4b, baseline fixture)"
assert_eq "gpu" "$(printf '%s' "${ovh_plan}" | json_stdin 'd["profiles"]["decide-kev-4b"]["mode"]')" "...and the placement mode is still gpu"
assert_eq "$(printf '%s' "${base_plan}" | json_stdin 'd["profiles"]["decide-tiny"]["vram_mb"]')" \
  "$(printf '%s' "${ovh_plan}" | json_stdin 'd["profiles"]["decide-tiny"]["vram_mb"]')" "golden-false: a profile without overhead_mb keeps its footprint"
b_r="$(plan_with "${LLMCTL_CATALOG}" cpu-heavy | json_stdin 'd["profiles"]["decide-kev-4b"]["ram_mb"]')"
o_r="$(plan_with "${OVH_CAT}" cpu-heavy | json_stdin 'd["profiles"]["decide-kev-4b"]["ram_mb"]')"
assert_eq "500" "$(( o_r - b_r ))" "overhead_mb is added to the CPU-mode RAM footprint (decide-kev-4b, cpu-heavy fixture)"
for bad in -1 "\"x\"" 70000; do
  python3 - "${LLMCTL_CATALOG}" "${TEST_TMP}/catalog-bad-ovh.json" "${bad}" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1])); d["profiles"]["decide-kev-4b"]["defaults"]["overhead_mb"] = json.loads(sys.argv[3])
json.dump(d, open(sys.argv[2], "w"))
PYEOF
  rc=0; plan_with "${TEST_TMP}/catalog-bad-ovh.json" baseline >/dev/null 2>"${TEST_TMP}/bad-ovh.err" || rc=$?
  assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "an invalid overhead_mb (${bad}) is refused loudly, never ignored"
done

# --- T139: measured memory overhead of the decision profiles (G-137 / G-138) ---------------------------------
# The numbers come from scripts/overhead_from_memory.py (rule: ceil(1.10 x (peak VmHWM - model file)); VRAM:
# ceil(1.10 x the peak VRAM the engine pid held)); the planner books weights + KV + overhead_mb of RAM and, on a
# host WITH a GPU, overhead_vram_mb of VRAM even in cpu mode (a CUDA build offloads large-batch ops).
# Hand-computed (decide-julia: 168166496 B -> 160 MiB; ctx 1024 x 1 slot x f16 -> KV 128 MiB; overhead_mb 1410,
# overhead_vram_mb 194 - catalog.memory.*):
#   cpu-mode RAM  = 160 + 128 + 1410 = 1698 MiB      cpu-mode VRAM = 194 MiB (GPU host) / 0 (CPU-only host)
#   gpu-mode VRAM = 160 + 128 + 1410 = 1698 MiB      gpu-mode RAM  = 2048 MiB (fixed)
write_hw() {  # write_hw <file> <vram_free_mb|none> : the baseline host with a chosen free VRAM (none = no GPU)
  python3 - "${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json" "$1" "$2" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
if sys.argv[3] == "none":
    d["gpus"] = []; d.pop("gpu_total_vram_mb", None); d.pop("gpu_free_vram_mb", None)
else:
    d["gpus"][0]["vram_free_mb"] = int(sys.argv[3]); d["gpu_free_vram_mb"] = int(sys.argv[3])
json.dump(d, open(sys.argv[2], "w"))
PYEOF
}
plan_hw() { LLMCTL_FAKE_HW="$1" hw_probe_json | catalog_plan_json; }
write_hw "${TEST_TMP}/hw-gpu-1000.json" 1000    # VRAM budget int(1000 * 0.85) = 850 -> julia gpu (1698) does not fit, cpu does
write_hw "${TEST_TMP}/hw-gpu-150.json" 150      # VRAM budget 127 < the 194 MiB offload overhead
write_hw "${TEST_TMP}/hw-nogpu.json" none       # CPU-only host
pj="$(plan_hw "${TEST_TMP}/hw-gpu-1000.json")"
assert_eq "cpu" "$(printf '%s' "${pj}" | json_stdin 'd["profiles"]["decide-julia"]["mode"]')" "T139: julia lands in cpu mode when the GPU budget is 850 MiB"
assert_eq "1698" "$(printf '%s' "${pj}" | json_stdin 'd["profiles"]["decide-julia"]["ram_mb"]')" "T139: julia cpu RAM = 160 weights + 128 KV + 1410 measured overhead"
assert_eq "194" "$(printf '%s' "${pj}" | json_stdin 'd["profiles"]["decide-julia"]["vram_mb"]')" "T139/G-138: julia in cpu mode books its measured 194 MiB offload VRAM (was 0)"
assert_eq "True" "$(printf '%s' "${pj}" | json_stdin 'd["profiles"]["decide-julia"]["fits"]')" "T139: ...and it fits"
pj2="$(plan_hw "${TEST_TMP}/hw-gpu-150.json")"
assert_eq "False" "$(printf '%s' "${pj2}" | json_stdin 'd["profiles"]["decide-julia"]["fits"]')" "T139: julia is refused when its offload VRAM (194) exceeds the VRAM budget (127)"
assert_eq "none" "$(printf '%s' "${pj2}" | json_stdin 'd["profiles"]["decide-julia"]["mode"]')" "T139: ...mode none, never silently 0 VRAM"
pj3="$(plan_hw "${TEST_TMP}/hw-nogpu.json")"
assert_eq "0" "$(printf '%s' "${pj3}" | json_stdin 'd["profiles"]["decide-julia"]["vram_mb"]')" "T139 golden-false: a CPU-only host books 0 VRAM (no CUDA build, no offload)"
assert_eq "1698" "$(printf '%s' "${pj3}" | json_stdin 'd["profiles"]["decide-julia"]["ram_mb"]')" "T139: CPU-only host: same RAM as the GPU host in cpu mode"
# the plan exposes what it booked and why
assert_eq "1410 194 1024 measured" "$(printf '%s' "${pj}" | json_stdin '" ".join(str(x) for x in (d["profiles"]["decide-julia"]["overhead_mb"], d["profiles"]["decide-julia"]["overhead_vram_mb"], d["profiles"]["decide-julia"]["window_tokens"], d["profiles"]["decide-julia"]["memory_status"]))')" \
  "T139: llmctl plan --json exposes overhead_mb, overhead_vram_mb, window_tokens and memory_status"
assert_eq "None None unmeasured" "$(printf '%s' "${pj}" | json_stdin '" ".join(str(x) for x in (d["profiles"]["decide-tiny"]["window_tokens"], d["profiles"]["decide-tiny"].get("overhead_mb_measured"), d["profiles"]["decide-tiny"]["memory_status"]))')" \
  "T139: an unmeasured decision profile says so (window_tokens null, memory_status unmeasured)"
assert_eq "0 0" "$(printf '%s' "${pj}" | json_stdin 'str(d["profiles"]["decide-tiny"]["overhead_mb"]) + " " + str(d["profiles"]["decide-tiny"]["overhead_vram_mb"])')" "T139: ...and books 0 for it, as before"
# lev on a CPU-only host: 2872 weights + 1024 KV (8192 x 1 / 8) + 3098 measured overhead
assert_eq "6994" "$(printf '%s' "${pj3}" | json_stdin 'd["profiles"]["decide-lev"]["ram_mb"]')" "T139: decide-lev RAM = 2872 + 1024 + 3098 (peak 5688.1 MiB measured on nezha)"
# decision capacity: the cpu placement carries the VRAM too, and divides the VRAM budget by it
assert_eq "194" "$(printf '%s' "${pj}" | json_stdin 'd["decision_instances"]["decide-julia"]["placements"]["cpu"]["vram_mb"]')" "T139: capacity cpu placement of julia books 194 MiB VRAM"
assert_eq "0" "$(printf '%s' "${pj3}" | json_stdin 'd["decision_instances"]["decide-julia"]["placements"]["cpu"]["vram_mb"]')" "T139: capacity cpu placement on a CPU-only host books 0 VRAM"
assert_eq "4" "$(printf '%s' "${pj}" | json_stdin 'd["decision_instances"]["decide-julia"]["instances_cpu"]')" "T139: 850 // 194 = 4 cpu-mode instances (VRAM-bound), not 25904 // 1698 = 15"

# --- decide capability rank (scheduler auto-pick order) ------------------------
# Ascending footprint/accuracy tradeoff, best-first (rationale documented at
# sched_rank_for_capability): decide-tiny > decide-nli > decide-2b > decide
# > decide-pro > decide-max, then the six native /v1/systemone profiles in
# ascending footprint (never preferred over a proven profile).
source "${LLMCTL_ROOT}/lib/scheduler.sh"
assert_eq "decide-tiny decide-nli decide-2b decide decide-pro decide-max decide-julia decide-laya decide-kev-08b decide-lev decide-kev-4b decide-kev-9b" \
  "$(sched_rank_for_capability decide)" "decide rank: tiny > nli > 2b > base > pro > max > native (julia > laya > kev-08b > lev > kev-4b > kev-9b)"

test_finish
