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
# MUTANT_GROUPS (space-separated: judge judge2 judge3 suites record served cleanup enforcement qenv marker interrupt gate policy ramunits ramcap gateway; default all) lets a bounded runner split the work
want() { [[ -z "${MUTANT_GROUPS:-}" || " ${MUTANT_GROUPS} " == *" $1 "* ]]; }

if want judge; then
echo "== judge mutants (each must turn tests/test_validation_judge_soundness.sh RED)"
jm() { # jm <name> <old> <new>
  local m="${TEST_TMP}/jm.$1.py"
  mutate "${J}" "${m}" "$2" "$3"
  caught "judge/$1" "$(run_suite JUDGE_UNDER_TEST="${m}" bash "${T}/test_validation_judge_soundness.sh")" nonzero
}
jm hedged-number '    if len(set(vals)) > 1:' '    if False:'
jm order-subsequence '    return (not neg) and seq == list(range(len(items))), seq' '    return (not neg) and sorted(set(seq)) == list(range(len(items))), seq'
jm negation-ignored '            if not (nxt in _HEDGE_AFTER_NEG and i + 1 != start):
                return True' '            if not (nxt in _HEDGE_AFTER_NEG and i + 1 != start):
                return False'
jm code-operator-ignored '    return (isinstance(e, ast.BinOp) and isinstance(e.op, ast.Add) and isinstance(e.left, ast.Name)' '    return (isinstance(e, ast.BinOp) and isinstance(e.left, ast.Name)'
jm empty-checks-vacuous '    if not isinstance(checks, dict) or not checks:' '    if not isinstance(checks, dict):'
jm json-bool-is-int '    if isinstance(a, bool) or isinstance(b, bool):
        return type(a) is type(b) and a == b' '    if isinstance(a, bool) or isinstance(b, bool):
        return a == b'
jm repeat-once 'DEFAULT_REPEAT = 3' 'DEFAULT_REPEAT = 1'

fi
if want judge2; then
echo "== adversarial-judge mutants (review 2026-10-15 finding 4; each must turn tests/test_validation_judge_adversarial.sh RED)"
j2() { # j2 <name> <old> <new>
  local m="${TEST_TMP}/j2.$1.py"
  mutate "${J}" "${m}" "$2" "$3"
  caught "judge2/$1" "$(run_suite JUDGE_UNDER_TEST="${m}" bash "${T}/test_validation_judge_adversarial.sh")" nonzero
}
j2 unicode-letters-uppercased '        elif unicodedata.category(ch)[0] in "LM":
            out.append(" ")' '        elif unicodedata.category(ch)[0] in "LM":
            out.append(ch.upper())'
j2 post-negation-ignored '    w = [t[0] for t in toks[end + 1:end + 4]]' '    return False'
j2 retraction-ignored '        if _RETRACT_RE.match(up, st):' '        if False:'
j2 json-duplicate-keys '        return json.loads(t, object_pairs_hook=_no_dup_pairs, parse_constant=_bad_constant), None' '        return json.loads(t, parse_constant=_bad_constant), None'
j2 exact-text-substring '            if got != val:
                reasons.append("exact_text' '            if val not in got:
                reasons.append("exact_text'
j2 number-modifiers-ignored '    v = _num_value(t)
    if v is not None:
        return v, None
    m = re.match(r"^(.+?)' '    v = _num_value(t.split()[0] if t.split() else t)
    if v is not None:
        return v, None
    m = re.match(r"^(.+?)'
j2 alternatives-allowed '            elif "OR" in ws:' '            elif False:'

fi
if want judge3; then
echo "== review-3 judge mutants (third 2026-10-15 review findings 1-5; each must turn tests/test_validation_judge_adversarial_r3.sh RED)"
j3() { # j3 <name> <old> <new>
  local m="${TEST_TMP}/j3.$1.py"
  mutate "${J}" "${m}" "$2" "$3"
  caught "judge3/$1" "$(run_suite JUDGE_UNDER_TEST="${m}" bash "${T}/test_validation_judge_adversarial_r3.sh")" nonzero
}
j3 lead-in-trailing-words '            v = _num_value(t[len(lead):].strip(" :"))' '            v = _num_value((t[len(lead):].strip(" :").split() or [""])[0])'
j3 retraction-word-negates '        if i in marks:
            return False' '        if False:
            return False'
j3 abbreviation-period-splits '        if len(a) > 1 and a.endswith(".") and a[-2].isalnum():' '        if False:'
j3 aside-counts-as-claim '    return any(not neg and depth[off] == 0 for' '    return any(not neg for'
j3 extra-label-ignored '    if extra:
        return "words other than the labels' '    if False:
        return "words other than the labels'
j3 denial-clause-unbounded '        if ws[0] in _DENIAL_WORDS and len(rest) <= 1 and' '        if ws[0] in _DENIAL_WORDS and len(rest) <= 9 and'
j3 allow-phrase-as-loose-words '        hit = next((x for x in want if x and words[i:i + len(x)] == x), None)
        if hit is None:
            out.append(words[i])' '        hit = next(([words[i]] for x in want if words[i] in x), None)
        if hit is None:
            out.append(words[i])'
j3 module-statements-allowed '    for i, st in enumerate(tree.body):
        if st is f or' '    for i, st in enumerate([]):
        if st is f or'
j3 calls-allowed '        if isinstance(n, ast.Call):
            return "the code calls' '        if False:
            return "the code calls'
j3 attribute-store-allowed '        if isinstance(n, (ast.Attribute, ast.Subscript)) and isinstance(n.ctx, (ast.Store, ast.Del)):' '        if False:'

fi
if want suites; then
echo "== suite-structure mutant (third 2026-10-15 review finding 13; must turn tests/test_validation_suites.sh RED)"
m="${TEST_TMP}/su.judge.py"
mutate "${J}" "${m}" '                "label_set", "words_allow")' '                "label_set")'
caught "suites/check-unknown-to-judge" "$(run_suite JUDGE_UNDER_TEST="${m}" bash "${T}/test_validation_suites.sh")" nonzero
assert_contains "$(cat "${TEST_TMP}/suite.out")" "unknown check words_allow" "suites/check-unknown-to-judge: the structure check names the check the judge lacks"

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
em optout-consumer-facing-unchecked svc_hook.sh '    if [[ "${cf}" == "False" ]]; then' '    if true; then'

fi
if want qenv; then
echo "== quarantine env-record mutants (third 2026-10-15 review finding 6; each must turn tests/test_validation_quarantine_env.sh RED)"
qm() { # qm <name> <lib-file> <old> <new>
  mutate "${LLMCTL_ROOT}/lib/$2" "${TEST_TMP}/qm.check" "$3" "$4"
  caught "qenv/$1" "$(run_suite QE_MUT_FILE="$2" QE_MUT_OLD="$3" QE_MUT_NEW="$4" bash "${T}/test_validation_quarantine_env.sh")" nonzero
  assert_contains "$(cat "${TEST_TMP}/suite.out")" "MUTANT applied to $2" "qenv/$1: the mutant was really applied"
}
qm stop-keeps-quarantine-record scheduler.sh '    _sched_quarantine_env_restore "${p}"
    rm -f "$(_sched_run_file "${p}")"' '    rm -f "$(_sched_run_file "${p}")"'
qm previous-record-not-saved scheduler.sh '      if ! _sched_quarantine_env_save "${p}"; then' '      if false; then'
qm validator-not-recorded scheduler.sh 'LLMCTL_SVC_QUARANTINE_VALIDATOR="$(proc_identity "$$")"' 'LLMCTL_SVC_QUARANTINE_VALIDATOR=""'
qm dead-validator-honoured svc_hook.sh '        && [[ "${vid}" =~ ^[0-9]+: ]] && [[ "$(proc_identity "${vid%%:*}" 2>/dev/null)" == "${vid}" ]]; then' '        ; then'

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
if want gate; then
echo "== gate-input mutants (review 2026-10-15 findings 3, 5, 9; each must turn tests/test_gate_launch.sh RED)"
gm() { # gm <name> <lib-file> <old> <new>
  mutate "${LLMCTL_ROOT}/lib/$2" "${TEST_TMP}/gm.check" "$3" "$4"
  caught "gate/$1" "$(run_suite GATE_MUT_FILE="$2" GATE_MUT_OLD="$3" GATE_MUT_NEW="$4" bash "${T}/test_gate_launch.sh")" nonzero
  assert_contains "$(cat "${TEST_TMP}/suite.out")" "MUTANT applied to $2" "gate/$1: the mutant was really applied"
}
gm fresh-ignored-before-onstart validate.sh '  if _val_fresh "${p}" "${envf}"; then echo public; return 0; fi' '  :'
gm previous-launch-decides scheduler.sh '    gate="$(_sched_gate_launch "${p}")"' '    gate="$(_sched_gate_for "${p}")"'
gm publish-not-rechecked validate.sh '    if [[ "${LLMCTL_DRY_RUN:-0}" == "1" ]] || _val_fresh "${p}" "${envf}"; then echo public; return 0; fi' '    echo public; return 0'
gm hermetic-variable-alone common.sh '  [[ "${LLMCTL_VALIDATE_HERMETIC:-0}" == "1" && -f "${LLMCTL_STATE_DIR}/.test-harness" && -O "${LLMCTL_STATE_DIR}/.test-harness" ]]' '  [[ "${LLMCTL_VALIDATE_HERMETIC:-0}" == "1" ]]'
gm switch-stops-before-gate scheduler.sh '  if [[ "${tgate}" == refuse:* ]]; then' '  if false; then'
gm external-gets-validated validate.sh '  if [[ "${LLMCTL_VALIDATE_ON_START:-1}" == "external" ]]; then
    local _x' '  if false; then
    local _x'

fi
if want policy; then
echo "== validate-policy mutants (review 2026-10-15 findings 6, 8; each must turn tests/test_validate_policy.sh RED)"
pm() { # pm <name> <lib-file> <old> <new>
  mutate "${LLMCTL_ROOT}/lib/$2" "${TEST_TMP}/pm.check" "$3" "$4"
  caught "policy/$1" "$(run_suite POL_MUT_FILE="$2" POL_MUT_OLD="$3" POL_MUT_NEW="$4" bash "${T}/test_validate_policy.sh")" nonzero
  assert_contains "$(cat "${TEST_TMP}/suite.out")" "MUTANT applied to $2" "policy/$1: the mutant was really applied"
}
pm fail-keeps-serving validate.sh '       sched_stop "${p}" || warn "validation: could not stop '"'"'${p}'"'"' - stop it by hand: llmctl stop ${p}" ;;' '       : ;;'
pm env-not-restored validate.sh '        _val_restore_env
      else' '        :
      else'
# the other manual entry points (each must turn tests/test_validate_policy_entrypoints.sh RED)
pe() { # pe <name> <old> <new>
  mutate "${LLMCTL_ROOT}/lib/validate.sh" "${TEST_TMP}/pe.check" "$2" "$3"
  caught "policy/$1" "$(run_suite POL_MUT_FILE=validate.sh POL_MUT_OLD="$2" POL_MUT_NEW="$3" bash "${T}/test_validate_policy_entrypoints.sh")" nonzero
  assert_contains "$(cat "${TEST_TMP}/suite.out")" "MUTANT applied to validate.sh" "policy/$1: the mutant was really applied"
}
pe vision-keeps-serving '      _val_cli_policy "${vrc}" "${p}" ${rest[@]+"${rest[@]}"} || true   # finding 6 of the 2026-10-15 review' '      :'
pe validate-all-keeps-serving '    _val_cli_policy "${one}" "${p}" "$@" || true     # a FAILING served profile is stopped (finding 6 of the 2026-10-15 review)' '    :'
pe models-verify-keeps-serving '    _val_cli_policy "${vrc}" "${p}" || true          # a FAILING served profile is stopped (finding 6 of the 2026-10-15 review)' '    :'

fi
if want ramunits; then
echo "== unit-RAM mutant (review 2026-10-15 finding 10; must turn tests/test_ramcap_units.sh RED)"
d="$(tree units catalog.sh)"
mutate "${LLMCTL_ROOT}/lib/catalog.sh" "${d}/lib/catalog.sh" '  reserved=$(( reserved + units ))' '  :'
caught "ramunits/units-ignored" "$(run_suite RAMCAP_ROOT_UNDER_TEST="${d}" bash "${T}/test_ramcap_units.sh")" nonzero
ru() { # ru <name> <old> <new> - review 3 of 2026-10-15 finding 7
  local d; d="$(tree "units.$1" catalog.sh)"
  mutate "${LLMCTL_ROOT}/lib/catalog.sh" "${d}/lib/catalog.sh" "$2" "$3"
  caught "ramunits/$1" "$(run_suite RAMCAP_ROOT_UNDER_TEST="${d}" bash "${T}/test_ramcap_units.sh")" nonzero
}
ru fake-honoured-outside-harness '    if validation_hermetic; then
      local i c m h x' '    if true; then
      local i c m h x'
ru unknown-max-high-ignored '  for src in current:"$2" max:"$3" high:"$4"; do' '  for src in current:"$2"; do'
ru unknown-counts-zero '  base="${inst}"
  [[ "${inst}" =~' '  return 0
  [[ "${inst}" =~'

fi
if want ramcap; then
echo "== supply-chain / RAM-cap mutant (must turn tests/test_supply_chain_ramcap.sh RED)"
d="$(tree cap catalog.sh)"
mutate "${LLMCTL_ROOT}/lib/catalog.sh" "${d}/lib/catalog.sh" 'ram_budget = max(0, min(ram_avail_budget, ram_cap - reserved_ram))' 'ram_budget = ram_avail_budget'
caught "ramcap/cap-ignored" "$(run_suite SUPPLY_ROOT_UNDER_TEST="${d}" bash "${T}/test_supply_chain_ramcap.sh")" nonzero

fi
echo "== summary: ${CAUGHT} of ${TOTAL} mutants caught"
assert_eq "${TOTAL}" "${CAUGHT}" "every mutant of the new branches is caught by an assertion"
[[ -n "${MUTANT_GROUPS:-}" ]] || assert_eq 46 "${TOTAL}" "all 46 mutants were run"
test_finish
