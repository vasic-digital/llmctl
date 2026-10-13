#!/usr/bin/env bash
# test_shim_no_self_recursion.sh - generated PATH shims must not call themselves (or a sibling shim) by bare name.
# Incident 2026-10-13: a shim `tr` that ran `tr` re-executed itself through PATH: ~6,000 processes, uncapped session scope.
# tests/lint_shim_self_recursion.py is proven first on planted shims (positive needles, negative controls), then run on the tree.
# Pure static text analysis: nothing here executes a shim, so nothing here can fork.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
LINT="${LLMCTL_ROOT}/tests/lint_shim_self_recursion.py"
assert_file_exists "${LINT}" "tests/lint_shim_self_recursion.py exists"
run_lint() { local rc=0; LINT_OUT="$(python3 -I "${LINT}" "$@" 2>&1)" || rc=$?; LINT_RC=${rc}; }

C="${TEST_TMP}/ctl"; mkdir -p "${C}"
# --- planted offenders: each MUST be reported -------------------------------------------------
cat >"${C}/needle_heredoc.sh" <<'EOS'
mkdir -p "$W/shim"
cat >"$W/shim/tr" <<'S'
#!/bin/bash
tr '\0' '\n' </proc/$$/environ | grep -c FAKE >>"$W/leak"
exec /usr/bin/tr "$@"
S
EOS
run_lint "${C}/needle_heredoc.sh"
assert_eq 1 "${LINT_RC}" "NEEDLE: the p1.sh shape (shim tr calls tr, heredoc) is flagged"
assert_contains "${LINT_OUT}" "needle_heredoc.sh:4" "the offending line is named"
assert_contains "${LINT_OUT}" "shim \`tr\`" "the shim is named"

cat >"${C}/needle_printf.sh" <<'EOS'
printf '#!/bin/sh\ncurl -s "$@"\n' >"${FAKEBIN}/curl"
EOS
run_lint "${C}/needle_printf.sh"
assert_eq 1 "${LINT_RC}" "NEEDLE: a printf-written shim calling itself is flagged"

cat >"${C}/needle_sibling.sh" <<'EOS'
cat >"${B}/gh" <<'S'
#!/bin/sh
echo hi | sed s/a/b/
if glab --version; then :; fi
S
cat >"${B}/glab" <<'S'
#!/bin/sh
exit 0
S
EOS
run_lint "${C}/needle_sibling.sh"
assert_eq 1 "${LINT_RC}" "NEEDLE: shim gh calling sibling shim glab by bare name is flagged"
assert_contains "${LINT_OUT}" "sibling shim \`glab\`" "the sibling is named"

cat >"${C}/needle_pipe.sh" <<'EOS'
cat >"${B}/tr" <<'S'
#!/bin/bash
echo x | tr a b
$(tr a b </dev/null)
S
EOS
run_lint "${C}/needle_pipe.sh"
assert_eq 1 "${LINT_RC}" "NEEDLE: pipe and command-substitution positions are flagged"
assert_contains "${LINT_OUT}" "findings=2" "both positions counted"

# --- negative controls: each MUST pass ------------------------------------------------------
cat >"${C}/clean_abs.sh" <<'EOS'
cat >"$W/shim/tr" <<'S'
#!/bin/bash
# tr is mentioned in this comment only
echo "tr would be called here"; printf 'tr %s\n' "$*" >>"$W/calls"
exec /usr/bin/tr "$@"
S
cat >"$W/shim/systemctl" <<'S'
#!/bin/bash
case "$1" in
  systemctl) echo odd-case-label ;;
esac
exec "$REAL_SYSTEMCTL" "$@"
S
printf '#!/bin/sh\nexec /usr/bin/curl "$@"\n' >"${FAKEBIN}/curl"
EOS
run_lint "${C}/clean_abs.sh"
assert_eq 0 "${LINT_RC}" "NEGATIVE CONTROL: absolute exec, comment, quoted text, case label are NOT flagged"
assert_contains "${LINT_OUT}" "findings=0" "findings=0 on the clean shims"

cat >"${C}/exempt.sh" <<'EOS'
# SHIM-LINT-OK: deliberate recursive fixture for a containment test
printf '#!/bin/bash\ntr a b\n' >"$SH/tr"
EOS
run_lint "${C}/exempt.sh"
assert_eq 0 "${LINT_RC}" "a SHIM-LINT-OK exemption (with reason) is honoured"
cp "${C}/exempt.sh" "${C}/exempt2.sh"; sed -i '1d' "${C}/exempt2.sh"
run_lint "${C}/exempt2.sh"
assert_eq 1 "${LINT_RC}" "the same shim WITHOUT the exemption is flagged (the exemption is what silenced it)"

# --- the lint sees the real tree's shims at all (a lint that parses nothing proves nothing) ----
run_lint "${LLMCTL_ROOT}/tests/test_create_release.sh"
assert_eq 0 "${LINT_RC}" "test_create_release.sh (gh/glab shims) is clean"
cat >"${C}/count.py" <<'PY'
import importlib.util, glob, sys
spec = importlib.util.spec_from_file_location("l", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(sum(len(list(m.shims_in(open(f, errors="replace").read()))) for f in glob.glob(sys.argv[2] + "/tests/*.sh")))
PY
n="$(python3 -I "${C}/count.py" "${LINT}" "${LLMCTL_ROOT}")"
assert_eq "yes" "$([[ ${n} -ge 40 ]] && echo yes || echo no)" "the lint recognises the repository's generated shims (${n} found, >= 40)"

# --- the real tree --------------------------------------------------------------------------
files=()
for f in "${LLMCTL_ROOT}"/tests/*.sh "${LLMCTL_ROOT}"/scripts/*.sh "${LLMCTL_ROOT}"/scripts/*/*.sh "${LLMCTL_ROOT}"/lib/*.sh; do [[ -f "${f}" ]] && files+=("${f}"); done
run_lint "${files[@]}"
printf '  evidence: %s\n' "$(printf '%s' "${LINT_OUT}" | tail -3)"
assert_eq 0 "${LINT_RC}" "no generated shim in tests/ scripts/ lib/ calls itself or a sibling shim by bare name"
test_finish
