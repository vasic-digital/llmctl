#!/usr/bin/env bash
# test_cluster_header_signal.sh - class sweep 2026-10-22 (C10 temp leak): the bearer token handed to curl by lib/cluster.sh must
# not survive on disk when the calling shell is killed by a signal mid-request (the old header file was removed on normal
# return only). Real code path: _cluster_curl from lib/cluster.sh, a fake curl that blocks (so the signal arrives mid-request).
# Control needle: a planted file named like the old header file is detected by the same scan (the scan can see).
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
BIN="${TEST_TMP}/bin"; PT="${TEST_TMP}/tmp"; mkdir -p "${BIN}" "${PT}"
cat >"${BIN}/curl" <<'FAKE'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "curl 8.99.0 (fake)"; echo "Features: HTTP2 HTTP3 SSL"; exit 0; }
hdr=""; prev=""
for a in "$@"; do [[ "$prev" == "-H" && "$a" == @* ]] && hdr="${a#@}"; prev="$a"; done
cat "${hdr}" >"${FAKE_SEEN}" 2>/dev/null || true
: >"${FAKE_READY}"; echo $$ >"${FAKE_PID}"
exec sleep 30
FAKE
chmod +x "${BIN}/curl"
export FAKE_PID="${TEST_TMP}/pid" FAKE_SEEN="${TEST_TMP}/seen" FAKE_READY="${TEST_TMP}/ready"

scan() { grep -rl "tok-SECRET-SIG" "${PT}" 2>/dev/null | wc -l; }
printf 'tok-SECRET-SIG\n' >"${PT}/llmctl-hdr.PLANT"
assert_eq 1 "$(scan)" "control needle: the scan sees a planted token file"
rm -f "${PT}/llmctl-hdr.PLANT"

(
  export PATH="${BIN}:${PATH}" TMPDIR="${PT}" LLMCTL_CLUSTER_ENDPOINT="http://127.0.0.1:1" LLMCTL_CLUSTER_TOKEN="tok-SECRET-SIG"
  # shellcheck disable=SC1091
  source "${LLMCTL_ROOT}/lib/cluster.sh"
  _cluster_curl -s "http://127.0.0.1:1/x"
) &
SUB=$!
for _ in $(seq 1 100); do [[ -e "${FAKE_READY}" ]] && break; sleep 0.1; done
assert_eq yes "$([[ -e "${FAKE_READY}" ]] && echo yes || echo no)" "the fake curl is running (the request is in flight)"
assert_eq "Authorization: Bearer tok-SECRET-SIG" "$(cat "${FAKE_SEEN}" 2>/dev/null || true)" "curl received the Authorization header through -H @path"
kill -TERM "${SUB}" 2>/dev/null || true
for _ in $(seq 1 30); do kill -0 "${SUB}" 2>/dev/null || break; sleep 0.1; done
[[ -s "${FAKE_PID}" ]] && kill -TERM "$(cat "${FAKE_PID}")" 2>/dev/null || true
wait "${SUB}" 2>/dev/null || true
assert_eq 0 "$(scan)" "after SIGTERM no file under TMPDIR holds the bearer token"
assert_eq 0 "$(find "${PT}" -name 'llmctl-hdr.*' | wc -l)" "after SIGTERM no llmctl-hdr.* file remains"
test_finish
