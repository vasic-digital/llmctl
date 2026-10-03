#!/usr/bin/env bash
# test_ctx_kvtype_override.sh - per-profile context-size and KV-cache-type
# override mechanisms (LLMCTL_CTX_<PROFILE>, LLMCTL_KVTYPE_<PROFILE>),
# exercised for real against the actual catalog.
#
# Root cause this covers (2026-10-03, real repro on real hardware, not
# guessed): models/catalog.json's "ctx" default had NO override anywhere
# in the codebase (grep for LLMCTL_CTX found nothing pre-fix) - every
# profile was permanently stuck at its catalog default context size
# regardless of what a specific host could actually support. Confirmed
# live: llmctl-small's model (Llama-3.2-3B) served a REAL 75000-token
# context with q4_0 KV-cache quantization on a 12GB consumer GPU, far
# past its 8192-token catalog default - but there was no way to configure
# either the larger context OR the quantization without editing the
# shared, portable catalog file. This mirrors test_port_override.sh's
# exact convention for the identical class of fix.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/os_detect.sh"
source "${LLMCTL_ROOT}/lib/hardware.sh"
source "${LLMCTL_ROOT}/lib/catalog.sh"

# --- 1. name-derivation helpers ----------------------------------------------
assert_eq "LLMCTL_CTX_SMALL" "$(catalog_ctx_override_env_name small)" \
  "ctx override env-var name for a simple profile"
assert_eq "LLMCTL_CTX_WS_DENSE_32B" "$(catalog_ctx_override_env_name ws-dense-32b)" \
  "ctx override env-var name for a hyphenated profile"
assert_eq "LLMCTL_KVTYPE_SMALL" "$(catalog_kv_type_override_env_name small)" \
  "kv-type override env-var name for a simple profile"
assert_eq "LLMCTL_KVTYPE_WS_DENSE_32B" "$(catalog_kv_type_override_env_name ws-dense-32b)" \
  "kv-type override env-var name for a hyphenated profile"

plan_for() {
  LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json" hw_probe_json | catalog_plan_json
}

# --- 2. no override: catalog defaults, zero behavior change ------------------
# Uses 'fast' (untouched by this feature's own catalog-default changes to
# small/vision) rather than 'small', so this regression guard proves
# "no override -> whatever the catalog currently says" generically, and
# does not go stale the next time small/vision's own defaults are tuned.
plan="$(plan_for)"
assert_eq "8192" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["fast"]["ctx"]')" \
  "no override: fast's ctx is still the catalog default (regression guard)"
assert_eq "f16" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["fast"].get("kv_cache_type")')" \
  "no override: fast's kv_cache_type defaults to f16 (zero behavior change for every profile that doesn't opt in)"

# --- 3. LLMCTL_CTX_<PROFILE> plumbs into the FUNCTIONAL path (ctx) ----------
plan_ctx="$(LLMCTL_CTX_SMALL=65536 plan_for)"
assert_eq "65536" "$(printf '%s' "${plan_ctx}" | json_stdin 'd["profiles"]["small"]["ctx"]')" \
  "LLMCTL_CTX_SMALL=65536 plumbs into catalog_plan_json's small ctx - the actual launch --ctx-size"
assert_eq "8192" "$(printf '%s' "${plan_ctx}" | json_stdin 'd["profiles"]["fast"]["ctx"]')" \
  "ctx override is scoped to 'small' only, 'fast' keeps its catalog ctx"

# --- 4. an invalid (non-integer) ctx override fails loudly -------------------
rc=0
LLMCTL_CTX_SMALL=not-a-ctx plan_for >/dev/null 2>/tmp/llmctl_ctx_override_test_stderr.$$ || rc=$?
assert_eq 1 "${rc}" "an invalid LLMCTL_CTX_SMALL value fails the plan instead of silently using garbage"
assert_file_contains "/tmp/llmctl_ctx_override_test_stderr.$$" "not a valid context size" \
  "invalid ctx override reports a clear error naming the bad value"
rm -f "/tmp/llmctl_ctx_override_test_stderr.$$"

# --- 4b. a zero or negative ctx override fails loudly (not silently accepted) -
# Round-2 independent review (2026-10-03): a plain int() parse let 0/negative
# through, and 0 has a DANGEROUS, different meaning to llama-server's own
# --ctx-size (native/trained context, which kv_mb() would estimate as ~0 MiB
# and falsely report `fits: true` for a config that genuinely OOMs).
rc=0
LLMCTL_CTX_SMALL=0 plan_for >/dev/null 2>/tmp/llmctl_ctx_override_test_stderr_zero.$$ || rc=$?
assert_eq 1 "${rc}" "LLMCTL_CTX_SMALL=0 fails the plan instead of silently using it (0 means something dangerously different to llama-server, not 'use the catalog default')"
assert_file_contains "/tmp/llmctl_ctx_override_test_stderr_zero.$$" "must be >=" \
  "zero ctx override reports a clear error naming the MIN_CTX floor"
rm -f "/tmp/llmctl_ctx_override_test_stderr_zero.$$"

rc=0
LLMCTL_CTX_SMALL=-5 plan_for >/dev/null 2>/tmp/llmctl_ctx_override_test_stderr_neg.$$ || rc=$?
assert_eq 1 "${rc}" "LLMCTL_CTX_SMALL=-5 (negative) fails the plan instead of silently using it"
assert_file_contains "/tmp/llmctl_ctx_override_test_stderr_neg.$$" "must be >=" \
  "negative ctx override reports a clear error naming the MIN_CTX floor"
rm -f "/tmp/llmctl_ctx_override_test_stderr_neg.$$"

# --- 5. LLMCTL_KVTYPE_<PROFILE> plumbs into the FUNCTIONAL path -------------
plan_kv="$(LLMCTL_KVTYPE_SMALL=q4_0 plan_for)"
assert_eq "q4_0" "$(printf '%s' "${plan_kv}" | json_stdin 'd["profiles"]["small"].get("kv_cache_type")')" \
  "LLMCTL_KVTYPE_SMALL=q4_0 plumbs into catalog_plan_json's small kv_cache_type"
assert_eq "f16" "$(printf '%s' "${plan_kv}" | json_stdin 'd["profiles"]["fast"].get("kv_cache_type")')" \
  "kv-type override is scoped to 'small' only, 'fast' keeps f16"

# --- 6. kv_cache_type genuinely changes the VRAM footprint (not just a label) -
# Pins LLMCTL_KVTYPE_SMALL=f16 explicitly for the baseline: small's own
# catalog default is q4_0 (see models/catalog.json), so without the pin
# this "f16" baseline would silently inherit q4_0 and the two sides of
# this comparison would no longer differ.
plan_f16_ctx="$(LLMCTL_CTX_SMALL=8192 LLMCTL_KVTYPE_SMALL=f16 plan_for)"
vram_f16="$(printf '%s' "${plan_f16_ctx}" | json_stdin 'd["profiles"]["small"]["vram_mb"]')"
plan_q4="$(LLMCTL_CTX_SMALL=8192 LLMCTL_KVTYPE_SMALL=q4_0 plan_for)"
vram_q4="$(printf '%s' "${plan_q4}" | json_stdin 'd["profiles"]["small"]["vram_mb"]')"
[[ "${vram_q4}" -lt "${vram_f16}" ]] && ok=1 || ok=0
assert_eq 1 "${ok}" "q4_0 KV quantization genuinely reduces the estimated vram_mb vs f16 at the same ctx (got f16=${vram_f16} q4_0=${vram_q4})"

# --- 7. an invalid kv_cache_type value fails loudly, naming the allowed set --
rc=0
LLMCTL_KVTYPE_SMALL=bogus plan_for >/dev/null 2>/tmp/llmctl_kvtype_override_test_stderr.$$ || rc=$?
assert_eq 1 "${rc}" "an invalid LLMCTL_KVTYPE_SMALL value fails the plan instead of silently passing garbage to llama-server"
assert_file_contains "/tmp/llmctl_kvtype_override_test_stderr.$$" "q4_0" \
  "invalid kv-type override's error names the real allowed set (not a vague message)"
rm -f "/tmp/llmctl_kvtype_override_test_stderr.$$"

# --- 8. kv_mb()'s fits-flip: a profile wrongly marked unfit under a naive ---
# f16-only estimate is correctly marked fits:true once its real q4_0 cost is
# accounted for. Uses the existing vram-contended fixture (test_planner.sh's
# own fixture, 12288 MiB total / 3000 MiB real free) against a context large
# enough that f16 would NOT fit but q4_0 (≈1/4 the per-token cost) would.
plan_contended_f16() {
  LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-vram-contended.json" hw_probe_json | catalog_plan_json
}
# vram_budget on that fixture is 3000*0.85=2550 MiB; small's weights are
# ~1926 MiB per the real catalog entry. At f16 (1/8 MiB/token), ctx=12000
# needs 1500 MiB KV: 1926+1500=3426 > 2550, so it genuinely does NOT fit
# on GPU and falls through to "cpu" mode instead (still fits=True overall
# via that fallback, which is correct behavior - the REAL boundary this
# finding is about is whether it fits on GPU specifically, so the
# assertion checks "mode", not the overall "fits"). At q4_0, the SAME
# ctx needs only 375 MiB KV: 1926+375=2301 <= 2550 - genuinely fits on GPU.
# small's own catalog default for kv_cache_type is q4_0 (tuned separately,
# see models/catalog.json), so this f16 scenario must pin
# LLMCTL_KVTYPE_SMALL=f16 explicitly - otherwise it would silently inherit
# the catalog's q4_0 default and no longer exercise the f16 boundary this
# assertion is about.
mode_f16="$(LLMCTL_CTX_SMALL=12000 LLMCTL_KVTYPE_SMALL=f16 plan_contended_f16 | json_stdin 'd["profiles"]["small"]["mode"]')"
assert_eq "cpu" "${mode_f16}" \
  "sanity: ctx=12000 at f16 genuinely does NOT fit on GPU in the contended fixture's real headroom - falls through to cpu mode (confirms the test fixture actually exercises the boundary, not a vacuous pass)"
mode_q4="$(LLMCTL_CTX_SMALL=12000 LLMCTL_KVTYPE_SMALL=q4_0 plan_contended_f16 | json_stdin 'd["profiles"]["small"]["mode"]')"
assert_eq "gpu" "${mode_q4}" \
  "the SAME ctx=12000, with q4_0 KV quantization accounted for, now correctly fits on GPU (mode=gpu, not the cpu fallback) - proving kv_mb() is genuinely type-aware in the admission-control path, not just cosmetically labeled"

# --- 9. full-stack: `llmctl plan --json` via the real CLI entrypoint --------
LLMCTL="${LLMCTL_ROOT}/bin/llmctl"
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
out="$("${LLMCTL}" plan --json)"
assert_eq "8192" "$(printf '%s' "${out}" | json_stdin 'd["profiles"]["fast"]["ctx"]')" \
  "llmctl plan --json without overrides still shows the catalog default (regression guard, using 'fast' - untouched by this feature's own catalog tuning)"
out_overridden="$(LLMCTL_CTX_SMALL=65536 LLMCTL_KVTYPE_SMALL=q4_0 "${LLMCTL}" plan --json)"
assert_eq "65536" "$(printf '%s' "${out_overridden}" | json_stdin 'd["profiles"]["small"]["ctx"]')" \
  "llmctl plan --json honors LLMCTL_CTX_SMALL end-to-end through the real CLI entrypoint"
assert_eq "q4_0" "$(printf '%s' "${out_overridden}" | json_stdin 'd["profiles"]["small"].get("kv_cache_type")')" \
  "llmctl plan --json honors LLMCTL_KVTYPE_SMALL end-to-end through the real CLI entrypoint"

# --- 10. the REAL launch command genuinely carries --cache-type-k/-v -------
# Finding 2 (round-2 independent review, 2026-10-03): sections 1-9 above all
# test catalog_plan_json's kv_cache_type *decision*, but nothing previously
# asserted that the decision actually reaches the real llama-server command
# line lib/scheduler.sh's sched_build_launch constructs (SCHED_ARGS - the
# same array svc_write_env persists into the real per-profile .env file
# systemd/launchd actually execute, and scheduler.sh:599/:712's real call
# sites). A planner that decided correctly but was never wired to the real
# launch path would still pass every test above.
source "${LLMCTL_ROOT}/lib/scheduler.sh"
export LLMCTL_DRY_RUN=1

sched_build_launch small gpu 18099 8192 99 1 auto f16
args_f16=" ${SCHED_ARGS[*]} "
if [[ "${args_f16}" == *" --cache-type-k "* || "${args_f16}" == *" --cache-type-v "* ]]; then
  printf '  FAIL: %s\n    f16 (llama-servers own default) must NOT add --cache-type-k/-v to the real launch command, but it did: %s\n' \
    "f16 kv_type omits --cache-type-k/-v from the real launch command" "${args_f16}" >&2
  TEST_FAILS=$((TEST_FAILS+1))
else
  printf '  ok: %s\n' "f16 kv_type omits --cache-type-k/-v from the real launch command (byte-for-byte unchanged for every profile that does not opt in)"
fi

sched_build_launch small gpu 18099 8192 99 1 auto q4_0
args_q4="${SCHED_ARGS[*]}"
assert_contains "${args_q4}" "--cache-type-k q4_0" \
  "q4_0 kv_type adds --cache-type-k q4_0 to the real launch command sched_build_launch constructs"
assert_contains "${args_q4}" "--cache-type-v q4_0" \
  "q4_0 kv_type adds --cache-type-v q4_0 to the real launch command sched_build_launch constructs"

test_finish
