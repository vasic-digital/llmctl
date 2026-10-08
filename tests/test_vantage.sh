#!/usr/bin/env bash
# test_vantage.sh - REAL integration test of the second network location
# (FR-064, FR-069, FR-073, FR-091, SC-013). Boots a REAL rootless container
# through the Containers submodule (llmctl-decide vantage up; the tests never
# run `podman run` by hand) and proves, from inside it:
#   * its source address differs from the host loopback (selfcheck, echo server)
#   * an HTTPS server on the host's non-loopback address is reachable and its
#     certificate verifies with the right CA and FAILS with a wrong CA
#   * a 127.0.0.1-only listener is NOT reachable while 0.0.0.0 is (FR-073)
#   * `down` leaves no containers, networks or state (podman ps -a / network ls)
# SKIPs, loudly and with the reason, ONLY when rootless podman cannot run
# containers here. Never fakes a pass.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

SKIP_REASON=""
command -v go >/dev/null 2>&1 || SKIP_REASON="go is not installed"
command -v podman >/dev/null 2>&1 || SKIP_REASON="podman is not installed"
command -v python3 >/dev/null 2>&1 || SKIP_REASON="python3 is not installed (JSON assertions)"
if [[ -n "${SKIP_REASON}" ]]; then
  echo "SKIP-SUITE: ${SKIP_REASON}"; test_teardown_env; exit 0
fi

BIN="${TEST_TMP}/bin"; mkdir -p "${BIN}" "${TEST_TMP}/fx"
( cd "${LLMCTL_ROOT}" \
  && go build -o "${BIN}/llmctl-decide" ./cmd/llmctl-decide \
  && go build -o "${BIN}/fixture" ./internal/vantage/internal/fixture \
  && CGO_ENABLED=0 go build -trimpath -o "${BIN}/vantage-probe" ./internal/vantage/cmd/vantage-probe )
export LLMCTL_VANTAGE_PROBE="${BIN}/vantage-probe"
V() { "${BIN}/llmctl-decide" vantage "$@"; }
jget() { python3 -c 'import json,sys; d=json.load(sys.stdin)
for k in sys.argv[1].split("."): d=d[int(k)] if k.isdigit() else d[k]
print(str(d).lower() if isinstance(d,bool) else d)' "$1"; }
vantage_objects() { { podman ps -a --format '{{.Names}}'; podman network ls --format '{{.Name}}'; } 2>/dev/null | grep -c '^llmctl-vantage-' || true; }

FX_PID=""
cleanup() {
  [[ -n "${FX_PID}" ]] && kill "${FX_PID}" 2>/dev/null || true
  exec 7>&- 2>/dev/null || true
  V down >/dev/null 2>&1 || true
  test_teardown_env
}
trap cleanup EXIT

# G-085: `vantage up` is offline (--pull=never) and needs ONE locally cached candidate image. When rootless
# podman works but none is cached, `up` exits 1 with "no usable local image": that is a missing PREREQUISITE,
# not a defect, so the suite SKIPs (never passes) naming the images tried and the exact command to run.
# C3-17: the classifier lives in tests/vantage_classifier.sh and is SELF-CHECKED (a positive and a negative sample) silently
# BEFORE it is used to decide a SKIP - a classifier that regressed to match-everything would otherwise turn any rc=1 `up`
# failure into a SKIP on exactly the hosts that skip. (tests/run_tests.sh honours SKIP-SUITE only when no assertion line
# precedes it, so the self-check cannot print `  ok:` lines yet; it prints them after `up`, below.)
source "${LLMCTL_ROOT}/tests/vantage_classifier.sh"
vantage_classifier_selfcheck || { test_teardown_env; exit 1; }
NETS_BEFORE="$(podman network ls --format '{{.Name}}' | sort | tr '\n' ' ')"
echo "== up (rootless, through the Containers submodule) =="
set +e; UP="$(V up 2>"${TEST_TMP}/up.err")"; UPRC=$?; set -e
if [[ ${UPRC} -eq 3 ]]; then
  skip_suite "rootless containers unavailable: $(head -c 300 "${TEST_TMP}/up.err" | tr '\n' ' ')"
fi
if [[ ${UPRC} -eq 1 ]] && reason="$(no_image_skip_reason "$(cat "${TEST_TMP}/up.err")")"; then
  skip_suite "${reason}"
fi
# the (already silent) self-check, now stated as assertions
CANNED="${VANTAGE_CANNED_NOIMAGE}"
r="$(no_image_skip_reason "${CANNED}")" && rcc=0 || rcc=$?
assert_eq 0 "${rcc}" "no-image stderr is classified as a missing prerequisite"
assert_contains "${r}" "gcr.io/distroless/static-debian12:nonroot docker.io/library/alpine:3.20" "skip reason names every image tried"
assert_contains "${r}" "podman pull docker.io/library/alpine:3.20" "skip reason carries the exact pull command"
no_image_skip_reason "${VANTAGE_CANNED_OTHER}" >/dev/null && rcc=0 || rcc=$?
assert_eq 1 "${rcc}" "any other 'up' failure is NOT a skip (stays a FAIL)"

assert_eq 0 "${UPRC}" "vantage up succeeds ($(head -c 300 "${TEST_TMP}/up.err"))"
[[ ${UPRC} -eq 0 ]] || { echo "test_vantage: FAIL (up)" >&2; exit 1; }
NAME="$(echo "${UP}" | jget name)"; CIP="$(echo "${UP}" | jget ip)"; HIP="$(echo "${UP}" | jget host_ip)"
GW="$(echo "${UP}" | jget gateway)"; NET="$(echo "${UP}" | jget network)"; IMG="$(echo "${UP}" | jget image)"
echo "  vantage ${NAME} image=${IMG} network=${NET} ip=${CIP} gateway=${GW} host_ip=${HIP}"
assert_contains "${NAME}" "llmctl-vantage-" "container carries the llmctl-vantage- prefix"
assert_eq "slirp4netns" "${NET}" "default rootless network mode is slirp4netns (pasta is not a distinct vantage)"
[[ "${CIP}" != 127.* && "${CIP}" != "${HIP}" ]] && r=distinct || r=SAME
assert_eq distinct "${r}" "container address (${CIP}) is neither loopback nor the host address (${HIP})"
assert_eq 700 "$(stat -c %a "${LLMCTL_STATE_DIR}/vantage")" "vantage state dir is 0700"
assert_eq true "$(V status | jget up)" "status reports up"
assert_eq 1 "$(podman ps --filter "name=${NAME}" --format '{{.Names}}' | grep -c "^${NAME}$")" "container really runs (podman ps)"
MEM="$(podman inspect --format '{{.HostConfig.Memory}}' "${NAME}")"
assert_eq 67108864 "${MEM}" "container is memory-limited to 64m"

echo "== selfcheck: source address differs from the host loopback =="
set +e; SC="$(V --selfcheck)"; SCRC=$?; set -e
assert_eq 0 "${SCRC}" "selfcheck exits 0"
assert_eq true "$(echo "${SC}" | jget ok)" "selfcheck passes"
OBS="$(echo "${SC}" | jget server_observed_peer)"
echo "  echo server on ${HIP} observed peer ${OBS}; container source $(echo "${SC}" | jget container_local_addr)"
case "${OBS}" in 127.*|"") assert_eq "non-loopback" "${OBS}" "server-observed peer is not loopback";; *) assert_eq ok ok "server-observed peer ${OBS} is not loopback";; esac

echo "== exec runs inside the container =="
assert_contains "$(V exec -- /vantage/vantage-probe info)" "\"${CIP}\"" "exec shows the container's own address"

echo "== HTTPS from the second vantage =="
mkfifo "${TEST_TMP}/fx/stdin"
"${BIN}/fixture" -dir "${TEST_TMP}/fx" -ip "${HIP}" < "${TEST_TMP}/fx/stdin" > "${TEST_TMP}/fx/out" 2>"${TEST_TMP}/fx/err" &
FX_PID=$!; exec 7>"${TEST_TMP}/fx/stdin"
for _ in $(seq 1 50); do grep -q '^READY' "${TEST_TMP}/fx/out" 2>/dev/null && break; sleep 0.1; done
read -r _ URL LOPORT WPORT < "${TEST_TMP}/fx/out"
assert_contains "${URL}" "https://${HIP}:" "fixture HTTPS server is bound on the non-loopback host address"
R="$(V probe --url "${URL}/ok" --cacert "${TEST_TMP}/fx/ca.pem" --expect-status 200)"; rc=$?
assert_eq 0 "${rc}" "probe with the right CA exits 0"
assert_eq true "$(echo "${R}" | jget tls_verified)" "TLS verified inside the container with the right CA"
assert_eq 200 "$(echo "${R}" | jget status)" "status 200 over HTTPS from the second vantage"
assert_contains "$(echo "${R}" | jget body)" "ok from ${HIP}" "server saw the call arrive from the host address (not container loopback)"
assert_eq "${CIP}" "$(echo "${R}" | jget local_addr | cut -d: -f1)" "call used the container's own source address"
set +e; W="$(V probe --url "${URL}/ok" --cacert "${TEST_TMP}/fx/wrong-ca.pem")"; rc=$?; set -e
assert_eq 1 "${rc}" "probe with the WRONG CA exits 1"
assert_eq false "$(echo "${W}" | jget tls_verified)" "TLS verification FAILS with the wrong CA"
assert_eq tls_verify "$(echo "${W}" | jget error_class)" "failure is classified tls_verify"
assert_rc 0 "wrong CA with --expect-tls-failure is the expected outcome" V probe --url "${URL}/ok" --cacert "${TEST_TMP}/fx/wrong-ca.pem" --expect-tls-failure
set +e; V probe --url "${URL}/ok" --expect-tls-failure >/dev/null 2>&1; rc=$?; set -e
assert_eq 0 "${rc}" "no CA at all also fails verification (expected failure)"
assert_rc 0 "401 path with --expect-status 401" V probe --url "${URL}/unauthorized" --cacert "${TEST_TMP}/fx/ca.pem" --expect-status 401
assert_rc 1 "wrong expected status is reported" V probe --url "${URL}/ok" --cacert "${TEST_TMP}/fx/ca.pem" --expect-status 404
assert_rc 1 "a valid-CA call to a closed port fails" V probe --url "https://${HIP}:1/" --cacert "${TEST_TMP}/fx/ca.pem" --timeout 2s

echo "== FR-073: loopback-only listener is unreachable, wildcard reachable =="
HOST_LO="$(python3 - "$LOPORT" <<'PY'
import socket,sys
s=socket.create_connection(("127.0.0.1",int(sys.argv[1])),2); print("open")
PY
)"
assert_eq open "${HOST_LO}" "control: the 127.0.0.1 listener IS reachable from the host itself"
PP="$(V probe-ports --host-ip "${HIP}" --ports "${LOPORT},${WPORT}")"
assert_eq False "$(echo "${PP}" | python3 -c 'import json,sys;d=json.load(sys.stdin);print([r["reachable"] for r in d["results"] if r["port"]==int(sys.argv[1])][0])' "${LOPORT}")" "127.0.0.1-only port ${LOPORT} is NOT reachable from the second vantage"
assert_eq True "$(echo "${PP}" | python3 -c 'import json,sys;d=json.load(sys.stdin);print([r["reachable"] for r in d["results"] if r["port"]==int(sys.argv[1])][0])' "${WPORT}")" "0.0.0.0 port ${WPORT} IS reachable from the second vantage"
assert_eq "[${WPORT}]" "$(echo "${PP}" | jget reachable | tr -d ' ')" "reachable set is exactly the wildcard port"

echo "== down leaves nothing behind =="
V down >/dev/null; assert_eq 0 "$?" "down succeeds"
V down >/dev/null; assert_eq 0 "$?" "down is idempotent"
assert_eq 0 "$(vantage_objects)" "no llmctl-vantage- container or network remains (podman ps -a / network ls)"
# Networks other projects create or remove on this shared host while the test runs are none of our
# business (comparing the whole list made this assertion flaky, G-079): the property is that the vantage
# left NO NEW network behind.
NETS_AFTER="$(podman network ls --format '{{.Name}}' | sort | tr '\n' ' ')"
NEW_NETS="$(comm -13 <(tr ' ' '\n' <<<"${NETS_BEFORE}" | sort) <(tr ' ' '\n' <<<"${NETS_AFTER}" | sort) | tr '\n' ' ')"
assert_eq "" "${NEW_NETS}" "no network created by the vantage is left behind"
assert_file_absent "${LLMCTL_STATE_DIR}/vantage/state.json" "state file removed"
assert_eq false "$(V status | jget up 2>/dev/null || echo false)" "status reports down"

if [[ ${TEST_FAILS} -gt 0 ]]; then echo "test_vantage: ${TEST_FAILS} FAILED" >&2; exit 1; fi
echo "test_vantage: PASS"
