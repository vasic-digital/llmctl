#!/usr/bin/env bash
# test_no_pipe_grep_q.sh - `echo/printf ... | grep -q` in a pipefail script is a false-null/false-fail trap:
# grep -q exits at the first match, the writer then dies of SIGPIPE (rc 141) once its output exceeds one stdio chunk
# (4 KB for the bash builtin), and pipefail turns a MATCH into a failed pipeline. A secrecy check written this way
# can MISS a real leak (`... | grep -q needle && leak=1`), a positive check can fail on a match (it did: the symlink
# invocation suite, once the plan JSON grew). Use a here-string: `grep -q pattern <<<"$var"`.
# The scan covers every tests/*.sh that enables pipefail; a planted file proves the scanner can see the pattern.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

PAT='(^|[;&|(][[:space:]]*|[[:space:]])(echo|printf)[[:space:]][^|#]*\|[[:space:]]*grep[[:space:]]+(-[A-Za-z]*q[A-Za-z]*|--quiet)'
scan() { # $1 = dir ; prints file:line of offending lines in scripts that enable pipefail
  local f
  for f in "$1"/*.sh; do
    [[ -f "${f}" ]] || continue
    grep -q 'pipefail' "${f}" || continue
    grep -nE "${PAT}" "${f}" | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s#^#${f##*/}:#" || true
  done
}

ctl="$(mktemp -d)"; trap 'rm -rf "${ctl}"' EXIT
printf '#!/usr/bin/env bash\nset -euo pipefail\nout="$(big)"\necho "$out" | grep -q needle && echo hit\n' > "${ctl}/planted.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\ngrep -q needle <<<"$out" && echo ok\n' > "${ctl}/clean.sh"
assert_contains "$(scan "${ctl}")" "planted.sh" "control: the scanner sees a planted echo|grep -q in a pipefail script"
case "$(scan "${ctl}")" in *clean.sh*) assert_eq 0 1 "control: a here-string script is not flagged" ;; *) assert_eq 0 0 "control: a here-string script is not flagged" ;; esac

hits="$(scan "${LLMCTL_ROOT}/tests")"
assert_eq "" "${hits}" "no test pipes echo/printf into grep -q under pipefail"
test_finish
