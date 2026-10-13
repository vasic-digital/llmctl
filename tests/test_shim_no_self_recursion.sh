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

# --- reviewer shapes: each MUST be reported (these were false negatives of the first version) ---
needle() { # <file> <expected-findings-count> <message>   (body of the planted file on stdin)
  cat >"${C}/$1"; run_lint "${C}/$1"
  assert_eq 1 "${LINT_RC}" "NEEDLE: $3"
  assert_contains "${LINT_OUT}" "findings=$2" "  $3: findings=$2"
}
needle n_brace.sh 1 "brace-group writer { echo ...; } > \$B/tr, body calls tr" <<'EOS'
{ echo '#!/bin/bash'; echo 'tr a b'; } > "$B/tr"
EOS
needle n_brace_multi.sh 1 "multi-line brace group writer" <<'EOS'
{ echo '#!/bin/bash'
  echo 'tr a b'
} > "$B/tr"; chmod +x "$B/tr"
EOS
needle n_tee.sh 1 "heredoc piped to tee \$B/tr" <<'EOS'
cat <<'S' | tee "$B/tr" >/dev/null
#!/bin/bash
tr a b
S
EOS
needle n_loop.sh 2 "loop writer: for t in tr sed; printf '%s \"\$@\"' >\$B/\$t" <<'EOS'
for t in tr sed; do printf '#!/bin/sh\n%s "$@"\n' "$t" > "$B/$t"; done
EOS
needle n_loop_cross.sh 1 "loop writer whose body names ANOTHER name of the loop" <<'EOS'
for t in tr sed; do printf '#!/bin/sh\nsed s/a/b/\n' > "$B/$t"; done
EOS
needle n_noslash.sh 1 "target without a slash: cat >\"tr\"" <<'EOS'
cat >"tr" <<'S'
#!/bin/bash
tr a b
S
EOS
needle n_exec.sh 1 "exec tr \"\$@\" inside shim tr (the most idiomatic recursion)" <<'EOS'
cat >"$B/tr" <<'S'
#!/bin/bash
exec tr "$@"
S
EOS
needle n_wrappers.sh 6 "wrappers env/command/nice/xargs/timeout/nohup before the bare name" <<'EOS'
cat >"$B/tr" <<'S'
#!/bin/bash
env X=1 tr a b
command tr a b
nice -n 5 tr a b
xargs -0 tr a b
timeout 5 tr a b
nohup tr a b
S
EOS
# Go test shim: planted
mkdir -p "${C}/go"
cat >"${C}/go/needle_test.go" <<'EOS'
package x
func fakeGit(t *testing.T) {
	p := filepath.Join(t.TempDir(), "fakegit")
	os.WriteFile(p, []byte("#!/bin/sh\nfakegit status\n"), 0o755)
}
EOS
run_lint "${C}/go/needle_test.go"
assert_eq 1 "${LINT_RC}" "NEEDLE: a Go test shim whose script calls its own name is flagged"
assert_contains "${LINT_OUT}" "go-shim-sites=1" "the Go shim site is counted"

# --- negative controls for the new shapes: each MUST pass ---
cat >"${C}/clean_shapes.sh" <<'EOS'
{ echo '#!/bin/bash'; echo 'exec /usr/bin/tr "$@"'; } > "$B/tr"
cat >"$B/sed" <<'S'
#!/bin/bash
command -v tr >/dev/null && exec "$REAL_SED" "$@"
exec /usr/bin/env /usr/bin/sed "$@"
S
for t in tr sed; do printf '#!/bin/sh\nexec /usr/bin/%s "$@"\n' "$t" > "$B/$t"; done
cat >"tr" <<'S'
#!/bin/bash
exec /usr/bin/tr "$@"
S
EOS
run_lint "${C}/clean_shapes.sh"
assert_eq 0 "${LINT_RC}" "NEGATIVE CONTROL: absolute-path exec in brace/heredoc/loop/no-slash shims, and 'command -v tr', stay clean"
cat >"${C}/go/clean_test.go" <<'EOS'
package x
func fakeGit(t *testing.T) {
	p := filepath.Join(t.TempDir(), "fakegit")
	os.WriteFile(p, []byte("#!/bin/sh\nexit 0\n"), 0o755)
}
EOS
run_lint "${C}/go/clean_test.go"
assert_eq 0 "${LINT_RC}" "NEGATIVE CONTROL: a clean Go test shim passes"
cat >"${C}/unresolved.sh" <<'EOS'
cat >"${STUB}" <<'S'
#!/bin/bash
tr a b
S
EOS
run_lint "${C}/unresolved.sh"
assert_contains "${LINT_OUT}" "name-unresolved=1" "a dynamic, non-loop shim name is COUNTED as unresolved (not silently passed)"

# --- the real tree: coverage is reported, not asserted away ------------------------------------
files=()
for f in "${LLMCTL_ROOT}"/tests/*.sh "${LLMCTL_ROOT}"/tests/*/*.sh "${LLMCTL_ROOT}"/tests/*.py "${LLMCTL_ROOT}"/tests/*/*.py \
         "${LLMCTL_ROOT}"/scripts/*.sh "${LLMCTL_ROOT}"/scripts/*/*.sh "${LLMCTL_ROOT}"/lib/*.sh "${LLMCTL_ROOT}"/internal/*/*_test.go; do
  [[ -f "${f}" ]] && files+=("${f}")
done
run_lint -v "${files[@]}"
printf '%s\n' "${LINT_OUT}" | tail -4 | sed 's/^/  evidence: /'
assert_eq 0 "${LINT_RC}" "no generated shim in tests/ scripts/ lib/ (and no Go test shim literal) calls itself or a sibling by bare name"
sites="$(printf '%s' "${LINT_OUT}" | sed -n 's/.*sh-shebang-sites=\([0-9]*\).*/\1/p')"
recog="$(printf '%s' "${LINT_OUT}" | sed -n 's/.* recognised=\([0-9]*\) .*/\1/p')"
assert_eq "${sites}" "${recog}" "every shell shebang-writing site the lint can see is recognised (${recog}/${sites}); unresolved names and Go/python are reported above, not hidden"
assert_eq "yes" "$([[ ${sites} -ge 100 ]] && echo yes || echo no)" "the lint sees >= 100 shebang-writing sites (${sites})"
test_finish
