#!/usr/bin/env bash
# test_syntax.sh - bash -n syntax check of every shipped script.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

shopt -s nullglob
scripts=( "${LLMCTL_ROOT}/bin/llmctl" "${LLMCTL_ROOT}"/lib/*.sh "${LLMCTL_ROOT}"/tests/*.sh "${LLMCTL_ROOT}"/docs/integrations/*.sh "${LLMCTL_ROOT}"/scripts/release/*.sh )
echo "checking ${#scripts[@]} scripts with bash -n"
for s in "${scripts[@]}"; do
  rc=0
  bash -n "${s}" || rc=$?
  assert_eq 0 "${rc}" "bash -n ${s#"${LLMCTL_ROOT}/"}"
done

# strict_ok <repo-relative-name> <file> -> rc 0 when the file declares strict mode.
# -e may be waived ONLY for the few suites in the allow-list below that must run failing commands on purpose, and only with an
# in-file "# STRICT-EXEMPT: <reason of at least 3 words>" line; they must still set -u and pipefail.
strict_ok() {
  grep -q 'set -euo pipefail' "$2" && return 0
  case "$1" in
    tests/test_livetest_watchdog.sh)
      [[ "$(grep -m1 '^# STRICT-EXEMPT: ' "$2" | sed 's/^# STRICT-EXEMPT: //' | wc -w)" -ge 3 ]] && grep -q '^set -uo pipefail' "$2" && return 0 ;;
  esac
  return 1
}
# negative controls of the rule itself
ctl="$(mktemp -d)"; mkdir -p "${ctl}/tests"
printf '#!/usr/bin/env bash\n# STRICT-EXEMPT: needs failures\nset -uo pipefail\n' > "${ctl}/two_words.sh"
printf '#!/usr/bin/env bash\n# STRICT-EXEMPT: runs failing commands on purpose\nset -uo pipefail\n' > "${ctl}/not_allow_listed.sh"
printf '#!/usr/bin/env bash\n# STRICT-EXEMPT: runs failing commands on purpose\nset -uo pipefail\n' > "${ctl}/tests/test_livetest_watchdog.sh"
printf '#!/usr/bin/env bash\n# STRICT-EXEMPT: two words\nset -uo pipefail\n' > "${ctl}/tests/short.sh"
printf '#!/usr/bin/env bash\nset -uo pipefail\n' > "${ctl}/tests/noreason.sh"
assert_eq 1 "$(strict_ok tests/test_livetest_watchdog.sh "${ctl}/two_words.sh" && echo 0 || echo 1)" "exemption with a 2-word reason is refused"
assert_eq 1 "$(strict_ok tests/test_other.sh "${ctl}/not_allow_listed.sh" && echo 0 || echo 1)" "exemption in a file that is not allow-listed is refused"
assert_eq 1 "$(strict_ok tests/test_livetest_watchdog.sh "${ctl}/tests/noreason.sh" && echo 0 || echo 1)" "no STRICT-EXEMPT line is refused"
assert_eq 0 "$(strict_ok tests/test_livetest_watchdog.sh "${ctl}/tests/test_livetest_watchdog.sh" && echo 0 || echo 1)" "control: allow-listed file + >=3-word reason + set -uo pipefail is accepted"
rm -rf "${ctl}"

# Every shipped script must declare the bash shebang and strict mode.
for s in "${scripts[@]}"; do
  head -1 "${s}" | grep -q '^#!/usr/bin/env bash' \
    && assert_eq 0 0 "shebang: ${s#"${LLMCTL_ROOT}/"}" \
    || { assert_eq 0 1 "shebang: ${s#"${LLMCTL_ROOT}/"}"; }
  if strict_ok "${s#"${LLMCTL_ROOT}/"}" "${s}"; then
    assert_eq 0 0 "strict mode: ${s#"${LLMCTL_ROOT}/"}"
  else
    assert_eq 0 1 "strict mode: ${s#"${LLMCTL_ROOT}/"}"
  fi
done

test_finish
