#!/usr/bin/env bash
# test_port_override.sh - per-profile port override mechanism
# (LLMCTL_PORT_<PROFILE>), exercised for real against the actual catalog.
#
# Root cause this covers: models/catalog.json's "port" field is a fixed,
# host-independent value with no override anywhere in the codebase (grep
# for PORT_OVERRIDE/LLMCTL_PORT found nothing pre-fix), so a host where a
# catalog profile's default port collides with an unrelated already-running
# process (observed on this host: port 8080, catalog profile "fast", taken
# by a sibling project's process) could never start that profile as a
# persistent service without either editing the shared, portable catalog
# file or patching code. LLMCTL_PORT_<PROFILE> (same ${VAR:-default}
# opt-in-env-var convention as LLMCTL_LLAMA_SERVER / LLMCTL_COLI_BIN) fixes
# that at the two places a profile's port is actually resolved:
#   1. catalog_port()      - the display-only getter (models list)
#   2. catalog_plan_json() - the FUNCTIONAL path every real launch
#                            (start/enable/switch/auto, via
#                            sched_build_launch's --port) resolves its
#                            port through.
# Both are exercised here; a fix touching only #1 would look complete but
# never change what the scheduler actually binds to.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/os_detect.sh"
source "${LLMCTL_ROOT}/lib/hardware.sh"
source "${LLMCTL_ROOT}/lib/catalog.sh"

# --- 1. name-derivation helper -----------------------------------------------
assert_eq "LLMCTL_PORT_FAST" "$(catalog_port_override_env_name fast)" \
  "override env-var name for a simple profile"
assert_eq "LLMCTL_PORT_WS_DENSE_32B" "$(catalog_port_override_env_name ws-dense-32b)" \
  "override env-var name for a hyphenated profile (hyphens -> underscores, uppercased)"
assert_eq "LLMCTL_PORT_COLIBRI_GLM" "$(catalog_port_override_env_name colibri-glm)" \
  "override env-var name for another hyphenated profile"

# --- 2. catalog_port(): no override -> catalog's fixed value -----------------
assert_eq "8080" "$(catalog_port fast)" "catalog_port fast (no override) is the catalog default"

# --- 3. catalog_port(): override takes effect for JUST that profile ----------
out="$(LLMCTL_PORT_FAST=18080 catalog_port fast)"
assert_eq "18080" "${out}" "catalog_port fast honors LLMCTL_PORT_FAST"
out="$(LLMCTL_PORT_FAST=18080 catalog_port small)"
assert_eq "8085" "${out}" "LLMCTL_PORT_FAST does not leak into an unrelated profile (small unchanged)"

# --- 4. override is still profile-validated (no silent bypass) ---------------
# die() calls exit(1) directly, so the call MUST run inside a command
# substitution subshell here - calling it bare in this process would abort
# this entire test script, not just the one assertion.
rc=0
out="$(LLMCTL_PORT_FAST=18080 catalog_port does-not-exist 2>&1)" || rc=$?
assert_eq 1 "${rc}" "an override for an unknown profile still dies (die() exits 1), never silently returns the override"
assert_contains "${out}" "unknown profile: does-not-exist" "die() message is the same as the no-override unknown-profile path"

# --- 5. the FUNCTIONAL path: catalog_plan_json (what start/enable/switch use) -
plan_for() {
  LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json" hw_probe_json | catalog_plan_json
}

plan="$(plan_for)"
assert_eq "8080" "$(printf '%s' "${plan}" | json_stdin 'd["profiles"]["fast"]["port"]')" \
  "no override: plan's fast port is still the catalog default (regression guard)"

plan_overridden="$(LLMCTL_PORT_FAST=18080 plan_for)"
assert_eq "18080" "$(printf '%s' "${plan_overridden}" | json_stdin 'd["profiles"]["fast"]["port"]')" \
  "LLMCTL_PORT_FAST=18080 plumbs into catalog_plan_json's fast port - the actual launch port"
assert_eq "8085" "$(printf '%s' "${plan_overridden}" | json_stdin 'd["profiles"]["small"]["port"]')" \
  "plan: override is scoped to 'fast' only, 'small' keeps its catalog port"
assert_eq "8081" "$(printf '%s' "${plan_overridden}" | json_stdin 'd["profiles"]["coder"]["port"]')" \
  "plan: override is scoped to 'fast' only, 'coder' keeps its catalog port"

# A hyphenated profile name overrides correctly too (present in every plan
# regardless of tier_ok, so the baseline fixture is sufficient here).
plan_ws="$(LLMCTL_PORT_WS_DENSE_32B=19999 plan_for)"
assert_eq "19999" "$(printf '%s' "${plan_ws}" | json_stdin 'd["profiles"]["ws-dense-32b"]["port"]')" \
  "hyphenated profile name (ws-dense-32b) override plumbs through catalog_plan_json"

# --- 6. an invalid (non-integer) override fails loudly, never silently -------
rc=0
LLMCTL_PORT_FAST=not-a-port plan_for >/dev/null 2>/tmp/llmctl_port_override_test_stderr.$$ || rc=$?
assert_eq 1 "${rc}" "an invalid LLMCTL_PORT_FAST value fails the plan instead of silently using garbage"
assert_file_contains "/tmp/llmctl_port_override_test_stderr.$$" "not a valid port number" \
  "invalid override reports a clear error naming the bad value"
rm -f "/tmp/llmctl_port_override_test_stderr.$$"

# --- 7. full-stack: `llmctl models list` (display) and `llmctl plan --json` --
# (functional) both reflect the override end-to-end through the real CLI
# entrypoint, not just the sourced library functions above.
LLMCTL="${LLMCTL_ROOT}/bin/llmctl"
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"

out="$(LLMCTL_PORT_FAST=18080 "${LLMCTL}" models list)"
# Built with the exact same printf format cmd_models_list uses, so this
# assertion can never drift from that format string's real column widths.
expect_row_prefix="$(printf '%-16s %-6s' "fast" "18080")"
assert_contains "${out}" "${expect_row_prefix}" "llmctl models list shows the overridden port for fast"

out="$("${LLMCTL}" plan --json)"
assert_eq "8080" "$(printf '%s' "${out}" | json_stdin 'd["profiles"]["fast"]["port"]')" \
  "llmctl plan --json without the override still shows the catalog default (regression guard)"

out="$(LLMCTL_PORT_FAST=18080 "${LLMCTL}" plan --json)"
assert_eq "18080" "$(printf '%s' "${out}" | json_stdin 'd["profiles"]["fast"]["port"]')" \
  "llmctl plan --json with LLMCTL_PORT_FAST=18080 shows the overridden port - this is the exact value 'llmctl start/enable fast' would bind to"

test_finish
