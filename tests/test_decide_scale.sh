#!/usr/bin/env bash
# test_decide_scale.sh - `llmctl decide scale <profile> <N>` (T135 / T071, OD-23, FR-027/FR-028/FR-029).
#
# Hermetic and host-safe: LLMCTL_DRY_RUN=1 (no systemd call, no engine, no server), hardware from a
# fixture (LLMCTL_FAKE_HW), nothing downloaded. The port registry is exercised through a recording
# stand-in for the llmctl-decide binary (unit tier; the real allocator has its own Go tests). The
# admission arithmetic is NOT re-implemented here: the expected refusal numbers are the ones
# tests/test_decision_capacity.sh pins for the same fixture (baseline: decide = 2048 MiB RAM +
# 3671 MiB VRAM per instance, 2 instances fit, the 3rd is refused with 21808 MiB RAM + 3102 MiB VRAM left).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT

LLMCTL="${LLMCTL_ROOT}/bin/llmctl"
export LLMCTL_DRY_RUN=1
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
unset LLMCTL_DECIDE_MODE LLMCTL_TENANT_ID

# run <args...>: rc in $RC, merged stdout+stderr in $OUT
run() { RC=0; OUT="$("${LLMCTL}" "$@" 2>&1)" || RC=$?; }
runs() { find "${LLMCTL_RUNTIME_DIR}" -maxdepth 1 -name '*.run' -printf '%f\n' 2>/dev/null | sort | paste -sd' ' -; }

echo "== usage and validation =="
run decide scale
assert_eq 2 "${RC}" "scale with no arguments is a usage error (rc 2)"
run decide scale decide
assert_eq 2 "${RC}" "scale without N is a usage error (rc 2)"
run decide scale decide two
assert_eq 2 "${RC}" "a non-numeric N is a usage error (rc 2)"
run decide scale decide -1
assert_eq 2 "${RC}" "a negative N is a usage error (rc 2)"
run decide scale not-a-profile 1
assert_eq 1 "${RC}" "an unknown profile fails (rc 1)"
assert_contains "${OUT}" "unknown profile: not-a-profile" "unknown profile is named"
run decide scale fast 1
assert_eq 1 "${RC}" "a chat profile is not a decision profile (rc 1)"
assert_eq "" "$(runs)" "validation failures start nothing"

echo "== admission refusal: exit 3 with the exact numbers, nothing started =="
run decide scale decide 3
assert_eq 3 "${RC}" "scaling past the admission bound exits 3"
assert_contains "${OUT}" "cannot scale 'decide' to 3" "refusal names the target"
assert_contains "${OUT}" "instance 3 (decide.3) needs 2048 MiB RAM + 3671 MiB VRAM, but only 21808 MiB RAM + 3102 MiB VRAM remain" \
  "refusal carries the instance key and the exact numbers"
assert_eq "" "$(runs)" "a refused scale is all-or-nothing: no reservation was written"
assert_eq "" "$(ls -A "${LLMCTL_SERVICES_DIR}" 2>/dev/null || true)" "a refused scale wrote no service env"

echo "== scale up: instance keys <profile>, <profile>.2; deterministic mode =="
run decide scale decide 2
assert_eq 0 "${RC}" "scale decide 2 within admission exits 0"
assert_eq "decide.2.run decide.run" "$(runs)" "reservations exist under the instance keys decide and decide.2"
assert_contains "${OUT}" "decide.2" "the second instance key is reported"
assert_contains "${OUT}" "deterministic" "deterministic mode is stated (primary first, overflow to the next instance)"
p1="$(sed -n 's/^port=//p' "${LLMCTL_RUNTIME_DIR}/decide.run")"
p2="$(sed -n 's/^port=//p' "${LLMCTL_RUNTIME_DIR}/decide.2.run")"
assert_eq 8093 "${p1}" "the primary keeps the documented port"
if [[ -n "${p2}" && "${p2}" != "${p1}" ]]; then printf '  ok: the second instance has a distinct port (%s)\n' "${p2}"
else printf '  FAIL: second instance port %q must differ from %q\n' "${p2}" "${p1}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
assert_file_contains "${LLMCTL_SERVICES_DIR}/decide.2.env" "llama-decide.2.key" \
  "each instance has its OWN internal key file (the prestart hook rotates a key per start)"
assert_file_contains "${LLMCTL_SERVICES_DIR}/decide.env" "llama-decide.key" "the primary keeps its key file"
assert_file_contains "${LLMCTL_SERVICES_DIR}/decide.2.env" "LLMCTL_REG_PROFILE=decide" "the registry profile label of decide.2 is the base profile"

echo "== idempotent, then the admission bound counts what already runs =="
run decide scale decide 2
assert_eq 0 "${RC}" "scale to the current count exits 0"
assert_contains "${OUT}" "already 2" "no-op is reported"
assert_eq "decide.2.run decide.run" "$(runs)" "no-op changes nothing"
run decide scale decide 3
assert_eq 3 "${RC}" "with two instances running, a third is still refused (rc 3)"
assert_contains "${OUT}" "instance 3 (decide.3) needs 2048 MiB RAM + 3671 MiB VRAM, but only 25904 MiB RAM + 3102 MiB VRAM remain" \
  "the running instances' reservations are subtracted (VRAM 10444 - 2 x 3671 = 3102; RAM budget is the live figure)"

echo "== scale down stops the highest instance first =="
run decide scale decide 1
assert_eq 0 "${RC}" "scale decide 1 exits 0"
assert_eq "decide.run" "$(runs)" "decide.2 stopped, the primary stays"
assert_file_absent "${LLMCTL_SERVICES_DIR}/decide.2.env" "a scaled-down instance leaves no service env behind"
run decide scale decide 0
assert_eq 0 "${RC}" "scale decide 0 exits 0"
assert_eq "" "$(runs)" "all instances stopped"

echo "== throughput mode is flagged (FR-029) =="
LLMCTL_DECIDE_MODE=throughput run decide scale decide 2
assert_eq 0 "${RC}" "throughput scale exits 0"
assert_contains "${OUT}" "throughput" "throughput mode is named in the output"
assert_contains "${OUT}" "x-llmctl-decide-mode: throughput" "output states the response marking"
run decide scale decide 0
LLMCTL_DECIDE_MODE=bogus run decide scale decide 1
assert_eq 1 "${RC}" "an invalid LLMCTL_DECIDE_MODE is refused"

echo "== a failed switch restores scaled instances (rollback keeps decide AND decide.2) =="
BE="${TEST_TMP}/backend.sh"
cat > "${BE}" <<'EOF2'
source "${LLMCTL_ROOT}/lib/service_linux.sh"
eval "_orig_$(declare -f svc_start)"
eval "_orig_$(declare -f svc_stop)"
svc_stop() { case " ${LLMCTL_FAKE_STOP_FAIL:-} " in *" $1 "*) return 1 ;; esac; _orig_svc_stop "$@"; }
svc_start() { case " ${LLMCTL_FAKE_START_FAIL:-} " in *" $1 "*) return 1 ;; esac; _orig_svc_start "$@"; }
EOF2
export LLMCTL_SERVICE_BACKEND_FILE="${BE}"
run decide scale decide 2
assert_eq "decide.2.run decide.run" "$(runs)" "two instances running before the switch"
run status
assert_contains "${OUT}" "decide #2" "status shows the second instance as an instance of decide, not as a profile 'decide.2'"
run status --json
assert_eq "decide decide" "$(printf '%s' "${OUT}" | python3 -c 'import json,sys; print(" ".join(r["profile"] for r in json.load(sys.stdin)))')" "status --json: profile is the base profile for every instance"
assert_contains "${OUT}" '"instance": "decide.2"' "status --json names the instance key"
LLMCTL_FAKE_START_FAIL="decide-tiny" run switch decide-tiny
assert_eq 1 "${RC}" "the switch to a target that cannot start fails"
if [[ "${OUT}" == *"unknown profile: decide.2"* ]]; then printf '  FAIL: rollback must not treat an instance key as a profile\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: rollback does not treat decide.2 as an unknown profile\n'; fi
assert_eq "decide.2.run decide.run" "$(runs)" "rollback restored decide AND decide.2"
run decide scale decide 0

echo "== restore is best-effort: a secondary that cannot restart never costs the primary =="
run decide scale decide 2
LLMCTL_FAKE_START_FAIL="decide-tiny decide.2" run switch decide-tiny
assert_eq 75 "${RC}" "switch failed AND the restore was incomplete (rc 75)"
assert_eq "decide.run" "$(runs)" "decide stays running although decide.2 could not be restored"
assert_contains "${OUT}" "decide.2" "the instance that could not be restored is named"
run decide scale decide 0

echo "== tier/footprint refusal states the true reason (plan says it does not fit) =="
cat > "${TEST_TMP}/nofit.sh" <<'EOF2'
source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/os_detect.sh"; source "${LLMCTL_ROOT}/lib/hardware.sh"
source "${LLMCTL_ROOT}/lib/catalog.sh"; source "${LLMCTL_ROOT}/lib/scheduler.sh"
eval "_real_$(declare -f catalog_plan_json)"
catalog_plan_json() { _real_catalog_plan_json | python3 -c '
import json,sys
d=json.load(sys.stdin); d["profiles"]["decide"]["fits"]=False
d["decision_instances"]["decide"]["reason"]="tier gate: host tier baseline below min_tier workstation"
print(json.dumps(d))'; }
rc=0; sched_decision_scale decide 1 || rc=$?
echo "RC=${rc}"
EOF2
OUT="$(bash "${TEST_TMP}/nofit.sh" 2>&1)" || true
assert_contains "${OUT}" "RC=3" "a profile the plan marks as not fitting is refused with exit 3 (not started)"
assert_contains "${OUT}" "does not fit this host: tier gate: host tier baseline below min_tier workstation" "the refusal states the real reason, not a headroom figure"
assert_eq "" "$(runs)" "nothing reserved for a non-fitting profile"

echo "== ports come from the registry allocator =="
ARGS="${TEST_TMP}/reg-args"; : > "${ARGS}"
STUB="${TEST_TMP}/stub-decide"
cat > "${STUB}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_ARGS}"
if [[ "${1:-}" == "port" && "${2:-}" == "allocate" ]]; then
  [[ -n "${STUB_FAIL_ALLOC:-}" && "$3" == "${STUB_FAIL_ALLOC}" ]] && { echo "port 9999 is taken (override LLMCTL_PORT_DECIDE)" >&2; exit 1; }
  case "$3" in decide) echo 8093 ;; decide.2) echo 9201 ;; *) echo 9300 ;; esac
fi
exit 0
EOF
chmod +x "${STUB}"
export LLMCTL_PORTREG=1 LLMCTL_DECIDE_BIN="${STUB}" STUB_ARGS="${ARGS}"
run decide scale decide 2
assert_eq 0 "${RC}" "scale with the registry active exits 0"
assert_contains "$(cat "${ARGS}")" "port allocate decide --profile decide --fixed 8093" "the primary asks for its documented port"
assert_contains "$(cat "${ARGS}")" "port allocate decide.2 --profile decide --strategy dynamic" "decide.2 asks the allocator for a dynamic port"
assert_eq 9201 "$(sed -n 's/^port=//p' "${LLMCTL_RUNTIME_DIR}/decide.2.run")" "the reservation records the allocated port"
assert_file_contains "${LLMCTL_SERVICES_DIR}/decide.2.env" "LLMCTL_PORT=9201" "the service env carries the allocated port"
run decide scale decide 0
assert_contains "$(cat "${ARGS}")" "port release decide.2" "scale down releases the port hold"
assert_eq "" "$(runs)" "everything stopped"

echo "== allocator failure: honest rc 1, nothing left behind =="
: > "${ARGS}"
STUB_FAIL_ALLOC=decide.2 run decide scale decide 2
assert_eq 1 "${RC}" "a failed port allocation fails the scale (rc 1)"
assert_contains "${OUT}" "decide.2" "the failing instance key is named"
assert_contains "${OUT}" "LLMCTL_PORT_DECIDE" "the allocator's message (port + override variable) is passed through"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/decide.2.run" "the failed instance has no reservation"
assert_eq "" "$(runs)" "an allocation failure rolls back the instances started in this call"
assert_contains "$(cat "${ARGS}")" "port release decide" "the rolled-back primary's port hold is released"

echo "== start failure: rolled back, port hold released, no stray env =="
rm -f "${LLMCTL_SERVICES_DIR}"/decide*.env
: > "${ARGS}"
LLMCTL_FAKE_START_FAIL="decide.2" run decide scale decide 2
assert_eq 1 "${RC}" "a failing svc_start fails the scale (rc 1)"
assert_contains "${OUT}" "failed to start 'decide.2'" "the failing key is named"
assert_contains "$(cat "${ARGS}")" "port release decide.2" "the failed instance's port hold is released"
assert_eq "" "$(runs)" "the instance started earlier in this call was rolled back"
assert_file_absent "${LLMCTL_SERVICES_DIR}/decide.2.env" "no stray env for the failed instance"
assert_file_absent "${LLMCTL_SERVICES_DIR}/decide.env" "no stray env for the rolled-back instance"

echo "== rollback releases the port hold even when svc_stop fails =="
: > "${ARGS}"
LLMCTL_FAKE_STOP_FAIL="decide" LLMCTL_FAKE_START_FAIL="decide.2" run decide scale decide 2
assert_eq 1 "${RC}" "the scale fails (rc 1)"
if grep -qx "port release decide" "${ARGS}"; then printf '  ok: the rolled-back primary'"'"'s port hold is released although its svc_stop failed\n'
else printf '  FAIL: port hold of decide not released when svc_stop failed\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
assert_eq "" "$(runs)" "the reservation is dropped regardless"

echo "== best-effort restore (registry active): the unrestorable secondary's hold and env are cleaned =="
run decide scale decide 2
: > "${ARGS}"
LLMCTL_FAKE_START_FAIL="decide-tiny decide.2" run switch decide-tiny
assert_eq 75 "${RC}" "switch failed AND the restore was incomplete (rc 75)"
assert_eq "decide.run" "$(runs)" "the primary is kept"
if [[ "$(grep ' decide.2\b' "${ARGS}" | tail -n1)" == "port release decide.2" ]]; then printf '  ok: the failed secondary'"'"'s port hold is released AFTER its re-allocation in best-effort mode\n'
else printf '  FAIL: port hold of decide.2 not released after its re-allocation in best-effort restore\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
assert_file_absent "${LLMCTL_SERVICES_DIR}/decide.2.env" "no decide.2.env remains after the best-effort restore"
run decide scale decide 0

echo "== extra instances refuse to guess a port without the allocator (real run) =="
export LLMCTL_PORTREG=0
unset LLMCTL_DECIDE_BIN
run decide scale decide 0
LLMCTL_DRY_RUN=0 run decide scale decide 2
assert_eq 1 "${RC}" "a real scale to 2 without the registry allocator is refused (rc 1)"
assert_contains "${OUT}" "llmctl build decide" "the refusal says how to get the allocator"
assert_eq "" "$(runs)" "refused before anything was reserved"

test_finish
