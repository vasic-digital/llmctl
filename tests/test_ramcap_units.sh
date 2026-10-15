#!/usr/bin/env bash
# test_ramcap_units.sh - review 2026-10-15 finding 10: the 60%-of-MemTotal cap (Constitution 12.6) counted only the
# reservations (.run files) that llmctl start/enable write. A unit started by systemd itself (boot, Restart=, the unit
# waiter) writes none, so `llmctl plan --json` reported ram_reserved_mb 0 while llmctl-onnx@decide-nli ran. Running llmctl
# engine units WITHOUT a reservation are now counted with their cgroup memory (systemd MemoryCurrent); a unit WITH a
# reservation is counted once. Hermetic: the unit list comes from LLMCTL_FAKE_UNIT_MEM ("<instance> <MiB>" lines; a fake
# can only ADD to the reservation, never lower it); with LLMCTL_FAKE_HW and no fake unit list the host's real units are
# never read (a fake host has no real units).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
L="${RAMCAP_ROOT_UNDER_TEST:-${LLMCTL_ROOT}}/bin/llmctl"
HW="${TEST_TMP}/hw.json"
python3 -I - "${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json" "${HW}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["memory"]["total_mb"] = 32768; d["memory"]["available_mb"] = 30720
json.dump(d, open(sys.argv[2], "w"))
PY
export LLMCTL_FAKE_HW="${HW}"
b() { "${L}" plan --json | python3 -I -c 'import json,sys; b=json.load(sys.stdin)["budgets"]; print(b["ram_mb"], b["ram_reserved_mb"], b.get("ram_units_unreserved_mb", "absent"))'; }

echo "== a fake host without a unit list: no unit is counted (the real host's units are never read)"
assert_eq "19660 0 0" "$(b)" "no reservation, no unit: budget 19660 (60% of 32768)"

echo "== a running unit with NO reservation is counted with its memory"
printf 'decide-nli 3000\n' > "${TEST_TMP}/units"
export LLMCTL_FAKE_UNIT_MEM="${TEST_TMP}/units"
assert_eq "16660 3000 3000" "$(b)" "llmctl-onnx@decide-nli (3000 MiB, started by systemd, no .run) is reserved: 19660 - 3000"

echo "== a unit WITH a reservation is counted once (the reservation)"
printf 'profile=decide-nli\nmode=cpu\nport=1\nram_mb=2000\nvram_mb=0\nstarted_epoch=1\n' > "${LLMCTL_RUNTIME_DIR}/decide-nli.run"
assert_eq "17660 2000 0" "$(b)" "the reservation (2000) counts, the unit is not added on top"
rm -f "${LLMCTL_RUNTIME_DIR}/decide-nli.run"

echo "== malformed unit lines are ignored, several units add up"
printf 'decide-nli 3000\nbad line here\nsmall x\nvision 1500\n' > "${TEST_TMP}/units"
assert_eq "15160 4500 4500" "$(b)" "3000 + 1500 counted, the malformed lines ignored"

test_finish
