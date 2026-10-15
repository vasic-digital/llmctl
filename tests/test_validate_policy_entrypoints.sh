#!/usr/bin/env bash
# test_validate_policy_entrypoints.sh - review 2026-10-15 finding 6, the OTHER manual entry points. The first fix applied
# the verdict policy to `llmctl validate <p>` only; `llmctl vision validate`, `llmctl validate-all` and `llmctl models
# verify <p>` (which validates a running profile) also judge a SERVED profile and left it serving after a FAIL. Every
# manual entry point now applies the same policy: FAIL -> stopped through the normal stop path (registry row withdrawn);
# UNDETERMINED -> keeps running NOT validated, and says so.
# Harness: tests/gate_wiring_lib.sh (recording service manager, recorder validate_profile, ports remapped).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap 'gw_cleanup_bg; test_teardown_env' EXIT
source "$(dirname "${BASH_SOURCE[0]}")/gate_wiring_lib.sh"
gw_init
if [[ -n "${POL_MUT_FILE:-}" ]]; then    # mutation hook (tests/test_validation_mutants.sh group "policy")
  _mf="${GW_TREE}/lib/${POL_MUT_FILE}"; rm -f -- "${_mf:?}"; cp "${LLMCTL_ROOT}/lib/${POL_MUT_FILE}" "${_mf}"
  python3 -I - "${_mf}" "${POL_MUT_OLD}" "${POL_MUT_NEW}" <<'PY2'
import sys
f, old, new = sys.argv[1:4]
s = open(f).read()
if s.count(old) != 1: sys.exit("mutation anchor found %d times" % s.count(old))
open(f, "w").write(s.replace(old, new))
PY2
  echo "MUTANT applied to ${POL_MUT_FILE}"
fi
L="${GW_LLMCTL}"
P="$(gw_free_port)"

echo "== vision validate: FAIL stops the served profile"
gw_mark_running vision "${P}"; gw_calls_reset
rc="$(GW_VALIDATE_RC=1 gw_run "${L}" vision validate)"
assert_eq 1 "${rc}" "vision validate: FAIL -> exit 1"
assert_eq 1 "$(gw_count '^svc_stop vision')" "the served vision profile is stopped"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/vision.run" "its reservation is removed"

echo "== vision validate: UNDETERMINED keeps it running, NOT validated"
gw_mark_running vision "${P}"; gw_calls_reset
rc="$(GW_VALIDATE_RC=2 gw_run "${L}" vision validate)"
assert_eq 2 "${rc}" "vision validate: UNDETERMINED -> exit 2"
assert_eq 0 "$(gw_count '^svc_stop vision')" "not stopped"
assert_contains "$(gw_out)" "NOT validated" "says it keeps running NOT validated"
rm -f "${LLMCTL_RUNTIME_DIR}/vision.run" "${GW_ACTIVE_DIR}/vision"

echo "== vision validate --host: an external endpoint never touches the local profile"
gw_mark_running vision "${P}"; gw_calls_reset
rc="$(GW_VALIDATE_RC=1 gw_run "${L}" vision validate --host "http://127.0.0.1:${P}")"
assert_eq 0 "$(gw_count '^svc_stop vision')" "--host FAIL: the local profile is untouched"
rm -f "${LLMCTL_RUNTIME_DIR}/vision.run" "${GW_ACTIVE_DIR}/vision"

echo "== validate-all: the FAILING served profile is stopped, the passing one keeps serving"
P2="$(gw_free_port)"
gw_mark_running small "${P}"; gw_mark_running fast "${P2}"; gw_calls_reset
rc="$(GW_VALIDATE_RC_small=1 GW_VALIDATE_RC_fast=0 gw_run "${L}" validate-all)"
assert_eq 1 "${rc}" "validate-all: one FAIL -> exit 1"
assert_eq 1 "$(gw_count '^svc_stop small')" "the failing profile is stopped"
assert_eq 0 "$(gw_count '^svc_stop fast')" "the passing profile is not"
assert_file_absent "${LLMCTL_RUNTIME_DIR}/small.run" "the failing profile's reservation is removed"
rm -f "${LLMCTL_RUNTIME_DIR}"/*.run; rm -f "${GW_ACTIVE_DIR}"/*

echo "== models verify of a running profile: a FAIL stops it"
# make the checksum half pass: small's placeholder files get bytes (an empty file is refused) and the test catalog pins
# them to their real size and sha256
for _f in "${LLMCTL_MODELS_DIR}/small"/*; do printf 'placeholder bytes\n' > "${_f}"; done
python3 -I - "${LLMCTL_CATALOG}" "${LLMCTL_MODELS_DIR}/small" <<'PY'
import hashlib, json, os, sys
cat, d = sys.argv[1:3]
c = json.load(open(cat))
for f in c["profiles"]["small"]["files"]:
    p = os.path.join(d, f["name"])
    f["size"] = os.path.getsize(p)
    f["sha256"] = hashlib.sha256(open(p, "rb").read()).hexdigest()
json.dump(c, open(cat, "w"))
PY
gw_mark_running small "${P}"; gw_calls_reset
rc="$(GW_VALIDATE_RC=1 gw_run "${L}" models verify small)"
assert_contains "$(gw_out)" "passed checksum verification" "setup: the checksum half passes"
assert_eq 1 "${rc}" "models verify: FAIL -> exit 1"
assert_eq 1 "$(gw_count '^svc_stop small')" "the served profile is stopped"
test_finish
