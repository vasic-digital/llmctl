#!/usr/bin/env bash
# test_engine_build_onnx.sh - `llmctl build onnx`: hash-locked private venv (D-16).
# Offline cases always run: UNPINNED/hashless/missing lock => REFUSE, dry-run
# creates nothing and prints the real pins, the committed lock really carries
# sha256 hashes for every direct dependency. The live install + tamper cases
# need PyPI and run only with LLMCTL_TEST_NETWORK=1 (else a printed SKIP).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
test_setup_env
trap test_teardown_env EXIT
source "${LLMCTL_ROOT}/lib/common.sh"
source "${LLMCTL_ROOT}/lib/engine.sh"

LOCK="${LLMCTL_ROOT}/lib/lock/requirements-onnx.lock"
assert_file_exists "${LOCK}" "committed lock file lib/lock/requirements-onnx.lock exists"
for pkg in onnxruntime numpy sentencepiece tokenizers; do
  assert_eq 1 "$(grep -cE "^${pkg}==[0-9]" "${LOCK}" | awk '$1>=1{print 1; exit} {print 0}')" "lock pins ${pkg} with =="
done
assert_eq 1 "$(grep -cE -- '--hash=sha256:[0-9a-f]{64}' "${LOCK}" | awk '$1>=100{print 1; exit} {print 0}')" "lock carries many real sha256 hashes"
assert_eq 0 "$(grep -c 'UNPINNED' "${LOCK}" || true)" "committed lock is not marked UNPINNED"

# refusal: UNPINNED marker
printf '# UNPINNED: hashes could not be obtained\nonnxruntime\n' > "${TEST_TMP}/unpinned.lock"
rc=0; out="$(LLMCTL_ONNX_LOCK="${TEST_TMP}/unpinned.lock" engine_build_onnx 2>&1)" || rc=$?
assert_eq "1" "$( [[ ${rc} -ne 0 ]] && echo 1 || echo 0)" "UNPINNED lock: build refuses (non-zero exit)"
assert_contains "${out}" "UNPINNED" "UNPINNED lock: message names the marker"
assert_file_absent "${LLMCTL_DATA_DIR}/venv-onnx" "UNPINNED lock: no venv created"
# refusal: no hashes
printf 'onnxruntime==1.30.0\nnumpy==2.4.6\n' > "${TEST_TMP}/nohash.lock"
rc=0; out="$(LLMCTL_ONNX_LOCK="${TEST_TMP}/nohash.lock" engine_build_onnx 2>&1)" || rc=$?
assert_eq "1" "$( [[ ${rc} -ne 0 ]] && echo 1 || echo 0)" "hashless lock: build refuses"
assert_contains "${out}" "no sha256 hashes" "hashless lock: message"
# refusal: missing lock
rc=0; out="$(LLMCTL_ONNX_LOCK="${TEST_TMP}/absent.lock" engine_build_onnx 2>&1)" || rc=$?
assert_eq "1" "$( [[ ${rc} -ne 0 ]] && echo 1 || echo 0)" "missing lock: build refuses"
# dry run
out="$(LLMCTL_DRY_RUN=1 engine_build_onnx 2>&1)"
assert_contains "${out}" "onnxruntime==" "dry-run prints the pinned onnxruntime version (D-16 hint carries a pin)"
assert_contains "${out}" "--require-hashes" "dry-run states hashes are verified"
assert_file_absent "${LLMCTL_DATA_DIR}/venv-onnx" "dry-run creates no venv"

# --- C-04: the venv location is never deleted unless llmctl made it --------------------------------
FAKE_HOME="${TEST_TMP}/fakehome"; mkdir -p "${FAKE_HOME}/projects/precious"
echo "my work" > "${FAKE_HOME}/projects/precious/file.txt"
# (only throw-away paths under TEST_TMP go through the real build; the install root, / and relative
# paths are checked with the pure predicate so a regression can never delete the repository)
for bad in "${FAKE_HOME}" "${FAKE_HOME}/projects" "${LLMCTL_DATA_DIR}"; do
  mkdir -p "${LLMCTL_DATA_DIR}"
  rc=0; out="$(HOME="${FAKE_HOME}" LLMCTL_ONNX_VENV="${bad}" engine_build_onnx 2>&1)" || rc=$?
  assert_eq "1" "$( [[ ${rc} -ne 0 ]] && echo 1 || echo 0)" "venv override '${bad}' is refused"
  assert_contains "${out}" "refusing" "...with a message"
done
assert_file_exists "${FAKE_HOME}/projects/precious/file.txt" "the override pointing at HOME/an ancestor deleted nothing"
for bad in "${LLMCTL_ROOT}" "/" "relative/venv" ""; do
  rc=0; HOME="${FAKE_HOME}" engine_venv_prepare "${bad}" >/dev/null 2>&1 || rc=$?
  assert_eq 1 "${rc}" "engine_venv_prepare refuses '${bad}'"
done
# an unrelated existing directory (no llmctl marker) is refused, a symlink is refused, a copied marker of another path is refused
mkdir -p "${TEST_TMP}/someproj/sub"; echo keep > "${TEST_TMP}/someproj/sub/f"
rc=0; out="$(LLMCTL_ONNX_VENV="${TEST_TMP}/someproj" engine_build_onnx 2>&1)" || rc=$?
assert_eq "1" "$( [[ ${rc} -ne 0 ]] && echo 1 || echo 0)" "an existing directory without the llmctl marker is refused"
assert_file_exists "${TEST_TMP}/someproj/sub/f" "...and left intact"
ln -s "${TEST_TMP}/someproj" "${TEST_TMP}/venvlink"
rc=0; out="$(LLMCTL_ONNX_VENV="${TEST_TMP}/venvlink" engine_build_onnx 2>&1)" || rc=$?
assert_eq "1" "$( [[ ${rc} -ne 0 ]] && echo 1 || echo 0)" "a symlink venv path is refused"
assert_contains "${out}" "symlink" "...naming the symlink"
assert_file_exists "${TEST_TMP}/someproj/sub/f" "...target intact"
mkdir -p "${TEST_TMP}/fakevenv"; echo "home = /usr/bin" > "${TEST_TMP}/fakevenv/pyvenv.cfg"
printf 'path=/some/other/place\n' > "${TEST_TMP}/fakevenv/${ENGINE_VENV_MARKER}"
rc=0; engine_venv_prepare "${TEST_TMP}/fakevenv" >/dev/null 2>&1 || rc=$?
assert_eq 1 "${rc}" "a marker naming a DIFFERENT path (a copied venv) is refused"
printf 'path=%s\n' "$(cd -P "${TEST_TMP}/fakevenv" && pwd -P)" > "${TEST_TMP}/fakevenv/${ENGINE_VENV_MARKER}"
rc=0; engine_venv_prepare "${TEST_TMP}/fakevenv" >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "an llmctl-made venv (marker naming exactly this path) may be replaced"
rc=0; engine_venv_prepare "${TEST_TMP}/does/not/exist" >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "a path that does not exist yet is fine"
# the legacy default location (venv built before the marker existed) stays replaceable
mkdir -p "${LLMCTL_DATA_DIR}/venv-onnx"; echo "home = /usr/bin" > "${LLMCTL_DATA_DIR}/venv-onnx/pyvenv.cfg"
rc=0; engine_venv_prepare "${LLMCTL_DATA_DIR}/venv-onnx" >/dev/null 2>&1 || rc=$?
assert_eq 0 "${rc}" "a marker-less venv at the DEFAULT location (built by an older llmctl) is replaceable"
rm -rf "${LLMCTL_DATA_DIR}/venv-onnx"

if [[ "${LLMCTL_TEST_NETWORK:-0}" == "1" ]]; then
  rc=0; ( engine_build_onnx >/dev/null 2>&1 ) || rc=$?
  assert_eq 0 "${rc}" "live: hash-locked install into a private venv succeeds"
  assert_file_exists "${LLMCTL_DATA_DIR}/venv-onnx/bin/python" "live: venv python exists"
  assert_eq "1.30.0" "$("${LLMCTL_DATA_DIR}/venv-onnx/bin/python" -B -c 'import onnxruntime; print(onnxruntime.__version__)')" "live: pinned onnxruntime imports"
  python3 - "${LOCK}" "${TEST_TMP}/tampered.lock" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
i = s.index("onnxruntime=="); j = s.index("# via", i)
blk = re.sub(r"--hash=sha256:.", lambda m: "--hash=sha256:" + ("0" if m.group(0)[-1] != "0" else "1"), s[i:j])
open(sys.argv[2], "w").write(s[:i] + blk + s[j:])
PY
  export LLMCTL_DATA_DIR="${TEST_TMP}/data-tamper"
  rc=0; ( LLMCTL_ONNX_LOCK="${TEST_TMP}/tampered.lock" engine_build_onnx >/dev/null 2>&1 ) || rc=$?
  assert_eq "1" "$( [[ ${rc} -ne 0 ]] && echo 1 || echo 0)" "live: a tampered hash makes the install FAIL"
  assert_file_absent "${LLMCTL_DATA_DIR}/venv-onnx" "live: failed install leaves no half-installed venv"
else
  assert_skip "needs PyPI access; set LLMCTL_TEST_NETWORK=1" "live hash-locked install + tamper rejection"
fi
test_finish
