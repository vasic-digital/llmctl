#!/usr/bin/env bash
# test_service_ops_hardening.sh - the operational shell layer around the service units
# (review-2 scope C): tenant-mode registry live set (C-05), dry-run safety of the gateway
# disable (C-12), launchd respawn re-registration through `svc_hook.sh run-engine` (C-13),
# key-directory permissions (C-14), systemd quoting of units (C-18), and stale installed units
# (G-067).
#
# Stand-ins (on purpose, and only for the OS service manager): `systemctl` is a tiny script that
# answers is-active / show MainPID for named units and records every call; the registry, the
# Go binary, the hook scripts and the generated unit text are the real ones. The quoting proof
# additionally goes through a real transient systemd unit when a user manager is reachable.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

command -v python3 >/dev/null 2>&1 || { echo "SKIP-SUITE: python3 not installed"; exit 0; }
command -v go >/dev/null 2>&1 || { echo "SKIP-SUITE: go not installed"; exit 0; }

BIN="${TEST_TMP}/bin/llmctl-decide"
mkdir -p "${TEST_TMP}/bin" "${TEST_TMP}/fakebin"
( cd "${LLMCTL_ROOT}" && go build -o "${BIN}" ./cmd/llmctl-decide )

PIDS=()
cleanup() {
  local p
  for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "${p}" 2>/dev/null || true; done
  test_teardown_env
}
trap cleanup EXIT

# ---- the fake service manager ---------------------------------------------------------------
cat > "${TEST_TMP}/fakebin/systemctl" <<'EOF'
#!/usr/bin/env bash
# fake systemctl --user: UNITS_ACTIVE lists "unit=pid" pairs; every call is recorded.
echo "$*" >> "${FAKE_SYSTEMCTL_LOG}"
shift                                   # --user
case "$1" in
  is-active) unit="${@: -1}"; grep -q "^${unit}=" "${UNITS_ACTIVE}" ;;
  show)      unit="${@: -1}"; sed -n "s/^${unit}=//p" "${UNITS_ACTIVE}" | head -1 ;;
  *)         exit 0 ;;
esac
EOF
chmod +x "${TEST_TMP}/fakebin/systemctl"
export FAKE_SYSTEMCTL_LOG="${TEST_TMP}/systemctl.log" UNITS_ACTIVE="${TEST_TMP}/units_active"
: > "${FAKE_SYSTEMCTL_LOG}"

mk_env() { # mk_env <instance-key> <engine>
  printf 'LLMCTL_PROFILE=x\nLLMCTL_ENGINE=%s\nLLMCTL_EXEC=/bin/true\nLLMCTL_ARGS=\n' "$2" > "${LLMCTL_SERVICES_DIR}/$1.env"
}

echo "== C-05. tenant mode: the doctor's live set names the registered instance keys =="
mkdir -p "${LLMCTL_SERVICES_DIR}"
mk_env "acme--small" llama; mk_env "acme--fast" llama; mk_env "other--small" llama; mk_env "plain" llama
sleep 300 & SLEEP_PID=$!; PIDS+=("${SLEEP_PID}")
printf 'llmctl-llama@acme--small.service=%s\n' "${SLEEP_PID}" > "${UNITS_ACTIVE}"
out="$(
  export LLMCTL_TENANT_ID=acme PATH="${TEST_TMP}/fakebin:${PATH}" LLMCTL_DRY_RUN=0
  source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_linux.sh"
  printf 'PROFILES=%s\n' "$(svc_known_profiles | paste -sd, -)"
  printf 'UNIT=%s\n' "$(_svc_unit_for small)"
  printf 'LIVE=%s\n' "$(portreg_live_set)"
)"
assert_contains "${out}" "PROFILES=fast,small" "svc_known_profiles lists this tenant's PROFILE names only (not other--small, not plain)"
assert_contains "${out}" "UNIT=llmctl-llama@acme--small.service" "the unit name carries the tenant prefix exactly once"
assert_contains "${out}" "LIVE=acme--small=${SLEEP_PID}" "the live set reports the active tenant service under its registered instance key"
if grep -q 'acme--acme--' "${FAKE_SYSTEMCTL_LOG}"; then
  printf '  FAIL: the tenant prefix was applied twice (acme--acme--...)\n' >&2; TEST_FAILS=$((TEST_FAILS+1))
else printf '  ok: no systemctl call used a doubled tenant prefix\n'; fi
# against the REAL registry: registry == live set, in tenant mode, in both directions
export LLMCTL_PORTREG=1 LLMCTL_DECIDE_BIN="${BIN}"
"${BIN}" registry register acme--small --port 45671 --pid "${SLEEP_PID}" --token sleep --protocol tcp --kind chat --profile small >/dev/null
rc=0; rep="$(
  export LLMCTL_TENANT_ID=acme PATH="${TEST_TMP}/fakebin:${PATH}"
  source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_linux.sh"
  portreg_diff_report
)" || rc=$?
assert_eq 0 "${rc}" "tenant mode: the registry row equals the live service (doctor would PASS)"
assert_contains "${rep}" "registry == live set" "...and says so"
# C2-03: ANOTHER tenant's row (and a non-tenant one) in the same shared registry must not make this tenant's doctor FAIL
"${BIN}" registry register other--small --port 45672 --pid "${SLEEP_PID}" --token sleep --protocol tcp --kind chat --profile small >/dev/null
rc=0; rep="$(
  export LLMCTL_TENANT_ID=acme PATH="${TEST_TMP}/fakebin:${PATH}"
  source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_linux.sh"
  portreg_diff_report
)" || rc=$?
assert_eq 0 "${rc}" "C2-03: tenant acme's diff ignores tenant other's registry row (no false doctor FAIL)"
assert_contains "${rep}" "registry == live set" "C2-03: ...and says so with two tenants registered"
# the scope is not a blanket pass: an own row without a live service is still reported
"${BIN}" registry register acme--ghost --port 45673 --pid "${SLEEP_PID}" --token sleep --protocol tcp --kind chat --profile ghost >/dev/null
rc=0; rep="$(
  export LLMCTL_TENANT_ID=acme PATH="${TEST_TMP}/fakebin:${PATH}"
  source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_linux.sh"
  portreg_diff_report
)" || rc=$?
assert_eq 1 "${rc}" "C2-03 control: tenant acme's OWN stale row is still a diff failure"
assert_contains "${rep}" "acme--ghost" "C2-03 control: ...naming it"
"${BIN}" registry unregister acme--ghost >/dev/null
# no tenant: the tenant rows belong to the tenants, not to this backend
rc=0; rep="$(
  unset LLMCTL_TENANT_ID; export PATH="${TEST_TMP}/fakebin:${PATH}"
  source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_linux.sh"
  portreg_diff_report
)" || rc=$?
assert_eq 0 "${rc}" "C2-03: a non-tenant diff ignores every <tenant>--<profile> row"
"${BIN}" registry unregister other--small >/dev/null
"${BIN}" registry unregister acme--small >/dev/null
rc=0; rep="$(
  export LLMCTL_TENANT_ID=acme PATH="${TEST_TMP}/fakebin:${PATH}"
  source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_linux.sh"
  portreg_diff_report
)" || rc=$?
assert_eq 1 "${rc}" "tenant mode: a live service without a row is still reported (control: the check can fail)"
assert_contains "${rep}" "live service without a registry row: acme--small" "...naming the instance key"
unset LLMCTL_PORTREG LLMCTL_DECIDE_BIN

echo "== C-12. a dry run of the gateway disable leaves the real unit/agent file alone =="
mkdir -p "${LLMCTL_UNIT_DIR}" "${LLMCTL_PLIST_DIR}"
echo "[Unit]" > "${LLMCTL_UNIT_DIR}/llmctl-decide-gateway.service"
( export LLMCTL_DRY_RUN=1; source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_linux.sh"; decide_service_disable ) >/dev/null 2>&1
assert_file_exists "${LLMCTL_UNIT_DIR}/llmctl-decide-gateway.service" "linux: --dry-run decide disable did NOT delete the unit file"
echo "<plist/>" > "${LLMCTL_PLIST_DIR}/com.llmctl.decide-gateway.plist"
( export LLMCTL_DRY_RUN=1; source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_macos.sh"; decide_service_disable ) >/dev/null 2>&1
assert_file_exists "${LLMCTL_PLIST_DIR}/com.llmctl.decide-gateway.plist" "macOS: --dry-run decide disable did NOT delete the agent plist"
( export LLMCTL_DRY_RUN=0 PATH="${TEST_TMP}/fakebin:${PATH}"; source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_linux.sh"; decide_service_disable ) >/dev/null 2>&1
assert_file_absent "${LLMCTL_UNIT_DIR}/llmctl-decide-gateway.service" "linux: a real disable removes the unit (control)"

echo "== C2-07 (shell side). portreg_register retries ONLY the 'not (yet) running' refusal, for a bounded time =="
FAKEREG="${TEST_TMP}/fakereg"; mkdir -p "${FAKEREG}"
cat > "${FAKEREG}/llmctl-decide" <<'EOF'
#!/usr/bin/env bash
n=$(( $(cat "${FAKEREG_COUNT}" 2>/dev/null || echo 0) + 1 )); echo "${n}" > "${FAKEREG_COUNT}"
if [[ "${FAKEREG_MODE}" == early && "${n}" -lt 3 ]]; then echo "pid 5 is not (yet) running \"llama-server\": register after the process has exec'd" >&2; exit 2; fi
if [[ "${FAKEREG_MODE}" == other ]]; then echo "port 1 is already registered" >&2; exit 1; fi
if [[ "${FAKEREG_MODE}" == never ]]; then echo "pid 5 is not (yet) running \"llama-server\": register after the process has exec'd" >&2; exit 2; fi
exit 0
EOF
chmod +x "${FAKEREG}/llmctl-decide"
reg_try() { # reg_try <mode> <wait> -> prints "rc=<n> calls=<n>"
  local rc=0; : > "${FAKEREG}/count"
  ( export LLMCTL_DECIDE_BIN="${FAKEREG}/llmctl-decide" LLMCTL_PORTREG=1 FAKEREG_MODE="$1" FAKEREG_COUNT="${FAKEREG}/count" LLMCTL_REGISTER_IDENTITY_WAIT="$2"
    source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/portreg.sh"
    portreg_register svc 1234 5 llama-server http /health chat p i 1 ) >/dev/null 2>&1 || rc=$?
  printf 'rc=%s calls=%s' "${rc}" "$(cat "${FAKEREG}/count")"
}
assert_eq "rc=0 calls=3" "$(reg_try early 10)" "C2-07: an early publish ('not yet running') is retried until the pid has exec'd, then succeeds"
assert_eq "rc=1 calls=1" "$(reg_try other 10)" "C2-07: any OTHER registry failure is reported at once (no retry), rc preserved"
assert_eq "rc=2 calls=3" "$(reg_try never 2)" "C2-07: a pid that never becomes the program stops retrying after the bounded wait, rc preserved"

echo "== C-18. units quote paths with spaces / % / quotes the way systemd reads them =="
QROOT="${TEST_TMP}/ro ot %x\"q"
mkdir -p "${QROOT}"
gen() ( # gen <unit-dir> : svc_install in dry-run with awkward state paths
  export LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json" LLMCTL_UNIT_DIR="$1"
  export LLMCTL_STATE_DIR="${QROOT}/state" LLMCTL_LOG_DIR="${QROOT}/log %l" LLMCTL_SERVICES_DIR="${QROOT}/serv ices"
  source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/os_detect.sh"
  source "${LLMCTL_ROOT}/lib/hardware.sh"; source "${LLMCTL_ROOT}/lib/service_linux.sh"
  svc_install
) >/dev/null 2>&1
gen "${TEST_TMP}/q-units"
QU="${TEST_TMP}/q-units/llmctl-llama@.service"
assert_file_contains "${QU}" 'Environment="LLMCTL_SERVICES_DIR='"${TEST_TMP}"'/ro ot %%x\"q/serv ices"' "Environment= value is ONE quoted word (a space no longer splits it; % doubled, \" escaped)"
if grep -qF 'log %%l' "${QU}" && grep -qF 'append:'"${TEST_TMP}"'/ro ot %%x"q/log %%l/%i.log' "${QU}"; then
  printf '  ok: a %% in a path is doubled (specifier-safe)\n'
else printf '  FAIL: a %% in a path is not doubled\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
if grep -qF '%%x\"q' "${QU}"; then printf '  ok: an embedded double quote is escaped\n'; else printf '  FAIL: embedded " not escaped\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
assert_file_contains "${QU}" 'ExecStartPre=/bin/bash "'"${LLMCTL_ROOT}"'/lib/svc_hook.sh" prestart %i' "the hook script path is one quoted word"
# C2-12: systemd expands $VAR / ${VAR} inside ExecStart= words (even double-quoted); a literal `$` is written `$$`.
# Environment= values are NOT expanded that way, so there `$` stays single.
hookline="$( source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_linux.sh"; _svl_dir='/opt/ro$HOME ot/${X}/lib'; _svc_hook_cmd prestart %i )"
assert_eq '/bin/bash "/opt/ro$$HOME ot/$${X}/lib/svc_hook.sh" prestart %i' "${hookline}" "C2-12: \$ in the hook path is doubled in an ExecStart word (a real argument containing \$HOME and \${X})"
envline="$( source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_linux.sh"; _svc_env LLMCTL_ROOT '/opt/ro$HOME ot' )"
assert_eq 'Environment="LLMCTL_ROOT=/opt/ro$HOME ot"' "${envline}" "C2-12 control: \$ is NOT doubled in Environment= (systemd does not expand it there)"
if command -v systemd-run >/dev/null 2>&1 && systemd-run --user --wait --pipe --quiet --collect /bin/true >/dev/null 2>&1; then
  # (the % doubling is asserted textually above, per systemd.unit(5): a transient unit's properties
  # skip specifier expansion, so % cannot be read back through systemd-run)
  val="$(source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_linux.sh"; _svc_env PROBE_VAR 'a b "q" \z')"
  got="$(systemd-run --user --wait --pipe --quiet --collect -p "${val}" /usr/bin/env 2>&1 | sed -n 's/^PROBE_VAR=//p')"
  assert_eq 'a b "q" \z' "${got}" "a real systemd unit reads _svc_env's value back byte for byte (space, quotes, backslash)"
else
  assert_skip "no reachable systemd --user manager" "live systemd read-back of the quoted Environment= value"
fi
if command -v systemd-analyze >/dev/null 2>&1; then
  vout="$(systemd-analyze --user verify "${QU}" 2>&1 || true)"
  if grep -E "llmctl-llama@\.service" <<<"${vout}" | grep -qiE "invalid|failed to parse|unbalanced|missing"; then
    printf '  FAIL: systemd-analyze verify rejects the generated unit:\n%s\n' "${vout}" >&2; TEST_FAILS=$((TEST_FAILS+1))
  else printf '  ok: systemd-analyze verify accepts the unit generated with awkward paths\n'; fi
fi

echo "== G-067. a unit installed by an earlier llmctl is flagged, and 'llmctl install' regenerates it =="
SU="${TEST_TMP}/stale-units"; mkdir -p "${SU}"
cat > "${SU}/llmctl-llama@.service" <<'EOF'
[Unit]
Description=old
[Service]
Type=simple
StartLimitBurst=5
StartLimitIntervalSec=60
ExecStart=/bin/true
EOF
cp "${SU}/llmctl-llama@.service" "${SU}/llmctl-decide-gateway.service"   # an installed, stale gateway unit too
stale="$( export LLMCTL_UNIT_DIR="${SU}"; source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_linux.sh"; svc_stale_units )"
assert_contains "${stale}" "llmctl-llama@.service" "svc_stale_units names the stale unit"
assert_contains "${stale}" "llmctl install" "...with the remedy"
doc="$(export LLMCTL_UNIT_DIR="${SU}" LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"; bash "${LLMCTL_ROOT}/bin/llmctl" doctor 2>&1 || true)"
assert_contains "${doc}" "stale service unit(s):" "llmctl doctor WARNs about the stale units"
assert_contains "${doc}" "llmctl-llama@.service" "...naming the engine template"
assert_contains "${doc}" "llmctl-decide-gateway.service" "...and the gateway unit"
( export LLMCTL_UNIT_DIR="${SU}" LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json" LLMCTL_DECIDE_BIN="${BIN}"; bash "${LLMCTL_ROOT}/bin/llmctl" install ) >/dev/null 2>&1
assert_file_contains "${SU}/llmctl-decide-gateway.service" 'svc_hook.sh" run-gateway' "...the installed gateway unit was regenerated too (current body, not the stale one)"
stale2="$( export LLMCTL_UNIT_DIR="${SU}"; source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_linux.sh"; svc_stale_units )"
assert_eq "" "${stale2}" "after 'llmctl install' no unit is stale"
assert_file_contains "${SU}/llmctl-llama@.service" "ExecStartPre=" "...and the regenerated unit has the current body (hooks present)"
doc2="$(export LLMCTL_UNIT_DIR="${SU}" LLMCTL_DRY_RUN=1 LLMCTL_FAKE_HW="${LLMCTL_ROOT}/tests/fixtures/hw-baseline.json"; bash "${LLMCTL_ROOT}/bin/llmctl" doctor 2>&1 || true)"
if grep -q "stale service unit" <<<"${doc2}"; then printf '  FAIL: doctor still warns after the regeneration\n' >&2; TEST_FAILS=$((TEST_FAILS+1)); else printf '  ok: doctor no longer warns after the regeneration\n'; fi

# C2-11: the detector is not limited to the one historical defect - ANY directive the current generator writes
# that an installed unit lacks marks it stale (here: a unit from before the registry hooks / state-dir environment)
SU2="${TEST_TMP}/stale-units2"; mkdir -p "${SU2}"
cat > "${SU2}/llmctl-llama@.service" <<'EOF'
[Unit]
Description=old but without the StartLimit defect
StartLimitBurst=5
StartLimitIntervalSec=60
[Service]
Type=simple
EnvironmentFile=/x/%i.env
ExecStart=/bin/bash -c 'set -f; exec "$LLMCTL_EXEC" $LLMCTL_ARGS'
Restart=always
RestartSec=5
MemoryHigh=100M
MemoryMax=100M
[Install]
WantedBy=default.target
EOF
stale3="$( export LLMCTL_UNIT_DIR="${SU2}"; source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_linux.sh"; svc_stale_units )"
assert_contains "${stale3}" "llmctl-llama@.service" "C2-11: a unit that merely LACKS directives the generator now writes is flagged stale"
assert_contains "${stale3}" "ExecStartPre" "C2-11: ...naming the missing registry hook directive"
assert_contains "${stale3}" "Environment:LLMCTL_STATE_DIR" "C2-11: ...and the missing state-dir environment"
# no false positive (§11.4.201): a CURRENT unit whose VALUES differ (other memory limit, other description, other paths) is not stale
cur="$( export LLMCTL_UNIT_DIR="${TEST_TMP}/q-units"; source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_linux.sh"; svc_stale_units )"
assert_eq "" "${cur}" "C2-11 control: units generated by the current generator with awkward paths / other values are not stale"
sed -e 's/^MemoryMax=.*/MemoryMax=123M/' -e 's/^Description=.*/Description=edited description/' "${TEST_TMP}/q-units/llmctl-llama@.service" > "${SU2}/llmctl-colibri@.service"
rm -f "${SU2}/llmctl-llama@.service"
cur2="$( export LLMCTL_UNIT_DIR="${SU2}"; source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_linux.sh"; svc_stale_units )"
assert_eq "" "${cur2}" "C2-11 control: different directive VALUES (not names) do not make a unit stale"

echo "== G-074. rows that stay 'unknown' (https, no CA) are reported by the doctor, and can be pruned on request =="
sleep 300 & UNK_PID=$!; PIDS+=("${UNK_PID}")
export LLMCTL_PORTREG=1 LLMCTL_DECIDE_BIN="${BIN}"
unset LLMCTL_CACERT; export LLMCTL_HOME="${TEST_TMP}/no-ca-home"
"${BIN}" registry register unk-gw --port 45672 --pid "${UNK_PID}" --token sleep --protocol https --health-path /healthz --kind gateway --profile decide >/dev/null
rep="$("${BIN}" registry reconcile --grace 0s --port-grace 0s 2>&1)"
assert_contains "${rep}" "unknown unk-gw" "the https row without a CA is reported unknown (and kept)"
: > "${UNITS_ACTIVE}"
doc="$(PATH="${TEST_TMP}/fakebin:${PATH}" LLMCTL_DRY_RUN=0 bash "${LLMCTL_ROOT}/bin/llmctl" doctor 2>&1 || true)"
assert_contains "${doc}" "registry rows that cannot be certified" "llmctl doctor WARNs about the unknown row"
assert_contains "${doc}" "unk-gw" "...naming it"
assert_contains "${doc}" "--prune-unknown-after" "...with the opt-in remedy"
rep="$("${BIN}" registry reconcile --grace 0s --port-grace 0s --prune-unknown-after 24h 2>&1)"
assert_contains "${rep}" "unknown unk-gw" "--prune-unknown-after 24h keeps a row that has been unknown for seconds"
rep="$("${BIN}" registry reconcile --grace 0s --port-grace 0s --prune-unknown-after 1ns 2>&1)"
assert_contains "${rep}" "removed unk-gw" "--prune-unknown-after 1ns removes it, with the reason"
assert_contains "${rep}" "prune-unknown-after" "...the reason names the option"
"${BIN}" registry unregister unk-gw >/dev/null 2>&1 || true
unset LLMCTL_PORTREG LLMCTL_DECIDE_BIN LLMCTL_HOME

echo "== C-13/C-14. launchd respawn re-registers through 'svc_hook.sh run-engine'; the key hook owns only its directories =="
ENGINE="${TEST_TMP}/bin/fake-engine.py"
cat > "${ENGINE}" <<'EOF'
import http.server, sys
port = int(sys.argv[sys.argv.index("--port") + 1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
EOF
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
KEYHOME="${TEST_TMP}/someone-home"; mkdir -p "${KEYHOME}"; chmod 755 "${KEYHOME}"
KEYFILE="${KEYHOME}/onnx.key"
printf 'LLMCTL_PROFILE=eng\nLLMCTL_ENGINE=onnx\nLLMCTL_EXEC=python3\nLLMCTL_ARGS=\nLLMCTL_PORT=%s\nLLMCTL_REG_TOKEN=fake-engine.py\nLLMCTL_REG_KIND=decide\nLLMCTL_REG_PROTOCOL=http\nLLMCTL_REG_HEALTH=/health\nLLMCTL_REG_PROFILE=eng\nLLMCTL_REG_LOOPBACK=1\nLLMCTL_KEY_FILE=%s\n' \
  "${PORT}" "${KEYFILE}" > "${LLMCTL_SERVICES_DIR}/eng.env"
export LLMCTL_PORTREG=1 LLMCTL_DECIDE_BIN="${BIN}" LLMCTL_REGISTER_POLL=0.2 LLMCTL_REGISTER_WAIT=30
reg_pid() { "${BIN}" registry list --json | python3 -c 'import json,sys;print(next((s["pid"] for s in json.load(sys.stdin)["services"] if s["name"]=="eng"),""))'; }
spawn_engine() { # the launchd ProgramArguments, verbatim
  bash "${LLMCTL_ROOT}/lib/svc_hook.sh" run-engine eng -- python3 "${ENGINE}" --port "${PORT}" >/dev/null 2>&1 &
  ENG_PID=$!; PIDS+=("${ENG_PID}")
}
wait_row() { local want="$1"; for _ in $(seq 1 100); do [[ "$(reg_pid)" == "${want}" ]] && return 0; sleep 0.1; done; return 1; }
spawn_engine
rc=0; wait_row "${ENG_PID}" || rc=$?
assert_eq 0 "${rc}" "run-engine registers the engine under the pid that exec made the engine"
assert_eq "755" "$(stat -c %a "${KEYHOME}")" "C-14: the key file's pre-existing parent directory keeps its mode (not chmod 700)"
assert_eq "600" "$(stat -c %a "${KEYFILE}")" "C-14: the key file itself is 0600"
rep="$("${BIN}" registry reconcile --grace 0s --port-grace 0s 2>&1)"
assert_contains "${rep}" "1 healthy" "the registered engine survives a reconcile (process identity + start-time fingerprint hold after the exec)"
kill -9 "${ENG_PID}"; { wait "${ENG_PID}"; } 2>/dev/null || true; for _ in $(seq 1 50); do kill -0 "${ENG_PID}" 2>/dev/null || break; sleep 0.1; done
"${BIN}" registry reconcile --grace 0s --port-grace 0s >/dev/null 2>&1
assert_eq "" "$(reg_pid)" "after the crash the stale row is reconciled away"
OLD_PID="${ENG_PID}"
spawn_engine                                  # launchd KeepAlive respawn = the same ProgramArguments again
rc=0; wait_row "${ENG_PID}" || rc=$?
assert_eq 0 "${rc}" "C-13: the respawned engine re-registered itself (no 'llmctl start' needed)"
assert_eq "1" "$(( ENG_PID != OLD_PID ? 1 : 0 ))" "...under its NEW pid"
kill "${ENG_PID}" 2>/dev/null || true
# a directory llmctl creates is 0700; a state-dir keys directory is 0700
NEWDIR="${TEST_TMP}/fresh/keys-here"
printf 'LLMCTL_KEY_FILE=%s\n' "${NEWDIR}/k.key" > "${LLMCTL_SERVICES_DIR}/fresh.env"
bash "${LLMCTL_ROOT}/lib/svc_hook.sh" prestart fresh >/dev/null 2>&1
assert_eq "700" "$(stat -c %a "${NEWDIR}")" "a key directory created by the hook is 0700"
mkdir -p "${LLMCTL_STATE_DIR}/keys"; chmod 755 "${LLMCTL_STATE_DIR}/keys"
printf 'LLMCTL_KEY_FILE=%s\n' "${LLMCTL_STATE_DIR}/keys/own.key" > "${LLMCTL_SERVICES_DIR}/own.env"
bash "${LLMCTL_ROOT}/lib/svc_hook.sh" prestart own >/dev/null 2>&1
assert_eq "700" "$(stat -c %a "${LLMCTL_STATE_DIR}/keys")" "llmctl's own keys directory is tightened to 0700"
# the macOS plist of an engine is wrapped by the hook (the wrapper is what makes C-13 true in production)
( export LLMCTL_DRY_RUN=1; source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_macos.sh"
  svc_write_env eng llama /opt/llama-server --port 8081 --model /m.gguf ) >/dev/null 2>&1
PL="${LLMCTL_PLIST_DIR}/com.llmctl.eng.plist"
assert_file_contains "${PL}" "<string>run-engine</string>" "macOS plist: ProgramArguments go through svc_hook.sh run-engine"
assert_file_contains "${PL}" "<string>--</string>" "macOS plist: the engine command follows the -- separator"
assert_file_contains "${PL}" "<string>/opt/llama-server</string>" "macOS plist: the engine executable is still launched"

# --- G-129: the run-engine wrapper makes the engine resolve ITS OWN shared libraries first -------------------------
# A llama.cpp build is a shared-library build (RUNPATH into build/bin). RUNPATH ranks BELOW LD_LIBRARY_PATH, so a
# caller's LD_LIBRARY_PATH holding a system libggml.so.0 of another version wins and the engine dies with
# "undefined symbol ggml_flash_attn_ext_set_n_kv_max" (reproduced on this host, evidence/live/g129-ldd-repro.txt).
# The wrapper PREPENDS the engine's own directory (keeping the caller's other entries, e.g. CUDA) when that directory
# ships libggml*; an engine that ships none (colibri, python runners) is left untouched (golden-false).
ENGDIR="${TEST_TMP}/own-libs"; mkdir -p "${ENGDIR}" "${TEST_TMP}/plain-engine"
: > "${ENGDIR}/libggml.so.0"
printf '#!/bin/sh\nprintf "%%s|%%s\\n" "${LD_LIBRARY_PATH-UNSET}" "${DYLD_LIBRARY_PATH-UNSET}" > "$G129_OUT"\n' > "${ENGDIR}/llama-server"
cp "${ENGDIR}/llama-server" "${TEST_TMP}/plain-engine/engine"; chmod +x "${ENGDIR}/llama-server" "${TEST_TMP}/plain-engine/engine"
printf 'LLMCTL_PROFILE=g129\nLLMCTL_ENGINE=llama\n' > "${LLMCTL_SERVICES_DIR}/g129.env"
run_engine_env() { # <exe> <LD_LIBRARY_PATH or -> : prints what the engine saw
  local exe="$1" ld="$2" out="${TEST_TMP}/g129.out"; rm -f "${out}"
  if [[ "${ld}" == "-" ]]; then
    env -u LD_LIBRARY_PATH -u DYLD_LIBRARY_PATH G129_OUT="${out}" bash "${LLMCTL_ROOT}/lib/svc_hook.sh" run-engine g129 -- "${exe}" >/dev/null 2>&1 || true
  else
    env -u DYLD_LIBRARY_PATH LD_LIBRARY_PATH="${ld}" G129_OUT="${out}" bash "${LLMCTL_ROOT}/lib/svc_hook.sh" run-engine g129 -- "${exe}" >/dev/null 2>&1 || true
  fi
  cat "${out}" 2>/dev/null || echo "NO-OUTPUT"
}
if [[ "$(uname -s)" == "Darwin" ]]; then DYL_ONE="${ENGDIR}:/usr/lib/x86_64-linux-gnu"; DYL_NONE="${ENGDIR}"; else DYL_ONE="UNSET"; DYL_NONE="UNSET"; fi
assert_eq "${ENGDIR}:/usr/lib/x86_64-linux-gnu|${DYL_ONE}" "$(run_engine_env "${ENGDIR}/llama-server" /usr/lib/x86_64-linux-gnu)" \
  "G-129: the engine's own library directory is FIRST on the library path, the caller's entries are kept behind it"
assert_eq "${ENGDIR}|${DYL_NONE}" "$(run_engine_env "${ENGDIR}/llama-server" -)" "G-129: with no caller path the engine directory is the whole path"
assert_eq "/usr/lib/x86_64-linux-gnu|UNSET" "$(run_engine_env "${TEST_TMP}/plain-engine/engine" /usr/lib/x86_64-linux-gnu)" \
  "G-129 golden-false: an engine directory that ships no libggml* leaves the caller's path untouched"

# --- C3-08: the row-name grammar "<tenant>--<profile>" must be unambiguous --------------------------------------------
# Tenant ids may hold single dashes, so "acme--eu" / "acme-" would make "acme---small" / "acme--eu--small" ambiguous
# (which tenant owns it?) and a tenant-scoped doctor diff would leak across tenants. Such ids are refused.
tenant_ok() { ( source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_linux.sh"; _svc_validate_tenant_id "$1" ) >/dev/null 2>&1; }
for id in "acme--eu" "acme-" "a--" "x--y--z" "acme---"; do
  rc=0; tenant_ok "${id}" || rc=$?
  assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "C3-08: tenant id '${id}' is refused (it would make <tenant>--<profile> row names ambiguous)"
done
key_ok() { ( source "${LLMCTL_ROOT}/lib/common.sh"; source "${LLMCTL_ROOT}/lib/service_linux.sh"; LLMCTL_TENANT_ID="$1" _svc_instance_key "$2" ) >/dev/null 2>&1; }
rc=0; key_ok acme "a--b" || rc=$?
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "C3-08: a profile name holding '--' is refused when it would form a tenant row name"
rc=0; key_ok "" "qwen--7b" || rc=$?
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "C3-08: a NON-tenant profile name holding '--' is refused too (it would be a tenant-looking row)"
rc=0; key_ok acme "-b" || rc=$?
assert_eq 1 "$(( rc != 0 ? 1 : 0 ))" "C3-08: a profile name starting with '-' is refused when it would form a tenant row name"
rc=0; key_ok acme "qwen-7b-q4" || rc=$?
assert_eq 0 "${rc}" "C3-08 control: a profile name with single dashes forms a tenant row name"
for id in "acme" "acme-eu" "tenant-1" "Tenant.3" "a_b-c"; do
  rc=0; tenant_ok "${id}" || rc=$?
  assert_eq 0 "${rc}" "C3-08 control: tenant id '${id}' is still accepted"
done

test_finish
