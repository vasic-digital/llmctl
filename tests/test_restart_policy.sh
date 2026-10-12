#!/usr/bin/env bash
# test_restart_policy.sh - RED-first (fix/bounded-restart-and-pressure-gates).
# Root cause (3): StartLimitBurst=5/IntervalSec=60 with Restart=always cannot trip when a real cycle (model load + stop-post
# stall) is >60 s, so OOM-kills were retried forever. tests/test_services_crashloop.sh only greps unit text; this file
# also drives a REAL transient systemd --user unit built from the GENERATED unit's values (time scaled 1/20).
# Contract: Restart=on-failure, RestartPreventExitStatus includes SIGKILL, RestartSteps/RestartMaxDelaySec present,
# [Unit] StartLimitIntervalSec>=600 and StartLimitBurst<=3. Transient units are named llmctl-test-<pid>-* and removed.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
export LLMCTL_DRY_RUN=1
export LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
# shellcheck disable=SC1090
for l in common os_detect hardware service_linux; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
( svc_install ) >/dev/null 2>&1
sect_val() { awk -v s="$2" -v k="$3" '/^\[/{cur=$0} cur==s && index($0,k"=")==1{sub(/^[^=]*=/,""); print; exit}' "$1"; }

PREFIX="llmctl-test-$$"
STARTED=()
# Every transient unit gets a systemd-run --on-active reaper timer: if this test is SIGKILLed before its EXIT trap, the
# user manager itself stops the (possibly Restart=always looping) unit after 120 s.
arm_reaper() { # <unit-name-without-.service>
  systemd-run --user --quiet --on-active=120s --unit="$1-reaper" systemctl --user stop "$1.service" >/dev/null 2>&1 || true
  if systemctl --user list-units --all --plain --no-legend "$1-reaper.timer" 2>/dev/null | grep -q "$1-reaper.timer"; then echo "  ok: reaper timer armed for $1"
  else printf '  FAIL: no reaper timer armed for %s (a SIGKILLed test could leave a looping unit in the live user manager)\n' "$1" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
}
cleanup() {
  local u; for u in ${STARTED[@]+"${STARTED[@]}"}; do systemctl --user stop "${u}.service" >/dev/null 2>&1 || true; systemctl --user reset-failed "${u}.service" >/dev/null 2>&1 || true; done
  test_teardown_env
}
trap cleanup EXIT

for eng in llama colibri onnx; do
  U="${LLMCTL_UNIT_DIR}/llmctl-${eng}@.service"
  assert_eq "on-failure" "$(sect_val "${U}" '[Service]' Restart)" "${eng}: Restart=on-failure (not always)"
  assert_contains "$(sect_val "${U}" '[Service]' RestartPreventExitStatus)" "SIGKILL" "${eng}: RestartPreventExitStatus includes SIGKILL"
  assert_contains "$(grep -E '^RestartSteps=' "${U}" || true)" "RestartSteps=" "${eng}: RestartSteps= present"
  assert_contains "$(grep -E '^RestartMaxDelaySec=' "${U}" || true)" "RestartMaxDelaySec=" "${eng}: RestartMaxDelaySec= present"
  iv="$(sect_val "${U}" '[Unit]' StartLimitIntervalSec)"; iv="${iv%s}"; bu="$(sect_val "${U}" '[Unit]' StartLimitBurst)"
  if [[ "${iv}" =~ ^[0-9]+$ && "${iv}" -ge 600 ]]; then echo "  ok: ${eng}: [Unit] StartLimitIntervalSec=${iv} >= 600"; else printf '  FAIL: %s: [Unit] StartLimitIntervalSec=%s (need >= 600)\n' "${eng}" "${iv:-unset}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
  if [[ "${bu}" =~ ^[0-9]+$ && "${bu}" -le 3 ]]; then echo "  ok: ${eng}: [Unit] StartLimitBurst=${bu} <= 3"; else printf '  FAIL: %s: [Unit] StartLimitBurst=%s (need <= 3)\n' "${eng}" "${bu:-unset}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
done
GU="${LLMCTL_UNIT_DIR}/llmctl-llama@.service"

# --- behavioral (real systemd --user manager) -------------------------------------------------------------------
if ! systemctl --user show-environment >/dev/null 2>&1 || ! command -v systemd-run >/dev/null 2>&1; then
  assert_skip "no reachable systemd --user manager" "behavioral restart-bound tests"
else
  restart="$(sect_val "${GU}" '[Service]' Restart)"; restart="${restart:-no}"
  prevent="$(sect_val "${GU}" '[Service]' RestartPreventExitStatus)"
  biv="$(sect_val "${GU}" '[Unit]' StartLimitIntervalSec)"; biv="${biv%s}"; biv="${biv:-10}"
  bbu="$(sect_val "${GU}" '[Unit]' StartLimitBurst)"; bbu="${bbu:-5}"
  sciv=$(( biv / 20 )); [[ "${sciv}" -ge 1 ]] || sciv=1     # time scaled 1/20: 60s -> 3s, 600s -> 30s
  # (a) a unit whose real cycle (2s run + 1s RestartSec = 3s+) is longer than the scaled 3s interval: only a long
  #     interval + small burst bounds it. Wait up to ~40 s for it to give up.
  U1="${PREFIX}-loop"; STARTED+=("${U1}"); arm_reaper "${U1}"
  systemd-run --user --quiet --unit="${U1}" -p "Restart=${restart}" -p RestartSec=1 -p "StartLimitIntervalSec=${sciv}" \
    -p "StartLimitBurst=${bbu}" bash -c 'sleep 2; exit 1' >/dev/null 2>&1 || true
  st=""; res=""; nr=""; tripped=0
  # Tripped = the unit sits in `failed` and stays there with an unchanged NRestarts for longer than a whole cycle
  # (3 s). (On systemd 259 a limit hit during an auto-restart leaves Result=exit-code, journal: "Start request repeated
  # too quickly"; state=failed alone is also transient inside the RestartSec window, so it is not enough.)
  for _ in $(seq 1 40); do
    st="$(systemctl --user show -p ActiveState --value "${U1}.service" 2>/dev/null || true)"
    if [[ "${st}" == failed ]]; then
      nr="$(systemctl --user show -p NRestarts --value "${U1}.service" 2>/dev/null || echo ?)"; sleep 4
      st2="$(systemctl --user show -p ActiveState --value "${U1}.service" 2>/dev/null || true)"
      nr2="$(systemctl --user show -p NRestarts --value "${U1}.service" 2>/dev/null || echo ?)"
      [[ "${st2}" == failed && "${nr}" == "${nr2}" ]] && { tripped=1; break; }
    fi
    sleep 1
  done
  res="$(systemctl --user show -p Result --value "${U1}.service" 2>/dev/null || true)"
  if [[ "${tripped}" == 1 ]]; then echo "  ok: behavioral: crash loop gave up and stayed failed (NRestarts=${nr}, Result=${res})"
  else printf '  FAIL: behavioral: crash loop never gave up within 40s (state=%s result=%s NRestarts=%s; Restart=%s interval=%s(scaled %ss) burst=%s)\n' "${st}" "${res}" "${nr}" "${restart}" "${biv}" "${sciv}" "${bbu}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
  systemctl --user stop "${U1}.service" >/dev/null 2>&1 || true; systemctl --user reset-failed "${U1}.service" >/dev/null 2>&1 || true

  # (b) a SIGKILLed (OOM-killed) main process must NOT be restarted when the unit says RestartPreventExitStatus=SIGKILL.
  U2="${PREFIX}-oomkill"; STARTED+=("${U2}"); arm_reaper "${U2}"
  args=(-p "Restart=${restart}" -p RestartSec=1)
  [[ -z "${prevent}" ]] || args+=(-p "RestartPreventExitStatus=${prevent}")
  systemd-run --user --quiet --unit="${U2}" "${args[@]}" bash -c 'kill -9 $$$$' >/dev/null 2>&1 || true   # systemd turns $$ into $, so $$$$ reaches bash as $$
  sleep 4
  nr2="$(systemctl --user show -p NRestarts --value "${U2}.service" 2>/dev/null || echo ?)"
  st2="$(systemctl --user show -p ActiveState --value "${U2}.service" 2>/dev/null || true)"
  if [[ "${nr2}" == 0 && "${st2}" == failed ]]; then echo "  ok: behavioral: SIGKILLed unit is not restarted (state=${st2} NRestarts=0)"
  else printf '  FAIL: behavioral: SIGKILLed unit was restarted or still cycling (state=%s NRestarts=%s; Restart=%s PreventExitStatus=%s)\n' "${st2}" "${nr2}" "${restart}" "${prevent:-unset}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
  systemctl --user stop "${U2}.service" >/dev/null 2>&1 || true; systemctl --user reset-failed "${U2}.service" >/dev/null 2>&1 || true

  # --- negative control: today's policy (Restart=always, 5/60) with the SAME scaled loop does NOT trip within 12 s
  U3="${PREFIX}-ctl"; STARTED+=("${U3}"); arm_reaper "${U3}"
  systemd-run --user --quiet --unit="${U3}" -p Restart=always -p RestartSec=1 -p StartLimitIntervalSec=3 -p StartLimitBurst=5 bash -c 'sleep 2; exit 1' >/dev/null 2>&1 || true
  sleep 12
  st3="$(systemctl --user show -p ActiveState --value "${U3}.service" 2>/dev/null || true)"
  res3="$(systemctl --user show -p Result --value "${U3}.service" 2>/dev/null || true)"
  if [[ "${res3}" != start-limit-hit ]]; then echo "  ok: negative control: old policy (always, 5/60 scaled) never trips (state=${st3} result=${res3}) - the harness can see the bug"
  else printf '  FAIL: negative control: old policy tripped (result=%s); the behavioral harness cannot discriminate\n' "${res3}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
  systemctl --user stop "${U3}.service" >/dev/null 2>&1 || true; systemctl --user reset-failed "${U3}.service" >/dev/null 2>&1 || true
fi
# prove nothing of this run is left in the live user manager (units AND reaper timers)
for u in ${STARTED[@]+"${STARTED[@]}"}; do systemctl --user stop "${u}.service" "${u}-reaper.timer" "${u}-reaper.service" >/dev/null 2>&1 || true; systemctl --user reset-failed "${u}.service" >/dev/null 2>&1 || true; done
left="$(systemctl --user list-units --all --plain --no-legend "${PREFIX}-*" 2>/dev/null | wc -l)"
assert_eq "0" "${left}" "no ${PREFIX}-* unit or timer remains in the user manager"
test_finish
