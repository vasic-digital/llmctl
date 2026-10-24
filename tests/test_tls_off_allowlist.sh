#!/usr/bin/env bash
# test_tls_off_allowlist.sh - class sweep 2026-10-22 (TLS verification off). Every place that turns certificate verification off must be
# justified in place:
#   * Go: `InsecureSkipVerify: true` is allowed only together with a `VerifyPeerCertificate` callback within 6 lines (custom verification
#     against the pinned CA - node identity is checked, only the stdlib hostname check is replaced).
#   * shell/python: `curl -k` / `--insecure` / `ssl._create_unverified_context` / `CERT_NONE` need a `TLS-OFF-OK: <reason>` marker on the
#     same line or the line before.
# Control needles: a planted violation of each kind MUST be reported; the justified forms MUST pass.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
SCAN="${TEST_TMP}/scan.py"
cat >"${SCAN}" <<'PY'
import re,sys
bad=0
sh=re.compile(r"curl\b[^\n#]*(\s-[a-zA-Z]*k[a-zA-Z]*\b|--insecure)|_create_unverified_context|CERT_NONE")
for f in sys.argv[1:]:
    lines=open(f,errors="replace").read().split("\n")
    for i,l in enumerate(lines):
        if f.endswith(".go"):
            if "InsecureSkipVerify: " in l and "true" in l and not l.strip().startswith("//"):
                if "VerifyPeerCertificate" not in "\n".join(lines[max(0,i-6):i+7]):
                    print(f"{f}:{i+1}: InsecureSkipVerify without VerifyPeerCertificate"); bad+=1
        else:
            if sh.search(l) and "TLS-OFF-OK:" not in l and (i==0 or "TLS-OFF-OK:" not in lines[i-1]):
                print(f"{f}:{i+1}: TLS verification off without a TLS-OFF-OK marker"); bad+=1
sys.exit(1 if bad else 0)
PY
printf 'x := &tls.Config{\n\tInsecureSkipVerify: true,\n}\n' >"${TEST_TMP}/bad.go"
printf 'x := &tls.Config{\n\tInsecureSkipVerify: true,\n\tVerifyPeerCertificate: f,\n}\n' >"${TEST_TMP}/good.go"
printf 'curl -sk https://127.0.0.1/x\n' >"${TEST_TMP}/bad.sh"
printf 'ctx=ssl._create_unverified_context()\n' >"${TEST_TMP}/bad.py"
printf '# TLS-OFF-OK: loopback throw-away cert\ncurl -sk https://127.0.0.1/x\ncurl -s https://127.0.0.1/y\n' >"${TEST_TMP}/good.sh"
for b in bad.go bad.sh bad.py; do rc=0; python3 "${SCAN}" "${TEST_TMP}/${b}" >/dev/null || rc=$?; assert_eq 1 "${rc}" "control needle: ${b} is reported"; done
for g in good.go good.sh; do rc=0; python3 "${SCAN}" "${TEST_TMP}/${g}" >/dev/null || rc=$?; assert_eq 0 "${rc}" "negative control: ${g} passes"; done
mapfile -t files < <(cd "${LLMCTL_ROOT}" && git ls-files '*.go' '*.sh' '*.py' ':!:submodules' ':!:tests/test_tls_off_allowlist.sh' ':!:tests/test_cluster_cli_args.sh' 2>/dev/null | sed "s#^#${LLMCTL_ROOT}/#")
assert_eq yes "$([[ ${#files[@]} -gt 200 ]] && echo yes || echo no)" "the scan covers the tracked go/sh/py files (${#files[@]})"
rc=0; out="$(python3 "${SCAN}" "${files[@]}" 2>&1)" || rc=$?
[[ -z "${out}" ]] || printf '%s\n' "${out}" >&2
assert_eq 0 "${rc}" "every TLS-verification-off site is justified in place"
test_finish
