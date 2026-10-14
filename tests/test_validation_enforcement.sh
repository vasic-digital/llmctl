#!/usr/bin/env bash
# test_validation_enforcement.sh - RED-first (independent review 2026-10-14, finding 1, HIGH): the validation requirement
# was not ENFORCED. A started profile was registered/published (and an `enable`d unit enabled) BEFORE it was validated,
# UNDETERMINED kept it serving by default, and nothing a consumer could call refused an unvalidated profile. Now:
#  (a) a profile without a fresh, signed PASS record starts in QUARANTINE - loopback, private ephemeral port, never in the
#      registry - and is published on its documented port only after its validation PASSES; `enable` enables a unit only
#      for a validated profile; a systemd start without a fresh record is skipped (ExecCondition `validated`, exit 77);
#  (b) strict is the DEFAULT: FAIL and UNDETERMINED are stopped; LLMCTL_VALIDATE_STRICT=0 is the documented opt-out,
#      shown in status, and REFUSED for consumer-facing profiles; LLMCTL_VALIDATE_ON_START=0 likewise;
#  (c) start/switch/auto/enable/restart/scale and the systemd waiter refuse or hide unvalidated profiles; status says why;
#  (d) `llmctl endpoint <profile>` prints the URL only for a running, published, validated profile.
# Harness: tests/gate_wiring_lib.sh (recording service manager, validate_profile recorder with an injected verdict - a
# verdict 0 counts as "a PASS record was written" for the freshness check) and, for (d) and the waiter, real records
# from tests/validation_local_lib.sh. No real model, unit or llama-server is started or stopped.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source "$(dirname "${BASH_SOURCE[0]}")/gate_wiring_lib.sh"
test_setup_env
unset LLMCTL_VALIDATE_HERMETIC
cleanup() {
  local p
  for p in $(pgrep -f "${TEST_TMP}/tree/lib/svc_hook.sh" 2>/dev/null || true); do kill "${p}" 2>/dev/null || true; done
  gw_cleanup_bg; test_teardown_env
}
trap cleanup EXIT
gw_init
L="${GW_LLMCTL}"
# mutation hook (tests/test_validation_mutants.sh): one exact replacement in ONE lib file of the throw-away tree
if [[ -n "${ENF_MUT_FILE:-}" ]]; then
  mf="${GW_TREE}/lib/${ENF_MUT_FILE}"
  if [[ -L "${mf}" ]]; then cp --remove-destination "$(readlink -f "${mf}")" "${mf}"; fi
  python3 -I - "${mf}" <<'PY'
import os, sys
p = sys.argv[1]; s = open(p).read(); old, new = os.environ["ENF_MUT_OLD"], os.environ["ENF_MUT_NEW"]
if s.count(old) != 1:
    sys.exit("mutation anchor found %d times" % s.count(old))
open(p, "w").write(s.replace(old, new))
PY
  echo "MUTANT applied to ${ENF_MUT_FILE}"
fi
DOC_PORT="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["profiles"]["small"]["port"])' "${LLMCTL_CATALOG}")"
envv() { sed -n "s/^$2=//p" "${LLMCTL_SERVICES_DIR}/$1.env" 2>/dev/null | head -1; }
b2i() { if "$@"; then echo 1; else echo 0; fi; }
out_has() { grep -qE -- "$1" "${TEST_TMP}/last.out"; }

echo "== (a) no record: the start is a QUARANTINE start (loopback, private port, unpublished); PASS -> published"
gw_calls_reset; rm -f "${LLMCTL_RUNTIME_DIR}"/*.run
export GW_VALIDATE_RC=2      # UNDETERMINED first: the profile is stopped, so the quarantine env record stays inspectable
rc="$(gw_run "${L}" start small)"
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "UNDETERMINED (default strict): start exits non-zero (rc=${rc})"
assert_contains "$(envv small LLMCTL_ARGS)" "--host 127.0.0.1" "the quarantine start binds loopback only"
qport="$(envv small LLMCTL_PORT)"
if [[ "${qport}" =~ ^[0-9]+$ && "${qport}" != "${DOC_PORT}" ]]; then printf '  ok: private port %s, not the documented %s\n' "${qport}" "${DOC_PORT}"; else printf '  FAIL: quarantine port %s (documented %s)\n' "${qport}" "${DOC_PORT}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
assert_eq 1 "$(b2i [ -n "$(envv small LLMCTL_QUARANTINE_UNTIL)" ])" "the env record carries the quarantine deadline (the unit's ExecCondition reads it)"
assert_eq 1 "$(b2i out_has 'UNPUBLISHED for validation')" "the start says it is unpublished"
assert_eq 1 "$(gw_count '^validate_profile small')" "validation ran once"
assert_eq 1 "$(gw_count '^svc_stop small$')" "UNDETERMINED: stopped (strict is the default)"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/small.run" "UNDETERMINED: nothing left running"
assert_eq 1 "$(b2i out_has 'never served')" "UNDETERMINED: the message says an unvalidated model is never served"

gw_calls_reset; export GW_VALIDATE_RC=0
rc="$(gw_run "${L}" start small)"
assert_eq 0 "${rc}" "PASS: start exits 0"
assert_eq 2 "$(gw_count '^svc_start small$')" "PASS: started twice (quarantine, then published)"
s1="$(gw_line '^svc_start small$')"; v="$(gw_line '^validate_profile_end small rc=0')"; st="$(gw_line_after '^svc_stop small$' "${v}")"; s2="$(gw_line_after '^svc_start small$' "${s1}")"
assert_eq 1 "$(( s1 < v && v < st && st < s2 ? 1 : 0 ))" "order: quarantine start (${s1}) < PASS (${v}) < stop (${st}) < public start (${s2})"
assert_eq "${DOC_PORT}" "$(envv small LLMCTL_PORT)" "published on the documented port"
assert_eq "" "$(envv small LLMCTL_QUARANTINE_UNTIL)" "the published env record has no quarantine marker"
assert_eq 0 "$(grep -c '^quarantine=1' "${LLMCTL_RUNTIME_DIR}/small.run" || true)" "the reservation is no longer a quarantine one"
assert_eq 1 "$(b2i out_has 'PASSED - published')" "the message says PASSED - published"
gw_run "${L}" stop small >/dev/null

echo "== (a) a fresh record: published directly, no quarantine, no second validation"
gw_calls_reset
rc="$(GW_FRESH=small gw_run "${L}" start small)"
assert_eq 0 "${rc}" "fresh: start exits 0"
assert_eq 1 "$(gw_count '^svc_start small$')" "fresh: started once"
assert_eq 0 "$(gw_count '^validate_profile small')" "fresh: not re-validated"
assert_eq "${DOC_PORT}" "$(envv small LLMCTL_PORT)" "fresh: documented port"
gw_run "${L}" stop small >/dev/null

echo "== (b) FAIL -> stopped; STRICT=0 is REFUSED for a consumer-facing profile; honoured (marked) for a non-consumer-facing one"
gw_calls_reset; export GW_VALIDATE_RC=1
rc="$(gw_run "${L}" start small)"
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "FAIL: exit non-zero"
assert_eq 1 "$(gw_count '^svc_stop small$')" "FAIL: stopped"
assert_eq 1 "$(gw_count '^svc_start small$')" "FAIL: never published"
gw_calls_reset; export GW_VALIDATE_RC=2
rc="$(gw_run env LLMCTL_VALIDATE_STRICT=0 "${L}" start small)"
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "STRICT=0 on consumer-facing small: refused (exit non-zero)"
assert_eq 1 "$(b2i out_has 'REFUSED for the consumer-facing')" "...and says why"
assert_eq 1 "$(gw_count '^svc_start small$')" "...never published"
python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["profiles"]["small"]["validation"]["consumer_facing"]=False; json.dump(d,open(p,"w"))' "${LLMCTL_CATALOG}"
gw_calls_reset
rc="$(gw_run env LLMCTL_VALIDATE_STRICT=0 "${L}" start small)"
assert_eq 0 "${rc}" "STRICT=0 on a NON-consumer-facing profile: served"
assert_eq 2 "$(gw_count '^svc_start small$')" "...published (quarantine, then public)"
assert_contains "$(cat "${LLMCTL_RUNTIME_DIR}/small.run")" "unvalidated=" "...and its reservation says UNVALIDATED"
assert_contains "$(envv small LLMCTL_UNVALIDATED)" "STRICT=0" "...as does its env record (the unit gate reads it)"
st="$(LLMCTL_VALIDATE_STRICT=0 "${L}" status 2>&1 || true)"
assert_contains "${st}" "validation: UNVALIDATED" "status shows the profile as UNVALIDATED"
assert_contains "${st}" "LLMCTL_VALIDATE_STRICT=0 is set" "status names the opt-out loudly"
assert_eq 1 "$(gw_run "${L}" endpoint small)" "endpoint refuses an UNVALIDATED profile"
gw_run "${L}" stop small >/dev/null
gw_calls_reset
rc="$(gw_run env -u LLMCTL_VALIDATE_STRICT "${L}" start small)"
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "a NON-consumer-facing profile WITHOUT the opt-out: UNDETERMINED is still stopped (strict is the default for every profile)"
assert_eq 1 "$(gw_count '^svc_start small$')" "...never published"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/small.run" "...nothing left running"
python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["profiles"]["small"]["validation"].pop("consumer_facing",None); json.dump(d,open(p,"w"))' "${LLMCTL_CATALOG}"

echo "== (b) LLMCTL_VALIDATE_ON_START=0 is refused for a consumer-facing profile (outside the test harness)"
gw_calls_reset
rc="$(gw_run env LLMCTL_VALIDATE_ON_START=0 "${L}" start small)"
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "ON_START=0: start refused"
assert_eq 0 "$(gw_count '^svc_start small$')" "...nothing started"
assert_eq 1 "$(b2i out_has 'LLMCTL_VALIDATE_ON_START=0 is refused')" "...and the reason is printed"

echo "== (c) enable: a unit is enabled only for a validated profile"
gw_calls_reset; export GW_VALIDATE_RC=1
rc="$(gw_run "${L}" enable small)"
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "enable of a profile that FAILS validation: refused"
assert_eq 0 "$(gw_count '^svc_enable small$')" "...no unit enabled"
assert_eq 1 "$(gw_count '^validate_profile small')" "...it was validated (in quarantine) first"
gw_calls_reset; export GW_VALIDATE_RC=0
rc="$(gw_run "${L}" enable small)"
assert_eq 0 "${rc}" "enable of a profile that PASSES: exit 0"
assert_eq 1 "$(gw_count '^svc_enable small$')" "...unit enabled after the PASS"
v="$(gw_line '^validate_profile_end small rc=0')"; e="$(gw_line '^svc_enable small$')"
assert_eq 1 "$(( v < e ? 1 : 0 ))" "...validation (${v}) BEFORE enablement (${e})"
gw_run "${L}" disable small >/dev/null; rm -f "${LLMCTL_RUNTIME_DIR}/small.run"

echo "== (c) restart without a fresh record: never restarted on the public port; quarantine + validation"
gw_mark_running small "${DOC_PORT}"; gw_calls_reset; export GW_VALIDATE_RC=2
rc="$(gw_run "${L}" restart small)"
assert_eq 0 "$(gw_count '^svc_restart small$')" "restart: no plain restart of an unvalidated profile"
assert_eq 1 "$(gw_count '^validate_profile small')" "restart: validated"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/small.run" "restart: UNDETERMINED -> not left running"

echo "== (c) decide scale refuses to add instances of an unvalidated decision profile"
gw_calls_reset
rc="$(gw_run "${L}" decide scale decide-tiny 2)"
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "scale without a fresh record: refused"
assert_eq 0 "$(gw_count '^svc_start decide-tiny')" "...nothing started"
assert_eq 1 "$(b2i out_has 'no fresh validation record')" "...and the reason is printed"

echo "== (c) switch: a target that fails validation is stopped and the previous set comes back through the gate"
gw_calls_reset; export GW_VALIDATE_RC=0 GW_VALIDATE_RC_fast=1
GW_FRESH=small gw_run "${L}" start small >/dev/null
gw_calls_reset
rc="$(GW_FRESH=small gw_run "${L}" switch fast)"
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "switch to a failing target: exit non-zero"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/fast.run" "the failing target is not running"
assert_file_exists "${LLMCTL_RUNTIME_DIR}/small.run" "the previous profile is running again"
unset GW_VALIDATE_RC_fast; gw_run "${L}" stop all >/dev/null

echo "== (c) the systemd unit: ExecCondition 'validated' skips an unvalidated start (exit 77), passes quarantine / opt-out"
HK="${GW_TREE}/lib/svc_hook.sh"
mkdir -p "${LLMCTL_SERVICES_DIR}"
uenv() { { printf 'LLMCTL_ENGINE=llama\nLLMCTL_PORT=9\nLLMCTL_REG_KIND=chat\nLLMCTL_REG_PROFILE=small\n'; printf '%s\n' "$@"; } > "${LLMCTL_SERVICES_DIR}/small.env"; }
hrc() { local rc=0; LLMCTL_ROOT="${GW_TREE}" bash "${HK}" validated small >/dev/null 2>&1 || rc=$?; echo "${rc}"; }
uenv;                                                  assert_eq 77 "$(hrc)" "no fresh record -> exit 77 (unit skipped, not failed, not restarted)"
uenv "LLMCTL_QUARANTINE_UNTIL=$(( $(date +%s) + 600 ))"; assert_eq 0 "$(hrc)" "a live quarantine start -> allowed"
uenv "LLMCTL_QUARANTINE_UNTIL=$(( $(date +%s) - 1 ))";   assert_eq 77 "$(hrc)" "an EXPIRED quarantine record (validation never finished) -> refused at boot"
uenv "LLMCTL_UNVALIDATED=opt-out";                     assert_eq 0 "$(hrc)" "an opt-out env record -> allowed (and logged)"
( export LLMCTL_DRY_RUN=1 LLMCTL_ROOT="${LLMCTL_ROOT}"; for l in common os_detect hardware service_linux; do source "${LLMCTL_ROOT}/lib/${l}.sh"; done; svc_install ) >/dev/null 2>&1 || true
U="${LLMCTL_UNIT_DIR}/llmctl-llama@.service"
assert_eq 1 "$(grep -cE '^ExecCondition=.*svc_hook\.sh.* validated %i' "${U}" 2>/dev/null || echo 0)" "the generated engine unit carries ExecCondition=... validated %i"

echo "== (c) the waiter: validates BEFORE it registers; kind 'chat' (what the env record really says) is validated"
FAKEBIN="${TEST_TMP}/fakebin"; mkdir -p "${FAKEBIN}"
printf '#!/usr/bin/env bash\nprintf "systemctl %%s\\n" "$*" >> "${GW_CALLS:?}"\nexit 0\n' > "${FAKEBIN}/systemctl"; chmod +x "${FAKEBIN}/systemctl"
GW_HTTP_FIXED_PORT=0 gw_http_server "${TEST_TMP}/ready.req"; WPORT="${GW_HTTP_PORT}"
sleep 300 >/dev/null 2>&1 & EPID=$!; GW_BG_PIDS+=("${EPID}")
wenv() { { printf 'LLMCTL_ENGINE=llama\nLLMCTL_PORT=%s\nLLMCTL_REG_TOKEN=tok\nLLMCTL_REG_PROTOCOL=http\n' "${WPORT}"
           printf 'LLMCTL_REG_HEALTH=/health\nLLMCTL_REG_KIND=chat\nLLMCTL_REG_PROFILE=small\nLLMCTL_REG_LOOPBACK=1\n'; printf '%s\n' "$@"; } > "${LLMCTL_SERVICES_DIR}/small.env"; }
waiter() { ( PATH="${FAKEBIN}:${PATH}" LLMCTL_ROOT="${GW_TREE}" LLMCTL_REGISTER_WAIT=15 LLMCTL_REGISTER_POLL=1 LLMCTL_VALIDATE_SETTLE=0 \
             timeout 60 bash "${HK}" _wait_register small "${EPID}" >"${TEST_TMP}/waiter.out" 2>&1 || true ); }
gw_mark_running small "${WPORT}"; gw_calls_reset; export GW_VALIDATE_RC=2
wenv; waiter
assert_eq 1 "$(gw_count '^validate_profile small')" "kind=chat: the waiter validated (it used to require kind=llm, which no env record carries)"
assert_eq 1 "$(gw_count '^systemctl --user stop llmctl-llama@small.service')" "UNDETERMINED in the waiter: the unit is stopped (strict default)"
assert_contains "$(cat "${LLMCTL_LOG_DIR}/svc_hook.log" 2>/dev/null)" "NOT registered (not validated)" "...and it was NOT registered"
gw_mark_running small "${WPORT}"; gw_calls_reset
wenv "LLMCTL_QUARANTINE_UNTIL=$(( $(date +%s) + 600 ))"; waiter
assert_eq 0 "$(gw_count '^validate_profile small')" "a quarantine unit: the waiter neither validates nor registers (llmctl does)"
assert_contains "$(cat "${LLMCTL_LOG_DIR}/svc_hook.log")" "quarantine start - not registered" "...and says so"
rm -f "${LLMCTL_RUNTIME_DIR}/small.run"

echo "== (d) llmctl endpoint: the URL only for a running, published, validated profile"
assert_eq 1 "$(gw_run "${L}" endpoint small)" "not running -> exit 1"
assert_eq 2 "$(gw_run "${L}" endpoint nosuch)" "unknown profile -> exit 2"
gw_mark_running small "${DOC_PORT}"; printf 'quarantine=1\n' >> "${LLMCTL_RUNTIME_DIR}/small.run"
assert_eq 1 "$(gw_run "${L}" endpoint small)" "quarantined -> exit 1"
assert_eq 1 "$(b2i out_has 'being validated')" "...'being validated'"
assert_contains "$("${L}" status 2>&1 || true)" "validation: QUARANTINE" "status shows the QUARANTINE state"
rm -f "${LLMCTL_RUNTIME_DIR}/small.run"
test_finish
