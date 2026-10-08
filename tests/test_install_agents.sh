#!/usr/bin/env bash
# test_install_agents.sh - scripts/install_agents.sh with a fake npm/uv (no network), plus an
# opt-in real install (LLMCTL_TEST_NETWORK=1). Covers --dry-run, install, idempotency, --check,
# the download record, and the integrity-mismatch refusal.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
S="${LLMCTL_ROOT}/scripts/install_agents.sh"
FX="${LLMCTL_ROOT}/tests/fixtures/agents"
export HOME="${TEST_TMP}/home"; mkdir -p "${HOME}"
P="${TEST_TMP}/agents"; B="${TEST_TMP}/bin"; L="${TEST_TMP}/agents.jsonl"
export FAKE_NPM_DIR="${TEST_TMP}/npmfake"; mkdir -p "${FAKE_NPM_DIR}"
# the fake npm names the bin after the package being installed: wrap per package
cat >"${TEST_TMP}/npm" <<WRAP
#!/usr/bin/env bash
case "\$*" in *cline*) export FAKE_NPM_BIN=cline;; *) export FAKE_NPM_BIN=cn;; esac
exec "${FX}/fake_npm.sh" "\$@"
WRAP
chmod +x "${TEST_TMP}/npm"
export LLMCTL_AGENTS_NPM="${TEST_TMP}/npm" LLMCTL_AGENTS_UV="${FX}/fake_uv.sh"
# PyPI stand-in: JSON metadata (file://) for aider-chat + the wheel it points to
PYPI="${TEST_TMP}/pypi"; mkdir -p "${PYPI}/aider-chat/9.9.9"
WHEEL="${PYPI}/aider_chat-9.9.9-py3-none-any.whl"; printf 'fake wheel bytes\n' >"${WHEEL}"
WSHA="$(openssl dgst -sha256 "${WHEEL}" | awk '{print $NF}')"
mk_pypi_json() { # mk_pypi_json <published-sha256> -> the JSON for /aider-chat/json and /aider-chat/9.9.9/json
  printf '{"info":{"version":"9.9.9"},"urls":[{"packagetype":"sdist","filename":"aider_chat-9.9.9.tar.gz","url":"file://%s/none","digests":{"sha256":"0"}},{"packagetype":"bdist_wheel","filename":"aider_chat-9.9.9-py3-none-any.whl","url":"file://%s","digests":{"sha256":"%s"}}]}\n' \
    "${PYPI}" "${WHEEL}" "$1" | tee "${PYPI}/aider-chat/json" >"${PYPI}/aider-chat/9.9.9/json"
}
mk_pypi_json "${WSHA}"
export LLMCTL_AGENTS_PYPI_BASE="file://${PYPI}" FAKE_UV_LOG="${TEST_TMP}/uv.log"
args=(--prefix "${P}" --bin "${B}" --log "${L}" --lock "${TEST_TMP}/none.lock")

echo "dry-run"
rc=0; out="$("${S}" --dry-run "${args[@]}" 2>&1)" || rc=$?
assert_eq 0 "${rc}" "dry-run rc"
assert_contains "${out}" "would install" "dry-run announces the install"
assert_file_absent "${B}/cn" "dry-run installs nothing"
assert_file_absent "${L}" "dry-run writes no download record"

echo "install"
rc=0; out="$("${S}" "${args[@]}" 2>&1)" || rc=$?
assert_eq 0 "${rc}" "install rc"
assert_file_exists "${B}/cn" "cn shim"
assert_file_exists "${B}/cline" "cline shim"
assert_file_exists "${B}/aider" "aider shim"
assert_eq "cn 9.9.9" "$("${B}/cn" --version)" "cn shim runs the installed bin"
assert_eq 3 "$(wc -l <"${L}")" "one download record per agent"
assert_file_contains "${L}" '"package":"@continuedev/cli"' "record names the package"
assert_file_contains "${L}" '"integrity_verified":true' "npm tarball integrity verified"
assert_eq 3 "$(grep -c '"integrity_verified":true' "${L}")" "all three installs (cn, cline, aider) verified the artifact they installed"
assert_eq 3 "$(grep -c '"dependency_tree_pinned":false' "${L}")" "the record states honestly that the dependency tree is not pinned"
assert_eq 3 "$(grep -c '"pinned":false' "${L}")" "...and that no lock pin was used"
assert_eq 2 "$(grep -c '"runtime_smoke":"version+help (exit 0, non-empty stdout)"' "${L}")" "C2-18/C3-09: the npm records state the smoke honestly (version+help, each exit 0 with stdout, not a runtime check)"
assert_eq 1 "$(grep -c '"runtime_smoke":"version (aider --version, exit 0, non-empty stdout)"' "${L}")" "C3-09: the aider record states the smoke that RAN (aider --version) - it ran on the verified path too"
assert_eq 2 "$(grep -c '"lifecycle_scripts":"skipped"' "${L}")" "C2-18: ...and that lifecycle scripts were skipped"
# C-08: the verified artifact IS the installed artifact
inst="$(grep -c '\.tgz$' "${FAKE_NPM_DIR}/install.args" || true)"
assert_eq 2 "${inst}" "npm install was given the packed TARBALL FILE (not a name npm would resolve for itself)"
assert_contains "$(cat "${FAKE_NPM_DIR}/install.args")" "--ignore-scripts" "npm install ran with --ignore-scripts by default"
assert_contains "$(cat "${FAKE_UV_LOG}")" "aider_chat-9.9.9-py3-none-any.whl" "uv installed the verified WHEEL FILE"
case "$(cat "${FAKE_UV_LOG}")" in *"aider-chat@latest"*) TEST_FAILS=$((TEST_FAILS+1)); echo "  FAIL: uv resolved aider-chat@latest itself" >&2 ;; *) echo "  ok: uv did not resolve aider-chat@latest itself" ;; esac
assert_file_contains "${L}" '"version":"9.9.9"' "record carries the version"

echo "idempotent"
out="$("${S}" "${args[@]}" 2>&1)"
assert_contains "${out}" "already installed" "second run is a no-op"
assert_eq 3 "$(wc -l <"${L}")" "no new record on a no-op"

echo "check"
# G-081: scope the check to the three agents this test installed; the full seven-agent check is
# host-dependent (opencode/pi/crush/claude are not installed by this script) and is covered below
# with a controlled PATH.
rc=0; out="$("${S}" --check --only cn,cline,aider "${args[@]}" 2>&1)" || rc=$?
assert_eq 0 "${rc}" "check rc"
assert_contains "${out}" "cn installed=yes version=" "check reports cn"
assert_contains "${out}" "aider installed=yes" "check reports aider"
assert_contains "${out}" "headless=" "check reports the headless capability"

echo "check on empty prefix"
rc=0; out="$(PATH=/usr/bin:/bin "${S}" --check --only cn --prefix "${TEST_TMP}/none" --bin "${TEST_TMP}/nobin" --log "${L}" 2>&1)" || rc=$?
assert_eq 1 "${rc}" "check rc 1 when missing"
assert_contains "${out}" "cn installed=no" "check reports absence"

echo "full seven-agent check on a controlled PATH (host-independent)"
TB="${TEST_TMP}/toolbin"; SB="${TEST_TMP}/stubbin"; mkdir -p "${TB}" "${SB}"
for t in timeout head tr grep dirname mkdir awk cat sed env bash; do
  tp="$(command -v "${t}" || true)"; [[ -n "${tp}" ]] && ln -sf "${tp}" "${TB}/${t}"
done
for a in aider cn cline opencode pi crush claude; do
  printf '#!/usr/bin/env bash\necho "%s 1.0"\n' "${a}" >"${SB}/${a}"; chmod +x "${SB}/${a}"
done
rm -f "${SB}/crush"
rc=0; out="$(PATH="${SB}:${TB}" "${S}" --check --prefix "${TEST_TMP}/none" --bin "${TEST_TMP}/nobin" --log "${L}" 2>&1)" || rc=$?
assert_eq 1 "${rc}" "full check rc 1 when one of the seven is missing"
assert_contains "${out}" "crush installed=no" "full check reports the missing agent"
assert_contains "${out}" "claude installed=yes" "full check reports a present agent"
assert_eq 7 "$(printf '%s\n' "${out}" | grep -c ' installed=')" "full check covers all seven agents"
printf '#!/usr/bin/env bash\necho "crush 1.0"\n' >"${SB}/crush"; chmod +x "${SB}/crush"
rc=0; out="$(PATH="${SB}:${TB}" "${S}" --check --prefix "${TEST_TMP}/none" --bin "${TEST_TMP}/nobin" --log "${L}" 2>&1)" || rc=$?
assert_eq 0 "${rc}" "full check rc 0 when all seven are present"

echo "integrity mismatch is refused"
export FAKE_NPM_BAD_INTEGRITY=1
rc=0; out="$("${S}" --only cn --prefix "${TEST_TMP}/p2" --bin "${TEST_TMP}/b2" --log "${TEST_TMP}/l2" 2>&1)" || rc=$?
assert_eq 1 "${rc}" "mismatch rc"
assert_contains "${out}" "integrity mismatch" "mismatch reported"
assert_file_absent "${TEST_TMP}/b2/cn" "no shim after a mismatch"
unset FAKE_NPM_BAD_INTEGRITY

echo "C-08: the packed tarball differs from the one the registry vouched for -> refused"
export FAKE_NPM_PACK_TAMPERED=1
rc=0; out="$("${S}" --only cn --prefix "${TEST_TMP}/p3" --bin "${TEST_TMP}/b3" --log "${TEST_TMP}/l3" --lock "${TEST_TMP}/none.lock" 2>&1)" || rc=$?
assert_eq 1 "${rc}" "tampered packed tarball rc"
assert_contains "${out}" "integrity mismatch" "tampered tarball reported"
assert_file_absent "${TEST_TMP}/b3/cn" "no shim for a tarball that does not match its published integrity"
assert_file_absent "${TEST_TMP}/l3" "no record claiming verification"
unset FAKE_NPM_PACK_TAMPERED

echo "C-08: a tampered aider wheel is refused (PyPI digest vs downloaded bytes)"
mk_pypi_json "0000000000000000000000000000000000000000000000000000000000000000"
rc=0; out="$("${S}" --only aider --prefix "${TEST_TMP}/p4" --bin "${TEST_TMP}/b4" --log "${TEST_TMP}/l4" --lock "${TEST_TMP}/none.lock" 2>&1)" || rc=$?
assert_eq 1 "${rc}" "wheel digest mismatch rc"
assert_contains "${out}" "wheel sha256 mismatch" "wheel mismatch reported"
assert_file_absent "${TEST_TMP}/b4/aider" "no aider shim after a wheel mismatch"
mk_pypi_json "${WSHA}"

echo "C-08/C2-02: offline (no PyPI metadata) and UNPINNED -> refused unless the operator opts in"
rc=0; : >"${FAKE_UV_LOG}"
LLMCTL_AGENTS_PYPI_BASE="file://${TEST_TMP}/no-such-pypi" "${S}" --only aider --prefix "${TEST_TMP}/p5" --bin "${TEST_TMP}/b5" --log "${TEST_TMP}/l5" --lock "${TEST_TMP}/none.lock" >"${TEST_TMP}/o5" 2>&1 || rc=$?
assert_eq 1 "${rc}" "an unverifiable unpinned aider install is refused by default (fail closed)"
assert_file_absent "${TEST_TMP}/b5/aider" "...no aider shim"
assert_file_absent "${TEST_TMP}/l5" "...and no record claiming an install"
assert_eq 0 "$(wc -c <"${FAKE_UV_LOG}")" "...uv was never invoked"
assert_contains "$(cat "${TEST_TMP}/o5")" "LLMCTL_AGENTS_ALLOW_UNVERIFIED" "...the message names the opt-in"
LLMCTL_AGENTS_ALLOW_UNVERIFIED=1 LLMCTL_AGENTS_PYPI_BASE="file://${TEST_TMP}/no-such-pypi" "${S}" --only aider --prefix "${TEST_TMP}/p5" --bin "${TEST_TMP}/b5" --log "${TEST_TMP}/l5" --lock "${TEST_TMP}/none.lock" >"${TEST_TMP}/o5" 2>&1 || true
assert_file_contains "${TEST_TMP}/l5" '"integrity_verified":false' "an opted-in unverifiable aider install records integrity_verified=false"
assert_file_contains "${TEST_TMP}/l5" '"integrity_source":"none"' "...with integrity_source none (not lock/pypi)"
assert_file_contains "${TEST_TMP}/l5" '"pinned":false' "...pinned false"
assert_file_contains "${TEST_TMP}/l5" '(UNVERIFIED: no wheel digest was checked)' "...and a method that says UNVERIFIED, not 'the verified wheel'"
assert_contains "$(cat "${TEST_TMP}/o5")" "UNVERIFIED" "...and says so on the console"

echo "C2-02: a PINNED aider whose verified wheel cannot be had NEVER falls back to latest"
printf 'pypi aider-chat 9.9.9 %s\n' "${WSHA}" >"${TEST_TMP}/pin_aider.lock"
for how in unreachable bad_json; do
  case "${how}" in
    unreachable) pb="file://${TEST_TMP}/no-such-pypi" ;;
    bad_json) mkdir -p "${TEST_TMP}/badpypi/aider-chat/9.9.9"; echo '{not json' >"${TEST_TMP}/badpypi/aider-chat/9.9.9/json"; pb="file://${TEST_TMP}/badpypi" ;;
  esac
  : >"${FAKE_UV_LOG}"; rm -rf "${TEST_TMP}/p10" "${TEST_TMP}/b10" "${TEST_TMP}/l10"
  rc=0; out="$(LLMCTL_AGENTS_ALLOW_UNVERIFIED=1 LLMCTL_AGENTS_PYPI_BASE="${pb}" "${S}" --only aider --prefix "${TEST_TMP}/p10" --bin "${TEST_TMP}/b10" --log "${TEST_TMP}/l10" --lock "${TEST_TMP}/pin_aider.lock" 2>&1)" || rc=$?
  assert_eq 1 "${rc}" "pinned aider + ${how} PyPI -> exit 1 (even with the unverified opt-in: a pin is never downgraded)"
  assert_file_absent "${TEST_TMP}/b10/aider" "${how}: no shim"
  assert_file_absent "${TEST_TMP}/l10" "${how}: no install record"
  assert_eq 0 "$(wc -c <"${FAKE_UV_LOG}")" "${how}: uv never ran (no aider-chat@latest)"
  assert_contains "${out}" "pinned" "${how}: the message says the pinned install failed closed"
done

echo "C3-09: the --help smoke needs exit 0 AND stdout (a crash on stderr is not a pass)"
export FAKE_NPM_HELP_CRASH=1
rc=0; out="$("${S}" --only cn --prefix "${TEST_TMP}/p11" --bin "${TEST_TMP}/b11" --log "${TEST_TMP}/l11" --lock "${TEST_TMP}/none.lock" 2>&1)" || rc=$?
assert_eq 1 "${rc}" "C3-09: a bin whose --help crashes (stderr text, exit 1) fails the install"
assert_file_absent "${TEST_TMP}/b11/cn" "C3-09: ...no shim"
assert_file_absent "${TEST_TMP}/l11" "C3-09: ...and no record claiming version+help"
unset FAKE_NPM_HELP_CRASH
export FAKE_NPM_HELP_RC1=1
rc=0; out="$("${S}" --only cn --prefix "${TEST_TMP}/p15" --bin "${TEST_TMP}/b15" --log "${TEST_TMP}/l15" --lock "${TEST_TMP}/none.lock" 2>&1)" || rc=$?
assert_eq 1 "${rc}" "C3-09: a bin whose --help prints usage but EXITS 1 fails the install (the status is judged, not only the text)"
assert_file_absent "${TEST_TMP}/b15/cn" "C3-09: ...no shim"
unset FAKE_NPM_HELP_RC1
export FAKE_NPM_HELP_EMPTY=1
rc=0; out="$("${S}" --only cn --prefix "${TEST_TMP}/p12" --bin "${TEST_TMP}/b12" --log "${TEST_TMP}/l12" --lock "${TEST_TMP}/none.lock" 2>&1)" || rc=$?
assert_eq 1 "${rc}" "C3-09/S3: a bin whose --help exits 0 but prints nothing fails the install"
assert_contains "${out}" "printed nothing" "C3-09/S3: ...saying so"
assert_file_absent "${TEST_TMP}/b12/cn" "C3-09/S3: ...no shim"
unset FAKE_NPM_HELP_EMPTY
export FAKE_UV_VERSION_CRASH=1
rc=0; out="$("${S}" --only aider --prefix "${TEST_TMP}/p13" --bin "${TEST_TMP}/b13" --log "${TEST_TMP}/l13" --lock "${TEST_TMP}/none.lock" 2>&1)" || rc=$?
assert_eq 1 "${rc}" "C3-09: an installed aider whose --version crashes fails the (VERIFIED) install - the smoke runs on every path"
assert_file_absent "${TEST_TMP}/b13/aider" "C3-09: ...no aider shim"
assert_file_absent "${TEST_TMP}/l13" "C3-09: ...no record"
unset FAKE_UV_VERSION_CRASH

echo "C3-15/S7: a pinned aider whose pinned version resolves to ANOTHER version is refused"
mkdir -p "${PYPI}/aider-chat/9.8.0"; cp "${PYPI}/aider-chat/9.9.9/json" "${PYPI}/aider-chat/9.8.0/json"   # asks for 9.8.0, PyPI answers 9.9.9
printf 'pypi aider-chat 9.8.0 %s\n' "${WSHA}" >"${TEST_TMP}/pin_mismatch.lock"
: >"${FAKE_UV_LOG}"
rc=0; out="$("${S}" --only aider --prefix "${TEST_TMP}/p14" --bin "${TEST_TMP}/b14" --log "${TEST_TMP}/l14" --lock "${TEST_TMP}/pin_mismatch.lock" 2>&1)" || rc=$?
assert_eq 1 "${rc}" "C3-15/S7: a pin that resolves to a different version exits 1"
assert_contains "${out}" "resolved to" "C3-15/S7: ...saying the pinned version resolved to another"
assert_eq 0 "$(wc -c <"${FAKE_UV_LOG}")" "C3-15/S7: ...and uv never ran"
assert_file_absent "${TEST_TMP}/b14/aider" "C3-15/S7: ...no shim"

echo "C3-10: no GNU 'timeout' on PATH (stock macOS): --check still works (perl alarm / honest unbounded fallback)"
TB2="${TEST_TMP}/toolbin2"; SB2="${TEST_TMP}/stubbin2"; mkdir -p "${TB2}" "${SB2}"
for t in bash env dirname mkdir awk cat sed head tr grep id date rm mv chmod mktemp tail basename python3 openssl sleep; do
  tp="$(command -v "${t}" || true)"; [[ -n "${tp}" ]] && ln -sf "${tp}" "${TB2}/${t}"
done
printf '#!/usr/bin/env bash\ncase "$1" in --version) echo "cn 1.0";; --help) echo "usage: cn -p TEXT --print";; esac\n' >"${SB2}/cn"; chmod +x "${SB2}/cn"
rc=0; out="$(PATH="${SB2}:${TB2}" "${S}" --check --only cn --prefix "${TEST_TMP}/none" --bin "${TEST_TMP}/nobin" --log "${L}" 2>"${TEST_TMP}/to.err")" || rc=$?
assert_eq 0 "${rc}" "C3-10: --check works with no timeout/gtimeout/perl on PATH"
assert_contains "${out}" "version=cn 1.0" "C3-10: ...and still reads the version (not '-' from a 'timeout: command not found')"
assert_contains "${out}" "headless=cn -p TEXT" "C3-10: ...and the headless form"
assert_file_contains "${TEST_TMP}/to.err" "no timeout" "C3-10: ...with an honest warning that probes run unbounded"
if command -v perl >/dev/null 2>&1; then
  ln -sf "$(command -v perl)" "${TB2}/perl"
  printf '#!/usr/bin/env bash\ncase "$1" in --version) sleep 6; echo "cn 1.0";; --help) echo "usage: cn -p TEXT";; esac\n' >"${SB2}/cn"
  t0="$(date +%s)"; rc=0
  out="$(PATH="${SB2}:${TB2}" LLMCTL_AGENTS_CHECK_TIMEOUT=1 "${S}" --check --only cn --prefix "${TEST_TMP}/none" --bin "${TEST_TMP}/nobin" --log "${L}" 2>"${TEST_TMP}/to2.err")" || rc=$?
  t1="$(date +%s)"
  assert_eq 1 "$(( t1 - t0 < 5 ? 1 : 0 ))" "C3-10: with perl but no timeout, a hung --version is cut off by the perl alarm fallback"
  assert_contains "${out}" "version=-" "C3-10: ...so the hung probe reports no version"
  assert_eq 0 "$(grep -c 'no timeout' "${TEST_TMP}/to2.err" || true)" "C3-10: ...without the unbounded-run warning"
else
  assert_skip "perl not installed" "C3-10 perl alarm fallback"
fi

echo "C-08: lock pins (agents.lock)"
NPMSHA="sha512-$(openssl dgst -sha512 -binary "${FAKE_NPM_DIR}/pkg.tgz" | openssl base64 -A)"
printf '# test lock\nnpm @continuedev/cli 9.9.9 %s\npypi aider-chat 9.9.9 %s\n' "${NPMSHA}" "${WSHA}" >"${TEST_TMP}/pin.lock"
rc=0; out="$("${S}" --only cn,aider --prefix "${TEST_TMP}/p6" --bin "${TEST_TMP}/b6" --log "${TEST_TMP}/l6" --lock "${TEST_TMP}/pin.lock" 2>&1)" || rc=$?
assert_eq 0 "${rc}" "pinned install rc"
assert_eq 2 "$(grep -c '"pinned":true' "${TEST_TMP}/l6")" "both records say pinned=true"
assert_eq 2 "$(grep -c '"integrity_source":"lock"' "${TEST_TMP}/l6")" "...with the digest taken from the lock, not the registry"
printf 'npm @continuedev/cli 9.9.9 sha512-WRONG\n' >"${TEST_TMP}/bad.lock"
rc=0; out="$("${S}" --only cn --prefix "${TEST_TMP}/p7" --bin "${TEST_TMP}/b7" --log "${TEST_TMP}/l7" --lock "${TEST_TMP}/bad.lock" 2>&1)" || rc=$?
assert_eq 1 "${rc}" "a pin the download does not match is refused"
assert_contains "${out}" "lock pin" "...naming the lock as the source of the expected digest"
assert_file_absent "${TEST_TMP}/b7/cn" "no shim after a pin mismatch"
rc=0; out="$("${S}" --only cn,aider --prefix "${TEST_TMP}/p8" --bin "${TEST_TMP}/b8" --log "${TEST_TMP}/l8" --lock "${TEST_TMP}/w.lock" --write-lock 2>&1)" || rc=$?
assert_eq 0 "${rc}" "--write-lock install rc"
assert_contains "$(cat "${TEST_TMP}/w.lock")" "npm @continuedev/cli 9.9.9 ${NPMSHA}" "--write-lock records the pin of a verified npm install"
assert_contains "$(cat "${TEST_TMP}/w.lock")" "pypi aider-chat 9.9.9 ${WSHA}" "--write-lock records the pin of a verified aider install"

echo "defaults"
if grep -q 'base64 -w0' "${S}"; then echo "  FAIL: install_agents.sh uses GNU-only base64 -w0" >&2; TEST_FAILS=$((TEST_FAILS+1)); else echo "  ok: no GNU-only base64 -w0 (portable openssl base64 -A)"; fi
H2="${TEST_TMP}/h2"; mkdir -p "${H2}"
HOME="${H2}" "${S}" --only cn --prefix "${TEST_TMP}/p9" --bin "${TEST_TMP}/b9" --lock "${TEST_TMP}/none.lock" >/dev/null 2>&1 || true
assert_file_exists "${H2}/.local/state/llmctl/agents-install.jsonl" "the default --log is under the user's state dir, not the tracked evidence file"

echo "usage"
assert_rc 2 "unknown agent" "${S}" --only nosuch
assert_rc 2 "unknown flag" "${S}" --bogus

if [[ "${LLMCTL_TEST_NETWORK:-0}" == 1 ]]; then
  echo "real install (opt-in)"
  unset LLMCTL_AGENTS_NPM LLMCTL_AGENTS_UV
  export HOME="${TEST_TMP}/realhome"; mkdir -p "${HOME}"
  rc=0; out="$("${S}" --only cn --prefix "${TEST_TMP}/rp" --bin "${TEST_TMP}/rb" --log "${TEST_TMP}/rl" 2>&1)" || rc=$?
  assert_eq 0 "${rc}" "real cn install rc"
  assert_file_exists "${TEST_TMP}/rb/cn" "real cn shim"
else
  assert_skip "LLMCTL_TEST_NETWORK!=1" "real network install"
fi
test_finish
