#!/usr/bin/env bash
# test_run_live_nli.sh - the live encoder runner specs/009-jev-decision-models/evidence/realcheck/run_live_nli.sh
# must hand the golden/probe clients the REAL gateway access key. Defect (live 2026-10-08, D-06 run): it
# called `llmctl decide key export`, which is the startup-file installer (needs --file, prints nothing to
# stdout), so the key file came out EMPTY and the run stopped with "no access key could be exported"
# (the live agent had to run a hand-edited copy). This test builds the real Go binary into a temp dir,
# creates a real key in a temp LLMCTL_HOME through the real CLI, sources the runner in lib-only mode and
# asserts acquire_access_key writes exactly that key (compared with cmp, never printed), mode 0600.
# It also asserts the runner's live_checks.py path exists in the tree.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

if ! command -v go >/dev/null 2>&1; then
  echo "SKIP-SUITE: go toolchain not installed"; exit 0
fi
RUNNER="${LLMCTL_ROOT}/specs/009-jev-decision-models/evidence/realcheck/run_live_nli.sh"
assert_file_exists "${RUNNER}" "runner present"
BIN="${TEST_TMP}/bin/llmctl-decide"
mkdir -p "${TEST_TMP}/bin"
( cd "${LLMCTL_ROOT}" && go build -o "${BIN}" ./cmd/llmctl-decide )

W="${TEST_TMP}/w"
mkdir -p "${W}/home" "${W}/state" "${W}/data" "${W}/work"
export LLMCTL_DATA_DIR="${W}/data" LLMCTL_STATE_DIR="${W}/state" LLMCTL_HOME="${W}/home" LLMCTL_ENV_FILE="${W}/home/env"
export LLMCTL_DECIDE_BIN="${BIN}"
unset LLMCTL_API_KEY LLMCTL_API_KEY_PREVIOUS 2>/dev/null || true

cd "${LLMCTL_ROOT}"
bin/llmctl decide key rotate >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 0 "${rc}" "a real access key is created in the temp LLMCTL_HOME"
REF="${TEST_TMP}/ref.key"
( umask 077; bin/llmctl decide key show --yes-print > "${REF}" 2>/dev/null )
assert_eq 1 "$(wc -l < "${REF}" | tr -d ' ')" "reference key read back through the real CLI (one line)"

# shellcheck source=/dev/null
RUN_LIVE_NLI_LIB_ONLY=1 source "${RUNNER}"
OUT="${W}/work/access.key"
acquire_access_key "${OUT}" && arc=0 || arc=$?
assert_eq 0 "${arc}" "acquire_access_key exits 0"
if [[ -s "${OUT}" ]]; then sz=nonempty; else sz=empty; fi
assert_eq nonempty "${sz}" "acquire_access_key writes a non-empty key file"
if cmp -s "${REF}" "${OUT}"; then same=yes; else same=no; fi
assert_eq yes "${same}" "the key file holds exactly the gateway access key"
assert_eq 600 "$(stat -c '%a' "${OUT}")" "key file mode 0600"

# the runner calls live_checks.py from its own directory, not a stale path
lc_line="$(grep -E 'live_checks\.py' "${RUNNER}" | grep -v '^#' | head -1)"
assert_contains "${lc_line}" 'RUNNER_DIR}/live_checks.py' "runner resolves live_checks.py beside itself"
assert_file_exists "$(dirname "${RUNNER}")/live_checks.py" "live_checks.py exists beside the runner"

test_finish
