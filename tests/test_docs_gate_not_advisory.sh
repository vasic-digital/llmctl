#!/usr/bin/env bash
# test_docs_gate_not_advisory.sh - the validation gate is ENFORCED (docs/validation.md, "Enforcement (strict by default)"):
# every path that brings a profile up runs the hook, FAIL stops the profile, UNDETERMINED never stops/passes (strict: stops).
# Shipped prose must not still call it advisory, say a wrong answer keeps serving, or say systemd-started units skip the hook.
# The scanner is proven first: each stale shape planted in a temp file MUST be flagged, an allowed sentence MUST NOT be.
# Scope: README.md, CHANGELOG.md, docs/*.md (not docs/qa evidence, not specs), bin/llmctl help text.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT

# One ERE per stale claim about the validation gate. "advisory flock" and the tier gate are different things and not matched.
STALE='((validation|hook|gate)( step)? (is|stays|remains) advisory|The validation gate is advisory|The hook is advisory|gate is advisory'
STALE+='|(a )?(wrong|failing) (answer|model)[^.|]{0,60}(leaves the service running|keeps? serving|still serving)'
STALE+='|still serving, exit 1|only `?require-validated`? refuses'
STALE+='|(systemd|units started by systemd)[^.]{0,80}never (run|pass through) the (validation )?hook'
STALE+='|never (run|pass through) the hook|but not the validation step'
STALE+='|do(es)? not (pass through|run) the (validation )?hook|hook runs after `start`, `switch` and `auto`( \(|\.|;|$)'
STALE+=')'

scan() { # <file...>: print file:line of stale hits
  grep -n -i -E "${STALE}" "$@" 2>/dev/null || true
}

# --- scanner proof ---
ctl="${TEST_TMP}/ctl.md"
printf '%s\n' \
  'The validation gate is advisory.' \
  'A wrong answer after start leaves the service running; only `require-validated` refuses.' \
  'Units started by systemd never run the hook.' \
  'V -- exit 1 wrong answer --> BAD[still serving, exit 1 reported]' \
  'The failing model keeps serving after start.' \
  'units started by systemd (boot, `enable`, `restart`) do not pass through the validation hook.' \
  'the validation hook runs after `start`, `switch` and `auto` (only for the profiles they started)' >"${ctl}"
n="$(scan "${ctl}" | wc -l)"
assert_eq 7 "${n}" "scanner flags every planted stale shape"
ok="${TEST_TMP}/ok.md"
printf '%s\n' 'An advisory flock serialises the scheduler.' 'Tier gating is advisory for explicit starts.' \
  'The gate is no longer enforced only by require-validated.' 'A FAIL stops the profile.' >"${ok}"
n="$(scan "${ok}" | wc -l)"
assert_eq 0 "${n}" "scanner leaves allowed sentences alone (advisory flock, tier gate, FAIL stops)"

# --- the real tree ---
cd "${LLMCTL_ROOT}"
files=(README.md CHANGELOG.md bin/llmctl)
while IFS= read -r f; do files+=("$f"); done < <(find docs -maxdepth 1 -name '*.md' | sort)
# The release notes live outside the repository (the release directory); LLMCTL_RELEASE_NOTES overrides the path.
notes="${LLMCTL_RELEASE_NOTES:-${HOME}/llmctl-release-3.2.2/RELEASE_NOTES.md}"
if [[ -f "${notes}" ]]; then files+=("${notes}"); else echo "  SKIP: release notes not found at ${notes} (not scanned)"; fi
hits="$(scan "${files[@]}")"
assert_eq "" "${hits}" "no shipped doc or help text calls the validation gate advisory (hits: ${hits})"

# --- the truth is still stated where it must be ---
assert_contains "$(cat docs/validation.md)" "The gate is no longer advisory" "docs/validation.md states the enforcement"
assert_contains "$(cat docs/limitations.md)" "validation gate is enforced" "docs/limitations.md states the gate is enforced"
assert_contains "$(bash bin/llmctl help 2>&1 || true)" "a FAIL stops the profile" "llmctl help says a FAIL stops the profile"
assert_contains "$(cat docs/limitations.md)" "LLMCTL_PORTREG" "docs/limitations.md states the waiter needs the port registry"
assert_contains "$(cat docs/validation.md)" "LLMCTL_PORTREG" "docs/validation.md states the waiter needs the port registry"
test_finish
