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

# Wiring (live 2026-10-08 D-06 re-run): the gateway only learns a hand-started engine's address from
# LLMCTL_DECIDE_ENDPOINT_<PROFILE> (which wins) or LLMCTL_PORT_<PROFILE> (precedence ENDPOINT > PORT > catalog,
# internal/gateway/resolver.go) and the CLI client only finds a
# non-default gateway through LLMCTL_DECIDE_PORT. Missing either made every golden request 503 not_ready
# and `decide models` "connection refused" while the engine itself was healthy. Behavioural checks: the
# real functions run, the effective environment / exit status / RESULT file are asserted.
unset LLMCTL_DECIDE_ENDPOINT_DECIDE_NLI LLMCTL_DECIDE_PORT LLMCTL_PORT_DECIDE_NLI
wire_gateway_env 8196 8195
assert_eq "http://127.0.0.1:8196" "${LLMCTL_DECIDE_ENDPOINT_DECIDE_NLI:-}" "wire_gateway_env points the gateway at the hand-started engine"
assert_eq "8195" "${LLMCTL_DECIDE_PORT:-}" "wire_gateway_env points the CLI client at its gateway port"
assert_eq "8196" "${LLMCTL_PORT_DECIDE_NLI:-}" "wire_gateway_env also exports the engine port override"
# the main flow must actually call wire_gateway_env and preflight_gateway (not merely define them)
main_wire="$(grep -cE '^wire_gateway_env "\$\{ENG_PORT\}" "\$\{GW_PORT\}"$' "${RUNNER}" || true)"
assert_eq 1 "${main_wire}" "the runner calls wire_gateway_env with the engine and gateway ports"
main_pf="$(grep -cE '^preflight_gateway .*\|\| exit 5$' "${RUNNER}" || true)"
assert_eq 1 "${main_pf}" "the runner aborts (exit 5) when the pre-flight fails"
# preflight behaviour: ready row passes; not-ready / absent / unreadable all fail and write FAILED-PREFLIGHT
printf 'decide-nli               ready    nli-onnx\n' > "${W}/work/m_ready.txt"
printf 'decide-nli               degraded nli-onnx\n' > "${W}/work/m_degraded.txt"
printf 'decide-2b                ready    letter-logit\n' > "${W}/work/m_other.txt"
preflight_gateway decide-nli "${W}/work/m_ready.txt" "${W}/work/r1.txt" && prc=0 || prc=$?
assert_eq 0 "${prc}" "pre-flight passes when the profile is ready"
for f in m_degraded m_other m_missing; do
  rm -f "${W}/work/r2.txt"
  preflight_gateway decide-nli "${W}/work/${f}.txt" "${W}/work/r2.txt" && prc=0 || prc=$?
  assert_eq 1 "${prc}" "pre-flight fails for ${f}"
  assert_contains "$(cat "${W}/work/r2.txt")" "FAILED-PREFLIGHT" "pre-flight writes FAILED-PREFLIGHT for ${f}"
done
# cleanup must stop the gateway and redact the engine log even on early exits. Behavioural: the real cleanup()
# body (extracted from the runner, which defines it after the lib-only return) runs in a subshell whose
# bin/llmctl is a recording stub; the planted token must be gone and the stop command recorded.
CLR="${W}/cl"; mkdir -p "${CLR}/bin" "${CLR}/out"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/calls.txt"\n' "${CLR}" > "${CLR}/bin/llmctl"; chmod +x "${CLR}/bin/llmctl"
printf 'GET /x\nAuthorization: Bearer abc123\nkeep this line\n' > "${CLR}/out/engine.log"
cl_body="$(sed -n '/^cleanup() {/,/^}/p' "${RUNNER}")"
# shellcheck disable=SC2034  # PID is read by the eval'd cleanup() body
( cd "${CLR}"; OUT="${CLR}/out"; PID=""; eval "${cl_body}"; cleanup ) >/dev/null 2>&1 || true
cl_log="$(cat "${CLR}/out/engine.log")"
assert_contains "${cl_log}" "Bearer <redacted>" "cleanup redacts the bearer token in the engine log"
assert_contains "${cl_log}" "keep this line" "cleanup leaves the rest of the engine log intact"
if [[ "${cl_log}" == *abc123* ]]; then leak=yes; else leak=no; fi
assert_eq no "${leak}" "the planted token no longer appears in the engine log"
assert_contains "$(cat "${CLR}/calls.txt" 2>/dev/null)" "decide serve --stop" "cleanup actually invokes the gateway stop command"
test_finish
