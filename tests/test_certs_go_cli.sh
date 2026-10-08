#!/usr/bin/env bash
# test_certs_go_cli.sh - builds the REAL Go binary (into a temp dir, nothing in
# the repo tree) and drives `cert` end to end; the independent `openssl`
# binary judges what the Go implementation produced (FR-066..FR-068, FR-087).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT

command -v go >/dev/null 2>&1 || { echo "SKIP-SUITE: go not installed"; exit 0; }
HAVE_OPENSSL=0; command -v openssl >/dev/null 2>&1 && HAVE_OPENSSL=1
BIN="${TEST_TMP}/bin/llmctl-decide"
mkdir -p "${TEST_TMP}/bin"
( cd "${LLMCTL_ROOT}" && go build -o "${BIN}" ./cmd/llmctl-decide )

H="${TEST_TMP}/home/llmctl"
mkdir -p "${H}"
unset LLMCTL_TLS_SAN LLMCTL_TLS_MODE LLMCTL_CA_NAME_CONSTRAINTS LLMCTL_HOME
# hermetic names/addresses so the test does not depend on the host's network
cert() { "${BIN}" cert --home "${H}" --hostname testhost --address 192.168.1.115 "$@"; }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
assert_not_contains() { if [[ "$1" != *"$2"* ]]; then printf '  ok: %s\n' "$3"; else printf '  FAIL: %s\n' "$3" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi; }
sha() { sha256sum "$@" 2>/dev/null || shasum -a 256 "$@"; }

echo "== ensure creates CA + leaf with strict modes =="
out="$(cert ensure 2>&1)"
assert_contains "${out}" "issued mode=ca-leaf version=1 created=true" "first ensure issues v-1"
assert_eq "700" "$(mode "${H}/cert")" "cert dir is 0700"
assert_eq "600" "$(mode "${H}/cert/ca/ca.key")" "CA key is 0600"
assert_eq "644" "$(mode "${H}/cert/ca/ca.crt")" "CA cert is 0644"
assert_eq "600" "$(mode "${H}/cert/v-1/leaf.key")" "leaf key is 0600"
assert_eq "v-1" "$(readlink "${H}/cert/current")" "current is a relative symlink to v-1"
assert_not_contains "${out}" "PRIVATE" "ensure prints nothing secret"

echo "== idempotent second ensure =="
before="$(ls -A "${H}/cert" | sort | tr '\n' ' ')"
out2="$(cert ensure 2>&1)"
assert_contains "${out2}" "created=false" "second ensure creates nothing"
assert_eq "${before}" "$(ls -A "${H}/cert" | sort | tr '\n' ' ')" "cert dir content unchanged"

echo "== concurrent ensure from separate processes issues exactly once =="
C="${TEST_TMP}/home-conc/llmctl"; mkdir -p "${C}"
pids=()
for i in 1 2 3 4 5 6; do
  "${BIN}" cert --home "${C}" --hostname testhost --address 192.168.1.115 ensure > "${TEST_TMP}/conc.${i}" 2>&1 & pids+=($!)
done
for p in "${pids[@]}"; do wait "${p}"; done
assert_eq "v-1" "$(cd "${C}/cert" && ls -d v-* | tr '\n' ' ' | sed 's/ $//')" "exactly one version directory"
assert_eq "1" "$(grep -h '^leaf_sha256' "${TEST_TMP}"/conc.* | sort -u | wc -l | tr -d ' ')" "all six processes saw the same leaf"
assert_eq "1" "$(grep -l 'issued ' "${TEST_TMP}"/conc.* | wc -l | tr -d ' ')" "exactly one process issued"
assert_eq "" "$(find "${C}/cert" -maxdepth 1 \( -name '.v-*' -o -name '.ca-*' \) -print)" "no staging directories left behind"

if [[ ${HAVE_OPENSSL} -eq 1 ]]; then
echo "== name constraints are enforced by openssl itself =="
ca_text="$(openssl x509 -in "${H}/cert/ca/ca.crt" -noout -text)"
assert_contains "${ca_text}" "Name Constraints: critical" "CA carries a critical nameConstraints extension"
assert_contains "${ca_text}" "pathlen:0" "CA is pathlen 0"
assert_contains "${ca_text}" "prime256v1" "CA key is EC P-256"
lt="$(openssl x509 -in "${H}/cert/v-1/leaf.crt" -noout -text)"
assert_contains "${lt}" "CA:FALSE" "leaf is CA:FALSE"
assert_contains "${lt}" "TLS Web Server Authentication" "leaf is serverAuth"
assert_not_contains "${lt}" "TLS Web Client Authentication" "leaf is not clientAuth"
rc=0; openssl verify -CAfile "${H}/cert/ca/ca.crt" -purpose sslserver "${H}/cert/v-1/leaf.crt" >/dev/null 2>&1 || rc=$?
assert_eq "0" "${rc}" "permitted leaf verifies"
F="${TEST_TMP}/foreign"; mkdir -p "${F}"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${F}/k.pem" 2>/dev/null
openssl req -new -key "${F}/k.pem" -subj /CN=example.com -out "${F}/r.csr"
printf 'subjectAltName=DNS:example.com\nextendedKeyUsage=serverAuth\n' > "${F}/e.cnf"
openssl x509 -req -in "${F}/r.csr" -CA "${H}/cert/ca/ca.crt" -CAkey "${H}/cert/ca/ca.key" -set_serial 5 -days 5 -extfile "${F}/e.cnf" -out "${F}/c.pem" 2>/dev/null
rc=0; vout="$(openssl verify -CAfile "${H}/cert/ca/ca.crt" "${F}/c.pem" 2>&1)" || rc=$?
assert_eq "nonzero" "$([[ ${rc} -ne 0 ]] && echo nonzero || echo zero)" "out-of-scope leaf (example.com) is REJECTED by openssl verify"
assert_contains "${vout}" "permitted subtree violation" "rejection reason is the name constraint"
printf 'subjectAltName=IP:8.8.8.8\nextendedKeyUsage=serverAuth\n' > "${F}/e2.cnf"
openssl x509 -req -in "${F}/r.csr" -CA "${H}/cert/ca/ca.crt" -CAkey "${H}/cert/ca/ca.key" -set_serial 6 -days 5 -extfile "${F}/e2.cnf" -out "${F}/c2.pem" 2>/dev/null
rc=0; openssl verify -CAfile "${H}/cert/ca/ca.crt" "${F}/c2.pem" >/dev/null 2>&1 || rc=$?
assert_eq "nonzero" "$([[ ${rc} -ne 0 ]] && echo nonzero || echo zero)" "public IP leaf (8.8.8.8) is REJECTED by openssl verify"

echo "== constraints off is a deliberate, warned opt-out =="
O="${TEST_TMP}/home-off/llmctl"; mkdir -p "${O}"
err="$(LLMCTL_CA_NAME_CONSTRAINTS=off "${BIN}" cert --home "${O}" --hostname testhost --address 192.168.1.115 ensure 2>&1 >/dev/null)"
assert_contains "${err}" "WARNING:" "opt-out is logged on stderr"
assert_contains "${err}" "constraints" "warning names the constraints"
assert_not_contains "$(openssl x509 -in "${O}/cert/ca/ca.crt" -noout -text)" "Name Constraints" "no nameConstraints extension when off"
openssl x509 -req -in "${F}/r.csr" -CA "${O}/cert/ca/ca.crt" -CAkey "${O}/cert/ca/ca.key" -set_serial 7 -days 5 -extfile "${F}/e.cnf" -out "${F}/c3.pem" 2>/dev/null
rc=0; openssl verify -CAfile "${O}/cert/ca/ca.crt" "${F}/c3.pem" >/dev/null 2>&1 || rc=$?
assert_eq "0" "${rc}" "with constraints off the same out-of-scope leaf verifies (the test above is not vacuous)"
else
assert_skip "openssl not installed" "independent name-constraint oracle"
fi

echo "== export / show / doctor =="
cert export "${TEST_TMP}/pub/ca.crt" >/dev/null
assert_eq "644" "$(mode "${TEST_TMP}/pub/ca.crt")" "exported CA is 0644"
pk=0; grep -q PRIVATE "${TEST_TMP}/pub/ca.crt" && pk=1
assert_eq "0" "${pk}" "exported CA holds no private key"
assert_contains "$(cert show)" "leaf_sha256" "show lists fingerprints"
assert_contains "$(cert show --json)" '"ca_key_on_host": true' "show --json is machine-readable"
rc=0; cert doctor >/dev/null 2>&1 || rc=$?
assert_eq "0" "${rc}" "doctor healthy -> exit 0"
chmod 644 "${H}/cert/ca/ca.key"
rc=0; cert doctor >/dev/null 2>&1 || rc=$?
assert_eq "5" "${rc}" "doctor with a world-readable CA key -> exit 5"
chmod 600 "${H}/cert/ca/ca.key"

echo "== renew swaps current atomically and keeps the CA =="
ca_before="$(sha "${H}/cert/ca/ca.crt" | cut -d' ' -f1)"
cert --address 192.168.1.200 renew >/dev/null
assert_eq "v-2" "$(readlink "${H}/cert/current")" "current -> v-2"
assert_eq "${ca_before}" "$(sha "${H}/cert/ca/ca.crt" | cut -d' ' -f1)" "CA untouched by renew"
k1="$(sha "${H}/cert/v-2/leaf.key" | cut -d' ' -f1)"
cert renew --reuse-key >/dev/null
assert_eq "${k1}" "$(sha "${H}/cert/v-3/leaf.key" | cut -d' ' -f1)" "--reuse-key keeps the leaf key"
assert_eq "v-3" "$(readlink "${H}/cert/current")" "current -> v-3"

echo "== expired leaf refused (exit 5) via the test clock =="
rc=0; err="$(cert --now "$(( $(date +%s) + 400*86400 ))" ensure 2>&1 >/dev/null)" || rc=$?
assert_eq "5" "${rc}" "ensure on an expired leaf exits 5"
assert_contains "${err}" "expired" "message says expired"
rc=0; cert --now "$(( $(date +%s) + 400*86400 ))" doctor >/dev/null 2>&1 || rc=$?
assert_eq "5" "${rc}" "doctor on an expired leaf exits 5"
rc=0; cert --now "$(( $(date +%s) + 400*86400 ))" renew >/dev/null 2>&1 || rc=$?
assert_eq "0" "${rc}" "renew is the way out of expiry"

echo "== offline CA key =="
OF="${TEST_TMP}/home-off2/llmctl"; mkdir -p "${OF}" "${TEST_TMP}/usb"
"${BIN}" cert --home "${OF}" --hostname testhost --address 192.168.1.115 ensure --offline-ca-key "${TEST_TMP}/usb/ca.key" >/dev/null
assert_file_absent "${OF}/cert/ca/ca.key" "CA key removed from the host"
assert_eq "600" "$(mode "${TEST_TMP}/usb/ca.key")" "offline CA key is 0600"
rc=0; err="$("${BIN}" cert --home "${OF}" --hostname testhost --address 192.168.1.115 renew 2>&1 >/dev/null)" || rc=$?
assert_eq "5" "${rc}" "renew without the offline key exits 5"
assert_contains "${err}" "offline" "message says the key is offline"
rc=0; "${BIN}" cert --home "${OF}" --hostname testhost --address 192.168.1.115 renew --ca-key "${TEST_TMP}/usb/ca.key" >/dev/null 2>&1 || rc=$?
assert_eq "0" "${rc}" "renew with the key supplied works"
assert_file_absent "${OF}/cert/ca/ca.key" "CA key is still not on the host"

echo "== BYO: expired pair refused, files never written =="
if [[ ${HAVE_OPENSSL} -eq 1 ]]; then
B="${TEST_TMP}/home2/llmctl"; mkdir -p "${B}/cert/byo"; chmod 700 "${B}/cert"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${B}/cert/byo/key.pem" 2>/dev/null
openssl req -x509 -new -key "${B}/cert/byo/key.pem" -subj /CN=byo.local -addext subjectAltName=DNS:byo.local \
  -not_before 20190101000000Z -not_after 20200101000000Z -out "${B}/cert/byo/cert.pem" 2>/dev/null
h1="$(sha "${B}/cert/byo/cert.pem" "${B}/cert/byo/key.pem")"
rc=0; "${BIN}" cert --home "${B}" ensure --mode byo >/dev/null 2>&1 || rc=$?
assert_eq "5" "${rc}" "expired BYO pair -> exit 5"
assert_eq "${h1}" "$(sha "${B}/cert/byo/cert.pem" "${B}/cert/byo/key.pem")" "BYO files untouched"
# a valid pair is accepted and still untouched
openssl req -x509 -new -key "${B}/cert/byo/key.pem" -subj /CN=byo.local -addext subjectAltName=DNS:byo.local \
  -days 30 -out "${B}/cert/byo/cert.pem" 2>/dev/null
h2="$(sha "${B}/cert/byo/cert.pem" "${B}/cert/byo/key.pem")"
out="$("${BIN}" cert --home "${B}" ensure 2>&1)"
assert_contains "${out}" "mode=byo" "valid BYO pair accepted (mode auto-detected)"
assert_eq "${h2}" "$(sha "${B}/cert/byo/cert.pem" "${B}/cert/byo/key.pem")" "valid BYO files untouched"
assert_file_absent "${B}/cert/ca" "BYO creates no CA"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${B}/cert/byo/key.pem" 2>/dev/null
rc=0; err="$("${BIN}" cert --home "${B}" ensure 2>&1 >/dev/null)" || rc=$?
assert_eq "5" "${rc}" "mismatched BYO pair -> exit 5"
assert_contains "${err}" "does not match" "message says the key does not match"
else
assert_skip "openssl not installed" "BYO pair generation"
fi

echo "== selfsigned mode =="
S="${TEST_TMP}/home-ss/llmctl"; mkdir -p "${S}"
out="$("${BIN}" cert --home "${S}" --hostname testhost --address 192.168.1.115 ensure --mode selfsigned 2>&1)"
assert_contains "${out}" "mode=selfsigned" "selfsigned issued"
assert_file_absent "${S}/cert/ca" "no CA in selfsigned mode"
if [[ ${HAVE_OPENSSL} -eq 1 ]]; then
rc=0; openssl verify -CAfile "${S}/cert/v-1/leaf.crt" "${S}/cert/v-1/leaf.crt" >/dev/null 2>&1 || rc=$?
assert_eq "0" "${rc}" "openssl trusts the self-signed certificate as its own root"
fi

echo "== placement guard: planted in an un-ignored git work tree =="
R="${TEST_TMP}/repo"; mkdir -p "${R}"; git -C "${R}" init -q
rc=0; err="$("${BIN}" cert --home "${R}/llmctl" --hostname testhost --address 192.168.1.115 ensure 2>&1 >/dev/null)" || rc=$?
assert_eq "5" "${rc}" "ensure inside an un-ignored work tree is refused (exit 5)"
assert_contains "${err}" "git work tree" "message names the git work tree"
assert_file_absent "${R}/llmctl/cert/ca/ca.key" "no CA key was written into the repository"
printf 'cert/\n' > "${R}/.gitignore"
rc=0; "${BIN}" cert --home "${R}" --hostname testhost --address 192.168.1.115 ensure >/dev/null 2>&1 || rc=$?
assert_eq "0" "${rc}" "allowed once git ignores cert/"
assert_eq "" "$(git -C "${R}" status --porcelain --untracked-files=all | grep -E 'cert/' || true)" "git sees no cert files as untracked"

echo "== usage errors exit 2 =="
rc=0; "${BIN}" cert bogus >/dev/null 2>&1 || rc=$?
assert_eq "2" "${rc}" "unknown cert command -> 2"
rc=0; "${BIN}" cert --home "${H}" ensure --mode nope >/dev/null 2>&1 || rc=$?
assert_eq "2" "${rc}" "bad --mode -> 2"

echo "== nothing written into the repository tree =="
assert_eq "" "$(git -C "${LLMCTL_ROOT}" status --porcelain -- 'cert' '*.key' '*.pem' 2>/dev/null | grep -v '^??.*tests/' || true)" "no key/cert files appeared in the repo"

[[ ${TEST_FAILS} -eq 0 ]] && echo "test_certs_go_cli: ALL PASS" || { echo "test_certs_go_cli: ${TEST_FAILS} FAILED" >&2; exit 1; }
