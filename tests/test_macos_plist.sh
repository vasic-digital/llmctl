#!/usr/bin/env bash
# test_macos_plist.sh - the launchd plists lib/service_macos.sh writes (C2-04). No Mac is available, so this is a
# FILE-level proof, honestly: plutil is absent on Linux, so the plists are parsed with python's plistlib (a strict
# XML property-list reader) and the run-engine wrapper they name is EXECUTED here under `env -i` with ONLY the
# environment launchd would give it (the plist's EnvironmentVariables plus a minimal HOME/PATH).
# What this does NOT prove: that launchd itself accepts and runs the plist (needs macOS; tracked in the report).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
command -v python3 >/dev/null 2>&1 || { echo "SKIP-SUITE: python3 not installed"; exit 0; }

W="${TEST_TMP}/mac"; mkdir -p "${W}/bin"
# overridden state dirs (an '&', '<', '>' and a space in a path also prove the plist is valid XML: C3-07 - bash >= 5.2 broke '<' and '>')
export LLMCTL_STATE_DIR="${W}/st & x" LLMCTL_SERVICES_DIR="${W}/serv ices" LLMCTL_LOG_DIR="${W}/lo<g>s &q"
export LLMCTL_PLIST_DIR="${W}/agents" LLMCTL_DRY_RUN=1
printf '#!/bin/sh\nexit 0\n' > "${W}/bin/llmctl-decide"; chmod +x "${W}/bin/llmctl-decide"
export LLMCTL_DECIDE_BIN="${W}/bin/llmctl-decide"
KEYF="${W}/keys/onnx.key"; mkdir -p "$(dirname "${KEYF}")"; echo OLD-KEY-CONTENT > "${KEYF}"

( source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_macos.sh"
  svc_write_env small llama /bin/true --port 18081 --api-key-file "${KEYF}"
  _decide_gateway_write_plist >/dev/null ) >/dev/null 2>&1
ENG="${LLMCTL_PLIST_DIR}/com.llmctl.small.plist"; GW="${LLMCTL_PLIST_DIR}/com.llmctl.decide-gateway.plist"
assert_file_exists "${ENG}" "engine plist written"
assert_file_exists "${GW}" "gateway plist written"

pl() { python3 -I - "$1" "$2" <<'PY'
import plistlib, sys, json
d = plistlib.load(open(sys.argv[1], "rb"))
w = sys.argv[2]
if w == "env": print(json.dumps(d.get("EnvironmentVariables", {}), sort_keys=True))
elif w == "envkeys": print(" ".join(sorted(d.get("EnvironmentVariables", {}))))
elif w == "argv0": print("\0".join(d["ProgramArguments"]), end="")
elif w == "logpath": print(d["StandardOutPath"])
PY
}
rc=0; pl "${ENG}" envkeys >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "engine plist is a valid property list (python plistlib parse, incl. an '&' in a path)"
rc=0; pl "${GW}" envkeys >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "gateway plist is a valid property list"
assert_eq "$(pl "${GW}" envkeys)" "$(pl "${ENG}" envkeys)" "C2-04: the engine plist carries the SAME EnvironmentVariables keys as the gateway plist"
assert_contains "$(pl "${ENG}" envkeys)" "LLMCTL_SERVICES_DIR" "C2-04: ...including LLMCTL_SERVICES_DIR (where the hook finds the env record)"
assert_contains "$(pl "${ENG}" env)" "serv ices" "C2-04: ...with the operator's OVERRIDDEN value, not a default"
assert_eq "${LLMCTL_LOG_DIR}/small.log" "$(pl "${ENG}" logpath)" "engine StandardOutPath equals the log dir"

# Execute the wrapper exactly as launchd would: argv from the plist, environment from the plist only.
args=()
while IFS= read -r -d '' a; do args+=("$a"); done < <(pl "${ENG}" argv0)
assert_eq "/bin/bash" "${args[0]}" "ProgramArguments starts with /bin/bash"
assert_contains "${args[*]}" "run-engine small --" "...and is the run-engine wrapper for the profile"
envargs=()
while IFS= read -r kv; do envargs+=("$kv"); done < <(python3 -I -c '
import plistlib, sys
for k, v in plistlib.load(open(sys.argv[1], "rb"))["EnvironmentVariables"].items(): print("%s=%s" % (k, v))' "${ENG}")
# control (the pre-fix behaviour): WITHOUT the plist environment the wrapper falls back to default dirs, finds no env
# record, and rotates nothing - this is the failure mode C2-04 reported, shown to be real
echo OLD-KEY-CONTENT > "${KEYF}"
env -i HOME="${W}/home" PATH=/usr/bin:/bin "${args[@]}" >/dev/null 2>&1 || true
assert_eq "OLD-KEY-CONTENT" "$(cat "${KEYF}")" "C2-04 control: without the plist environment the key is NOT rotated (the reported failure mode)"
# with exactly the plist environment, the per-start key rotation happens
env -i HOME="${W}/home" PATH=/usr/bin:/bin "${envargs[@]}" "${args[@]}" >/dev/null 2>&1 || true
now="$(cat "${KEYF}")"
if [[ -n "${now}" && "${now}" != "OLD-KEY-CONTENT" ]]; then printf '  ok: C2-04: under the plist environment alone the wrapper rotated the key file\n'
else printf '  FAIL: C2-04: the key file was not rotated under the plist environment alone (%s)\n' "${now}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
assert_file_exists "${LLMCTL_LOG_DIR}/svc_hook.log" "C2-04: the hook logged into the OVERRIDDEN log dir"
test_finish
