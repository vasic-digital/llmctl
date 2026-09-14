#!/usr/bin/env bash
# test_cli.sh - bin/llmctl dispatch: help, version, exit codes, fake-hw paths.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
LLMCTL="${LLMCTL_ROOT}/bin/llmctl"

# help / version
captured="$("${LLMCTL}" help)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "help exit code"
assert_contains "${captured}" "USAGE" "help shows usage"
captured="$("${LLMCTL}" version)" && rc=0 || rc=$?
assert_eq 0 "${rc}" "version exit code"
assert_contains "${captured}" "llmctl 0." "version string"

# unknown command -> exit 2
captured="$("${LLMCTL}" frobnicate 2>&1)" && rc=0 || rc=$?
assert_eq 2 "${rc}" "unknown command exit code"
assert_contains "${captured}" "unknown command: frobnicate" "unknown command message"

# missing-arg errors -> exit 1 with usage hint
captured="$("${LLMCTL}" switch 2>&1)" && rc=0 || rc=$?
assert_eq 1 "${rc}" "switch without profile exits 1"
captured="$("${LLMCTL}" models download 2>&1)" && rc=0 || rc=$?
assert_eq 1 "${rc}" "models download without profile exits 1"
captured="$("${LLMCTL}" models frob 2>&1)" && rc=0 || rc=$?
assert_eq 1 "${rc}" "unknown models subcommand exits 1"

# models list renders all profiles
captured="$("${LLMCTL}" models list)"
for p in fast coder vision vision-pro moe-fast small ws-dense-32b ws-moe-30b colibri-glm colibri-qwen36; do
  assert_contains "${captured}" "${p}" "models list contains ${p}"
done

# hw --json with fixture -> valid JSON, fixture contents
captured="$("${LLMCTL}" hw --json)"
assert_eq "AMD Ryzen 7 2700X Eight-Core Processor" \
  "$(printf '%s' "${captured}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["cpu"]["model"])')" \
  "hw --json returns fixture"
captured="$("${LLMCTL}" hw)"
assert_contains "${captured}" "NVIDIA GeForce RTX 3060" "hw human output shows GPU"

# plan end-to-end via CLI
captured="$("${LLMCTL}" plan)"
assert_contains "${captured}" "Host tier:   baseline" "plan tier line"
assert_contains "${captured}" "group 1: fast, coder, vision" "plan co-residency group 1"

# unknown profile -> clear error, exit 1
captured="$(LLMCTL_DRY_RUN=1 "${LLMCTL}" start nosuchprofile 2>&1)" && rc=0 || rc=$?
assert_eq 1 "${rc}" "start unknown profile exits 1"
assert_contains "${captured}" "unknown profile: nosuchprofile" "unknown profile message"

test_finish
