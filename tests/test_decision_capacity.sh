#!/usr/bin/env bash
# test_decision_capacity.sh - SC-010 / FR-027 / FR-028 (spec 009): the
# decision-capacity report in `plan --json` must EQUAL what the scheduler's
# admission logic actually accepts.
#
# For every decision profile on every hardware fixture, starting instances
# one at a time through the REAL admission code path (lib/scheduler.sh:
# sched_decision_probe -> _sched_admission_fits, the same predicate
# _sched_start_impl uses), in an otherwise idle budget, succeeds exactly
# instances_<placement> times and the next attempt is refused WITH NUMBERS.
# The best single placement therefore accepts max(instances_gpu,
# instances_cpu) instances = total_decision_slots / slots_per_instance
# (data-model.md section 10). Nothing in this file re-implements the
# admission arithmetic; the only arithmetic done here is max() and a
# comparison. The probe is read-only: no reservation or service file may
# appear (asserted below).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/os_detect.sh"
source "${LLMCTL_ROOT}/lib/hardware.sh"
source "${LLMCTL_ROOT}/lib/catalog.sh"
source "${LLMCTL_ROOT}/lib/scheduler.sh"

FIXTURES=(baseline workstation constrained vram-contended tiny apple cpu-heavy small-exact \
          ram-contended-auto-eviction vram-contended-coresident)

# check_capacity <fixture> <plan-json-file> -> prints a line per mismatch,
# returns the number of mismatches. Uses the REAL admission probe.
check_capacity() {
  local fx="$1" plan_file="$2" bad=0 prof placement want got msg
  local profiles
  profiles="$(json_query "${plan_file}" 'sorted(d["decision_instances"].keys())')"
  for prof in ${profiles}; do
    for placement in gpu cpu; do
      want="$(json_query "${plan_file}" "d[\"decision_instances\"][\"${prof}\"][\"instances_${placement}\"]")"
      # plan computed ONCE per fixture (speed); the un-cached end-to-end
      # path (probe computes its own plan) is exercised further below
      out="$(sched_decision_probe "${prof}" "${placement}" "${plan_file}")" \
        || { echo "probe failed: ${fx} ${prof} ${placement}"; bad=$((bad+1)); continue; }
      got="$(printf '%s\n' "${out}" | sed -n 's/^accepted=//p')"
      msg="$(printf '%s\n' "${out}" | sed -n 's/^refused=//p')"
      if [[ "${got}" != "${want}" ]]; then
        echo "MISMATCH ${fx} ${prof} ${placement}: report=${want} admission=${got}"
        bad=$((bad+1))
      fi
      # the refusal after the last accepted instance must carry numbers
      # (or name the tier gate), never be empty
      if [[ -z "${msg}" ]] || ! [[ "${msg}" =~ [0-9]+\ MiB || "${msg}" == *"tier gate"* || "${msg}" == *"not applicable"* ]]; then
        echo "NO-NUMBERS-REFUSAL ${fx} ${prof} ${placement}: '${msg}'"
        bad=$((bad+1))
      fi
    done
  done
  return "${bad}"
}

plan_for() { LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-$1.json" hw_probe_json | catalog_plan_json; }

total_profiles=0
for fx in "${FIXTURES[@]}"; do
  [[ -f "${LLMCTL_ROOT}/tests/fixtures/hw-${fx}.json" ]] || { assert_skip "fixture hw-${fx}.json absent" "capacity==admission on ${fx}"; continue; }
  plan_for "${fx}" > "${TEST_TMP}/plan-${fx}.json"
  rc=0; mism="$(check_capacity "${fx}" "${TEST_TMP}/plan-${fx}.json")" || rc=$?
  [[ -z "${mism}" ]] || printf '%s\n' "${mism}" >&2
  assert_eq 0 "${rc}" "SC-010 ${fx}: every decision profile accepts exactly instances_gpu/instances_cpu instances, then refuses with numbers"
  total_profiles=$(( total_profiles + $(json_query "${TEST_TMP}/plan-${fx}.json" 'len(d["decision_instances"])') ))

  # best placement: max(instances_gpu, instances_cpu) is what the best single
  # placement accepts and equals total_decision_slots / slots_per_instance
  ok="$(python3 - "${TEST_TMP}/plan-${fx}.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
bad = []
for n, r in d["decision_instances"].items():
    best = max(r["instances_gpu"], r["instances_cpu"])
    if r["total_decision_slots"] != best * r["per_instance"]["slots"]:
        bad.append(n + ": total_decision_slots != max(gpu,cpu)*slots")
    bp = r.get("best_placement")
    want = "gpu" if r["instances_gpu"] >= r["instances_cpu"] and r["instances_gpu"] > 0 else ("cpu" if r["instances_cpu"] > 0 else None)
    if bp != want:
        bad.append("%s: best_placement %r != %r" % (n, bp, want))
    if "protocol" not in r:
        bad.append(n + ": additive 'protocol' field missing")
    if r["instances_gpu"] == 0 and r["instances_cpu"] == 0 and "reason" not in r:
        bad.append(n + ": zero instances without a reason")
    if (r["instances_gpu"] or r["instances_cpu"]) and "reason" in r:
        bad.append(n + ": reason present although instances fit")
print("; ".join(bad) if bad else "ok")
PYEOF
)"
  assert_eq ok "${ok}" "data-model s10 definition on ${fx}: slots = max(gpu,cpu) x slots/instance, best_placement, protocol, reason only at 0"
done
printf '  info: %s fixture x profile combinations checked\n' "${total_profiles}"

# --- the probe is read-only (the report "never starts or reserves anything") ---
assert_eq "" "$(ls -A "${LLMCTL_RUNTIME_DIR}" 2>/dev/null)" "probe left no reservation (.run) files"
assert_eq "" "$(ls -A "${LLMCTL_SERVICES_DIR}" 2>/dev/null || true)" "probe left no service files"

# --- paired mutation: a report one instance too generous / too small MUST be caught ---
python3 - "${TEST_TMP}/plan-baseline.json" "${TEST_TMP}/plan-baseline-plus1.json" "${TEST_TMP}/plan-baseline-minus1.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
plus = json.loads(json.dumps(d)); minus = json.loads(json.dumps(d))
plus["decision_instances"]["decide"]["instances_cpu"] += 1
minus["decision_instances"]["decide-tiny"]["instances_gpu"] -= 1
json.dump(plus, open(sys.argv[2], "w")); json.dump(minus, open(sys.argv[3], "w"))
PYEOF
rc=0; check_capacity baseline "${TEST_TMP}/plan-baseline-plus1.json" >/dev/null 2>&1 || rc=$?
assert_eq 1 "${rc}" "mutation: report claiming one instance too many is detected by the admission comparison"
rc=0; check_capacity baseline "${TEST_TMP}/plan-baseline-minus1.json" >/dev/null 2>&1 || rc=$?
assert_eq 1 "${rc}" "mutation: report claiming one instance too few is detected by the admission comparison"

# --- refusal wording: exact numbers, instance ordinal, placement ---------------
out="$(LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json" sched_decision_probe decide gpu)"
assert_contains "${out}" "accepted=2" "baseline decide: 2 GPU instances accepted (3671 MiB VRAM each of 10444)"
assert_contains "${out}" "refused=cannot start instance 3 of 'decide' (gpu placement): needs 2048 MiB RAM + 3671 MiB VRAM, but only 21808 MiB RAM + 3102 MiB VRAM remain" \
  "refusal after the last fitting instance names the instance, placement and the exact remaining numbers"
out="$(LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json" sched_decision_probe decide-pro gpu)"
assert_contains "${out}" "accepted=0" "baseline decide-pro (tier-gated): admission accepts 0 instances, like the report"
assert_contains "${out}" "tier gate" "baseline decide-pro: refusal names the tier gate"
out="$(LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json" sched_decision_probe decide-nli gpu)"
assert_contains "${out}" "accepted=0" "decide-nli has no GPU placement (CPU-only encoder): 0 accepted"
assert_contains "${out}" "not applicable" "decide-nli gpu: refusal says the placement is not applicable"
rc=0; LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json" sched_decision_probe not-a-profile gpu >/dev/null 2>&1 || rc=$?
assert_eq 1 "${rc}" "unknown profile: probe fails loudly"
rc=0; LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json" sched_decision_probe fast gpu >/dev/null 2>&1 || rc=$?
assert_eq 1 "${rc}" "a chat profile is not a decision profile: probe refuses (FR-006)"
rc=0; LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json" sched_decision_probe decide tpu >/dev/null 2>&1 || rc=$?
assert_eq 1 "${rc}" "unknown placement: probe fails loudly"

# --- the SAME predicate guards a real `llmctl start` ------------------------------
# (_sched_start_impl uses _sched_admission_fits; a start that does not fit is refused with numbers)
export LLMCTL_DRY_RUN=1
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-tiny.json"
out="$("${LLMCTL_ROOT}/bin/llmctl" start decide 2>&1)" && rc=0 || rc=$?
assert_eq 1 "${rc}" "llmctl start decide on a host with no RAM budget is refused"
assert_contains "${out}" "cannot start 'decide': needs" "refused start reports the needed numbers"

test_finish
