#!/usr/bin/env bash
# test_docs_diagrams_governance.sh - the governance-facing documentation of llmctl (hub engine role, Constitution
# 11.4.277 / 11.4.278 / 11.4.279, claude_toolkit JEV integration) and the diagrams under docs/diagrams/ (11.4.258).
# Each assertion reads the real files. Instrument check first: a needle that cannot exist is reported as absent
# (negative control) and a needle that must exist is found (positive control), so a silent grep failure cannot pass.
# Static, hermetic: reads the repository only, starts nothing, touches no model.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
R="${LLMCTL_ROOT}"

has() { grep -qiE -- "$2" "$1"; }   # file, extended regex (case-insensitive)

# --- instrument controls
if has "${R}/README.md" 'ZZNEEDLEQQ9-no-such-text'; then assert_eq absent present "negative control: an impossible needle is not found"; else assert_eq 1 1 "negative control: an impossible needle is not found"; fi
has "${R}/README.md" 'llmctl' && assert_eq 1 1 "positive control: 'llmctl' is found in README.md"

# --- required topics per document (all must be present)
need() { # <file> <label> <regex>
  if has "${R}/$1" "$3"; then assert_eq 1 1 "$1 mentions $2"; else assert_eq present absent "$1 mentions $2"; fi
}
for f in README.md docs/user-manual.md docs/faq.md docs/validation.md; do
  need "$f" "hub engine"              'hub engine'
  need "$f" "Constitution 11.4.277"   '11\.4\.277'
  need "$f" "Constitution 11.4.278"   '11\.4\.278'
done
for f in README.md docs/user-manual.md docs/faq.md docs/decision-models.md docs/decide-gateway.md; do
  need "$f" "Constitution 11.4.279"   '11\.4\.279'
  need "$f" "claude_toolkit JEV"      'claude_toolkit'
done
for f in README.md docs/user-manual.md docs/faq.md docs/validation.md docs/decision-models.md docs/decide-gateway.md; do
  need "$f" "11.4.28(C) / 11.4.31 resolver or manifest" '11\.4\.28\(C\)|11\.4\.31'
done
need docs/validation.md  "exit codes 75 and 98"      '75.*98|98.*75'
need docs/validation.md  "model identity / tiers"    'model identity'
need docs/decide-gateway.md "bearer key"             'bearer'
need docs/decide-gateway.md "HTTPS"                  'https'
need docs/validation.md  "vision-pro tier"           'vision-pro'

# --- diagrams: source, rendered svg (or an honest recorded skip), embedded at point of use, index linked from README
D="${R}/docs/diagrams"
assert_file_exists "${D}/README.md" "docs/diagrams/README.md (index)"
need README.md "diagram index link" 'docs/diagrams/README\.md'
# name:doc-that-embeds-it
for pair in validation-gate:docs/validation.md decide-gateway-flow:docs/decide-gateway.md \
            hub-engine-placement:docs/dependency-layout.md vision-tiers:docs/validation.md; do
  n="${pair%%:*}"; doc="${pair#*:}"
  assert_file_exists "${D}/${n}.mmd" "diagram source ${n}.mmd"
  [ -s "${D}/${n}.mmd" ] && assert_eq 1 1 "${n}.mmd is non-empty" || assert_eq nonempty empty "${n}.mmd is non-empty"
  if [ -f "${D}/${n}.svg" ]; then
    [ -s "${D}/${n}.svg" ] && grep -q '<svg' "${D}/${n}.svg" && assert_eq 1 1 "${n}.svg is a non-empty svg" || assert_eq svg notsvg "${n}.svg is a non-empty svg"
  else
    has "${D}/README.md" "${n}.*(not rendered|SKIP)" && assert_eq 1 1 "${n}.svg absent but the index records the honest SKIP" || assert_eq svg none "${n}.svg exists or the index records a SKIP"
  fi
  # embedded: the doc holds a mermaid block whose body is byte-identical to the .mmd source
  got="$(python3 - "${D}/${n}.mmd" "${R}/${doc}" <<'PY'
import re,sys
src=open(sys.argv[1]).read().strip()
doc=open(sys.argv[2]).read()
blocks=[b.strip() for b in re.findall(r"```mermaid\n(.*?)```", doc, re.S)]
print("embedded" if src in blocks else "missing")
PY
)"
  assert_eq embedded "${got}" "${n}.mmd is embedded verbatim as a mermaid block in ${doc}"
  need "${doc}" "link to diagrams/${n}" "diagrams/${n}"
done
# the validation-gate diagram must carry every exit code of the contract
for c in 0 1 2 75 98; do
  has "${D}/validation-gate.mmd" "(exit|rc|code).*\\b${c}\\b" && assert_eq 1 1 "validation-gate.mmd shows exit code ${c}" || assert_eq present absent "validation-gate.mmd shows exit code ${c}"
done
need docs/diagrams/decide-gateway-flow.mmd "bearer"   'bearer'
need docs/diagrams/decide-gateway-flow.mmd "HTTPS"    'https'
need docs/diagrams/hub-engine-placement.mmd "resolver" 'resolve'

# --- manifest validity (Constitution 11.4.31) through the canonical engine when present (else honest SKIP)
V="${LLMCTL_CONSTITUTION_VERIFY:-}"
if [ -z "${V}" ]; then
  cdir="$(bash "${R}/lib/resolve_deps.sh" constitution 2>/dev/null | tail -1 || true)"
  [ -n "${cdir}" ] && V="${cdir}/scripts/deps_manifest/verify_helix_deps_manifests.sh"
fi
if [ -n "${V}" ] && [ -f "${V}" ]; then
  rc=0; bash "${V}" --validate-file "${R}/helix-deps.yaml" >/dev/null 2>&1 || rc=$?
  assert_eq 0 "${rc}" "helix-deps.yaml validates through the canonical 11.4.31 engine"
else
  assert_skip "canonical verify_helix_deps_manifests.sh not resolvable here (set LLMCTL_CONSTITUTION_VERIFY)" "helix-deps.yaml validates through the canonical 11.4.31 engine"
fi

# --- release metadata coherence
v="$(tr -d '[:space:]' <"${R}/VERSION")"
has "${R}/CHANGELOG.md" "^## v?${v//./\\.}( |$)" && assert_eq 1 1 "CHANGELOG.md has a section for VERSION ${v}" || assert_eq present absent "CHANGELOG.md has a section for VERSION ${v}"
test_finish
