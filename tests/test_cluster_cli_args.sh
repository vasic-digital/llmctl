#!/usr/bin/env bash
# test_cluster_cli_args.sh - G-106 (OD-21 / T131): lib/cluster.sh builds the
# right curl command for the mutual-TLS llmctld daemon.
#
# A fake `curl` on PATH records its argv (one argument per line), the content
# of any `-H @file` header file at call time, and answers like a daemon would.
# That proves the ARGUMENT CONSTRUCTION - trust anchor, client cert/key,
# transport selection, secret hygiene, and the absence of every
# verification-disabling switch. It does NOT exercise a real HTTP/3
# transport (this host's curl has none): the end-to-end TLS handshake with
# the same inputs is proven by the Go tests in llmctld/cmd/llmctld
# (TestCLIRoundTrip_*), and tests/test_cluster_join_leave.sh,
# test_apikey_lifecycle.sh and test_tenant_list_quota.sh run the real CLI
# against a real daemon whenever the host curl has the HTTP3 feature.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

# --- fake curl ------------------------------------------------------------
BIN="${TEST_TMP}/fakebin"; mkdir -p "${BIN}"
ARGV_LOG="${TEST_TMP}/argv.log"
HDR_LOG="${TEST_TMP}/hdr.log"
HDR_PATH_LOG="${TEST_TMP}/hdrpath.log"
cat >"${BIN}/curl" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "curl 8.99.0 (fake)"; echo "Features: HTTP2 HTTP3 SSL"; exit 0
fi
: >"${FAKE_ARGV_LOG}"; : >"${FAKE_HDR_LOG}"; : >"${FAKE_HDR_PATH_LOG}"
want_w=0; prev=""
for a in "$@"; do
  printf '%s\n' "$a" >>"${FAKE_ARGV_LOG}"
  if [[ "$prev" == "-H" && "$a" == @* ]]; then
    printf '%s\n' "${a#@}" >>"${FAKE_HDR_PATH_LOG}"
    cat "${a#@}" >>"${FAKE_HDR_LOG}" 2>/dev/null || true
  fi
  [[ "$a" == "-w" ]] && want_w=1
  prev="$a"
done
printf '{"ok":true}'
[[ "$want_w" == 1 ]] && printf '\n200'
exit 0
FAKE
chmod +x "${BIN}/curl"
export PATH="${BIN}:${PATH}"
export FAKE_ARGV_LOG="${ARGV_LOG}" FAKE_HDR_LOG="${HDR_LOG}" FAKE_HDR_PATH_LOG="${HDR_PATH_LOG}"

# --- CLI material on disk, shaped like `llmctld cluster bootstrap` writes ---
CERTS="${TEST_TMP}/cli"; mkdir -m 700 "${CERTS}"
printf 'CA\n' >"${CERTS}/ca.crt"; printf 'CERT\n' >"${CERTS}/client.crt"; printf 'KEYBYTES-SECRET\n' >"${CERTS}/client.key"
chmod 600 "${CERTS}/ca.crt" "${CERTS}/client.crt" "${CERTS}/client.key"

reset_env() {
  unset LLMCTL_CLUSTER_TOKEN LLMCTL_CLUSTER_CACERT LLMCTL_CLUSTER_CERT LLMCTL_CLUSTER_KEY LLMCTL_CLUSTER_CERT_DIR CURL_CA_BUNDLE 2>/dev/null || true
  export LLMCTL_CLUSTER_ENDPOINT="https://127.0.0.1:9443"
  : >"${ARGV_LOG}"; : >"${HDR_LOG}"; : >"${HDR_PATH_LOG}"
}
argv_has() { grep -qxF -- "$1" "${ARGV_LOG}"; }
argv_pair() { # argv_pair <flag> <value>: flag immediately followed by value
  awk -v f="$1" -v v="$2" 'p==1 && $0==v {ok=1} {p=($0==f)} END{exit ok?0:1}' "${ARGV_LOG}"
}
run_cluster() { # run_cluster <fn> args... -> RC/OUT, in a fresh shell so set -e/die do not kill the test
  RC=0
  OUT="$(bash -c 'source "$1/lib/cluster.sh"; shift; "$@"' _ "${LLMCTL_ROOT}" "$@" 2>&1)" || RC=$?
}

# 1. cert dir -> --cacert/--cert/--key + --http3, nothing insecure --------
reset_env
export LLMCTL_CLUSTER_CERT_DIR="${CERTS}"
run_cluster cluster::request GET /v1/cluster/status
assert_eq 0 "${RC}" "request with a cert dir succeeds against the fake curl"
argv_pair --cacert "${CERTS}/ca.crt" && echo "  ok: --cacert <dir>/ca.crt" || { echo "  FAIL: --cacert missing" >&2; TEST_FAILS=$((TEST_FAILS+1)); }
argv_pair --cert "${CERTS}/client.crt" && echo "  ok: --cert <dir>/client.crt" || { echo "  FAIL: --cert missing" >&2; TEST_FAILS=$((TEST_FAILS+1)); }
argv_pair --key "${CERTS}/client.key" && echo "  ok: --key <dir>/client.key" || { echo "  FAIL: --key missing" >&2; TEST_FAILS=$((TEST_FAILS+1)); }
argv_has --http3 && echo "  ok: --http3 used when the curl lists HTTP3" || { echo "  FAIL: --http3 missing" >&2; TEST_FAILS=$((TEST_FAILS+1)); }
for bad in -k --insecure --proxy-insecure --doh-insecure --ssl-no-revoke --ssl-revoke-best-effort; do
  if argv_has "${bad}"; then echo "  FAIL: verification-weakening switch ${bad} on argv" >&2; TEST_FAILS=$((TEST_FAILS+1)); else echo "  ok: no ${bad}"; fi
done
assert_eq "no" "$(grep -q 'KEYBYTES-SECRET' "${ARGV_LOG}" && echo yes || echo no)" "key bytes never appear on argv (only the file path)"

# 2. request_checked builds the same TLS args --------------------------------
reset_env; export LLMCTL_CLUSTER_CERT_DIR="${CERTS}"
run_cluster cluster::request_checked POST /v1/tenants '{"id":"x"}'
assert_eq 0 "${RC}" "request_checked with a cert dir succeeds"
argv_pair --cacert "${CERTS}/ca.crt" && argv_pair --cert "${CERTS}/client.crt" && argv_pair --key "${CERTS}/client.key" \
  && echo "  ok: request_checked passes --cacert/--cert/--key" || { echo "  FAIL: request_checked lacks TLS args" >&2; TEST_FAILS=$((TEST_FAILS+1)); }

# 3. explicit env overrides win over the directory ---------------------------
reset_env; export LLMCTL_CLUSTER_CERT_DIR="${CERTS}"
OTHER="${TEST_TMP}/other"; mkdir -m 700 "${OTHER}"; printf 'x\n' >"${OTHER}/ca.pem"; chmod 600 "${OTHER}/ca.pem"
export LLMCTL_CLUSTER_CACERT="${OTHER}/ca.pem"
run_cluster cluster::request GET /v1/cluster/status
argv_pair --cacert "${OTHER}/ca.pem" && echo "  ok: LLMCTL_CLUSTER_CACERT overrides the dir's ca.crt" || { echo "  FAIL: override ignored" >&2; TEST_FAILS=$((TEST_FAILS+1)); }

# 4. token is passed via a private header file, not on argv ------------------
reset_env; export LLMCTL_CLUSTER_CERT_DIR="${CERTS}" LLMCTL_CLUSTER_TOKEN="tok-SECRET-123"
run_cluster cluster::request GET /v1/cluster/status
assert_eq "no" "$(grep -q 'tok-SECRET-123' "${ARGV_LOG}" && echo yes || echo no)" "bearer token is not on argv"
assert_file_contains "${HDR_LOG}" "Authorization: Bearer tok-SECRET-123" "curl received the Authorization header via -H @file"
HP="$(head -1 "${HDR_PATH_LOG}")"
assert_eq "no" "$([[ -n "${HP}" && -e "${HP}" ]] && echo yes || echo no)" "the temporary header file is removed after the call"

# 5. a group/other-readable private key is refused, curl never runs ----------
reset_env; export LLMCTL_CLUSTER_CERT_DIR="${CERTS}"
chmod 644 "${CERTS}/client.key"
run_cluster cluster::request GET /v1/cluster/status
assert_eq 78 "${RC}" "world-readable client key: request refuses (78)"
assert_contains "${OUT}" "accessible to group/others" "refusal names the permission problem"
assert_eq "0" "$(wc -c <"${ARGV_LOG}" | tr -d ' ')" "curl was not invoked with a loose key"
run_cluster cluster::require_daemon
assert_eq 1 "${RC}" "require_daemon dies on unusable TLS material"
assert_contains "${OUT}" "TLS material is unusable" "require_daemon says TLS material is the problem, not 'unreachable'"
chmod 600 "${CERTS}/client.key"

# 6. cert without key / unreadable CA -> clear failure -----------------------
reset_env; export LLMCTL_CLUSTER_CERT="${CERTS}/client.crt"
run_cluster cluster::request GET /v1/cluster/status
assert_eq 78 "${RC}" "client cert without a key: refused"
assert_contains "${OUT}" "needs both" "message explains cert+key pairing"
reset_env; export LLMCTL_CLUSTER_CACERT="${TEST_TMP}/does-not-exist.crt"
run_cluster cluster::request GET /v1/cluster/status
assert_eq 78 "${RC}" "missing CA file: refused"

# 7. CURL_CA_BUNDLE still works as a trust anchor ----------------------------
reset_env; export CURL_CA_BUNDLE="${CERTS}/ca.crt"
run_cluster cluster::request GET /v1/cluster/status
argv_pair --cacert "${CERTS}/ca.crt" && echo "  ok: CURL_CA_BUNDLE becomes an explicit --cacert" || { echo "  FAIL: CURL_CA_BUNDLE not turned into --cacert" >&2; TEST_FAILS=$((TEST_FAILS+1)); }
if argv_has --cert; then echo "  FAIL: client cert sent although none configured" >&2; TEST_FAILS=$((TEST_FAILS+1)); else echo "  ok: no client cert when none is configured"; fi

# 8. plain http:// test doubles get no TLS args ------------------------------
reset_env; export LLMCTL_CLUSTER_ENDPOINT="http://127.0.0.1:1" LLMCTL_CLUSTER_CERT_DIR="${CERTS}"
run_cluster cluster::request GET /x
if argv_has --cacert || argv_has --cert; then echo "  FAIL: TLS args on an http:// endpoint" >&2; TEST_FAILS=$((TEST_FAILS+1)); else echo "  ok: http:// endpoint carries no TLS args"; fi

# 9. guard: no verification-disabling switch anywhere in the shell sources ---
SWITCHES='(^|[[:space:]("'\''=])(-k|--insecure|--proxy-insecure|--doh-insecure|--ssl-no-revoke|--ssl-revoke-best-effort|--no-check-certificate)([[:space:])"'\'']|$)|CURLOPT_SSL_VERIFY|CURL_INSECURE|NODE_TLS_REJECT_UNAUTHORIZED|InsecureSkipVerify[[:space:]]*[:=]+[[:space:]]*true'
# lib/cluster.sh builds curl args across many lines: scan the whole file. Every
# other shell source: only lines that actually invoke curl/wget (so unrelated
# flags like `launchctl kickstart -k` are not mistaken for curl's -k).
HITS="$(grep -En -e "${SWITCHES}" "${LLMCTL_ROOT}/lib/cluster.sh" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
HITS_OTHER="$(grep -rEn --include='*.sh' -e "${SWITCHES}" "${LLMCTL_ROOT}/lib" | grep -v '/lib/cluster.sh:' | grep -E 'curl|wget' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
HITS_BIN="$(grep -En -e "${SWITCHES}" "${LLMCTL_ROOT}/bin/llmctl" | grep -E 'curl|wget' | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
HITS="${HITS}${HITS_OTHER}"
if [[ -z "${HITS}${HITS_BIN}" ]]; then echo "  ok: no TLS-verification-disabling switch in lib/*.sh or bin/llmctl"; else
  printf '  FAIL: verification-disabling switch found:\n%s\n%s\n' "${HITS}" "${HITS_BIN}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
# the guard itself must be able to see a switch (control needle)
NEEDLE="$(printf 'curl -k https://x\n' | grep -E -e "${SWITCHES}" || true)"
assert_eq "curl -k https://x" "${NEEDLE}" "guard pattern detects a planted -k (control needle)"

test_finish
