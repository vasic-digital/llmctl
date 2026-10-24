#!/usr/bin/env bash
# test_no_auth_redirect_forwarding.sh - class sweep 2026-10-22: urllib's default opener follows redirects and RE-SENDS the request headers
# (Authorization: Bearer ...) to the redirect target. A python file that sends an Authorization header through urllib.request must
# either install a no-redirect handler (HTTPRedirectHandler / NoRedirect) or carry `REDIRECT-OK: <reason>` (loopback fixture only).
# Control needles: a planted file MUST be reported; handler / marker forms MUST pass.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
SCAN="${TEST_TMP}/scan.py"
cat >"${SCAN}" <<'PY'
import re,sys
bad=0
for f in sys.argv[1:]:
    s=open(f,errors="replace").read()
    if "urllib.request" in s and re.search(r"Authorization|Bearer", s) and re.search(r"urlopen|build_opener|OpenerDirector", s):
        if not re.search(r"HTTPRedirectHandler|NoRedirect|REDIRECT-OK:", s):
            print(f"{f}: sends Authorization through urllib without a no-redirect handler or REDIRECT-OK marker"); bad+=1
sys.exit(1 if bad else 0)
PY
printf 'import urllib.request\nh={"Authorization":"Bearer "+k}\nurllib.request.urlopen(r)\n' >"${TEST_TMP}/bad.py"
printf 'import urllib.request\nclass NoRedirect(urllib.request.HTTPRedirectHandler): pass\nh={"Authorization":"Bearer "+k}\nurllib.request.urlopen(r)\n' >"${TEST_TMP}/good1.py"
printf '# REDIRECT-OK: loopback fixture\nimport urllib.request\nh={"Authorization":"Bearer "+k}\nurllib.request.urlopen(r)\n' >"${TEST_TMP}/good2.py"
printf 'import urllib.request\nurllib.request.urlopen(r)\n' >"${TEST_TMP}/good3.py"
rc=0; python3 "${SCAN}" "${TEST_TMP}/bad.py" >/dev/null || rc=$?; assert_eq 1 "${rc}" "control needle: a planted bearer-over-urllib file is reported"
for g in good1 good2 good3; do rc=0; python3 "${SCAN}" "${TEST_TMP}/${g}.py" >/dev/null || rc=$?; assert_eq 0 "${rc}" "negative control: ${g}.py passes"; done
mapfile -t files < <(cd "${LLMCTL_ROOT}" && git ls-files '*.py' ':!:submodules' | sed "s#^#${LLMCTL_ROOT}/#")
assert_eq yes "$([[ ${#files[@]} -gt 40 ]] && echo yes || echo no)" "the scan covers the tracked python files (${#files[@]})"
rc=0; out="$(python3 "${SCAN}" "${files[@]}" 2>&1)" || rc=$?
[[ -z "${out}" ]] || printf '%s\n' "${out}" >&2
assert_eq 0 "${rc}" "no tracked python file forwards an Authorization header across redirects"
test_finish
