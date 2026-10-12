#!/usr/bin/env bash
# test_hostsafety_oomd_doc.sh - RED-first (fix/bounded-restart-and-pressure-gates).
# Root cause (1): a systemd-oomd VENDOR rule on user@.service (ManagedOOMMemoryPressure=kill, 50% for 20s) killed 259
# units (incl. llmctl-llama@vision and podman healthcheck units), yet docs/host-safety.md (~:29 and ~:235) says oomd is
# "not enabled for these slices". Contract: the doc must acknowledge the user@.service oomd vendor rule and must no
# longer claim oomd is not enabled for these slices without that qualification.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
DOC="${LLMCTL_ROOT}/docs/host-safety.md"
body="$(cat "${DOC}")"
lc="${body,,}"
has_ack=0
if [[ "${lc}" == *"user@.service"* && "${lc}" == *"managedoom"* && "${lc}" == *"vendor"* ]]; then has_ack=1; fi
if [[ "${has_ack}" == 1 ]]; then echo "  ok: host-safety.md acknowledges the user@.service oomd vendor rule (ManagedOOM*)"
else printf '  FAIL: docs/host-safety.md does not mention the user@.service oomd vendor rule (needs user@.service + ManagedOOM + vendor)\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
if grep -qiE 'oomd[^.]*(is )?not enabled for these slices|not enabled for these slices on purpose' "${DOC}" && [[ "${lc}" != *"user@.service"* ]]; then
  printf '  FAIL: docs/host-safety.md still states oomd is not enabled for these slices (line %s) with no user@.service caveat\n' "$(grep -niE 'not enabled for these slices' "${DOC}" | head -1 | cut -d: -f1)" >&2; TEST_FAILS=$((TEST_FAILS+1))
else echo "  ok: no unqualified 'oomd not enabled for these slices' claim"; fi
# negative control: the same predicate rejects today's two sentences verbatim
ctl="systemd-oomd active but no ManagedOOMMemoryPressure ... deliberately not enabled. systemd-oomd is not enabled for these slices on purpose"
c="${ctl,,}"; if [[ "${c}" == *"user@.service"* && "${c}" == *"vendor"* ]]; then neg=0; else neg=1; fi
assert_eq "1" "${neg}" "negative control: the acknowledgement predicate rejects the old wording"
test_finish
