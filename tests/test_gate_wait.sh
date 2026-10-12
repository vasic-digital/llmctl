#!/usr/bin/env bash
# test_gate_wait.sh - RED-first (review HIGH-1). `svc_hook.sh gate` is the unit's ExecStartPre. Exiting 75 at once made
# Restart=on-failure retry it, and every retry counts against StartLimitBurst=3/900s: a pressure spike longer than ~30 s
# ended in start-limit-hit and a 900 s lockout. Contract: the gate WAITS (LLMCTL_GATE_WAIT s, default 120, polling every
# LLMCTL_GATE_POLL s, default 5) and exits 75 only if the pressure persists; TimeoutStartSec exceeds wait + model load.
# Persistent refusal (> 3 x (wait+RestartSec) with pressure the whole time) can still end in start-limit-hit: that is the
# deliberate fail-closed end state, documented in docs/host-safety.md; this test pins the single-start behaviour.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
HOOK="${LLMCTL_ROOT}/lib/svc_hook.sh"
HIGH=$'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\nfull avg10=9.00 avg60=0.00 avg300=0.00 total=1\n'
LOW=$'some avg10=0.00 avg60=0.00 avg300=0.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=1\n'
PSI="${TEST_TMP}/psi.dyn"; export LLMCTL_PSI_FILE="${PSI}"
BG=""; trap '[[ -z "${BG}" ]] || kill "${BG}" 2>/dev/null || true; test_teardown_env' EXIT
now() { date +%s.%N; }
el() { awk -v a="$1" -v b="$(now)" 'BEGIN{printf "%.1f", b-a}'; }

echo "== pressure that drops after ~3 s: the gate waits and then passes =="
printf '%s' "${HIGH}" > "${PSI}"
( sleep 3; printf '%s' "${LOW}" > "${PSI}" ) & BG=$!
t0="$(now)"; rc=0; LLMCTL_GATE_WAIT=20 LLMCTL_GATE_POLL=1 timeout 40 bash "${HOOK}" gate vision >/dev/null 2>&1 || rc=$?
e="$(el "${t0}")"
assert_eq "0" "${rc}" "gate passes once the PSI fixture drops (waited ${e}s)"
awk -v e="${e}" 'BEGIN{exit !(e>=2.0 && e<15)}' && echo "  ok: it actually waited (${e}s, between 2 and 15)" || { printf '  FAIL: elapsed %ss: expected a wait of ~3 s\n' "${e}" >&2; TEST_FAILS=$((TEST_FAILS+1)); }
wait "${BG}" 2>/dev/null || true; BG=""

echo "== pressure that never drops: 75 after the bounded wait, not before =="
printf '%s' "${HIGH}" > "${PSI}"
t0="$(now)"; rc=0; LLMCTL_GATE_WAIT=3 LLMCTL_GATE_POLL=1 timeout 30 bash "${HOOK}" gate vision >/dev/null 2>&1 || rc=$?
e="$(el "${t0}")"
assert_eq "75" "${rc}" "persistent pressure: exit 75"
awk -v e="${e}" 'BEGIN{exit !(e>=2.5 && e<10)}' && echo "  ok: refused only after the wait (${e}s)" || { printf '  FAIL: elapsed %ss: expected ~3 s of waiting before refusing\n' "${e}" >&2; TEST_FAILS=$((TEST_FAILS+1)); }

echo "== WAIT=0 keeps the immediate refusal (interactive/test use) =="
t0="$(now)"; rc=0; LLMCTL_GATE_WAIT=0 timeout 10 bash "${HOOK}" gate vision >/dev/null 2>&1 || rc=$?
assert_eq "75" "${rc}" "WAIT=0: exit 75"
awk -v e="$(el "${t0}")" 'BEGIN{exit !(e<1.5)}' && echo "  ok: immediate" || { printf '  FAIL: WAIT=0 still waited\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); }

echo "== TimeoutStartSec covers gate wait + model start =="
export LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"
# shellcheck disable=SC1090
for l in common os_detect hardware service_linux; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done
( svc_install ) >/dev/null 2>&1
for eng in llama colibri onnx; do
  t="$(sed -n 's/^TimeoutStartSec=//p' "${LLMCTL_UNIT_DIR}/llmctl-${eng}@.service" | tail -1)"; t="${t%s}"
  if [[ "${t}" =~ ^[0-9]+$ && "${t}" -ge 420 ]]; then echo "  ok: ${eng}: TimeoutStartSec=${t} >= 420 (120 s gate + 300 s start)"
  else printf '  FAIL: %s: TimeoutStartSec=%s must be >= 420 (gate wait 120 + 300)\n' "${eng}" "${t:-unset}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
done
test_finish
