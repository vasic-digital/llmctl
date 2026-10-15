#!/usr/bin/env bash
# test_validation_mutants.sh - mutation proof for the branches added by the 2026-10-14 fix round (independent review
# findings 1-10). Each mutant re-introduces ONE defect into a COPY of the code (the repository is never modified), and an
# assertion must catch it. For every mutant this file first proves the mutant really differs from the original (a sed that
# matched nothing would be a bluff), then runs the check that must turn RED.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
FAKE_PIDS_FILE="$(mktemp)"
cleanup() { local p; while read -r p; do [[ -n "${p}" ]] && kill "${p}" 2>/dev/null || true; done < "${FAKE_PIDS_FILE}"; rm -f "${FAKE_PIDS_FILE}"; test_teardown_env; }
trap cleanup EXIT
T="${LLMCTL_ROOT}/tests"
J="${LLMCTL_ROOT}/lib/validate_judge.py"
CAUGHT=0; TOTAL=0

# mutate <src> <dst> <python-literal-old> <python-literal-new> - exact single replacement; fails the test when absent
mutate() {
  python3 -I - "$1" "$2" "$3" "$4" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
if s.count(old) != 1:
    sys.exit("mutation anchor found %d times in %s: %r" % (s.count(old), src, old))
open(dst, "w").write(s.replace(old, new))
PY
}
# caught <name> <rc-of-the-check> <expect-nonzero|expect:<rc>> - one mutant's verdict
caught() {
  local name="$1" rc="$2" want="$3" ok=0
  TOTAL=$((TOTAL+1))
  if [[ "${want}" == nonzero ]]; then [[ "${rc}" != 0 ]] && ok=1; else [[ "${rc}" == "${want#expect:}" ]] && ok=1; fi
  if (( ok )); then CAUGHT=$((CAUGHT+1)); printf '  ok: %s - caught (check rc=%s)\n' "${name}" "${rc}"
  else printf '  FAIL: %s - NOT caught (check rc=%s, wanted %s)\n' "${name}" "${rc}" "${want}" >&2; TEST_FAILS=$((TEST_FAILS+1)); fi
}
# lib_copy <dir> <file-to-copy> - a lib dir with every file symlinked except <file> (copied, to be mutated)
lib_copy() {
  local d="$1" keep="$2" f
  mkdir -p "${d}"
  for f in "${LLMCTL_ROOT}"/lib/*; do
    [[ "$(basename "${f}")" == "${keep}" ]] && cp "${f}" "${d}/" || ln -sf "${f}" "${d}/"
  done
}
# tree <name> <lib-file> - a throw-away llmctl tree (bin/llmctl copied, lib/<lib-file> copied, the rest symlinked)
tree() {
  local d="${TEST_TMP}/tree.$1" e
  mkdir -p "${d}/bin"
  for e in "${LLMCTL_ROOT}"/*; do case "$(basename "${e}")" in bin|lib) ;; *) ln -s "${e}" "${d}/$(basename "${e}")" ;; esac; done
  cp "${LLMCTL_ROOT}/bin/llmctl" "${d}/bin/llmctl"
  lib_copy "${d}/lib" "$2"
  printf '%s\n' "${d}"
}
run_suite() { local rc=0; env "$@" >"${TEST_TMP}/suite.out" 2>&1 || rc=$?; echo "${rc}"; }
# MUTANT_GROUPS (space-separated: judge record served cleanup enforcement marker interrupt ramcap; default all) lets a bounded runner split the work
want() { [[ -z "${MUTANT_GROUPS:-}" || " ${MUTANT_GROUPS} " == *" $1 "* ]]; }

if want judge; then
echo "== judge mutants (each must turn tests/test_validation_judge_soundness.sh RED)"
jm() { # jm <name> <old> <new>
  local m="${TEST_TMP}/jm.$1.py"
  mutate "${J}" "${m}" "$2" "$3"
  caught "judge/$1" "$(run_suite JUDGE_UNDER_TEST="${m}" bash "${T}/test_validation_judge_soundness.sh")" nonzero
}
jm hedged-number '    if len(vals) > 1:' '    if False:'
jm order-subsequence '    return seq == list(range(len(items))), seq' '    return sorted(set(seq)) == list(range(len(items))), seq'
jm negation-ignored '        if w in _NEG_WORDS or (w == "T" and i > 0 and toks[i - 1][0] in _NT_PREFIX):
            return True' '        if w in _NEG_WORDS or (w == "T" and i > 0 and toks[i - 1][0] in _NT_PREFIX):
            return False'
jm comments-kept '        return _strip_python_comments(src)' '        return src'
jm empty-checks-vacuous '    if not isinstance(checks, dict) or not checks:' '    if not isinstance(checks, dict):'
jm json-bool-is-int '    if isinstance(a, bool) or isinstance(b, bool):
        return type(a) is type(b) and a == b' '    if isinstance(a, bool) or isinstance(b, bool):
        return a == b'
jm repeat-once 'DEFAULT_REPEAT = 3' 'DEFAULT_REPEAT = 1'

fi
if want record; then
echo "== record mutants (each must turn tests/test_validation_record_integrity.sh RED)"
rm_() { # rm_ <name> <old> <new>
  local d; d="$(tree "rec.$1" validate_judge.py)"
  mutate "${LLMCTL_ROOT}/lib/validate_judge.py" "${d}/lib/validate_judge.py" "$2" "$3"
  caught "record/$1" "$(run_suite LLMCTL_ROOT="${d}" VL_LLMCTL_OVERRIDE="${d}/bin/llmctl" bash "${T}/test_validation_record_integrity.sh")" nonzero
}
rm_ unsigned-accepted '    elif not signature_ok(state, hkey):' '    elif False:'
rm_ ctime-ignored '    return [st.st_size, st.st_mtime_ns, st.st_ctime_ns, st.st_ino, st.st_dev]' '    return [st.st_size, st.st_mtime_ns, st.st_ino, st.st_dev]'
rm_ nan-age '    if not math.isfinite(v) or v < 0:' '    if v < 0:'
rm_ undetermined-overwrites-fail '    if a.status == "undetermined" and prior.get("status") in ("pass", "fail"):' '    if a.status == "undetermined" and prior.get("status") == "pass":'
rm_ evidence-unbound '    if not cur or cur != evsha:' '    if False:'

fi
if want served; then
echo "== served-model mutant (must turn tests/test_validation_served_identity.sh RED)"
d="$(tree served validate_judge.py)"
mutate "${LLMCTL_ROOT}/lib/validate_judge.py" "${d}/lib/validate_judge.py" '        if sm.get("mismatch"):
            out("[UNDETERMINED] served model file: %s" % sm["mismatch"])' '        if False:
            out("[UNDETERMINED] served model file: %s" % sm["mismatch"])'
caught "served/mismatch-ignored" "$(run_suite LLMCTL_ROOT="${d}" VL_LLMCTL_OVERRIDE="${d}/bin/llmctl" bash "${T}/test_validation_served_identity.sh")" nonzero

fi
if want cleanup; then
echo "== cleanup mutant (must turn tests/test_validation_cleanup.sh RED)"
lib_copy "${TEST_TMP}/cl" validate.sh
mutate "${LLMCTL_ROOT}/lib/validate.sh" "${TEST_TMP}/cl/validate.sh" '        sched_stop "${p}" >/dev/null 2>&1 || warn "could not stop '"'"'${p}'"'"' after validation - stop it by hand: llmctl stop ${p}"' '        :'
caught "cleanup/started-profile-left-running" "$(run_suite VALIDATE_LIB_UNDER_TEST="${TEST_TMP}/cl/validate.sh" bash "${T}/test_validation_cleanup.sh")" nonzero

fi
if want enforcement; then
echo "== enforcement mutants (each must turn tests/test_validation_enforcement.sh RED)"
em() { # em <name> <lib-file> <old> <new> - applied by the enforcement test to its own throw-away tree (ENF_MUT_*)
  mutate "${LLMCTL_ROOT}/lib/$2" "${TEST_TMP}/em.check" "$3" "$4"     # proves the anchor exists exactly once
  caught "enforcement/$1" "$(run_suite ENF_MUT_FILE="$2" ENF_MUT_OLD="$3" ENF_MUT_NEW="$4" bash "${T}/test_validation_enforcement.sh")" nonzero
  assert_contains "$(cat "${TEST_TMP}/suite.out")" "MUTANT applied to $2" "enforcement/$1: the mutant was really applied"
}
em strict-off-by-default validate.sh '  [[ "${LLMCTL_VALIDATE_STRICT:-1}" == "0" ]] || return 0' '  [[ "${LLMCTL_VALIDATE_STRICT:-0}" == "0" ]] || return 0'
em quarantine-binds-public scheduler.sh '    [[ "${SCHED_ARGS[i]}" == "--host" ]] && SCHED_ARGS[i+1]="127.0.0.1"' '    :'
em unit-gate-open svc_hook.sh '  printf '"'"'llmctl: profile %s is not validated (no fresh, signed PASS record); not starting. Run: llmctl start %s\n'"'"' "${prof}" "${prof}" >&2
  return 77' '  return 0'
em consumer-facing-ignored validate.sh '  _val_consumer_facing "$1" && return 0
  return 1' '  return 1'

fi
if want marker; then
echo "== install-marker mutants (review 2026-10-15 finding 1; each must turn tests/test_enforcement_marker.sh RED)"
mm() { # mm <name> <lib-file> <old> <new>
  mutate "${LLMCTL_ROOT}/lib/$2" "${TEST_TMP}/mm.check" "$3" "$4"
  caught "marker/$1" "$(run_suite MARK_MUT_FILE="$2" MARK_MUT_OLD="$3" MARK_MUT_NEW="$4" bash "${T}/test_enforcement_marker.sh")" nonzero
  assert_contains "$(cat "${TEST_TMP}/suite.out")" "MUTANT applied to $2" "marker/$1: the mutant was really applied"
}
mm waiter-ignores-marker svc_hook.sh '  if ! enforcement_installed; then
    _hk_wait_register' '  if false; then
    _hk_wait_register'
mm condition-ignores-marker svc_hook.sh '  if ! enforcement_installed; then
    _hk_log "${inst}: unit-level' '  if false; then
    _hk_log "${inst}: unit-level'
mm marker-always-on common.sh '  [[ "${v}" =~ ^[0-9]+$ ]] && (( v >= 1 ))' '  return 0'
mm install-writes-no-marker service_linux.sh '  if enforcement_mark_installed; then
    info "unit-level' '  if true; then
    info "unit-level'

fi
if want interrupt; then
echo "== interruption mutants (review 2026-10-15 finding 2; each must turn tests/test_validate_interrupt.sh RED)"
im() { # im <name> <lib-file> <old> <new>
  mutate "${LLMCTL_ROOT}/lib/$2" "${TEST_TMP}/im.check" "$3" "$4"
  caught "interrupt/$1" "$(run_suite INT_MUT_FILE="$2" INT_MUT_OLD="$3" INT_MUT_NEW="$4" bash "${T}/test_validate_interrupt.sh")" nonzero
  assert_contains "$(cat "${TEST_TMP}/suite.out")" "MUTANT applied to $2" "interrupt/$1: the mutant was really applied"
}
im lock-not-reentrant scheduler.sh '  if [[ -n "${_SCHED_LOCK_OWNER}" && "${_SCHED_LOCK_OWNER}" == "${BASHPID}" ]]; then' '  if false; then'
im rfiles-declared-late validate.sh '  local evidence="" run_ev="" vfile=""
  local -a rfiles=()' '  local evidence="" run_ev="" vfile=""'
im quarantine-left-on-interrupt validate.sh '    elif [[ -z "${host}" ]] && _val_is_quarantined "${p}"; then' '    elif false; then'
im after-start-handler-inert validate.sh '      if _val_is_quarantined "${q}"; then
        warn "interrupted: stopping the quarantined' '      if false; then
        warn "interrupted: stopping the quarantined'

fi
if want ramcap; then
echo "== supply-chain / RAM-cap mutant (must turn tests/test_supply_chain_ramcap.sh RED)"
d="$(tree cap catalog.sh)"
mutate "${LLMCTL_ROOT}/lib/catalog.sh" "${d}/lib/catalog.sh" 'ram_budget = max(0, min(ram_avail_budget, ram_cap - reserved_ram))' 'ram_budget = ram_avail_budget'
caught "ramcap/cap-ignored" "$(run_suite SUPPLY_ROOT_UNDER_TEST="${d}" bash "${T}/test_supply_chain_ramcap.sh")" nonzero

fi
echo "== summary: ${CAUGHT} of ${TOTAL} mutants caught"
assert_eq "${TOTAL}" "${CAUGHT}" "every mutant of the new branches is caught by an assertion"
[[ -n "${MUTANT_GROUPS:-}" ]] || assert_eq 27 "${TOTAL}" "all 27 mutants were run"
test_finish
