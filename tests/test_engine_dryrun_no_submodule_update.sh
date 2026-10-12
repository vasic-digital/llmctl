#!/usr/bin/env bash
# test_engine_dryrun_no_submodule_update.sh - under LLMCTL_DRY_RUN=1 the engine
# build entry points MUST NOT run `git submodule update` (which clones ~1.1 GB
# over SSH). A fake `git` on PATH records every invocation; the dry-run path
# must print the would-run line instead and contact no git submodule/network verb.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env

FAKEBIN="${TEST_TMP}/fakebin"; CALLS="${TEST_TMP}/git-calls.log"
mkdir -p "${FAKEBIN}"; : > "${CALLS}"
cat > "${FAKEBIN}/git" <<EOS
#!/usr/bin/env bash
echo "git \$*" >> "${CALLS}"
exit 0
EOS
chmod +x "${FAKEBIN}/git"

REAL_ROOT="${LLMCTL_ROOT}"
EMPTY_ROOT="${TEST_TMP}/empty-root"; mkdir -p "${EMPTY_ROOT}"   # no submodule dirs

run_in_empty_root() {
  # run_in_empty_root <function> : dry-run, fake git first on PATH, no submodule dirs
  (
    export LLMCTL_ROOT="${EMPTY_ROOT}" LLMCTL_DRY_RUN=1 PATH="${FAKEBIN}:${PATH}"
    source "${REAL_ROOT}/lib/common.sh"
    source "${REAL_ROOT}/lib/os_detect.sh"
    source "${REAL_ROOT}/lib/engine.sh"
    "$1"
  ) 2>&1 || true
}

out="$(run_in_empty_root engine_ensure_submodules)"
assert_contains "${out}" "[dry-run]" "engine_ensure_submodules prints a [dry-run] would-run line"
assert_contains "${out}" "submodule update" "the dry-run line names the git submodule update it skipped"
assert_eq "" "$(grep 'submodule' "${CALLS}" || true)" "engine_ensure_submodules (dry-run) made no git submodule call"

: > "${CALLS}"
run_in_empty_root engine_build_llama >/dev/null
assert_eq "" "$(grep -E 'submodule|clone|fetch|pull' "${CALLS}" || true)" "engine_build_llama (dry-run, no submodule dirs) made no git network/submodule call"

: > "${CALLS}"
run_in_empty_root engine_build_colibri >/dev/null
assert_eq "" "$(grep -E 'submodule|clone|fetch|pull' "${CALLS}" || true)" "engine_build_colibri (dry-run, no submodule dirs) made no git network/submodule call"

# Non-dry-run behaviour is unchanged: the real path still calls submodule update.
: > "${CALLS}"
( export LLMCTL_ROOT="${EMPTY_ROOT}" PATH="${FAKEBIN}:${PATH}"; unset LLMCTL_DRY_RUN
  source "${REAL_ROOT}/lib/common.sh"; source "${REAL_ROOT}/lib/os_detect.sh"; source "${REAL_ROOT}/lib/engine.sh"
  engine_ensure_submodules ) >/dev/null 2>&1 || true
assert_contains "$(cat "${CALLS}")" "submodule update --init --recursive" "non-dry-run engine_ensure_submodules still runs git submodule update"

test_finish
